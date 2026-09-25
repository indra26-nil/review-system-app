import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// The kinds of place this app surfaces.
///
/// Each carries its own icon and accent so markers stay distinguishable at a
/// glance, which is what makes the map scannable without reading labels.
enum PlaceCategory {
  restaurant('Restaurants', Icons.restaurant_rounded, Color(0xFFE8734A)),
  hotel('Hotels', Icons.hotel_rounded, Color(0xFF7C6BD4)),
  coffee('Coffee', Icons.local_cafe_rounded, Color(0xFF9A6B4F)),
  museum('Museums', Icons.museum_rounded, Color(0xFF4A7FC1)),
  attraction('Attractions', Icons.landscape_rounded, Color(0xFF3FA37A)),
  shopping('Shopping', Icons.shopping_bag_rounded, Color(0xFFD4568C)),
  transit('Transit', Icons.directions_transit_rounded, Color(0xFF2F7CF6)),
  park('Parks', Icons.park_rounded, Color(0xFF5B9E4F));

  const PlaceCategory(this.label, this.icon, this.tint);

  final String label;
  final IconData icon;

  /// Marker fill. Kept low-saturation so the map does not turn into confetti.
  final Color tint;
}

/// How a place is trading right now.
enum OpenStatus {
  open('Open now'),
  closingSoon('Closing soon'),
  closed('Closed');

  const OpenStatus(this.label);

  /// Short human label, e.g. "Closing soon".
  final String label;
}

/// A discoverable place.
///
/// Coordinates are stored as plain [latitude]/[longitude] and converted to a
/// [LatLng] on demand — the same convention the geocoding layer uses, so a
/// place coming from search and a place coming from the database look
/// identical to the rest of the app.
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.category,
    required this.latitude,
    required this.longitude,
    this.rating = 0,
    this.reviewCount = 0,
    this.openStatus = OpenStatus.open,
    this.closingTime,
    this.description = '',
    this.address = '',
    this.photoUrls = const [],
  });

  final String id;
  final String name;
  final PlaceCategory category;
  final double latitude;
  final double longitude;

  /// Average rating out of 5, or 0 when unrated.
  final double rating;
  final int reviewCount;

  final OpenStatus openStatus;

  /// e.g. "22:00" — muted, shown next to the open/closed state.
  final String? closingTime;

  final String description;
  final String address;

  /// Optional photography. When empty the UI draws a generated placeholder so
  /// the card is never a broken-image box.
  final List<String> photoUrls;

  LatLng get point => LatLng(latitude, longitude);

  bool get isRated => rating > 0;

  String get openLabel => switch (openStatus) {
        OpenStatus.open => 'Open now',
        OpenStatus.closingSoon => 'Closing soon',
        OpenStatus.closed => 'Closed',
      };

  Color get openColor => switch (openStatus) {
        OpenStatus.open => const Color(0xFF16A34A),
        OpenStatus.closingSoon => const Color(0xFFD97706),
        OpenStatus.closed => const Color(0xFF6B6B6B),
      };

  /// Rating with one decimal, or an em dash when unrated.
  String get ratingLabel => isRated ? rating.toStringAsFixed(1) : '—';

  /// "5,089 ratings" / "1 rating" / "No ratings yet".
  String get reviewCountLabel {
    if (reviewCount == 0) return 'No ratings yet';
    final s = reviewCount.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return '$buf ${reviewCount == 1 ? 'rating' : 'ratings'}';
  }

  /// Copy with an adjusted [rating] and review count, used when a review lands.
  Place withRating({required double rating, required int reviewCount}) =>
      Place(
        id: id,
        name: name,
        category: category,
        latitude: latitude,
        longitude: longitude,
        rating: rating,
        reviewCount: reviewCount,
        openStatus: openStatus,
        closingTime: closingTime,
        description: description,
        address: address,
        photoUrls: photoUrls,
      );

  /// Straight-line distance from [from], in kilometres, via the haversine
  /// formula. Accurate enough at city scale and needs no extra dependency.
  double distanceKmFrom(LatLng from) {
    const earthKm = 6371.0;
    double rad(double d) => d * math.pi / 180.0;
    final dLat = rad(latitude - from.latitude);
    final dLon = rad(longitude - from.longitude);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(from.latitude)) *
            math.cos(rad(latitude)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthKm * 2 * math.asin(math.min(1.0, math.sqrt(a)));
  }

  /// "450 m" below a kilometre, otherwise "1.2 km".
  String distanceLabelFrom(LatLng from) {
    final m = distanceKmFrom(from) * 1000;
    if (m < 950) return '${m.round()} m';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }
}
