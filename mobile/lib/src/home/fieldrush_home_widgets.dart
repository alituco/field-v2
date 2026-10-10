import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../clans/clan.dart';
import '../fixtures/fixture.dart';
import '../leaderboard/leaderboard.dart';
import '../open_queue/open_queue.dart';
import '../profile/profile.dart';

const fieldrushHomeCream = Color(0xFFFAF7EF);
const _ink = Color(0xFF22301F);
const _muted = Color(0xFF55654A);
const _green = Color(0xFF386641);
const _border = Color(0xFFE6DFCB);
const _wash = Color(0xFFF2EFE3);
const _lime = Color(0xFFC7DD9B);
const _light = Color(0xFFE4F0D5);
const _roles = [
  OpenQueueRole.goalkeeper,
  OpenQueueRole.defender,
  OpenQueueRole.attacker,
];

TextStyle _jakarta(double size, {Color color = _muted, double? tracking}) =>
    TextStyle(
      fontFamily: 'PlusJakartaSans',
      fontWeight: FontWeight.w800,
      fontSize: size,
      height: 1.2,
      color: color,
      letterSpacing: tracking,
    );

TextStyle _outfit(double size, {Color color = _ink, double? tracking}) =>
    TextStyle(
      fontFamily: 'Outfit',
      fontWeight: FontWeight.w800,
      fontSize: size,
      height: 1.1,
      color: color,
      letterSpacing: tracking,
    );

class FieldrushHomeHeader extends StatelessWidget {
  const FieldrushHomeHeader({
    super.key,
    required this.profile,
    this.rating,
    required this.onProfile,
    required this.onSearch,
    required this.onActivity,
    required this.hasUnread,
    this.ratingUnavailable = false,
    this.now,
  });

  final PlayerProfile profile;
  final PlayerRatingLeaderboardEntry? rating;
  final VoidCallback onProfile;
  final VoidCallback onSearch;
  final VoidCallback onActivity;
  final bool hasUnread;
  final bool ratingUnavailable;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final hour = (now ?? DateTime.now()).hour;
    final greeting = hour < 12
        ? 'Morning'
        : hour < 18
        ? 'Afternoon'
        : 'Evening';
    final name = profile.displayName.trim().split(RegExp(r'\s+')).first;
    final matches =
        rating?.matchesPlayed ?? profile.playerRating?.matchesPlayed ?? 0;
    final value = rating?.skillRating ?? profile.playerRating?.skillRating;
    final placement = matches < minimumPlayerLeaderboardMatches;
    final line = ratingUnavailable
        ? 'Rating unavailable'
        : placement
        ? 'Placement · ${matches.clamp(0, 2)} of 2 played'
        : value == null
        ? 'View your skill rating'
        : 'Division ${divisionFromRating(value).number} · $value skill rating';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Semantics(
            button: true,
            label: 'Your profile',
            child: InkWell(
              onTap: onProfile,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 42,
                height: 42,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: _wash,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: profile.avatarUrl?.trim().isNotEmpty == true
                    ? Image.network(
                        profile.avatarUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _initials(),
                      )
                    : _initials(),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$greeting, ${name.isEmpty ? 'Player' : name}',
                  style: _outfit(17, tracking: -.17),
                ),
                const SizedBox(height: 3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (placement && !ratingUnavailable) ...[
                      const FieldrushDivisionShield(size: 13, placement: true),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        line,
                        style: _jakarta(
                          11.5,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _HeaderButton(
            label: 'Search players',
            icon: Icons.search_rounded,
            onTap: onSearch,
          ),
          const SizedBox(width: 8),
          _HeaderButton(
            label: 'Activity',
            icon: Icons.notifications_none_rounded,
            onTap: onActivity,
            hasUnread: hasUnread,
          ),
        ],
      ),
    );
  }

