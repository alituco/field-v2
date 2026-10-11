import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../payments/fieldrush_embedded_payment.dart';
import '../payments/payment_service.dart';
import 'fieldrush_booking_widgets.dart';
import 'open_queue.dart';
import 'open_queue_repository.dart';

/// Fieldrush review sheet with native, embedded payment-method selection.
/// Never show a simulated card/wallet or confirm based on a client-only event.
class FieldrushCheckoutSheet extends StatefulWidget {
  const FieldrushCheckoutSheet({
    super.key,
    required this.repository,
    required this.game,
    required this.role,
    this.embeddedPaymentSessionFactory,
  });
  final OpenQueueRepository repository;
  final OpenQueueGame game;
  final OpenQueueRole role;
  final FieldrushEmbeddedPaymentSessionFactory? embeddedPaymentSessionFactory;

  @override
  State<FieldrushCheckoutSheet> createState() => _FieldrushCheckoutSheetState();
}

class _FieldrushCheckoutSheetState extends State<FieldrushCheckoutSheet> {
  OpenQueueBookingCostPreview? _preview;
  bool _loading = true;
  bool _processing = false;
  String? _error;
  bool _resumePayment = false;
  bool _paymentSubmitted = false;
  FieldrushEmbeddedPaymentSession? _paymentSession;
  bool _allowPop = false;
  bool _closing = false;
  int _loadGeneration = 0;

  bool get _embedded =>
      widget.repository is OpenQueueEmbeddedCheckoutRepository &&
      !PaymentService.stagingE2EBypass;

  bool get _canPay =>
      !_loading &&
      !_processing &&
      !_closing &&
      _preview != null &&
      (!_embedded ||
          _preview!.totalFils == 0 ||
          _resumePayment ||
          (_paymentSession?.isReady == true &&
              _paymentSession?.hasSelection == true));

