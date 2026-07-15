import 'package:flutter/material.dart';

import '../clans/clan.dart';
import '../clans/clan_detail_screen.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture_repository.dart';
import '../profile/profile.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import 'leaderboard.dart';
import 'leaderboard_repository.dart';

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({
    super.key,
    required this.clanRepository,
    required this.fixtureRepository,
    required this.leaderboardRepository,
    this.activationTick = 0,
    this.playerActivationTick = 0,
  });

  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final LeaderboardRepository leaderboardRepository;
  final int activationTick;
  final int playerActivationTick;

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardRegion {
  const _LeaderboardRegion({required this.id, required this.label});

  final String id;
  final String label;
}

enum _LeaderboardMode { clans, players }

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  static const _activeRegion = _LeaderboardRegion(
    id: 'bahrain',
    label: 'Bahrain',
  );

  static const _seasons = leaderboardSeasons;

  final ProfileRepository _profileRepository = SupabaseProfileRepository();
  _LeaderboardMode _mode = _LeaderboardMode.clans;
  int _seasonIndex = 0;
  int _loadGeneration = 0;
  late String _lastActiveSeasonId;
  List<Clan> _clans = const [];
  ClanMembership? _myMembership;
  LeaderboardPlayerStats _playerStats = const LeaderboardPlayerStats(
    finalMatchCount: 0,
    clanRecords: {},
    topScorers: [],
    topAssisters: [],
  );
  List<PlayerRatingLeaderboardEntry> _playerRatings = const [];
  String? _currentProfileId;
  bool _isLoading = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final activeSeason = activeLeaderboardSeason;
    final activeIndex = _seasons.indexWhere(
      (season) => season.id == activeSeason.id,
    );
    _seasonIndex = activeIndex < 0 ? 0 : activeIndex;
    _lastActiveSeasonId = activeSeason.id;
    _load();
  }

  @override
  void didUpdateWidget(covariant LeaderboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final playerActivated =
        widget.playerActivationTick != oldWidget.playerActivationTick;
    final ranksActivated = widget.activationTick != oldWidget.activationTick;
    var shouldReload = false;

    if (playerActivated) {
      _mode = _LeaderboardMode.players;
      shouldReload = _selectActiveSeasonInState(force: true);
    } else if (ranksActivated) {
      shouldReload = _selectActiveSeasonInState();
    }

    if (shouldReload) {
      _loadGeneration++;
      _isLoading = true;
      _errorText = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  LeaderboardSeason get _selectedSeason => _seasons[_seasonIndex];

  bool _selectActiveSeasonInState({bool force = false}) {
    final activeSeason = activeLeaderboardSeason;
    final seasonChanged = activeSeason.id != _lastActiveSeasonId;
    _lastActiveSeasonId = activeSeason.id;
    if (!force && !seasonChanged) return false;

    final activeIndex = _seasons.indexWhere(
      (season) => season.id == activeSeason.id,
    );
    if (activeIndex < 0 || activeIndex == _seasonIndex) return false;
    _seasonIndex = activeIndex;
    return true;
  }

  Future<void> _refresh() async {
    _selectActiveSeasonInState();
    await _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final season = _selectedSeason;
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final results = await Future.wait([
        widget.clanRepository.listClans(),
        widget.clanRepository.getMyClanMembership(),
        widget.leaderboardRepository.loadPlayerStats(season),
        widget.leaderboardRepository.loadPlayerRatingLeaderboard(
          season: season,
        ),
        _profileRepository.getCurrentProfile(),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _clans = (results[0] as List<Clan>).toList()
          ..sort((a, b) {
            final ratingCompare = b.skillRating.compareTo(a.skillRating);
            if (ratingCompare != 0) return ratingCompare;
            return a.name.compareTo(b.name);
          });
        _myMembership = results[1] as ClanMembership?;
        _playerStats = results[2] as LeaderboardPlayerStats;
        _playerRatings = results[3] as List<PlayerRatingLeaderboardEntry>;
        _currentProfileId = (results[4] as PlayerProfile).id;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _errorText = userFacingError(
          error,
          fallback: 'We could not load the leaderboard. Try again.',
        );
      });
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _selectSeason(int index) {
    if (index == _seasonIndex) return;
    setState(() => _seasonIndex = index);
    _load();
  }

  void _previousSeason() {
    if (_seasonIndex == 0) return;
    _selectSeason(_seasonIndex - 1);
  }

  void _nextSeason() {
    if (_seasonIndex == _seasons.length - 1) return;
    _selectSeason(_seasonIndex + 1);
  }

  Future<void> _openClan(Clan clan) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ClanDetailScreen(
          clan: clan,
          clanRepository: widget.clanRepository,
          fixtureRepository: widget.fixtureRepository,
          currentMembership: _myMembership,
        ),
      ),
    );
    if (mounted) {
      await _load();
    }
  }

  Future<void> _openPlayerProfile(LeaderboardPlayerStat player) async {
    return _openProfileId(player.profileId);
  }

  Future<void> _openRatingProfile(PlayerRatingLeaderboardEntry player) {
    return _openProfileId(player.profileId);
  }

  Future<void> _openProfileId(String profileId) async {
    if (profileId.trim().isEmpty) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: fieldBackground,
          body: ProfileScreen(
            profileRepository: _profileRepository,
            profileId: profileId,
          ),
        ),
      ),
    );
  }

  Future<void> _openAllRankings(List<Clan> rankedClans) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _AllRankingsScreen(
          region: _activeRegion,
          clans: rankedClans,
          clanRecords: _playerStats.clanRecords,
          myMembership: _myMembership,
          clanRepository: widget.clanRepository,
          fixtureRepository: widget.fixtureRepository,
        ),
      ),
    );
    if (mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final clanRecords = _playerStats.clanRecords;
    final rankedClans =
        _clans
            .where(
              (clan) =>
                  clan.region == _activeRegion.id &&
                  _playerStats.isClanEligible(clan.id),
            )
            .toList()
          ..sort((a, b) {
            final srCompare = b.skillRating.compareTo(a.skillRating);
            if (srCompare != 0) return srCompare;
            return a.name.compareTo(b.name);
          });
    final topRankedClans = rankedClans.take(10).toList();
    final statEmptyMessage = _playerStats.finalMatchCount == 0
        ? 'No matches played.'
        : 'No data.';

    return FieldHeaderOverlay(
      header: const FieldPageHeader(title: 'Leaderboards'),
      child: RefreshIndicator(
        color: fieldEmerald600,
        edgeOffset: fieldPageHeaderExtent(context),
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: fieldHeaderAwarePadding(context, top: 16, bottom: 124),
          children: [
            _LeaderboardModeSelector(
              mode: _mode,
              onChanged: (mode) => setState(() => _mode = mode),
            ),
            const SizedBox(height: 18),
            _SeasonSelector(
              season: _selectedSeason,
              canGoPrevious: _seasonIndex > 0,
              canGoNext: _seasonIndex < _seasons.length - 1,
              onPrevious: _previousSeason,
              onNext: _nextSeason,
            ),
            const SizedBox(height: 12),
            if (_mode == _LeaderboardMode.clans)
              const _ClanLeaderboardEligibilityNote()
            else
              const _PlayerLeaderboardEligibilityNote(),
            const SizedBox(height: 24),
            if (_mode == _LeaderboardMode.clans) ...[
              _SectionHeader(
                title: 'The Top 10',
                action: rankedClans.isEmpty
                    ? null
                    : _ViewRankingsButton(
                        onTap: () => _openAllRankings(rankedClans),
                      ),
              ),
              const SizedBox(height: 12),
              if (_isLoading)
                const _LeaderboardLoadingState()
              else if (_errorText != null)
                _LeaderboardErrorState(message: _errorText!, onRetry: _load)
              else if (topRankedClans.isEmpty)
                const _NoLeaderboardDataState(
                  message: 'No clans have completed 4 matches this season.',
                )
              else
                for (var i = 0; i < topRankedClans.length; i++) ...[
                  _ClanRankRow(
                    rank: i + 1,
                    clan: topRankedClans[i],
                    record:
                        clanRecords[topRankedClans[i].id] ??
                        const LeaderboardClanRecord(
                          wins: 0,
                          losses: 0,
                          draws: 0,
                        ),
                    isMe: topRankedClans[i].id == _myMembership?.clanId,
                    onTap: () => _openClan(topRankedClans[i]),
                  ),
                  if (i != topRankedClans.length - 1) const SizedBox(height: 8),
                ],
              const SizedBox(height: 30),
              _PlayerStatSection(
                title: 'Top Scorers',
                icon: Icons.sports_soccer_rounded,
                iconColor: fieldEmerald600,
                emptyMessage: statEmptyMessage,
                label: 'goals',
                players: _playerStats.topScorers,
                loading: _isLoading,
                onPlayerTap: _openPlayerProfile,
              ),
              const SizedBox(height: 24),
              _PlayerStatSection(
                title: 'Top Assisters',
                icon: Icons.auto_awesome_rounded,
                iconColor: fieldBlue600,
                emptyMessage: statEmptyMessage,
                label: 'assists',
                players: _playerStats.topAssisters,
                loading: _isLoading,
                onPlayerTap: _openPlayerProfile,
              ),
            ] else ...[
              _PlayerRatingHero(season: _selectedSeason),
              const SizedBox(height: 18),
              if (_isLoading)
                const _LeaderboardLoadingState()
              else if (_errorText != null)
                _LeaderboardErrorState(message: _errorText!, onRetry: _load)
              else if (_playerRatings.isEmpty)
                const _NoLeaderboardDataState(
                  message:
                      'No players have completed 2 rated games this season.',
                )
              else
                for (var i = 0; i < _playerRatings.length; i++) ...[
                  _PlayerRatingRow(
                    player: _playerRatings[i],
                    isMe: _playerRatings[i].profileId == _currentProfileId,
                    onTap: () => _openRatingProfile(_playerRatings[i]),
                  ),
                  if (i != _playerRatings.length - 1) const SizedBox(height: 8),
                ],
            ],
          ],
        ),
      ),
    );
  }
}

