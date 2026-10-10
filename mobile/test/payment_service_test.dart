import 'dart:async';

import 'package:field/src/payments/payment_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _payload = {'game_id': 'game', 'role': 'DEF'};
Map<String, dynamic> _prepared() => {
  'intent_id': 'attempt-1',
  'stripe_payment_intent_id': 'pi_1',
  'client_secret': 'pi_1_secret_test',
  'status': 'PENDING',
  'currency': 'USD',
  'amount_fils': 13000,
};
Map<String, dynamic> _completed() => {
  'intent_id': 'attempt-1',
  'stripe_payment_intent_id': 'pi_1',
  'status': 'FINALIZED',
  'resource_type': 'OPEN_QUEUE_BOOKING',
  'resource_id': 'booking-1',
  'payment_method': 'APPLE_PAY',
};

void main() {
  test(
    'free booking finalizes without a payment key or native sheet',
    () async {
      final service = PaymentService(
        functionInvoker: (_) async => {
          ..._completed(),
          'intent_id': null,
          'stripe_payment_intent_id': null,
          'payment_method': 'FREE',
        },
      );
      final result = await service.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: _payload,
      );
      expect(result.intentId, isNull);
      expect(result.resourceId, 'booking-1');
      expect(result.paymentMethod, 'FREE');
    },
  );
  test(
    'sheet completion verifies server booking before returning success',
    () async {
      final calls = <Map<String, dynamic>>[];
      String? sheetSecret;
      final service = PaymentService(
        functionInvoker: (body) async {
          calls.add(body);
          return body['action'] == 'prepare' ? _prepared() : _completed();
        },
        sheetPresenter: (secret) async => sheetSecret = secret,
      );
      final result = await service.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: _payload,
      );
      expect(sheetSecret, 'pi_1_secret_test');
      expect(calls, [
        {'action': 'prepare', 'purpose': 'SOLO_BOOKING', 'payload': _payload},
        {'action': 'confirm', 'intent_id': 'attempt-1'},
      ]);
      expect(result.resourceId, 'booking-1');
      expect(result.paymentMethod, 'APPLE_PAY');
    },
  );

  test('already finalized retry never opens another sheet', () async {
    var presentations = 0;
    final service = PaymentService(
      functionInvoker: (_) async => _completed(),
      sheetPresenter: (_) async => presentations++,
    );
    final result = await service.pay(
      purpose: PaymentPurpose.soloBooking,
      payload: _payload,
    );
    expect(result.resourceId, 'booking-1');
    expect(presentations, 0);
  });

  test(
    'processing retry polls same attempt without another charge sheet',
    () async {
      var confirms = 0;
      var presentations = 0;
      final service = PaymentService(
        functionInvoker: (body) async {
          if (body['action'] == 'prepare') {
            return {..._prepared(), 'status': 'PROCESSING'};
          }
          confirms++;
          return confirms < 3 ? {'status': 'PROCESSING'} : _completed();
        },
        sheetPresenter: (_) async => presentations++,
        delay: (_) async {},
      );
      expect(
        (await service.pay(
          purpose: PaymentPurpose.soloBooking,
          payload: _payload,
        )).resourceId,
        'booking-1',
      );
      expect(confirms, 3);
      expect(presentations, 0);
    },
  );

  test('a lost confirmation response retries same attempt', () async {
    var confirms = 0;
    final service = PaymentService(
      functionInvoker: (body) async {
        if (body['action'] == 'prepare') return _prepared();
        expect(body['intent_id'], 'attempt-1');
        if (++confirms == 1) throw TimeoutException('network timeout');
        return _completed();
      },
      sheetPresenter: (_) async {},
      delay: (_) async {},
    );
    await service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload);
    expect(confirms, 2);
  });

  test(
    'unresolved payment is pending rather than a successful booking',
    () async {
      var confirms = 0;
      final service = PaymentService(
        functionInvoker: (body) async {
          if (body['action'] == 'prepare') return _prepared();
          confirms++;
          return {'status': 'PROCESSING'};
        },
        sheetPresenter: (_) async {},
        confirmationAttempts: 2,
        delay: (_) async {},
      );
      await expectLater(
        service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
        throwsA(isA<PaymentPendingException>()),
      );
      expect(confirms, 2);
    },
  );

  test(
    'cancelled sheet reconciles a payment that succeeded concurrently',
    () async {
      final service = PaymentService(
        functionInvoker: (body) async {
          if (body['action'] == 'prepare') return _prepared();
          expect(body['action'], 'cancel');
          return _completed();
        },
        sheetPresenter: (_) async => throw const PaymentCancelledException(),
      );
      expect(
        (await service.pay(
          purpose: PaymentPurpose.soloBooking,
          payload: _payload,
        )).resourceId,
        'booking-1',
      );
    },
  );

  test('confirmed cancellation does not finalize a booking', () async {
    final service = PaymentService(
      functionInvoker: (body) async =>
          body['action'] == 'prepare' ? _prepared() : {'status': 'CANCELLED'},
      sheetPresenter: (_) async => throw const PaymentCancelledException(),
    );
    await expectLater(
      service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
      throwsA(isA<PaymentCancelledException>()),
    );
  });

  for (final status in ['REQUIRES_REFUND', 'REFUNDED']) {
    test(
      '$status does not present checkout or claim a successful booking',
      () async {
        final service = PaymentService(
          functionInvoker: (_) async => {..._prepared(), 'status': status},
          sheetPresenter: (_) async => fail('Must not charge again'),
        );
        await expectLater(
          service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
          throwsA(
            isA<PaymentException>().having(
              (error) => error.message,
              'message',
              contains('refund'),
            ),
          ),
        );
      },
    );
  }

  test(
    'rapid calls from two repository instances share a single sheet',
    () async {
      final sheet = Completer<void>();
      var prepares = 0;
      var presentations = 0;
      Future<Map<String, dynamic>> invoke(Map<String, dynamic> body) async {
        if (body['action'] == 'prepare') {
          prepares++;
          return _prepared();
        }
        return _completed();
      }

      Future<void> present(String _) {
        presentations++;
        return sheet.future;
      }

      final one = PaymentService(
        functionInvoker: invoke,
        sheetPresenter: present,
      );
      final two = PaymentService(
        functionInvoker: invoke,
        sheetPresenter: present,
      );
      final first = one.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: _payload,
      );
      final second = two.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: {'role': 'DEF', 'game_id': 'game'},
      );
      await Future<void>.delayed(Duration.zero);
      expect(prepares, 1);
      expect(presentations, 1);
      sheet.complete();
      expect((await first).resourceId, (await second).resourceId);
    },
  );

  test('failure releases deduplication lock for a later attempt', () async {
    var prepares = 0;
    final service = PaymentService(
      functionInvoker: (body) async {
        if (body['action'] == 'prepare') {
          prepares++;
          if (prepares == 1) throw const PaymentException('Game full');
          return _completed();
        }
        fail('No confirmation expected');
      },
      sheetPresenter: (_) async => fail('No presentation expected'),
    );
    await expectLater(
      service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
      throwsA(isA<PaymentException>()),
    );
    expect(
      (await service.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: _payload,
      )).resourceId,
      'booking-1',
    );
    expect(prepares, 2);
  });

  test('FINALIZED requires an actual booking resource', () async {
    final service = PaymentService(
      functionInvoker: (_) async => {..._completed(), 'resource_id': ''},
      sheetPresenter: (_) async => fail('No sheet expected'),
    );
    await expectLater(
      service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
      throwsA(isA<PaymentException>()),
    );
  });

  for (final purpose in [PaymentPurpose.clanCreate, PaymentPurpose.clanJoin]) {
    test('${purpose.code} uses the same verified payment flow', () async {
      final service = PaymentService(
        functionInvoker: (body) async {
          if (body['action'] == 'prepare') {
            expect(body['purpose'], purpose.code);
            return _prepared();
          }
          return {..._completed(), 'resource_type': 'FIXTURE'};
        },
        sheetPresenter: (_) async {},
      );
      expect(
        (await service.pay(purpose: purpose, payload: {})).resourceType,
        'FIXTURE',
      );
    });
  }
}
