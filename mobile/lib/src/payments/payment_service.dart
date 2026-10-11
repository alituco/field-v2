import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fieldrush_payment_appearance.dart';

/// A completed sheet is only a payment signal. The server must verify Stripe
/// and finalize the booking before the caller can navigate to a booking page.
class PaymentService {
  PaymentService({
    SupabaseClient? client,
    PaymentFunctionInvoker? functionInvoker,
    PaymentSheetPresenter? sheetPresenter,
    Future<void> Function(Duration)? delay,
    this.confirmationAttempts = 12,
    this.pollInterval = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 30),
    this.confirmationTimeout = const Duration(seconds: 45),
  }) : _client = client,
       _functionInvoker = functionInvoker,
       _sheetPresenter = sheetPresenter ?? _presentStripeSheet,
       _hasInjectedPresenter = sheetPresenter != null,
       _delay = delay ?? Future<void>.delayed;

  final SupabaseClient? _client;
  final PaymentFunctionInvoker? _functionInvoker;
  final PaymentSheetPresenter _sheetPresenter;
  final bool _hasInjectedPresenter;
  final Future<void> Function(Duration) _delay;
  final int confirmationAttempts;
  final Duration pollInterval;
  final Duration requestTimeout;
  final Duration confirmationTimeout;

  // Repository instances are short-lived. Share pending calls so rapid taps or
  // simultaneous screens cannot present two sheets for the same booking.
  static final Map<String, Future<PaymentResult>> _pending = {};

  Future<PaymentResult> pay({
    required PaymentPurpose purpose,
    required Map<String, dynamic> payload,
  }) {
    final actor = _client?.auth.currentUser?.id ?? 'current-user';
    final key = '$actor:${purpose.code}:${jsonEncode(_sorted(payload))}';
    return _pending.putIfAbsent(key, () {
      return _pay(purpose: purpose, payload: payload).whenComplete(() {
        _pending.remove(key);
      });
    });
  }

  Future<PaymentResult> _pay({
    required PaymentPurpose purpose,
    required Map<String, dynamic> payload,
  }) async {
    if (_stagingE2EPaymentBypass) {
      if (_environment != 'staging' && _environment != 'local') {
        throw const PaymentException('Test checkout is unavailable.');
      }
      final response = await _invoke({
        'action': 'complete_staging_e2e',
        'purpose': purpose.code,
        'payload': payload,
        'run_id': _stagingE2ERunId,
      });
      return _finalized(response);
    }

    final preparation = await _invoke({
      'action': 'prepare',
      'purpose': purpose.code,
      'payload': payload,
    });
    final status = _status(preparation);
    if (status == 'FINALIZED') return _finalized(preparation);
    _throwTerminal(preparation);
    final intentId = _requiredString(preparation['intent_id']);

    // A retry after payment or a delayed webhook must resume verification,
    // rather than request another payment from the customer.
    if (status != 'PENDING') return _confirm(intentId);
    if (!_hasInjectedPresenter) _validateConfiguration();
    final clientSecret = _requiredString(preparation['client_secret']);
    try {
      await _sheetPresenter(clientSecret);
    } on PaymentCancelledException {
      // Closing the sheet can race a successful payment. The server resolves
      // that race before we describe the attempt as cancelled.
      try {
        final cancellation = await _invoke({
          'action': 'cancel',
          'intent_id': intentId,
        });
        if (_status(cancellation) == 'FINALIZED') {
          return _finalized(cancellation);
        }
        _throwTerminal(cancellation);
        if (_status(cancellation) != 'CANCELLED') return _confirm(intentId);
      } on PaymentPendingException {
        rethrow;
      } on PaymentCancelledException {
        rethrow;
      } on PaymentException {
        rethrow;
      } catch (_) {
        throw const PaymentPendingException();
      }
      throw const PaymentCancelledException();
    }
    return _confirm(intentId);
  }

  Future<PaymentResult> _confirm(String intentId) async {
    final elapsed = Stopwatch()..start();
    for (var attempt = 0; attempt < confirmationAttempts; attempt++) {
      final remaining = confirmationTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) break;
      try {
        final response = await _invoke({
          'action': 'confirm',
          'intent_id': intentId,
        }, timeout: remaining < requestTimeout ? remaining : requestTimeout);
        if (_status(response) == 'FINALIZED') return _finalized(response);
        _throwTerminal(response);
      } on PaymentPendingException {
        // Temporary transport errors can follow a successful native payment.
        // Retry this same attempt; never initiate a replacement payment here.
      }
      if (attempt + 1 < confirmationAttempts &&
          elapsed.elapsed + pollInterval < confirmationTimeout) {
        await _delay(pollInterval);
      }
    }
    throw const PaymentPendingException();
  }

  Future<Map<String, dynamic>> _invoke(
    Map<String, dynamic> body, {
    Duration? timeout,
  }) async {
    try {
      final injected = _functionInvoker;
      if (injected != null) {
        return await injected(body).timeout(timeout ?? requestTimeout);
      }
      final response = await (_client ?? Supabase.instance.client).functions
          .invoke('stripe-payment', body: body)
          .timeout(timeout ?? requestTimeout);
      if (response.data is! Map) {
        throw const PaymentException('Checkout returned an invalid response.');
      }
      return Map<String, dynamic>.from(response.data as Map);
    } on TimeoutException {
      throw const PaymentPendingException();
    } on FunctionException catch (error) {
      if (error.status >= 500) throw const PaymentPendingException();
      final details = error.details;
      throw PaymentException(
        details is Map && details['error'] is String
            ? details['error'] as String
            : 'Payment could not be completed. Please try again.',
      );
    } on PaymentException {
      rethrow;
    } catch (_) {
      throw const PaymentPendingException();
    }
  }

  static void _validateConfiguration() {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      throw const PaymentException(
        'Please book using the iPhone or Android app.',
      );
    }
    final expectedPrefix = _environment == 'production'
        ? 'pk_live_'
        : 'pk_test_';
    if (!_publishableKey.startsWith(expectedPrefix)) {
      throw const PaymentException('Payments are not configured for this app.');
    }
  }

  static Future<void> _presentStripeSheet(String clientSecret) async {
    try {
      Stripe.publishableKey = _publishableKey;
      Stripe.merchantIdentifier = _appleMerchantId;
      Stripe.urlScheme = _returnScheme;
      await Stripe.instance.applySettings();
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: 'Fieldrush',
          returnURL: '$_returnScheme://safepay',
          allowsDelayedPaymentMethods: false,
          applePay: _appleMerchantId.isEmpty
              ? null
              : const PaymentSheetApplePay(merchantCountryCode: 'US'),
          style: ThemeMode.light,
          appearance: fieldrushPaymentSheetAppearance,
        ),
      );
      // The native sheet owns interaction time, including bank authentication.
      // Timing it out in Dart would leave a live sheet charging in the background.
      await Stripe.instance.presentPaymentSheet();
    } on StripeException catch (error) {
      if (error.error.code == FailureCode.Canceled) {
        throw const PaymentCancelledException();
      }
      throw PaymentException(
        error.error.localizedMessage ??
            'Payment could not be completed. Please try another card.',
      );
    } on PaymentException {
      rethrow;
    } catch (_) {
      throw const PaymentException(
        'Checkout could not open. Please try again.',
      );
    }
  }

  static PaymentResult _finalized(Map<String, dynamic> response) {
    if (_status(response) != 'FINALIZED') {
      throw const PaymentPendingException();
    }
    return PaymentResult(
      intentId: response['payment_method'] == 'FREE'
          ? null
          : _requiredString(response['intent_id']),
      stripePaymentIntentId: response['stripe_payment_intent_id']?.toString(),
      resourceType: _requiredString(response['resource_type']),
      resourceId: _requiredString(response['resource_id']),
      paymentMethod: response['payment_method']?.toString() ?? 'CARD',
    );
  }

  static void _throwTerminal(Map<String, dynamic> response) {
    switch (_status(response)) {
      case 'CANCELLED':
        throw const PaymentCancelledException();
      case 'REFUNDED':
        throw const PaymentException(
          'The booking could not be completed. Your payment has been refunded.',
        );
      case 'REQUIRES_REFUND':
        throw const PaymentException(
          'Your payment was received, but the booking could not be completed. '
          'Support has been alerted and your refund is being resolved. Do not pay again.',
        );
      case 'FAILED':
      case 'EXPIRED':
        throw const PaymentException(
          'This payment was not completed. Please try again.',
        );
    }
  }

  static String _status(Map<String, dynamic> response) =>
      response['status']?.toString().toUpperCase() ?? '';

  static String _requiredString(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw const PaymentException('Checkout returned an incomplete response.');
    }
    return value.trim();
  }

  static Object? _sorted(Object? value) {
    if (value is Map<String, dynamic>) {
      return {
        for (final key in value.keys.toList()..sort()) key: _sorted(value[key]),
      };
    }
    if (value is List) return value.map(_sorted).toList();
    return value;
  }
}

