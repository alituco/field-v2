import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../payments/fieldrush_embedded_payment.dart';
import '../payments/payment_service.dart';
import 'fieldrush_booking_widgets.dart';
import 'open_queue.dart';
import 'fieldrush_game_loading.dart';
import 'open_queue_repository.dart';

Future<OpenQueueBooking?> showFieldrushCheckout({
  required BuildContext context,
  required OpenQueueRepository repository,
  required OpenQueueGame game,
  OpenQueueRole? role,
}) => showModalBottomSheet<OpenQueueBooking>(
  context: context,
  isScrollControlled: true,
  isDismissible: false,
  enableDrag: false,
  backgroundColor: FieldrushAuthTheme.cream,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  builder: (_) =>
      FieldrushCheckoutSheet(repository: repository, game: game, role: role),
);

/// Fieldrush review sheet with native, embedded payment-method selection.
/// Never show a simulated card/wallet or confirm based on a client-only event.
class FieldrushCheckoutSheet extends StatefulWidget {
  const FieldrushCheckoutSheet({
    super.key,
    required this.repository,
    required this.game,
    this.role,
    this.allowPositionSelection = false,
    this.embeddedPaymentSessionFactory,
  });
  final OpenQueueRepository repository;
  final OpenQueueGame game;
  final OpenQueueRole? role;
  final bool allowPositionSelection;
  final FieldrushEmbeddedPaymentSessionFactory? embeddedPaymentSessionFactory;

  @override
  State<FieldrushCheckoutSheet> createState() => _FieldrushCheckoutSheetState();
}

class _FieldrushCheckoutSheetState extends State<FieldrushCheckoutSheet> {
  late OpenQueueGame _game = widget.game;
  late OpenQueueRole? _role = widget.role;
  bool _availabilityReady = false;
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

  bool get _selectingPosition =>
      widget.allowPositionSelection || widget.role == null;
  bool get _positionLocked =>
      _loading ||
      _processing ||
      _closing ||
      _paymentSubmitted ||
      _resumePayment;

  bool get _embedded =>
      widget.repository is OpenQueueEmbeddedCheckoutRepository &&
      !PaymentService.stagingE2EBypass;

  bool get _canPay =>
      !_loading &&
      !_processing &&
      !_closing &&
      _role != null &&
      _preview != null &&
      (!_embedded ||
          _preview!.totalFils == 0 ||
          _resumePayment ||
          (_paymentSession?.isReady == true &&
              _paymentSession?.hasSelection == true));

