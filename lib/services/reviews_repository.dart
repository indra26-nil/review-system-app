import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';

/// Public evidence labels, as opposed to the raw numbers behind them.
///
/// The server stores the full breakdown in `explanation`, but showing
/// `device_risk = 0.72` publicly would hand attackers a tuning oracle. These
/// are the only review properties that leave the database.
enum ReviewerStatus {
  established('established', 'Established account'),
  newAccount('new', 'New account');

  const ReviewerStatus(this.wire, this.label);
  final String wire;
  final String label;

  static ReviewerStatus fromTrust(num? trust) =>
      (trust ?? 0) >= 60 ? ReviewerStatus.established : ReviewerStatus.newAccount;
}

enum EvidenceLevel {
  strong('strong', 'Strong evidence'),
  moderate('moderate', 'Moderate evidence'),
  weak('weak', 'Limited evidence');

  const EvidenceLevel(this.wire, this.label);
  final String wire;
  final String label;

  static EvidenceLevel fromTrust(num? reviewTrust) {
    final t = reviewTrust ?? 0;
    if (t >= 70) return EvidenceLevel.strong;
    if (t >= 40) return EvidenceLevel.moderate;
    return EvidenceLevel.weak;
  }
}

/// A review as the public is allowed to see it.
class Review {
  const Review({
    required this.id,
    required this.authorName,
    required this.rating,
    required this.text,
    required this.createdAt,
    required this.verifiedVisit,
    required this.reviewerStatus,
    required this.evidenceLevel,
    required this.isOwner,
  });

  final String id;
  final String authorName;
  final int rating;
  final String text;
  final DateTime createdAt;
  final bool verifiedVisit;
  final ReviewerStatus reviewerStatus;
  final EvidenceLevel evidenceLevel;

  /// True when the reviewer owns the store being reviewed. Such a review is
  /// excluded from the aggregate rather than merely trusted less.
  final bool isOwner;
}

/// A place's aggregate, as the server calculates it.
class PlaceRating {
  const PlaceRating({
    required this.adjustedRating,
    required this.effectiveReviews,
    required this.rawReviews,
    required this.confidence,
  });

  /// Bayesian-smoothed, evidence-weighted rating.
  final double adjustedRating;

  /// Sum of review weights. 100 raw reviews can total 42.7 here.
  final double effectiveReviews;
  final int rawReviews;

  /// How much independent evidence supports the aggregate, 0..1.
  final double confidence;

  String get confidenceLabel {
    if (confidence >= 0.65) return 'Strong';
    if (confidence >= 0.35) return 'Moderate';
    return 'Limited';
  }
}

class ReviewsException implements Exception {
  ReviewsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reading and writing reviews.
///
/// Note what the client sends: a rating, some text, and optionally a visit
/// proof. It never sends a weight, a trust score or a confidence value — those
/// columns are not grantable to the app, and the database computes them.
class ReviewsRepository {
  ReviewsRepository({http.Client? client, String? accessToken})
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

  /// The server-computed aggregate and confidence for a place.
  ///
  /// Both come from the database rather than the client, so a stale or
  /// hand-edited rating on the device cannot disagree with the aggregate.
  Future<PlaceRating> ratingFor(String placeId) async {
    final results = await Future.wait([
      _rpcOne('place_rating', placeId),
      _rpcOne('place_confidence', placeId),
    ]);

    final rating = results[0];
    final confidence = results[1] ?? 0;
    if (rating == null) {
      return PlaceRating(
        adjustedRating: 0,
        effectiveReviews: 0,
        rawReviews: 0,
        confidence: 0,
      );
    }
    return PlaceRating(
      adjustedRating: (rating['adjusted_rating'] as num?)?.toDouble() ?? 0,
      effectiveReviews:
          (rating['effective_review_count'] as num?)?.toDouble() ?? 0,
      rawReviews: (rating['raw_review_count'] as num?)?.toInt() ?? 0,
      confidence: (confidence as num?)?.toDouble() ?? 0,
    );
  }