const _environment = String.fromEnvironment('APP_ENV');
const _publishableKey = String.fromEnvironment('STRIPE_PUBLISHABLE_KEY');
const _appleMerchantId = String.fromEnvironment('APPLE_MERCHANT_ID');
const _returnScheme = _environment == 'production'
    ? 'com.alialtaraif.field'
    : 'com.alialtaraif.field.staging';
const _stagingE2EPaymentBypass = bool.fromEnvironment(
  'FIELD_E2E_PAYMENT_BYPASS',
);
const _stagingE2ERunId = String.fromEnvironment('E2E_RUN_ID');

typedef PaymentFunctionInvoker =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> body);
typedef PaymentSheetPresenter = Future<void> Function(String clientSecret);

enum PaymentPurpose {
  soloBooking('SOLO_BOOKING'),
  clanCreate('CLAN_CREATE'),
  clanJoin('CLAN_JOIN');

  const PaymentPurpose(this.code);
  final String code;
}

class PaymentResult {
  const PaymentResult({
    required this.intentId,
    this.stripePaymentIntentId,
    required this.resourceType,
    required this.resourceId,
    required this.paymentMethod,
  });

  final String? intentId;
  final String? stripePaymentIntentId;
  final String resourceType;
  final String resourceId;
  final String paymentMethod;
}

class PaymentException implements Exception {
  const PaymentException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PaymentCancelledException extends PaymentException {
  const PaymentCancelledException() : super('Payment was cancelled.');
}

class PaymentPendingException extends PaymentException {
  const PaymentPendingException()
    : super(
        'We are still checking this payment. Check your bookings shortly. '
        'Trying again will check the same payment before asking you to pay.',
      );
}
