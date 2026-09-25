// Parsing tests for Photon search results.
//
// The thing most likely to break here is coordinate order: Photon returns
// GeoJSON, which is [longitude, latitude], while Dart's LatLng is the reverse.
// Reading them the naive way puts the map in the wrong hemisphere, so these
// tests pin the ordering down explicitly.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:revamp/models/search_result.dart';

void main() {
  group('SearchResult.fromPhoton', () {
    // A real (trimmed) response for "kolkata", fetched from photon.komoot.io.
    const cityFeature = {
      'type': 'Feature',
      'properties': {
        'osm_type': 'R',
        'osm_id': 9381363,
        'osm_key': 'place',
        'osm_value': 'city',
        'type': 'city',
        'name': 'Kolkata',
        'state': 'West Bengal',
        'country': 'India',
        'countrycode': 'IN',
      },
      'geometry': {
        'type': 'Point',
        // GeoJSON order: longitude first.
        'coordinates': [88.3638953, 22.5726459],
      },
    };

    test('reads coordinates as latitude/longitude, not the reverse', () {
      final result = SearchResult.fromPhoton(cityFeature);

      expect(result.latitude, closeTo(22.5726459, 1e-7));
      expect(result.longitude, closeTo(88.3638953, 1e-7));
    });

    test('builds a comma-separated label, most specific first', () {
      final result = SearchResult.fromPhoton(cityFeature);

      expect(result.displayName, 'Kolkata, West Bengal, India');
      expect(result.title, 'Kolkata');
      expect(result.subtitle, 'West Bengal, India');
    });

    test('exposes osm_value as the category for icon selection', () {
      expect(SearchResult.fromPhoton(cityFeature).category, 'city');
    });

    test('de-duplicates repeated context such as city == county', () {
      const feature = {
        'type': 'Feature',
        'properties': {
          'name': 'Kolkata',
          'city': 'Kolkata',
          'county': 'Kolkata',
          'state': 'West Bengal',
          'country': 'India',
        },
        'geometry': {
          'type': 'Point',
          'coordinates': [88.36, 22.57],
        },
      };

      expect(
        SearchResult.fromPhoton(feature).displayName,
        'Kolkata, West Bengal, India',
      );
    });

    test('prefixes a house number to its street', () {
      const feature = {
        'type': 'Feature',
        'properties': {
          'name': 'RevMap',
          'housenumber': '12',
          'street': 'MG Road',
          'city': 'Bengaluru',
          'country': 'India',
        },
        'geometry': {
          'type': 'Point',
          'coordinates': [77.60, 12.97],
        },
      };

      expect(
        SearchResult.fromPhoton(feature).displayName,
        '12 MG Road, Bengaluru, India',
      );
    });

    test('falls back to coordinates when no name is returned', () {
      const feature = {
        'type': 'Feature',
        'properties': {'osm_value': 'building'},
        'geometry': {
          'type': 'Point',
          'coordinates': [77.60, 12.97],
        },
      };

      final result = SearchResult.fromPhoton(feature);
      // Separator is not a comma, so the whole thing stays in the title instead
      // of the row reading "12.97" with "77.6" as its subtitle.
      expect(result.title, '12.97 · 77.6');
      expect(result.subtitle, isEmpty);
    });

    test('rejects a feature with no usable coordinates', () {
      const feature = {
        'type': 'Feature',
        'properties': {'name': 'Nowhere'},
        'geometry': {'type': 'Point', 'coordinates': <dynamic>[]},
      };

      expect(
        () => SearchResult.fromPhoton(feature),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('parses a whole Photon FeatureCollection body', () {
    const body = '''
    {"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"name":"Kolkata","osm_value":"city"},
       "geometry":{"type":"Point","coordinates":[88.3638953,22.5726459]}},
      {"type":"Feature","properties":{"name":"Kolkata Junction","osm_value":"railway"},
       "geometry":{"type":"Point","coordinates":[88.4467,22.5546]}}
    ]}''';

    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final results = (decoded['features'] as List)
        .cast<Map<String, dynamic>>()
        .map(SearchResult.fromPhoton)
        .toList();

    expect(results, hasLength(2));
    expect(results.first.title, 'Kolkata');
    expect(results.first.latitude, closeTo(22.5726459, 1e-7));
    expect(results.last.category, 'railway');
  });
}
