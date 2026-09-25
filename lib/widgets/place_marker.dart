import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/place.dart';
import '../theme/app_tokens.dart';

/// A map marker for a single place.
///
/// Markers are rounded squares with a category glyph rather than classic map
/// pins: at city zoom they read as a set of tidy objects, and the silhouette
/// stays consistent across categories. The selected marker is larger, uses the
/// category's full tint, and gains [AppTokens.markerShadow] so it visibly floats
/// above its neighbours.
class PlaceMarker extends StatelessWidget {
  const PlaceMarker({
    super.key,
    required this.category,
    this.isSelected = false,
    this.size = 38,
    this.onTap,
  });

  final PlaceCategory category;
  final bool isSelected;

  /// Edge length of the rounded square at rest.
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final side = isSelected ? size * 1.18 : size;
    final iconSize = side * 0.5;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: side,
        height: side,
        decoration: BoxDecoration(
          // White is the resting fill so markers stay light on busy tiles; the
          // selected one takes the category tint for a clear highlight.
          color: isSelected ? category.tint : AppTokens.background,
          borderRadius: BorderRadius.circular(side * 0.32),
          border: Border.all(
            color: isSelected
                ? AppTokens.background
                : category.tint.withValues(alpha: 0.28),
            width: isSelected ? 2.5 : 1.2,
          ),
          boxShadow: isSelected
              ? AppTokens.markerShadow
              : AppTokens.controlShadow,
        ),
        child: Icon(
          category.icon,
          size: iconSize,
          color: isSelected ? Colors.white : category.tint,
        ),
      ),
    );
  }
}

/// An aggregate marker standing in for several nearby places.
///
/// The count is the whole message, so the badge stays small and the label is
/// the loudest part of it.
class ClusterMarker extends StatelessWidget {
  const ClusterMarker({
    super.key,
    required this.count,
    required this.point,
    required this.zoom,
    this.onTap,
  });

  final int count;
  final double point;
  final double zoom;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Grow gently with the count, and shrink as the user zooms in so the map
    // does not fill with equally loud badges.
    final zoomT = ((zoom - 8) / 8).clamp(0.0, 1.0);
    final base = 34.0 + math.min(count, 100) / 100 * 8.0;
    final side = base * (0.82 + 0.18 * zoomT);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: side,
        height: side,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTokens.accent.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Container(
          width: side * 0.72,
          height: side * 0.72,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppTokens.accent,
            shape: BoxShape.circle,
            border: Border.all(color: AppTokens.background, width: 2),
            boxShadow: AppTokens.controlShadow,
          ),
          child: Text(
            count > 99 ? '99+' : '$count',
            style: TextStyle(
              color: Colors.white,
              fontSize: side * 0.28,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// A hand-picked map point, shown as a crosshair.
///
/// Deliberately a different *shape* from [PlaceMarker] and [DestinationPin]: a
/// circle-with-cross reads as "an arbitrary coordinate you dropped", where a
/// rounded square reads as a place and a teardrop reads as a destination.
class PickedPointPin extends StatelessWidget {
  const PickedPointPin({super.key, this.selected = true});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final accent = AppTokens.accent;
    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: selected ? 30 : 26,
          height: selected ? 30 : 26,
          decoration: BoxDecoration(
            color: AppTokens.background,
            shape: BoxShape.circle,
            border: Border.all(color: accent, width: 2.5),
            boxShadow: AppTokens.markerShadow,
          ),
          child: Center(
            child: Icon(
              Icons.add_rounded,
              size: selected ? 18 : 16,
              color: accent,
            ),
          ),
        ),
      ),
    );
  }
}

/// The blue "you are here" dot with its accuracy halo.
///
/// The halo is a separate widget so the map can draw it *under* the marker
/// layer; otherwise it would cover neighbouring markers.
class MyLocationDot extends StatelessWidget {
  const MyLocationDot({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTokens.accent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: AppTokens.markerShadow,
      ),
    );
  }
}

/// A large pin used for a route destination: the one thing on the map that
/// should read as unambiguous.
class DestinationPin extends StatelessWidget {
  const DestinationPin({super.key, this.selected = false});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      duration: const Duration(milliseconds: 180),
      scale: selected ? 1.12 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: AppTokens.danger,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(4),
          ),
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: AppTokens.markerShadow,
        ),
        padding: const EdgeInsets.all(7),
        child: const Icon(Icons.place_rounded, color: Colors.white, size: 16),
      ),
    );
  }
}
