import 'dart:async';

import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import 'api_client.dart';

/// Where a set of places came from, so the map can tell the truth about it.
enum PlacesSource { network, fallback }

class PlacesResult {
  const PlacesResult(this.places, this.source, {this.message});

  final List<Place> places;
  final PlacesSource source;

  /// Why the fallback was used, when it was.
  final String? message;
}

/// Reads places from Supabase, falling back to the bundled sample data.
///
/// The fallback is not a placeholder for an unimplemented feature: this device
/// loses the network regularly, and a map that empties itself every time DNS
/// hiccups is worse than one that admits it is showing sample data.
class PlacesRepository {
  PlacesRepository(this._api);

  final ApiClient _api;

  /// Places inside a map viewport, ordered nearest-first from its centre.
  ///
  /// The bounds query is what the `(latitude, longitude)` index exists for: the
  /// database reads only the rows inside the rectangle the user is looking at,
  /// rather than scanning the table.
  Future<List<Place>> fetchInBounds(LatLng centre, double zoom) async {
    // Half the world at zoom 0, tightening as the user zooms in. Generous
    // enough to fill the viewport, small enough to stay a selective query.
    final span = 360.0 / (1 << zoom.clamp(0, 18).round());
    final minLat = (centre.latitude - span).clamp(-90.0, 90.0);
    final maxLat = (centre.latitude + span).clamp(-90.0, 90.0);
    // Longitude is not clamped, so the query crosses the antimeridian naturally
    // as a min > max range, which Postgres handles correctly.
    final minLng = centre.longitude - span;
    final maxLng = centre.longitude + span;

    final res = await _api.get('/places', query: {
      'select': 'id,name,category,description,address_text,latitude,longitude,'
          'status,place_seed_stats(rating,review_count,open_status,closing_time)',
      'status': 'eq.published',
      // A bounding box is two ranges per axis, expressed as repeated query
      // keys. PostgREST ANDs them, which is what "inside this rectangle" means.
      //
      // A flat `or=(...)` would be wrong: `or` means a or b or c, so every row
      // matching any single edge would come back.
      'latitude': ['gte.$minLat', 'lte.$maxLat'],
      'longitude': ['gte.$minLng', 'lte.$maxLng'],
      'order': 'name.asc',
    });

    if (res is! List) return const [];
    return res
        .whereType<Map<String, dynamic>>()
        .map(_fromRow)
        .whereType<Place>()
        .toList();
  }

  /// Every published place, regardless of where it is.
  ///
  /// The viewport query is the right one for the map, but it hides anything
  /// outside a few kilometres. Listings made elsewhere -- in another city, or
  /// from the simulator -- are then invisible with no way to reach them, which
  /// looks like the data is missing when it is simply off screen.
  Future<List<Place>> fetchAll({int limit = 200}) async {
    final res = await _api.get('/places', query: {
      'select': 'id,name,category,description,address_text,latitude,longitude,'
          'status,place_seed_stats(rating,review_count,open_status,closing_time)',
      'status': 'eq.published',
      'order': 'name.asc',
      'limit': '$limit',
    });

    if (res is! List) return const [];
    return res
        .whereType<Map<String, dynamic>>()
        .map(_fromRow)
        .whereType<Place>()
        .toList();
  }

  /// Maps a database row onto the app's [Place] model.
  ///
  /// Returns null for a row that cannot be understood, so one bad record
  /// cannot discard an entire viewport.
  static Place? _fromRow(Map<String, dynamic> row) {
    final lat = row['latitude'];
    final lng = row['longitude'];
    if (lat is! num || lng is! num) return null;

    // The seed aggregate arrives as a single-element list because
    // place_seed_stats is a one-to-one join from places.
    final stats = row['place_seed_stats'];
    final stat = (stats is List && stats.isNotEmpty)
        ? stats.first
        : const <String, dynamic>{};

    return Place(
      id: '${row['id'] ?? ''}',
      name: '${row['name'] ?? ''}',
      category: _categoryFrom('${row['category'] ?? ''}'),
      latitude: lat.toDouble(),
      longitude: lng.toDouble(),
      rating: (stat['rating'] as num?)?.toDouble() ?? 0,
      reviewCount: (stat['review_count'] as num?)?.toInt() ?? 0,
      openStatus: switch ('${stat['open_status'] ?? ''}') {
        'closingSoon' => OpenStatus.closingSoon,
        'closed' => OpenStatus.closed,
        _ => OpenStatus.open,
      },
      closingTime: stat['closing_time']?.toString(),
      description: '${row['description'] ?? ''}',
      address: '${row['address_text'] ?? ''}',
    );
  }

  /// Maps the database's category string onto the enum.
  ///
  /// Unknown categories fall back to a neutral one rather than throwing: a new
  /// category added server-side should not break an older client.
  static PlaceCategory _categoryFrom(String value) {
    for (final c in PlaceCategory.values) {
      if (c.name == value) return c;
    }
    return PlaceCategory.attraction;
  }
}
