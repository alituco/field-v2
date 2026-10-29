import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../home/fieldrush_home_widgets.dart';
import '../leaderboard/leaderboard.dart';
import '../leaderboard/fieldrush_rating_tracks.dart';
import '../leaderboard/fieldrush_rating_role_tabs.dart';
import '../ranking/rating_division.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_avatar_image.dart';
import 'fieldrush_you_widgets.dart';
import 'profile.dart';

const _ink = FieldrushAuthTheme.ink;
const _muted = FieldrushAuthTheme.muted;
const _border = FieldrushAuthTheme.border;
const _green = FieldrushAuthTheme.forest;
const _danger = FieldrushAuthTheme.danger;

TextStyle _jakarta(double size, {Color color = _ink, double tracking = 0}) =>
    TextStyle(
      fontFamily: 'PlusJakartaSans',
      fontWeight: FontWeight.w800,
      fontSize: size,
      height: 1,
      letterSpacing: tracking,
      color: color,
    );

TextStyle _outfit(double size, {Color color = _ink, double height = 1}) =>
    TextStyle(
      fontFamily: 'Outfit',
      fontWeight: FontWeight.w800,
      fontSize: size,
      height: height,
      letterSpacing: -size * .02,
      color: color,
    );

/// Reference-matched public player presentation. The owner supplies scrolling,
/// safe areas, authenticated actions, and verified public statistics.
///
/// Results are supplied newest first and shown chronologically. Null results
/// are unknown outcomes, never assumed draws.
/// Missing values remain unknown; private account fields are never displayed.
class FieldrushPlayerProfileContent extends StatelessWidget {
  const FieldrushPlayerProfileContent({
    super.key,
    required this.profile,
    required this.isFollowing,
    required this.followBusy,
    required this.onBack,
    this.onFollow,
    this.onReport,
    this.onBlock,
    this.blockBusy = false,
    this.onOpenClan,
    this.positionLabel,
    this.onMatchHistory,
    this.onClip,
    this.onAllClips,
    this.recentResults = const [],
    this.trailingChildren = const [],
    this.ratings,
    this.track = RatingTrack.outfield,
    this.onTrack,
    this.ratingUnavailable = false,
    this.ratingLoading = false,
    this.detailsLoading = false,
    this.detailsUnavailable = false,
  });

  final PlayerProfile profile;
  final bool isFollowing;
  final bool followBusy;
  final VoidCallback? onBack;
  final VoidCallback? onFollow;
  final VoidCallback? onReport;
  final VoidCallback? onBlock;
  final bool blockBusy;
  final VoidCallback? onOpenClan;
  final String? positionLabel;
  final VoidCallback? onMatchHistory;
  final ValueChanged<ProfileHighlight>? onClip;
  final VoidCallback? onAllClips;
  final List<ProfileGameOutcome?> recentResults;
  final List<Widget> trailingChildren;
  final FieldrushPlayerRatings? ratings;
  final RatingTrack track;
  final ValueChanged<RatingTrack>? onTrack;
  final bool ratingUnavailable;
  final bool ratingLoading;
  final bool detailsLoading;
  final bool detailsUnavailable;

  bool get _detailsReady => !detailsLoading && !detailsUnavailable;

