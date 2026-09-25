import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// A compass that reflects the map's rotation and snaps back to north on tap.
///
/// Shown only while the map is actually rotated: a compass pinned at "N" on a
/// north-up map is noise, and the screen already has enough floating controls.
/// The needle stays fixed to north while the *ring* turns, so the heading is
/// readable at a glance.
class CompassButton extends StatelessWidget {
  const CompassButton({super.key, required this.rotationDegrees, this.onTap});

  /// Map rotation in degrees. flutter_map treats positive as counter-clockwise,
  /// so it is negated here to match a physical compass.
  final double rotationDegrees;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = rotationDegrees.abs() > 0.5;
    return Tooltip(
      message: active ? 'Reset to north' : 'North',
      child: Material(
        color: AppTokens.background,
        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
        elevation: 0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTokens.radiusButton),
          child: SizedBox(
            width: AppTokens.controlSize,
            height: AppTokens.controlSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Rotating ring with the cardinal letters.
                AnimatedRotation(
                  turns: -rotationDegrees / 360.0,
                  duration: const Duration(milliseconds: 120),
                  child: CustomPaint(
                    size: const Size.square(AppTokens.controlSize - 14),
                    painter: _CompassRingPainter(),
                  ),
                ),
                // Fixed north needle, so the heading is unambiguous.
                Transform.rotate(
                  angle: 0,
                  child: Icon(
                    Icons.navigation_rounded,
                    size: 15,
                    color: active ? AppTokens.accent : AppTokens.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompassRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.5;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = const Color(0x1F000000);
    canvas.drawCircle(center, radius, ring);

    // Red half marks north; the opposite half stays neutral.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 0.7),
      -math.pi / 2,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = AppTokens.danger.withValues(alpha: 0.75),
    );
  }

  @override
  bool shouldRepaint(covariant _CompassRingPainter oldDelegate) => false;
}

/// Compact N/E/S/W label used on the picked-location sheet.
/// Maps a map rotation to a compass point.
///
/// [rotationDegrees] is the map's rotation; a negative bearing is folded back
/// into 0-360 so 359 degrees reads as north rather than out of range.
String cardinalFor(double rotationDegrees) {
  final deg = (-rotationDegrees) % 360;
  const names = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final index = ((deg + 22.5) / 45).floor() % 8;
  return names[index];
}

class CompassLabel extends StatelessWidget {
  const CompassLabel({super.key, required this.rotationDegrees});

  final double rotationDegrees;

  String get _cardinal => cardinalFor(rotationDegrees);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.rotate(
          angle: rotationDegrees * math.pi / 180.0,
          child: const Icon(
            Icons.navigation_rounded,
            size: 14,
            color: AppTokens.textMuted,
          ),
        ),
        const SizedBox(width: 5),
        Text(_cardinal, style: AppTokens.metadata),
      ],
    );
  }
}
