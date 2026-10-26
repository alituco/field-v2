import 'package:flutter/material.dart';
import 'fieldrush_check_in_notice.dart';

import '../ui/field_loading.dart';
import '../ui/fieldrush_toast.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../home/field_bottom_nav.dart';
import 'open_queue.dart';
import 'open_queue_repository.dart';
import 'open_queue_review_screen.dart';

class OpenQueueGamesScreen extends StatefulWidget {
  const OpenQueueGamesScreen({
    super.key,
    required this.repository,
    required this.mainRole,
    required this.backupRoles,
    this.onNavigateTab,
  });

  final OpenQueueRepository repository;
  final OpenQueueRole mainRole;
  final Set<OpenQueueRole> backupRoles;
  final ValueChanged<int>? onNavigateTab;

  @override
  State<OpenQueueGamesScreen> createState() => _OpenQueueGamesScreenState();
}

class _OpenQueueGamesScreenState extends State<OpenQueueGamesScreen> {
  List<OpenQueueGame> _games = const [];
  List<OpenQueueBooking> _upcomingBookings = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<dynamic>([
        widget.repository.listGames(),
        widget.repository.getMyUpcomingBookings(),
      ]);
      final games = [...results[0] as List<OpenQueueGame>]
        ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
      if (mounted) {
        setState(() {
          _games = games;
          _upcomingBookings = results[1] as List<OpenQueueBooking>;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(
          error,
          fallback: 'We could not refresh Open Queue availability.',
        );
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openReview(OpenQueueGame game, OpenQueueRole role) async {
    if (_upcomingBookings.any((b) => b.game.blocksNewBooking)) {
      showFieldrushToast(
        context,
        'You already have an upcoming or active game. Finish or cancel it before booking another.',
      );
      return;
    }
    final booked = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OpenQueueReviewScreen(
          repository: widget.repository,
          game: game,
          role: role,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (booked == true && mounted) {
      Navigator.of(context).pop(true);
      return;
    }
    if (mounted) await _load();
  }

  void _navigateTab(int index) {
    widget.onNavigateTab?.call(index);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final bookedGameIds = _upcomingBookings
        .map((booking) => booking.gameId)
        .toSet();
    final matches = _matchGames(
      games: _games
          .where(
            (game) => !game.hasMyBooking && !bookedGameIds.contains(game.id),
          )
          .toList(growable: false),
      mainRole: widget.mainRole,
      backupRoles: widget.backupRoles,
    );
    final earliestMain = matches.primary.isEmpty
        ? null
        : ([
            ...matches.primary,
          ]..sort((a, b) => a.startsAt.compareTo(b.startsAt))).first;
    final earliestBackup = matches.backups.isEmpty
        ? null
        : ([
            ...matches.backups,
          ]..sort((a, b) => a.game.startsAt.compareTo(b.game.startsAt))).first;
    final showFastestBackup =
        earliestBackup != null &&
        (earliestMain == null ||
            earliestBackup.game.startsAt.isBefore(earliestMain.startsAt));

    return Scaffold(
      extendBody: true,
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(title: 'Games for you', showBack: true),
        child: FieldRefreshIndicator(
          color: fieldEmerald600,
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: fieldHeaderAwarePadding(context, top: 16, bottom: 100),
            children: [
              _SelectedRolesCard(
                mainRole: widget.mainRole,
                backupRoles: widget.backupRoles,
                onEdit: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 24),
              if (_loading)
                const _QueueGamesLoading()
              else if (_error != null)
                _QueueGamesEmpty(
                  icon: Icons.cloud_off_rounded,
                  message: _error!,
                  action: 'Try again',
                  onAction: _load,
                )
              else if (_upcomingBookings.any((b) => b.game.blocksNewBooking))
                const _QueueGamesEmpty(
                  icon: Icons.event_busy_rounded,
                  message:
                      'One upcoming or active game at a time. Finish or cancel your current booking before joining another.',
                )
              else ...[
                if (showFastestBackup) ...[
                  _FastestWayCard(
                    match: earliestBackup,
                    mainRole: widget.mainRole,
                    nextMainGame: earliestMain,
                    onTap: () =>
                        _openReview(earliestBackup.game, earliestBackup.role),
                  ),
                  const SizedBox(height: 24),
                ],
                const Text(
                  'BEST MATCHES FOR YOU',
                  style: TextStyle(
                    color: fieldGray500,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Playing as ${widget.mainRole.label.toLowerCase()}',
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 12),
                if (matches.primary.isEmpty)
                  _PrimaryMatchesEmpty(
                    mainRole: widget.mainRole,
                    backupCount: matches.backups.length,
                  )
                else
                  for (final game in matches.primary) ...[
                    _QueueGameCard(
                      game: game,
                      role: widget.mainRole,
                      onJoin: () => _openReview(game, widget.mainRole),
                    ),
                    const SizedBox(height: 12),
                  ],
                if (matches.backups.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  const _MoreGamesDivider(),
                  const SizedBox(height: 8),
                  const Text(
                    'Using your backup positions',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: fieldGray400,
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final match in matches.backups) ...[
                    _QueueGameCard(
                      game: match.game,
                      role: match.role,
                      backup: true,
                      onJoin: () => _openReview(match.game, match.role),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: FieldBottomNav(
        selectedIndex: null,
        onSelected: widget.onNavigateTab == null ? (_) {} : _navigateTab,
      ),
    );
  }
}

enum _QueueAvailability { neededNow, lastSpot, available, full }

extension on _QueueAvailability {
  int get rank => switch (this) {
    _QueueAvailability.neededNow => 0,
    _QueueAvailability.lastSpot => 1,
    _QueueAvailability.available => 2,
    _QueueAvailability.full => 3,
  };

  bool get strong => this == _QueueAvailability.neededNow;
}

_QueueAvailability _availabilityFor(OpenQueueGame game, OpenQueueRole role) {
  final openSpots = game.spotsFor(role);
  if (game.isFull || openSpots <= 0) return _QueueAvailability.full;
  if (role == OpenQueueRole.goalkeeper ||
      game.confirmedCount >= game.capacity - 2) {
    return _QueueAvailability.neededNow;
  }
  if (openSpots == 1) return _QueueAvailability.lastSpot;
  return _QueueAvailability.available;
}

class _QueueMatches {
  const _QueueMatches({required this.primary, required this.backups});

  final List<OpenQueueGame> primary;
  final List<_BackupMatch> backups;
}

class _BackupMatch {
  const _BackupMatch({
    required this.game,
    required this.role,
    required this.availability,
  });

  final OpenQueueGame game;
  final OpenQueueRole role;
  final _QueueAvailability availability;
}

_QueueMatches _matchGames({
  required List<OpenQueueGame> games,
  required OpenQueueRole mainRole,
  required Set<OpenQueueRole> backupRoles,
}) {
  final primaryCandidates =
      games
          .where(
            (game) =>
                _availabilityFor(game, mainRole) != _QueueAvailability.full,
          )
          .toList()
        ..sort((a, b) {
          final availability = _availabilityFor(
            a,
            mainRole,
          ).rank.compareTo(_availabilityFor(b, mainRole).rank);
          return availability != 0
              ? availability
              : a.startsAt.compareTo(b.startsAt);
        });
  final primary = primaryCandidates.take(4).toList();
  final everyPrimaryId = primaryCandidates.map((game) => game.id).toSet();
  final backups = <_BackupMatch>[];

  for (final game in games) {
    if (everyPrimaryId.contains(game.id)) continue;
    _BackupMatch? best;
    for (final role in backupRoles) {
      final availability = _availabilityFor(game, role);
      if (availability == _QueueAvailability.full) continue;
      if (best == null || availability.rank < best.availability.rank) {
        best = _BackupMatch(game: game, role: role, availability: availability);
      }
    }
    if (best != null) backups.add(best);
  }

  backups.sort((a, b) => a.game.startsAt.compareTo(b.game.startsAt));
  final visibleBackups = backups.take(4).toList()
    ..sort((a, b) {
      final availability = a.availability.rank.compareTo(b.availability.rank);
      return availability != 0
          ? availability
          : a.game.startsAt.compareTo(b.game.startsAt);
    });
  return _QueueMatches(primary: primary, backups: visibleBackups);
}

class _SelectedRolesCard extends StatelessWidget {
  const _SelectedRolesCard({
    required this.mainRole,
    required this.backupRoles,
    required this.onEdit,
  });

  final OpenQueueRole mainRole;
  final Set<OpenQueueRole> backupRoles;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final isAnywhere = backupRoles.length == OpenQueueRole.values.length - 1;
    final backupLabel = isAnywhere
        ? 'Anywhere'
        : backupRoles.map((role) => role.label).join(', ');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: fieldGray100),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D111827),
            blurRadius: 9,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mainRole.label,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'MAIN POSITION',
                style: TextStyle(
                  color: fieldEmerald600,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          if (backupRoles.isNotEmpty) ...[
            const SizedBox(width: 16),
            Container(width: 1, height: 38, color: fieldGray200),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    backupLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: fieldGray700,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'BACKUP',
                    style: TextStyle(
                      color: fieldGray400,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ] else
            const Spacer(),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: onEdit,
            style: OutlinedButton.styleFrom(
              foregroundColor: fieldGray500,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              side: const BorderSide(color: fieldGray200),
              shape: const StadiumBorder(),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.edit_outlined, size: 14),
            label: const Text(
              'Edit',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _FastestWayCard extends StatelessWidget {
  const _FastestWayCard({
    required this.match,
    required this.mainRole,
    required this.nextMainGame,
    required this.onTap,
  });

  final _BackupMatch match;
  final OpenQueueRole mainRole;
  final OpenQueueGame? nextMainGame;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final date = match.game.displayDateGroup == 'TODAY'
        ? 'today'
        : match.game.displayDateGroup.toLowerCase();
    final role = match.role.label;
    final mainCopy = nextMainGame == null
        ? 'No ${mainRole.label.toLowerCase()} spot is currently available.'
        : 'Your next ${mainRole.label.toLowerCase()} option is '
              '${nextMainGame!.displayDateGroup.toLowerCase()} with check-in at '
              '${nextMainGame!.displayTimeLabel}.';
    return Material(
      color: fieldGray900,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.rocket_launch_outlined,
                    color: Color(0xFF34D399),
                    size: 17,
                  ),
                  SizedBox(width: 9),
                  Text(
                    'FASTEST WAY TO PLAY',
                    style: TextStyle(
                      color: Color(0xFF34D399),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'A $role spot is open $date with check-in at ${match.game.displayTimeLabel}. '
                '$mainCopy',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  height: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'View ${role.toLowerCase()} match',
                    style: const TextStyle(
                      color: Color(0xFF6EE7B7),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFF6EE7B7),
                    size: 17,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryMatchesEmpty extends StatelessWidget {
  const _PrimaryMatchesEmpty({
    required this.mainRole,
    required this.backupCount,
  });

  final OpenQueueRole mainRole;
  final int backupCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: fieldGray100),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D111827),
            blurRadius: 9,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Text.rich(
        TextSpan(
          text:
              'No ${mainRole.label.toLowerCase()} spot is available in the upcoming games.',
          children: [
            if (backupCount > 0)
              TextSpan(
                text:
                    '\nBut $backupCount game${backupCount == 1 ? '' : 's'} can confirm you in a backup position.',
                style: const TextStyle(color: fieldGray400),
              ),
          ],
        ),
        style: const TextStyle(
          color: fieldGray600,
          fontSize: 14,
          height: 1.5,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

class _MoreGamesDivider extends StatelessWidget {
  const _MoreGamesDivider();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider(color: fieldGray200)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'MORE GAMES YOU CAN JOIN',
            style: TextStyle(
              color: fieldGray400,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.3,
            ),
          ),
        ),
        Expanded(child: Divider(color: fieldGray200)),
      ],
    );
  }
}

class _QueueGameCard extends StatelessWidget {
  const _QueueGameCard({
    required this.game,
    required this.role,
    required this.onJoin,
    this.backup = false,
  });

  final OpenQueueGame game;
  final OpenQueueRole role;
  final VoidCallback onJoin;
  final bool backup;

  @override
  Widget build(BuildContext context) {
    final availability = _availabilityFor(game, role);
    final badge = _AvailabilityBadge(availability: availability, role: role);

    return Container(
      key: ValueKey('open-queue-game-${game.id}-${role.code.toLowerCase()}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: availability.strong ? const Color(0xFF6EE7B7) : fieldGray100,
          width: availability.strong ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: availability.strong
                ? const Color(0x2210B981)
                : const Color(0x0D111827),
            blurRadius: availability.strong ? 12 : 9,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      game.displayDateGroup,
                      style: const TextStyle(
                        color: fieldGray400,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${game.isUpcoming ? 'Check-in ' : ''}${game.displayTimeLabel}',
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 17,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        const Icon(
                          Icons.location_on_outlined,
                          size: 15,
                          color: fieldGray500,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            game.venue,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: fieldGray500,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              badge,
            ],
          ),
          if (game.isUpcoming) ...[
            const SizedBox(height: 12),
            FieldrushCheckInNotice(game: game),
          ],
          if (availability == _QueueAvailability.neededNow) ...[
            const SizedBox(height: 12),
            const Text(
              'Your place can be confirmed now.',
              style: TextStyle(
                color: fieldEmerald700,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.group_outlined, size: 15, color: fieldGray400),
              const SizedBox(width: 6),
              Text(
                '${game.confirmedCount} of ${game.capacity} players',
                style: const TextStyle(
                  color: fieldGray400,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(width: 8),
              const Text('·', style: TextStyle(color: fieldGray300)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  game.ageLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: const Text(
                  'RANKED',
                  style: TextStyle(
                    color: fieldBlue600,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.7,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                game.priceLabel,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: backup ? 152 : 94,
                height: 42,
                child: FilledButton(
                  key: ValueKey(
                    'open-queue-join-${game.id}-${role.code.toLowerCase()}',
                  ),
                  onPressed: onJoin,
                  style: FilledButton.styleFrom(
                    backgroundColor: availability.strong
                        ? fieldEmerald500
                        : fieldGray900,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    elevation: availability.strong ? 5 : 0,
                    shadowColor: const Color(0x6610B981),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          backup ? 'Join as ${role.label}' : 'Join',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(width: 5),
                        const Icon(Icons.bolt_rounded, size: 17),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AvailabilityBadge extends StatelessWidget {
  const _AvailabilityBadge({required this.availability, required this.role});

  final _QueueAvailability availability;
  final OpenQueueRole role;

  @override
  Widget build(BuildContext context) {
    final (background, foreground, label) = switch (availability) {
      _QueueAvailability.neededNow => (
        fieldEmerald100,
        fieldEmerald700,
        '${role.label} needed',
      ),
      _QueueAvailability.available => (
        const Color(0xFFEFF6FF),
        fieldBlue600,
        'Available as ${role.label.toLowerCase()}',
      ),
      _QueueAvailability.lastSpot => (
        const Color(0xFFFEF3C7),
        const Color(0xFFB45309),
        'Last spot',
      ),
      _QueueAvailability.full => (fieldGray100, fieldGray400, 'Position full'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          height: 1,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _QueueGamesLoading extends StatelessWidget {
  const _QueueGamesLoading();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        FieldSkeletonBox(height: 148, borderRadius: 24),
        SizedBox(height: 24),
        FieldSkeletonBox(height: 14, borderRadius: 7),
        SizedBox(height: 12),
        FieldSkeletonBox(height: 186, borderRadius: 24),
        SizedBox(height: 12),
        FieldSkeletonBox(height: 186, borderRadius: 24),
      ],
    );
  }
}

class _QueueGamesEmpty extends StatelessWidget {
  const _QueueGamesEmpty({
    required this.icon,
    required this.message,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: fieldGray100),
      ),
      child: Column(
        children: [
          Icon(icon, color: fieldGray400, size: 32),
          const SizedBox(height: 9),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray600,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}
