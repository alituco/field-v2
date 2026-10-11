import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import 'payment_service.dart';

typedef FieldrushEmbeddedPaymentSessionFactory =
    FieldrushEmbeddedPaymentSession Function({
      required int amountFils,
      required String currency,
    });

/// Owns native payment collection, but never prepares or cancels a server intent.
abstract class FieldrushEmbeddedPaymentSession extends ChangeNotifier {
  bool get isReady;
  bool get hasSelection;
  String? get loadingError;
  Future<void> initialize();
  Widget buildView();
  Future<void> collectPayment(PaymentCollectionRequest request);
  Future<void> close();
}

class StripeFieldrushEmbeddedPaymentSession
    extends FieldrushEmbeddedPaymentSession {
  StripeFieldrushEmbeddedPaymentSession({
    required this.amountFils,
    required String currency,
    @visibleForTesting EmbeddedPaymentElementController? controller,
    @visibleForTesting Future<void> Function()? configureNativePayments,
    @visibleForTesting
    Future<void> Function(IntentCreationCallbackParams)? intentCreationCallback,
    @visibleForTesting Duration loadTimeout = const Duration(seconds: 20),
  }) : currency = currency.trim().toUpperCase(),
       _controller = controller ?? EmbeddedPaymentElementController(),
       _configureNativePayments =
           configureNativePayments ?? PaymentService.configureNativePayments,
       _intentCreationCallback =
           intentCreationCallback ?? Stripe.instance.intentCreationCallback,
       _loadTimeout = loadTimeout;

  // Flutter Stripe routes handlers and native embedded events globally. A second
  // view must not replace those handlers while the first one is still mounted.
  static StripeFieldrushEmbeddedPaymentSession? _owner;

  final int amountFils;
  final String currency;
  final EmbeddedPaymentElementController _controller;
  final Future<void> Function() _configureNativePayments;
  final Future<void> Function(IntentCreationCallbackParams)
  _intentCreationCallback;
  final Duration _loadTimeout;

  Future<void>? _initialization;
  Future<void>? _closing;
  Timer? _loadTimer;
  Widget? _view;
  _CollectionAttempt? _attempt;
  bool _configured = false;
  bool _loaded = false;
  bool _selected = false;
  bool _closed = false;
  bool _isClosing = false;
  bool _disposed = false;
  bool _consumed = false;
  bool _indeterminate = false;
  bool _callbackResponded = false;
  String? _loadingError;

  @override
  bool get isReady =>
      _configured &&
      _loaded &&
      _loadingError == null &&
      !_closed &&
      !_isClosing &&
      !_consumed &&
      !_indeterminate;

  @override
  bool get hasSelection => _selected && isReady;

  @override
  String? get loadingError => _loadingError;

  @override
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (_closed || _disposed) return;
    if (currency != 'USD' ||
        amountFils <= 0 ||
        amountFils % 10 != 0 ||
        amountFils ~/ 10 > 99999999) {
      _failLoading('Checkout returned an invalid total.');
      return;
    }
    if (_owner != null && !identical(_owner, this)) {
      _failLoading('Another checkout is open. Close it and try again.');
      return;
    }
    _owner = this;
    try {
      await _configureNativePayments().timeout(_loadTimeout);
      if (_closed || _disposed || _isClosing) return;
      _configured = true;
      _view = EmbeddedPaymentElement(
        controller: _controller,
        intentConfiguration: IntentConfiguration(
          mode: IntentMode.paymentMode(
            amount: amountFils ~/ 10,
            currencyCode: currency,
            captureMethod: CaptureMethod.Automatic,
          ),
          paymentMethodTypes: const ['card'],
          confirmHandler: (_, _) => _respondToConfirmation(),
        ),
        configuration: PaymentService.nativeSheetConfiguration.copyWith(
          linkDisplayParams: const LinkDisplayParams(
            linkDisplay: LinkDisplay.never,
          ),
        ),
        onPaymentOptionChanged: _onPaymentOptionChanged,
        onHeightChanged: _onHeightChanged,
        onLoadingFailed: (_) => _failLoading(_loadFailureMessage),
        // Normal controller.confirm() also emits onFormSheetConfirmComplete.
        // Handle only its Future so a successful charge is never processed twice.
      );
      _loadTimer = Timer(_loadTimeout, () => _failLoading(_loadFailureMessage));
      _notify();
    } catch (_) {
      _failLoading(_loadFailureMessage);
    }
  }

  static const _loadFailureMessage =
      'Payment methods could not load. Please try again.';

  @override
  Widget buildView() => _closed || _disposed
      ? const SizedBox.shrink()
      : _view ?? const SizedBox.shrink();

  void _onPaymentOptionChanged(PaymentSheetPaymentOption? option) {
    if (!_acceptNativeEvents) return;
    _selected = option != null;
    if (_selected) _markLoaded();
    _notify();
  }

  void _onHeightChanged(double height) {
    // Android emits a 1dp configuration sentinel before actual content exists.
    if (!_acceptNativeEvents || !height.isFinite || height <= 1) return;
    _markLoaded();
    _notify();
  }

  bool get _acceptNativeEvents =>
      !_closed && !_disposed && !_isClosing && _loadingError == null;

  void _markLoaded() {
    _loaded = true;
    _loadTimer?.cancel();
    _loadTimer = null;
  }

  void _failLoading(String message) {
    if (_closed || _disposed || _isClosing) return;
    _loadTimer?.cancel();
    _loadTimer = null;
    _loadingError = message;
    _loaded = false;
    _selected = false;
    _notify();
  }

  @override
  Future<void> collectPayment(PaymentCollectionRequest request) async {
    // Reject a changed server quote before supplying any client secret to Stripe.
    if (request.amountFils != amountFils || request.currency != currency) {
      throw const PaymentQuoteChangedException();
    }
    if (_attempt != null || _indeterminate || _consumed || _closed) {
      throw const PaymentPendingException();
    }
    if (!isReady || !hasSelection) {
      throw const PaymentException('Select a payment method to continue.');
    }

    final attempt = _CollectionAttempt(request);
    _attempt = attempt;
    _callbackResponded = false;
    try {
      // There is intentionally no Dart timeout while native authentication is
      // active. Losing a callback must not permit starting another charge.
      unawaited(_confirm(attempt));
      final result = await attempt.result.future;
      switch (result?['status']) {
        case 'completed':
          _consumed = true;
          return;
        case 'canceled':
          throw const PaymentCancelledException();
        case 'failed':
          throw const PaymentException(
            'Payment could not be completed. Please try another card.',
          );
        default:
          _markIndeterminate();
          throw const PaymentPendingException();
      }
    } on PaymentException {
      rethrow;
    } catch (_) {
      _markIndeterminate();
      throw const PaymentPendingException();
    } finally {
      if (identical(_attempt, attempt)) _attempt = null;
      _notify();
    }
  }

  Future<void> _confirm(_CollectionAttempt attempt) async {
    try {
      final result = await _controller.confirm();
      if (!attempt.result.isCompleted) attempt.result.complete(result);
    } catch (_) {
      _markIndeterminate();
      if (!attempt.result.isCompleted) {
        attempt.result.completeError(const PaymentPendingException());
      }
    }
  }

  void _respondToConfirmation() {
    if (_callbackResponded) return;
    _callbackResponded = true;
    final attempt = _attempt;
    final request = attempt?.request;
    final response = request == null
        ? const IntentCreationCallbackParams(
            error: StripeException(
              error: LocalizedErrorMessage(
                code: FailureCode.Failed,
                message: 'Please return to checkout and try again.',
                localizedMessage: 'Please return to checkout and try again.',
              ),
            ),
          )
        : IntentCreationCallbackParams(clientSecret: request.clientSecret);
    // Android can leave this acknowledgement pending even when confirmation
    // succeeds. Only the controller result drives checkout completion.
    unawaited(_deliverResponse(response, attempt));
  }

  Future<void> _deliverResponse(
    IntentCreationCallbackParams response,
    _CollectionAttempt? attempt,
  ) async {
    try {
      await _intentCreationCallback(response);
    } catch (_) {
      if (attempt != null && !attempt.result.isCompleted) {
        _markIndeterminate();
        attempt.result.completeError(const PaymentPendingException());
      }
    }
  }

  void _markIndeterminate() {
    _indeterminate = true;
    _selected = false;
    _loadingError =
        'Payment connection interrupted. Reload payment methods to check this payment.';
  }

  @override
  Future<void> close() {
    _isClosing = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    _loadTimer?.cancel();
    _loadTimer = null;
    _notify();
    try {
      await _initialization;
      final attempt = _attempt;
      if (attempt != null) {
        try {
          await attempt.result.future;
        } catch (_) {
          // Closing the UI does not cancel or change the server payment state.
        }
      }
      await _controller.disposeView();
    } catch (_) {
      // The checkout removes the widget after close even if native teardown
      // reports a transport error. Never strand navigation or cancel an intent.
    } finally {
      _closed = true;
      _selected = false;
      _view = null;
      if (identical(_owner, this)) _owner = null;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Callers normally await close before removing the widget. This fallback
    // still releases ownership if a route is removed unexpectedly.
    unawaited(
      close().then<void>(
        (_) => _controller.dispose(),
        onError: (Object _, StackTrace _) => _controller.dispose(),
      ),
    );
    super.dispose();
  }
}

class _CollectionAttempt {
  _CollectionAttempt(this.request);

  final PaymentCollectionRequest request;
  final Completer<Map<String, dynamic>?> result = Completer();
}
