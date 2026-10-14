import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../home/field_bottom_nav.dart';
import '../reliability/reliability_deadline_notice.dart';
import 'open_queue.dart';
import 'fieldrush_game_loading.dart';
import 'open_queue_booking_screen.dart';
import 'open_queue_repository.dart';

class OpenQueueReviewScreen extends StatelessWidget {
  const OpenQueueReviewScreen({
    super.key,
    required this.repository,
    required this.game,
    required this.role,
    this.onNavigateTab,
  });

  final OpenQueueRepository repository;
  final OpenQueueGame game;
  final OpenQueueRole role;
  final ValueChanged<int>? onNavigateTab;

  Future<void> _pay(BuildContext context) async {
    final booked = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _OpenQueuePaymentScreen(
          repository: repository,
          game: game,
          role: role,
          onNavigateTab: onNavigateTab,
        ),
      ),
    );
    if (booked == true && context.mounted) Navigator.of(context).pop(true);
  }

  void _navigateTab(BuildContext context, int index) {
    onNavigateTab?.call(index);
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final rows = [
      _ReviewRow(
        Icons.schedule_rounded,
        'TIME',
        '${game.dateGroup} · ${game.timeLabel}',
      ),
      _ReviewRow(Icons.location_on_outlined, 'VENUE', game.venue),
      _ReviewRow(
        Icons.person_rounded,
        'POSITION',
        role.label,
        highlighted: true,
      ),
      const _ReviewRow(Icons.layers_rounded, 'FORMAT', '6-a-side · Open Queue'),
      _ReviewRow(
        Icons.groups_rounded,
        'PLAYERS',
        '${game.confirmedCount} of ${game.capacity} confirmed',
      ),
    ];

    return Scaffold(
      extendBody: true,
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(
          title: 'Open Queue Booking',
          showBack: true,
        ),
        child: ListView(
          padding: fieldHeaderAwarePadding(context, top: 16, bottom: 116),
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: fieldGray100),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var index = 0; index < rows.length; index++) ...[
                    _ReviewRowTile(row: rows[index]),
                    if (index != rows.length - 1)
                      const Divider(height: 1, color: fieldGray100),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (repository is OpenQueueReliabilityLookupRepository) ...[
              ReliabilityDeadlineNotice(
                load: () => (repository as OpenQueueReliabilityLookupRepository)
                    .getMatchReliabilityContext(game.id),
              ),
              const SizedBox(height: 16),
            ],
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: fieldEmerald50,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: fieldEmerald100),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.trending_up_rounded,
                        color: fieldEmerald700,
                        size: 19,
                      ),
                      SizedBox(width: 7),
                      Text(
                        'PLAYER RATING',
                        style: TextStyle(
                          color: fieldEmerald700,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 11),
                  Text(
                    'Clan and Open Queue games update Player Rating when you play. Solo results never affect Clan Rating.',
                    style: TextStyle(
                      color: fieldGray700,
                      height: 1.7,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: fieldGray100),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.shield_outlined,
                    color: fieldGray400,
                    size: 20,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      'White/Black teams and kits are finalized ${game.teamAssignmentLeadLabel} once the match is full.',
                      style: const TextStyle(
                        color: fieldGray600,
                        fontSize: 13,
                        height: 1.45,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _BookingCostPanel(
              repository: repository,
              game: game,
              role: role,
              onContinue: () => _pay(context),
            ),
          ],
        ),
      ),
      bottomNavigationBar: FieldBottomNav(
        selectedIndex: null,
        onSelected: (index) => _navigateTab(context, index),
      ),
    );
  }
}

class _OpenQueuePaymentScreen extends StatefulWidget {
  const _OpenQueuePaymentScreen({
    required this.repository,
    required this.game,
    required this.role,
    required this.onNavigateTab,
  });

  final OpenQueueRepository repository;
  final OpenQueueGame game;
  final OpenQueueRole role;
  final ValueChanged<int>? onNavigateTab;

  @override
  State<_OpenQueuePaymentScreen> createState() =>
      _OpenQueuePaymentScreenState();
}

class _OpenQueuePaymentScreenState extends State<_OpenQueuePaymentScreen> {
  bool _processing = false;
  String? _error;
  OpenQueueBookingCostPreview? _costPreview;
  int _costRefreshKey = 0;