  Future<OpenQueueBooking?> _confirmedBooking() async {
    final repository = widget.repository;
    final bookings = repository is OpenQueueBookingLookupRepository
        ? [
            await (repository as OpenQueueBookingLookupRepository)
                .getMyUpcomingBookingForGame(widget.game.id),
          ]
        : await repository.getMyUpcomingBookings();
    for (final booking in bookings) {
      if (booking?.gameId == widget.game.id && booking?.status == 'CONFIRMED') {
        return booking;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _loadGeneration++;
    _paymentSession?.removeListener(_paymentChanged);
    _paymentSession?.dispose();
    super.dispose();
  }

  void _paymentChanged() {
    if (mounted && !_closing) setState(() {});
  }

  Future<void> _replacePaymentSession(
    OpenQueueBookingCostPreview preview,
    int generation,
  ) async {
    final old = _paymentSession;
    if (old != null) {
      old.removeListener(_paymentChanged);
      await old.close();
      if (!mounted) return;
      setState(() {
        _paymentSession = null;
        _paymentSubmitted = false;
      });
      // Unmount the old native widget (and its global callbacks) before another
      // embedded selector attaches. Rebuilding with a new price is not enough.
      await WidgetsBinding.instance.endOfFrame;
      old.dispose();
    }
    if (!mounted || generation != _loadGeneration) return;
    if (!_embedded || preview.totalFils == 0) return;
    final factory =
        widget.embeddedPaymentSessionFactory ??
        StripeFieldrushEmbeddedPaymentSession.new;
    final session = factory(
      amountFils: preview.totalFils,
      currency: preview.currency,
    );
    session.addListener(_paymentChanged);
    setState(() => _paymentSession = session);
    await session.initialize();
  }

  Future<void> _retryPaymentSelection() async {
    final preview = _preview;
    if (preview == null || _processing || _closing || _loading) return;
    final generation = ++_loadGeneration;
    setState(() => _loading = true);
    try {
      await _replacePaymentSession(preview, generation);
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = 'Payment options could not load. Try again.');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _close([OpenQueueBooking? booking]) async {
    if (_closing || (_processing && booking == null)) return;
    _closing = true;
    await _paymentSession?.close();
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(booking);
  }

  Future<OpenQueueBookingCostPreview> _quote() async {
    final repository = widget.repository;
    if (repository is! OpenQueueBookingCostPreviewRepository) {
      throw StateError(
        'Your exact booking total is unavailable. Please try again.',
      );
    }
    final result = await (repository as OpenQueueBookingCostPreviewRepository)
        .previewBookingCost(gameId: widget.game.id, role: widget.role);
    if (result.currency != 'USD' ||
        result.totalFils < 0 ||
        result.totalFils % 10 != 0) {
      throw StateError('This game is not available for USD checkout.');
    }
    return result;
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _preview = null;
    });
    try {
      final preview = await _quote();
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _preview = preview);
      await _replacePaymentSession(preview, generation);
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Could not verify your booking total. Try again.',
          ),
        );
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _pay() async {
    final shown = _preview;
    if (!_canPay || shown == null) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      if (_resumePayment) {
        final recovered = await _confirmedBooking();
        if (!mounted) return;
        if (recovered != null) {
          await _close(recovered);
          return;
        }
      } else {
        final latest = await _quote();
        if (!mounted) return;
        if (!shown.hasSameCheckoutTermsAs(latest)) {
          setState(() {
            _preview = latest;
            _error =
                'Your booking terms changed. Review the updated total and deposit, then confirm again.';
          });
          await _replacePaymentSession(latest, ++_loadGeneration);
          return;
        }
      }
      // Keep the same game/role when resuming an ambiguous payment. The payment
      // service recovers its existing intent before quoting a new reservation;
      // quoting first would reject a now-full or already-booked game.
      _resumePayment = true;
      final repository = widget.repository;
      final booking = _embedded
          ? await (repository as OpenQueueEmbeddedCheckoutRepository)
                .bookGameWithCollector(
                  game: widget.game,
                  role: widget.role,
                  collectPayment: (request) async {
                    // Check again against the authoritative prepared intent.
                    // A price race must never confirm an unseen amount.
                    if (request.amountFils != shown.totalFils ||
                        request.currency != shown.currency) {
                      throw const PaymentQuoteChangedException();
                    }
                    final session = _paymentSession;
                    if (session == null ||
                        !session.isReady ||
                        !session.hasSelection) {
                      throw const PaymentPendingException();
                    }
                    await session.collectPayment(request);
                    if (mounted) setState(() => _paymentSubmitted = true);
                  },
                )
          : await repository.bookGame(
              game: widget.game,
              role: widget.role,
              paymentMethod: 'STRIPE',
            );
      if (!mounted) return;
      // bookGame returns only after server-side payment verification and an
      // actual booking lookup. A native-sheet success is not enough.
      if (booking.status != 'CONFIRMED' || booking.gameId != widget.game.id) {
        throw StateError(
          'Your payment is being checked. Please check your games before trying again.',
        );
      }
      await _close(booking);
    } catch (error) {
      if (_resumePayment) {
        try {
          final recovered = await _confirmedBooking();
          if (!mounted) return;
          if (recovered != null) {
            await _close(recovered);
            return;
          }
        } catch (_) {
          // Preserve the original error and the idempotent retry path if the
          // booking lookup is also temporarily unavailable.
        }
        if (!_paymentSubmitted &&
            error is PaymentException &&
            error is! PaymentPendingException) {
          _resumePayment = false;
        }
      }
      if (error is PaymentQuoteChangedException) {
        // The service only returns this after the superseded attempt is safely
        // cancelled. Reload terms and native configuration, then require Pay.
        await _load();
      }
      if (mounted) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Payment could not be completed. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Widget _embeddedPaymentOptions() {
    final session = _paymentSession;
    final error = session?.loadingError;
    if (error != null) {
      return BookingPanel(
        padding: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Payment options unavailable', style: bookingHeading(16)),
            const SizedBox(height: 6),
            Text(error, style: bookingText(12)),
            TextButton(
              key: const ValueKey('retry-payment-options'),
              onPressed: _processing || _loading
                  ? null
                  : _retryPaymentSelection,
              child: const Text('Retry payment options'),
            ),
          ],
        ),
      );
    }
    if (session == null) return const _PaymentOptionsSkeleton();
    return AbsorbPointer(
      absorbing: _processing || _closing || _paymentSubmitted,
      child: Stack(
        children: [
          Opacity(
            opacity: session.isReady || _paymentSubmitted ? 1 : 0,
            child: session.buildView(),
          ),
          if (!session.isReady && !_paymentSubmitted)
            const _PaymentOptionsSkeleton(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: PopScope<OpenQueueBooking>(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && !_processing && !_closing) _close();
        },
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .9,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFDED8C6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Confirm and pay',
                          style: bookingHeading(24),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close checkout',
                        onPressed: _processing || _closing ? null : _close,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  BookingPanel(
                    padding: 14,
                    child: Row(
                      children: [
                        BookingDateBadge(game: widget.game),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.game.calendarDateLabel,
                                style: bookingHeading(18),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                '${widget.game.startTimeLabel} · ${widget.game.venue}',
                                style: bookingText(11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text('YOUR POSITION', style: bookingText(10, bold: true)),
                  const SizedBox(height: 9),
                  BookingPanel(
                    padding: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bookingRoleName(widget.role),
                          style: bookingHeading(16),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${widget.game.spotsFor(widget.role)} spots open · availability checked at payment',
                          style: bookingText(11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (!_embedded || preview?.totalFils != 0) ...[
                    Text('PAY WITH', style: bookingText(10, bold: true)),
                    const SizedBox(height: 9),
                    if (_embedded)
                      _embeddedPaymentOptions()
                    else
                      BookingPanel(
                        padding: 16,
                        child: Row(
                          children: [
                            const Icon(
                              Icons.credit_card,
                              color: FieldrushAuthTheme.ink,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Card or Apple Pay',
                                    style: bookingText(
                                      13,
                                      color: FieldrushAuthTheme.ink,
                                      bold: true,
                                    ),
                                  ),
                                  Text(
                                    'Choose securely in the app. Apple Pay appears on supported devices.',
                                    style: bookingText(11),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.lock_outline,
                              size: 18,
                              color: FieldrushAuthTheme.muted,
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  if (_loading && preview == null)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (preview != null) ...[
                    BookingValueRow('Match fee', preview.standardMatchFeeLabel),
                    if (preview.discountAmountFils > 0)
                      BookingValueRow(
                        'Replacement discount (${preview.discountPercent}%)',
                        '−${preview.discountLabel}',
                      ),
                    if (preview.reliabilityDepositRequired) ...[
                      BookingValueRow(
                        'Refundable reliability deposit',
                        preview.depositLabel,
                      ),
                      Text(
                        'Returned to your original payment method when the policy’s attendance conditions are met.',
                        style: bookingText(11),
                      ),
                    ],
                    const Divider(color: FieldrushAuthTheme.border),
                    BookingValueRow(
                      'Total',
                      preview.totalLabel,
                      emphasized: true,
                    ),
                  ],
                  const SizedBox(height: 9),
                  Text(
                    'Cancellation refunds follow the game’s policy and return to your original payment method. Review the exact refund before cancelling.',
                    style: bookingText(11),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: bookingText(
                          12,
                          color: FieldrushAuthTheme.danger,
                        ),
                      ),
                    ),
                    if (_preview == null)
                      TextButton(
                        onPressed: _processing ? null : _load,
                        child: const Text('Retry price check'),
                      ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('open-queue-confirm-payment'),
                    onPressed: _canPay ? _pay : null,
                    child: _processing
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(width: 10),
                              Text('Processing…'),
                            ],
                          )
                        : Text(
                            _embedded
                                ? preview?.totalFils == 0
                                      ? 'Confirm booking'
                                      : '${_resumePayment ? 'Resume payment' : 'Pay'}${preview == null ? '' : ' · ${preview.totalLabel}'}'
                                : 'Continue to Pay${preview == null ? '' : ' · ${preview.totalLabel}'}',
                          ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Secure payments by Stripe',
                    textAlign: TextAlign.center,
                    style: bookingText(10),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaymentOptionsSkeleton extends StatelessWidget {
  const _PaymentOptionsSkeleton();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading secure payment options',
    liveRegion: true,
    child: ExcludeSemantics(
      child: Column(
        children: [
          for (var index = 0; index < 2; index++)
            Container(
              height: 55,
              margin: EdgeInsets.only(bottom: index == 0 ? 8 : 0),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: FieldrushAuthTheme.border),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 18,
                    decoration: BoxDecoration(
                      color: FieldrushAuthTheme.watermark,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 104,
                    height: 12,
                    decoration: BoxDecoration(
                      color: FieldrushAuthTheme.watermark,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