  Widget _initials() =>
      Center(child: Text(profile.initials, style: _outfit(16)));
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.hasUnread = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool hasUnread;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Stack(
            children: [
              Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CustomPaint(
                    painter: _HeaderIconPainter(
                      search: icon == Icons.search_rounded,
                    ),
                  ),
                ),
              ),
              if (hasUnread)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    key: const ValueKey('home-unread-activity'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _green,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _HeaderIconPainter extends CustomPainter {
  const _HeaderIconPainter({required this.search});
  final bool search;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = const Color(0xFF3C4A38)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (search) {
      canvas.drawCircle(const Offset(11, 11), 6.5, stroke);
      canvas.drawLine(const Offset(16, 16), const Offset(20.5, 20.5), stroke);
    } else {
      canvas.drawPath(
        Path()
          ..moveTo(6, 16.5)
          ..lineTo(6, 11)
          ..cubicTo(6, 7.69, 8.69, 5, 12, 5)
          ..cubicTo(15.31, 5, 18, 7.69, 18, 11)
          ..lineTo(18, 16.5)
          ..lineTo(19.5, 18.5)
          ..lineTo(4.5, 18.5)
          ..close(),
        stroke,
      );
      canvas.drawPath(
        Path()
          ..moveTo(10, 21)
          ..cubicTo(10.7, 23, 13.3, 23, 14, 21),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HeaderIconPainter oldDelegate) =>
      search != oldDelegate.search;
}

class FieldrushQuickGameCard extends StatefulWidget {
  const FieldrushQuickGameCard({
    super.key,
    required this.games,
    required this.onPlay,
    this.now,
  });
  final List<OpenQueueGame> games;
  final void Function(OpenQueueGame game, Set<OpenQueueRole> roles) onPlay;
  final DateTime? now;

  @override
  State<FieldrushQuickGameCard> createState() => _FieldrushQuickGameCardState();
}

class _FieldrushQuickGameCardState extends State<FieldrushQuickGameCard> {
  final Set<OpenQueueRole> _selected = {};

  @override
  Widget build(BuildContext context) {
    final now = widget.now ?? DateTime.now();
    final games = _bookableGames(widget.games, now);
    final matching = games
        .where((game) => _selected.any((role) => game.canBookAt(role, now)))
        .toList();
    final game = matching.isEmpty ? null : matching.first;
    final spots = game == null
        ? 0
        : _selected.fold<int>(
            0,
            (count, role) =>
                count + (game.canBookAt(role, now) ? game.spotsFor(role) : 0),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: CustomPaint(
        foregroundPainter: _DashedCardPainter(
          color: game == null ? const Color(0xFFD3CBB5) : _green,
        ),
        child: Container(
          key: const ValueKey('home-quick-game-card'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 2, 2, 0),
                child: Text('NEXT UP', style: _jakarta(10.5, tracking: 1.26)),
              ),
              if (game == null) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    _selected.isEmpty
                        ? 'Pick a position to find your game'
                        : 'No matching games right now',
                    style: _outfit(21, tracking: -.42),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    _selected.isEmpty
                        ? 'Choose one or more'
                        : 'Try another position or check back soon',
                    style: _jakarta(11.5).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _KickoffTime(
                    date: game.localStartsAt,
                    size: 52,
                    color: const Color(0xFF24472C),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    '${_dateLabel(game.localStartsAt)} · $spots ${spots == 1 ? 'spot' : 'spots'} left for you',
                    style: _jakarta(
                      12,
                      color: _green,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                key: const ValueKey('home-quick-pitch'),
                height: 118,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _HomePitchPainter(
                              selected: Set.of(_selected),
                            ),
                          ),
                        ),
                        for (var i = 0; i < _roles.length; i++)
                          Positioned(
                            left:
                                constraints.maxWidth * [.09, .30, .70][i] - 25,
                            top: 23,
                            width: 50,
                            height: 76,
                            child: _PitchPosition(
                              role: _roles[i],
                              selected: _selected.contains(_roles[i]),
                              enabled: games.any(
                                (g) => g.canBookAt(_roles[i], now),
                              ),
                              onTap: () => setState(() {
                                if (!_selected.remove(_roles[i])) {
                                  _selected.add(_roles[i]);
                                }
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('home-quick-play'),
                  onPressed: game == null
                      ? null
                      : () => widget.onPlay(
                          game,
                          Set.unmodifiable(
                            _selected.where(
                              (role) => game.canBookAt(role, now),
                            ),
                          ),
                        ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _green,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _wash,
                    disabledForegroundColor: const Color(0xFF9C9683),
                    minimumSize: const Size(0, 54),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: _outfit(16),
                  ),
                  child: Text(
                    game == null
                        ? 'Play'
                        : 'Play ${_weekday(game.localStartsAt.weekday)} · ${game.priceLabel}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PitchPosition extends StatelessWidget {
  const _PitchPosition({
    required this.role,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });
  final OpenQueueRole role;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    enabled: enabled,
    label: role == OpenQueueRole.goalkeeper ? 'Keeper' : role.label,
    child: Opacity(
      opacity: enabled ? 1 : .5,
      child: InkWell(
        key: ValueKey('home-position-${role.code}'),
        onTap: enabled ? onTap : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: selected ? 43 : 40,
              height: selected ? 43 : 40,
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF1F3D26) : Colors.white,
                shape: BoxShape.circle,
                border: selected
                    ? Border.all(color: Colors.white, width: 2.5)
                    : null,
                boxShadow: [
                  if (!selected)
                    BoxShadow(
                      color: Colors.white.withValues(alpha: .3),
                      spreadRadius: 4,
                    ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .35),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  selected ? '✓' : '+',
                  style: selected
                      ? _jakarta(17, color: Colors.white)
                      : _outfit(24, color: _green),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Pitch labels are part of the fixed-size diagram, with the full
            // accessible position label exposed on the enclosing button.
            FittedBox(
              child: Text(
                role == OpenQueueRole.goalkeeper ? 'Keeper' : role.label,
                style: _jakarta(10.5, color: Colors.white, tracking: .21),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

List<OpenQueueGame> _bookableGames(List<OpenQueueGame> games, DateTime now) =>
    (games
        .where((game) => _roles.any((role) => game.canBookAt(role, now)))
        .toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt)));

class FieldrushOpenNights extends StatelessWidget {
  const FieldrushOpenNights({
    super.key,
    required this.games,
    required this.onGame,
    this.now,
  });
  final List<OpenQueueGame> games;
  final ValueChanged<OpenQueueGame> onGame;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final available = _bookableGames(
      games,
      now ?? DateTime.now(),
    ).take(2).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
          child: Text('OR PICK A NIGHT', style: _jakarta(11, tracking: 1.54)),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(16, 11, 16, 0),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(20),
          ),
          child: available.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No open games right now. Check back for the next night.',
                    style: _jakarta(12).copyWith(fontWeight: FontWeight.w600),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < available.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, color: Color(0xFFF0ECE0)),
                      _OpenNightRow(
                        game: available[i],
                        onTap: () => onGame(available[i]),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _OpenNightRow extends StatelessWidget {
  const _OpenNightRow({required this.game, required this.onTap});
  final OpenQueueGame game;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('home-open-night-${game.id}'),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.2;
          final action = Text(
            'Take a spot ›',
            style: _jakarta(11, color: _green),
          );
          return Row(
            children: [
              _DateTile(date: game.localStartsAt, size: 42),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_clock(game.localStartsAt)} · Solo',
                      style: _outfit(14),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${(game.capacity - game.confirmedCount).clamp(0, game.capacity)} of ${game.capacity} spots left',
                      style: _jakarta(11).copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (game.matchAverageSr != null) ...[
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          FieldrushDivisionShield(
                            division: divisionFromRating(
                              game.matchAverageSr!,
                            ).number,
                            size: 15,
                            mini: true,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              'Avg ${game.matchAverageSr} SR',
                              style: _outfit(11.5),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (compact) ...[const SizedBox(height: 8), action],
                  ],
                ),
              ),
              if (!compact) ...[const SizedBox(width: 10), action],
            ],
          );
        },
      ),
    ),
  );
}

class FieldrushSoloHero extends StatelessWidget {
  const FieldrushSoloHero({
    super.key,
    required this.booking,
    required this.onTap,
  });
  final OpenQueueBooking booking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final game = booking.game;
    final count = game.confirmedCount;
    final remaining = (game.capacity - count).clamp(0, game.capacity);
    final team = booking.assignedTeam;
    final pending = team == null;
    final teamText = pending
        ? game.isUpcomingMatchConfirmed && game.isTeamAssignmentDue
              ? 'Kit assignment updating'
              : 'Teams assigned ${game.teamAssignmentLeadLabel}'
        : '${team == openQueueWhiteTeamId ? 'White' : 'Black'} team · ${booking.role.label}';
    return Container(
      key: ValueKey('home-solo-booking-${booking.id}'),
      margin: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      decoration: BoxDecoration(
        color: _green,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .2),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              "SOLO GAME · YOU'RE IN",
              style: _jakarta(10, color: Colors.white, tracking: 1.2),
            ),
          ),
          const SizedBox(height: 16),
          _HeroKickoff(date: game.localStartsAt, venue: game.venue),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.fromLTRB(15, 14, 15, 15),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 6,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: '$count',
                        style: _outfit(20, color: Colors.white),
                        children: [
                          TextSpan(
                            text: '/${game.capacity} in',
                            style: _outfit(20, color: _lime),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      remaining > 0 ? 'WAITING ON $remaining' : 'ROSTER FULL',
                      style: _jakarta(10.5, color: _light, tracking: 1.05),
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: game.capacity <= 0
                        ? 0
                        : (count / game.capacity).clamp(0, 1),
                    minHeight: 9,
                    backgroundColor: Colors.white.withValues(alpha: .24),
                    color: const Color(0xFFA7C957),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.only(top: 11),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: .14),
                      ),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: pending
                              ? _lime
                              : team == openQueueWhiteTeamId
                              ? Colors.white
                              : const Color(0xFF131913),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .65),
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          teamText,
                          style: _jakarta(
                            11.5,
                            color: _light,
                          ).copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (!pending) ...[
                        const SizedBox(width: 8),
                        Container(
                          key: const ValueKey('kit-instruction'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: team == openQueueWhiteTeamId
                                ? Colors.white
                                : const Color(0xFF141A15),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            booking.kitInstruction!,
                            style: _jakarta(
                              8.5,
                              color: team == openQueueWhiteTeamId
                                  ? _ink
                                  : Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF24472C),
                minimumSize: const Size(0, 50),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 15,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                textStyle: _jakarta(13.5),
              ),
              child: const Text('Match details'),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroKickoff extends StatelessWidget {
  const _HeroKickoff({required this.date, required this.venue});
  final DateTime date;
  final String venue;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final time = _KickoffTime(
        date: date,
        size: 56,
        color: Colors.white,
        periodColor: _lime,
      );
      final meta = Text(
        '${_dateLabel(date).toUpperCase()}\n$venue',
        style: _jakarta(
          11.5,
          color: _light,
        ).copyWith(fontWeight: FontWeight.w700, height: 1.4),
      );
      if (constraints.maxWidth < 310 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.2) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [time, const SizedBox(height: 10), meta],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(flex: 5, child: time),
          const SizedBox(width: 13),
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: meta,
            ),
          ),
        ],
      );
    },
  );
}

class FieldrushClanHero extends StatelessWidget {
  const FieldrushClanHero({
    super.key,
    required this.fixture,
    required this.clan,
    required this.onTap,
    this.selectedCount,
    this.isSelected = false,
  });

  final Fixture fixture;
  final Clan clan;
  final VoidCallback onTap;
  final int? selectedCount;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final opponent = fixture.opponentFor(clan.id);
    // Clan fixtures store a calendar day plus a local time-slot string,
    // rather than an instant with a timezone. Do not reinterpret that day
    // as a UTC kickoff or invent a time when the slot is unavailable.
    final slot = RegExp(
      r'(\d{1,2}):(\d{2})\s*(AM|PM)?',
      caseSensitive: false,
    ).firstMatch(fixture.timeSlot);
    DateTime? kickoff;
    if (slot != null) {
      var hour = int.parse(slot.group(1)!);
      final minute = int.parse(slot.group(2)!);
      final period = slot.group(3)?.toUpperCase();
      if (period != null) hour = hour % 12 + (period == 'PM' ? 12 : 0);
      if (hour < 24 && minute < 60) {
        kickoff = DateTime(
          fixture.matchDate.year,
          fixture.matchDate.month,
          fixture.matchDate.day,
          hour,
          minute,
        );
      }
    }
    return Container(
      key: ValueKey('home-clan-fixture-${fixture.id}'),
      margin: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      decoration: BoxDecoration(
        color: _green,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .2),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              isSelected ? "CLAN GAME · YOU'RE IN" : 'CLAN GAME',
              style: _jakarta(10, color: Colors.white, tracking: 1.2),
            ),
          ),
          const SizedBox(height: 16),
          if (kickoff != null)
            _HeroKickoff(date: kickoff, venue: fixture.venue)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fixture.timeSlot.isEmpty
                      ? 'Time to be confirmed'
                      : fixture.timeSlot,
                  style: _outfit(28, color: Colors.white),
                ),
                const SizedBox(height: 10),
                Text(
                  '${_dateLabel(fixture.matchDate).toUpperCase()}\n${fixture.venue}',
                  style: _jakarta(11.5, color: _light).copyWith(height: 1.4),
                ),
              ],
            ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(15, 14, 15, 15),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CLAN MATCH',
                  style: _jakarta(9.5, color: _lime, tracking: 1.14),
                ),
                const SizedBox(height: 10),
                Text(
                  '${clan.name} vs ${opponent?.name ?? 'Opponent TBC'}',
                  style: _outfit(17, color: Colors.white, tracking: -.17),
                ),
                const SizedBox(height: 9),
                Text(
                  isSelected
                      ? 'Selected in the lineup${selectedCount == null ? '' : ' · $selectedCount named'}'
                      : selectedCount == null
                      ? 'View match details and lineup'
                      : '$selectedCount named in the lineup',
                  style: _jakarta(
                    11,
                    color: _light,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF24472C),
                minimumSize: const Size(0, 50),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 15,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                textStyle: _jakarta(13.5),
              ),
              child: const Text('Match details'),
            ),
          ),
        ],
      ),
    );
  }
}

