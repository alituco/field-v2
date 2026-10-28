import 'dart:async';

import 'package:field/src/payments/fieldrush_embedded_payment.dart';
import 'package:field/src/payments/payment_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeController controller;
  late StripeFieldrushEmbeddedPaymentSession session;
  late List<IntentCreationCallbackParams> responses;

  setUp(() {
    controller = _FakeController();
    responses = [];
    session = StripeFieldrushEmbeddedPaymentSession(
      amountFils: 13000,
      currency: 'usd',
      controller: controller,
      configureNativePayments: () async {},
      intentCreationCallback: (response) async => responses.add(response),
    );
  });

  tearDown(() async {
    await session.close();
    session.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  Future<EmbeddedPaymentElement> ready() async {
    await session.initialize();
    final view = session.buildView() as EmbeddedPaymentElement;
    view.onPaymentOptionChanged!(
      const PaymentSheetPaymentOption(label: 'Card'),
    );
    return view;
  }

  PaymentCollectionRequest request({int amountFils = 13000}) =>
      PaymentCollectionRequest(
        clientSecret: 'pi_test_secret_test',
        amountFils: amountFils,
        currency: 'USD',
      );

  test('quote is converted once and view/configuration are stable', () async {
    await session.initialize();
    final view = session.buildView() as EmbeddedPaymentElement;
    expect(identical(view, session.buildView()), isTrue);
    expect(view.intentConfiguration.mode.toJson()['amount'], 1300);
    expect(view.intentConfiguration.mode.toJson()['currencyCode'], 'USD');
    expect(view.intentConfiguration.mode.toJson()['captureMethod'], 'Manual');
    expect(view.intentConfiguration.paymentMethodTypes, ['card']);
    expect(view.configuration.paymentIntentClientSecret, isNull);
    expect(
      view.configuration.linkDisplayParams?.linkDisplay,
      LinkDisplay.never,
    );
    expect(view.onFormSheetConfirmComplete, isNull);
  });

  test(
    'Android embeds Google Pay without starting payment on selection',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await session.initialize();
      final view = session.buildView() as EmbeddedPaymentElement;
      expect(view.configuration.googlePay?.merchantCountryCode, 'US');
      expect(view.configuration.googlePay?.currencyCode, 'USD');
      expect(
        view.configuration.googlePay?.testEnv,
        const String.fromEnvironment('APP_ENV') != 'production',
      );
      view.onHeightChanged!(100);
      view.onPaymentOptionChanged!(
        const PaymentSheetPaymentOption(label: 'Google Pay'),
      );
      expect(session.isReady, isTrue);
      expect(session.hasSelection, isTrue);
      expect(controller.confirmCount, 0);
      expect(responses, isEmpty);
      view.onPaymentOptionChanged!(null);
      expect(session.hasSelection, isFalse);
    },
  );

  test('native height is load readiness, never payment selection', () async {
    await session.initialize();
    final view = session.buildView() as EmbeddedPaymentElement;
    expect(session.isReady, isFalse);
    view.onHeightChanged!(1);
    expect(session.isReady, isFalse);
    view.onHeightChanged!(100);
    expect(session.isReady, isTrue);
    expect(session.hasSelection, isFalse);
    await expectLater(
      session.collectPayment(request()),
      throwsA(isA<PaymentException>()),
    );
    expect(controller.confirmCount, 0);
    view.onPaymentOptionChanged!(
      const PaymentSheetPaymentOption(label: 'Card'),
    );
    expect(session.hasSelection, isTrue);
    view.onPaymentOptionChanged!(null);
    expect(session.hasSelection, isFalse);
  });

  test('a changed server quote never reaches native confirmation', () async {
    await ready();
    await expectLater(
      session.collectPayment(request(amountFils: 14000)),
      throwsA(isA<PaymentQuoteChangedException>()),
    );
    expect(controller.confirmCount, 0);
    expect(responses, isEmpty);
  });

  test('invalid initial quotes are recoverable load errors', () async {
    await session.close();
    session.dispose();
    session = StripeFieldrushEmbeddedPaymentSession(
      amountFils: 13001,
      currency: 'USD',
      configureNativePayments: () async => fail('Must not configure Stripe'),
    );
    await session.initialize();
    expect(session.loadingError, 'Checkout returned an invalid total.');
    expect(session.isReady, isFalse);
  });

  test('confirmation supplies the active secret once', () async {
    final view = await ready();
    controller.onConfirm = () async {
      final callback = view.intentConfiguration.confirmHandler!;
      callback(_paymentMethod, false);
      callback(_paymentMethod, false);
      return {'status': 'completed'};
    };
    await session.collectPayment(request());
    expect(responses, hasLength(1));
    expect(responses.single.clientSecret, 'pi_test_secret_test');
    expect(session.isReady, isFalse);
    await expectLater(
      session.collectPayment(request()),
      throwsA(isA<PaymentPendingException>()),
    );
    expect(controller.confirmCount, 1);
  });

  test(
    'an unexpected native callback is failed once without a secret',
    () async {
      final view = await ready();
      view.intentConfiguration.confirmHandler!(_paymentMethod, false);
      view.intentConfiguration.confirmHandler!(_paymentMethod, false);
      expect(responses, hasLength(1));
      expect(responses.single.clientSecret, isNull);
      expect(responses.single.error, isNotNull);
    },
  );

  test(
    'cancellation remains a cancellation and supports a later attempt',
    () async {
      await ready();
      controller.onConfirm = () async => {'status': 'canceled'};
      await expectLater(
        session.collectPayment(request()),
        throwsA(isA<PaymentCancelledException>()),
      );
      expect(session.isReady, isTrue);
      controller.onConfirm = () async => {'status': 'completed'};
      await session.collectPayment(request());
      expect(controller.confirmCount, 2);
    },
  );

  test('failed confirmation exposes a safe app message only', () async {
    await ready();
    controller.onConfirm = () async => {
      'status': 'failed',
      'error': 'raw native details containing pi_secret_or_card_data',
    };
    await expectLater(
      session.collectPayment(request()),
      throwsA(
        isA<PaymentException>().having(
          (error) => error.message,
          'message',
          'Payment could not be completed. Please try another card.',
        ),
      ),
    );
  });

  for (final result in <Map<String, dynamic>?>[
    null,
    {},
    {'status': 'unknown'},
  ]) {
    test('ambiguous result $result blocks another native attempt', () async {
      await ready();
      controller.onConfirm = () async => result;
      await expectLater(
        session.collectPayment(request()),
        throwsA(isA<PaymentPendingException>()),
      );
      expect(session.loadingError, contains('Reload payment methods'));
      await expectLater(
        session.collectPayment(request()),
        throwsA(isA<PaymentPendingException>()),
      );
      expect(controller.confirmCount, 1);
    });
  }

  test('native transport errors remain pending, not canceled', () async {
    await ready();
    controller.onConfirm = () async => throw PlatformException(code: 'lost');
    await expectLater(
      session.collectPayment(request()),
      throwsA(isA<PaymentPendingException>()),
    );
    expect(session.isReady, isFalse);
  });

  test(
    'concurrent confirms are blocked without timing out active work',
    () async {
      await ready();
      final native = Completer<Map<String, dynamic>?>();
      controller.onConfirm = () => native.future;
      final first = session.collectPayment(request());
      await expectLater(
        session.collectPayment(request()),
        throwsA(isA<PaymentPendingException>()),
      );
      expect(controller.confirmCount, 1);
      native.complete({'status': 'completed'});
      await first;
    },
  );

  test('a missing callback acknowledgement does not hold completion', () async {
    await session.close();
    session.dispose();
    final acknowledgement = Completer<void>();
    controller = _FakeController();
    session = StripeFieldrushEmbeddedPaymentSession(
      amountFils: 13000,
      currency: 'USD',
      controller: controller,
      configureNativePayments: () async {},
      intentCreationCallback: (_) => acknowledgement.future,
    );
    final view = await ready();
    controller.onConfirm = () async {
      view.intentConfiguration.confirmHandler!(_paymentMethod, false);
      return {'status': 'completed'};
    };
    await session.collectPayment(request());
    expect(acknowledgement.isCompleted, isFalse);
    acknowledgement.complete();
  });

  test(
    'a retired selector cannot answer callbacks for its replacement',
    () async {
      final retiredView = await ready();
      await session.close();
      session.dispose();
      controller = _FakeController();
      session = StripeFieldrushEmbeddedPaymentSession(
        amountFils: 13000,
        currency: 'USD',
        controller: controller,
        configureNativePayments: () async {},
        intentCreationCallback: (response) async => responses.add(response),
      );
      final replacementView = await ready();

      retiredView.intentConfiguration.confirmHandler!(_paymentMethod, false);
      await Future<void>.delayed(Duration.zero);
      expect(responses, isEmpty);
      expect(session.isReady, isTrue);

      controller.onConfirm = () async {
        replacementView.intentConfiguration.confirmHandler!(
          _paymentMethod,
          false,
        );
        return {'status': 'completed'};
      };
      await session.collectPayment(request());
      expect(responses.single.clientSecret, 'pi_test_secret_test');
    },
  );

  test(
    'callback transport error resolves ambiguity even if native is waiting',
    () async {
      await session.close();
      session.dispose();
      controller = _FakeController();
      session = StripeFieldrushEmbeddedPaymentSession(
        amountFils: 13000,
        currency: 'USD',
        controller: controller,
        configureNativePayments: () async {},
        intentCreationCallback: (_) async =>
            throw PlatformException(code: 'lost'),
      );
      final view = await ready();
      final native = Completer<Map<String, dynamic>?>();
      controller.onConfirm = () {
        view.intentConfiguration.confirmHandler!(_paymentMethod, false);
        return native.future;
      };
      await expectLater(
        session.collectPayment(request()),
        throwsA(isA<PaymentPendingException>()),
      );
      expect(session.isReady, isFalse);
      native.complete({'status': 'completed'});
      await Future<void>.delayed(Duration.zero);
      expect(session.isReady, isFalse);
    },
  );

  test(
    'loading failures do not expose SDK details and ignore stale events',
    () async {
      final view = await ready();
      view.onLoadingFailed!(
        const EmbeddedPaymentElementLoadingException(message: 'secret details'),
      );
      expect(
        session.loadingError,
        'Payment methods could not load. Please try again.',
      );
      view.onHeightChanged!(100);
      view.onPaymentOptionChanged!(
        const PaymentSheetPaymentOption(label: 'Card'),
      );
      expect(session.isReady, isFalse);
      expect(session.hasSelection, isFalse);
    },
  );

  test('loading has a bounded, recoverable timeout', () async {
    await session.close();
    session.dispose();
    session = StripeFieldrushEmbeddedPaymentSession(
      amountFils: 13000,
      currency: 'USD',
      configureNativePayments: () async {},
      loadTimeout: const Duration(milliseconds: 5),
    );
    await session.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.loadingError, isNotNull);
    expect(session.isReady, isFalse);
  });

  test(
    'close tolerates native teardown errors and dispose is idempotent',
    () async {
      await ready();
      controller.onClose = () async => throw PlatformException(code: 'lost');
      await session.close();
      await session.close();
      expect(controller.closeCount, 1);
      session.dispose();
      session.dispose();
      final replacement = StripeFieldrushEmbeddedPaymentSession(
        amountFils: 13000,
        currency: 'USD',
        configureNativePayments: () async {},
      );
      await replacement.initialize();
      expect(replacement.loadingError, isNull);
      await replacement.close();
      replacement.dispose();
    },
  );

  test(
    'close retains ownership until delayed initialization finishes',
    () async {
      await session.close();
      session.dispose();
      final configuring = Completer<void>();
      controller = _FakeController();
      session = StripeFieldrushEmbeddedPaymentSession(
        amountFils: 13000,
        currency: 'USD',
        controller: controller,
        configureNativePayments: () => configuring.future,
      );
      final initializing = session.initialize();
      final closing = session.close();
      final other = StripeFieldrushEmbeddedPaymentSession(
        amountFils: 13000,
        currency: 'USD',
        configureNativePayments: () async {},
      );
      await other.initialize();
      expect(other.loadingError, contains('Another checkout'));
      expect(controller.closeCount, 0);
      await other.close();
      other.dispose();
      configuring.complete();
      await initializing;
      await closing;
      expect(session.isReady, isFalse);
      expect(controller.closeCount, 1);
      final replacement = StripeFieldrushEmbeddedPaymentSession(
        amountFils: 13000,
        currency: 'USD',
        configureNativePayments: () async {},
      );
      await replacement.initialize();
      expect(replacement.loadingError, isNull);
      await replacement.close();
      replacement.dispose();
    },
  );

  test(
    'close awaits native teardown before releasing global ownership',
    () async {
      await ready();
      final teardown = Completer<void>();
      controller.onClose = () => teardown.future;
      final closing = session.close();
      final other = StripeFieldrushEmbeddedPaymentSession(
        amountFils: 13000,
        currency: 'USD',
        configureNativePayments: () async {},
      );
      await other.initialize();
      expect(other.loadingError, contains('Another checkout'));
      await other.close();
      other.dispose();
      teardown.complete();
      await closing;
      expect(controller.closeCount, 1);
      await session.close();
      expect(controller.closeCount, 1);
      final replacement = StripeFieldrushEmbeddedPaymentSession(
        amountFils: 13000,
        currency: 'USD',
        configureNativePayments: () async {},
      );
      await replacement.initialize();
      expect(replacement.loadingError, isNull);
      await replacement.close();
      replacement.dispose();
    },
  );
}

final _paymentMethod = PaymentMethod.fromJson({
  'id': 'pm_test',
  'paymentMethodType': 'Card',
  'livemode': false,
  'billingDetails': <String, dynamic>{},
  'Card': <String, dynamic>{},
  'SepaDebit': <String, dynamic>{},
  'BacsDebit': <String, dynamic>{},
  'AuBecsDebit': <String, dynamic>{},
  'Ideal': <String, dynamic>{},
  'Fpx': <String, dynamic>{},
  'USBankAccount': <String, dynamic>{},
});

class _FakeController extends EmbeddedPaymentElementController {
  int confirmCount = 0;
  int closeCount = 0;
  Future<Map<String, dynamic>?> Function()? onConfirm;
  Future<void> Function()? onClose;

  @override
  Future<Map<String, dynamic>?> confirm() async {
    confirmCount++;
    return onConfirm?.call() ?? Future.value({'status': 'completed'});
  }

  @override
  Future<void> disposeView() async {
    closeCount++;
    await onClose?.call();
  }
}
