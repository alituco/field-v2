import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../home/fieldrush_home_widgets.dart';
import 'leaderboard.dart';

const _ink = FieldrushAuthTheme.ink;
const _muted = FieldrushAuthTheme.muted;
const _border = FieldrushAuthTheme.border;
const _green = FieldrushAuthTheme.forest;
const _wash = Color(0xFFF2EFE3);

TextStyle _jakarta(
  double size, {
  Color color = _ink,
  double tracking = 0,
  FontWeight weight = FontWeight.w800,
}) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  fontWeight: weight,
  color: color,
  letterSpacing: tracking,
  height: 1.3,
);
TextStyle _outfit(double size, {Color color = _ink}) => TextStyle(
  fontFamily: 'Outfit',
  fontSize: size,
  fontWeight: FontWeight.w800,
  color: color,
  height: 1.1,
  letterSpacing: -.02 * size,
);

/// Fieldrush's Ranks layout. All displayed standings come from season data.
class FieldrushLeaderboardContent extends StatelessWidget {
  const FieldrushLeaderboardContent({
    super.key,
    required this.season,
    required this.onSeason,
    required this.players,
    required this.neighbors,
    required this.currentRating,
    required this.currentProfileId,
    required this.totalCount,
    required this.hasMore,
    required this.visibleCount,
    required this.loading,
    required this.loadingMore,
    required this.error,
    required this.pageError,
    required this.clans,
    required this.onBoard,
    required this.onPlayer,
    required this.onSearch,
    required this.onRefresh,
    required this.onMore,
    required this.onCollapse,
  });

  final LeaderboardSeason season;
  final ValueChanged<LeaderboardSeason> onSeason;
  final List<PlayerRatingLeaderboardEntry> players, neighbors;
  final PlayerRatingLeaderboardEntry? currentRating;
  final String? currentProfileId;
  final int? totalCount;
  final bool hasMore, loading, loadingMore, clans;
  final int visibleCount;
  final String? error, pageError;
  final ValueChanged<bool> onBoard;
  final ValueChanged<String> onPlayer;
  final VoidCallback onSearch, onMore, onCollapse;
  final Future<void> Function() onRefresh;

  bool get _home => currentRating?.region.trim().toLowerCase() == 'phoenix';
  bool get _placement =>
      _home && currentRating!.matchesPlayed < minimumPlayerLeaderboardMatches;

  List<PlayerRatingLeaderboardEntry> get _rows {
    final podiumIds = players.take(3).map((p) => p.profileId).toSet();
    final rest = players.where((p) => !podiumIds.contains(p.profileId));
    if (visibleCount > 0) return rest.take(visibleCount).toList();
    if (!_home || _placement || currentRating?.isRanked != true) {
      return rest.take(5).toList();
    }
    final around = neighbors.isNotEmpty
        ? neighbors
        : players.where((p) => (p.rank - currentRating!.rank).abs() <= 2);
    final byId = {
      for (final p in rest.take(2)) p.profileId: p,
      for (final p in around)
        if (!podiumIds.contains(p.profileId)) p.profileId: p,
    };
    final own = currentRating!;
    if (!podiumIds.contains(own.profileId)) byId[own.profileId] = own;
    return byId.values.toList()..sort((a, b) => a.rank.compareTo(b.rank));
  }

