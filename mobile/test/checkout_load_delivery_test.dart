import 'dart:async';

import 'package:field/src/payments/checkout_load_delivery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, Object?> event(String id, [String state = 'started']) => {
  'attempt_id_to_use': id,
  'outcome_to_use': state,
  'elapsed_ms_to_use': 125,
  'platform_to_use': 'ios',
  'app_version_to_use': '1.0.1+80',
  'reason_to_use': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String? signedIn;
  late DateTime now;
  final stored = <String>[];
  CheckoutLoadDelivery delivery({
    String project = 'staging',
    Future<void> Function(String, Map<String, Object?>)? send,
  }) {
    final result = CheckoutLoadDelivery.forTesting(
      project: project,
      account: () => signedIn,
      now: () => now,
      send:
          send ??
          (actor, p) async => stored.add(
            '$actor/${p['attempt_id_to_use']}/${p['outcome_to_use']}',
          ),
    );
    addTearDown(result.cancelRetryTimer);
    return result;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    signedIn = 'a';
    now = DateTime.utc(2026, 11, 9);
    stored.clear();
  });

  test('can construct a tracker before Supabase initialization', () async {
    expect(CheckoutLoadDelivery.instance.currentAccountId, isNull);
    await CheckoutLoadDelivery.instance.record('a', event('offline'));
  });

  test(
    'replays an offline load only for its original project and account',
    () async {
      final offline = delivery(
        send: (_, _) async => throw TimeoutException('offline'),
      );
      await offline.record('a', {...event('one'), 'private': 'secret-value'});
      await offline.retry();
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getKeys().single;
      expect(prefs.getStringList(key)!.single, isNot(contains('secret-value')));

      await delivery(project: 'production').retry();
      signedIn = 'b';
      final restarted = delivery();
      await restarted.retry();
      expect(stored, isEmpty);
      signedIn = 'a';
      await restarted.retry();
      expect(stored, ['a/one/started']);
      expect(prefs.containsKey(key), isFalse);
      await delivery().retry();
      expect(stored, hasLength(1));
    },
  );

  test(
    'persists concurrent updates while another send is blocked, deduplicates',
    () async {
      final busy = Completer<void>();
      final entered = Completer<void>();
      final transport = delivery(
        send: (owner, p) async {
          if (!entered.isCompleted) {
            entered.complete();
            await busy.future;
          }
          stored.add("${p['attempt_id_to_use']}/${p['outcome_to_use']}");
        },
      );
      await transport.record('a', event('one'));
      await entered.future;

      await Future.wait([
        transport.record('a', event('one')),
        transport.record('a', event('one', 'ready')),
        transport.record('a', event('two')),
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(prefs.getKeys().single), hasLength(3));
      busy.complete();
      await transport.retry();
      expect(stored, ['one/started', 'one/ready', 'two/started']);
    },
  );

  test('retains at most 64 events and ages them out after one hour', () async {
    signedIn = null;
    final transport = delivery();
    for (var i = 0; i < 66; i++) {
      await transport.record('a', event('$i'));
    }
    await transport.retry();
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getKeys().single;
    expect(prefs.getStringList(key), hasLength(64));
    expect(
      prefs.getStringList(key)!.first,
      contains('"attempt_id_to_use":"2"'),
    );

    now = now.add(const Duration(hours: 1));
    signedIn = 'a';
    await transport.retry();
    expect(stored, isEmpty);
    expect(prefs.containsKey(key), isFalse);
  });

  test('a permanently rejected row does not block later events', () async {
    signedIn = null;
    final transport = delivery(
      send: (_, p) async {
        if (p['attempt_id_to_use'] == 'bad') {
          throw const PostgrestException(
            message: 'invalid event',
            code: '22023',
          );
        }
        stored.add(p['attempt_id_to_use'] as String);
      },
    );
    await transport.record('a', event('bad'));
    await transport.record('a', event('good'));
    signedIn = 'a';
    await transport.retry();
    expect(stored, ['good']);
  });
}
