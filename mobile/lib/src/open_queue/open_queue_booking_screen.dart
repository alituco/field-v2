import 'dart:async';

import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../home/field_bottom_nav.dart';
import 'open_queue.dart';
import 'open_queue_kit_indicator.dart';
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
  late OpenQueueBooking _booking = widget.booking;
  bool _cancelling = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshBooking(quiet: true));
  }

  Future<void> _refreshBooking({bool quiet = false}) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final latest = await widget.repository.getMyUpcomingBooking();
      if (!mounted || latest == null || latest.id != _booking.id) return;
      setState(() => _booking = latest);
    } catch (error) {
      if (!mounted || quiet) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'Could not refresh the player count.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

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
      preview = await widget.repository.previewCancellation(_booking.id);
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
      await widget.repository.cancelBooking(_booking.id);
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
    final booking = _booking;
    final game = booking.game;
    final isConfirmed = game.isUpcomingMatchConfirmed;
    final hasTeamAssignment = game.hasActiveTeamAssignment;
    final assignedTeam = booking.assignedTeam;
    final confirmedCount = game.confirmedCount.clamp(0, game.capacity);
    return Scaffold(
      extendBody: true,
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(title: 'Booking Details', showBack: true),
        child: RefreshIndicator(
          color: fieldEmerald600,
          edgeOffset: fieldPageHeaderExtent(context),
          onRefresh: _refreshBooking,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: fieldHeaderAwarePadding(context, top: 20, bottom: 116),
            children: [
              _BookingPlayerStatusCard(
                confirmedCount: confirmedCount,
                capacity: game.capacity,
                averagePlayerRating: hasTeamAssignment
                    ? game.matchAverageSr
                    : null,
                isConfirmed: isConfirmed,
                isRefreshing: _refreshing,
                onRefresh: _refreshBooking,
              ),
              const SizedBox(height: 12),
              _BookingMatchDayCard(booking: booking),
              const SizedBox(height: 20),
              const Text(
                'YOUR BOOKING',
                style: TextStyle(
                  color: fieldGray500,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.3,
                ),
              ),
              const SizedBox(height: 9),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: fieldGray100),
                ),
                child: Column(
                  children: [
                    _bookingRow(
                      Icons.schedule_rounded,
                      'KICKOFF',
                      game.timeLabel,
                    ),
                    const Divider(height: 1, color: fieldGray100),
                    _bookingRow(
                      Icons.verified_rounded,
                      'YOUR POSITION',
                      booking.role.label,
                      highlight: true,
                    ),
                    const Divider(height: 1, color: fieldGray100),
                    _bookingRow(
                      Icons.location_on_outlined,
                      'VENUE',
                      game.venue,
                    ),
                    const Divider(height: 1, color: fieldGray100),
                    _bookingRow(
                      Icons.shield_outlined,
                      'TEAM',
                      assignedTeam == null
                          ? isConfirmed
                                ? 'Assignment updating'
                                : 'Assigned when the match fills'
                          : '$assignedTeam TEAM',
                    ),
                    if (hasTeamAssignment && game.matchAverageSr != null) ...[
                      const Divider(height: 1, color: fieldGray100),
                      _bookingRow(
                        Icons.balance_rounded,
                        'TEAM BALANCE',
                        'White ${game.whiteAverageSr ?? '—'} · Black ${game.blackAverageSr ?? '—'} · ${game.teamSrSpread ?? 0} SR spread',
                      ),
                    ],
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
                      Icons.info_outline_rounded,
                      color: fieldBlue600,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        assignedTeam == null
                            ? isConfirmed
                                  ? 'Your match is confirmed. Pull to refresh while your kit assignment finishes updating.'
                                  : 'Your spot is secured. Teams are assigned automatically when ${game.capacity}/${game.capacity} players confirm.'
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

class _BookingMatchDayCard extends StatelessWidget {
  const _BookingMatchDayCard({required this.booking});

  final OpenQueueBooking booking;

  @override
  Widget build(BuildContext context) {
    final game = booking.game;
    final isConfirmed = game.isUpcomingMatchConfirmed;
    final isClose = game.isToday || game.isTomorrow;

    return Container(
      key: const ValueKey('match-day-kit-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isConfirmed
              ? const [Color(0xFFECFDF5), Colors.white]
              : const [Colors.white, Color(0xFFF9FAFB)],
        ),
        border: Border.all(
          color: isConfirmed ? fieldEmerald200 : fieldGray200,
          width: 1.3,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D111827),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isClose ? fieldEmerald600 : fieldGray900,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.calendar_month_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'MATCH DATE',
                      style: TextStyle(
                        color: fieldGray500,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      game.prominentDateLabel,
                      style: TextStyle(
                        color: isClose ? fieldEmerald800 : fieldGray900,
                        fontSize: isClose ? 16 : 14,
                        height: 1.15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (isConfirmed) ...[
            const SizedBox(height: 13),
            const Divider(height: 1, color: fieldGray200),
            const SizedBox(height: 13),
            OpenQueueKitIndicator(booking: booking),
          ],
        ],
      ),
    );
  }
}

class _BookingPlayerStatusCard extends StatelessWidget {
  const _BookingPlayerStatusCard({
    required this.confirmedCount,
    required this.capacity,
    required this.averagePlayerRating,
    required this.isConfirmed,
    required this.isRefreshing,
    required this.onRefresh,
  });

  final int confirmedCount;
  final int capacity;
  final int? averagePlayerRating;
  final bool isConfirmed;
  final bool isRefreshing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final remaining = (capacity - confirmedCount).clamp(0, capacity);
    final progress = capacity <= 0 ? 0.0 : confirmedCount / capacity;
    final accent = isConfirmed ? fieldEmerald600 : const Color(0xFFD97706);
    final softAccent = isConfirmed
        ? const Color(0xFFECFDF5)
        : const Color(0xFFFFFBEB);
    final border = isConfirmed
        ? const Color(0xFFA7F3D0)
        : const Color(0xFFFDE68A);

    return Container(
      key: const ValueKey('booking-player-status-card'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: border, width: 1.4),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D111827),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: softAccent,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  isConfirmed
                      ? Icons.check_circle_rounded
                      : Icons.groups_2_rounded,
                  color: accent,
                  size: 23,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isConfirmed ? 'MATCH CONFIRMED' : 'MATCH PENDING',
                      style: TextStyle(
                        color: accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isConfirmed ? 'Everyone is in' : 'Your spot is reserved',
                      style: const TextStyle(
                        color: fieldGray500,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('refresh-booking-player-count'),
                tooltip: 'Refresh player count',
                onPressed: isRefreshing ? null : onRefresh,
                visualDensity: VisualDensity.compact,
                icon: isRefreshing
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$confirmedCount',
                key: const ValueKey('booking-confirmed-player-count'),
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 50,
                  height: 0.9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -2,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 2, left: 4),
                child: Text(
                  '/ $capacity',
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 25,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 10,
            runSpacing: 7,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'PLAYERS CONFIRMED',
                style: TextStyle(
                  color: fieldGray500,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              if (averagePlayerRating case final rating?) ...[
                Container(
                  key: const ValueKey('booking-average-player-rating'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: fieldGray900,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.bolt_rounded,
                        color: fieldEmerald200,
                        size: 13,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '$rating AVG PLAYER RATING',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              key: const ValueKey('booking-player-progress'),
              value: progress.clamp(0, 1),
              minHeight: 10,
              color: accent,
              backgroundColor: softAccent,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isConfirmed
                ? 'Full squad confirmed. This match is on.'
                : '$remaining more player${remaining == 1 ? '' : 's'} needed to confirm this match.',
            style: const TextStyle(
              color: fieldGray700,
              fontSize: 13,
              height: 1.3,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