  PlayerRatingLeaderboardEntry? get _trackRating => ratings?.forTrack(track);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _PlayerHeader(name: profile.displayName, onBack: onBack),
      Padding(
        key: const ValueKey('player-rating-section'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: _PlayerRatingCard(
          profile: profile,
          ratingOverride: _trackRating,
          unavailable: ratingUnavailable,
          loading: ratingLoading,
          roleTabs: onTrack == null
              ? null
              : FieldrushRatingRoleTabs(
                  selected: track,
                  ratings: ratings,
                  onChanged: onTrack!,
                  dark:
                      _trackRating?.ratingVisible != true ||
                      ![3, 4].contains(_trackRating?.division?.number),
                ),
          positionLabel: positionLabel,
          isFollowing: isFollowing,
          followBusy: followBusy,
          followKnown: _detailsReady,
          onFollow: onFollow,
        ),
      ),
      if (_detailsReady && onMatchHistory != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Builder(
            builder: (context) {
              final games = <String, ProfilePreviousGame>{
                for (final game in profile.previousGames)
                  if (game.id.trim().isNotEmpty)
                    '${game.type.name}:${game.id}': game,
              }.values;
              return FieldrushMatchRecordCard(
                key: const ValueKey('player-match-record'),
                wins: games
                    .where((game) => game.outcome == ProfileGameOutcome.win)
                    .length,
                draws: games
                    .where((game) => game.outcome == ProfileGameOutcome.draw)
                    .length,
                losses: games
                    .where((game) => game.outcome == ProfileGameOutcome.loss)
                    .length,
                played: games.length,
                resultsKnown: games.every((game) => game.outcome != null),
                actionKey: const ValueKey('player-match-history'),
                onTap: onMatchHistory!,
              );
            },
          ),
        ),
      if (!_detailsReady)
        Padding(
          key: const ValueKey('player-details-status'),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            detailsLoading
                ? 'Loading player details…'
                : 'Player details unavailable. Try again to load them.',
          ),
        ),
      if (_detailsReady || ratings != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _LastFive(
            results: ratings == null
                ? recentResults
                : ratings!
                      .eventsFor(track)
                      .take(5)
                      .map(
                        (event) => switch (event.result) {
                          'WIN' => ProfileGameOutcome.win,
                          'LOSS' => ProfileGameOutcome.loss,
                          'DRAW' => ProfileGameOutcome.draw,
                          _ => null,
                        },
                      )
                      .toList(),
          ),
        ),
      if (_detailsReady)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _PlayerClan(clan: profile.clan, onTap: onOpenClan),
        ),
      if (_detailsReady && onClip != null)
        FieldrushProfileClips(
          key: const ValueKey('player-clips'),
          highlights: profile.highlights,
          onClip: onClip!,
          onAllClips: onAllClips,
          clipKeyPrefix: 'player',
        ),
      if (onBlock != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextButton.icon(
            key: const ValueKey('player-block-action'),
            onPressed: blockBusy ? null : onBlock,
            icon: const Icon(Icons.block_outlined, size: 16),
            label: Text(blockBusy ? 'Updating…' : 'Block player'),
          ),
        ),
      if (onReport != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Center(
            child: TextButton.icon(
              key: const ValueKey('player-report'),
              onPressed: onReport,
              style: TextButton.styleFrom(
                foregroundColor: _danger,
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: _jakarta(12, color: _danger),
                iconSize: 14,
              ),
              icon: const Icon(Icons.outlined_flag),
              label: const Text('Report player'),
            ),
          ),
        ),
      ...trailingChildren,
      const SizedBox(height: 28),
    ],
  );
}

