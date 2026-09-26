import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// A named scenario from the specification's §18 table.
///
/// Each carries the inputs *and* the weight the specification says they should
/// produce, so the simulator can show its own arithmetic next to the target and
/// a drift between the two is visible rather than silent.
class TrustScenario {
  const TrustScenario({
    required this.label,
    required this.blurb,
    required this.userTrust,
    required this.cityTrust,
    required this.reviewTrust,
    required this.expectedWeight,
    this.stars = 5,
  });

  final String label;
  final String blurb;
  final double userTrust;
  final double cityTrust;
  final double reviewTrust;
  final double expectedWeight;
  final int stars;
}

/// The nine worked examples, taken verbatim from the specification.
const List<TrustScenario> kTrustScenarios = [
  TrustScenario(
    label: 'A · Local, trusted, verified',
    blurb: 'The strongest reviewer the model allows',
    userTrust: 90, cityTrust: 90, reviewTrust: 95, expectedWeight: 0.975,
  ),
  TrustScenario(
    label: 'B · Trusted visitor, verified',
    blurb: 'Not a local, but a genuine visit',
    userTrust: 90, cityTrust: 30, reviewTrust: 95, expectedWeight: 0.8775,
  ),
  TrustScenario(
    label: 'C · Trusted local, unverified',
    blurb: 'A local without visit evidence',
    userTrust: 90, cityTrust: 90, reviewTrust: 30, expectedWeight: 0.65,
  ),
  TrustScenario(
    label: 'D · Normal local, verified',
    blurb: 'An ordinary established local',
    userTrust: 60, cityTrust: 85, reviewTrust: 90, expectedWeight: 0.7125,
  ),
  TrustScenario(
    label: 'E · Normal visitor, verified',
    blurb: 'No local standing, solid evidence',
    userTrust: 60, cityTrust: 20, reviewTrust: 90, expectedWeight: 0.57,
  ),
  TrustScenario(
    label: 'F · New account, verified',
    blurb: 'A new account cannot buy influence',
    userTrust: 30, cityTrust: 20, reviewTrust: 95, expectedWeight: 0.2925,
  ),
  TrustScenario(
    label: 'G · Weak account, spoofed visit',
    blurb: 'A strong signal cannot rescue a weak account',
    userTrust: 20, cityTrust: 20, reviewTrust: 95, expectedWeight: 0.195,
  ),
  TrustScenario(
    label: 'H · Trusted visitor, perfect visit',
    blurb: 'A traveller the system fully trusts',
    userTrust: 98, cityTrust: 20, reviewTrust: 100, expectedWeight: 0.98,
  ),
  TrustScenario(
    label: 'I · Trusted local, no evidence',
    blurb: 'The floor: strong reviewer, nothing to show',
    userTrust: 100, cityTrust: 100, reviewTrust: 0, expectedWeight: 0.5,
  ),
];

class SimulationException implements Exception {
  SimulationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Drives the trust simulator.
///
/// Every value it shows comes from the database running the real formula; this
/// class never computes a weight itself. If the app's arithmetic ever drifted
/// from the specification's, the simulator would be the place it showed.
class SimulationRepository {
  SimulationRepository({http.Client? client, String? accessToken})
      : _client = client ?? http.Client(),
        _token = accessToken;

  final http.Client _client;
  final String? _token;