  String get _longDateLabel {
    final date = _game.localStartsAt;
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}';
  }

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
    if (!mounted || _closing || generation != _loadGeneration) return;
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
    if (preview == null ||
        _processing ||
        _closing ||
        _loading ||
        _resumePayment ||
        _paymentSubmitted) {
      return;
    }
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
    _loadGeneration++;
    await _paymentSession?.close();
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(booking);
  }

  Future<OpenQueueBookingCostPreview> _quote({
    OpenQueueRole? previewRole,
  }) async {
    final role = previewRole ?? _role;
    if (role == null) throw StateError('Choose your position first.');
    final repository = widget.repository;
    if (repository is! OpenQueueBookingCostPreviewRepository) {
      throw StateError(
        'Your exact booking total is unavailable. Please try again.',
      );
    }
    final result = await (repository as OpenQueueBookingCostPreviewRepository)
        .previewBookingCost(gameId: widget.game.id, role: role);
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
      var previewRole = _role;
      if (_selectingPosition) {
        _availabilityReady = false;
        final results = await Future.wait([
          widget.repository.getMatchDetail(widget.game.id),
          widget.repository.getMyUpcomingBookings(),
        ]);
        if (!mounted || generation != _loadGeneration) return;
        final game = (results[0] as OpenQueueMatchDetail).game;
        final bookings = results[1] as List<OpenQueueBooking>;
        final now = DateTime.now();
        if (bookings.any(
          (booking) =>
              booking.status == 'CONFIRMED' &&
              !['CANCELLED', 'FINAL'].contains(booking.game.status) &&
              (booking.game.status == 'LIVE' ||
                  (booking.game.operationalState !=
                          MatchOperationalState.noData &&
                      booking.game.endsAt.isAfter(now))),
        )) {
          throw StateError(
            'You can only join one upcoming or active game. Manage your current game before taking another spot.',
          );
        }
        setState(() {
          _game = game;
          _availabilityReady = true;
          if (_role != null && !game.canBook(_role!)) _role = null;
        });
        if (!game.supportedRoles.any(game.canBook)) {
          throw StateError('This game no longer has an available spot.');
        }
        // Preview an actually available spot without choosing it for the player.
        // This exposes the server's price and eligibility before selection;
        // native initialization does not reserve a spot or create an intent.
        previewRole = _role ?? game.supportedRoles.firstWhere(game.canBook);
      }
      final preview = await _quote(previewRole: previewRole);
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
    final role = _role;
    if (!_canPay || shown == null || role == null) return;
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
                  game: _game,
                  role: role,
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
              game: _game,
              role: role,
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
              onPressed:
                  _processing || _loading || _resumePayment || _paymentSubmitted
                  ? null
                  : _retryPaymentSelection,
              child: const Text('Retry payment options'),
            ),
          ],
        ),
      );
    }
    if (session == null) {
      return _loading
          ? const _PaymentOptionsSkeleton()
          : Text(
              'Choose a position to see secure payment options.',
              style: bookingText(12),
            );
    }
    return AbsorbPointer(
      absorbing:
          _loading ||
          _preview == null ||
          _processing ||
          _closing ||
          _paymentSubmitted,
      child: Stack(
        children: [
          Opacity(
            opacity:
                !_loading &&
                    _preview != null &&
                    (session.isReady || _paymentSubmitted)
                ? 1
                : 0,
            child: session.buildView(),
          ),
          if ((_loading || !session.isReady) && !_paymentSubmitted)
            const _PaymentOptionsSkeleton(),
        ],
      ),
    );
  }

  Widget _positionOptions() => Row(
    children: [
      for (final role in fieldrushOpenQueueRoles) ...[
        if (role != fieldrushOpenQueueRoles.first) const SizedBox(width: 7),
        Expanded(
          child: Builder(
            builder: (context) {
              final available = _game.canBook(role);
              final selected = _role == role;
              final enabled =
                  _availabilityReady && available && !_positionLocked;
              return Semantics(
                button: true,
                selected: selected,
                enabled: enabled,
                child: OutlinedButton(
                  key: ValueKey('checkout-position-${role.code}'),
                  onPressed: !enabled
                      ? null
                      : () {
                          if (_positionLocked || _role == role) return;
                          setState(() => _role = role);
                          _load();
                        },
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 58),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 10,
                    ),
                    backgroundColor: selected
                        ? FieldrushAuthTheme.forest
                        : available
                        ? Colors.white
                        : const Color(0xFFF6F3EA),
                    side: BorderSide(
                      color: selected
                          ? FieldrushAuthTheme.forest
                          : FieldrushAuthTheme.border,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        role.label,
                        style: bookingHeading(
                          13,
                          color: selected
                              ? Colors.white
                              : available
                              ? FieldrushAuthTheme.ink
                              : const Color(0xFFA9A490),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        available ? '${_game.spotsFor(role)} open' : 'Full',
                        style: bookingText(
                          10,
                          bold: true,
                          color: selected
                              ? const Color(0xFFC7DD9B)
                              : available
                              ? FieldrushAuthTheme.muted
                              : const Color(0xFFA9A490),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ],
  );

  Widget _gameSummary() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: FieldrushAuthTheme.border),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        Container(
          width: 54,
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: FieldrushAuthTheme.forest,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Column(
            children: [
              Text(
                const [
                  'MON',
                  'TUE',
                  'WED',
                  'THU',
                  'FRI',
                  'SAT',
                  'SUN',
                ][_game.localStartsAt.weekday - 1],
                style: bookingText(
                  9.5,
                  bold: true,
                  color: const Color(0xFFC7DD9B),
                ).copyWith(letterSpacing: 1.14, height: 1),
              ),
              const SizedBox(height: 5),
              Text(
                '${_game.localStartsAt.day}',
                style: bookingHeading(25, color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_game.startTimeLabel, style: bookingHeading(26)),
              const SizedBox(height: 7),
              Text(
                _longDateLabel,
                style: bookingText(12, color: const Color(0xFF3C4A38)),
              ),
              const SizedBox(height: 3),
              Text(_game.venue, style: bookingText(11)),
              if (_game.locationLabel case final String address) ...[
                const SizedBox(height: 3),
                Text(address, style: bookingText(11)),
              ],
              const SizedBox(height: 5),
              Text(
                _game.divisionRangeLabel,
                key: const ValueKey('checkout-division-range'),
                style: bookingText(
                  10,
                  bold: true,
                  color: FieldrushAuthTheme.forest,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

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
                          'Pay for your spot',
                          style: bookingHeading(19),
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
                  _gameSummary(),
                  const SizedBox(height: 18),
                  Text('YOUR POSITION', style: bookingText(10, bold: true)),
                  const SizedBox(height: 9),
                  if (_selectingPosition)
                    _positionOptions()
                  else
                    BookingPanel(
                      padding: 16,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            bookingRoleName(_role!),
                            style: bookingHeading(16),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${_game.spotsFor(_role!)} spots open in this game',
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
                    const FieldrushPriceLoading()
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
                  ] else
                    Text(
                      'Select a position to see your exact total.',
                      style: bookingText(12),
                    ),
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
                        ? const Text('Processing…')
                        : Text(
                            _role == null
                                ? 'Pick a position'
                                : _embedded
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
