import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Why a backend call failed, in terms the UI can act on.
enum ApiErrorKind {
  /// No credentials were compiled in, so there is nothing to talk to.
  notConfigured,

  /// The device could not reach the host.
  network,

  /// Credentials were sent but rejected.
  unauthorised,

  /// The request was rejected by a policy, trigger or constraint.
  rejected,

  /// Anything else, including server faults.
  unknown,
}

class ApiException implements Exception {
  ApiException(this.kind, this.message, {this.statusCode, this.code});

  final ApiErrorKind kind;
  final String message;

  /// HTTP status, when the request reached the server.
  final int? statusCode;

  /// PostgREST/Supabase machine-readable code, e.g. `42501` for RLS denial.
  final String? code;

  /// Message suitable for showing a person.
  String get userMessage => switch (kind) {
        ApiErrorKind.notConfigured => AppConfig.missingConfig,
        ApiErrorKind.network =>
          'No connection. Showing saved places instead.',
        ApiErrorKind.unauthorised => 'Please sign in to continue.',
        ApiErrorKind.rejected => message,
        ApiErrorKind.unknown => 'Something went wrong. Please try again.',
      };

  @override
  String toString() => 'ApiException($kind, $statusCode, $message)';
}

/// A thin REST client for Supabase's PostgREST API.
///
/// Written by hand rather than using `supabase_flutter` because pub.dev is
/// unreachable from this machine, so no new packages can be installed. PostgREST
/// is an ordinary JSON-over-HTTPS API, so the SDK's value here is convenience,
/// not capability.
///
/// The anon key is public by design; **row-level security in the database is
/// what protects the data**, not this key's secrecy. The `service_role` key
/// must never be sent from a client.
class ApiClient {
  /// [baseUrl] and [anonKey] default to the compile-time configuration but can
  /// be overridden, which is what makes the client testable without a build
  /// flag and lets a future multi-environment build swap hosts.
  ApiClient({http.Client? client, String? baseUrl, String? anonKey})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? AppConfig.supabaseUrl,
        _anonKey = anonKey ?? AppConfig.supabaseAnonKey;

  final http.Client _client;
  final String _baseUrl;
  final String _anonKey;

  /// True when this client has somewhere to send requests.
  bool get isConfigured => _baseUrl.isNotEmpty && _anonKey.isNotEmpty;

  static const _timeout = Duration(seconds: 12);

  /// Bearer token for the signed-in user. Null means anonymous, which is
  /// enough for reading published data.
  String? accessToken;

  /// Install identity used for device-risk signals. A random value generated
  /// once per install — deliberately not a hardware identifier, so it cannot be
  /// used to track a person across apps.
  String? installId;

  Map<String, String> get _headers {
    final headers = <String, String>{
      'apikey': _anonKey,
      'Content-Type': 'application/json',
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    };
    // Added after construction: the null-aware element marker cannot narrow
    // String? to String inside a Map<String, String> literal.
    final id = installId;
    if (id != null) headers['x-revmap-install'] = id;
    return headers;
  }

  /// Builds an absolute PostgREST URL for [path], which must start with `/`.
  ///
  /// The base already ends in `/rest/v1`, so appending another `/v1` here
  /// produced `/rest/v1/v1/places` -- a 404 for every request, which surfaced
  /// as "cannot reach the backend" and made the app silently serve sample data.
  /// Builds a PostgREST URL.
  ///
  /// A [List] value repeats the key, which is how a bounding box is expressed:
  /// `latitude=gte.12.9&latitude=lte.13.0` is an AND across the same column.
  /// A plain `or=(a,b,c,d)` cannot express that -- it means a or b or c or d.
  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse('$_baseUrl/rest/v1');
    if (query == null || query.isEmpty) return base.replace(path: '${base.path}$path');

