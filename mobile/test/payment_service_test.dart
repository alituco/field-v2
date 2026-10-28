import 'dart:async';

import 'package:field/src/payments/payment_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _payload = {'game_id': 'game', 'role': 'DEF'};
Map<String, dynamic> _prepared() => {
  'intent_id': 'attempt-1',
  'stripe_payment_intent_id': 'pi_1',
  'client_secret': 'pi_1_secret_test',
  'status': 'PENDING',
  'currency': 'USD',
  'amount_fils': 13000,
  'capture_method': 'manual',
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
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final status in ['PENDING', 'PROCESSING', 'FAILED', 'EXPIRED']) {
    test(
      'explicit close retains an unconfirmed $status cancellation',
      () async {
        final service = PaymentService(
          functionInvoker: (body) async {
            expect(body, {'action': 'cancel', 'intent_id': 'attempt-1'});
            return {'status': status, 'intent_id': 'attempt-1'};
          },
        );
        await expectLater(
          service.cancelCheckout('attempt-1'),
          throwsA(isA<PaymentPendingException>()),
        );
      },
    );
  }
  test(
    'explicit close releases only an exact confirmed cancellation',
    () async {
      final service = PaymentService(
        functionInvoker: (_) async => {
          'status': 'CANCELLED',
          'intent_id': 'attempt-1',
        },
      );
      expect(await service.cancelCheckout('attempt-1'), isNull);
      final wrong = PaymentService(
        functionInvoker: (_) async => {
          'status': 'CANCELLED',
          'intent_id': 'other-attempt',
        },
      );
      await expectLater(
        wrong.cancelCheckout('attempt-1'),
        throwsA(isA<PaymentPendingException>()),
      );
    },
  );
  test('explicit close returns a booking when capture wins the race', () async {
    final service = PaymentService(functionInvoker: (_) async => _completed());
    expect(
      (await service.cancelCheckout('attempt-1'))?.resourceId,
      'booking-1',
    );
  });
  test('explicit close preserves a real refund outcome', () async {
    final service = PaymentService(
      functionInvoker: (_) async => {
        'status': 'REQUIRES_REFUND',
        'intent_id': 'attempt-1',
        'refund_status': 'PROCESSING',
      },
    );
    await expectLater(
      service.cancelCheckout('attempt-1'),
      throwsA(isA<PaymentRefundException>()),
    );
  });
  for (final status in ['FINALIZED', 'CANCELLED', 'REQUIRES_REFUND']) {
    for (final receivedId in [null, 'wrong-attempt']) {
      test(
        'confirmation cannot trust $status for receipt $receivedId',
        () async {
          final service = PaymentService(
            functionInvoker: (body) async => body['action'] == 'prepare'
                ? _prepared()
                : {..._completed(), 'status': status, 'intent_id': receivedId},
            paymentCollector: (_) async {},
            confirmationAttempts: 1,
          );
          await expectLater(
            service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
            throwsA(isA<PaymentPendingException>()),
          );
        },
      );
    }
  }
  test(
    'a native decline is cancelled before the player can change games',
    () async {
      final actions = <String>[];
      final service = PaymentService(
        functionInvoker: (body) async {
          actions.add(body['action'] as String);
          return body['action'] == 'prepare'
              ? _prepared()
              : {'status': 'CANCELLED', 'intent_id': 'attempt-1'};
        },
        paymentCollector: (_) async => throw const PaymentDeclinedException(),
      );
      await expectLater(
        service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
        throwsA(isA<PaymentDeclinedException>()),
      );
      expect(actions, ['prepare', 'cancel']);
    },
  );
  for (final serverMode in ['automatic', null]) {
    test(
      'new mobile never sends a $serverMode capture secret to its manual selector',
      () async {
        final actions = <String>[];
        final service = PaymentService(
          functionInvoker: (body) async {
            actions.add(body['action'] as String);
            if (body['action'] == 'prepare') {
              expect(body['capture_method'], 'manual');
              return {..._prepared(), 'capture_method': serverMode};
            }
            return {'status': 'CANCELLED', 'intent_id': 'attempt-1'};
          },
          paymentCollector: (_) async =>
              fail('Capture mode mismatch cannot reach native confirmation'),
        );
        await expectLater(
          service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
          throwsA(isA<PaymentQuoteChangedException>()),
        );
        expect(actions, ['prepare', 'cancel']);
      },
    );
  }

  Map<String, dynamic> collectable() => {
    ..._prepared(),
    'status': 'COLLECTABLE',
    'verified_unpaid': true,
    'provider_status': 'requires_payment_method',
  };
  test(
    'a lost prepare response resumes existing checkout without requiring a local intent ID',
    () async {
      final actions = <String>[];
      var resumeCalls = 0;
      var collections = 0;
      final service = PaymentService(
        functionInvoker: (body) async {
          actions.add(body['action'] as String);
          if (body['action'] == 'prepare') {
            throw const PaymentPendingException();
          }
          if (body['action'] == 'resume') {
            expect(body.containsKey('intent_id'), isFalse);
            return ++resumeCalls == 1
                ? {'status': 'PENDING', 'provider_status': 'UNKNOWN'}
                : collectable();
          }
          return _completed();
        },
        paymentCollector: (request) async {
          expect(request.intentId, 'attempt-1');
          expect(request.verifiedUnpaidResume, isTrue);
          collections++;
        },
      );
      await expectLater(
        service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
        throwsA(isA<PaymentPendingException>()),
      );
      await expectLater(
        service.pay(
          purpose: PaymentPurpose.soloBooking,
          payload: _payload,
          resumeOnly: true,
        ),
        throwsA(isA<PaymentPendingException>()),
      );
      expect(collections, 0);
      final result = await service.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: _payload,
        resumeOnly: true,
      );
      expect(result.resourceId, 'booking-1');
      expect(collections, 1);
      expect(actions, ['prepare', 'resume', 'resume', 'confirm']);
    },
  );
  for (final malformed in [
    {'intent_id': null},
    {'client_secret': null},
    {'stripe_payment_intent_id': null},
    {'amount_fils': '13000'},
    {'amount_fils': -1},
    {'currency': null},
    {'currency': 'BHD'},
  ]) {
    test(
      'a malformed resume remains indeterminate before collection: $malformed',
      () async {
        final service = PaymentService(
          functionInvoker: (_) async => {...collectable(), ...malformed},
          paymentCollector: (_) async =>
              fail('A malformed response cannot collect'),
        );
        await expectLater(
          service.pay(
            purpose: PaymentPurpose.soloBooking,
            payload: _payload,
            resumeOnly: true,
          ),
          throwsA(isA<PaymentPendingException>()),
        );
      },
    );
  }
  for (final terminal in [
    'FINALIZED',
    'CANCELLED',
    'REFUNDED',
    'REQUIRES_REFUND',
    'FAILED',
    'EXPIRED',
  ]) {
    test(
      'unidentified terminal resume cannot release an ambiguous attempt: $terminal',
      () async {
        final service = PaymentService(
          functionInvoker: (_) async => {'status': terminal},
          paymentCollector: (_) async =>
              fail('Unidentified terminal response cannot collect'),
        );
        await expectLater(
          service.pay(
            purpose: PaymentPurpose.soloBooking,
            payload: _payload,
            resumeOnly: true,
          ),
          throwsA(isA<PaymentPendingException>()),
        );
      },
    );
  }
  test(
    'exact unpaid resume rechecks and collects the same intent without prepare',
    () async {
      final actions = <String>[];
      PaymentCollectionRequest? collected;
      final service = PaymentService(
        functionInvoker: (body) async {
          actions.add(body['action'] as String);
          expect(body['intent_id'], 'attempt-1');
          return body['action'] == 'resume' ? collectable() : _completed();
        },
        paymentCollector: (request) async => collected = request,
      );
      final result = await service.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: _payload,
        resumeIntentId: 'attempt-1',
      );
      expect(result.resourceId, 'booking-1');
      expect(actions, ['resume', 'confirm']);
      expect(collected?.intentId, 'attempt-1');
      expect(collected?.stripePaymentIntentId, 'pi_1');
      expect(collected?.verifiedUnpaidResume, isTrue);
    },
  );
  test(
    'selector replacement pauses without confirming or preparing a second payment',
    () async {
      final actions = <String>[];
      final service = PaymentService(
        functionInvoker: (body) async {
          actions.add(body['action'] as String);
          return collectable();
        },
        paymentCollector: (_) async =>
            throw const PaymentSelectionRequiredException(),
      );
      await expectLater(
        service.pay(
          purpose: PaymentPurpose.soloBooking,
          payload: _payload,
          resumeIntentId: 'attempt-1',
        ),
        throwsA(isA<PaymentSelectionRequiredException>()),
      );
      expect(actions, ['resume']);
    },
  );
  for (final response in [
    {..._prepared(), 'status': 'PENDING'},
    {..._prepared(), 'status': 'PROCESSING'},
    {...collectable(), 'intent_id': 'foreign-attempt'},
    {...collectable(), 'verified_unpaid': false},
    {...collectable(), 'provider_status': 'succeeded'},
  ]) {
    test(
      'unverified or non-collectable resume never collects: ${response['status']}/${response['intent_id']}/${response['provider_status']}',
      () async {
        final actions = <String>[];
        final service = PaymentService(
          functionInvoker: (body) async {
            actions.add(body['action'] as String);
            return response;
          },
          paymentCollector: (_) async =>
              fail('Must not collect ambiguous/captured/foreign payment'),
        );
        await expectLater(
          service.pay(
            purpose: PaymentPurpose.soloBooking,
            payload: _payload,
            resumeIntentId: 'attempt-1',
          ),
          throwsA(isA<PaymentPendingException>()),
        );
        expect(actions, ['resume']);
      },
    );
  }
  test('a finalized exact-intent resume does not collect again', () async {
    final service = PaymentService(
      functionInvoker: (_) async => _completed(),
      paymentCollector: (_) async => fail('Already captured'),
    );
    expect(
      (await service.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: _payload,
        resumeIntentId: 'attempt-1',
      )).resourceId,
      'booking-1',
    );
  });
  test(
    'resume transport/auth failures remain pending rather than unlocking retry',
    () async {
      final service = PaymentService(
        functionInvoker: (_) async =>
            throw const PaymentException('Session expired'),
        paymentCollector: (_) async => fail('Unverified'),
      );
      await expectLater(
        service.pay(
          purpose: PaymentPurpose.soloBooking,
          payload: _payload,
          resumeIntentId: 'attempt-1',
        ),
        throwsA(isA<PaymentPendingException>()),
      );
    },
  );

  test('Android wallet matches the build environment and USD checkout', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final wallet = PaymentService.nativeSheetConfiguration.googlePay;
    expect(wallet, isNotNull);
    expect(wallet!.merchantCountryCode, 'US');
    expect(wallet.currencyCode, 'USD');
    expect(
      wallet.testEnv,
      const String.fromEnvironment('APP_ENV') != 'production',
    );
    expect(wallet.buttonType, PlatformButtonType.pay);
    // The authoritative PaymentIntent provides the price, never a static total.
    expect(wallet.amount, isNull);
  });

  test('iOS keeps Apple Pay configuration without offering Google Pay', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final configuration = PaymentService.nativeSheetConfiguration;
    expect(configuration.googlePay, isNull);
    const merchant = String.fromEnvironment('APPLE_MERCHANT_ID');
    expect(
      configuration.applePay?.merchantCountryCode,
      merchant.isEmpty ? null : 'US',
    );
  });

  test(
    'embedded collector receives authoritative USD cents before verification',
    () async {
      final actions = <String>[];
      PaymentCollectionRequest? collected;
      final service = PaymentService(
        functionInvoker: (body) async {
          actions.add(body['action'] as String);
          return body['action'] == 'prepare' ? _prepared() : _completed();
        },
        paymentCollector: (request) async {
          expect(actions, ['prepare']);
          collected = request;
        },
        sheetPresenter: (_) async =>
            fail('Embedded checkout must not open a sheet'),
      );
      final result = await service.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: _payload,
      );
      expect(collected?.clientSecret, 'pi_1_secret_test');
      expect(collected?.currency, 'USD');
      expect(collected?.amountFils, 13000);
      expect(collected?.amountMinor, 1300);
      expect(result.resourceId, 'booking-1');
      expect(actions, ['prepare', 'confirm']);
    },
  );

  for (final free in [false, true]) {
    test(
      'already finalized ${free ? 'free' : 'paid'} checkout skips collection and amount parsing',
      () async {
        final service = PaymentService(
          functionInvoker: (_) async => {
            ..._completed(),
            if (free) 'payment_method': 'FREE',
            if (free) 'intent_id': null,
            'amount_fils': 0,
            'currency': null,
          },
          paymentCollector: (_) async =>
              fail('Must not collect a completed payment'),
        );
        final result = await service.pay(
          purpose: PaymentPurpose.soloBooking,
          payload: _payload,
        );
        expect(result.resourceId, 'booking-1');
        expect(result.intentId, free ? null : 'attempt-1');
      },
    );
  }

  test(
    'embedded processing recovery skips collection and invalid amount parsing',
    () async {
      final actions = <String>[];
      final service = PaymentService(
        functionInvoker: (body) async {
          actions.add(body['action'] as String);
          return body['action'] == 'prepare'
              ? {'status': 'PROCESSING', 'intent_id': 'attempt-1'}
              : _completed();
        },
        paymentCollector: (_) async => fail('Must reconcile the same payment'),
      );
      expect(
        (await service.pay(
          purpose: PaymentPurpose.soloBooking,
          payload: _payload,
        )).resourceId,
        'booking-1',
      );
      expect(actions, ['prepare', 'confirm']);
    },
  );

  for (final invalid in <Map<String, dynamic>>[
    {'amount_fils': 0},
    {'amount_fils': -10},
    {'amount_fils': 13001},
    {'amount_fils': 13000.0},
    {'amount_fils': '13000'},
    {'amount_fils': null},
    {'amount_fils': 1000000000},
    {'currency': 'BHD'},
    {'currency': null},
  ]) {
    test(
      'embedded collection rejects an invalid prepared total $invalid',
      () async {
        final actions = <String>[];
        final service = PaymentService(
          functionInvoker: (body) async {
            actions.add(body['action'] as String);
            return {..._prepared(), ...invalid};
          },
          paymentCollector: (_) async =>
              fail('Must not confirm an invalid total'),
        );
        await expectLater(
          service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
          throwsA(isA<PaymentException>()),
        );
        expect(actions, ['prepare']);
      },
    );
  }

  test(
    'legacy sheet presenter does not require embedded amount fields',
    () async {
      var presentations = 0;
      final service = PaymentService(
        functionInvoker: (body) async => body['action'] == 'prepare'
            ? (_prepared()
                ..remove('amount_fils')
                ..remove('currency'))
            : _completed(),
        sheetPresenter: (_) async => presentations++,
      );
      await service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload);
      expect(presentations, 1);
    },
  );

  test(
    'embedded duplicate calls share prepare and native confirmation',
    () async {
      final collection = Completer<void>();
      var prepares = 0;
      var confirmations = 0;
      var collections = 0;
      Future<Map<String, dynamic>> invoke(Map<String, dynamic> body) async {
        if (body['action'] == 'prepare') {
          prepares++;
          return _prepared();
        }
        confirmations++;
        return _completed();
      }

      Future<void> collect(PaymentCollectionRequest _) {
        collections++;
        return collection.future;
      }

      final first = PaymentService(
        functionInvoker: invoke,
        paymentCollector: collect,
      ).pay(purpose: PaymentPurpose.soloBooking, payload: _payload);
      final second =
          PaymentService(
            functionInvoker: invoke,
            paymentCollector: collect,
          ).pay(
            purpose: PaymentPurpose.soloBooking,
            payload: {'role': 'DEF', 'game_id': 'game'},
          );
      await Future<void>.delayed(Duration.zero);
      expect(prepares, 1);
      expect(collections, 1);
      expect(confirmations, 0);
      collection.complete();
      expect((await first).resourceId, (await second).resourceId);
      expect(confirmations, 1);
    },
  );

  test(
    'changed quote cancels the same prepared attempt before allowing review',
    () async {
      final actions = <String>[];
      final service = PaymentService(
        functionInvoker: (body) async {
          actions.add(body['action'] as String);
          if (body['action'] == 'prepare') return _prepared();
          expect(body['intent_id'], 'attempt-1');
          return {'status': 'CANCELLED', 'intent_id': 'attempt-1'};
        },
        paymentCollector: (_) async =>
            throw const PaymentQuoteChangedException(),
      );
      await expectLater(
        service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
        throwsA(isA<PaymentQuoteChangedException>()),
      );
      expect(actions, ['prepare', 'cancel']);
    },
  );

  for (final cancelStatus in ['FINALIZED', 'PROCESSING']) {
    test(
      'quote cancellation racing $cancelStatus recovers the original booking',
      () async {
        final actions = <String>[];
        final service = PaymentService(
          functionInvoker: (body) async {
            actions.add(body['action'] as String);
            if (body['action'] == 'prepare') return _prepared();
            expect(body['intent_id'], 'attempt-1');
            if (body['action'] == 'cancel' && cancelStatus == 'PROCESSING') {
              return {'status': 'PROCESSING'};
            }
            return _completed();
          },
          paymentCollector: (_) async =>
              throw const PaymentQuoteChangedException(),
        );
        final result = await service.pay(
          purpose: PaymentPurpose.soloBooking,
          payload: _payload,
        );
        expect(result.resourceId, 'booking-1');
        expect(actions, [
          'prepare',
          'cancel',
          if (cancelStatus == 'PROCESSING') 'confirm',
        ]);
      },
    );
  }

  for (final cancelStatus in ['PENDING', 'PROCESSING', 'FAILED', 'EXPIRED']) {
    test(
      'unresolved quote cancellation $cancelStatus remains pending',
      () async {
        final actions = <String>[];
        final service = PaymentService(
          functionInvoker: (body) async {
            actions.add(body['action'] as String);
            if (body['action'] == 'prepare') return _prepared();
            expect(body['intent_id'], 'attempt-1');
            return {'status': cancelStatus};
          },
          paymentCollector: (_) async =>
              throw const PaymentQuoteChangedException(),
          confirmationAttempts: 1,
        );
        await expectLater(
          service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
          throwsA(isA<PaymentPendingException>()),
        );
        expect(actions.where((action) => action == 'prepare').length, 1);
        expect(actions, contains('cancel'));
      },
    );
  }

  for (final error in <Object>[
    TimeoutException('Cancellation response lost'),
    const PaymentException('Cancellation could not be validated'),
  ]) {
    test('failed quote cancellation $error remains pending', () async {
      final service = PaymentService(
        functionInvoker: (body) async {
          if (body['action'] == 'prepare') return _prepared();
          expect(body['action'], 'cancel');
          throw error;
        },
        paymentCollector: (_) async =>
            throw const PaymentQuoteChangedException(),
      );
      await expectLater(
        service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
        throwsA(isA<PaymentPendingException>()),
      );
    });
  }

  test(
    'failed reconciliation after unresolved quote cancellation remains pending',
    () async {
      final actions = <String>[];
      final service = PaymentService(
        functionInvoker: (body) async {
          actions.add(body['action'] as String);
          if (body['action'] == 'prepare') return _prepared();
          if (body['action'] == 'cancel') return {'status': 'PROCESSING'};
          throw const PaymentException('Confirmation could not be validated');
        },
        paymentCollector: (_) async =>
            throw const PaymentQuoteChangedException(),
        confirmationAttempts: 1,
      );
      await expectLater(
        service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
        throwsA(isA<PaymentPendingException>()),
      );
      expect(actions, ['prepare', 'cancel', 'confirm']);
    },
  );

  test('incomplete finalized cancellation response remains pending', () async {
    final service = PaymentService(
      functionInvoker: (body) async =>
          body['action'] == 'prepare' ? _prepared() : {'status': 'FINALIZED'},
      paymentCollector: (_) async => throw const PaymentQuoteChangedException(),
    );
    await expectLater(
      service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
      throwsA(isA<PaymentPendingException>()),
    );
  });

  test(
    'an unclassified collector error is not treated as a native decline',
    () async {
      final actions = <String>[];
      final service = PaymentService(
        functionInvoker: (body) async {
          actions.add(body['action'] as String);
          return _prepared();
        },
        paymentCollector: (_) async =>
            throw const PaymentException('Collector error'),
      );
      await expectLater(
        service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
        throwsA(
          isA<PaymentException>().having(
            (error) => error.message,
            'message',
            'Collector error',
          ),
        ),
      );
      expect(actions, ['prepare']);
    },
  );

  test(
    'shared native configuration has no payment secret or deferred intent',
    () {
      final configuration = PaymentService.nativeSheetConfiguration;
      expect(configuration.paymentIntentClientSecret, isNull);
      expect(configuration.setupIntentClientSecret, isNull);
      expect(configuration.intentConfiguration, isNull);
      expect(configuration.merchantDisplayName, 'Fieldrush');
      expect(configuration.allowsDelayedPaymentMethods, isFalse);
      expect(configuration.returnURL, endsWith('://safepay'));
    },
  );

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
        {
          'action': 'prepare',
          'purpose': 'SOLO_BOOKING',
          'payload': _payload,
          'capture_method': 'manual',
        },
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

  for (final error in <Object>[
    const FunctionException(status: 401, details: {'error': 'Session expired'}),
    const FunctionException(
      status: 409,
      details: {'error': 'Invalid reference'},
    ),
    const PaymentException('Checkout returned an invalid response.'),
  ]) {
    test(
      'unverified confirmation error $error preserves pending payment',
      () async {
        final actions = <String>[];
        var collections = 0;
        final service = PaymentService(
          functionInvoker: (body) async {
            actions.add(body['action'] as String);
            if (body['action'] == 'prepare') return _prepared();
            expect(body['intent_id'], 'attempt-1');
            throw error;
          },
          paymentCollector: (_) async => collections++,
          confirmationAttempts: 2,
          delay: (_) async {},
        );
        await expectLater(
          service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
          throwsA(isA<PaymentPendingException>()),
        );
        expect(collections, 1);
        expect(actions, ['prepare', 'confirm', 'confirm']);
      },
    );
  }

  test(
    'incomplete finalized confirmation retries without collecting again',
    () async {
      var confirms = 0;
      var collections = 0;
      final service = PaymentService(
        functionInvoker: (body) async {
          if (body['action'] == 'prepare') return _prepared();
          expect(body['intent_id'], 'attempt-1');
          return ++confirms == 1 ? {'status': 'FINALIZED'} : _completed();
        },
        paymentCollector: (_) async => collections++,
        delay: (_) async {},
      );
      final result = await service.pay(
        purpose: PaymentPurpose.soloBooking,
        payload: _payload,
      );
      expect(result.resourceId, 'booking-1');
      expect(confirms, 2);
      expect(collections, 1);
    },
  );

  for (final status in [
    'CANCELLED',
    'FAILED',
    'EXPIRED',
    'REFUNDED',
    'REQUIRES_REFUND',
  ]) {
    test(
      'explicit confirmation terminal status $status remains terminal',
      () async {
        var confirms = 0;
        final service = PaymentService(
          functionInvoker: (body) async {
            if (body['action'] == 'prepare') return _prepared();
            confirms++;
            return {'status': status, 'intent_id': 'attempt-1'};
          },
          paymentCollector: (_) async {},
          delay: (_) async {},
        );
        await expectLater(
          service.pay(purpose: PaymentPurpose.soloBooking, payload: _payload),
          throwsA(
            (status == 'REFUNDED' || status == 'REQUIRES_REFUND')
                ? isA<PaymentRefundException>()
                      .having((error) => error.intentId, 'intent', 'attempt-1')
                      .having((error) => error.status, 'status', status)
                : isA<PaymentException>().having(
                    (error) => error is PaymentPendingException,
                    'is pending',
                    isFalse,
                  ),
          ),
        );
        expect(confirms, 1);
      },
    );
  }

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
      functionInvoker: (body) async => body['action'] == 'prepare'
          ? _prepared()
          : {'status': 'CANCELLED', 'intent_id': 'attempt-1'},
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
            isA<PaymentRefundException>()
                .having((error) => error.intentId, 'intent', 'attempt-1')
                .having((error) => error.status, 'status', status)
                .having(
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
    'refund refresh confirms the same attempt without preparing or collecting',
    () async {
      final calls = <Map<String, dynamic>>[];
      var status = 'REQUIRES_REFUND';
      final service = PaymentService(
        functionInvoker: (body) async {
          calls.add(body);
          return {'intent_id': 'attempt-1', 'status': status};
        },
        paymentCollector: (_) async =>
            fail('Refund refresh must never collect'),
        sheetPresenter: (_) async =>
            fail('Refund refresh must never present payment'),
      );
      final pending = await service.checkRefundStatus('attempt-1');
      expect(pending.isRefunded, isFalse);
      status = 'REFUNDED';
      final completed = await service.checkRefundStatus('attempt-1');
      expect(completed.isRefunded, isTrue);
      expect(completed.intentId, 'attempt-1');
      expect(calls, [
        {'action': 'confirm', 'intent_id': 'attempt-1'},
        {'action': 'confirm', 'intent_id': 'attempt-1'},
      ]);
    },
  );

  test(
    'failed refund exposes support review instead of claiming it is processing',
    () async {
      final service = PaymentService(
        functionInvoker: (_) async => {
          'intent_id': 'attempt-1',
          'status': 'REQUIRES_REFUND',
          'refund_status': 'FAILED',
        },
      );
      final refund = await service.checkRefundStatus('attempt-1');
      expect(refund.needsReview, isTrue);
      expect(refund.message, contains('support review'));
      expect(refund.message, contains('Do not pay again'));
    },
  );

  for (final response in [
    {'intent_id': 'another-attempt', 'status': 'REFUNDED'},
    {'intent_id': 'attempt-1', 'status': 'PENDING'},
    {'status': 'FINALIZED'},
    <String, dynamic>{},
  ]) {
    test(
      'refund refresh rejects mismatched or non-refund response $response',
      () async {
        var calls = 0;
        final service = PaymentService(
          functionInvoker: (body) async {
            expect(body, {'action': 'confirm', 'intent_id': 'attempt-1'});
            calls++;
            return response;
          },
        );
        await expectLater(
          service.checkRefundStatus('attempt-1'),
          throwsA(isA<PaymentPendingException>()),
        );
        expect(calls, 1);
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
