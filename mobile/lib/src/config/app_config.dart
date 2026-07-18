enum AppEnvironment {
  local,
  staging,
  production,
  unknown;

  static AppEnvironment parse(String value) {
    return switch (value.trim().toLowerCase()) {
      'local' => AppEnvironment.local,
      'staging' => AppEnvironment.staging,
      'production' => AppEnvironment.production,
      _ => AppEnvironment.unknown,
    };
  }

  String get label => switch (this) {
    AppEnvironment.local => 'LOCAL',
    AppEnvironment.staging => 'STAGING',
    AppEnvironment.production => 'PRODUCTION',
    AppEnvironment.unknown => 'UNKNOWN',
  };
}

class AppConfig {
  const AppConfig({
    required this.environment,
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    this.isDev = false,
  });

  factory AppConfig.fromEnvironment() {
    return AppConfig(
      environment: AppEnvironment.parse(
        const String.fromEnvironment('APP_ENV'),
      ),
      supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: const String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
      isDev: const bool.fromEnvironment('DEV'),
    );
  }

  static const stagingProjectRef = 'nfdkdhdevpstfspazbfn';
  static const productionProjectRef = 'zjsjuuhborxrlmdcpvlj';

  final AppEnvironment environment;
  final String supabaseUrl;
  final String supabasePublishableKey;
  final bool isDev;

  bool get hasSupabaseConfig =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;

  String? validationError({required String? nativeFlavor}) {
    if (environment == AppEnvironment.unknown) {
      return 'APP_ENV must be local, staging, or production.';
    }
    if (!hasSupabaseConfig) {
      return 'SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are required.';
    }

    final uri = Uri.tryParse(supabaseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'SUPABASE_URL is not a valid URL.';
    }
    final isBareOrigin =
        (uri.path.isEmpty || uri.path == '/') &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.userInfo.isEmpty;
    if (!isBareOrigin) {
      return 'SUPABASE_URL must be a bare origin without credentials, '
          'a path, query, or fragment.';
    }

    final expectedFlavor = environment == AppEnvironment.production
        ? 'production'
        : 'staging';
    if (nativeFlavor != expectedFlavor) {
      return 'The ${environment.label} environment must run with '
          '--flavor $expectedFlavor.';
    }

    final isLoopback =
        uri.host == '127.0.0.1' ||
        uri.host == 'localhost' ||
        uri.host == '10.0.2.2';
    if (environment == AppEnvironment.local &&
        (!isLoopback || uri.scheme != 'http')) {
      return 'The LOCAL environment must use a loopback Supabase URL.';
    }
    if (environment != AppEnvironment.local &&
        (uri.scheme != 'https' || uri.hasPort)) {
      return 'Hosted Supabase environments must use their secure default origin.';
    }

    final expectedHostedHost = environment == AppEnvironment.staging
        ? '$stagingProjectRef.supabase.co'
        : '$productionProjectRef.supabase.co';
    if (environment == AppEnvironment.staging &&
        uri.host != expectedHostedHost) {
      return 'The staging build is not pointing at Field Staging.';
    }
    if (environment == AppEnvironment.production &&
        uri.host != expectedHostedHost) {
      return 'The production build is not pointing at Field Production.';
    }
    if (environment == AppEnvironment.production && isDev) {
      return 'DEV must be false in production.';
    }

    return null;
  }
}