class FieldrushAlsoBooked extends StatelessWidget {
  const FieldrushAlsoBooked({
    super.key,
    required this.title,
    required this.startsAt,
    required this.onTap,
    this.gameTimezone = 'UTC',
  });
  final String title;
  final DateTime startsAt;
  final VoidCallback onTap;
  final String gameTimezone;

  @override
  Widget build(BuildContext context) {
    final date = gameLocalDateTime(startsAt, gameTimezone);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: _border),
          borderRadius: BorderRadius.circular(18),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
            child: Row(
              children: [
                _DateTile(date: date, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ALSO BOOKED', style: _jakarta(9.5, tracking: 1.14)),
                      const SizedBox(height: 7),
                      Text('${_clock(date)} · $title', style: _outfit(13.5)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text('›', style: _jakarta(18)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DateTile extends StatelessWidget {
  const _DateTile({required this.date, required this.size});
  final DateTime date;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: _wash,
      borderRadius: BorderRadius.circular(13),
    ),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _weekday(date.weekday).substring(0, 3).toUpperCase(),
            style: _jakarta(8.5, tracking: .85),
          ),
          const SizedBox(height: 2),
          Text('${date.day}', style: _outfit(size == 40 ? 15 : 17)),
        ],
      ),
    ),
  );
}

