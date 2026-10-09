import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/auth/fieldrush_account.dart';
import 'src/config/app_config.dart';

Future<void> main() => runFieldApp();

/// Integration tests can inject a fixture transport without shipping any
/// fixed-code authentication path in the Fieldrush account repository.
Future<void> runFieldApp({
  FieldrushAccountRepository? accountRepository,
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = AppConfig.fromEnvironment();
  final configurationError = config.validationError(nativeFlavor: appFlavor);
  if (configurationError == null) {
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabasePublishableKey,
    );
  }

  runApp(
    FieldApp(
      accountRepository: accountRepository,
      hasSupabaseConfig: configurationError == null,
      isDev: config.isDev,
      profileSwitcherEnabled: config.canSwitchProfiles,
      configurationError: configurationError,
      environmentLabel: config.environment == AppEnvironment.production
          ? null
          : config.environment.label,
    ),
  );
}
