import 'dart:convert';
import 'dart:io';

import 'package:field/src/notifications/fieldrush_push.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Explicit provider integration check: use a disposable staging iOS simulator.
// Firebase is real; Supabase is mocked and no player/device is registered.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native iOS token cleanup works with auto-init off and no APNs token',
    (tester) async {
      final config = FieldrushPushConfiguration.fromEnvironment();
      expect(config.environment, 'staging');
      expect(config.projectId, 'fieldrush-1cfe5');
      await Firebase.initializeApp(options: config.options(TargetPlatform.iOS));
      final messaging = FirebaseMessaging.instance;
      await messaging.setAutoInitEnabled(false);
      expect(await messaging.getAPNSToken(), isNull);
      await expectLater(
        messaging.deleteToken(),
        throwsA(
          isA<FirebaseException>().having(
            (error) => error.code,
            'code',
            'apns-token-not-set',
          ),
        ),
      );
      // Exercise the native transport directly too, so provider failures report
      // their actual error instead of only leaving cleanup pending.
      await const MethodChannel('fieldrush/push_cleanup')
          .invokeMethod<void>('deleteRegistrations')
          .timeout(const Duration(seconds: 4));

      const owner = '20000000-0000-4000-8000-000000000001';
      SharedPreferences.setMockInitialValues({
        'push.opted_in': false,
        'push.cleanup.pending': true,
        'push.cleanup.user_id': owner,
      });
      final storage = await SharedPreferences.getInstance();
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://test.supabase.co',
        'public-fixture-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            'null',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await client.auth.setInitialSession(
        jsonEncode({
          'access_token': 'fixture-jwt',
          'refresh_token': 'fixture-refresh',
          'token_type': 'bearer',
          'expires_in': 3600,
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          'user': {
            'id': owner,
            'aud': 'authenticated',
            'app_metadata': <String, Object?>{},
            'user_metadata': <String, Object?>{},
            'created_at': '2026-01-01T00:00:00Z',
          },
        }),
      );
      final controller = FieldrushPush.testing(
        client: client,
        messaging: messaging,
        storage: storage,
        installationId: '20000000-0000-4000-8000-000000000002',
        projectId: config.projectId,
        listenToAuth: false,
      );
      try {
        await controller.synchronizeForTesting();
        expect(requests.single.url.path, '/rest/v1/rpc/revoke_my_push_device');
        expect(storage.getBool('push.cleanup.pending'), isFalse);
        expect(messaging.isAutoInitEnabled, isFalse);
        expect(await messaging.getAPNSToken(), isNull);
        expect(controller.phoneEnabled, isFalse);
      } finally {
        controller.dispose();
        await client.dispose();
      }
    },
    skip:
        !Platform.isIOS ||
        !const bool.fromEnvironment('VERIFY_NATIVE_PUSH_CLEANUP'),
  );
}
