import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../home/fieldrush_home_widgets.dart';
import '../leaderboard/leaderboard.dart';
import '../leaderboard/fieldrush_rating_tracks.dart';
import '../leaderboard/fieldrush_rating_role_tabs.dart';
import '../ranking/rating_division.dart';
import '../reliability/reliability.dart';
import 'profile.dart';

const _ink = FieldrushAuthTheme.ink;
const _green = FieldrushAuthTheme.forest;
const _muted = FieldrushAuthTheme.muted;
const _border = FieldrushAuthTheme.border;
const _danger = FieldrushAuthTheme.danger;
const _wash = Color(0xFFF2EFE3);

TextStyle _jakarta(double size, {Color color = _ink, double tracking = 0}) =>
    TextStyle(
      fontFamily: 'PlusJakartaSans',
      fontSize: size,
      fontWeight: FontWeight.w700,
      height: 1.3,
      color: color,
      letterSpacing: tracking,
    );

TextStyle _outfit(double size, {Color color = _ink}) => TextStyle(
  fontFamily: 'Outfit',
  fontSize: size,
  fontWeight: FontWeight.w800,
  height: 1.05,
  color: color,
  letterSpacing: -size * .02,
);

/// Keeps the You layout recognizable while the first profile request is pending.
/// Static placeholders deliberately avoid shimmer, including in reduced motion.
class FieldrushYouLoadingContent extends StatelessWidget {
  const FieldrushYouLoadingContent({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: 'Loading your profile and rating',
    child: ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('You', style: _outfit(25)),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                _SkeletonBlock(width: 66, height: 66, radius: 21),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SkeletonBlock(width: 132, height: 20),
                      SizedBox(height: 8),
                      _SkeletonBlock(width: 178, height: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Row(
              children: [
                for (var i = 0; i < 2; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: _WhiteCard(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _SkeletonBlock(
                              width: 40,
                              height: MediaQuery.textScalerOf(
                                context,
                              ).scale(31.5),
                            ),
                            const SizedBox(height: 5),
                            _SkeletonBlock(
                              width: 88,
                              height: MediaQuery.textScalerOf(
                                context,
                              ).scale(13.65),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: _RatingCardSkeleton(),
          ),
        ],
      ),
    ),
  );
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({this.width, required this.height, this.radius = 5});
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: const Color(0x1A24472C),
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

/// The native You surface. Data and navigation stay with the owning screen.
/// [rating] and [recentResults] must describe the same current season.
class FieldrushYouContent extends StatefulWidget {
  const FieldrushYouContent({
    super.key,
    required this.profile,
    this.rating,
    this.ratings,
    this.track = RatingTrack.outfield,
    this.onTrack,
    this.ratingLoading = false,
    this.ratingUnavailable = false,
    this.recentResults = const [],
    this.accountDisplayName,
    this.cityLabel = 'Phoenix, AZ',
    this.emailUnverified = false,
    this.reliability,
    this.reliabilityLoading = false,
    this.reliabilityUnavailable = false,
    this.walletLabel,
    this.notificationLabel,
    this.paymentMethodsLabel,
    required this.onEdit,
    required this.onFollowing,
    required this.onFans,
    required this.onRanks,
    required this.onMatchHistory,
    required this.onClip,
    required this.onReliability,
    required this.onNotifications,
    required this.onWallet,
    required this.onPaymentMethods,
    required this.onSignOut,
    this.isSigningOut = false,
    this.onSupport,
    this.onSwitchUser,
  });

  final PlayerProfile profile;
  final PlayerRatingLeaderboardEntry? rating;
  final FieldrushPlayerRatings? ratings;
  final RatingTrack track;
  final ValueChanged<RatingTrack>? onTrack;
  final bool ratingLoading;
  final bool ratingUnavailable;
  final List<ProfileRatingEvent> recentResults;
  final String? accountDisplayName;
  final String cityLabel;
  final bool emailUnverified;
  final ReliabilityStatus? reliability;
  final bool reliabilityLoading;
  final bool reliabilityUnavailable;
  final String? walletLabel;
  final String? notificationLabel;
  final String? paymentMethodsLabel;
  final VoidCallback onEdit;
  final VoidCallback onFollowing;
  final VoidCallback onFans;
  final VoidCallback onRanks;
  final VoidCallback onMatchHistory;
  final ValueChanged<ProfileHighlight> onClip;
  final VoidCallback onReliability;
  final VoidCallback onNotifications;
  final VoidCallback onWallet;
  final VoidCallback onPaymentMethods;
  final VoidCallback onSignOut;
  final bool isSigningOut;
  final VoidCallback? onSupport;
  final VoidCallback? onSwitchUser;

  @override
  State<FieldrushYouContent> createState() => _FieldrushYouContentState();
}

class _FieldrushYouContentState extends State<FieldrushYouContent> {
  bool _reliabilityOpen = false;

  @override
  Widget build(BuildContext context) {
    final rating = widget.rating;
    final recordAvailable =
        !widget.ratingLoading && !widget.ratingUnavailable && rating != null;
    final ranked =
        recordAvailable &&
        rating.matchesPlayed >= minimumPlayerLeaderboardMatches;
    final recent = [...widget.recentResults]
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    final lastFive = recent.take(5).toList().reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Row(
            children: [
              Expanded(child: Text('You', style: _outfit(25))),
              SizedBox(
                height: 44,
                child: Center(
                  child: OutlinedButton(
                    key: const ValueKey('you-edit'),
                    onPressed: widget.onEdit,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(58, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 15),
                      side: const BorderSide(color: _border),
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF3C4A38),
                      shape: const StadiumBorder(),
                      textStyle: _jakarta(
                        11,
                      ).copyWith(fontWeight: FontWeight.w800),
                    ),
                    child: const Text('Edit'),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              _Avatar(profile: widget.profile),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.accountDisplayName?.trim().isNotEmpty == true
                          ? widget.accountDisplayName!.trim()
                          : widget.profile.displayName,
                      style: _outfit(19),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '@${widget.profile.username} · ${widget.cityLabel}',
                      style: _jakarta(
                        12,
                        color: _muted,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _PeopleCard(
                  key: const ValueKey('you-following'),
                  count: widget.profile.followingCount,
                  label: 'FOLLOWING',
                  onTap: widget.onFollowing,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PeopleCard(
                  key: const ValueKey('you-fans'),
                  count: widget.profile.fansCount,
                  label: 'FANS',
                  onTap: widget.onFans,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: _RatingCard(
            rating: rating,
            ratings: widget.ratings,
            track: widget.track,
            onTrack: widget.onTrack,
            loading: widget.ratingLoading,
            unavailable: widget.ratingUnavailable || rating == null,
            cityLabel: widget.cityLabel,
            onTap: widget.onRanks,
          ),
        ),
        if (recordAvailable)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FieldrushMatchRecordCard(
              wins: rating.wins,
              draws: rating.draws,
              losses: rating.losses,
              played: rating.matchesPlayed,
              actionKey: const ValueKey('you-match-history'),
              onTap: widget.onMatchHistory,
            ),
          ),
        if (ranked) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LAST FIVE', style: _sectionStyle),
                const SizedBox(height: 12),
                if (lastFive.isEmpty)
                  Text(
                    'No recent results available.',
                    style: _jakarta(11.5, color: _muted),
                  )
                else
                  Row(
                    children: [
                      for (var i = 0; i < lastFive.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(child: _ResultPip(event: lastFive[i])),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ],
        FieldrushProfileClips(
          highlights: widget.profile.highlights,
          onClip: widget.onClip,
          emptyMessage: 'Open the replay of a finished match and tap Clip.',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
          child: _WhiteCard(
            radius: 20,
            child: Column(
              children: [
                _reliabilityRow(),
                if (_reliabilityOpen) _reliabilityDetail(),
                if (!ranked && widget.profile.previousGames.isNotEmpty)
                  _SettingRow(
                    key: const ValueKey('you-match-history'),
                    label: 'Match history',
                    onTap: widget.onMatchHistory,
                  ),
                _SettingRow(
                  key: const ValueKey('you-account-details'),
                  label: 'Account details',
                  onTap: widget.onEdit,
                  badge: widget.emailUnverified ? 'VERIFY EMAIL' : null,
                ),
                _SettingRow(
                  key: const ValueKey('you-notifications'),
                  label: 'Notifications',
                  value: widget.notificationLabel,
                  onTap: widget.onNotifications,
                ),
                _SettingRow(
                  key: const ValueKey('you-wallet'),
                  label: 'Wallet',
                  value: widget.walletLabel,
                  onTap: widget.onWallet,
                ),
                _SettingRow(
                  key: const ValueKey('you-payment-methods'),
                  label: 'Payment methods',
                  value: widget.paymentMethodsLabel,
                  onTap: widget.onPaymentMethods,
                ),
                if (widget.onSupport case final onSupport?)
                  _SettingRow(label: 'Help & support', onTap: onSupport),
                if (widget.onSwitchUser case final onSwitchUser?)
                  _SettingRow(
                    key: const ValueKey('you-switch-user'),
                    label: 'Switch profile',
                    onTap: onSwitchUser,
                  ),
                _SettingRow(
                  key: const ValueKey('you-sign-out'),
                  label: widget.isSigningOut ? 'Signing out…' : 'Sign out',
                  onTap: widget.isSigningOut ? null : widget.onSignOut,
                  color: _danger,
                  chevron: false,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _reliabilityRow() {
    final status = widget.reliability;
    final unavailable = widget.reliabilityUnavailable || status == null;
    final headline = widget.reliabilityLoading
        ? 'Loading…'
        : unavailable
        ? 'Unavailable'
        : status.headline;
    final color = !unavailable && !status.isGoodStanding ? _danger : _muted;
    return Semantics(
      expanded: _reliabilityOpen,
      child: InkWell(
        key: const ValueKey('you-reliability'),
        onTap: () => setState(() => _reliabilityOpen = !_reliabilityOpen),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('Reliability', style: _jakarta(13.5)),
                      if (!unavailable &&
                          !widget.reliabilityLoading &&
                          status.activeStrikes > 0)
                        ExcludeSemantics(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (
                                var i = 0;
                                i < math.min(status.activeStrikes, 5);
                                i++
                              )
                                Container(
                                  margin: const EdgeInsets.only(right: 4),
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: _danger,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    headline,
                    style: _jakarta(11.5, color: color),
                    textAlign: TextAlign.end,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _reliabilityOpen
                      ? Icons.keyboard_arrow_down
                      : Icons.chevron_right,
                  size: 18,
                  color: _muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _reliabilityDetail() {
    final status = widget.reliability;
    return Container(
      key: const ValueKey('you-reliability-expanded'),
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFFFBFAF4),
        border: Border(top: BorderSide(color: Color(0xFFF0ECE0))),
      ),
      padding: const EdgeInsets.fromLTRB(18, 13, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.reliabilityLoading
                ? 'Loading your attendance record…'
                : widget.reliabilityUnavailable || status == null
                ? 'Your reliability record could not be loaded. Try opening the full record again.'
                : status.supportingText,
            style: _jakarta(12).copyWith(height: 1.45),
          ),
          TextButton(
            key: const ValueKey('you-reliability-details'),
            onPressed: widget.onReliability,
            style: TextButton.styleFrom(
              foregroundColor: _green,
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 44),
              alignment: Alignment.centerLeft,
            ),
            child: Text(
              'View attendance & appeals',
              style: _jakarta(11.5, color: _green),
            ),
          ),
        ],
      ),
    );
  }
}

TextStyle get _sectionStyle => _jakarta(
  11,
  color: _muted,
  tracking: 1.54,
).copyWith(fontWeight: FontWeight.w800);

class _Avatar extends StatelessWidget {
  const _Avatar({required this.profile});
  final PlayerProfile profile;

  @override
  Widget build(BuildContext context) {
    final url = profile.avatarUrl?.trim();
    final placeholder = Center(
      child: Text(profile.initials, style: _outfit(23, color: _green)),
    );
    return Semantics(
      image: true,
      label: '${profile.displayName} profile photo',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(21),
        child: ColoredBox(
          color: _wash,
          child: SizedBox(
            width: 66,
            height: 66,
            child: url == null || url.isEmpty
                ? placeholder
                : Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => placeholder,
                  ),
          ),
        ),
      ),
    );
  }
}

class _WhiteCard extends StatelessWidget {
  const _WhiteCard({required this.child, this.radius = 17});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: const BorderSide(color: _border),
    ),
    child: child,
  );
}

class _PeopleCard extends StatelessWidget {
  const _PeopleCard({
    super.key,
    required this.count,
    required this.label,
    required this.onTap,
  });
  final int count;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _WhiteCard(
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$count', style: _outfit(30, color: const Color(0xFF24472C))),
            const SizedBox(height: 5),
            Text(
              '$label ›',
              style: _jakarta(
                10.5,
                color: _muted,
                tracking: 1.05,
              ).copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RatingCard extends StatelessWidget {
  const _RatingCard({
    required this.rating,
    required this.loading,
    required this.unavailable,
    required this.cityLabel,
    required this.onTap,
    this.ratings,
    this.track = RatingTrack.outfield,
    this.onTrack,
  });
  final PlayerRatingLeaderboardEntry? rating;
  final FieldrushPlayerRatings? ratings;
  final RatingTrack track;
  final ValueChanged<RatingTrack>? onTrack;
  final bool loading;
  final bool unavailable;
  final String cityLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return _RatingCardSkeleton(
        placement:
            rating != null &&
            rating!.matchesPlayed < minimumPlayerLeaderboardMatches,
      );
    }
    if (unavailable) {
      return _WhiteCard(
        radius: 24,
        child: InkWell(
          key: const ValueKey('you-rating-unavailable'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                const Icon(Icons.shield_outlined, color: _muted, size: 30),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Rating unavailable', style: _outfit(19)),
                      const SizedBox(height: 6),
                      Text(
                        'Open ranks to try again.',
                        style: _jakarta(11.5, color: _muted),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: _muted),
              ],
            ),
          ),
        ),
      );
    }
    final current = rating!;
    final placement = current.matchesPlayed < minimumPlayerLeaderboardMatches;
    if (placement) {
      return FieldrushPlacementRatingCard(
        matchesPlayed: current.matchesPlayed,
        cityLabel:
            ratings?.primaryCityName ??
            (current.region.trim().isNotEmpty ? current.region : ''),
        onTap: onTap,
        actionKey: const ValueKey('you-rating-placement'),
        keeper: track == RatingTrack.goalkeeper,
        roleTabs: onTrack == null
            ? null
            : FieldrushRatingRoleTabs(
                selected: track,
                ratings: ratings,
                onChanged: onTrack!,
                dark: true,
              ),
      );
    }
    final division = divisionFromRating(current.skillRating);
    final palette = _palettes[division.number]!;
    const count = 10;
    final filled = (division.progressFor(current.skillRating) * 10).round();
    final next = division.nextDivisionRating;
    final words = {1: 'ONE', 2: 'TWO', 3: 'THREE', 4: 'FOUR', 5: 'FIVE'};
    final city =
        ratings?.primaryCityName?.toUpperCase() ??
        (current.region.trim().isNotEmpty
            ? current.region.toUpperCase()
            : cityLabel.split(',').first.toUpperCase());
    final rank = current.rank > 0 ? '#${current.rank}' : '—';
    return DecoratedBox(
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
              colors: palette.background,
            ),
          ),
          child: CustomPaint(
            painter: _RatingBackgroundPainter(palette: palette),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('you-rating-ranked'),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (onTrack != null) ...[
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FieldrushRatingRoleTabs(
                              selected: track,
                              ratings: ratings,
                              onChanged: onTrack!,
                              dark:
                                  division.number != 3 && division.number != 4,
                            ),
                            Text(
                              '$rank IN $city',
                              style: _jakarta(
                                9,
                                color: palette.chipInk,
                                tracking: .6,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FieldrushDivisionShield(
                            division: division.number,
                            size: 62,
                          ),
                          const SizedBox(width: 15),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _Spread(
                                  leading: Text(
                                    'DIVISION ${words[division.number]}',
                                    style: _jakarta(
                                      9.5,
                                      color: palette.accent,
                                      tracking: 1.71,
                                    ).copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  trailing: onTrack != null
                                      ? const SizedBox.shrink()
                                      : Container(
                                          decoration: BoxDecoration(
                                            color: palette.chip,
                                            borderRadius: BorderRadius.circular(
                                              99,
                                            ),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          child: Text(
                                            '$rank IN $city',
                                            style:
                                                _jakarta(
                                                  9,
                                                  color: palette.chipInk,
                                                  tracking: .6,
                                                ).copyWith(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                          ),
                                        ),
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 7,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.end,
                                  children: [
                                    Text(
                                      '${current.skillRating}',
                                      style: _outfit(40, color: palette.ink)
                                          .copyWith(
                                            letterSpacing: -1.6,
                                            height: .9,
                                          ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 3),
                                      child: Text(
                                        'SKILL RATING',
                                        style: _jakarta(
                                          10,
                                          color: palette.accent,
                                          tracking: 1.2,
                                        ).copyWith(fontWeight: FontWeight.w800),
                                      ),
                                    ),
                                  ],
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
                                  color: i < filled
                                      ? palette.segmentOn
                                      : palette.segmentOff,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),
                      _Spread(
                        leading: Text(
                          next == null
                              ? 'Top division'
                              : '${next - current.skillRating} SR to Division ${division.number - 1}',
                          style: _jakarta(11.5, color: palette.ink),
                        ),
                        trailing: Text(
                          next == null
                              ? '1650+'
                              : '$next · D${division.number - 1} ›',
                          style: _jakarta(
                            10,
                            color: palette.accent,
                            tracking: .8,
                          ).copyWith(fontWeight: FontWeight.w800),
                        ),
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

class _RatingCardSkeleton extends StatelessWidget {
  const _RatingCardSkeleton({this.placement = false});
  final bool placement;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale;
    return Semantics(
      key: const ValueKey('you-rating-loading'),
      container: true,
      liveRegion: true,
      label: 'Loading your rating',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0x1824472C)),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFEDF0E7), Color(0xFFDCE3D5)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.shield_rounded,
                      size: 62,
                      color: Color(0x1A24472C),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Spread(
                            leading: _SkeletonBlock(
                              width: 92,
                              height: scale(12.35),
                            ),
                            trailing: _SkeletonBlock(
                              width: 104,
                              height: scale(11.7) + 12,
                              radius: 99,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 7,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.end,
                            children: [
                              _SkeletonBlock(width: 92, height: scale(36)),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: _SkeletonBlock(
                                  width: 94,
                                  height: scale(13),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (placement) ...[
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      for (var i = 0; i < 5; i++)
                        const Expanded(
                          child: Center(
                            child: _SkeletonBlock(
                              width: 24,
                              height: 24,
                              radius: 8,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    for (var i = 0; i < (placement ? 2 : 10); i++) ...[
                      if (i > 0) const SizedBox(width: 3),
                      const Expanded(
                        child: _SkeletonBlock(height: 6, radius: 2),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                _Spread(
                  leading: _SkeletonBlock(width: 142, height: scale(14.95)),
                  trailing: _SkeletonBlock(width: 72, height: scale(13)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Spread extends StatelessWidget {
  const _Spread({required this.leading, required this.trailing});
  final Widget leading;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        constraints.maxWidth < 230 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.2
        ? Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [leading, trailing],
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: leading),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .58,
                ),
                child: trailing,
              ),
            ],
          ),
  );
}

/// Shared match-history entry for You and public player profiles.
class FieldrushMatchRecordCard extends StatelessWidget {
  const FieldrushMatchRecordCard({
    super.key,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.played,
    required this.onTap,
    this.resultsKnown = true,
    this.actionKey,
  });
  final int wins;
  final int draws;
  final int losses;
  final int played;
  final bool resultsKnown;
  final Key? actionKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final percent = played == 0 ? 0 : (wins / played * 100).round();
    return _WhiteCard(
      radius: 20,
      child: InkWell(
        key: actionKey,
        onTap: onTap,
        child: Column(
          children: [
            IntrinsicHeight(
              child: Row(
                children: [
                  for (final (index, count, label, color) in [
                    (0, wins, 'WON', _green),
                    (1, draws, 'DRAWN', const Color(0xFF8E897A)),
                    (2, losses, 'LOST', _danger),
                  ])
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: index == 0
                              ? null
                              : const Border(
                                  left: BorderSide(color: Color(0xFFF0ECE0)),
                                ),
                        ),
                        padding: const EdgeInsets.fromLTRB(4, 19, 4, 16),
                        child: Column(
                          children: [
                            Text('$count', style: _outfit(40, color: color)),
                            const SizedBox(height: 8),
                            Text(
                              label,
                              style: _jakarta(
                                9.5,
                                color: _muted,
                                tracking: 1.52,
                              ).copyWith(fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFFF0ECE0))),
              ),
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 13),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      resultsKnown
                          ? '$played played · $percent% won'
                          : '$played played · Results incomplete',
                      style: _jakarta(11.5, color: _muted),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18, color: _muted),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The same clip strip, empty state and native viewer entry on every profile.
class FieldrushProfileClips extends StatelessWidget {
  const FieldrushProfileClips({
    super.key,
    required this.highlights,
    required this.onClip,
    this.emptyMessage = 'No clips yet.',
    this.clipKeyPrefix = 'you',
  });
  final List<ProfileHighlight> highlights;
  final ValueChanged<ProfileHighlight> onClip;
  final String emptyMessage;
  final String clipKeyPrefix;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
        child: Row(
          children: [
            Expanded(child: Text('CLIPS', style: _sectionStyle)),
            Text('${highlights.length}', style: _jakarta(11, color: _muted)),
          ],
        ),
      ),
      const SizedBox(height: 11),
      if (highlights.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: CustomPaint(
            painter: const _DashedBorderPainter(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
              child: Text(
                emptyMessage,
                style: _jakarta(
                  11.5,
                  color: _muted,
                ).copyWith(fontWeight: FontWeight.w600, height: 1.5),
              ),
            ),
          ),
        )
      else
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < highlights.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                _ClipTile(
                  highlight: highlights[i],
                  actionKey: ValueKey(
                    '$clipKeyPrefix-clip-${highlights[i].id}',
                  ),
                  onTap: () => onClip(highlights[i]),
                ),
              ],
            ],
          ),
        ),
    ],
  );
}

class _ResultPip extends StatelessWidget {
  const _ResultPip({required this.event});
  final ProfileRatingEvent event;

  @override
  Widget build(BuildContext context) {
    final result = switch (event.result.toUpperCase()) {
      'W' || 'WIN' => 'W',
      'L' || 'LOSS' => 'L',
      'D' || 'DRAW' => 'D',
      _ => '–',
    };
    final text = switch (result) {
      'W' => 'Win',
      'L' => 'Loss',
      'D' => 'Draw',
      _ => 'Result unavailable',
    };
    return Semantics(
      label: '$text against ${event.opponentLabel}',
      child: Container(
        key: ValueKey('you-result-${event.id}'),
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: result == 'W'
              ? _green
              : result == 'L'
              ? const Color(0xFFF7E3E3)
              : const Color(0xFFEAE5D5),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Text(
          result,
          style: _outfit(
            17,
            color: result == 'W'
                ? Colors.white
                : result == 'L'
                ? _danger
                : _muted,
          ),
        ),
      ),
    );
  }
}

class _ClipTile extends StatelessWidget {
  const _ClipTile({
    required this.highlight,
    required this.onTap,
    required this.actionKey,
  });
  final ProfileHighlight highlight;
  final VoidCallback onTap;
  final Key actionKey;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 150,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        key: actionKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Color(0xFF1D2A1B)),
                    if (highlight.thumbnailUrl.trim().isNotEmpty)
                      Image.network(
                        highlight.thumbnailUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    Center(
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: .16),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .5),
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          highlight.isProcessing
                              ? Icons.hourglass_top_rounded
                              : highlight.isReady
                              ? Icons.play_arrow_rounded
                              : Icons.error_outline,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                    if (highlight.isReady)
                      Positioned(
                        right: 7,
                        bottom: 7,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .5),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            highlight.duration,
                            style: _jakarta(
                              9.5,
                              color: Colors.white,
                            ).copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              highlight.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _jakarta(12),
            ),
            const SizedBox(height: 4),
            Text(
              highlight.isProcessing
                  ? 'Processing'
                  : !highlight.isReady
                  ? 'Could not process clip'
                  : highlight.createdAt != null
                  ? _clipDate(highlight.createdAt!)
                  : '${highlight.views} ${highlight.views == 1 ? 'view' : 'views'}',
              style: _jakarta(
                10.5,
                color: _muted,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
  );
}

String _clipDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final date = value.toUtc().subtract(const Duration(hours: 7));
  return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}';
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    super.key,
    required this.label,
    required this.onTap,
    this.value,
    this.badge,
    this.color = _ink,
    this.chevron = true,
  });
  final String label;
  final VoidCallback? onTap;
  final String? value;
  final String? badge;
  final Color color;
  final bool chevron;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF0ECE0))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: _jakarta(13.5, color: color)),
          ),
          if (badge != null) ...[
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7EED6),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  badge!,
                  textAlign: TextAlign.center,
                  style: _jakarta(
                    9,
                    color: const Color(0xFF8A6516),
                    tracking: .9,
                  ).copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
          if (value != null) ...[
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(
                value!,
                textAlign: TextAlign.end,
                style: _jakarta(
                  11.5,
                  color: _muted,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
          if (chevron) ...[
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 18, color: _muted),
          ],
        ],
      ),
    ),
  );
}

class _RatingPalette {
  const _RatingPalette(
    this.background,
    this.ink,
    this.accent,
    this.chip,
    this.chipInk,
    this.segmentOn,
    this.segmentOff,
    this.lines,
    this.circle,
  );
  final List<Color> background;
  final Color ink, accent, chip, chipInk, segmentOn, segmentOff, lines, circle;
}

const _palettes = {
  1: _RatingPalette(
    [Color(0xFF26251F), Color(0xFF0E0E0C)],
    Color(0xFFF6E7C1),
    Color(0xFFD9B25C),
    Color(0xFF2B281F),
    Color(0xFFF2D99A),
    Color(0xFFE3C27A),
    Color(0x1FFFFFFF),
    Color(0x12FFFFFF),
    Color(0x47D9B25C),
  ),
  2: _RatingPalette(
    [Color(0xFF22406F), Color(0xFF101F40)],
    Colors.white,
    Color(0xFFE9CB7E),
    Color(0xFF0C1833),
    Color(0xFFF2D99A),
    Color(0xFFE9CB7E),
    Color(0x24FFFFFF),
    Color(0x1AFFFFFF),
    Color(0x3DE9CB7E),
  ),
  3: _RatingPalette(
    [Color(0xFFEBC86C), Color(0xFFAB7C28)],
    Color(0xFF2B1E06),
    Color(0xFF4A360B),
    Color(0xFFFBEBC0),
    Color(0xFF3A2A08),
    Color(0xFF3A2A08),
    Color(0x292B1E06),
    Color(0x143C2805),
    Color(0x263C2805),
  ),
  4: _RatingPalette(
    [Color(0xFFE8ECEF), Color(0xFFA6AFB7)],
    Color(0xFF1E252B),
    Color(0xFF3A4550),
    Color(0xFFF7F9FA),
    Color(0xFF2A333A),
    Color(0xFF2F3940),
    Color(0x261E252B),
    Color(0x121E252B),
    Color(0x211E252B),
  ),
  5: _RatingPalette(
    [Color(0xFF9A6236), Color(0xFF5A3519)],
    Color(0xFFFFF4E8),
    Color(0xFFF6D2AE),
    Color(0xFF4A2C15),
    Color(0xFFFFE6CC),
    Color(0xFFF7D5AE),
    Color(0x42000000),
    Color(0x1FFFFFFF),
    Color(0x26FFFFFF),
  ),
};

class _RatingBackgroundPainter extends CustomPainter {
  const _RatingBackgroundPainter({required this.palette});
  final _RatingPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = palette.lines
      ..strokeWidth = 1;
    for (double x = 0; x < size.width + size.height; x += 26) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x - size.height * .249, size.height),
        paint,
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
        (Offset.zero & size).deflate(.5),
        const Radius.circular(24),
      ),
      Paint()
        ..color = palette.ink.withValues(alpha: .12)
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _RatingBackgroundPainter oldDelegate) =>
      oldDelegate.palette != palette;
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.75),
          const Radius.circular(16),
        ),
      );
    final paint = Paint()
      ..color = const Color(0xFFDED8C6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (double distance = 0; distance < metric.length; distance += 8) {
        canvas.drawPath(
          metric.extractPath(distance, math.min(distance + 4, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) => false;
}