  @override
  Widget build(BuildContext context) {
    final top = players.take(3).toList();
    final podium = top.length == 3 ? [top[2], top[0], top[1]] : top;
    final rows = _rows;
    final more = visibleCount == 0
        ? players.length > 3 || hasMore
        : players.length > visibleCount + 3 || hasMore;
    final seasonIndex = leaderboardSeasons.indexWhere((s) => s.id == season.id);
    return ColoredBox(
      color: FieldrushAuthTheme.cream,
      child: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: _green,
          onRefresh: onRefresh,
          child: ListView(
            key: const ValueKey('ranks-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 132),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                child: _HeaderLayout(
                  children: [
                    Text('Ranks', style: _outfit(25)),
                    _RankButton(
                      label: 'Search players',
                      onTap: onSearch,
                      radius: 99,
                      padding: EdgeInsets.zero,
                      child: const SizedBox(
                        width: 36,
                        height: 36,
                        child: Icon(
                          Icons.search_rounded,
                          size: 19,
                          color: Color(0xFF3C4A38),
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      key: const ValueKey('ranks-city'),
                      tooltip: 'Choose city',
                      offset: const Offset(0, 44),
                      color: Colors.white,
                      surfaceTintColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        side: const BorderSide(color: _border),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      itemBuilder: (_) => [
                        PopupMenuItem<String>(
                          value: 'phoenix',
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('Phoenix, AZ', style: _jakarta(13)),
                                    const SizedBox(height: 5),
                                    Text(
                                      'Solo ladder is live',
                                      style: _jakarta(
                                        10.5,
                                        color: _muted,
                                        weight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Icon(Icons.check, color: _green, size: 16),
                            ],
                          ),
                        ),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: _border),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Phoenix, AZ', style: _jakarta(12)),
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.arrow_drop_down,
                              size: 15,
                              color: _muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                decoration: BoxDecoration(
                  color: _wash,
                  border: Border.all(color: _border),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    _SeasonArrow(
                      previous: true,
                      onTap: seasonIndex > 0
                          ? () => onSeason(leaderboardSeasons[seasonIndex - 1])
                          : null,
                    ),
                    Expanded(
                      child: Text(
                        'SEASON ${season.label.replaceFirst('S', '')}',
                        textAlign: TextAlign.center,
                        style: _jakarta(12.5, tracking: .75),
                      ),
                    ),
                    _SeasonArrow(
                      previous: false,
                      onTap:
                          seasonIndex >= 0 &&
                              seasonIndex < leaderboardSeasons.length - 1 &&
                              seasonIndex <
                                  leaderboardSeasons.indexWhere(
                                    (s) => s.id == activeLeaderboardSeason.id,
                                  )
                          ? () => onSeason(leaderboardSeasons[seasonIndex + 1])
                          : null,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 9, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: _BoardTab(
                        label: 'Solo',
                        selected: !clans,
                        onTap: () => onBoard(false),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: _BoardTab(
                        label: 'Clans',
                        selected: clans,
                        onTap: () => onBoard(true),
                      ),
                    ),
                  ],
                ),
              ),
              if (clans)
                _ClanComingSoon(onSolo: () => onBoard(false))
              else if (loading)
                const Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(
                    child: CircularProgressIndicator(color: _green),
                  ),
                )
              else if (error != null)
                _MessageCard(
                  title: 'Ranks unavailable',
                  message: error!,
                  onRetry: onRefresh,
                )
              else ...[
                if (_home)
                  _StandingCard(
                    rating: currentRating!,
                    onTap: () => onPlayer(currentRating!.profileId),
                  )
                else if (currentRating != null)
                  _MessageCard(
                    title: 'VIEWING PHOENIX',
                    message:
                        'Your rating is in ${_marketLabel(currentRating!.region)}. This ladder is view only.',
                  )
                else
                  _MessageCard(
                    title: 'Your standing is unavailable',
                    message: 'The Phoenix ladder is available below.',
                    onRetry: onRefresh,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      Text(
                        'TOP PLAYERS',
                        style: _jakarta(11, color: _muted, tracking: 1.54),
                      ),
                      Text(
                        totalCount == null
                            ? '${players.length} shown'
                            : '$totalCount ranked ${totalCount == 1 ? 'player' : 'players'}',
                        style: _jakarta(
                          11,
                          color: _muted,
                          weight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (players.isEmpty)
                  const _MessageCard(
                    title: 'The ladder starts here',
                    message:
                        'No ranked players this season yet. Complete 2 rated games to reveal your division.',
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 11, 16, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < podium.length; i++) ...[
                          if (i > 0) const SizedBox(width: 9),
                          Expanded(
                            child: _PodiumPlayer(
                              player: podium[i],
                              you: podium[i].profileId == currentProfileId,
                              onTap: () => onPlayer(podium[i].profileId),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (rows.isNotEmpty || _placement) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                    child: Text(
                      visibleCount > 0
                          ? 'FULL LADDER'
                          : _home && !_placement && currentRating!.isRanked
                          ? 'AROUND YOU'
                          : 'PHOENIX LADDER',
                      style: _jakarta(11, color: _muted, tracking: 1.54),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 11, 16, 0),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: _border),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < rows.length; i++)
                          _PlayerRow(
                            player: rows[i],
                            you: rows[i].profileId == currentProfileId,
                            border: i < rows.length - 1 || _placement,
                            onTap: () => onPlayer(rows[i].profileId),
                          ),
                        if (_placement)
                          _PlacementRow(
                            rating: currentRating!,
                            onTap: () => onPlayer(currentRating!.profileId),
                          ),
                      ],
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (pageError != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            pageError!,
                            style: _jakarta(
                              11.5,
                              color: FieldrushAuthTheme.danger,
                            ),
                          ),
                        ),
                      if (more)
                        _RankButton(
                          key: const ValueKey('ranks-more'),
                          onTap: loadingMore ? null : onMore,
                          child: Text(
                            loadingMore
                                ? 'Loading…'
                                : pageError != null
                                ? 'Try again'
                                : visibleCount == 0
                                ? 'See full Phoenix ladder'
                                : totalCount == null
                                ? 'Show more'
                                : 'Show ${math.min(20, math.max(0, totalCount! - visibleCount - 3))} more',
                            style: _jakarta(12.5),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      if (visibleCount > 0)
                        TextButton(
                          key: const ValueKey('ranks-collapse'),
                          onPressed: onCollapse,
                          child: Text(
                            'Show less',
                            style: _jakarta(12, color: _green),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        'Solo skill rating moves on every rated game. Complete 2 rated games in a season to join the ladder.',
                        style: _jakarta(
                          11.5,
                          color: _muted,
                          weight: FontWeight.w600,
                        ).copyWith(height: 1.5),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderLayout extends StatelessWidget {
  const _HeaderLayout({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 330 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.2) {
        return Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: children,
        );
      }
      return Row(
        children: [
          Expanded(child: children.first),
          children[1],
          const SizedBox(width: 12),
          children[2],
        ],
      );
    },
  );
}

class _SeasonArrow extends StatelessWidget {
  const _SeasonArrow({required this.previous, this.onTap});
  final bool previous;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: previous ? 'Previous season' : 'Next season',
    onPressed: onTap,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 34, height: 34),
    visualDensity: VisualDensity.compact,
    icon: Icon(
      previous ? Icons.chevron_left : Icons.chevron_right,
      size: 20,
      color: onTap == null ? const Color(0xFFB3B7A6) : _ink,
    ),
  );
}

class _BoardTab extends StatelessWidget {
  const _BoardTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: _RankButton(
      onTap: onTap,
      radius: 13,
      color: selected ? _green : Colors.white,
      border: selected ? _green : _border,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: _jakarta(
          12,
          color: selected ? Colors.white : const Color(0xFF3C4A38),
        ),
      ),
    ),
  );
}

class _RankButton extends StatelessWidget {
  const _RankButton({
    super.key,
    required this.child,
    this.onTap,
    this.label,
    this.radius = 14,
    this.color = Colors.white,
    this.border = _border,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
  });
  final Widget child;
  final VoidCallback? onTap;
  final String? label;
  final double radius;
  final Color color, border;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Material(
      color: color,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: border),
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    ),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.title,
    required this.message,
    this.onRetry,
  });
  final String title, message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: _jakarta(12.5)),
        const SizedBox(height: 8),
        Text(
          message,
          style: _jakarta(
            12,
            color: _muted,
            weight: FontWeight.w600,
          ).copyWith(height: 1.5),
        ),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}

class _ClanComingSoon extends StatelessWidget {
  const _ClanComingSoon({required this.onSolo});
  final VoidCallback onSolo;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: CustomPaint(
      painter: const _DashedBorder(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF7EED6),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                'COMING SOON',
                style: _jakarta(
                  9.5,
                  color: const Color(0xFF8A6516),
                  tracking: 1.14,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Clan ladders are coming',
              textAlign: TextAlign.center,
              style: _outfit(21),
            ),
            const SizedBox(height: 8),
            Text(
              'Clans get ranked once clan games start. The solo ladder is live now.',
              textAlign: TextAlign.center,
              style: _jakarta(
                12,
                color: _muted,
                weight: FontWeight.w600,
              ).copyWith(height: 1.5),
            ),
            const SizedBox(height: 18),
            _RankButton(
              onTap: onSolo,
              radius: 13,
              child: Text('See solo ladder', style: _jakarta(12.5)),
            ),
          ],
        ),
      ),
    ),
  );
}

