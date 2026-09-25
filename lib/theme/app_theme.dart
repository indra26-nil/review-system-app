import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// The app's [ThemeData], derived entirely from [AppTokens].
///
/// Light and near-white by default: the map supplies the colour, and the UI
/// stays out of its way. There is no dark variant — the sheets sit directly on
/// a light map, and a dark surface would break that spatial relationship.
class RevMapTheme {
  RevMapTheme._();

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppTokens.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppTokens.accent,
        secondary: AppTokens.accent,
        surface: AppTokens.background,
        onSurface: AppTokens.textPrimary,
      ),
      scaffoldBackgroundColor: AppTokens.background,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // The map is the hero; a solid app bar would cut it in half.
        foregroundColor: AppTokens.textPrimary,
      ),
      cardTheme: CardThemeData(
        color: AppTokens.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusCard),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppTokens.background,
        surfaceTintColor: Colors.transparent,
        // The design uses a custom grabber and explicit radii instead.
        showDragHandle: false,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.radiusSheet),
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppTokens.hairline,
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppTokens.surfaceMuted,
        selectedColor: AppTokens.accentSoft,
        labelStyle: AppTokens.caption.copyWith(
          fontWeight: FontWeight.w600,
          color: AppTokens.textPrimary,
        ),
        side: BorderSide.none,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppTokens.background,
        foregroundColor: AppTokens.textPrimary,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppTokens.radiusButton)),
        ),
      ),
      iconTheme: const IconThemeData(color: AppTokens.textPrimary, size: 20),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppTokens.textPrimary,
        contentTextStyle: const TextStyle(
          color: AppTokens.background,
          fontSize: 14,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusButton),
        ),
      ),
      // Type scale from the tokens so text never drifts between screens.
      textTheme: base.textTheme
          .apply(
            bodyColor: AppTokens.textPrimary,
            displayColor: AppTokens.textPrimary,
          )
          .copyWith(
            headlineSmall: AppTokens.titleLg,
            titleLarge: AppTokens.titleMd,
            titleMedium: AppTokens.titleSm,
            bodyLarge: AppTokens.body,
            bodyMedium: AppTokens.bodySecondary,
            bodySmall: AppTokens.caption,
            labelSmall: AppTokens.metadata,
          ),
    );
  }
}