    final parts = <String>[];
    for (final entry in query.entries) {
      final value = entry.value;
      if (value == null) continue;
      for (final v in (value is List ? value : [value])) {
        parts.add('${Uri.encodeQueryComponent(entry.key)}='
            '${Uri.encodeQueryComponent('$v')}');
      }
    }
    return base.replace(
      path: '${base.path}$path',
      query: parts.isEmpty ? null : parts.join('&'),
    );
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) {
    final uri = _uri(path, query);
    return _send(() => _client.get(uri, headers: _headers));
  }

  /// A deliberately trivial request, used to tell two failures apart.
  ///
  /// "Could not reach the backend" covers a DNS failure, a TLS failure and a
  /// rejected query equally, which is not enough to act on. If a one-column
  /// request succeeds while the real one does not, the problem is the query; if
  /// both fail, it is the connection.
  Future<String> probe() async {
    final started = DateTime.now();
    try {
      final res = await _client
          .get(_uri('/places', {'limit': '1', 'select': 'id'}), headers: _headers)
          .timeout(const Duration(seconds: 8));
      debugPrint('[RevMap] probe ${res.statusCode} in '
          '${DateTime.now().difference(started).inMilliseconds}ms');
      return '${res.statusCode}';
    } catch (e) {
      debugPrint('[RevMap] probe failed after '
          '${DateTime.now().difference(started).inMilliseconds}ms: '
          '${e.runtimeType}: $e');
      return 'failed';
    }
  }

  Future<dynamic> post(String path, Object? body,
      {bool returning = false}) {
    return _send(() {
      final headers = {..._headers, if (returning) 'Prefer': 'return=representation'};
      return _client.post(_uri(path), headers: headers, body: jsonEncode(body));
    });
  }

  Future<dynamic> patch(String path, Object? body) {
    return _send(() => _client.patch(
          _uri(path),
          headers: _headers,
          body: jsonEncode(body),
        ));
  }

  Future<void> delete(String path) {
    return _send(() => _client.delete(_uri(path), headers: _headers));
  }

  Future<dynamic> _send(Future<http.Response> Function() run) async {
    if (!isConfigured) {
      throw ApiException(
          ApiErrorKind.notConfigured,
          'Backend not configured '
              '(${_baseUrl.isEmpty ? 'missing SUPABASE_URL' : 'missing SUPABASE_ANON_KEY'})');
    }

    late final http.Response res;
    try {
      res = await run().timeout(_timeout);
    } on TimeoutException {
      throw ApiException(ApiErrorKind.network, 'The request timed out.');
    } catch (e) {
      // SocketException, DNS failure, TLS problems — all "can't reach it".
      //
      // The detail is logged because the message alone has been misleading:
      // a malformed URI and a DNS failure both arrived as "could not reach".
      // The error is still wrapped rather than rethrown, so callers can keep
      // branching on ApiErrorKind (the map retries only the network kind).
      debugPrint('[RevMap] api error: ${e.runtimeType}: $e');
      throw ApiException(ApiErrorKind.network, 'Could not reach the backend.');
    }

    if (res.statusCode == 204 || res.body.isEmpty) return null;

    dynamic decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    } on FormatException {
      decoded = null;
    }

    if (res.statusCode >= 200 && res.statusCode < 300) return decoded;

    // PostgREST puts the machine-readable reason in a `code` field and the
    // detail in `message` (sometimes `hint` / `details`).
    final map = decoded is Map<String, dynamic> ? decoded : const {};
    final code = map['code']?.toString();
    final message = (map['message'] ?? map['hint'] ?? res.reasonPhrase)
        ?.toString()
        .trim();

    final kind = switch (res.statusCode) {
      401 || 403 => ApiErrorKind.unauthorised,
      400 || 409 || 42501 => ApiErrorKind.rejected,
      _ => ApiErrorKind.unknown,
    };

    // An RLS denial is worth saying plainly, because it is the security model
    // working rather than a bug.
    final friendly = code == '42501'
        ? 'Not allowed to do that.'
        : (message == null || message.isEmpty ? 'Request failed.' : message);

    throw ApiException(kind, friendly,
        statusCode: res.statusCode, code: code);
  }

  void close() => _client.close();
}