class _StandingCard extends StatelessWidget {
  const _StandingCard({required this.rating, required this.onTap});
  final PlayerRatingLeaderboardEntry rating;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final placement = rating.matchesPlayed < minimumPlayerLeaderboardMatches;
    final palette = _palettes[placement ? 0 : rating.division.number]!;
    final next = rating.division.nextDivisionRating;
    final count = placement ? 2 : 10;
    final filled = placement
        ? rating.matchesPlayed.clamp(0, 2)
        : (rating.division.progressFor(rating.skillRating) * 10).round();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .35),
            blurRadius: 34,
            spreadRadius: -22,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: const Alignment(-.423, -.906),
              end: const Alignment(.423, .906),
              colors: palette.colors,
            ),
          ),
          child: CustomPaint(
            painter: _StandingBackground(
              palette: palette,
              placement: placement,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('ranks-standing'),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 10,
                        runSpacing: 6,
                        children: [
                          Text(
                            'YOUR STANDING',
                            style: _jakarta(
                              9.5,
                              color: palette.accent,
                              tracking: 1.71,
                            ),
                          ),
                          if (!placement && rating.matchesPlayed > 0)
                            Text(
                              '${_signed(rating.lastChange)} SR last game',
                              style: _jakarta(
                                11.5,
                                color: palette.ink,
                                weight: FontWeight.w700,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          FieldrushDivisionShield(
                            size: 62,
                            division: rating.division.number,
                            placement: placement,
                          ),
                          const SizedBox(width: 15),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  placement
                                      ? '#?'
                                      : rating.isRanked
                                      ? '#${rating.rank}'
                                      : '—',
                                  style: _outfit(
                                    46,
                                    color: palette.ink,
                                  ).copyWith(height: .9),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'in Phoenix · ${placement ? '????' : rating.skillRating} skill rating',
                                  style: _jakarta(
                                    11.5,
                                    color: palette.ink,
                                    weight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          for (var i = 0; i < count; i++) ...[
                            if (i > 0) const SizedBox(width: 3),
                            Expanded(
                              child: Container(
                                height: 6,
                                decoration: BoxDecoration(
                                  color: i < filled ? palette.on : palette.off,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 10,
                        runSpacing: 6,
                        children: [
                          Text(
                            placement
                                ? '${2 - filled} ${2 - filled == 1 ? 'game' : 'games'} to reveal your division'
                                : next == null
                                ? 'Top division'
                                : '${next - rating.skillRating} SR to Division ${rating.division.number - 1}',
                            style: _jakarta(
                              11.5,
                              color: palette.ink,
                              weight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            placement
                                ? '$filled / 2'
                                : next == null
                                ? '1650+'
                                : '$next · D${rating.division.number - 1} ›',
                            style: _jakarta(
                              10,
                              color: palette.accent,
                              tracking: .8,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PodiumPlayer extends StatelessWidget {
  const _PodiumPlayer({
    required this.player,
    required this.you,
    required this.onTap,
  });
  final PlayerRatingLeaderboardEntry player;
  final bool you;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final first = player.rank == 1;
    return _RankButton(
      key: ValueKey('ranks-podium-${player.profileId}'),
      onTap: onTap,
      radius: 16,
      color: you ? const Color(0xFFEFF6E4) : Colors.white,
      border: you ? const Color(0xFFC7DD9B) : _border,
      padding: EdgeInsets.fromLTRB(10, first ? 16 : 13, 10, first ? 15 : 13),
      child: Column(
        children: [
          _PlayerBadge(
            player: player,
            you: you,
            size: first ? 62 : 52,
            podium: true,
            first: first,
          ),
          const SizedBox(height: 9),
          Text(
            you ? 'You' : player.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _jakarta(11.5, weight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text('${player.skillRating}', style: _outfit(first ? 19 : 16)),
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: first ? const Color(0xFFA7C957) : _wash,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              '${player.rank}',
              style: _jakarta(
                9.5,
                color: first ? const Color(0xFF1F2A0C) : _muted,
                tracking: .76,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.player,
    required this.you,
    required this.border,
    required this.onTap,
  });
  final PlayerRatingLeaderboardEntry player;
  final bool you, border;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: you ? const Color(0xFFEFF6E4) : Colors.white,
    child: InkWell(
      key: ValueKey('ranks-player-${player.profileId}'),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 15, vertical: you ? 14 : 12),
        decoration: BoxDecoration(
          border: border
              ? const Border(bottom: BorderSide(color: Color(0xFFF0ECE0)))
              : null,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(
                '${player.rank}',
                style: _outfit(
                  13,
                  color: you ? const Color(0xFF24472C) : _muted,
                ),
              ),
            ),
            const SizedBox(width: 12),
            _PlayerBadge(player: player, you: you, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    you ? 'You' : player.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _jakarta(
                      13,
                      weight: you ? FontWeight.w800 : FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${player.divisionLabel} · ${player.recordLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _jakarta(
                      10.5,
                      color: _muted,
                      weight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${player.skillRating}', style: _outfit(13.5)),
                const SizedBox(height: 4),
                Semantics(
                  label:
                      '${_signed(player.lastChange)} skill rating from last game',
                  child: Text(
                    _signed(player.lastChange),
                    style: _jakarta(
                      10,
                      color: player.lastChange < 0
                          ? FieldrushAuthTheme.danger
                          : player.lastChange > 0
                          ? _green
                          : _muted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _PlayerBadge extends StatelessWidget {
  const _PlayerBadge({
    required this.player,
    required this.you,
    required this.size,
    this.podium = false,
    this.first = false,
  });
  final PlayerRatingLeaderboardEntry player;
  final bool you, podium, first;
  final double size;
  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: first || you
              ? _green
              : podium
              ? const Color(0xFFDDE8C4)
              : _wash,
          borderRadius: BorderRadius.circular(
            podium ? (size / 3.4).roundToDouble() : 11,
          ),
        ),
        child: player.avatarUrl?.trim().isNotEmpty == true
            ? Image.network(
                player.avatarUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _initials(),
              )
            : _initials(),
      ),
      Positioned(
        right: podium ? -7 : -9,
        bottom: podium ? -7 : -9,
        child: FieldrushDivisionShield(
          division: player.division.number,
          size: podium ? 22 : 18,
        ),
      ),
    ],
  );
  Widget _initials() => Center(
    child: Text(
      you
          ? 'YOU'
          : player.initials.isEmpty
          ? '?'
          : player.initials,
      style: _outfit(
        first
            ? 22
            : podium
            ? 18
            : 12,
        color: first || you
            ? Colors.white
            : podium
            ? const Color(0xFF24472C)
            : const Color(0xFF3C4A38),
      ),
    ),
  );
}

class _PlacementRow extends StatelessWidget {
  const _PlacementRow({required this.rating, required this.onTap});
  final PlayerRatingLeaderboardEntry rating;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFFFBFAF4),
    child: InkWell(
      key: const ValueKey('ranks-placement-row'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text('–', style: _outfit(12, color: _muted)),
            ),
            const SizedBox(width: 11),
            const FieldrushDivisionShield(size: 20, placement: true),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('You', style: _jakarta(13, weight: FontWeight.w700)),
                  const SizedBox(height: 5),
                  Text(
                    'Placement · ${rating.matchesPlayed.clamp(0, 2)} of 2 played',
                    style: _jakarta(
                      10.5,
                      color: _muted,
                      weight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('????', style: _outfit(14)),
          ],
        ),
      ),
    ),
  );
}

class _Palette {
  const _Palette(
    this.colors,
    this.ink,
    this.accent,
    this.on,
    this.off,
    this.lines,
    this.circle,
  );
  final List<Color> colors;
  final Color ink, accent, on, off, lines, circle;
}

const _palettes = {
  0: _Palette(
    [Color(0xFF1E2A23), Color(0xFF0B110D)],
    Color(0xFFF3EBD6),
    Color(0xFFC9C2AE),
    Color(0xFFF3EBD6),
    Color(0x29F3EBD6),
    Color(0x0DFFFFFF),
    Color(0x17FFFFFF),
  ),
  1: _Palette(
    [Color(0xFF26251F), Color(0xFF0E0E0C)],
    Color(0xFFF6E7C1),
    Color(0xFFD9B25C),
    Color(0xFFE3C27A),
    Color(0x1FFFFFFF),
    Color(0x12FFFFFF),
    Color(0x47D9B25C),
  ),
  2: _Palette(
    [Color(0xFF22406F), Color(0xFF101F40)],
    Colors.white,
    Color(0xFFE9CB7E),
    Color(0xFFE9CB7E),
    Color(0x24FFFFFF),
    Color(0x1AFFFFFF),
    Color(0x3DE9CB7E),
  ),
  3: _Palette(
    [Color(0xFFEBC86C), Color(0xFFAB7C28)],
    Color(0xFF2B1E06),
    Color(0xFF4A360B),
    Color(0xFF3A2A08),
    Color(0x292B1E06),
    Color(0x143C2805),
    Color(0x263C2805),
  ),
  4: _Palette(
    [Color(0xFFE8ECEF), Color(0xFFA6AFB7)],
    Color(0xFF1E252B),
    Color(0xFF3A4550),
    Color(0xFF2F3940),
    Color(0x261E252B),
    Color(0x121E252B),
    Color(0x211E252B),
  ),
  5: _Palette(
    [Color(0xFF9A6236), Color(0xFF5A3519)],
    Color(0xFFFFF4E8),
    Color(0xFFF6D2AE),
    Color(0xFFF7D5AE),
    Color(0x42000000),
    Color(0x1FFFFFFF),
    Color(0x26FFFFFF),
  ),
};

class _StandingBackground extends CustomPainter {
  const _StandingBackground({required this.palette, required this.placement});
  final _Palette palette;
  final bool placement;
  @override
  void paint(Canvas canvas, Size size) {
    if (placement) {
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
          Offset.zero & size,
          Paint()
            ..shader = RadialGradient(
              colors: [color, color.withValues(alpha: 0)],
              stops: const [0, .7],
            ).createShader(Rect.fromCircle(center: center, radius: radius)),
        );
      }
    }
    final line = Paint()
      ..color = palette.lines
      ..strokeWidth = 1;
    for (double x = 0; x < size.width + size.height; x += 26) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x - size.height * .249, size.height),
        line,
      );
    }
    canvas.drawCircle(
      Offset(47, size.height - 23),
      93,
      Paint()
        ..color = palette.circle
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _StandingBackground oldDelegate) =>
      palette != oldDelegate.palette || placement != oldDelegate.placement;
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder();
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.75),
          const Radius.circular(22),
        ),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFFDED8C6);
    for (final metric in path.computeMetrics()) {
      for (double offset = 0; offset < metric.length; offset += 10) {
        canvas.drawPath(
          metric.extractPath(offset, math.min(offset + 5, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorder oldDelegate) => false;
}

String _signed(int value) => value > 0
    ? '+$value'
    : value < 0
    ? '−${-value}'
    : '0';
String _marketLabel(String region) => region.trim().isEmpty
    ? 'another market'
    : region
          .trim()
          .split(RegExp(r'[_\s-]+'))
          .map((s) => '${s[0].toUpperCase()}${s.substring(1)}')
          .join(' ');
