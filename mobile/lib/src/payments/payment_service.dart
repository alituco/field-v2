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
    PaymentCollector? paymentCollector,
    Future<void> Function(Duration)? delay,
    this.confirmationAttempts = 12,
    this.pollInterval = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 30),
    this.confirmationTimeout = const Duration(seconds: 45),
  }) : _client = client,
       _functionInvoker = functionInvoker,
       _sheetPresenter = sheetPresenter ?? _presentStripeSheet,
       _paymentCollector = paymentCollector,
       _hasInjectedPresenter = sheetPresenter != null,
       _delay = delay ?? Future<void>.delayed;

  final SupabaseClient? _client;
  final PaymentFunctionInvoker? _functionInvoker;
  final PaymentSheetPresenter _sheetPresenter;
  final PaymentCollector? _paymentCollector;
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

  /// Rechecks one already-paid attempt. Never prepares or collects a payment.
  Future<PaymentRefundState> checkRefundStatus(String intentId) async {
    final id = _requiredString(intentId);
    final response = await _invoke({'action': 'confirm', 'intent_id': id});
    if (response['intent_id'] != null && response['intent_id'] != id) {
      throw const PaymentPendingException();
    }
    final status = _status(response);
    if (status != 'REQUIRES_REFUND' && status != 'REFUNDED') {
      // A stale/unknown response never makes this paid attempt chargeable again.
      throw const PaymentPendingException();
    }
    return PaymentRefundState(
      intentId: id,
      status: status,
      refundStatus: response['refund_status']?.toString().toUpperCase(),
    );
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
    final clientSecret = _requiredString(preparation['client_secret']);
    try {
      final collector = _paymentCollector;
      if (collector != null) {
        final amount = preparation['amount_fils'];
        final currency = preparation['currency'];
        if (amount is! int || currency is! String) {
          throw const PaymentException('Checkout returned an invalid total.');
        }
        await collector(
          PaymentCollectionRequest(
            clientSecret: clientSecret,
            amountFils: amount,
            currency: currency,
          ),
        );
      } else {
        if (!_hasInjectedPresenter) _validateConfiguration();
        await _sheetPresenter(clientSecret);
      }
    } on PaymentQuoteChangedException catch (error) {
      return _cancelAndReconcile(intentId, error);
    } on PaymentCancelledException catch (error) {
      return _cancelAndReconcile(intentId, error);
    }
    return _confirm(intentId);
  }

  Future<PaymentResult> _cancelAndReconcile(
    String intentId,
    PaymentException reason,
  ) async {
    // Both abandoning checkout and rejecting a changed quote can race a
    // successful payment. Only an authoritative cancellation permits a fresh
    // checkout; transport/validation failures here remain ambiguous.
    final Map<String, dynamic> cancellation;
    try {
      cancellation = await _invoke({'action': 'cancel', 'intent_id': intentId});
    } catch (_) {
      throw const PaymentPendingException();
    }
    if (_status(cancellation) == 'FINALIZED') {
      try {
        return _finalized(cancellation);
      } on PaymentException {
        throw const PaymentPendingException();
      }
    }
    _throwCancellationTerminal(cancellation, reason, intentId: intentId);
    return _confirm(intentId, cancellationReason: reason);
  }

  Future<PaymentResult> _confirm(
    String intentId, {
    PaymentException? cancellationReason,
  }) async {
    final elapsed = Stopwatch()..start();
    for (var attempt = 0; attempt < confirmationAttempts; attempt++) {
      final remaining = confirmationTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) break;
      try {
        final Map<String, dynamic> response;
        try {
          response = await _invoke({
            'action': 'confirm',
            'intent_id': intentId,
          }, timeout: remaining < requestTimeout ? remaining : requestTimeout);
          if (_status(response) == 'FINALIZED') return _finalized(response);
        } on PaymentException {
          // Authentication, transport, and malformed responses cannot establish
          // that Stripe did not charge. Only explicit server terminal statuses
          // below may release this attempt from the reconciliation path.
          throw const PaymentPendingException();
        }
        if (cancellationReason != null) {
          _throwCancellationTerminal(
            response,
            cancellationReason,
            intentId: intentId,
          );
        } else {
          _throwTerminal(response, intentId: intentId);
        }
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

  /// Applies the same guarded native configuration to embedded and sheet flows.
  static Future<void> configureNativePayments() async {
    _validateConfiguration();
    Stripe.publishableKey = _publishableKey;
    Stripe.merchantIdentifier = _appleMerchantId;
    Stripe.urlScheme = _returnScheme;
    await Stripe.instance.applySettings();
  }

  /// Shared appearance and wallet configuration, deliberately without a secret.
  static SetupPaymentSheetParameters
  get nativeSheetConfiguration => SetupPaymentSheetParameters(
    merchantDisplayName: 'Fieldrush',
    returnURL: '$_returnScheme://safepay',
    allowsDelayedPaymentMethods: false,
    applePay: _appleMerchantId.isEmpty
        ? null
        : const PaymentSheetApplePay(merchantCountryCode: 'US'),
    googlePay: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const PaymentSheetGooglePay(
            merchantCountryCode: 'US',
            currencyCode: 'USD',
            // Match the Stripe key guard: only production uses live wallets.
            testEnv: _environment != 'production',
            buttonType: PlatformButtonType.pay,
          )
        : null,
    style: ThemeMode.light,
    appearance: fieldrushPaymentSheetAppearance,
  );

  /// This only skips native collection; the existing server E2E gate remains.
  static bool get stagingE2EBypass =>
      _stagingE2EPaymentBypass &&
      (_environment == 'staging' || _environment == 'local');

  static Future<void> _presentStripeSheet(String clientSecret) async {
    try {
      await configureNativePayments();
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: nativeSheetConfiguration.copyWith(
          paymentIntentClientSecret: clientSecret,
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

  static void _throwTerminal(
    Map<String, dynamic> response, {
    String? intentId,
  }) {
    switch (_status(response)) {
      case 'CANCELLED':
        throw const PaymentCancelledException();
      case 'REFUNDED':
      case 'REQUIRES_REFUND':
        throw PaymentRefundException(
          PaymentRefundState(
            intentId: _requiredString(intentId ?? response['intent_id']),
            status: _status(response),
            refundStatus: response['refund_status']?.toString().toUpperCase(),
          ),
        );
      case 'FAILED':
      case 'EXPIRED':
        throw const PaymentException(
          'This payment was not completed. Please try again.',
        );
    }
  }

  static void _throwCancellationTerminal(
    Map<String, dynamic> response,
    PaymentException reason, {
    String? intentId,
  }) {
    switch (_status(response)) {
      case 'CANCELLED':
        throw reason;
      case 'FAILED':
      case 'EXPIRED':
        // These are not confirmation that the requested cancellation reached
        // Stripe. Do not turn an ambiguous cancellation into a new charge.
        throw const PaymentPendingException();
      default:
        _throwTerminal(response, intentId: intentId);
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
typedef PaymentCollector =
    Future<void> Function(PaymentCollectionRequest request);

/// The immutable, server-prepared total supplied only after an explicit pay.
class PaymentCollectionRequest {
  factory PaymentCollectionRequest({
    required String clientSecret,
    required int amountFils,
    required String currency,
  }) {
    final normalizedCurrency = currency.trim().toUpperCase();
    if (clientSecret.trim().isEmpty ||
        normalizedCurrency != 'USD' ||
        amountFils <= 0 ||
        amountFils % 10 != 0 ||
        amountFils ~/ 10 > 99999999) {
      throw const PaymentException('Checkout returned an invalid total.');
    }
    return PaymentCollectionRequest._(
      clientSecret: clientSecret,
      amountFils: amountFils,
      currency: normalizedCurrency,
      amountMinor: amountFils ~/ 10,
    );
  }

  const PaymentCollectionRequest._({
    required this.clientSecret,
    required this.amountFils,
    required this.currency,
    required this.amountMinor,
  });

  final String clientSecret;
  final int amountFils;
  final String currency;
  final int amountMinor;
}

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

class PaymentRefundState {
  const PaymentRefundState({
    required this.intentId,
    required this.status,
    this.refundStatus,
  }) : assert(status == 'REQUIRES_REFUND' || status == 'REFUNDED');

  final String intentId;
  final String status;
  final String? refundStatus;
  bool get isRefunded => status == 'REFUNDED';
  bool get needsReview => !isRefunded && refundStatus == 'FAILED';
  String get message => isRefunded
      ? 'Your spot could not be booked. Your payment has been refunded to your original payment method. Your bank may take time to show it.'
      : needsReview
      ? 'Your spot could not be booked and the refund needs support review. Keep the payment reference below when contacting support. Do not pay again.'
      : 'Your payment was received, but your spot could not be booked. A refund to your original payment method is being processed. Do not pay again.';
}

class PaymentRefundException extends PaymentException {
  PaymentRefundException(this.refund) : super(refund.message);
  final PaymentRefundState refund;
  String get intentId => refund.intentId;
  String get status => refund.status;
}

class PaymentQuoteChangedException extends PaymentException {
  const PaymentQuoteChangedException()
    : super(
        'Your booking total changed. Review the updated total, then confirm again.',
      );
}

class PaymentPendingException extends PaymentException {
  const PaymentPendingException()
    : super(
        'We are still checking this payment. Check your bookings shortly. '
        'Trying again will check the same payment before asking you to pay.',
      );
}
