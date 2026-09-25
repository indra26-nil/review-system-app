import 'package:flutter/material.dart';

/// The RevMap design system.
///
/// Everything visual in the app resolves through these tokens so the map
/// screen, the bottom sheets and the transport views stay consistent, and so a
/// single edit here re-skins the whole app.
///
/// The guiding rule is **restraint**: the interface should feel premium because
/// of whitespace, typography, rounded cards and map geometry — not because of
/// saturated colour or heavy shadow. The map is the dominant element and the
/// cards float above it.
class AppTokens {
  AppTokens._();

  // ---------------------------------------------------------------- surfaces

  /// Page background behind the map.
  static const Color background = Color(0xFFFFFFFF);

  /// Slightly recessed fill: sheet backgrounds, inactive chips, skeletons.
  static const Color surfaceMuted = Color(0xFFF7F7F5);

  /// A hairline used for separators. Deliberately near-invisible.
  static const Color hairline = Color(0x14000000);

  // ------------------------------------------------------------------- text

  static const Color textPrimary = Color(0xFF171717);
  static const Color textSecondary = Color(0xFF6B6B6B);
  static const Color textMuted = Color(0xFF969696);

  // ----------------------------------------------------------------- accent

  /// The single accent. Restrained blue — present, never neon.
  static const Color accent = Color(0xFF2F7CF6);

  /// Accent at ~10% for selected pill fills and soft icon backgrounds.
  static const Color accentSoft = Color(0x1A2F7CF6);

  /// Accent at ~20% for borders on selected controls.
  static const Color accentBorder = Color(0x332F7CF6);

  // -------------------------------------------------------------- semantics

  /// "Open now", positive states.
  static const Color success = Color(0xFF16A34A);
  static const Color successSoft = Color(0xFFE8F6EE);

  /// Closing-soon, "Fastest" badge.
  static const Color warning = Color(0xFFD97706);
  static const Color warningSoft = Color(0xFFFDF3E4);

  /// Closed states, destructive actions.
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerSoft = Color(0xFFFDECEC);

  /// Rating stars.
  static const Color ratingStar = Color(0xFFFFB800);

  // -------------------------------------------------------------- map canvas

  /// Shown while tiles load, and beneath them at the edges.
  static const Color mapLand = Color(0xFFF3F3F0);
  static const Color mapWater = Color(0xFFBFE4F5);
  static const Color mapRoadMinor = Color(0xFFFFFFFF);
  static const Color mapRoadMajor = Color(0xFFE5E5E5);

  // ----------------------------------------------------------------- radius

  /// Floating cards and the place card.
  static const double radiusCard = 26;

  /// Bottom sheets, on their top corners.
  static const double radiusSheet = 30;

  /// Buttons and icon controls.
  static const double radiusButton = 18;

  /// Inline image thumbnails.
  static const double radiusImage = 20;

  /// Pills: category chips, badges, line numbers.
  static const double radiusPill = 999;

  // ------------------------------------------------------- control sizing

  /// Sized for comfortable thumb reach, not for a desktop browser.
  static const double controlSize = 50;
  static const double searchBarHeight = 58;
  static const double categoryPillHeight = 46;
  static const double markerSize = 44;
  static const double touchTarget = 44;

  // ---------------------------------------------------------------- spacing

  static const double s2 = 2;
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;

  /// Standard horizontal gutter for edge-to-edge content.
  static const double gutter = 16;

  // ---------------------------------------------------------------- shadows

  /// The one shadow used across the app. Anything heavier competes with the
  /// map and makes the interface feel heavy rather than floating.
  static List<BoxShadow> get floatShadow => const [
        BoxShadow(
          color: Color(0x14000000), // rgba(0,0,0,0.08)
          blurRadius: 20,
          offset: Offset(0, 4),
        ),
      ];

  /// A slightly tighter variant for small controls that sit on the map.
  static List<BoxShadow> get controlShadow => const [
        BoxShadow(
          color: Color(0x0F000000),
          blurRadius: 10,
          offset: Offset(0, 2),
        ),
      ];

  /// Reserved for the elevated/selected marker only.
  static List<BoxShadow> get markerShadow => const [
        BoxShadow(
          color: Color(0x1F000000),
          blurRadius: 12,
          offset: Offset(0, 4),
        ),
      ];

  // ------------------------------------------------------------- typography

  /// Place names on the card and at the top of a sheet.
  static const TextStyle titleLg = TextStyle(
    fontSize: 24,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: textPrimary,
    letterSpacing: -0.4,
  );

  /// Section headers inside sheets.
  static const TextStyle titleMd = TextStyle(
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    letterSpacing: -0.3,
  );

  /// Row titles, list item names.
  static const TextStyle titleSm = TextStyle(
    fontSize: 16.5,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontSize: 15.5,
    height: 1.4,
    color: textPrimary,
  );

  static const TextStyle bodySecondary = TextStyle(
    fontSize: 15,
    height: 1.4,
    color: textSecondary,
  );

  /// Subtitles, supporting lines.
  static const TextStyle caption = TextStyle(
    fontSize: 13.5,
    height: 1.35,
    color: textSecondary,
  );

  /// Ratings counts, distances, timestamps.
  static const TextStyle metadata = TextStyle(
    fontSize: 12.5,
    height: 1.3,
    color: textMuted,
  );

  /// All-caps micro labels such as the FASTEST badge.
  static const TextStyle overline = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: textSecondary,
    letterSpacing: 0.6,
  );

  // ------------------------------------------------------------- components

  /// The floating search container at the top of the map.
  static BoxDecoration get searchDecoration => BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radiusPill),
        boxShadow: floatShadow,
      );

  /// A floating sheet or card surface.
  static BoxDecoration sheetDecoration({double topRadius = radiusSheet}) =>
      BoxDecoration(
        color: background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(topRadius)),
        boxShadow: floatShadow,
      );

  /// The small grabber at the top of a draggable sheet.
  static Widget get grabber => Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        decoration: BoxDecoration(
          color: const Color(0x1F000000),
          borderRadius: BorderRadius.circular(2),
        ),
      );

  /// A white rounded control that floats over the map.
  static BoxDecoration get controlDecoration => BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radiusButton),
        boxShadow: controlShadow,
      );
}