class _LeaderboardModeSelector extends StatelessWidget {
  const _LeaderboardModeSelector({required this.mode, required this.onChanged});

  final _LeaderboardMode mode;
  final ValueChanged<_LeaderboardMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_LeaderboardMode>(
      key: const ValueKey('leaderboard-mode-selector'),
      showSelectedIcon: false,
      expandedInsets: EdgeInsets.zero,
      segments: const [
        ButtonSegment(value: _LeaderboardMode.clans, label: Text('Clans')),
        ButtonSegment(value: _LeaderboardMode.players, label: Text('Players')),
      ],
      selected: {mode},
      onSelectionChanged: (selection) => onChanged(selection.first),
      style: ButtonStyle(
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w900),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : fieldGray600,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? fieldGray900
              : Colors.white,
        ),
      ),
    );
  }
}

class _PlayerRatingHero extends StatelessWidget {
  const _PlayerRatingHero({required this.season});

  final LeaderboardSeason season;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF047857), Color(0xFF0F3D31)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33047857),
            blurRadius: 20,
            offset: Offset(0, 9),
          ),
        ],
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PLAYER LADDER',
                  style: TextStyle(
                    color: fieldEmerald200,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.4,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Your game. Your rating.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  'Bahrain · Season rankings',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Icon(
                Icons.emoji_events_rounded,
                color: fieldEmerald200,
                size: 34,
              ),
              const SizedBox(height: 8),
              Text(
                season.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayerRatingRow extends StatelessWidget {
  const _PlayerRatingRow({
    required this.player,
    required this.isMe,
    required this.onTap,
  });

  final PlayerRatingLeaderboardEntry player;
  final bool isMe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isMe ? fieldEmerald50 : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: isMe ? fieldEmerald200 : fieldGray100),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  '#${player.rank}',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    color: player.rank <= 3 ? fieldEmerald700 : fieldGray400,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              CircleAvatar(
                radius: 21,
                backgroundColor: fieldGray100,
                backgroundImage: player.avatarUrl?.trim().isNotEmpty == true
                    ? NetworkImage(player.avatarUrl!)
                    : null,
                child: player.avatarUrl?.trim().isNotEmpty == true
                    ? null
                    : Text(
                        player.initials,
                        style: const TextStyle(
                          color: fieldGray600,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            player.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: fieldGray900,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 5),
                          const Text(
                            'YOU',
                            style: TextStyle(
                              color: fieldEmerald700,
                              fontSize: 8,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      '${player.tierLabel} · ${player.matchesPlayed} season games',
                      style: const TextStyle(
                        color: fieldGray400,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${player.skillRating}',
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '${player.lastChange >= 0 ? '+' : ''}${player.lastChange}',
                    style: TextStyle(
                      color: player.lastChange >= 0
                          ? fieldEmerald600
                          : Colors.redAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
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
}

class _AllRankingsScreen extends StatelessWidget {
  const _AllRankingsScreen({
    required this.region,
    required this.clans,
    required this.clanRecords,
    required this.myMembership,
    required this.clanRepository,
    required this.fixtureRepository,
  });

  final _LeaderboardRegion region;
  final List<Clan> clans;
  final Map<String, LeaderboardClanRecord> clanRecords;
  final ClanMembership? myMembership;
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;

  Future<void> _openClan(BuildContext context, Clan clan) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ClanDetailScreen(
          clan: clan,
          clanRepository: clanRepository,
          fixtureRepository: fixtureRepository,
          currentMembership: myMembership,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: FieldPageHeader(
          title: '${region.label} Rankings',
          showBack: true,
        ),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: fieldHeaderAwarePadding(context, top: 18, bottom: 40),
          children: [
            _RankingsSummaryCard(region: region, clanCount: clans.length),
            const SizedBox(height: 12),
            const _ClanLeaderboardEligibilityNote(),
            const SizedBox(height: 16),
            _SectionHeader(
              title: 'All Clans',
              trailing: '${clans.length} clans',
            ),
            const SizedBox(height: 12),
            if (clans.isEmpty)
              const _NoLeaderboardDataState(
                message: 'No clans have completed 4 matches this season.',
              )
            else
              for (var i = 0; i < clans.length; i++) ...[
                _ClanRankRow(
                  rank: i + 1,
                  clan: clans[i],
                  record:
                      clanRecords[clans[i].id] ??
                      const LeaderboardClanRecord(wins: 0, losses: 0, draws: 0),
                  isMe: clans[i].id == myMembership?.clanId,
                  onTap: () => _openClan(context, clans[i]),
                ),
                if (i != clans.length - 1) const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }
}

class _ClanLeaderboardEligibilityNote extends StatelessWidget {
  const _ClanLeaderboardEligibilityNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: fieldGray400, size: 16),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              'Clans need at least $minimumClanLeaderboardMatches completed '
              'matches in the selected season to be ranked.',
              style: const TextStyle(
                color: fieldGray500,
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerLeaderboardEligibilityNote extends StatelessWidget {
  const _PlayerLeaderboardEligibilityNote();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: fieldGray400, size: 16),
          SizedBox(width: 7),
          Expanded(
            child: Text(
              'Players need at least $minimumPlayerLeaderboardMatches completed rated games in the selected season to be ranked. Clan and Open Queue games both count.',
              style: TextStyle(
                color: fieldGray500,
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RankingsSummaryCard extends StatelessWidget {
  const _RankingsSummaryCard({required this.region, required this.clanCount});

  final _LeaderboardRegion region;
  final int clanCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: fieldGray900.withValues(alpha: 0.035),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [fieldEmerald500, fieldBlue600],
              ),
              borderRadius: BorderRadius.circular(15),
              boxShadow: [
                BoxShadow(
                  color: fieldEmerald500.withValues(alpha: 0.24),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(
              Icons.leaderboard_rounded,
              color: Colors.white,
              size: 23,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  region.label.toUpperCase(),
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 18,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '$clanCount CLAN${clanCount == 1 ? '' : 'S'} RANKED BY SR',
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 10,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
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

class _SeasonSelector extends StatelessWidget {
  const _SeasonSelector({
    required this.season,
    required this.canGoPrevious,
    required this.canGoNext,
    required this.onPrevious,
    required this.onNext,
  });

  final LeaderboardSeason season;
  final bool canGoPrevious;
  final bool canGoNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: fieldGray900.withValues(alpha: 0.035),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _SeasonArrowButton(
            icon: Icons.chevron_left_rounded,
            enabled: canGoPrevious,
            onTap: onPrevious,
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeOutCubic,
              transitionBuilder: (child, animation) {
                final offsetAnimation = Tween<Offset>(
                  begin: const Offset(0, 0.16),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: offsetAnimation,
                    child: child,
                  ),
                );
              },
              child: Column(
                key: ValueKey(season.id),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    season.label.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 16,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isActiveLeaderboardSeason(season)) ...[
                        const _LiveDot(),
                        const SizedBox(width: 5),
                        const Text(
                          'LIVE',
                          style: TextStyle(
                            color: fieldEmerald600,
                            fontSize: 10,
                            height: 1,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 3,
                          height: 3,
                          decoration: const BoxDecoration(
                            color: fieldGray300,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          season.rangeLabel.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: fieldGray400,
                            fontSize: 10,
                            height: 1,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          _SeasonArrowButton(
            icon: Icons.chevron_right_rounded,
            enabled: canGoNext,
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

class _SeasonArrowButton extends StatelessWidget {
  const _SeasonArrowButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.3,
      duration: const Duration(milliseconds: 150),
      child: Material(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, color: fieldGray500, size: 21),
          ),
        ),
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 0.45,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: fieldEmerald500,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.trailing,
    this.icon,
    this.action,
  });

  final String title;
  final String? trailing;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(
          width: 4,
          height: 24,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [fieldEmerald500, fieldBlue600],
              ),
              borderRadius: BorderRadius.all(Radius.circular(999)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (icon != null) ...[
          Icon(icon, size: 16, color: fieldEmerald600),
          const SizedBox(width: 7),
        ],
        Expanded(
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              color: icon == null ? fieldGray900 : fieldGray700,
              fontSize: icon == null ? 20 : 12,
              height: 1,
              fontWeight: FontWeight.w900,
              letterSpacing: icon == null ? 0 : 1.8,
            ),
          ),
        ),
        if (trailing != null)
          Text(
            trailing!.toUpperCase(),
            style: const TextStyle(
              color: fieldGray400,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
        if (action != null) action!,
      ],
    );
  }
}

class _ViewRankingsButton extends StatelessWidget {
  const _ViewRankingsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: fieldGray100),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: fieldGray900.withValues(alpha: 0.035),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.format_list_numbered_rounded, size: 15),
              SizedBox(width: 6),
              Text(
                'VIEW RANKINGS',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClanRankRow extends StatelessWidget {
  const _ClanRankRow({
    required this.rank,
    required this.clan,
    required this.record,
    required this.isMe,
    required this.onTap,
  });

  final int rank;
  final Clan clan;
  final LeaderboardClanRecord record;
  final bool isMe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFFECFDF5) : Colors.white,
            border: Border.all(
              color: isMe ? const Color(0xFFA7F3D0) : fieldGray100,
              width: isMe ? 1.2 : 1,
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: fieldGray900.withValues(alpha: isMe ? 0.045 : 0.03),
                blurRadius: isMe ? 16 : 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              _RankBadge(rank: rank),
              const SizedBox(width: 12),
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: fieldGray100,
                  border: Border.all(color: fieldGray100),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(clan.emblem, style: const TextStyle(fontSize: 24)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            clan.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: fieldGray900,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFD1FAE5),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: const Text(
                              'YOU',
                              style: TextStyle(
                                color: Color(0xFF047857),
                                fontSize: 9,
                                height: 1,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.7,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Text(
                          record.label,
                          style: const TextStyle(
                            color: fieldGray500,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        TierLabelBadge(rank: clan.rank, small: true),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    clan.skillRating.toString(),
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 18,
                      height: 1,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'SR',
                    style: TextStyle(
                      color: fieldGray400,
                      fontSize: 10,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
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
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    if (rank == 1) {
      return Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [fieldEmerald500, fieldBlue600],
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: fieldEmerald500.withValues(alpha: 0.30),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: const Icon(
          Icons.workspace_premium_rounded,
          color: Colors.white,
          size: 19,
        ),
      );
    }

    final podium = rank <= 3;
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: podium
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [fieldGray700, fieldGray900],
              )
            : null,
        color: podium ? null : fieldGray100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        rank.toString(),
        style: TextStyle(
          color: podium ? Colors.white : fieldGray700,
          fontSize: 14,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _PlayerStatSection extends StatelessWidget {
  const _PlayerStatSection({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.emptyMessage,
    required this.label,
    required this.players,
    required this.loading,
    required this.onPlayerTap,
  });

  final String title;
  final IconData icon;
  final Color iconColor;
  final String emptyMessage;
  final String label;
  final List<LeaderboardPlayerStat> players;
  final bool loading;
  final ValueChanged<LeaderboardPlayerStat> onPlayerTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SectionHeader(title: title, icon: icon),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: fieldGray100),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: fieldGray900.withValues(alpha: 0.03),
                blurRadius: 12,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: loading
              ? const Column(
                  children: [
                    _PlayerStatSkeletonRow(),
                    Divider(height: 1, color: fieldGray100),
                    _PlayerStatSkeletonRow(),
                    Divider(height: 1, color: fieldGray100),
                    _PlayerStatSkeletonRow(),
                  ],
                )
              : players.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    emptyMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: fieldGray400,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < players.length; i++) ...[
                      _PlayerStatRow(
                        rank: i + 1,
                        player: players[i],
                        label: label,
                        iconColor: iconColor,
                        onTap: () => onPlayerTap(players[i]),
                      ),
                      if (i != players.length - 1)
                        const Divider(height: 1, color: fieldGray100),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _PlayerStatRow extends StatelessWidget {
  const _PlayerStatRow({
    required this.rank,
    required this.player,
    required this.label,
    required this.iconColor,
    required this.onTap,
  });

  final int rank;
  final LeaderboardPlayerStat player;
  final String label;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: rank == 1
                    ? const Icon(
                        Icons.military_tech_rounded,
                        color: Color(0xFFF59E0B),
                        size: 22,
                      )
                    : Text(
                        rank.toString(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: fieldGray400,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              _PlayerAvatar(player: player, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      player.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${player.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray500,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    player.value.toString(),
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 20,
                      height: 1,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label.toUpperCase(),
                    style: const TextStyle(
                      color: fieldGray400,
                      fontSize: 10,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
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
}

class _PlayerAvatar extends StatelessWidget {
  const _PlayerAvatar({required this.player, required this.color});

  final LeaderboardPlayerStat player;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final avatarUrl = player.avatarUrl;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [fieldEmerald500, fieldBlue600]),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.18),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: avatarUrl == null || avatarUrl.isEmpty
          ? Center(
              child: Text(
                player.initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
            )
          : Image.network(
              avatarUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Center(
                  child: Text(
                    player.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _LeaderboardLoadingState extends StatelessWidget {
  const _LeaderboardLoadingState();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 5; i++) ...[
          const _ClanRankSkeletonRow(),
          if (i != 4) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _ClanRankSkeletonRow extends StatelessWidget {
  const _ClanRankSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const FieldSkeletonCard(
      height: 70,
      borderRadius: 18,
      padding: EdgeInsets.all(12),
      children: [
        Row(
          children: [
            FieldSkeletonBox(width: 38, height: 38, borderRadius: 12),
            SizedBox(width: 12),
            FieldSkeletonBox(width: 44, height: 44, borderRadius: 13),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FieldSkeletonBox(height: 14, borderRadius: 6),
                  SizedBox(height: 8),
                  FieldSkeletonBox(width: 140, height: 12, borderRadius: 6),
                ],
              ),
            ),
            SizedBox(width: 12),
            FieldSkeletonBox(width: 48, height: 28, borderRadius: 8),
          ],
        ),
      ],
    );
  }
}

class _PlayerStatSkeletonRow extends StatelessWidget {
  const _PlayerStatSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(12),
      child: Row(
        children: [
          FieldSkeletonBox(width: 28, height: 20, borderRadius: 6),
          SizedBox(width: 10),
          FieldSkeletonBox(width: 42, height: 42, borderRadius: 999),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FieldSkeletonBox(height: 14, borderRadius: 6),
                SizedBox(height: 8),
                FieldSkeletonBox(width: 120, height: 12, borderRadius: 6),
              ],
            ),
          ),
          SizedBox(width: 12),
          FieldSkeletonBox(width: 34, height: 32, borderRadius: 8),
        ],
      ),
    );
  }
}

class _LeaderboardErrorState extends StatelessWidget {
  const _LeaderboardErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _StatePanel(
      icon: Icons.warning_rounded,
      title: 'Leaderboard unavailable',
      message: message,
      actionLabel: 'Try Again',
      onAction: onRetry,
    );
  }
}

class _NoLeaderboardDataState extends StatelessWidget {
  const _NoLeaderboardDataState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _StatePanel(
      icon: Icons.emoji_events_outlined,
      title: 'No data',
      message: message,
    );
  }
}

class _StatePanel extends StatelessWidget {
  const _StatePanel({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Icon(icon, color: fieldGray400, size: 32),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