class _PlayerHeader extends StatelessWidget {
  const _PlayerHeader({required this.name, required this.onBack});
  final String name;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 20, 0),
    child: Row(
      children: [
        Semantics(
          button: true,
          enabled: onBack != null,
          label: 'Back',
          child: InkResponse(
            key: const ValueKey('player-back'),
            onTap: onBack,
            radius: 24,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: _border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ExcludeSemantics(
                    child: Text(
                      '‹',
                      style: _jakarta(20, color: const Color(0xFF3C4A38)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(name, style: _outfit(18))),
      ],
    ),
  );
}

class _PlayerRatingCard extends StatelessWidget {
  const _PlayerRatingCard({
    required this.profile,
    required this.positionLabel,
    required this.isFollowing,
    required this.followBusy,
    required this.onFollow,
    this.ratingOverride,
    this.roleTabs,
    this.unavailable = false,
    this.loading = false,
    this.followKnown = true,
  });
  final PlayerProfile profile;
  final String? positionLabel;
  final bool isFollowing;
  final bool followBusy;
  final VoidCallback? onFollow;
  final PlayerRatingLeaderboardEntry? ratingOverride;
  final Widget? roleTabs;
  final bool unavailable;
  final bool loading;
  final bool followKnown;

  @override
  Widget build(BuildContext context) {
    final override = ratingOverride;
    final rating = unavailable
        ? null
        : override == null
        ? profile.playerRating
        : ProfilePlayerRating(
            skillRating: override.skillRating,
            matchesPlayed: override.matchesPlayed,
            wins: override.wins,
            losses: override.losses,
            draws: override.draws,
            lastChange: override.lastChange,
            visibility: override.visibility,
            region: override.region,
            events: const [],
          );
    final placement = rating != null && !rating.ratingVisible;
    final division = rating == null || placement
        ? null
        : divisionFromRating(rating.skillRating!).number;
    final palette = _palettes[division] ?? _placementPalette;
    final light = division == 3 || division == 4;
    final heading = loading
        ? 'LOADING RATING'
        : rating == null
        ? 'RATING UNAVAILABLE'
        : placement
        ? 'PLACEMENT'
        : 'DIVISION $division';
    return DecoratedBox(
      key: const ValueKey('profile-player-rating-card'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: palette.shadow,
            offset: const Offset(0, 18),
            blurRadius: 34,
            spreadRadius: -22,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: DecoratedBox(
          key: ValueKey(
            loading
                ? 'player-rating-loading'
                : rating == null
                ? 'player-rating-unavailable'
                : placement
                ? 'player-rating-placement'
                : 'player-rating-ranked',
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: const Alignment(-.423, -.906),
              end: const Alignment(.423, .906),
              colors: palette.background,
            ),
          ),
          child: CustomPaint(
            painter: _PlayerCardPainter(palette: palette),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 19),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (roleTabs != null) ...[
                    Align(alignment: Alignment.centerLeft, child: roleTabs!),
                    const SizedBox(height: 14),
                  ],
                  Row(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 58,
                            height: 58,
                            alignment: Alignment.center,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(
                                alpha: light ? .55 : .14,
                              ),
                              border: Border.all(
                                color: light
                                    ? const Color(0x14000000)
                                    : const Color(0x3DFFFFFF),
                                width: 1.5,
                              ),
                              borderRadius: BorderRadius.circular(19),
                            ),
                            child: _PlayerAvatar(
                              profile: profile,
                              color: palette.ink,
                            ),
                          ),
                          if (rating != null)
                            Positioned(
                              right: -8,
                              bottom: -8,
                              child: FieldrushDivisionShield(
                                division: division ?? 5,
                                size: 22,
                                mini: true,
                                placement: placement,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              heading,
                              style: _jakarta(
                                9.5,
                                color: palette.accent,
                                tracking: 1.71,
                              ),
                            ),
                            const SizedBox(height: 9),
                            Text(
                              profile.displayName,
                              style: _outfit(
                                19,
                                color: palette.ink,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '@${profile.username}',
                              style: _jakarta(
                                12,
                                color: palette.ink,
                              ).copyWith(fontWeight: FontWeight.w700),
                            ),
                            if (positionLabel?.trim().isNotEmpty == true) ...[
                              const SizedBox(height: 7),
                              Text(
                                positionLabel!,
                                key: const ValueKey('player-played-position'),
                                style: _jakarta(11, color: palette.accent)
                                    .copyWith(
                                      height: 1.35,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final scoreText = Text(
                        rating == null
                            ? '—'
                            : placement
                            ? '????'
                            : '${rating.skillRating}',
                        style: _outfit(
                          40,
                          color: palette.ink,
                          height: .82,
                        ).copyWith(letterSpacing: -1.6),
                      );
                      final scoreLabel = Text(
                        'SKILL RATING',
                        style: _jakarta(
                          10,
                          color: palette.accent,
                          tracking: 1.2,
                        ),
                      );
                      final largeText =
                          MediaQuery.textScalerOf(context).scale(40) > 60;
                      final score = Semantics(
                        label: loading
                            ? 'Skill rating loading'
                            : rating == null
                            ? 'Skill rating unavailable'
                            : placement
                            ? 'Skill rating hidden until placement is complete'
                            : 'Skill rating ${rating.skillRating}',
                        child: ExcludeSemantics(
                          child: largeText
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    scoreText,
                                    const SizedBox(height: 8),
                                    scoreLabel,
                                  ],
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    scoreText,
                                    const SizedBox(width: 7),
                                    Flexible(child: scoreLabel),
                                  ],
                                ),
                        ),
                      );
                      final follow = !followKnown
                          ? const SizedBox.shrink()
                          : _FollowButton(
                              isFollowing: isFollowing,
                              busy: followBusy,
                              onPressed: onFollow,
                              palette: palette,
                              light: light,
                            );
                      if (constraints.maxWidth < 285 ||
                          MediaQuery.textScalerOf(context).scale(12) > 15) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            score,
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerRight,
                              child: follow,
                            ),
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(child: score),
                          const SizedBox(width: 12),
                          follow,
                        ],
                      );
                    },
                  ),
                  if (placement) ...[
                    const SizedBox(height: 12),
                    Text(
                      '${2 - rating.placementMatchesRemaining}/$minimumPlayerLeaderboardMatches placement games',
                      style: _jakarta(
                        11,
                        color: palette.accent,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerAvatar extends StatelessWidget {
  const _PlayerAvatar({required this.profile, required this.color});
  final PlayerProfile profile;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final initials = Center(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            profile.initials,
            maxLines: 1,
            softWrap: false,
            style: _outfit(20, color: color),
          ),
        ),
      ),
    );
    final url = profile.avatarUrl?.trim();
    return FieldrushAvatarImage(
      url: url,
      size: 58,
      excludeFromSemantics: true,
      fallback: initials,
    );
  }
}

class _FollowButton extends StatelessWidget {
  const _FollowButton({
    required this.isFollowing,
    required this.busy,
    required this.onPressed,
    required this.palette,
    required this.light,
  });
  final bool isFollowing;
  final bool busy;
  final VoidCallback? onPressed;
  final _PlayerPalette palette;
  final bool light;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: !busy && onPressed != null,
    onTap: busy ? null : onPressed,
    liveRegion: busy,
    label: busy
        ? 'Updating follow status'
        : isFollowing
        ? 'Following. Tap to unfollow'
        : 'Follow player',
    child: ExcludeSemantics(
      child: TextButton(
        key: const ValueKey('player-follow'),
        onPressed: busy ? null : onPressed,
        style: TextButton.styleFrom(
          foregroundColor: isFollowing
              ? palette.ink
              : light
              ? Colors.white
              : palette.followInk,
          disabledForegroundColor: isFollowing
              ? palette.ink.withValues(alpha: .65)
              : palette.followInk.withValues(alpha: .65),
          backgroundColor: isFollowing ? Colors.transparent : palette.ink,
          minimumSize: const Size(44, 38),
          padding: EdgeInsets.symmetric(horizontal: isFollowing ? 16 : 18),
          tapTargetSize: MaterialTapTargetSize.padded,
          visualDensity: VisualDensity.standard,
          shape: StadiumBorder(
            side: isFollowing
                ? BorderSide(color: palette.ink, width: 1.5)
                : BorderSide.none,
          ),
          textStyle: _jakarta(12),
        ),
        child: Text(isFollowing ? 'Following' : 'Follow'),
      ),
    ),
  );
}