  /// Calls a function that returns a single row, tolerating failure.
  ///
  /// Confidence is a nice-to-have; if it fails the card still shows a rating
  /// rather than nothing.
  Future<dynamic> _rpcOne(String function, String placeId) async {
    try {
      final res = await _client.post(
        Uri.parse('$_rest/rpc/$function'),
        headers: _headers,
        body: jsonEncode({'p_place_id': placeId}),
      );
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is List) return decoded.isEmpty ? null : decoded.first;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  /// Published reviews for a place, newest first.
  Future<List<Review>> reviewsFor(String placeId) async {
    final res = await _client.get(
      Uri.parse('$_rest/reviews'
          '?select=id,user_id,rating,text,created_at,visit_proof_id,'
          'review_trust,user_trust,is_owner'
          '&place_id=eq.$placeId'
          '&status=eq.published'
          '&order=created_at.desc'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw ReviewsException('Could not load reviews.');
    }
    return _rows(res).map(_fromRow).toList();
  }

  /// Submits a review.
  ///
  /// The `review_weight`, `user_trust`, `city_trust`, `review_trust` and
  /// `fraud_score` are all written by the BEFORE INSERT trigger. A malicious
  /// client that tried to send them would be refused at the permission layer.
  Future<void> submit({
    required String placeId,
    required int rating,
    String text = '',
    String? visitProofId,
  }) async {
    final res = await _client.post(
      Uri.parse('$_rest/reviews'),
      headers: {..._headers, 'Prefer': 'return=minimal'},
      body: jsonEncode({
        'place_id': placeId,
        'rating': rating,
        'text': text,
        if (visitProofId != null) 'visit_proof_id': visitProofId,
      }),
    );
    if (res.statusCode >= 200 && res.statusCode < 300) return;

    // The trigger raises with these codes, and they mean specific things.
    var message = 'Could not submit the review.';
    try {
      final body = jsonDecode(res.body);
      if (body is Map) {
        final raw = '${body['message'] ?? body['msg'] ?? ''}'.toLowerCase();
        if (raw.contains('rate limit')) {
          message = 'You have reached the review limit. Try again later.';
        } else if (raw.contains('unique') || raw.contains('duplicate')) {
          message = 'You have already reviewed this place. Edit your review instead.';
        } else if (raw.contains('visit proof')) {
          message = 'That visit verification is no longer valid.';
        } else if (raw.contains('row-level security') || res.statusCode == 42501) {
          message = 'Please sign in to leave a review.';
        } else if (raw.isNotEmpty) {
          message = '${body['message']}';
        }
      }
    } catch (_) {
      if (res.statusCode == 401) message = 'Please sign in to leave a review.';
    }
    throw ReviewsException(message);
  }

  Review _fromRow(Map<String, dynamic> r) {
    return Review(
      id: '${r['id']}',
      // The author's name is not public, so reviews are shown anonymously with
      // an initial. Joining the author's real name would turn the review
      // section into a directory of everyone's activity.
      authorName: _initial('${r['user_id']}'),
      rating: (r['rating'] as num?)?.toInt() ?? 0,
      text: '${r['text'] ?? ''}',
      createdAt:
          DateTime.tryParse('${r['created_at']}')?.toLocal() ?? DateTime.now(),
      verifiedVisit: r['visit_proof_id'] != null,
      reviewerStatus: ReviewerStatus.fromTrust(r['user_trust'] as num?),
      evidenceLevel: EvidenceLevel.fromTrust(r['review_trust'] as num?),
      isOwner: r['is_owner'] == true,
    );
  }

  static String _initial(String userId) =>
      userId.isEmpty ? '?' : userId.substring(0, 1).toUpperCase();

  List<Map<String, dynamic>> _rows(http.Response res) {
    if (res.body.isEmpty) return const [];
    final decoded = jsonDecode(res.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  void close() => _client.close();
}

/// Convenience for the "near me" bias used by search.
typedef SearchBias = LatLng;
