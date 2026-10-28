import 'dart:async';
import 'dart:convert';

import 'package:field/src/home/home_discovery_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late SupabaseClient client;
  late List<http.Request> requests;
  late Future<Object?> Function() response;
  setUp(() {
    requests = [];
    response = () async => _notice;
    client = SupabaseClient(
      'https://fieldrush-tests.invalid',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(await response()),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
  });
  tearDown(() => client.dispose());

  test(
    'receipt lookup uses owner RPC and canonical stored destination',
    () async {
      await client.auth.setInitialSession(jsonEncode(_session('player-a')));
      final item = await SupabaseHomeDiscoveryRepository(
        client: client,
      ).notificationById('receipt');
      expect(item?.openQueueGameId, 'actual-game');
      expect(item?.type, 'PLAYER_CHECKOUT_CONFIRMED');
      expect(
        requests.single.url.path,
        '/rest/v1/rpc/get_my_player_notification',
      );
      expect(jsonDecode(requests.single.body), {
        'notification_id_to_use': 'receipt',
      });
    },
  );

  test('signed-out receipt lookup performs no private request', () async {
    expect(
      await SupabaseHomeDiscoveryRepository(
        client: client,
      ).notificationById('receipt'),
      isNull,
    );
    expect(requests, isEmpty);
  });

  test(
    'receipt for another account or an expired source remains unavailable',
    () async {
      await client.auth.setInitialSession(jsonEncode(_session('player-a')));
      response = () async => null;
      expect(
        await SupabaseHomeDiscoveryRepository(
          client: client,
        ).notificationById('receipt'),
        isNull,
      );
    },
  );

  test(
    'late lookup cannot leak a previous account receipt after switching',
    () async {
      await client.auth.setInitialSession(jsonEncode(_session('player-a')));
      final hold = Completer<Object?>();
      response = () => hold.future;
      final pending = SupabaseHomeDiscoveryRepository(
        client: client,
      ).notificationById('receipt');
      await Future<void>.delayed(Duration.zero);
      await client.auth.setInitialSession(jsonEncode(_session('player-b')));
      hold.complete(_notice);
      expect(await pending, isNull);
    },
  );

  test('unexpected receipt identity never opens its destination', () async {
    await client.auth.setInitialSession(jsonEncode(_session('player-a')));
    response = () async => {..._notice, 'id': 'other-receipt'};
    expect(
      await SupabaseHomeDiscoveryRepository(
        client: client,
      ).notificationById('receipt'),
      isNull,
    );
  });

  test(
    'financial and discipline destinations use known canonical types only',
    () {
      HomeNotification notice(
        String type, {
        Map<String, dynamic> data = const {},
      }) => HomeNotification.fromJson({..._notice, 'type': type, 'data': data});
      expect(notice('PLAYER_CHECKOUT_REFUNDED').opensPaymentHistory, isTrue);
      expect(
        notice('PLAYER_CHECKOUT_AUTH_RELEASED').opensPaymentHistory,
        isFalse,
      );
      expect(notice('RELIABILITY_APPEAL_DECIDED').opensReliability, isTrue);
      expect(
        notice(
          'PLAYER_RESTRICTION_LIFTED',
          data: {'route_hint': 'reliability'},
        ).opensReliability,
        isTrue,
      );
      expect(notice('PLAYER_ACCOUNT_RESTRICTED').opensReliability, isFalse);
      expect(
        notice(
          'UNTRUSTED',
          data: {'route_hint': 'reliability'},
        ).opensReliability,
        isFalse,
      );
      expect(
        notice('UNTRUSTED', data: {'route': 'payments'}).opensPaymentHistory,
        isFalse,
      );
    },
  );

  test(
    'checkout acknowledgment sends only its exact displayed outcome',
    () async {
      response = () async => null;
      await SupabaseOpenQueueRepository(
        client: client,
      ).acknowledgeCheckoutNotification(
        paymentId: 'payment-attempt',
        outcome: 'REFUND_PENDING',
      );
      expect(
        requests.single.url.path,
        '/rest/v1/rpc/acknowledge_my_checkout_notification',
      );
      expect(jsonDecode(requests.single.body), {
        'payment_id_to_use': 'payment-attempt',
        'outcome_to_use': 'REFUND_PENDING',
      });
    },
  );
}

final _notice = <String, dynamic>{
  'id': 'receipt',
  'type': 'PLAYER_CHECKOUT_CONFIRMED',
  'title': 'You’re in',
  'body': 'Your spot is secured.',
  'created_at': '2026-10-26T12:00:00Z',
  'related_entity_type': 'OPEN_QUEUE_GAME',
  'related_entity_id': 'actual-game',
  'data': <String, dynamic>{},
};

Map<String, dynamic> _session(String owner) => {
  'access_token': 'test-access-token',
  'token_type': 'bearer',
  'expires_in': 3600,
  'refresh_token': 'test-refresh-token',
  'user': {
    'id': owner,
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': '',
    'phone': '',
    'created_at': '2026-10-10T12:00:00Z',
    'app_metadata': <String, dynamic>{},
    'user_metadata': <String, dynamic>{},
  },
};
