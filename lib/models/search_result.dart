import 'package:latlong2/latlong.dart';

/// A single place returned by a geocoding search.
class SearchResult {
  const SearchResult({
    required this.id,
    required this.displayName,
    required this.latitude,
    required this.longitude,
    this.category,
  });

  /// Stable identifier, used to key widgets so the list does not jump around.
  final String id;

  /// Human-readable address, ordered most-specific first, e.g.
  /// "Kolkata, West Bengal, India".
  final String displayName;

  final double latitude;
  final double longitude;

  /// Coarse feature type (`city`, `street`, `house`, ...), used to pick an icon.
  final String? category;

  LatLng get point => LatLng(latitude, longitude);

  /// The most specific part of [displayName], shown as the row title.
  String get title {
    final parts = _parts;
    if (parts.isEmpty) return displayName;
    return parts.first;
  }

  /// Everything after [title], shown as the row subtitle.
  String get subtitle => _parts.length < 2 ? '' : _parts.skip(1).join(', ');

  List<String> get _parts =>
      displayName.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();

  /// Builds a result from one Photon GeoJSON feature.
  ///
  /// Photon returns GeoJSON, whose coordinates are **[longitude, latitude]** —
  /// the reverse of Dart's `LatLng`. Reading them in the wrong order puts the
  /// map in the ocean off the coast of Africa, so this is easy to get wrong.
  factory SearchResult.fromPhoton(Map<String, dynamic> feature) {
    final geometry = feature['geometry'];
    final coordinates = geometry is Map<String, dynamic>
        ? geometry['coordinates']
        : null;
    if (coordinates is! List || coordinates.length < 2) {
      throw const FormatException('Photon feature had no usable coordinates');
    }

    // GeoJSON order: [lon, lat]
    final lon = (coordinates[0] as num?)?.toDouble();
    final lat = (coordinates[1] as num?)?.toDouble();
    if (lat == null || lon == null) {
      throw const FormatException('Photon feature had non-numeric coordinates');
    }

    final props = feature['properties'];
    final p = props is Map<String, dynamic> ? props : const <String, dynamic>{};

    // Most specific first: a house number or street, then the enclosing places.
    final houseNumber = p['housenumber']?.toString();
    final street = p['street']?.toString();
    final name = (p['name'] ?? '').toString();

    final head = [
      if (houseNumber != null && houseNumber.isNotEmpty && street != null && street.isNotEmpty)
        '$houseNumber $street'
      else if (street != null && street.isNotEmpty && name.isEmpty) street
      else name,
    ].join('').trim();

    // Typed String? because the values come from dynamic JSON and any of them
    // may be absent, which is normal for a partially-mapped place.
    final context = <String?>[
      p['district'],
      p['city'],
      p['county'],
      p['state'],
      p['country'],
    ].map((v) => v?.toString() ?? '').where((s) => s.isNotEmpty).toSet().toList();

    // A place is often its own city *and* county ("Kolkata" for both), which
    // would otherwise render as "Kolkata, Kolkata, West Bengal, India".
    // De-duplicate while preserving the most-specific-first order.
    final parts = <String>[];
    for (final part in <String>[if (head.isNotEmpty) head, ...context]) {
      if (part.isNotEmpty && !parts.contains(part)) parts.add(part);
    }

    final osmId = p['osm_id'] ?? p['osm_key'] ?? 'feature';

    return SearchResult(
      id: '$osmId',
      // No name came back, so fall back to the coordinates. The separator is
      // deliberately not a comma: displayName is split on commas to derive the
      // row title, and "22.57, 88.36" would then render as a title of "22.57".
      displayName: parts.isEmpty ? '$lat · $lon' : parts.join(', '),
      latitude: lat,
      longitude: lon,
      category: (p['osm_value'] ?? p['type'])?.toString(),
    );
  }
}
