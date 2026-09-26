// Tests for the Supabase data layer.
//
// The repository is exercised against a fake HTTP client so no network or
// running backend is needed: what matters here is that rows are parsed
// correctly, that a bad row cannot poison a whole viewport, and that an
// unreachable backend degrades to sample data rather than an empty map.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:revamp/models/place.dart';
import 'package:revamp/services/api_client.dart';
import 'package:revamp/services/places_repository.dart';

/// A row shaped like PostgREST returns for a place with its one-to-one stats
/// join: `place_seed_stats` comes back as a single-element list.
Map<String, dynamic> placeRow({
  String id = 'p1',
  String name = 'Cubbon Park',
  String category = 'attraction',
  double lat = 12.9763,
  double lng = 77.5929,
  num? rating = 4.6,
  num? reviewCount = 8420,
  String openStatus = 'open',
  String? closingTime,
}) =>
    {
      'id': id,
      'name': name,
      'category': category,
      'description': 'A large green space.',
      'address_text': 'Sampangi Rama Nagar',
      'latitude': lat,
      'longitude': lng,
      'status': 'published',
      'place_seed_stats': [
        {
          'rating': rating,
          'review_count': reviewCount,
          'open_status': openStatus,
          'closing_time': closingTime,
        }
      ],
    };

void main() {
  group('PlacesRepository.fetchInBounds', () {
    test('maps rows onto Place, including the joined stats', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode([placeRow()]),
            200,
            headers: {'content-type': 'application/json'},
          ));
      final repo = PlacesRepository(_testApi(client));

      final places = await repo.fetchInBounds(const LatLng(12.9716, 77.5946), 13);

      expect(places, hasLength(1));
      final p = places.single;
      expect(p.name, 'Cubbon Park');
      expect(p.category, PlaceCategory.attraction);
      expect(p.latitude, closeTo(12.9763, 1e-9));
      expect(p.longitude, closeTo(77.5929, 1e-9));
      expect(p.rating, closeTo(4.6, 1e-9));
      expect(p.reviewCount, 8420);
      expect(p.openStatus, OpenStatus.open);
    });

    test('skips a malformed row instead of discarding the viewport', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode([
              {'id': 'bad', 'name': 'No coordinates'}, // missing lat/lng
              placeRow(id: 'p2', name: 'Good Park'),
            ]),
            200,
            headers: {'content-type': 'application/json'},
          ));
      final repo = PlacesRepository(_testApi(client));

      final places = await repo.fetchInBounds(const LatLng(12.9716, 77.5946), 13);

      // One bad row must not cost us the good one.
      expect(places, hasLength(1));
      expect(places.single.name, 'Good Park');
    });

    test('an unknown category falls back rather than throwing', () async {
      // A category added server-side must not break an older client.
      final client = MockClient((_) async => http.Response(
            jsonEncode([placeRow(category: 'nightmarket')]),
            200,
            headers: {'content-type': 'application/json'},
          ));
      final repo = PlacesRepository(_testApi(client));

      final places = await repo.fetchInBounds(const LatLng(12.9716, 77.5946), 13);
      expect(places.single.category, isA<PlaceCategory>());
    });

    test('a place with no stats still parses, with zero rating', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode([
              {
                'id': 'x',
                'name': 'No Stats',
                'category': 'coffee',
                'latitude': 1.0,
                'longitude': 2.0,
                'place_seed_stats': <dynamic>[],
              }
            ]),
            200,
            headers: {'content-type': 'application/json'},
          ));
      final repo = PlacesRepository(_testApi(client));

      final places = await repo.fetchInBounds(const LatLng(1, 2), 13);
      expect(places.single.rating, 0);
      expect(places.single.reviewCount, 0);
    });

    test('builds a PostgREST URL without a duplicated /v1', () async {
      // Regression guard: the client built '/rest/v1' + '/v1' + path, so every
      // request went to /rest/v1/v1/places and 404'd. That surfaced as
      // "cannot reach the backend" and the app silently served sample data.
      Uri? seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'});
      });
      final repo = PlacesRepository(_testApi(client));

      await repo.fetchInBounds(const LatLng(12.9716, 77.5946), 13);

      expect(seen!.path, '/rest/v1/places');
      expect(seen!.path.contains('/v1/v1'), isFalse);
      expect(seen!.host, 'project.test');
    });

    test('sends a viewport query scoped to published places', () async {
      Uri? seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'});
      });
      final repo = PlacesRepository(_testApi(client));

      await repo.fetchInBounds(const LatLng(12.9716, 77.5946), 13);

      expect(seen, isNotNull);
      // The composite (latitude, longitude) index exists for exactly this.
      // Ranges are repeated keys, ANDed by PostgREST -- not a flat `or=(...)`,
      // which would be a union of the four edges rather than a rectangle.
      final q = seen!.queryParametersAll;
      expect(q['latitude'], hasLength(2));
      expect(q['latitude']!.first, startsWith('gte.'));
      expect(q['latitude']!.last, startsWith('lte.'));
      expect(q['longitude']!, hasLength(2));
      expect(q['status'], ['eq.published']);
      expect(seen!.query, isNot(contains('or=')));
    });

    test('a server error surfaces as a rejected ApiException', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode({'code': '42501', 'message': 'permission denied'}),
            403,
          ));
      final repo = PlacesRepository(_testApi(client));

      expect(
        () => repo.fetchInBounds(const LatLng(12.9716, 77.5946), 13),
        throwsA(isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.unauthorised)),
      );
    });
  });

  group('ApiClient configuration', () {
    test('a client with no base URL refuses to send, and says why', () async {
      // A build without .env must fail with a clear reason rather than a
      // confusing DNS error later on.
      final client = MockClient((_) async => http.Response('[]', 200));
      final api = ApiClient(client: client, baseUrl: '', anonKey: '');

      expect(api.isConfigured, isFalse);
      expect(
        () => api.get('/places'),
        throwsA(isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.notConfigured)
            .having((e) => e.message, 'message', contains('SUPABASE_URL'))),
      );
    });

    test('a configured client reports itself as configured', () {
      final client = MockClient((_) async => http.Response('[]', 200));
      expect(_testApi(client).isConfigured, isTrue);
    });

    test('a transport failure is reported as a network problem', () async {
      // A thrown exception from the client stands in for a dropped connection.
      final client = MockClient((_) async => throw const SocketFailure());
      final repo = PlacesRepository(_testApi(client));

      expect(
        () => repo.fetchInBounds(const LatLng(12.9716, 77.5946), 13),
        throwsA(isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.network)),
      );
    });
  });
}

/// Stands in for a socket-level failure, so the network path can be tested
/// without actually unplugging anything.
class SocketFailure implements Exception {
  const SocketFailure();
}

/// An [ApiClient] pointed at a fake host, so the parsing and error paths are
/// actually reached instead of short-circuiting on missing build config.
ApiClient _testApi(http.Client inner) => ApiClient(
      client: inner,
      baseUrl: 'https://project.test',
      anonKey: 'test-anon-key',
    );
