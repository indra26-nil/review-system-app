/// Build-time configuration for the Supabase backend.
///
/// Values arrive as `--dart-define`s, which `build_and_install.sh` derives from
/// the gitignored `.env` file. Nothing here reads a file or embeds a secret:
/// the keys are compile-time constants, so they are absent from source control
/// and from the repository entirely.
///
/// When [isConfigured] is false the app still runs — it falls back to the
/// bundled sample data, so a build without a backend is a valid state rather
/// than a broken one.
class AppConfig {
  AppConfig._();

  /// e.g. `https://abcdefghijkl.supabase.co`
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');

  /// The `anon` / public key. Safe to ship: Supabase relies on row-level
  /// security rather than on keeping this secret. The `service_role` key must
  /// never appear in an app build — it bypasses RLS entirely.
  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Enables the simulator screen. False in anything real.
  static const bool demoMode = bool.fromEnvironment('DEMO_MODE');

  /// True when both credentials were supplied at build time.
  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// Human-readable reason the backend is unavailable, for the status chip.
  static String get missingConfig {
    if (isConfigured) return '';
    final missing = <String>[
      if (supabaseUrl.isEmpty) 'SUPABASE_URL',
      if (supabaseAnonKey.isEmpty) 'SUPABASE_ANON_KEY',
    ];
    return 'Backend not configured (missing ${missing.join(', ')})';
  }
}