class _LastFive extends StatelessWidget {
  const _LastFive({required this.results});
  final List<ProfileGameOutcome?> results;

  @override
  Widget build(BuildContext context) {
    final lastFive = results.take(5).toList().reversed.toList();
    return _WhiteCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Tooltip(
              message:
                  'Most recent played solo and clan games, oldest to newest. A dash means the result is unavailable.',
              child: Text(
                'LAST FIVE',
                style: _jakarta(
                  11,
                  color: const Color(0xFF24472C),
                  tracking: 1.32,
                ),
              ),
            ),
            const SizedBox(height: 13),
            Row(
              children: [
                for (var i = 0; i < 5; i++) ...[
                  if (i != 0) const SizedBox(width: 7),
                  Expanded(
                    child: _ResultPip(
                      key: ValueKey('player-result-$i'),
                      result: i < lastFive.length ? lastFive[i] : null,
                      hasGame: i < lastFive.length,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultPip extends StatelessWidget {
  const _ResultPip({super.key, required this.result, required this.hasGame});
  final ProfileGameOutcome? result;
  final bool hasGame;

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        result?.label ?? (hasGame ? 'Result unavailable' : 'No completed game'),
    child: ExcludeSemantics(
      child: Container(
        constraints: const BoxConstraints(minHeight: 34),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: switch (result) {
            ProfileGameOutcome.win => _green,
            ProfileGameOutcome.loss => const Color(0xFFF7E3E3),
            _ => const Color(0xFFF2EFE3),
          },
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(
          switch (result) {
            ProfileGameOutcome.win => 'W',
            ProfileGameOutcome.loss => 'L',
            ProfileGameOutcome.draw => 'D',
            null => '—',
          },
          style: _outfit(
            13,
            color: switch (result) {
              ProfileGameOutcome.win => Colors.white,
              ProfileGameOutcome.loss => _danger,
              _ => _muted,
            },
          ),
        ),
      ),
    ),
  );
}

class _PlayerClan extends StatelessWidget {
  const _PlayerClan({required this.clan, required this.onTap});
  final ProfileClan? clan;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final current = clan;
    if (current == null) {
      return _WhiteCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Row(
            key: const ValueKey('player-no-clan'),
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFF2EFE3),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.shield_outlined,
                  color: _muted,
                  size: 23,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CLAN',
                      style: _jakarta(9.5, color: _muted, tracking: 1.14),
                    ),
                    const SizedBox(height: 7),
                    Text('Not in a clan', style: _outfit(14, color: _muted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    final initials = current.name
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .take(2)
        .map((word) => word.substring(0, 1))
        .join()
        .toUpperCase();
    return _WhiteCard(
      child: InkWell(
        key: const ValueKey('player-clan'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _green,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  initials.isEmpty ? '?' : initials,
                  style: _outfit(14, color: Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CLAN',
                      style: _jakarta(9.5, color: _muted, tracking: 1.14),
                    ),
                    const SizedBox(height: 7),
                    Text(current.name, style: _outfit(14)),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 12),
                Text('›', style: _jakarta(13, color: _muted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WhiteCard extends StatelessWidget {
  const _WhiteCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: _border),
    ),
    child: child,
  );
}

/// Static, reduced-motion-safe initial state. Back navigation stays available.
class FieldrushPlayerProfileLoadingContent extends StatelessWidget {
  const FieldrushPlayerProfileLoadingContent({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _PlayerHeader(name: 'Player', onBack: onBack),
      Semantics(
        key: const ValueKey('player-profile-loading'),
        container: true,
        liveRegion: true,
        label: 'Loading player profile',
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              children: [
                const _Skeleton(height: 193, radius: 24),
                const SizedBox(height: 12),
                const _Skeleton(
                  key: ValueKey('player-record-loading'),
                  height: 142,
                  radius: 20,
                ),
                const SizedBox(height: 12),
                const _Skeleton(height: 93, radius: 20),
                const SizedBox(height: 12),
                const _Skeleton(height: 72, radius: 20),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({super.key, required this.height, required this.radius});
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => FieldSkeleton(
    height: height,
    radius: radius,
    color: const Color(0x1A24472C),
  );
}

class _PlayerPalette {
  const _PlayerPalette(
    this.background,
    this.ink,
    this.accent,
    this.followInk,
    this.lines,
    this.circle,
    this.rim,
    this.shadow,
  );
  final List<Color> background;
  final Color ink, accent, followInk, lines, circle, rim, shadow;
}

const _placementPalette = _PlayerPalette(
  [Color(0xFF1E2A23), Color(0xFF0B110D)],
  Color(0xFFF3EBD6),
  Color(0xFFC9C2AE),
  Color(0xFF1E2A23),
  Color(0x0DFFFFFF),
  Color(0x17FFFFFF),
  Color(0x1FF3EBD6),
  Color(0xB3000000),
);
const _palettes = {
  1: _PlayerPalette(
    [Color(0xFF26251F), Color(0xFF0E0E0C)],
    Color(0xFFF6E7C1),
    Color(0xFFD9B25C),
    Color(0xFF2B281F),
    Color(0x12FFFFFF),
    Color(0x47D9B25C),
    Color(0x99D9B25C),
    Color(0xCC000000),
  ),
  2: _PlayerPalette(
    [Color(0xFF22406F), Color(0xFF101F40)],
    Colors.white,
    Color(0xFFE9CB7E),
    Color(0xFF0C1833),
    Color(0x1AFFFFFF),
    Color(0x3DE9CB7E),
    Color(0x59D9B25C),
    Color(0xD9081028),
  ),
  3: _PlayerPalette(
    [Color(0xFFEBC86C), Color(0xFFAB7C28)],
    Color(0xFF2B1E06),
    Color(0xFF4A360B),
    Colors.white,
    Color(0x143C2805),
    Color(0x263C2805),
    Color(0x1F50370A),
    Color(0x995A3C0A),
  ),
  4: _PlayerPalette(
    [Color(0xFFE8ECEF), Color(0xFFA6AFB7)],
    Color(0xFF1E252B),
    Color(0xFF3A4550),
    Colors.white,
    Color(0x121E252B),
    Color(0x211E252B),
    Color(0x12000000),
    Color(0x8C28323C),
  ),
  5: _PlayerPalette(
    [Color(0xFF9A6236), Color(0xFF5A3519)],
    Color(0xFFFFF4E8),
    Color(0xFFF6D2AE),
    Color(0xFF4A2C15),
    Color(0x1FFFFFFF),
    Color(0x26FFFFFF),
    Color(0x0FFFFFFF),
    Color(0xB3000000),
  ),
};

class _PlayerCardPainter extends CustomPainter {
  const _PlayerCardPainter({required this.palette});
  final _PlayerPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final stripe = Paint()
      ..color = palette.lines
      ..strokeWidth = 1;
    for (double x = 0; x < size.width + size.height; x += 26) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x - size.height * .249, size.height),
        stripe,
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
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(.75),
        const Radius.circular(24),
      ),
      Paint()
        ..color = palette.rim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _PlayerCardPainter oldDelegate) =>
      oldDelegate.palette != palette;
}
