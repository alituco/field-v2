import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../home/field_bottom_nav.dart';
import 'open_queue.dart';
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
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, color: fieldGray400, size: 20),
                  SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      "You'll be assigned to White or Black when the match fills, to keep both teams balanced.",
                      style: TextStyle(
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
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: fieldGray100),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text(
                        'Total',
                        style: TextStyle(
                          color: fieldGray500,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        game.priceLabel,
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  FilledButton.icon(
                    onPressed: () => _pay(context),
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
                      'Continue to Test Checkout',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
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
  String _method = 'APPLE_PAY';
  bool _processing = false;
  String? _error;

  Future<void> _pay() async {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      final booking = await widget.repository.bookGame(
        game: widget.game,
        role: widget.role,
        paymentMethod: _method,
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
    return Scaffold(
      extendBody: true,
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(title: 'Payment', showBack: true),
        child: ListView(
          padding: fieldHeaderAwarePadding(context, top: 16, bottom: 116),
          children: [
            _PaymentSummary(game: widget.game, role: widget.role),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFFED7AA)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.science_outlined, color: Color(0xFFC2410C)),
                  SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'TEST CHECKOUT · No real payment or refund is sent yet.',
                      style: TextStyle(
                        color: Color(0xFF9A3412),
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'PAYMENT METHOD',
              style: TextStyle(
                color: fieldGray500,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            _PaymentMethodTile(
              icon: Icons.apple_rounded,
              label: 'Apple Pay (test)',
              selected: _method == 'APPLE_PAY',
              onTap: () => setState(() => _method = 'APPLE_PAY'),
            ),
            const SizedBox(height: 9),
            _PaymentMethodTile(
              icon: Icons.account_balance_wallet_rounded,
              label: 'BenefitPay (test)',
              selected: _method == 'BENEFITPAY',
              onTap: () => setState(() => _method = 'BENEFITPAY'),
            ),
            const SizedBox(height: 14),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded, color: fieldGray400, size: 15),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Cancel before midnight starting game day for a 50% test-ledger refund. Cancellations on game day are not refundable.',
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
              onPressed: _processing ? null : _pay,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: fieldGray900,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _processing
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Text(
                      'Book Test Spot · ${widget.game.priceLabel}',
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
          const Divider(height: 25, color: fieldGray100),
          Row(
            children: [
              const Text('Total to pay', style: TextStyle(color: fieldGray500)),
              const Spacer(),
              Text(
                game.priceLabel,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
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

class _PaymentMethodTile extends StatelessWidget {
  const _PaymentMethodTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: selected ? fieldGray900 : fieldGray100,
              width: selected ? 2 : 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: fieldGray900),
              const SizedBox(width: 11),
              Text(
                label,
                style: const TextStyle(
                  color: fieldGray900,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? fieldGray900 : fieldGray300,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
