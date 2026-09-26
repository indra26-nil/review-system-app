import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Who a person is in the product. Chosen once at sign-up and never changed
/// afterwards: the database restricts profile updates to cosmetic columns, so
/// there is no path from `user` to `owner` after the fact.
enum UserRole {
  customer('user', 'Customer', 'Browse places and leave reviews'),
  owner('owner', 'Store owner', 'Register a store and list your places');

  const UserRole(this.wire, this.label, this.blurb);
  final String wire;
  final String label;
  final String blurb;

  static UserRole fromWire(String? value) => UserRole.values
      .firstWhere((r) => r.wire == value, orElse: () => UserRole.customer);
}

/// A signed-in person.
class Account {
  const Account({
    required this.id,
    required this.email,
    required this.displayName,
    required this.role,
  });

  final String id;
  final String email;
  final String displayName;
  final UserRole role;

  bool get isOwner => role == UserRole.owner;
}

/// Why sign-in or sign-up failed, in terms the screen can show directly.
class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Email and password sign-in against Supabase Auth.
///
/// Written by hand over the Auth REST endpoints because pub.dev is unreachable
/// from this machine, so `supabase_flutter` cannot be installed. The endpoints
/// are ordinary HTTPS calls; the SDK's value is convenience, not capability.
///
/// Google and GitHub sign-in use the same endpoints, but they need a publicly
/// reachable Supabase and a redirect the device can receive. Those are wired
/// separately once the dashboard providers are configured.
class AuthService {
  AuthService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _prefsToken = 'revmap.access_token';
  static const _prefsRefresh = 'revmap.refresh_token';

  Account? _account;

  /// The signed-in account, or null when anonymous.
  Account? get account => _account;

  /// True when the app holds a usable session.
  bool get isSignedIn => _account != null;

  String? _persistedToken;

  // ------------------------------------------------------------------ session

