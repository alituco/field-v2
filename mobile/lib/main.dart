import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/config/app_config.dart';

Future<void> main() async {
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
      hasSupabaseConfig: configurationError == null,
      isDev: config.isDev,
      configurationError: configurationError,
      environmentLabel: config.environment == AppEnvironment.production
          ? null
          : config.environment.label,
    ),
  );
}
