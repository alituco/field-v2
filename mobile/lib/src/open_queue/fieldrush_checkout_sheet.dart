import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../payments/payment_service.dart';
import 'fieldrush_booking_widgets.dart';
import 'open_queue.dart';
import 'open_queue_repository.dart';

/// Fieldrush review sheet; card collection remains in Stripe's native sheet.
/// Never show a simulated card/wallet or confirm based on a client-only event.
class FieldrushCheckoutSheet extends StatefulWidget {
  const FieldrushCheckoutSheet({
    super.key,
    required this.repository,
    required this.game,
    required this.role,
  });
  final OpenQueueRepository repository;
  final OpenQueueGame game;
  final OpenQueueRole role;

  @override
  State<FieldrushCheckoutSheet> createState() => _FieldrushCheckoutSheetState();
}

class _FieldrushCheckoutSheetState extends State<FieldrushCheckoutSheet> {
  OpenQueueBookingCostPreview? _preview;
  bool _loading = true;
  bool _processing = false;
  String? _error;
  bool _resumePayment = false;

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

  Future<OpenQueueBookingCostPreview> _quote() async {
    final repository = widget.repository;
    if (repository is! OpenQueueBookingCostPreviewRepository) {
      throw StateError(
        'Your exact booking total is unavailable. Please try again.',
      );
    }
    final result = await (repository as OpenQueueBookingCostPreviewRepository)
        .previewBookingCost(gameId: widget.game.id, role: widget.role);
    if (result.currency != 'USD' || result.totalFils < 0) {
      throw StateError('This game is not available for USD checkout.');
    }
    return result;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _preview = null;
    });
    try {
      final preview = await _quote();
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Could not verify your booking total. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pay() async {
    final shown = _preview;
    if (_processing || _loading || shown == null) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      if (_resumePayment) {
        final recovered = await _confirmedBooking();
        if (!mounted) return;
        if (recovered != null) {
          Navigator.of(context).pop(recovered);
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
          return;
        }
      }
      // Keep the same game/role when resuming an ambiguous payment. The payment
      // service recovers its existing intent before quoting a new reservation;
      // quoting first would reject a now-full or already-booked game.
      _resumePayment = true;
      final booking = await widget.repository.bookGame(
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
      Navigator.of(context).pop(booking);
    } catch (error) {
      if (_resumePayment) {
        try {
          final recovered = await _confirmedBooking();
          if (!mounted) return;
          if (recovered != null) {
            Navigator.of(context).pop(recovered);
            return;
          }
        } catch (_) {
          // Preserve the original error and the idempotent retry path if the
          // booking lookup is also temporarily unavailable.
        }
        if (error is PaymentException && error is! PaymentPendingException) {
          _resumePayment = false;
        }
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

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: PopScope<OpenQueueBooking>(
        canPop: !_processing,
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
                        onPressed: _processing
                            ? null
                            : () => Navigator.of(context).pop(),
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
                  Text('PAY WITH', style: bookingText(10, bold: true)),
                  const SizedBox(height: 9),
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
                                'Choose securely in Stripe. Apple Pay appears on supported devices.',
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
                  const SizedBox(height: 16),
                  if (_loading)
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
                    onPressed: _loading || _processing || preview == null
                        ? null
                        : _pay,
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
                            'Continue to Pay${preview == null ? '' : ' · ${preview.totalLabel}'}',
                          ),
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