  /// Restores a previous session so the user is not signed out between launches.
  ///
  /// A stored token can expire while the app is closed, so it is refreshed once
  /// before being trusted.
  Future<Account?> restore() async {
    if (!AppConfig.isConfigured) return null;
    final prefs = await SharedPreferences.getInstance();
    final refresh = prefs.getString(_prefsRefresh);
    if (refresh == null) return null;

    try {
      final res = await _client.post(
        Uri.parse('$authBase/token?grant_type=refresh_token'),
        headers: {'apikey': AppConfig.supabaseAnonKey, 'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refresh}),
      );
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      _persistedToken = body['access_token'] as String?;
      await prefs.setString(_prefsToken, _persistedToken ?? '');
      await prefs.setString(_prefsRefresh, body['refresh_token'] as String? ?? refresh);
      return await _loadAccount();
    } catch (_) {
      // A refresh can fail for benign reasons -- offline, expired, revoked --
      // and in every case the right answer is "not signed in" rather than a
      // crash, so the session is simply cleared.
      _account = null;
      _persistedToken = null;
      await prefs.remove(_prefsToken);
      await prefs.remove(_prefsRefresh);
      return null;
    }
  }

  /// Resolves the signed-in person: their auth record plus their profile.
  ///
  /// A profile is created on demand when one is missing. Accounts can be
  /// created outside the app -- the simulator console signs up through Supabase
  /// Auth alone, and the app's own sign-up can fail to write the profile -- and
  /// previously that produced "Signed in, but no profile found" with no way out
  /// but making yet another account. RLS permits this insert because the policy
  /// requires only that auth.uid() equals the supplied id.
  Future<Account?> _loadAccount() async {
    final token = _persistedToken;
    if (token == null) return null;

    // The auth record is the source of the id and email; the profile holds the
    // role and display name.
    final Map<String, dynamic> user;
    try {
      final res = await _client.get(
        Uri.parse('$authBase/user'),
        headers: {
          'apikey': AppConfig.supabaseAnonKey,
          'Authorization': 'Bearer $token',
        },
      );
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      user = decoded;
    } catch (_) {
      return null;
    }

    final userId = '${user['id'] ?? ''}';
    if (userId.isEmpty) return null;
    final email = '${user['email'] ?? ''}';

    var row = await _fetchProfile(userId);

    if (row == null) {
      row = await _createProfile(userId, email);
    }
    if (row == null) return null;

    final name = '${row['display_name'] ?? ''}'.trim();
    return _account = Account(
      id: userId,
      email: email,
      displayName: name.isEmpty ? _localPart(email) : name,
      role: UserRole.fromWire(row['role']?.toString()),
    );
  }

  /// The caller's own profile. RLS permits reading only their row.
  Future<Map<String, dynamic>?> _fetchProfile(String userId) async {
    try {
      final res = await _client.get(
        Uri.parse('$restBase/profiles?select=id,display_name,role'
            '&id=eq.$userId&limit=1'),
        headers: {
          'apikey': AppConfig.supabaseAnonKey,
          'Authorization': 'Bearer $_persistedToken',
        },
      );
      if (res.statusCode != 200) return null;
      final rows = jsonDecode(res.body);
      if (rows is! List || rows.isEmpty) return null;
      return rows.first as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Creates the missing profile, defaulting to the customer role.
  ///
  /// The role is `user` and always is: an account may not make itself a store
  /// owner, and the database would refuse an update to that column anyway.
  Future<Map<String, dynamic>?> _createProfile(String userId, String email) async {
    try {
      final res = await _client.post(
        Uri.parse('$restBase/profiles'),
        headers: {
          'apikey': AppConfig.supabaseAnonKey,
          'Authorization': 'Bearer $_persistedToken',
          'Content-Type': 'application/json',
          'Prefer': 'return=representation',
        },
        body: jsonEncode({
          'id': userId,
          'handle': await _uniqueHandle(userId, email),
          'display_name': _localPart(email),
          'role': UserRole.customer.wire,
        }),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final rows = jsonDecode(res.body);
      if (rows is List && rows.isNotEmpty) {
        return rows.first as Map<String, dynamic>;
      }
      return await _fetchProfile(userId);
    } catch (_) {
      return null;
    }
  }

  /// A readable, unique handle: the email's local part plus a short suffix
  /// from the user id, so two people on the same domain never collide.
  Future<String> _uniqueHandle(String userId, String email) async {
    final base = _localPart(email).replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    var candidate = '${base.isEmpty ? 'user' : base}-${userId.substring(0, 4)}';
    for (var attempt = 0; attempt < 4; attempt++) {
      final existing = await _handleTaken(candidate);
      if (!existing) return candidate;
      candidate = '$base-${userId.substring(0, 4)}-${attempt + 1}';
    }
    return candidate;
  }

  /// The handle is unique, so a collision has to be detected rather than
  /// assumed away -- otherwise the sign-in retry hits a duplicate-key error.
  Future<bool> _handleTaken(String handle) async {
    try {
      final res = await _client.get(
        Uri.parse('$restBase/profiles?select=id&handle=eq.$handle&limit=1'),
        headers: {
          'apikey': AppConfig.supabaseAnonKey,
          'Authorization': 'Bearer $_persistedToken',
        },
      );
      if (res.statusCode != 200) return false;
      final rows = jsonDecode(res.body);
      return rows is List && rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static String _localPart(String email) =>
      email.split('@').first.trim();

  String get authBase => '${AppConfig.supabaseUrl}/auth/v1';
  String get restBase => '${AppConfig.supabaseUrl}/rest/v1';

  /// The bearer token, for repositories that make their own calls.
  String? get accessToken => _persistedToken;

  // ------------------------------------------------------------------- actions

  /// Creates an account and its profile, then signs in.
  ///
  /// [role] is written once here and can never be changed later: the database
  /// grants UPDATE only on cosmetic profile columns.
  Future<Account> signUp({
    required String email,
    required String password,
    required String displayName,
    required UserRole role,
  }) async {
    _requireConfig();
    final res = await _client.post(
      Uri.parse('$authBase/signup'),
      headers: {'apikey': AppConfig.supabaseAnonKey, 'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    final body = _decode(res);

    // A brand-new user sometimes has no session yet (email confirmation on).
    final token = body['access_token']?.toString();
    if (token == null) {
      final session = body['session'] as Map<String, dynamic>?;
      if (session == null) {
        throw AuthException(
            'Account created. Check your email to confirm it, then sign in.');
      }
      _persistedToken = session['access_token'] as String?;
    } else {
      _persistedToken = token;
    }

    final userId = body['id']?.toString() ??
        (body['user'] as Map<String, dynamic>?)?['id']?.toString();
    if (userId != null) {
      await _client.post(
        Uri.parse('$restBase/profiles'),
        headers: {
          'apikey': AppConfig.supabaseAnonKey,
          'Authorization': 'Bearer $_persistedToken',
          'Content-Type': 'application/json',
          'Prefer': 'return=minimal',
        },
        body: jsonEncode({
          'id': userId,
          'handle': _handleFor(email, userId),
          'display_name': displayName,
          'role': role.wire,
        }),
      );
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsToken, _persistedToken ?? '');
    if (body['refresh_token'] != null) {
      await prefs.setString(_prefsRefresh, '${body['refresh_token']}');
    }

    final account = await _loadAccount();
    if (account == null) {
      throw AuthException('Signed up, but the profile could not be read. Try signing in.');
    }
    return account;
  }

  Future<Account> signIn({required String email, required String password}) async {
    _requireConfig();
    final res = await _client.post(
      Uri.parse('$authBase/token?grant_type=password'),
      headers: {'apikey': AppConfig.supabaseAnonKey, 'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    final body = _decode(res);
    _persistedToken = body['access_token'] as String?;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsToken, _persistedToken ?? '');
    if (body['refresh_token'] != null) {
      await prefs.setString(_prefsRefresh, '${body['refresh_token']}');
    }

    final account = await _loadAccount();
    if (account == null) throw AuthException('Signed in, but no profile was found.');
    return account;
  }

  Future<void> signOut() async {
    _account = null;
    _persistedToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsToken);
    await prefs.remove(_prefsRefresh);
  }

  void _requireConfig() {
    if (!AppConfig.isConfigured) {
      throw AuthException(AppConfig.missingConfig);
    }
  }

  /// Turns PostgREST/GoTrue error bodies into something a person can read.
  Map<String, dynamic> _decode(http.Response res) {
    dynamic decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    } on FormatException {
      decoded = null;
    }
    final map = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};

    if (res.statusCode >= 200 && res.statusCode < 300) return map;

    final raw = (map['error_description'] ?? map['msg'] ?? map['message'] ?? '').toString();
    final lower = raw.toLowerCase();
    throw AuthException(switch (lower) {
      _ when lower.contains('invalid login') =>
        'That email and password do not match an account.',
      _ when lower.contains('already registered') ||
              lower.contains('already been registered') =>
        'An account already exists for that email. Sign in instead.',
      _ when lower.contains('password should be') ||
              lower.contains('at least') =>
        'Passwords need to be at least 6 characters.',
      _ when lower.contains('email address') || lower.contains('unable to validate') =>
        'That does not look like a valid email address.',
      _ when lower.contains('rate limit') || lower.contains('too many') =>
        'Too many attempts. Wait a moment and try again.',
      _ when raw.isEmpty => 'Sign-in failed (HTTP ${res.statusCode}).',
      _ => raw,
    });
  }

  /// A readable, unique handle: the local part of the email, suffixed if needed.
  static String _handleFor(String email, String userId) {
    final base = email.split('@').first.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    final trimmed = base.length > 24 ? base.substring(0, 24) : base;
    return '$trimmed-${userId.substring(0, 4)}';
  }

  void close() => _client.close();
}
