import 'package:field/src/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig environment safety', () {
    test('accepts the hosted staging project in the staging flavor', () {
      const config = AppConfig(
        environment: AppEnvironment.staging,
        supabaseUrl: 'https://${AppConfig.stagingProjectRef}.supabase.co',
        supabasePublishableKey: 'publishable',
        isDev: true,
      );

      expect(config.validationError(nativeFlavor: 'staging'), isNull);
    });

    test(
      'enables profile switching only for configured non-production builds',
      () {
        const staging = AppConfig(
          environment: AppEnvironment.staging,
          supabaseUrl: 'https://${AppConfig.stagingProjectRef}.supabase.co',
          supabasePublishableKey: 'publishable',
          profileSwitcherEnabled: true,
        );
        const production = AppConfig(
          environment: AppEnvironment.production,
          supabaseUrl: 'https://${AppConfig.productionProjectRef}.supabase.co',
          supabasePublishableKey: 'publishable',
        );

        expect(staging.canSwitchProfiles, isTrue);
        expect(production.canSwitchProfiles, isFalse);
      },
    );

    test('rejects the profile switcher flag in production', () {
      const config = AppConfig(
        environment: AppEnvironment.production,
        supabaseUrl: 'https://${AppConfig.productionProjectRef}.supabase.co',
        supabasePublishableKey: 'publishable',
        profileSwitcherEnabled: true,
      );

      expect(
        config.validationError(nativeFlavor: 'production'),
        contains('PROFILE_SWITCHER_ENABLED must be false'),
      );
    });

    test('rejects Field Staging in a production build', () {
      const config = AppConfig(
        environment: AppEnvironment.production,
        supabaseUrl: 'https://${AppConfig.stagingProjectRef}.supabase.co',
        supabasePublishableKey: 'publishable',
      );

      expect(
        config.validationError(nativeFlavor: 'production'),
        contains('not pointing at Field Production'),
      );
    });

    test('rejects a lookalike hosted domain with the staging ref', () {
      const config = AppConfig(
        environment: AppEnvironment.staging,
        supabaseUrl: 'https://${AppConfig.stagingProjectRef}.other-domain.test',
        supabasePublishableKey: 'publishable',
        isDev: true,
      );

      expect(
        config.validationError(nativeFlavor: 'staging'),
        contains('not pointing at Field Staging'),
      );
    });

    test('rejects paths, queries, fragments, and credentials', () {
      for (final url in [
        'https://${AppConfig.stagingProjectRef}.supabase.co/rest/v1',
        'https://${AppConfig.stagingProjectRef}.supabase.co?preview=true',
        'https://${AppConfig.stagingProjectRef}.supabase.co#preview',
        'https://user:pass@${AppConfig.stagingProjectRef}.supabase.co',
      ]) {
        final config = AppConfig(
          environment: AppEnvironment.staging,
          supabaseUrl: url,
          supabasePublishableKey: 'publishable',
          isDev: true,
        );

        expect(
          config.validationError(nativeFlavor: 'staging'),
          contains('bare origin'),
        );
      }
    });

    test('rejects DEV mode in production', () {
      const config = AppConfig(
        environment: AppEnvironment.production,
        supabaseUrl: 'https://${AppConfig.productionProjectRef}.supabase.co',
        supabasePublishableKey: 'publishable',
        isDev: true,
      );

      expect(
        config.validationError(nativeFlavor: 'production'),
        contains('DEV must be false'),
      );
    });

    test('accepts the configured Field Production project', () {
      const config = AppConfig(
        environment: AppEnvironment.production,
        supabaseUrl: 'https://${AppConfig.productionProjectRef}.supabase.co',
        supabasePublishableKey: 'publishable',
      );

      expect(config.validationError(nativeFlavor: 'production'), isNull);
    });

    test('allows local Supabase through the staging app flavor', () {
      const config = AppConfig(
        environment: AppEnvironment.local,
        supabaseUrl: 'http://127.0.0.1:54321',
        supabasePublishableKey: 'publishable',
        isDev: true,
      );

      expect(config.validationError(nativeFlavor: 'staging'), isNull);
    });

    test('local requires plain HTTP on a bare loopback origin', () {
      for (final url in [
        'https://localhost:54321',
        'http://localhost:54321/rest/v1',
        'http://user:pass@localhost:54321',
      ]) {
        final config = AppConfig(
          environment: AppEnvironment.local,
          supabaseUrl: url,
          supabasePublishableKey: 'publishable',
          isDev: true,
        );

        expect(config.validationError(nativeFlavor: 'staging'), isNotNull);
      }
    });

    test('rejects mismatched native flavors', () {
      const config = AppConfig(
        environment: AppEnvironment.staging,
        supabaseUrl: 'https://${AppConfig.stagingProjectRef}.supabase.co',
        supabasePublishableKey: 'publishable',
        isDev: true,
      );

      expect(
        config.validationError(nativeFlavor: 'production'),
        contains('--flavor staging'),
      );
    });
  });
}
