import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/search_result.dart';

/// Thrown when a place search cannot be completed.
class GeocodingException implements Exception {
  GeocodingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Place search backed by [Photon], a free geocoder built on OpenStreetMap data.
///
/// Photon is used instead of Nominatim because Nominatim's public endpoint
/// refuses traffic from many shared/datacenter IP addresses with **HTTP 403
/// "Access denied"**, regardless of User-Agent. Photon is key-less, needs no
/// billing, and draws from the same OpenStreetMap data as the map tiles, so the
/// two stay consistent. Attribution to OpenStreetMap contributors is still
/// required and is shown under the result list.
class GeocodingService {
  GeocodingService({http.Client? client})
      : _client = client ?? debugClient ?? http.Client();

  /// Lets a test inject a fake HTTP client, so geocoding can be exercised
  /// without touching the network. Null in normal use.
  static http.Client? debugClient;

  final http.Client _client;

  static const _host = 'photon.komoot.io';
  static const _path = '/api';
  static const _reversePath = '/reverse';

  /// Identifying string, as the OSM Foundation asks every client to send.
  static const _userAgent =
      'RevMap/1.0 (Android; OpenStreetMap data consumer)';

  /// Small floor between requests so a fast typist cannot flood the service.
  /// Photon has no published hard cap, but it is a shared free service.
  static const _minRequestInterval = Duration(milliseconds: 350);

  DateTime? _lastRequestAt;
  Timer? _throttle;

  /// Runs [query] against Photon, waiting first if the previous request was too
  /// recent.
  ///
  /// [near] optionally biases results towards a point, so "coffee" near where
  /// the user is standing beats "coffee" in the middle of the Atlantic.
  Future<List<SearchResult>> search(String query, {LatLng? near}) async {
    final term = query.trim();
    if (term.length < 2) return const [];

    await _respectRateLimit();

    final uri = Uri.https(_host, _path, {
      'q': term,
      'limit': '8',
      'lang': 'en',
      if (near != null) ...{
        'lat': near.latitude.toStringAsFixed(4),
        'lon': near.longitude.toStringAsFixed(4),
      },
    });

    late final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw GeocodingException('The search took too long. Check your connection.');
    } catch (_) {
      throw GeocodingException('Could not reach the search service.');
    }

    if (response.statusCode != 200) {
      if (response.statusCode == 403) {
        throw GeocodingException(
          'The search service is refusing requests from this network.',
        );
      }
      if (response.statusCode == 429) {
        throw GeocodingException('Searching too quickly. Try again in a moment.');
      }
      throw GeocodingException('Search failed (HTTP ${response.statusCode}).');
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return const [];
      final features = decoded['features'];
      if (features is! List) return const [];

      final results = <SearchResult>[];
      for (final item in features) {
        if (item is! Map<String, dynamic>) continue;
        // One malformed feature should not discard the whole response.
        try {
          results.add(SearchResult.fromPhoton(item));
        } on FormatException {
          continue;
        }
      }
      return results;
    } on FormatException {
      throw GeocodingException('The search service returned an unexpected response.');
    }
  }

  /// Looks up what is at [latitude]/[longitude] — the reverse of [search].
  ///
  /// Returns `null` when the point is nowhere interesting (open country, sea),
  /// which is a normal answer rather than an error: the UI then falls back to
  /// showing bare coordinates.
  Future<SearchResult?> reverse({
    required double latitude,
    required double longitude,
  }) async {
    await _respectRateLimit();

    final uri = Uri.https(_host, _reversePath, {
      'lat': latitude.toStringAsFixed(6),
      'lon': longitude.toStringAsFixed(6),
      'lang': 'en',
    });

    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      return null;
    }
    debugPrint('[RevMap] reverse ${response.statusCode} at '
        '${latitude.toStringAsFixed(4)},${longitude.toStringAsFixed(4)}');
    if (response.statusCode != 200) return null;

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      final features = decoded['features'];
      if (features is! List || features.isEmpty) {
        debugPrint('[RevMap] reverse: nothing found at '
            '${latitude.toStringAsFixed(4)},${longitude.toStringAsFixed(4)}');
        return null;
      }
      final first = features.first;
      if (first is! Map<String, dynamic>) return null;
      final result = SearchResult.fromPhoton(first);
      debugPrint('[RevMap] reverse -> ${result.title}');
      return result;
    } on FormatException {
      return null;
    }
  }

  /// Completes once enough time has passed since the last request.
  Future<void> _respectRateLimit() {    final last = _lastRequestAt;
    if (last == null) {
      _lastRequestAt = DateTime.now();
      return Future.value();
    }

    final elapsed = DateTime.now().difference(last);
    if (elapsed >= _minRequestInterval) {
      _lastRequestAt = DateTime.now();
      return Future.value();
    }

    final wait = _minRequestInterval - elapsed;
    final completer = Completer<void>();
    _throttle?.cancel();
    _throttle = Timer(wait, () {
      _lastRequestAt = DateTime.now();
      completer.complete();
    });
    return completer.future;
  }

  void dispose() {
    _throttle?.cancel();
    _client.close();
  }
}
