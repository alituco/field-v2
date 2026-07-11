class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    this.isDev = false,
  });

  const AppConfig.fromEnvironment()
    : supabaseUrl = const String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey = const String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
      isDev = const bool.fromEnvironment('DEV');

  final String supabaseUrl;
  final String supabasePublishableKey;
  final bool isDev;

  bool get hasSupabaseConfig =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
