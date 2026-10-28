import 'package:field/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/staging_test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'staging app reaches an initial screen',
    (tester) async {
      await app.main();

      await pumpUntilAny(
        tester,
        [
          find.byKey(const ValueKey('fieldrush-create-account')),
          find.byKey(const ValueKey('fieldrush-first-name')),
          find.byKey(const ValueKey('fieldrush-phone')),
          find.byKey(const ValueKey('fieldrush-code')),
          find.byKey(const ValueKey('fieldrush-month')),
          find.byKey(const ValueKey('home-screen')),
        ],
        timeout: const Duration(seconds: 45),
        reason:
            'Field launched, but no signed-out, onboarding, or Home screen appeared.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
