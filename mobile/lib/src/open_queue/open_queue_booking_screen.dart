import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../home/field_bottom_nav.dart';
import 'open_queue.dart';
import 'open_queue_repository.dart';

class OpenQueueBookingScreen extends StatefulWidget {
  const OpenQueueBookingScreen({
    super.key,
    required this.repository,
    required this.booking,
    this.newlyBooked = false,
    this.onNavigateTab,
  });

  final OpenQueueRepository repository;
  final OpenQueueBooking booking;
  final bool newlyBooked;
  final ValueChanged<int>? onNavigateTab;

  @override
  State<OpenQueueBookingScreen> createState() => _OpenQueueBookingScreenState();
}

class _OpenQueueBookingScreenState extends State<OpenQueueBookingScreen> {
  bool _cancelling = false;

  void _goHome() {
    widget.onNavigateTab?.call(0);
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((route) => route.isFirst);
  }

  void _navigateTab(int index) {
    widget.onNavigateTab?.call(index);
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((route) => route.isFirst);
  }

  Future<void> _cancel() async {
    OpenQueueCancellationPreview preview;
    try {
      preview = await widget.repository.previewCancellation(widget.booking.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(error, fallback: 'Cancellation is unavailable.'),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel your spot?'),
        content: Text(
          preview.refundPercent == 50
              ? 'You will receive a 50% refund (${preview.refundLabel}). Your position will reopen immediately.'
              : 'Game-day cancellations are not refundable. Your position will reopen immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep spot'),
          ),
          FilledButton(
            onPressed: preview.canCancel
                ? () => Navigator.pop(context, true)
                : null,
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _cancelling = true);
    try {
      await widget.repository.cancelBooking(widget.booking.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(error, fallback: 'Could not cancel booking.'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final booking = widget.booking;
    final game = booking.game;
    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(
          title: 'Booking Confirmed',
          showBack: true,
        ),
        child: ListView(
          padding: fieldHeaderAwarePadding(context, top: 20, bottom: 92),
          children: [
            Center(
              child: Container(
                width: 82,
                height: 82,
                decoration: const BoxDecoration(
                  color: fieldEmerald500,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x5510B981),
                      blurRadius: 24,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: 45,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              widget.newlyBooked ? 'YOUR SPOT IS RESERVED' : 'MATCH CONFIRMED',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: fieldGray900,
                fontSize: 24,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              "You're confirmed for this Open Queue match.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: fieldGray500,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 22),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: fieldGray100),
              ),
              child: Column(
                children: [
                  _bookingRow(
                    Icons.schedule_rounded,
                    'TIME',
                    '${game.dateGroup} · ${game.timeLabel}',
                  ),
                  _bookingRow(Icons.location_on_outlined, 'VENUE', game.venue),
                  _bookingRow(
                    Icons.verified_rounded,
                    'YOUR ROLE',
                    booking.role.label,
                    highlight: true,
                  ),
                  _bookingRow(
                    Icons.shield_outlined,
                    'TEAM',
                    booking.team == null ? 'Assignment pending' : booking.team!,
                  ),
                  if (game.matchAverageSr != null)
                    _bookingRow(
                      Icons.balance_rounded,
                      'TEAM BALANCE',
                      'White ${game.whiteAverageSr ?? '—'} · Black ${game.blackAverageSr ?? '—'} · Avg ${game.matchAverageSr}',
                    ),
                ],
              ),
            ),
            const SizedBox(height: 15),
            Container(
              padding: const EdgeInsets.all(17),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFDBEAFE)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.notifications_active_outlined,
                    color: fieldBlue600,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      booking.team == null
                          ? "We'll notify you when the match fills and your White or Black team is assigned."
                          : 'Teams assigned. The two team averages are only ${game.teamSrSpread ?? 0} SR apart.',
                      style: const TextStyle(
                        color: fieldGray600,
                        fontSize: 12,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _goHome,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                backgroundColor: fieldEmerald600,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              icon: const Icon(Icons.home_rounded),
              label: const Text(
                'Go back home',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _cancelling ? null : _cancel,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Color(0xFFFECACA)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              child: _cancelling
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      'Cancel booking',
                      style: TextStyle(fontWeight: FontWeight.w900),
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

  Widget _bookingRow(
    IconData icon,
    String label,
    String value, {
    bool highlight = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(
            icon,
            color: highlight ? fieldEmerald600 : fieldGray400,
            size: 20,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: highlight ? fieldEmerald700 : fieldGray400,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