class _KickoffTime extends StatelessWidget {
  const _KickoffTime({
    required this.date,
    required this.size,
    required this.color,
    this.periodColor,
  });
  final DateTime date;
  final double size;
  final Color color;
  final Color? periodColor;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          _clockDigits(date),
          style: _outfit(
            size,
            color: color,
            tracking: -size * .035,
          ).copyWith(height: .85),
        ),
        const SizedBox(width: 5),
        Text(
          date.hour >= 12 ? 'PM' : 'AM',
          style: _outfit(18, color: periodColor ?? color, tracking: .36),
        ),
      ],
    ),
  );
}

class FieldrushHomeRating extends StatelessWidget {
  const FieldrushHomeRating({
    super.key,
    required this.profile,
    this.rating,
    this.season,
    required this.onTap,
  });
  final PlayerProfile profile;
  final PlayerRatingLeaderboardEntry? rating;
  final LeaderboardSeason? season;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final matches =
        rating?.matchesPlayed ?? profile.playerRating?.matchesPlayed ?? 0;
    if (matches < 2) return _placement(matches);
    final value = rating?.skillRating ?? profile.playerRating?.skillRating;
    if (value == null) return _unavailable();
    final division = divisionFromRating(value);
    final n = division.number;
    final next = division.nextDivisionRating;
    final filled = (division.progressFor(value) * 10).round();
    final allEvents = [...?profile.playerRating?.currentPeriodEvents]
      ..sort((a, b) => a.playedAt.compareTo(b.playedAt));
    final events = allEvents.skip(math.max(0, allEvents.length - 5)).toList();
    final delta = events.fold<int>(0, (sum, event) => sum + event.ratingChange);
    final region =
        rating?.region.trim() ?? profile.playerRating?.region.trim() ?? '';
    final rank = rating?.rank ?? 0;
    final rankLine = rank > 0
        ? '#$rank${region.isEmpty ? '' : ' in ${_titleCase(region)}'} ›'
        : 'View ladder ›';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: _border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: InkWell(
          key: const ValueKey('home-skill-rating'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SpreadLabels(
                  left: Text(
                    _seasonLabel(season),
                    style: _jakarta(11, tracking: 1.54),
                  ),
                  right: Text(
                    rankLine,
                    style: _jakarta(11).copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 13),
                Wrap(
                  spacing: 12,
                  runSpacing: 7,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: '$value',
                        style: _outfit(
                          38,
                          tracking: -1.14,
                        ).copyWith(height: .85),
                        children: [
                          TextSpan(
                            text: '  SKILL RATING',
                            style: _jakarta(10, tracking: 1.2),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      _tiers[n]!.name,
                      style: _jakarta(
                        10,
                        color: _tiers[n]!.label,
                        tracking: 1.4,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _ShieldLadder(selected: n),
                const SizedBox(height: 14),
                _Segments(
                  count: 10,
                  filled: filled,
                  on: _tiers[n]!.progress,
                  off: const Color(0xFFEFEBDF),
                ),
                const SizedBox(height: 9),
                _SpreadLabels(
                  left: Text(
                    next == null
                        ? 'Top division'
                        : '${next - value} SR to Division ${n - 1}',
                    style: _jakarta(
                      11.5,
                      color: _ink,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                  right: Text(
                    next == null ? '1650+' : '$next · D${n - 1}',
                    style: _jakarta(10, tracking: .8),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.only(top: 15),
                  padding: const EdgeInsets.only(top: 14),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Color(0xFFF0ECE0))),
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('LAST 5', style: _jakarta(10, tracking: 1.2)),
                      if (events.isEmpty)
                        Text(
                          'No rated results yet',
                          style: _jakarta(
                            10.5,
                          ).copyWith(fontWeight: FontWeight.w600),
                        )
                      else ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < events.length; i++) ...[
                              if (i > 0) const SizedBox(width: 4),
                              _FormPip(event: events[i]),
                            ],
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              _signed(delta),
                              style: _outfit(
                                15,
                                color: delta > 0
                                    ? _green
                                    : delta < 0
                                    ? const Color(0xFFA63A3C)
                                    : _muted,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'SR',
                              style: _jakarta(
                                10.5,
                              ).copyWith(fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placement(int matches) {
    final played = matches.clamp(0, 2);
    final left = 2 - played;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment(-.423, -.906),
          end: Alignment(.423, .906),
          colors: [Color(0xFF1E2A23), Color(0xFF0B110D)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0A140E).withValues(alpha: .8),
            blurRadius: 34,
            spreadRadius: -22,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: CustomPaint(
        painter: const _PlacementBackgroundPainter(),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('home-rating-placement'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SpreadLabels(
                    left: Text(
                      '${_seasonLabel(season)} · PLACEMENT',
                      style: _jakarta(
                        9.5,
                        color: const Color(0xFFC9C2AE),
                        tracking: 1.7,
                      ),
                    ),
                    right: Text(
                      '$played / 2 ›',
                      style: _jakarta(
                        10,
                        color: const Color(0xFFA9B3A6),
                        tracking: .8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const _ShieldLadder(),
                  const SizedBox(height: 12),
                  _Segments(
                    count: 2,
                    filled: played,
                    on: const Color(0xFFF3EBD6),
                    off: const Color(0x29F3EBD6),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    '$left ${left == 1 ? 'game' : 'games'} to reveal your division',
                    style: _jakarta(
                      11.5,
                      color: const Color(0xFFF3EBD6),
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _unavailable() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
    child: TextButton(onPressed: onTap, child: const Text('View your rating')),
  );
}

class _SpreadLabels extends StatelessWidget {
  const _SpreadLabels({required this.left, required this.right});
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 275 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.2) {
        return Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [left, right],
        );
      }
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: left),
          const SizedBox(width: 10),
          Flexible(child: right),
        ],
      );
    },
  );
}

class _PlacementBackgroundPainter extends CustomPainter {
  const _PlacementBackgroundPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(24)),
    );
    for (final (center, radius, color) in [
      (
        Offset(size.width * .96, size.height * -.04),
        130.0,
        const Color(0x4DD9B04F),
      ),
      (
        Offset(size.width * 1.04, size.height * .46),
        150.0,
        const Color(0x573A5E99),
      ),
    ]) {
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0, .7],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    final lines = Paint()
      ..color = Colors.white.withValues(alpha: .05)
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width + size.height; x += 26) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x - size.height * .249, size.height),
        lines,
      );
    }
    canvas.drawCircle(
      Offset(47, size.height + 23),
      93,
      Paint()
        ..color = Colors.white.withValues(alpha: .09)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PlacementBackgroundPainter oldDelegate) =>
      false;
}

class _ShieldLadder extends StatelessWidget {
  const _ShieldLadder({this.selected});
  final int? selected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final n in [5, 4, 3, 2, 1])
          Expanded(
            child: Center(
              child: Opacity(
                opacity: selected == null || selected == n ? 1 : .42,
                child: FieldrushDivisionShield(
                  division: n,
                  size: selected == n ? 36 : 24,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _Segments extends StatelessWidget {
  const _Segments({
    required this.count,
    required this.filled,
    required this.on,
    required this.off,
  });
  final int count;
  final int filled;
  final Color on;
  final Color off;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 0; i < count; i++) ...[
        if (i > 0) const SizedBox(width: 3),
        Expanded(
          child: Container(
            height: 6,
            decoration: BoxDecoration(
              color: i < filled ? on : off,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    ],
  );
}

class _FormPip extends StatelessWidget {
  const _FormPip({required this.event});
  final ProfileRatingEvent event;

  @override
  Widget build(BuildContext context) {
    final result = switch (event.result.toUpperCase()) {
      'W' || 'WIN' => 'W',
      'L' || 'LOSS' => 'L',
      'D' || 'DRAW' => 'D',
      _ => '–',
    };
    return Semantics(
      label:
          '${event.opponentLabel}: ${result == 'W'
              ? 'win'
              : result == 'L'
              ? 'loss'
              : result == 'D'
              ? 'draw'
              : 'result unavailable'}, ${_signed(event.ratingChange)} skill rating',
      child: Container(
        key: ValueKey('home-rating-event-${event.id}'),
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: result == 'W'
              ? _green
              : result == 'L'
              ? const Color(0xFFF7E3E3)
              : _wash,
          borderRadius: BorderRadius.circular(7),
        ),
        child: FittedBox(
          child: Text(
            result,
            style: _outfit(
              11,
              color: result == 'W'
                  ? Colors.white
                  : result == 'L'
                  ? const Color(0xFFA63A3C)
                  : _muted,
            ),
          ),
        ),
      ),
    );
  }
}

class FieldrushDivisionShield extends StatelessWidget {
  const FieldrushDivisionShield({
    super.key,
    this.division = 5,
    this.size = 24,
    this.mini = false,
    this.placement = false,
  });
  final int division;
  final double size;
  final bool mini;
  final bool placement;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: placement ? 'Placement shield' : 'Division $division shield',
    child: SizedBox(
      width: size,
      height: (size * 1.16).roundToDouble(),
      child: CustomPaint(
        painter: FieldrushDivisionShieldPainter(
          division: division,
          mini: mini,
          placement: placement,
        ),
      ),
    ),
  );
}

class FieldrushDivisionShieldPainter extends CustomPainter {
  const FieldrushDivisionShieldPainter({
    required this.division,
    this.mini = false,
    this.placement = false,
  });
  final int division;
  final bool mini;
  final bool placement;

  Path _shield(Rect rect) {
    const points = [
      Offset(0, 0),
      Offset(1, 0),
      Offset(1, .54),
      Offset(.90, .74),
      Offset(.72, .89),
      Offset(.5, 1),
      Offset(.28, .89),
      Offset(.10, .74),
      Offset(0, .54),
    ];
    return Path()..addPolygon(
      points
          .map(
            (p) => Offset(
              rect.left + p.dx * rect.width,
              rect.top + p.dy * rect.height,
            ),
          )
          .toList(),
      true,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final tier = _tiers[division] ?? _tiers[5]!;
    final bounds = Offset.zero & size;
    final shape = _shield(bounds);
    if (!mini) {
      canvas.drawShadow(shape, Colors.black.withValues(alpha: .28), 4, false);
    }
    final rim = placement
        ? const SweepGradient(
            colors: [
              Color(0xFFA8703F),
              Color(0xFFC9D0D6),
              Color(0xFFE2BC5A),
              Color(0xFF3A5E99),
              Color(0xFFD9B25C),
              Color(0xFFA8703F),
            ],
            transform: GradientRotation(120 * math.pi / 180),
          )
        : LinearGradient(
            begin: const Alignment(-.342, -.940),
            end: const Alignment(.342, .940),
            colors: tier.rim,
          );
    canvas.drawPath(shape, Paint()..shader = rim.createShader(bounds));
    final inset = math.max(2, (size.width * .055).round()).toDouble();
    final faceBounds = bounds.deflate(inset);
    canvas.drawPath(
      _shield(faceBounds),
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-.5, -.866),
          end: const Alignment(.5, .866),
          colors: placement
              ? const [Color(0xFF2A382F), Color(0xFF101712)]
              : tier.face,
        ).createShader(faceBounds),
    );
    final stars = mini || placement || division == 5 ? 0 : 5 - division;
    final starSize = math.max(4, (size.width * .11).round()).toDouble();
    final starGap = math.max(1, (size.width * .025).round()).toDouble();
    final rowWidth = stars * starSize + math.max(0, stars - 1) * starGap;
    for (var i = 0; i < stars; i++) {
      final rect = Rect.fromLTWH(
        (size.width - rowWidth) / 2 + i * (starSize + starGap),
        (size.height * .12).roundToDouble(),
        starSize,
        starSize,
      );
      const star = [
        Offset(.5, 0),
        Offset(.61, .35),
        Offset(.98, .35),
        Offset(.68, .57),
        Offset(.79, .91),
        Offset(.5, .70),
        Offset(.21, .91),
        Offset(.32, .57),
        Offset(.02, .35),
        Offset(.39, .35),
      ];
      final path = Path()
        ..addPolygon(
          star
              .map(
                (p) => Offset(
                  rect.left + p.dx * rect.width,
                  rect.top + p.dy * rect.height,
                ),
              )
              .toList(),
          true,
        );
      canvas.drawPath(path, Paint()..color = tier.ink);
    }
    final painter = TextPainter(
      text: TextSpan(
        text: placement ? '?' : '$division',
        style: _outfit(
          (size.width * (mini ? .5 : .44)).roundToDouble(),
          color: placement ? const Color(0xFFF3EBD6) : tier.ink,
          tracking: -.03 * size.width,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final top = (size.height * (stars > 0 ? .27 : .10)).roundToDouble();
    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        top + ((size.height * .58).roundToDouble() - painter.height) / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant FieldrushDivisionShieldPainter oldDelegate) =>
      division != oldDelegate.division ||
      mini != oldDelegate.mini ||
      placement != oldDelegate.placement;
}

class _Tier {
  const _Tier(
    this.name,
    this.rim,
    this.face,
    this.ink,
    this.label,
    this.progress,
  );
  final String name;
  final List<Color> rim;
  final List<Color> face;
  final Color ink;
  final Color label;
  final Color progress;
}

const _tiers = {
  1: _Tier(
    'BLACK & GOLD',
    [Color(0xFFF6E3A6), Color(0xFFA8792A)],
    [Color(0xFF3B382E), Color(0xFF151411)],
    Color(0xFFE9CB7E),
    Color(0xFF26251F),
    Color(0xFF26251F),
  ),
  2: _Tier(
    'ROYAL',
    [Color(0xFFF6E3A6), Color(0xFFA8792A)],
    [Color(0xFF2E5191), Color(0xFF132650)],
    Color(0xFFF2D99A),
    Color(0xFF22406F),
    Color(0xFF22406F),
  ),
  3: _Tier(
    'GOLD',
    [Color(0xFFFFF6D8), Color(0xFFA8792A)],
    [Color(0xFFF7E1A2), Color(0xFFC2933C)],
    Color(0xFF3A2A08),
    Color(0xFF8A6416),
    Color(0xFFB8872E),
  ),
  4: _Tier(
    'SILVER',
    [Color(0xFFFFFFFF), Color(0xFF8D969E)],
    [Color(0xFFF7F8FA), Color(0xFFB7BFC6)],
    Color(0xFF2A333A),
    Color(0xFF56616B),
    Color(0xFF7D8892),
  ),
  5: _Tier(
    'BRONZE',
    [Color(0xFFF2C79C), Color(0xFF5E391E)],
    [Color(0xFFC98E5A), Color(0xFF7A4A27)],
    Color(0xFFFFF4E8),
    Color(0xFF9A6236),
    Color(0xFF9A6236),
  ),
};

class _DashedCardPainter extends CustomPainter {
  const _DashedCardPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.75),
          const Radius.circular(20),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (var offset = 0.0; offset < metric.length; offset += 9) {
        canvas.drawPath(
          metric.extractPath(offset, math.min(offset + 5, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCardPainter oldDelegate) =>
      color != oldDelegate.color;
}

class _HomePitchPainter extends CustomPainter {
  const _HomePitchPainter({required this.selected});
  final Set<OpenQueueRole> selected;

  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 22, size.height),
        Paint()
          ..color = (x ~/ 22).isEven
              ? const Color(0xFF3B7448)
              : const Color(0xFF3F7A4C),
      );
    }
    for (final role in selected) {
      final (left, width) = switch (role) {
        OpenQueueRole.goalkeeper => (.04, .15),
        OpenQueueRole.defender => (.19, .31),
        _ => (.50, .46),
      };
      canvas.drawRect(
        Rect.fromLTWH(
          size.width * left,
          10,
          size.width * width,
          size.height - 20,
        ),
        Paint()..color = Colors.white.withValues(alpha: .16),
      );
    }
    final line = Paint()
      ..color = Colors.white.withValues(alpha: .62)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final middle = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(12, 10, size.width - 12, size.height - 10),
        const Radius.circular(2),
      ),
      line,
    );
    canvas.drawLine(
      Offset(size.width / 2, 10),
      Offset(size.width / 2, size.height - 10),
      line,
    );
    canvas.drawCircle(Offset(size.width / 2, middle), 22, line);
    final dot = Paint()..color = line.color;
    canvas.drawCircle(Offset(size.width / 2, middle), 2, dot);
    for (final right in [false, true]) {
      final x = right ? size.width - 12 : 12.0;
      final direction = right ? -1.0 : 1.0;
      for (final (width, height) in [(44.0, 76.0), (16.0, 36.0)]) {
        canvas.drawPath(
          Path()
            ..moveTo(x, middle - height / 2)
            ..lineTo(x + direction * width, middle - height / 2)
            ..lineTo(x + direction * width, middle + height / 2)
            ..lineTo(x, middle + height / 2),
          line,
        );
      }
      canvas.drawCircle(Offset(x + direction * 30, middle), 1.5, dot);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(right ? size.width - 12 : 6, middle - 8, 6, 16),
          const Radius.circular(2),
        ),
        line,
      );
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(right ? size.width - 66 : 56, middle - 22, 10, 44),
      );
      canvas.drawCircle(Offset(right ? size.width - 42 : 42, middle), 22, line);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _HomePitchPainter oldDelegate) =>
      !setEquals(selected, oldDelegate.selected);
}

String _weekday(int weekday) => const [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][weekday - 1];
String _dateLabel(DateTime date) =>
    '${_weekday(date.weekday).substring(0, 3)}, ${date.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][date.month - 1]}';
String _clockDigits(DateTime date) =>
    '${date.hour % 12 == 0 ? 12 : date.hour % 12}:${date.minute.toString().padLeft(2, '0')}';
String _clock(DateTime date) =>
    '${_clockDigits(date)} ${date.hour >= 12 ? 'PM' : 'AM'}';
String _signed(int value) => value > 0
    ? '+$value'
    : value < 0
    ? '−${value.abs()}'
    : '0';
String _titleCase(String value) => value
    .replaceAll('_', ' ')
    .split(' ')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}')
    .join(' ');
String _seasonLabel(LeaderboardSeason? season) => season == null
    ? 'SKILL RATING'
    : RegExp(r'^S\d+$', caseSensitive: false).hasMatch(season.label)
    ? 'SEASON ${season.label.substring(1)}'
    : season.label.toUpperCase();
