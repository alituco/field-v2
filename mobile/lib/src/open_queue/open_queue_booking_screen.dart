import 'dart:async';

import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/field_confirmation_dialog.dart';
import '../core/user_facing_error.dart';
import '../home/field_bottom_nav.dart';
import '../reliability/reliability_deadline_notice.dart';
import 'open_queue.dart';
import 'open_queue_kit_indicator.dart';
import 'open_queue_party.dart';
import 'open_queue_party_card.dart';
import 'open_queue_party_repository.dart';
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
  Future<void>? _bookingRefresh;
  OpenQueuePartyContext? _partyContext;
  bool _partyLoading = false;
  String? _partyError;
  String? _partyAction;

  OpenQueuePartyRepository? get _partyRepository {
    final repository = widget.repository;
    return repository is OpenQueuePartyRepository
        ? repository as OpenQueuePartyRepository
        : null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refreshBooking(quiet: true));
    if (_partyRepository != null) {
      _partyLoading = true;
      unawaited(_loadParty());
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _refreshBooking(),
      if (_partyRepository != null) _loadParty(),
    ]);
  }

  Future<void> _refreshBooking({
    bool quiet = false,
    bool requireFresh = false,
  }) async {
    final activeRefresh = _bookingRefresh;
    if (activeRefresh != null) {
      await activeRefresh;
      if (!requireFresh) return;
    }
    final refresh = _performBookingRefresh(quiet: quiet);
    _bookingRefresh = refresh;
    try {
      await refresh;
    } finally {
      if (identical(_bookingRefresh, refresh)) _bookingRefresh = null;
    }
  }

  Future<void> _performBookingRefresh({required bool quiet}) async {
    if (!mounted) return;
    setState(() => _refreshing = true);
    try {
      final repository = widget.repository;
      final bookingLookup = repository is OpenQueueBookingLookupRepository
          ? repository as OpenQueueBookingLookupRepository
          : null;
      final latest = bookingLookup == null
          ? await repository.getMyUpcomingBooking()
          : await bookingLookup.getMyUpcomingBookingForGame(_booking.gameId);
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

  Future<void> _loadParty() async {
    final repository = _partyRepository;
    if (repository == null) return;
    if (mounted) {
      setState(() {
        _partyLoading = true;
        _partyError = null;
      });
    }
    try {
      final party = await repository.getPartyContext(_booking.gameId);
      if (!mounted) return;
      setState(() => _partyContext = party);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _partyError = userFacingError(
          error,
          fallback: 'Party details could not be loaded. Your booking is safe.',
        );
      });
    } finally {
      if (mounted) setState(() => _partyLoading = false);
    }
  }

  Future<bool> _runPartyAction({
    required String key,
    required Future<void> Function(OpenQueuePartyRepository repository) action,
    required String successMessage,
    required String fallbackError,
  }) async {
    final repository = _partyRepository;
    if (repository == null || _partyAction != null) return false;
    setState(() {
      _partyAction = key;
      _partyError = null;
    });
    try {
      await action(repository);
      await Future.wait([
        _loadParty(),
        _refreshBooking(quiet: true, requireFresh: true),
      ]);
      if (!mounted) return true;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
      return true;
    } catch (error) {
      if (!mounted) return false;
      final message = userFacingError(error, fallback: fallbackError);
      setState(() => _partyError = message);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return false;
    } finally {
      if (mounted) setState(() => _partyAction = null);
    }
  }

  Future<void> _createParty() async {
    await _runPartyAction(
      key: 'create',
      action: (repository) async {
        await repository.createParty(_booking.gameId);
      },
      successMessage: 'Party created. Invite confirmed players from this game.',
      fallbackError: 'Could not create your party.',
    );
  }

  Future<void> _acceptPartyInvite(OpenQueuePartyInvite invite) async {
    await _runPartyAction(
      key: 'accept-${invite.membershipId}',
      action: (repository) => repository.respondToPartyInvite(
        membershipId: invite.membershipId,
        accept: true,
      ),
      successMessage: 'Party joined. You will be assigned together.',
      fallbackError: 'Could not join this party.',
    );
  }

  Future<void> _declinePartyInvite(OpenQueuePartyInvite invite) async {
    final confirmed = await showFieldConfirmDialog(
      context: context,
      icon: Icons.group_off_rounded,
      eyebrow: 'Party invitation',
      title: 'Decline this invite?',
      message:
          '${invite.owner.displayName} invited you to be assigned together for this game.',
      detail: 'Your match booking will not be affected.',
      cancelLabel: 'Keep invite',
      confirmLabel: 'Decline invite',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _runPartyAction(
      key: 'decline-${invite.membershipId}',
      action: (repository) => repository.respondToPartyInvite(
        membershipId: invite.membershipId,
        accept: false,
      ),
      successMessage: 'Party invitation declined.',
      fallbackError: 'Could not decline this invitation.',
    );
  }

  Future<void> _cancelPartyInvite(OpenQueuePartyMember member) async {
    final confirmed = await showFieldConfirmDialog(
      context: context,
      icon: Icons.person_remove_alt_1_rounded,
      eyebrow: 'Pending invitation',
      title: 'Cancel ${member.displayName}’s invite?',
      message: 'They will no longer be able to accept this party invitation.',
      detail: 'You can invite them again later if a party spot is available.',
      cancelLabel: 'Keep invite',
      confirmLabel: 'Cancel invite',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _runPartyAction(
      key: 'cancel-${member.membershipId}',
      action: (repository) => repository.cancelPartyInvite(member.membershipId),
      successMessage: 'Pending invitation cancelled.',
      fallbackError: 'Could not cancel this invitation.',
    );
  }

  Future<void> _leaveOrDisbandParty() async {
    final party = _partyContext?.myParty;
    if (party == null) return;
    final isOwner = party.isOwner;
    final confirmed = await showFieldConfirmDialog(
      context: context,
      icon: isOwner ? Icons.group_off_rounded : Icons.logout_rounded,
      eyebrow: 'Your party',
      title: isOwner ? 'Cancel this party?' : 'Leave this party?',
      message: isOwner
          ? 'The party will be closed for every member and pending invitation.'
          : 'You will no longer be guaranteed assignment with this party.',
      detail: 'Everyone keeps their individual match booking.',
      cancelLabel: 'Keep party',
      confirmLabel: isOwner ? 'Cancel party' : 'Leave party',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _runPartyAction(
      key: '${isOwner ? 'disband' : 'leave'}-${party.id}',
      action: (repository) => isOwner
          ? repository.disbandParty(party.id)
          : repository.leaveParty(party.id),
      successMessage: isOwner ? 'Party cancelled.' : 'You left the party.',
      fallbackError: isOwner
          ? 'Could not cancel this party.'
          : 'Could not leave this party.',
    );
  }

  Future<void> _showInvitePlayers() async {
    final data = _partyContext;
    final party = data?.myParty;
    if (data == null || party == null || !party.isOwner) return;
    await showOpenQueuePartyInviteSheet(
      context: context,
      partyContext: data,
      onInvite: (player) async {
        final succeeded = await _runPartyAction(
          key: 'invite-${player.profileId}',
          action: (repository) => repository.invitePartyMember(
            partyId: party.id,
            profileId: player.profileId,
          ),
          successMessage: 'Invite sent to ${player.displayName}.',
          fallbackError: 'Could not invite ${player.displayName}.',
        );
        return succeeded ? null : _partyError ?? 'Could not send the invite.';
      },
    );
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
    var previewUpdated = false;
    while (mounted) {
      if (!mounted) return;
      final consequenceLines = <String>[
        preview.refundDestinationLabel,
        if (preview.effectiveRefundBps > 0 && preview.refundAmountFils > 0)
          preview.refundLabel,
        if (preview.strikeDelta > 0)
          '+${preview.strikeDelta} reliability ${preview.strikeDelta == 1 ? 'strike' : 'strikes'}',
        if (preview.depositForfeited) 'Reliability deposit forfeited',
      ];
      final explanation = preview.explanation?.trim();
      final confirmed = await showFieldConfirmDialog(
        context: context,
        icon: Icons.event_busy_rounded,
        eyebrow: previewUpdated
            ? 'Updated ${preview.outcomeLabel}'
            : preview.outcomeLabel,
        title: previewUpdated
            ? 'Cancellation terms changed'
            : 'Cancel your spot?',
        message: explanation == null || explanation.isEmpty
            ? 'Your position will reopen immediately. These consequences were calculated using server time and the policy active for this match.'
            : explanation,
        detail: consequenceLines.join('\n'),
        cancelLabel: 'Keep my spot',
        confirmLabel: preview.canCancel
            ? 'Confirm cancellation'
            : 'Unavailable',
        destructive: true,
        confirmEnabled: preview.canCancel,
      );
      if (!confirmed || !mounted) return;

      OpenQueueCancellationPreview latestPreview;
      try {
        latestPreview = await widget.repository.previewCancellation(
          _booking.id,
        );
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              userFacingError(
                error,
                fallback: 'Could not verify the cancellation terms.',
              ),
            ),
          ),
        );
        return;
      }
      if (preview.hasSameConsequencesAs(latestPreview)) break;
      preview = latestPreview;
      previewUpdated = true;
    }
    if (!mounted) return;
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
    final isTeamAssignmentDue = game.isTeamAssignmentDue;
    final hasTeamAssignment = game.hasActiveTeamAssignment;
    final assignedTeam = booking.assignedTeam;
    final confirmedCount = game.confirmedCount.clamp(0, game.capacity);
    final hasPendingPartyInvite =
        _partyContext?.receivedInvites.isNotEmpty ?? false;
    final assignmentTiming = game.teamAssignmentLeadLabel;
    final partyTiming =
        _partyContext?.partyLockLeadLabel ?? game.partyLockLeadLabel;
    final showPartyBeforeMatchDate =
        widget.newlyBooked || hasPendingPartyInvite;
    final String teamLabel;
    final String teamInfoMessage;
    if (assignedTeam != null) {
      teamLabel = '$assignedTeam TEAM';
      teamInfoMessage =
          'Teams assigned. The two team averages are only ${game.teamSrSpread ?? 0} SR apart.';
    } else if (isConfirmed && isTeamAssignmentDue) {
      teamLabel = 'Assignment updating';
      teamInfoMessage =
          'Your match is confirmed. Pull to refresh while your team and kit assignment finishes updating.';
    } else if (isConfirmed) {
      teamLabel = 'Assigned $assignmentTiming';
      teamInfoMessage =
          'Your match is on. Teams and kits are finalized $assignmentTiming. Party changes close $partyTiming.';
    } else if (isTeamAssignmentDue) {
      teamLabel = 'Assigned when the match fills';
      teamInfoMessage =
          'Your spot is secured. Teams and kits are assigned as soon as ${game.capacity}/${game.capacity} players confirm.';
    } else {
      teamLabel = 'Assigned $assignmentTiming';
      teamInfoMessage =
          'Your spot is secured. Teams and kits are finalized $assignmentTiming once ${game.capacity}/${game.capacity} players confirm.';
    }
    return Scaffold(
      extendBody: true,
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(title: 'Booking Details', showBack: true),
        child: RefreshIndicator(
          color: fieldEmerald600,
          edgeOffset: fieldPageHeaderExtent(context),
          onRefresh: _refreshAll,
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
                onRefresh: _refreshAll,
              ),
              if (showPartyBeforeMatchDate && _partyRepository != null) ...[
                const SizedBox(height: 12),
                _partyCard(),
              ],
              const SizedBox(height: 12),
              _BookingMatchDayCard(booking: booking),
              if (widget.repository
                  is OpenQueueReliabilityLookupRepository) ...[
                const SizedBox(height: 12),
                ReliabilityDeadlineNotice(
                  includeNoShowCutoff: true,
                  load: () =>
                      (widget.repository
                              as OpenQueueReliabilityLookupRepository)
                          .getMatchReliabilityContext(game.id),
                ),
              ],
              if (!showPartyBeforeMatchDate && _partyRepository != null) ...[
                const SizedBox(height: 12),
                _partyCard(),
              ],
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
                    _bookingRow(Icons.shield_outlined, 'TEAM', teamLabel),
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
                        teamInfoMessage,
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

  Widget _partyCard() {
    return OpenQueuePartyCard(
      contextData: _partyContext,
      loading: _partyLoading,
      newlyBooked: widget.newlyBooked,
      actionKey: _partyAction,
      error: _partyError,
      onRetry: _loadParty,
      onCreate: _createParty,
      onAcceptInvite: _acceptPartyInvite,
      onDeclineInvite: _declinePartyInvite,
      onInvitePlayers: _showInvitePlayers,
      onCancelInvite: _cancelPartyInvite,
      onLeaveOrDisband: _leaveOrDisbandParty,
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
