import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/place.dart';
import '../theme/app_tokens.dart';

/// Photography for a place, with a graceful fallback.
///
/// Remote photos are used when a [urls] list is supplied, but the fallback is a
/// deliberately designed generated panel rather than a grey box: a muted
/// gradient keyed to the category with a large translucent glyph. It keeps the
/// card's visual rhythm intact when a photo is slow, missing, or not yet
/// supplied by the backend.
class PlaceImage extends StatelessWidget {
  const PlaceImage({
    super.key,
    required this.place,
    this.url,
    this.height,
    this.width,
    this.borderRadius,
    this.iconScale = 0.34,
  });

  final Place place;
  final String? url;
  final double? height;
  final double? width;
  final double? borderRadius;

  /// Size of the fallback glyph relative to the panel's short edge.
  final double iconScale;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius ?? AppTokens.radiusImage);
    final child = (url == null || url!.isEmpty)
        ? _GeneratedImage(place: place, iconScale: iconScale)
        : Image.network(
            url!,
            height: height,
            width: width,
            fit: BoxFit.cover,
            // Fade rather than pop, so a slow photo does not flash a hard edge.
            frameBuilder: (context, child, frame, wasSyncLoaded) {
              if (wasSyncLoaded || frame != null) {
                return AnimatedOpacity(
                  opacity: 1,
                  duration: const Duration(milliseconds: 220),
                  child: child,
                );
              }
              return _GeneratedImage(place: place, iconScale: iconScale);
            },
            errorBuilder: (context, _, _) =>
                _GeneratedImage(place: place, iconScale: iconScale),
          );

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(height: height, width: width, child: child),
    );
  }
}

class _GeneratedImage extends StatelessWidget {
  const _GeneratedImage({required this.place, required this.iconScale});

  final Place place;
  final double iconScale;

  @override
  Widget build(BuildContext context) {
    // Seed the gradient off the id so a place always looks the same, but two
    // places never look identical.
    final seed = place.id.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x7fffffff);
    final rand = math.Random(seed);
    final tint = place.category.tint;
    final angle = (rand.nextDouble() * 2 - 1) * 0.35;
    final light = Color.lerp(tint.withValues(alpha: 0.10), Colors.white, 0.55)!;
    final deep = Color.lerp(tint.withValues(alpha: 0.30), Colors.white, 0.15)!;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-1, -1 + angle),
          end: Alignment(1, 1 - angle),
          colors: [light, deep],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final short = math.min(constraints.maxWidth, constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : constraints.maxWidth);
          return Stack(
            fit: StackFit.expand,
            children: [
              // A couple of soft circles give the panel depth without noise.
              Positioned(
                right: -short * 0.18,
                top: -short * 0.22,
                child: Container(
                  width: short * 0.7,
                  height: short * 0.7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                ),
              ),
              Positioned(
                left: -short * 0.14,
                bottom: -short * 0.24,
                child: Container(
                  width: short * 0.5,
                  height: short * 0.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tint.withValues(alpha: 0.10),
                  ),
                ),
              ),
              Center(
                child: Icon(
                  place.category.icon,
                  size: short * iconScale,
                  color: Colors.white.withValues(alpha: 0.72),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A horizontal strip of small image cards.
///
/// Full-bleed rounded thumbnails, no borders — a gallery strip rather than a
/// row of boxed icons.
class PlaceImageStrip extends StatelessWidget {
  const PlaceImageStrip({
    super.key,
    required this.place,
    this.height = 86,
    this.spacing = AppTokens.s8,
  });

  final Place place;
  final double height;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    // A place with no photography still gets a strip, so the card does not
    // change height depending on data completeness.
    final urls = place.photoUrls;

    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: math.max(3, urls.length),
        separatorBuilder: (_, _) => SizedBox(width: spacing),
        itemBuilder: (context, i) {
          return SizedBox(
            width: height * 1.28,
            child: PlaceImage(place: place, url: i < urls.length ? urls[i] : null),
          );
        },
      ),
    );
  }
}