  Map<String, String> get _headers => {
        'apikey': AppConfig.supabaseAnonKey,
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  String get _rest => '${AppConfig.supabaseUrl}/rest/v1';

  /// True when the simulator has been switched on in the database.
  Future<bool> isEnabled() async {
    try {
      final res = await _client.get(
        Uri.parse('$_rest/trust_config?key=eq.simulator_enabled&select=value&limit=1'),
        headers: _headers,
      );
      if (res.statusCode != 200) return false;
      final rows = jsonDecode(res.body);
      if (rows is! List || rows.isEmpty) return false;
      return ((rows.first['value'] as num?) ?? 0) >= 1;
    } catch (_) {
      return false;
    }
  }

  /// The weight the *database's* formula gives for these inputs.
  ///
  /// Round-tripped rather than mirrored, so the number on screen is the one that
  /// will actually be stored.
  Future<double?> preview({
    required double userTrust,
    required double cityTrust,
    required double reviewTrust,
  }) async {
    final res = await _rpc('sim_preview_weight', {
      'p_user_trust': userTrust,
      'p_city_trust': cityTrust,
      'p_review_trust': reviewTrust,
    });
    return (res is num) ? res.toDouble() : null;
  }

  Future<String> createAccount(String handle) async {
    final res = await _client.post(
      Uri.parse('$_rest/rpc/sim_create_account'),
      headers: _headers,
      body: jsonEncode({'p_handle': handle, 'p_role': 'user'}),
    );
    if (res.statusCode != 200) {
      throw SimulationException(_message(res, 'Could not create the account'));
    }
    return '${jsonDecode(res.body)}';
  }

  Future<void> setTrust({
    required String userId,
    required String placeId,
    required double userTrust,
    required double cityTrust,
  }) async {
    final res = await _client.post(
      Uri.parse('$_rest/rpc/sim_set_trust'),
      headers: _headers,
      body: jsonEncode({
        'p_user_id': userId,
        'p_place_id': placeId,
        'p_user_trust': userTrust,
        'p_city_trust': cityTrust,
      }),
    );
    if (res.statusCode != 200) {
      throw SimulationException(_message(res, 'Could not set the trust scores'));
    }
  }

  Future<void> postReview({
    required String userId,
    required String placeId,
    required int rating,
    required double reviewTrust,
    String text = 'Simulated review',
  }) async {
    final res = await _client.post(
      Uri.parse('$_rest/rpc/sim_post_review'),
      headers: _headers,
      body: jsonEncode({
        'p_user_id': userId,
        'p_place_id': placeId,
        'p_rating': rating,
        'p_review_trust': reviewTrust,
        'p_text': text,
      }),
    );
    if (res.statusCode != 200) {
      throw SimulationException(_message(res, 'Could not post the review'));
    }
  }

  /// The live aggregate for a place, so the demonstrator can watch it move.
  Future<SimulationSummary?> summary(String placeId) async {
    final res = await _rpc('sim_place_summary', {'p_place_id': placeId});
    return res is Map<String, dynamic> ? SimulationSummary.fromJson(res) : null;
  }

  Future<void> reset() async {
    final res = await _client.post(
      Uri.parse('$_rest/rpc/sim_reset'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{}),
    );
    if (res.statusCode != 200) {
      throw SimulationException(_message(res, 'Could not reset'));
    }
  }

  Future<dynamic> _rpc(String function, Map<String, dynamic> args) async {
    try {
      final res = await _client.post(
        Uri.parse('$_rest/rpc/$function'),
        headers: _headers,
        body: jsonEncode(args),
      );
      if (res.statusCode != 200) {
        throw SimulationException(_message(res, 'The simulator call failed'));
      }
      return jsonDecode(res.body);
    } on SimulationException {
      rethrow;
    } catch (_) {
      throw SimulationException('Could not reach the simulator.');
    }
  }

  /// Turns a Postgres or Supabase error into something presentable.
  String _message(http.Response res, String fallback) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map) {
        final raw = '${body['message'] ?? body['msg'] ?? ''}';
        if (raw.toLowerCase().contains('disabled')) {
          return 'The simulator is switched off in the database. '
              'Set simulator_enabled = 1 in trust_config.';
        }
        if (raw.isNotEmpty) return raw;
      }
    } catch (_) {
      if (res.statusCode == 401 || res.statusCode == 403) {
        return 'Sign in first — the simulator needs an authenticated session.';
      }
    }
    return fallback;
  }

  void close() => _client.close();
}

class SimulationSummary {
  const SimulationSummary({
    required this.adjustedRating,
    required this.effectiveCount,
    required this.rawCount,
    required this.confidence,
  });

  factory SimulationSummary.fromJson(Map<String, dynamic> j) => SimulationSummary(
        adjustedRating: (j['adjusted_rating'] as num?)?.toDouble() ?? 0,
        effectiveCount: (j['effective_count'] as num?)?.toDouble() ?? 0,
        rawCount: (j['raw_count'] as num?)?.toInt() ??
            (j['review_rows'] as num?)?.toInt() ??
            0,
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
      );

  final double adjustedRating;
  final double effectiveCount;
  final int rawCount;
  final double confidence;

  String get confidenceLabel {
    if (confidence >= 0.65) return 'Strong';
    if (confidence >= 0.35) return 'Moderate';
    return 'Limited';
  }
}
