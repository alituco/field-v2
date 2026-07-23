import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:field/src/payments/tap_payment_service.dart';

void main() {
  test('Tap checkout confirms the captured charge with Field server', () async {
    final calls = <Map<String, dynamic>>[];
    Map<String, dynamic>? checkoutConfiguration;
    final service = TapPaymentService(
      functionInvoker: (body) async {
        calls.add(body);
        if (body['action'] == 'prepare') {
          return {
            'intent_id': 'intent-1',
            'configuration': {
              'gateway': {'publicKey': 'pk_test_example'},
              'supportedPaymentMethods': [
                'APPLE_PAY',
                'BENEFIT_PAY',
                'VISA',
                'MASTERCARD',
              ],
            },
          };
        }
        return {
          'resource_type': 'OPEN_QUEUE_BOOKING',
          'resource_id': 'booking-1',
          'payment_method': 'VISA',
        };
      },
      checkoutStarter:
          ({
            required configurations,
            onClose,
            onReady,
            onSuccess,
            onError,
            onCancel,
          }) async {
            checkoutConfiguration = configurations;
            onReady?.call();
            onSuccess?.call('{"chargeId":"chg_test_12345678"}');
            onClose?.call();
            return true;
          },
    );

    final result = await service.pay(
      purpose: TapPaymentPurpose.soloBooking,
      payload: {'game_id': 'game-1', 'role': 'DEF'},
    );

    expect(result.resourceId, 'booking-1');
    expect(result.chargeId, 'chg_test_12345678');
    expect(result.paymentMethod, 'VISA');
    expect(calls, hasLength(2));
    expect(calls.first['action'], 'prepare');
    expect(calls.last, {
      'action': 'confirm',
      'intent_id': 'intent-1',
      'charge_id': 'chg_test_12345678',
    });
    expect(checkoutConfiguration?['supportedPaymentMethods'], [
      'APPLE_PAY',
      'BENEFIT_PAY',
      'VISA',
      'MASTERCARD',
    ]);
  });

  test('closing Tap checkout does not finalize a booking', () async {
    var confirmationCalls = 0;
    final service = TapPaymentService(
      functionInvoker: (body) async {
        if (body['action'] == 'confirm') confirmationCalls += 1;
        return {'intent_id': 'intent-1', 'configuration': <String, dynamic>{}};
      },
      checkoutStarter:
          ({
            required configurations,
            onClose,
            onReady,
            onSuccess,
            onError,
            onCancel,
          }) async {
            scheduleMicrotask(() => onClose?.call());
            return true;
          },
    );

    await expectLater(
      service.pay(
        purpose: TapPaymentPurpose.clanCreate,
        payload: {
          'clan_id': 'clan-1',
          'match_date': '2026-07-31',
          'time_slot': '7:00 PM',
        },
      ),
      throwsA(
        isA<TapPaymentException>().having(
          (error) => error.message,
          'message',
          'Payment was cancelled.',
        ),
      ),
    );
    expect(confirmationCalls, 0);
  });

  test('Tap decline gives a clear error and never confirms', () async {
    var confirmationCalls = 0;
    final service = TapPaymentService(
      functionInvoker: (body) async {
        if (body['action'] == 'confirm') confirmationCalls += 1;
        return {'intent_id': 'intent-1', 'configuration': <String, dynamic>{}};
      },
      checkoutStarter:
          ({
            required configurations,
            onClose,
            onReady,
            onSuccess,
            onError,
            onCancel,
          }) async {
            scheduleMicrotask(() {
              onError?.call('Card declined');
              onClose?.call();
            });
            return true;
          },
    );

    await expectLater(
      service.pay(
        purpose: TapPaymentPurpose.clanJoin,
        payload: {'fixture_id': 'fixture-1', 'clan_id': 'clan-1'},
      ),
      throwsA(
        isA<TapPaymentException>().having(
          (error) => error.message,
          'message',
          'Payment was declined. Try another payment method.',
        ),
      ),
    );
    expect(confirmationCalls, 0);
  });

  test(
    'a captured payment resumes confirmation without charging again',
    () async {
      final calls = <Map<String, dynamic>>[];
      var checkoutStarts = 0;
      final service = TapPaymentService(
        functionInvoker: (body) async {
          calls.add(body);
          if (body['action'] == 'prepare') {
            return {
              'intent_id': 'intent-1',
              'captured_charge_id': 'chg_test_captured',
              'resume_confirmation': true,
            };
          }
          return {
            'resource_type': 'OPEN_QUEUE_BOOKING',
            'resource_id': 'booking-1',
            'payment_method': 'BENEFITPAY',
          };
        },
        checkoutStarter:
            ({
              required configurations,
              onClose,
              onReady,
              onSuccess,
              onError,
              onCancel,
            }) async {
              checkoutStarts += 1;
              return true;
            },
      );

      final result = await service.pay(
        purpose: TapPaymentPurpose.soloBooking,
        payload: {'game_id': 'game-1', 'role': 'DEF'},
      );

      expect(checkoutStarts, 0);
      expect(result.chargeId, 'chg_test_captured');
      expect(result.resourceId, 'booking-1');
      expect(calls.last, {
        'action': 'confirm',
        'intent_id': 'intent-1',
        'charge_id': 'chg_test_captured',
      });
    },
  );
}