  Future<void> _pay() async {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      final repository = widget.repository;
      if (repository is OpenQueueBookingCostPreviewRepository) {
        final latestPreview =
            await (repository as OpenQueueBookingCostPreviewRepository)
                .previewBookingCost(gameId: widget.game.id, role: widget.role);
        if (!mounted) return;
        final displayedPreview = _costPreview;
        if (displayedPreview == null ||
            !displayedPreview.hasSameCheckoutTermsAs(latestPreview)) {
          setState(() {
            _costPreview = latestPreview;
            _costRefreshKey += 1;
            _error =
                'Your booking terms changed. Review the updated total and deposit, then confirm again.';
          });
          return;
        }
      }
      final booking = await widget.repository.bookGame(
        game: widget.game,
        role: widget.role,
        paymentMethod: 'STRIPE',
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => OpenQueueBookingScreen(
            repository: widget.repository,
            booking: booking,
            newlyBooked: true,
            onNavigateTab: widget.onNavigateTab,
          ),
        ),
      );
      // The confirmation screen can clear the whole Open Queue stack when the
      // player chooses Home. During that unwind this State can briefly remain
      // mounted even though its route is no longer current. Popping again in
      // that window removes the app's root route and leaves a black screen.
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(
          error,
          fallback: 'Payment could not be completed. Try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _navigateTab(int index) {
    widget.onNavigateTab?.call(index);
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final walletName = kIsWeb
        ? null
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => 'Google Pay',
            TargetPlatform.iOS => 'Apple Pay',
            _ => null,
          };
    return Scaffold(
      extendBody: true,
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(title: 'Payment', showBack: true),
        child: ListView(
          padding: fieldHeaderAwarePadding(context, top: 16, bottom: 116),
          children: [
            _PaymentSummary(game: widget.game, role: widget.role),
            const SizedBox(height: 12),
            _BookingCostPanel(
              key: ValueKey(_costRefreshKey),
              repository: widget.repository,
              game: widget.game,
              role: widget.role,
              onLoaded: (preview) {
                if (mounted) setState(() => _costPreview = preview);
              },
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: fieldEmerald50,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: fieldEmerald100),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_rounded, color: fieldEmerald700),
                  SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'SECURE CHECKOUT',
                      style: TextStyle(
                        color: fieldEmerald700,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'AVAILABLE PAYMENT METHODS',
              style: TextStyle(
                color: fieldGray500,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: fieldGray100),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.credit_card_rounded,
                    color: fieldGray900,
                    size: 22,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      walletName == null
                          ? 'Visa · Mastercard'
                          : '$walletName · Visa · Mastercard',
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.lock_outline_rounded,
                  color: fieldGray400,
                  size: 15,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Before any cancellation, Fieldrush shows the exact refund, reliability strikes, and deposit outcome. Refunds return to your original payment method.',
                    style: TextStyle(
                      color: fieldGray400,
                      fontSize: 11,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 13),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton(
              key: const ValueKey('open-queue-confirm-payment'),
              onPressed: _processing || _costPreview == null ? null : _pay,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: fieldGray900,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _processing
                  ? const Text('Processing payment…')
                  : Text(
                      'Continue to Pay · ${_costPreview?.totalLabel ?? 'Checking total…'}',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: FieldBottomNav(
        selectedIndex: null,
        onSelected: _navigateTab,
      ),
    );
  }
}

class _ReviewRow {
  const _ReviewRow(
    this.icon,
    this.label,
    this.value, {
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool highlighted;
}

class _ReviewRowTile extends StatelessWidget {
  const _ReviewRowTile({required this.row});
  final _ReviewRow row;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: row.highlighted ? fieldEmerald50 : Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: row.highlighted ? fieldEmerald600 : fieldGray100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                row.highlighted ? Icons.verified_rounded : row.icon,
                color: row.highlighted ? Colors.white : fieldGray500,
                size: 19,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.label,
                    style: TextStyle(
                      color: row.highlighted ? fieldEmerald700 : fieldGray400,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                  Text(
                    row.value,
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
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
}

class _PaymentSummary extends StatelessWidget {
  const _PaymentSummary({required this.game, required this.role});
  final OpenQueueGame game;
  final OpenQueueRole role;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: fieldGray100),
      ),
      child: Column(
        children: [
          _summaryLine(
            Icons.schedule_rounded,
            '${game.dateGroup} · ${game.timeLabel}',
          ),
          _summaryLine(Icons.location_on_outlined, game.venue),
          _summaryLine(Icons.person_rounded, role.label),
        ],
      ),
    );
  }

  Widget _summaryLine(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, color: fieldGray400, size: 17),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: fieldGray700,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookingCostPanel extends StatefulWidget {
  const _BookingCostPanel({
    super.key,
    required this.repository,
    required this.game,
    required this.role,
    this.onContinue,
    this.onLoaded,
  });

  final OpenQueueRepository repository;
  final OpenQueueGame game;
  final OpenQueueRole role;
  final VoidCallback? onContinue;
  final ValueChanged<OpenQueueBookingCostPreview>? onLoaded;

  @override
  State<_BookingCostPanel> createState() => _BookingCostPanelState();
}

class _BookingCostPanelState extends State<_BookingCostPanel> {
  late Future<OpenQueueBookingCostPreview> _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _BookingCostPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.game.id != widget.game.id ||
        oldWidget.role != widget.role) {
      _load();
    }
  }

  void _load() {
    final repository = widget.repository;
    _preview = repository is OpenQueueBookingCostPreviewRepository
        ? (repository as OpenQueueBookingCostPreviewRepository)
              .previewBookingCost(gameId: widget.game.id, role: widget.role)
        : Future.value(
            OpenQueueBookingCostPreview(
              currency: widget.game.currency,
              standardMatchFeeFils: widget.game.priceFils,
              replacementDiscountBps: 0,
              discountAmountFils: 0,
              matchFeeFils: widget.game.priceFils,
              reliabilityDepositRequired: false,
              reliabilityDepositBps: 0,
              reliabilityDepositFils: 0,
              totalFils: widget.game.priceFils,
            ),
          );
    _preview.then<void>(
      (value) {
        if (mounted) widget.onLoaded?.call(value);
      },
      onError: (Object _, StackTrace _) {
        // FutureBuilder owns the visible error state. This handler prevents
        // the separate success observer from surfacing an unhandled error.
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OpenQueueBookingCostPreview>(
      future: _preview,
      builder: (context, snapshot) {
        final preview = snapshot.data;
        return Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: fieldGray100),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'BOOKING TOTAL',
                style: TextStyle(
                  color: fieldGray500,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 13),
              if (snapshot.connectionState == ConnectionState.waiting)
                const FieldrushPriceLoading()
              else if (snapshot.hasError || preview == null) ...[
                const Text(
                  'We could not verify the exact price. Refresh before booking.',
                  style: TextStyle(
                    color: Color(0xFFB45309),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () => setState(_load),
                  child: const Text('Try again'),
                ),
              ] else ...[
                _CostLine(
                  label: 'Match fee',
                  value: preview.replacementDiscountBps > 0
                      ? preview.standardMatchFeeLabel
                      : preview.matchFeeLabel,
                ),
                if (preview.replacementDiscountBps > 0)
                  _CostLine(
                    label: 'Replacement discount (${preview.discountPercent}%)',
                    value: '−${preview.discountLabel}',
                    valueColor: fieldEmerald700,
                  ),
                if (preview.reliabilityDepositRequired) ...[
                  const SizedBox(height: 7),
                  _CostLine(
                    label:
                        'Refundable reliability deposit (${preview.depositPercent}%)',
                    value: preview.depositLabel,
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: Text(
                      'Refunded to your original payment method after the referee records your on-time arrival.',
                      style: TextStyle(
                        color: fieldGray500,
                        fontSize: 11,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const Divider(height: 25, color: fieldGray100),
                Row(
                  children: [
                    const Text(
                      'Total to pay',
                      style: TextStyle(
                        color: fieldGray700,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      preview.totalLabel,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                if (widget.onContinue != null) ...[
                  const SizedBox(height: 15),
                  FilledButton.icon(
                    key: const ValueKey('open-queue-continue-to-checkout'),
                    onPressed: widget.onContinue,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      backgroundColor: fieldEmerald600,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: const Icon(Icons.chevron_right_rounded),
                    iconAlignment: IconAlignment.end,
                    label: const Text(
                      'Continue to Secure Checkout',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _CostLine extends StatelessWidget {
  const _CostLine({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: fieldGray600,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? fieldGray900,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}
