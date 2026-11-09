import 'dart:async';
import 'dart:convert';

import 'package:field/src/payments/checkout_load_delivery.dart';
import 'package:field/src/payments/checkout_load_tracking.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a failed selector sends exactly two authenticated diagnostic RPCs',
    () async {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final requests = <http.Request>[];
      final received = Completer<void>();
      const origin = 'https://checkout-tests.invalid';
      final client = SupabaseClient(
        origin,
        'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          if (requests.length == 2) received.complete();
          return http.Response('', 204, request: request);
        }),
      );
      addTearDown(client.dispose);
      const accountId = 'checkout-test-player';
      final expires =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
          1000;
      String encode(Map<String, Object> value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final token = [
        encode({'alg': 'HS256', 'typ': 'JWT'}),
        encode({'sub': accountId, 'exp': expires}),
        'test-signature',
      ].join('.');
      await client.auth.recoverSession(
        jsonEncode({
          'access_token': token,
          'refresh_token': 'test-refresh-token',
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': {
            'id': accountId,
            'aud': 'authenticated',
            'created_at': '2026-10-01T00:00:00Z',
            'app_metadata': {},
            'user_metadata': {},
          },
        }),
      );

      final delivery = CheckoutLoadDelivery.instance;
      delivery.initialize(client, origin);
      addTearDown(delivery.cancelRetryTimer);
      final attempt = CheckoutLoadAttempt();
      final elapsed = Stopwatch()..start();
      attempt.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      attempt.finish(CheckoutLoadOutcome.failed, reason: 'selector_failed');
      elapsed.stop();
      attempt.finish(CheckoutLoadOutcome.closed);
      await received.future.timeout(const Duration(seconds: 5));
      await delivery.retry();

      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.method, 'POST');
        expect(
          request.url,
          Uri.parse('$origin/rest/v1/rpc/record_checkout_load_event'),
        );
        expect(request.headers['Authorization'], 'Bearer $token');
      }
      final start = jsonDecode(requests.first.body) as Map<String, dynamic>;
      final attemptId = start['attempt_id_to_use'];
      expect(
        attemptId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      final sharedFields = {
        'attempt_id_to_use': attemptId,
        'platform_to_use': 'ios',
        'app_version_to_use': const String.fromEnvironment(
          'APP_RELEASE_VERSION',
          defaultValue: 'unknown',
        ),
      };
      expect(start, {
        ...sharedFields,
        'outcome_to_use': 'started',
        'elapsed_ms_to_use': 0,
        'reason_to_use': null,
      });
      expect(jsonDecode(requests.last.body), {
        ...sharedFields,
        'outcome_to_use': 'failed',
        'elapsed_ms_to_use': allOf(
          isA<int>(),
          inInclusiveRange(1, elapsed.elapsedMilliseconds),
        ),
        'reason_to_use': 'selector_failed',
      });
    },
  );
}
