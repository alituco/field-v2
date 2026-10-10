import 'dart:async';
import 'dart:convert';

import 'package:checkout_flutter/checkout_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Runs Tap's native checkout, then asks Field's server to retrieve and verify
/// the charge before any booking is treated as paid.
class TapPaymentService {
  TapPaymentService({
    SupabaseClient? client,
    TapFunctionInvoker? functionInvoker,
    TapCheckoutStarter? checkoutStarter,
  }) : _client = client,
       _functionInvoker = functionInvoker,
       _checkoutStarter = checkoutStarter ?? startCheckout;

  final SupabaseClient? _client;
  final TapFunctionInvoker? _functionInvoker;
  final TapCheckoutStarter _checkoutStarter;

  Future<TapPaymentResult> pay({
    required TapPaymentPurpose purpose,
    required Map<String, dynamic> payload,
  }) async {
    if (_stagingE2EPaymentBypass) {
      final confirmation = await _invoke({
        'action': 'complete_staging_e2e',
        'purpose': purpose.code,
        'payload': payload,
        'run_id': _stagingE2ERunId,
      });
      return TapPaymentResult(
        intentId: _requiredString(
          confirmation['intent_id'],
          'Field did not return a payment attempt.',
        ),
        chargeId: _requiredString(
          confirmation['charge_id'],
          'Field did not return a payment reference.',
        ),
        resourceType: _requiredString(
          confirmation['resource_type'],
          'Field did not return the paid booking type.',
        ),
        resourceId: _requiredString(
          confirmation['resource_id'],
          'Field did not return the paid booking.',
        ),
        paymentMethod: confirmation['payment_method']?.toString() ?? 'CARD',
      );
    }

    final preparation = await _invoke({
      'action': 'prepare',
      'purpose': purpose.code,
      'payload': payload,
    });
    final intentId = _requiredString(
      preparation['intent_id'],
      'Field did not return a payment attempt.',
    );
    final capturedChargeId = preparation['captured_charge_id']
        ?.toString()
        .trim();
    late final String chargeId;
    if (capturedChargeId != null && capturedChargeId.isNotEmpty) {
      chargeId = capturedChargeId;
    } else {
      final configuration = preparation['configuration'];
      if (configuration is! Map) {
        throw const TapPaymentException(
          'Field did not return a valid checkout.',
        );
      }
      chargeId = await _openCheckout(Map<String, dynamic>.from(configuration));
    }

    final confirmation = await _invoke({
      'action': 'confirm',
      'intent_id': intentId,
      'charge_id': chargeId,
    });
    return TapPaymentResult(
      intentId: intentId,
      chargeId: chargeId,
      resourceType: _requiredString(
        confirmation['resource_type'],
        'Field did not return the paid booking type.',
      ),
      resourceId: _requiredString(
        confirmation['resource_id'],
        'Field did not return the paid booking.',
      ),
      paymentMethod: confirmation['payment_method']?.toString() ?? 'CARD',
    );
  }

  Future<String> _openCheckout(Map<String, dynamic> configuration) async {
    final result = Completer<String>();
    var terminalCallbackReceived = false;

    void completeError(String message) {
      if (result.isCompleted) return;
      terminalCallbackReceived = true;
      result.completeError(TapPaymentException(message));
    }

    final started = await _checkoutStarter(
      configurations: configuration,
      onReady: () {},
      onSuccess: (data) {
        if (result.isCompleted) return;
        terminalCallbackReceived = true;
        try {
          final decoded = jsonDecode(data);
          if (decoded is! Map) {
            throw const FormatException('Invalid Tap response.');
          }
          final chargeId =
              decoded['chargeId'] ?? decoded['chargeID'] ?? decoded['id'];
          result.complete(
            _requiredString(
              chargeId,
              'Tap did not return a payment reference.',
            ),
          );
        } catch (_) {
          completeError(
            'Tap completed checkout but returned an invalid payment reference.',
          );
        }
      },
      onError: (error) {
        if (kDebugMode) {
          debugPrint('Tap checkout SDK error: $error');
        }
        completeError(_tapErrorMessage(error));
      },
      onCancel: () {
        completeError('Payment was cancelled.');
      },
      onClose: () {
        // Tap documents that close also fires after success/error. Only treat
        // an early close as cancellation when no terminal callback arrived.
        if (!terminalCallbackReceived) {
          completeError('Payment was cancelled.');
        }
      },
    );
    if (!started) {
      throw const TapPaymentException(
        'Tap checkout could not open. Try again.',
      );
    }
    return result.future.timeout(
      const Duration(minutes: 10),
      onTimeout: () => throw const TapPaymentException(
        'Payment timed out. Check your bookings before trying again.',
      ),
    );
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    final injectedInvoker = _functionInvoker;
    if (injectedInvoker != null) return injectedInvoker(body);
    try {
      final response = await (_client ?? Supabase.instance.client).functions
          .invoke('tap-payment', body: body);
      final data = response.data;
      if (data is! Map) {
        throw const TapPaymentException(
          'Field returned an invalid payment response.',
        );
      }
      return Map<String, dynamic>.from(data);
    } on FunctionException catch (error) {
      final details = error.details;
      final message = details is Map && details['error'] is String
          ? details['error'] as String
          : 'Payment could not be completed. Try again.';
      throw TapPaymentException(message);
    }
  }

  static String _requiredString(Object? value, String message) {
    final normalized = value?.toString().trim();
    if (normalized == null || normalized.isEmpty) {
      throw TapPaymentException(message);
    }
    return normalized;
  }

  static String _tapErrorMessage(String raw) {
    final normalized = raw.toLowerCase();
    if (normalized.contains('cancel')) return 'Payment was cancelled.';
    if (normalized.contains('declin')) {
      return 'Payment was declined. Try another payment method.';
    }
    if (normalized.contains('network') || normalized.contains('connection')) {
      return 'Tap could not connect. Check your internet and try again.';
    }
    return 'Tap could not complete the payment. Try another method.';
  }
}

const _stagingE2EPaymentBypass = bool.fromEnvironment(
  'FIELD_E2E_PAYMENT_BYPASS',
);
const _stagingE2ERunId = String.fromEnvironment('E2E_RUN_ID');

typedef TapFunctionInvoker =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> body);

typedef TapCheckoutStarter =
    Future<bool> Function({
      required Map<String, dynamic> configurations,
      Function()? onClose,
      Function()? onReady,
      Function(String)? onSuccess,
      Function(String)? onError,
      Function()? onCancel,
    });

enum TapPaymentPurpose {
  soloBooking('SOLO_BOOKING'),
  clanCreate('CLAN_CREATE'),
  clanJoin('CLAN_JOIN');

  const TapPaymentPurpose(this.code);
  final String code;
}

class TapPaymentResult {
  const TapPaymentResult({
    required this.intentId,
    required this.chargeId,
    required this.resourceType,
    required this.resourceId,
    required this.paymentMethod,
  });

  final String intentId;
  final String chargeId;
  final String resourceType;
  final String resourceId;
  final String paymentMethod;
}

class TapPaymentException implements Exception {
  const TapPaymentException(this.message);
  final String message;

  @override
  String toString() => message;
}
