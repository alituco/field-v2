import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../clans/clan.dart';
import '../clans/clan_detail_screen.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_detail_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../leaderboard/leaderboard.dart';
import '../moderation/moderation.dart';
import '../moderation/moderation_repository.dart';
import '../moderation/report_issue_sheet.dart';
import '../open_queue/open_queue.dart';
import '../open_queue/open_queue_repository.dart';
import 'dev_user_switcher_sheet.dart';
import 'edit_profile_screen.dart';
import 'profile.dart';
import 'profile_clip_screen.dart';
import 'profile_connections_screen.dart';
import 'profile_repository.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.profileRepository,
    this.clanRepository,
    this.fixtureRepository,
    this.openQueueRepository,
    this.moderationRepository,
    this.profileId,
    this.devModeEnabled = false,
    this.onSwitchUser,
    this.isSigningOut = false,
    this.onSignOut,
  });

  final ProfileRepository profileRepository;
  final ClanRepository? clanRepository;
  final FixtureRepository? fixtureRepository;
  final OpenQueueRepository? openQueueRepository;
  final ModerationRepository? moderationRepository;
  final String? profileId;
  final bool devModeEnabled;
  final Future<void> Function(String profileId)? onSwitchUser;
  final bool isSigningOut;
  final VoidCallback? onSignOut;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<PlayerProfile> _profileFuture;
  late final ClanRepository _clanRepository;
  late final FixtureRepository _fixtureRepository;
  late final OpenQueueRepository _openQueueRepository;
  late final ModerationRepository _moderationRepository;
  PlayerProfile? _latestProfile;
  String? _openingGameId;
  bool _isOpeningClan = false;

  bool get _isCurrentProfile => widget.profileId == null;
  bool get _canManageProfile =>
      _isCurrentProfile ||
      widget.profileId == widget.profileRepository.currentUserId;

  bool get _canReportProfile {
    final profileId = widget.profileId?.trim();
    final currentUserId = widget.profileRepository.currentUserId?.trim();
    return profileId != null &&
        profileId.isNotEmpty &&
        currentUserId != null &&
        currentUserId.isNotEmpty &&
        profileId != currentUserId;
  }

  @override
  void initState() {
    super.initState();
    _clanRepository = widget.clanRepository ?? SupabaseClanRepository();
    _fixtureRepository =
        widget.fixtureRepository ?? SupabaseFixtureRepository();
    _openQueueRepository =
        widget.openQueueRepository ?? SupabaseOpenQueueRepository();
    _moderationRepository =
        widget.moderationRepository ?? SupabaseModerationRepository();
    _profileFuture = _loadProfile();
  }

  Future<PlayerProfile> _loadProfile() async {
    final profile = _isCurrentProfile
        ? await widget.profileRepository.getCurrentProfile()
        : await widget.profileRepository.getProfile(widget.profileId!);
    _latestProfile = profile;
    return profile;
  }

  Future<void> _refresh() async {
    try {
      final profile = await _loadProfile();
      if (!mounted) return;
      setState(() {
        _profileFuture = Future.value(profile);
      });
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() {
        _profileFuture = Future.error(error, stackTrace);
      });
    }
  }

  Future<void> _copyProfileHandle() async {
    final profile = _latestProfile;
    if (profile == null) return;

    await Clipboard.setData(ClipboardData(text: '@${profile.username}'));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('@${profile.username} copied')));
  }

  Future<void> _openPreviousGame(ProfilePreviousGame game) {
    return _openRatedMatch(game);
  }

  Future<void> _openHighlight(ProfileHighlight highlight) async {
    await Navigator.of(context).push<ProfileHighlight>(
      MaterialPageRoute<ProfileHighlight>(
        builder: (_) => ProfileClipScreen(
          highlight: highlight,
          profileRepository: widget.profileRepository,
          canManage: _canManageProfile,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _openRatedMatch(ProfilePreviousGame game) async {
    final matchId = game.id;
    final isSolo = game.isSolo;
    if (_openingGameId != null) return;
    if (matchId.trim().isEmpty) return;
    setState(() => _openingGameId = matchId);
    try {
      if (isSolo) {
        final detail = await _openQueueRepository.getMatchDetail(matchId);
        final playerRatingUpdate = _playerRatingUpdateFor(game, detail);
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => FixtureDetailScreen(
              fixture: detail.toFixture(),
              fixtureRepository: _fixtureRepository,
              clanRepository: _clanRepository,
              myClanMembership: null,
              sourceLabel: 'SOLO',
              showTeamRatings: false,
              playerRatingUpdate: playerRatingUpdate,
              profileRepository: widget.profileRepository,
              refreshFixture: () async {
                final next = await _openQueueRepository.getMatchDetail(matchId);
                return next.toFixture();
              },
            ),
          ),
        );
      } else {
        final fixture = await _fixtureRepository.getFixture(matchId);
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => FixtureDetailScreen(
              fixture: fixture,
              fixtureRepository: _fixtureRepository,
              clanRepository: _clanRepository,
              myClanMembership: null,
              sourceLabel: 'CLAN',
              profileRepository: widget.profileRepository,
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not open this match. Try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingGameId = null);
    }
  }

  FixturePlayerRatingUpdate? _playerRatingUpdateFor(
    ProfilePreviousGame game,
    OpenQueueMatchDetail detail,
  ) {
    final ratingEvents = _latestProfile?.playerRating?.events ?? const [];
    for (final event in ratingEvents) {
      if (event.sourceId.trim() != game.id.trim() ||
          event.isSolo != game.isSolo) {
        continue;
      }
      return FixturePlayerRatingUpdate(
        ratingBefore: event.ratingBefore,
        ratingChange: event.ratingChange,
        ratingAfter: event.ratingAfter,
        result: event.result.isEmpty ? game.outcome?.label : event.result,
        scoreMargin: event.scoreMargin,
        marginMultiplier: event.marginMultiplier,
        baseRatingChange: event.baseRatingChange,
        marginBonusApplied: event.marginBonusApplied,
      );
    }

    final profileId = _latestProfile?.id;
    if (profileId == null || profileId.isEmpty) return null;
    for (final player in detail.players) {
      if (player.id != profileId) continue;
      final ratingBefore = player.displayedRating;
      final ratingChange = player.ratingChange;
      if (ratingBefore == null || ratingChange == null) return null;
      return FixturePlayerRatingUpdate(
        ratingBefore: ratingBefore,
        ratingChange: ratingChange,
        ratingAfter: ratingBefore + ratingChange,
        result: game.outcome?.label,
      );
    }
    return null;
  }

  Future<void> _openClan({
    required String clanId,
    required String clanName,
  }) async {
    if (_isOpeningClan || clanId.trim().isEmpty) return;
    setState(() => _isOpeningClan = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _ProfileClanRoute(
            clanId: clanId,
            clanName: clanName,
            clanRepository: _clanRepository,
            fixtureRepository: _fixtureRepository,
            moderationRepository: _moderationRepository,
          ),
        ),
      );
      if (mounted) await _refresh();
    } finally {
      if (mounted) setState(() => _isOpeningClan = false);
    }
  }

  Future<void> _openConnections(ProfileConnectionTab tab) async {
    final counts = await Navigator.of(context).push<ProfileConnectionCounts>(
      MaterialPageRoute<ProfileConnectionCounts>(
        builder: (_) => ProfileConnectionsScreen(
          profileRepository: widget.profileRepository,
          initialTab: tab,
        ),
      ),
    );
    if (!mounted) return;

    if (counts != null && _latestProfile != null) {
      final updatedProfile = _latestProfile!.copyWith(
        followingCount: counts.followingCount,
        fansCount: counts.fansCount,
      );
      _latestProfile = updatedProfile;
      setState(() {
        _profileFuture = Future.value(updatedProfile);
      });
      return;
    }

    final next = _loadProfile();
    setState(() {
      _profileFuture = next;
    });
  }

  Future<void> _openEditProfile() async {
    final profile = _latestProfile;
    if (profile == null) return;

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => EditProfileScreen(
          profile: profile,
          profileRepository: widget.profileRepository,
        ),
      ),
    );
    if (changed == true && mounted) {
      final next = _loadProfile();
      setState(() {
        _profileFuture = next;
      });
    }
  }

  Future<void> _openDevUserSwitcher() async {
    final profile = _latestProfile;
    final onSwitchUser = widget.onSwitchUser;
    if (profile == null || onSwitchUser == null) return;

    await showDevUserSwitcher(
      context: context,
      profileRepository: widget.profileRepository,
      currentUserId: profile.id,
      onSwitchUser: onSwitchUser,
    );
  }

  Future<void> _reportProfile() async {
    final profileId = widget.profileId?.trim();
    if (!_canReportProfile || profileId == null) return;

    final profileName = _latestProfile?.displayName.trim();
    final receipt = await showReportIssueSheet(
      context: context,
      repository: _moderationRepository,
      subjectType: ModerationSubjectType.player,
      subjectId: profileId,
      subjectName: profileName == null || profileName.isEmpty
          ? 'this player'
          : profileName,
    );
    if (!mounted || receipt == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Report sent privately · reference ${receipt.shortReference}',
        ),
      ),
    );
  }

  void _handleViewedProfileAction(_ViewedProfileAction action) {
    switch (action) {
      case _ViewedProfileAction.share:
        _copyProfileHandle();
      case _ViewedProfileAction.report:
        _reportProfile();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FieldHeaderOverlay(
      header: FieldPageHeader(
        title: 'Profile',
        showBack: !_isCurrentProfile,
        onBack: _isCurrentProfile ? null : () => Navigator.of(context).pop(),
        rightAction: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isCurrentProfile) ...[
              if (widget.devModeEnabled && widget.onSwitchUser != null) ...[
                _HeaderIconButton(
                  icon: Icons.switch_account_rounded,
                  tooltip: 'Switch dev user',
                  onPressed: _openDevUserSwitcher,
                ),
                const SizedBox(width: 8),
              ],
              _HeaderIconButton(
                icon: Icons.edit_rounded,
                tooltip: 'Edit profile',
                onPressed: _openEditProfile,
              ),
              if (widget.onSignOut != null) ...[
                const SizedBox(width: 8),
                _HeaderIconButton(
                  icon: Icons.logout_rounded,
                  tooltip: 'Sign out',
                  isLoading: widget.isSigningOut,
                  onPressed: widget.isSigningOut ? null : widget.onSignOut,
                ),
              ],
            ] else if (_canReportProfile)
              _ViewedProfileMenu(onSelected: _handleViewedProfileAction)
            else
              _HeaderIconButton(
                icon: Icons.ios_share_rounded,
                tooltip: 'Share profile',
                onPressed: _copyProfileHandle,
              ),
          ],
        ),
      ),
      child: FutureBuilder<PlayerProfile>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _ProfileLoadingView();
          }

          if (snapshot.hasError || !snapshot.hasData) {
            return _ProfileErrorView(
              message: userFacingError(
                snapshot.error,
                fallback: 'We could not load this profile. Try again.',
              ),
              onRetry: () {
                final next = _loadProfile();
                setState(() {
                  _profileFuture = next;
                });
              },
            );
          }

          final profile = snapshot.data!;
          return RefreshIndicator(
            color: fieldEmerald600,
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: fieldHeaderAwarePadding(
                context,
                top: 16,
                bottom: _isCurrentProfile ? 124 : 32,
              ),
              children: [
                _IdentityCard(
                  profile: profile,
                  onOpenClan: profile.clan == null
                      ? null
                      : () => _openClan(
                          clanId: profile.clan!.id,
                          clanName: profile.clan!.name,
                        ),
                  onOpenFollowing: _isCurrentProfile
                      ? () => _openConnections(ProfileConnectionTab.following)
                      : null,
                  onOpenFans: _isCurrentProfile
                      ? () => _openConnections(ProfileConnectionTab.fans)
                      : null,
                ),
                const SizedBox(height: 12),
                _StatsRow(profile: profile),
                if (profile.playerRating case final rating?) ...[
                  const SizedBox(height: 16),
                  _ProfilePlayerRatingCard(rating: rating),
                ],
                if (profile.career.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _CareerCard(
                    entries: profile.career,
                    onOpenClan: (entry) {
                      final clanId = entry.clanId;
                      if (clanId == null) return;
                      _openClan(clanId: clanId, clanName: entry.clanName);
                    },
                  ),
                ],
                if (_isCurrentProfile || profile.highlights.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _HighlightsCard(
                    highlights: profile.highlights,
                    showEmptyState: _isCurrentProfile,
                    onOpenHighlight: _openHighlight,
                  ),
                ],
                if (profile.previousGames.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _MatchHistoryCard(
                    games: profile.previousGames,
                    openingMatchId: _openingGameId,
                    onOpenGame: _openPreviousGame,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.profile,
    required this.onOpenClan,
    required this.onOpenFollowing,
    required this.onOpenFans,
  });

  final PlayerProfile profile;
  final VoidCallback? onOpenClan;
  final VoidCallback? onOpenFollowing;
  final VoidCallback? onOpenFans;

  @override
  Widget build(BuildContext context) {
    final clan = profile.clan;

    return _ProfileCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ProfileAvatar(profile: profile, size: 80),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      profile.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 20,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '@${profile.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray400,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 9),
                    if (clan == null)
                      const Text(
                        'No clan',
                        style: TextStyle(
                          color: fieldGray400,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    else
                      _ClanLine(clan: clan, onTap: onOpenClan),
                  ],
                ),
              ),
            ],
          ),
          if (profile.bio.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              profile.bio,
              style: const TextStyle(
                color: fieldGray600,
                fontSize: 14,
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 18),
          const Divider(height: 1, color: fieldGray100),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _SocialCount(
                  value: profile.followingCount,
                  label: 'Following',
                  onTap: onOpenFollowing,
                ),
              ),
              Container(width: 1, height: 32, color: fieldGray100),
              Expanded(
                child: _SocialCount(
                  value: profile.fansCount,
                  label: 'Fans',
                  onTap: onOpenFans,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ClanLine extends StatelessWidget {
  const _ClanLine({required this.clan, required this.onTap});

  final ProfileClan clan;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open ${clan.name} clan',
      child: Material(
        color: fieldEmerald50,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          key: ValueKey('profile-clan-${clan.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            child: Row(
              children: [
                Text(
                  clan.emblem,
                  style: const TextStyle(fontSize: 16, height: 1),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    clan.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: fieldGray700,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  clan.tag,
                  style: const TextStyle(
                    color: fieldEmerald700,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 3),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: fieldEmerald700,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SocialCount extends StatelessWidget {
  const _SocialCount({
    required this.value,
    required this.label,
    required this.onTap,
  });

  final int value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            Text(
              value.toString(),
              style: const TextStyle(
                color: fieldGray900,
                fontSize: 20,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: fieldGray400,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.profile});

  final PlayerProfile profile;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(value: profile.appearances, label: 'Apps'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(value: profile.goals, label: 'Goals'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(value: profile.assists, label: 'Assists'),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      borderRadius: 18,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Column(
        children: [
          Text(
            value.toString(),
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 24,
              height: 1,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: fieldGray400,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfilePlayerRatingCard extends StatelessWidget {
  const _ProfilePlayerRatingCard({required this.rating});

  final ProfilePlayerRating rating;

  @override
  Widget build(BuildContext context) {
    final change = rating.lastChange;
    final changeColor = change > 0
        ? fieldEmerald600
        : change < 0
        ? const Color(0xFFEF4444)
        : fieldGray400;
    return _ProfileCard(
      borderRadius: 22,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [fieldEmerald500, fieldBlue600],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.insights_rounded,
              color: Colors.white,
              size: 25,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PLAYER RATING',
                  style: TextStyle(
                    color: fieldEmerald600,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${rating.skillRating}',
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 28,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '${change > 0 ? '+' : ''}$change',
                        style: TextStyle(
                          color: changeColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${playerRatingTier(rating.skillRating)} · ${rating.recordLabel} · ${rating.matchesPlayed} rated games',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fieldGray500,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
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

class _MatchHistoryCard extends StatefulWidget {
  const _MatchHistoryCard({
    required this.games,
    required this.openingMatchId,
    required this.onOpenGame,
  });

  final List<ProfilePreviousGame> games;
  final String? openingMatchId;
  final ValueChanged<ProfilePreviousGame> onOpenGame;

  @override
  State<_MatchHistoryCard> createState() => _MatchHistoryCardState();
}

class _MatchHistoryCardState extends State<_MatchHistoryCard> {
  static const _previewCount = 3;
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hasMore = widget.games.length > _previewCount;
    final visibleGames = _expanded
        ? widget.games
        : widget.games.take(_previewCount).toList(growable: false);

    return _SectionCard(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                Icon(Icons.timeline_rounded, color: fieldGray400, size: 16),
                SizedBox(width: 8),
                Text(
                  'MATCH HISTORY',
                  style: TextStyle(
                    color: fieldGray700,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          for (var index = 0; index < visibleGames.length; index++) ...[
            if (index > 0)
              const Divider(height: 1, indent: 20, color: fieldGray100),
            _PreviousGameRow(
              game: visibleGames[index],
              isLoading: widget.openingMatchId == visibleGames[index].id,
              onTap: () => widget.onOpenGame(visibleGames[index]),
            ),
          ],
          if (hasMore) ...[
            const Divider(height: 1, color: fieldGray100),
            TextButton.icon(
              key: const ValueKey('profile-match-history-toggle'),
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(
                _expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 18,
              ),
              label: Text(_expanded ? 'SHOW LESS' : 'VIEW MORE'),
              style: TextButton.styleFrom(
                foregroundColor: fieldBlue600,
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.7,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HighlightsCard extends StatelessWidget {
  const _HighlightsCard({
    required this.highlights,
    required this.showEmptyState,
    required this.onOpenHighlight,
  });

  final List<ProfileHighlight> highlights;
  final bool showEmptyState;
  final ValueChanged<ProfileHighlight> onOpenHighlight;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                const Icon(
                  Icons.movie_creation_outlined,
                  color: fieldGray400,
                  size: 16,
                ),
                const SizedBox(width: 8),
                const Text(
                  'CLIPS',
                  style: TextStyle(
                    color: fieldGray700,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                Text(
                  '${highlights.length} clips',
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (highlights.isEmpty && showEmptyState)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 22),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    color: fieldEmerald600,
                    size: 20,
                  ),
                  SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      'Your goals will live here. Open a finished match, choose one of your goal chapters, and add it to your profile.',
                      style: TextStyle(
                        color: fieldGray500,
                        fontSize: 13,
                        height: 1.45,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          for (var index = 0; index < highlights.length; index++) ...[
            if (index > 0)
              const Divider(height: 1, indent: 20, color: fieldGray100),
            _HighlightRow(
              highlight: highlights[index],
              onTap: () => onOpenHighlight(highlights[index]),
            ),
          ],
        ],
      ),
    );
  }
}

class _HighlightRow extends StatelessWidget {
  const _HighlightRow({required this.highlight, required this.onTap});

  final ProfileHighlight highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 80,
                height: 56,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _NetworkImageFill(url: highlight.thumbnailUrl),
                    ColoredBox(color: Colors.black.withValues(alpha: 0.20)),
                    Center(
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.84),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          highlight.isProcessing
                              ? Icons.hourglass_top_rounded
                              : highlight.status ==
                                    ProfileHighlightStatus.failed
                              ? Icons.error_outline_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.black,
                          size: 20,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          highlight.duration,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    highlight.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 14,
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Icon(
                        highlight.isProcessing
                            ? Icons.auto_awesome_rounded
                            : highlight.status == ProfileHighlightStatus.failed
                            ? Icons.error_outline_rounded
                            : Icons.remove_red_eye_outlined,
                        color: fieldGray400,
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          highlight.isProcessing
                              ? 'Preparing clip...'
                              : highlight.status ==
                                    ProfileHighlightStatus.failed
                              ? 'Clip needs attention'
                              : _viewsLabel(highlight.views, highlight.clanTag),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: fieldGray400,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (!highlight.isPublic) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: fieldGray100,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.lock_rounded,
                                color: fieldGray600,
                                size: 11,
                              ),
                              SizedBox(width: 3),
                              Text(
                                'PRIVATE',
                                style: TextStyle(
                                  color: fieldGray600,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right_rounded,
              color: fieldGray300,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _CareerCard extends StatelessWidget {
  const _CareerCard({required this.entries, required this.onOpenClan});

  final List<ProfileCareerEntry> entries;
  final ValueChanged<ProfileCareerEntry> onOpenClan;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                Icon(Icons.history_rounded, color: fieldGray400, size: 16),
                SizedBox(width: 8),
                Text(
                  'CAREER',
                  style: TextStyle(
                    color: fieldGray700,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          const _CareerSubheading(label: 'CLAN HISTORY'),
          for (var index = 0; index < entries.length; index++) ...[
            if (index > 0)
              const Divider(height: 1, indent: 20, color: fieldGray100),
            _CareerRow(
              entry: entries[index],
              onTap: entries[index].clanId == null
                  ? null
                  : () => onOpenClan(entries[index]),
            ),
          ],
        ],
      ),
    );
  }
}

class _CareerSubheading extends StatelessWidget {
  const _CareerSubheading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 7, 20, 4),
        child: Text(
          label,
          style: const TextStyle(
            color: fieldGray400,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.1,
          ),
        ),
      ),
    );
  }
}

class _CareerRow extends StatelessWidget {
  const _CareerRow({required this.entry, required this.onTap});

  final ProfileCareerEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: fieldGray100,
              border: Border.all(color: fieldGray100),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(entry.emblem, style: const TextStyle(fontSize: 20)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.clanName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (entry.isCurrent) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD1FAE5),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'NOW',
                          style: TextStyle(
                            color: fieldEmerald600,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  entry.period,
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                  children: [
                    TextSpan(text: entry.goals.toString()),
                    const TextSpan(
                      text: ' G',
                      style: TextStyle(
                        color: fieldGray400,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${entry.apps} apps',
                style: const TextStyle(
                  color: fieldGray400,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (onTap != null) ...[
            const SizedBox(width: 5),
            const Icon(
              Icons.chevron_right_rounded,
              color: fieldGray300,
              size: 19,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: 'Open ${entry.clanName} clan',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('profile-career-clan-${entry.id}'),
          onTap: onTap,
          child: content,
        ),
      ),
    );
  }
}

class _PreviousGameRow extends StatelessWidget {
  const _PreviousGameRow({
    required this.game,
    required this.isLoading,
    required this.onTap,
  });

  final ProfilePreviousGame game;
  final bool isLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final date = game.playedAt;
    final role = game.playerRole?.toUpperCase();
    final side = game.playerSide.isEmpty ? null : game.playerSide;
    final outcome = game.outcome;
    final contextLabel = [
      _shortProfileGameDate(date),
      if (side != null) side,
      if (role != null) role,
    ].join(' · ');

    return InkWell(
      key: ValueKey('profile-previous-game-${game.id}'),
      onTap: isLoading ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: game.isSolo
                    ? const Color(0xFFEFF6FF)
                    : const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                game.isSolo ? Icons.person_rounded : Icons.shield_outlined,
                color: game.isSolo ? fieldBlue600 : fieldEmerald600,
                size: 21,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: game.isSolo
                              ? const Color(0xFFDBEAFE)
                              : const Color(0xFFD1FAE5),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          game.typeLabel,
                          style: TextStyle(
                            color: game.isSolo ? fieldBlue600 : fieldEmerald600,
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${game.homeTag} vs ${game.awayTag}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: fieldGray900,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    contextLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: fieldGray400,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (outcome != null) ...[
                  _ProfileGameOutcomeBadge(gameId: game.id, outcome: outcome),
                  const SizedBox(height: 4),
                ],
                if (isLoading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${game.homeScore} - ${game.awayScore}',
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: fieldGray300,
                        size: 20,
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileGameOutcomeBadge extends StatelessWidget {
  const _ProfileGameOutcomeBadge({required this.gameId, required this.outcome});

  final String gameId;
  final ProfileGameOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final (foreground, background, border) = switch (outcome) {
      ProfileGameOutcome.win => (
        fieldEmerald700,
        fieldEmerald50,
        fieldEmerald200,
      ),
      ProfileGameOutcome.loss => (
        const Color(0xFFDC2626),
        const Color(0xFFFEF2F2),
        const Color(0xFFFECACA),
      ),
      ProfileGameOutcome.draw => (fieldGray600, fieldGray100, fieldGray200),
    };

    return Semantics(
      label: 'Result: ${outcome.label.toLowerCase()}',
      child: ExcludeSemantics(
        child: Container(
          key: ValueKey('profile-game-result-$gameId'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: background,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            outcome.label,
            style: TextStyle(
              color: foreground,
              fontSize: 9,
              height: 1,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.7,
            ),
          ),
        ),
      ),
    );
  }
}

String _shortProfileGameDate(DateTime value) {
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
  return '${months[value.month - 1]} ${value.day}, ${value.year}';
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.profile, required this.size});

  final PlayerProfile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final avatarUrl = profile.avatarUrl;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [fieldEmerald500, fieldBlue600],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: avatarUrl == null || avatarUrl.isEmpty
            ? _AvatarInitials(profile: profile, size: size)
            : Image.network(
                avatarUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _AvatarInitials(profile: profile, size: size),
              ),
      ),
    );
  }
}

class _AvatarInitials extends StatelessWidget {
  const _AvatarInitials({required this.profile, required this.size});

  final PlayerProfile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        profile.initials,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.34,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _NetworkImageFill extends StatelessWidget {
  const _NetworkImageFill({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const _ImageFallback();
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const _ImageFallback(),
    );
  }
}

class _ImageFallback extends StatelessWidget {
  const _ImageFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [fieldEmerald500, fieldBlue600],
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = 24,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: fieldGray900.withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: _ProfileCard(child: child),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isLoading = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              border: Border.all(color: fieldGray200),
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: isLoading
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(icon, color: fieldGray600, size: 18),
          ),
        ),
      ),
    );
  }
}

enum _ViewedProfileAction { share, report }

class _ViewedProfileMenu extends StatelessWidget {
  const _ViewedProfileMenu({required this.onSelected});

  final ValueChanged<_ViewedProfileAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(999),
      child: PopupMenuButton<_ViewedProfileAction>(
        key: const ValueKey('profile-options-menu'),
        tooltip: 'Profile options',
        onSelected: onSelected,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            border: Border.all(color: fieldGray200),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: const Icon(
            Icons.more_horiz_rounded,
            color: fieldGray600,
            size: 19,
          ),
        ),
        itemBuilder: (context) => const [
          PopupMenuItem<_ViewedProfileAction>(
            key: ValueKey('profile-share-action'),
            value: _ViewedProfileAction.share,
            child: Row(
              children: [
                Icon(Icons.ios_share_rounded, color: fieldGray700, size: 19),
                SizedBox(width: 10),
                Text(
                  'Share profile',
                  style: TextStyle(
                    color: fieldGray900,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem<_ViewedProfileAction>(
            key: ValueKey('profile-report-action'),
            value: _ViewedProfileAction.report,
            child: Row(
              children: [
                Icon(
                  Icons.outlined_flag_rounded,
                  color: Color(0xFFDC2626),
                  size: 19,
                ),
                SizedBox(width: 10),
                Text(
                  'Report player',
                  style: TextStyle(
                    color: Color(0xFFDC2626),
                    fontWeight: FontWeight.w700,
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

class _ProfileClanRoute extends StatefulWidget {
  const _ProfileClanRoute({
    required this.clanId,
    required this.clanName,
    required this.clanRepository,
    required this.fixtureRepository,
    required this.moderationRepository,
  });

  final String clanId;
  final String clanName;
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final ModerationRepository moderationRepository;

  @override
  State<_ProfileClanRoute> createState() => _ProfileClanRouteState();
}

class _ProfileClanRouteState extends State<_ProfileClanRoute> {
  late Future<_ProfileClanRouteData> _future = _load();

  Future<_ProfileClanRouteData> _load() async {
    final results = await Future.wait<dynamic>([
      widget.clanRepository.listClans(),
      widget.clanRepository.getMyClanMembership(),
    ]);
    final clans = results[0] as List<Clan>;
    final membership = results[1] as ClanMembership?;
    Clan? clan;
    for (final candidate in clans) {
      if (candidate.id.trim() == widget.clanId.trim()) {
        clan = candidate;
        break;
      }
    }
    if (clan == null) throw StateError('Clan is unavailable.');
    return _ProfileClanRouteData(clan: clan, membership: membership);
  }

  void _retry() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ProfileClanRouteData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final data = snapshot.data!;
          return ClanDetailScreen(
            clan: data.clan,
            clanRepository: widget.clanRepository,
            fixtureRepository: widget.fixtureRepository,
            currentMembership: data.membership,
            moderationRepository: widget.moderationRepository,
          );
        }
        if (snapshot.hasError) {
          return _ProfileClanLoadError(
            clanName: widget.clanName,
            onRetry: _retry,
          );
        }
        return _ProfileClanLoadingView(clanName: widget.clanName);
      },
    );
  }
}

class _ProfileClanRouteData {
  const _ProfileClanRouteData({required this.clan, required this.membership});

  final Clan clan;
  final ClanMembership? membership;
}

class _ProfileClanLoadingView extends StatelessWidget {
  const _ProfileClanLoadingView({required this.clanName});

  final String clanName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('profile-clan-route-loading'),
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: FieldPageHeader(title: clanName, showBack: true),
        child: ListView(
          padding: fieldHeaderAwarePadding(context, top: 18, bottom: 32),
          children: const [
            FieldSkeletonCard(
              height: 230,
              borderRadius: 24,
              padding: EdgeInsets.all(20),
              children: [
                Center(
                  child: FieldSkeletonBox(
                    width: 82,
                    height: 82,
                    borderRadius: 24,
                  ),
                ),
                SizedBox(height: 18),
                Center(
                  child: FieldSkeletonBox(
                    width: 180,
                    height: 22,
                    borderRadius: 7,
                  ),
                ),
                SizedBox(height: 12),
                Center(
                  child: FieldSkeletonBox(
                    width: 125,
                    height: 14,
                    borderRadius: 7,
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            FieldSkeletonBox(height: 52, borderRadius: 16),
            SizedBox(height: 16),
            FieldSkeletonCard(height: 210, borderRadius: 22),
          ],
        ),
      ),
    );
  }
}

class _ProfileClanLoadError extends StatelessWidget {
  const _ProfileClanLoadError({required this.clanName, required this.onRetry});

  final String clanName;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: FieldPageHeader(title: clanName, showBack: true),
        child: ListView(
          padding: fieldHeaderAwarePadding(context, top: 80, bottom: 32),
          children: [
            const Icon(Icons.shield_outlined, color: fieldGray300, size: 44),
            const SizedBox(height: 14),
            const Text(
              'Clan unavailable',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: fieldGray900,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              'This clan may have been archived or removed.',
              textAlign: TextAlign.center,
              style: TextStyle(color: fieldGray500, fontSize: 13),
            ),
            const SizedBox(height: 18),
            Center(
              child: OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileLoadingView extends StatelessWidget {
  const _ProfileLoadingView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 16, bottom: 124),
      children: const [
        FieldSkeletonCard(
          height: 240,
          borderRadius: 24,
          padding: EdgeInsets.all(20),
          children: [
            Row(
              children: [
                FieldSkeletonBox(width: 80, height: 80, borderRadius: 999),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FieldSkeletonBox(height: 22, borderRadius: 6),
                      SizedBox(height: 9),
                      FieldSkeletonBox(width: 116, height: 14, borderRadius: 6),
                      SizedBox(height: 12),
                      FieldSkeletonBox(width: 178, height: 14, borderRadius: 6),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 22),
            FieldSkeletonBox(height: 14, borderRadius: 6),
            SizedBox(height: 10),
            FieldSkeletonBox(width: 220, height: 14, borderRadius: 6),
            Spacer(),
            Row(
              children: [
                Expanded(child: FieldSkeletonBox(height: 34, borderRadius: 8)),
                SizedBox(width: 20),
                Expanded(child: FieldSkeletonBox(height: 34, borderRadius: 8)),
              ],
            ),
          ],
        ),
        SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FieldSkeletonCard(
                height: 82,
                borderRadius: 18,
                padding: EdgeInsets.all(14),
                children: [
                  FieldSkeletonBox(height: 22, borderRadius: 6),
                  SizedBox(height: 10),
                  FieldSkeletonBox(height: 12, borderRadius: 6),
                ],
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: FieldSkeletonCard(
                height: 82,
                borderRadius: 18,
                padding: EdgeInsets.all(14),
                children: [
                  FieldSkeletonBox(height: 22, borderRadius: 6),
                  SizedBox(height: 10),
                  FieldSkeletonBox(height: 12, borderRadius: 6),
                ],
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: FieldSkeletonCard(
                height: 82,
                borderRadius: 18,
                padding: EdgeInsets.all(14),
                children: [
                  FieldSkeletonBox(height: 22, borderRadius: 6),
                  SizedBox(height: 10),
                  FieldSkeletonBox(height: 12, borderRadius: 6),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 16),
        FieldSkeletonCard(
          height: 188,
          borderRadius: 24,
          padding: EdgeInsets.all(20),
          children: [
            FieldSkeletonBox(width: 150, height: 16, borderRadius: 6),
            SizedBox(height: 18),
            Row(
              children: [
                FieldSkeletonBox(width: 80, height: 56, borderRadius: 12),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FieldSkeletonBox(height: 14, borderRadius: 6),
                      SizedBox(height: 9),
                      FieldSkeletonBox(width: 130, height: 12, borderRadius: 6),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _ProfileErrorView extends StatelessWidget {
  const _ProfileErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 16, bottom: 124),
      children: [
        _ProfileCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Could not load profile',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _viewsLabel(int views, String? clanTag) {
  final formatted = views >= 1000
      ? '${(views / 1000).toStringAsFixed(1).replaceAll('.0', '')}k'
      : views.toString();
  final suffix = clanTag == null || clanTag.isEmpty ? '' : ' - $clanTag';
  return '$formatted views$suffix';
}
