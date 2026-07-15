import 'package:flutter/material.dart';

import '../clans/clan.dart';
import '../clans/clan_detail_screen.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_detail_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../fixtures/fixtures_screen.dart';
import '../leaderboard/leaderboard.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../open_queue/open_queue.dart';
import '../open_queue/open_queue_booking_screen.dart';
import '../open_queue/open_queue_kit_indicator.dart';
import '../open_queue/open_queue_repository.dart';
import '../open_queue/open_queue_review_screen.dart';
import '../open_queue/open_queue_screen.dart';
import '../profile/profile.dart';
import '../profile/profile_repository.dart';

class DashboardHome extends StatefulWidget {
  const DashboardHome({
    super.key,
    required this.profileRepository,
    required this.clanRepository,
    required this.fixtureRepository,
    required this.leaderboardRepository,
    required this.openQueueRepository,
    required this.onOpenClans,
    required this.onOpenFixtures,
    required this.onOpenRanks,
    required this.onOpenProfile,
    required this.onNavigateTab,
  });

  final ProfileRepository profileRepository;
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final LeaderboardRepository leaderboardRepository;
  final OpenQueueRepository openQueueRepository;
  final VoidCallback onOpenClans;
  final VoidCallback onOpenFixtures;
  final VoidCallback onOpenRanks;
  final VoidCallback onOpenProfile;
  final ValueChanged<int> onNavigateTab;

  @override
  State<DashboardHome> createState() => _DashboardHomeState();
}

class _DashboardHomeState extends State<DashboardHome> {
  PlayerProfile? _profile;
  PlayerRatingLeaderboardEntry? _rating;
  LeaderboardSeason _ratingSeason = activeLeaderboardSeason;
  OpenQueueBooking? _booking;
  int _openQueuePlayerCount = 0;
  List<Clan> _clans = const [];
  Clan? _myClan;
  ClanMembership? _clanMembership;
  MyClanMembership? _fixtureMembership;
  List<Fixture> _fixtures = const [];
  List<OpenQueueGame> _soloFixtureGames = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ratingSeason = activeLeaderboardSeason;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<dynamic>([
        widget.profileRepository.getCurrentProfile(),
        widget.leaderboardRepository.loadCurrentPlayerRating(ratingSeason),
        widget.openQueueRepository.getMyUpcomingBooking(),
        widget.openQueueRepository.listGames(),
        widget.clanRepository.listClans(),
        widget.clanRepository.getMyClanMembership(),
        widget.fixtureRepository.getMyClanMembership(),
        widget.fixtureRepository.listFixtures(),
        widget.openQueueRepository.listFixtureGames(),
      ]);
      if (!mounted) return;
      final profile = results[0] as PlayerProfile;
      final rating = results[1] as PlayerRatingLeaderboardEntry;
      final games = results[3] as List<OpenQueueGame>;
      final clans = results[4] as List<Clan>;
      final membership = results[5] as ClanMembership?;
      setState(() {
        _profile = profile;
        _rating = rating;
        _ratingSeason = ratingSeason;
        _booking = results[2] as OpenQueueBooking?;
        _openQueuePlayerCount = games.fold<int>(
          0,
          (total, game) => total + game.confirmedCount,
        );
        _clans = clans;
        _clanMembership = membership;
        _fixtureMembership = results[6] as MyClanMembership?;
        _myClan = membership == null
            ? null
            : clans.cast<Clan?>().firstWhere(
                (clan) => clan?.id == membership.clanId,
                orElse: () => null,
              );
        _fixtures = results[7] as List<Fixture>;
        _soloFixtureGames = results[8] as List<OpenQueueGame>;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(
          error,
          fallback: 'We could not load your home feed.',
        );
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openQueue() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OpenQueueScreen(
          repository: widget.openQueueRepository,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openBooking() async {
    final booking = _booking;
    if (booking == null) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OpenQueueBookingScreen(
          repository: widget.openQueueRepository,
          booking: booking,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openClan() async {
    final clan = _myClan;
    if (clan == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ClanDetailScreen(
          clan: clan,
          clanRepository: widget.clanRepository,
          fixtureRepository: widget.fixtureRepository,
          currentMembership: _clanMembership,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openFixture(Fixture fixture) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FixtureDetailScreen(
          fixture: fixture,
          fixtureRepository: widget.fixtureRepository,
          myClanMembership: _fixtureMembership,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openSoloGame(OpenQueueGame game) async {
    final status = game.status.toUpperCase();
    if (status == 'FULL' ||
        status == 'LIVE' ||
        status == 'FINAL' ||
        game.isFull) {
      await _openSoloMatchDetail(game);
      return;
    }

    final role = await showSoloFixtureAvailabilitySheet(context, game);
    if (role == null || !mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OpenQueueReviewScreen(
          repository: widget.openQueueRepository,
          game: game,
          role: role,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openSoloMatchDetail(OpenQueueGame game) async {
    try {
      final detail = await widget.openQueueRepository.getMatchDetail(game.id);
      if (!mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => FixtureDetailScreen(
            fixture: detail.toFixture(),
            fixtureRepository: widget.fixtureRepository,
            myClanMembership: null,
            sourceLabel: 'SOLO',
            showTeamRatings: false,
            playerRatingUpdate: detail.viewerRatingUpdate,
            refreshFixture: () async {
              final next = await widget.openQueueRepository.getMatchDetail(
                game.id,
              );
              return next.toFixture();
            },
          ),
        ),
      );
      if (mounted) await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not open this solo match. Try again.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _openActivity(_HomeActivityItem item) {
    final fixture = item.fixture;
    if (fixture != null) return _openFixture(fixture);
    return _openSoloGame(item.soloGame!);
  }

  List<_HomeMatchdayGroup> get _activityMatchdays {
    final items = <_HomeActivityItem>[
      for (final fixture in _fixtures)
        if (!fixture.isCancelled) _HomeActivityItem.clan(fixture),
      for (final game in _soloFixtureGames)
        if (game.status.toUpperCase() != 'CANCELLED')
          _HomeActivityItem.solo(game),
    ];
    final today = _bahrainTodayDate();
    final past = items
        .where(
          (item) =>
              item.status == FixtureStatus.finalResult &&
              item.matchDate.isBefore(today),
        )
        .toList();
    final currentOrFuture = items
        .where((item) => !item.matchDate.isBefore(today))
        .toList();

    final groups = <_HomeMatchdayGroup>[];
    if (currentOrFuture.isNotEmpty) {
      final date = currentOrFuture
          .map((item) => item.matchDate)
          .reduce((left, right) => left.isBefore(right) ? left : right);
      groups.add(
        _HomeMatchdayGroup(
          date: date,
          isUpcoming: true,
          items: _matchdayItems(currentOrFuture, date),
        ),
      );
    }
    if (past.isNotEmpty) {
      final date = past
          .map((item) => item.matchDate)
          .reduce((left, right) => left.isAfter(right) ? left : right);
      groups.add(
        _HomeMatchdayGroup(
          date: date,
          isUpcoming: false,
          items: _matchdayItems(past, date),
        ),
      );
    }
    return groups;
  }

  Fixture? get _nextClanFixture {
    final clan = _myClan;
    if (clan == null) return null;
    final candidates = _fixtures.where((fixture) {
      return !fixture.isFinal &&
          !fixture.isCancelled &&
          (fixture.homeClanId == clan.id || fixture.awayClanId == clan.id);
    }).toList()..sort((a, b) => a.matchDate.compareTo(b.matchDate));
    return candidates.isEmpty ? null : candidates.first;
  }

  @override
  Widget build(BuildContext context) {
    return FieldHeaderOverlay(
      header: const FieldPageHeader(title: 'Field'),
      child: RefreshIndicator(
        color: fieldEmerald600,
        edgeOffset: fieldPageHeaderExtent(context),
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: fieldHeaderAwarePadding(context, top: 16, bottom: 124),
          children: [
            if (_loading && _profile == null) ...[
              const FieldSkeletonBox(height: 150, borderRadius: 24),
              const SizedBox(height: 16),
              const FieldSkeletonBox(height: 245, borderRadius: 24),
              const SizedBox(height: 16),
              const FieldSkeletonBox(height: 170, borderRadius: 24),
            ] else if (_error != null && _profile == null)
              _HomeError(message: _error!, onRetry: _load)
            else ...[
              _PlayerRatingCard(
                profile: _profile!,
                rating: _rating,
                season: _ratingSeason,
                onTap: widget.onOpenProfile,
                onRanks: widget.onOpenRanks,
              ),
              const SizedBox(height: 18),
              if (_booking case final booking?)
                _ConfirmedQueueHero(booking: booking, onTap: _openBooking)
              else
                _FindGameHero(
                  onTap: _openQueue,
                  playerCount: _openQueuePlayerCount,
                ),
              const SizedBox(height: 22),
              if (_myClan case final clan?)
                _MyClanSection(
                  clan: clan,
                  nextFixture: _nextClanFixture,
                  regionalRank: _regionalClanRank(clan),
                  onTap: _openClan,
                )
              else
                _FindClanSection(
                  recruitingCount: _clans
                      .where((clan) => clan.memberCount < 20)
                      .length,
                  onTap: widget.onOpenClans,
                ),
              const SizedBox(height: 23),
              _ActivitySection(
                matchdays: _activityMatchdays,
                onSeeAll: widget.onOpenFixtures,
                onMatch: _openActivity,
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: fieldGray400, fontSize: 11),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  int _regionalClanRank(Clan clan) {
    final ranked =
        _clans.where((candidate) => candidate.region == clan.region).toList()
          ..sort((a, b) => b.skillRating.compareTo(a.skillRating));
    final index = ranked.indexWhere((candidate) => candidate.id == clan.id);
    return index < 0 ? 0 : index + 1;
  }
}

class _PlayerRatingCard extends StatelessWidget {
  const _PlayerRatingCard({
    required this.profile,
    required this.rating,
    required this.season,
    required this.onTap,
    required this.onRanks,
  });

  final PlayerProfile profile;
  final PlayerRatingLeaderboardEntry? rating;
  final LeaderboardSeason season;
  final VoidCallback onTap;
  final VoidCallback onRanks;

  @override
  Widget build(BuildContext context) {
    final value = rating?.skillRating ?? 1200;
    final ratingChange = rating?.lastChange ?? 0;
    final tier = playerRatingTier(value);
    final next = playerRatingNextTierTarget(value);
    final isMaxTier = value >= next;
    final progressStart = next == 800
        ? 0
        : next == 1200
        ? 800
        : next == 1600
        ? 1200
        : next == 2000
        ? 1600
        : 2000;
    final progress = ((value - progressStart) / (next - progressStart)).clamp(
      0.0,
      1.0,
    );
    final gamesNeeded =
        rating?.gamesNeededToRank ?? minimumPlayerLeaderboardMatches;
    final rankLabel = rating?.isRanked == true
        ? '#${rating!.rank} in Bahrain · ${season.label}'
        : '$gamesNeeded rated game${gamesNeeded == 1 ? '' : 's'} to enter ${season.label} rankings';

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Container(
          padding: const EdgeInsets.all(19),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: fieldGray100),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0D111827),
                blurRadius: 12,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFFF59E0B),
                                Color(0xFFFCD34D),
                                Color(0xFFD97706),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(15),
                            child: ColoredBox(
                              color: Colors.white,
                              child:
                                  profile.avatarUrl?.trim().isNotEmpty == true
                                  ? Image.network(
                                      profile.avatarUrl!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Center(
                                        child: Text(
                                          profile.initials,
                                          style: const TextStyle(
                                            color: fieldGray700,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                                    )
                                  : Center(
                                      child: Text(
                                        profile.initials,
                                        style: const TextStyle(
                                          color: fieldGray700,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: -2,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: fieldGray900,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              tier.toUpperCase(),
                              style: const TextStyle(
                                color: Color(0xFFFCD34D),
                                fontSize: 7,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ],
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
                            letterSpacing: 1.2,
                          ),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '$value',
                              style: const TextStyle(
                                color: fieldGray900,
                                fontSize: 31,
                                height: 1.1,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${ratingChange >= 0 ? '+' : ''}$ratingChange',
                                style: TextStyle(
                                  color: ratingChange < 0
                                      ? Colors.redAccent
                                      : fieldEmerald600,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          rankLabel,
                          maxLines: 2,
                          style: const TextStyle(
                            color: fieldGray500,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: onRanks,
                    borderRadius: BorderRadius.circular(16),
                    child: const Column(
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFFFBBF24), Color(0xFFF97316)],
                            ),
                            borderRadius: BorderRadius.all(Radius.circular(14)),
                          ),
                          child: SizedBox(
                            width: 42,
                            height: 42,
                            child: Icon(
                              Icons.emoji_events_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'RANKS',
                          style: TextStyle(
                            color: fieldGray400,
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    tier,
                    style: const TextStyle(
                      color: fieldGray400,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    isMaxTier
                        ? 'Max tier'
                        : 'Next tier · ${next - value} to go',
                    style: const TextStyle(
                      color: fieldGray400,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: progress,
                  color: const Color(0xFFF59E0B),
                  backgroundColor: fieldGray100,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FindGameHero extends StatelessWidget {
  const _FindGameHero({required this.onTap, required this.playerCount});
  final VoidCallback onTap;
  final int playerCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(23),
      decoration: BoxDecoration(
        gradient: const RadialGradient(
          center: Alignment.topRight,
          radius: 1.45,
          colors: [Color(0xFF159F72), Color(0xFF047857), Color(0xFF07352A)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33065F46),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.circle, color: Color(0xFFBEF264), size: 8),
              SizedBox(width: 7),
              Text(
                'RANKED OPEN QUEUE · LIVE',
                style: TextStyle(
                  color: fieldEmerald200,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'READY FOR A MATCH?',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              height: 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose your position, see balanced 6-a-side games, then book your spot.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFD1FAE5),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(62),
              backgroundColor: Colors.white,
              foregroundColor: fieldEmerald800,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: const CircleAvatar(
              radius: 16,
              backgroundColor: fieldEmerald600,
              child: Icon(Icons.bolt_rounded, color: Colors.white, size: 18),
            ),
            label: const Text(
              'FIND A GAME',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 40,
                height: 18,
                child: Stack(
                  children: [
                    for (var index = 0; index < 3; index++)
                      Positioned(
                        left: index * 11,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: fieldEmerald200,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: fieldEmerald800,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '$playerCount player${playerCount == 1 ? '' : 's'} already booked',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fieldEmerald200,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
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

class _ConfirmedQueueHero extends StatelessWidget {
  const _ConfirmedQueueHero({required this.booking, required this.onTap});
  final OpenQueueBooking booking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final game = booking.game;
    final isConfirmed = game.isUpcomingMatchConfirmed;
    final isClose = game.isToday || game.isTomorrow;
    final confirmedCount = game.confirmedCount.clamp(0, game.capacity);
    final accent = isConfirmed ? fieldEmerald100 : const Color(0xFFFEF3C7);
    final dateForeground = isConfirmed
        ? fieldEmerald800
        : const Color(0xFF78350F);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topLeft,
              radius: 1.4,
              colors: isConfirmed
                  ? const [fieldEmerald500, fieldEmerald600, Color(0xFF0B3D2E)]
                  : const [
                      Color(0xFFF59E0B),
                      Color(0xFF92400E),
                      Color(0xFF3B2106),
                    ],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: isConfirmed
                    ? const Color(0x4410B981)
                    : const Color(0x44F59E0B),
                blurRadius: 22,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isConfirmed
                            ? Icons.check_circle_rounded
                            : Icons.hourglass_top_rounded,
                        color: Colors.white,
                        size: 19,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        isConfirmed ? 'MATCH CONFIRMED' : 'MATCH PENDING',
                        style: TextStyle(
                          color: accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$confirmedCount / ${game.capacity} CONFIRMED',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 11),
              Text(
                '${booking.role.label} · ${game.startTimeLabel}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                key: const ValueKey('match-day-kit-panel'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isClose
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: isClose ? 0.9 : 0.2),
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.calendar_month_rounded,
                          color: isClose ? dateForeground : Colors.white,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            game.prominentDateLabel,
                            style: TextStyle(
                              color: isClose ? dateForeground : Colors.white,
                              fontSize: isClose ? 15 : 13,
                              fontWeight: FontWeight.w900,
                              letterSpacing: isClose ? 0.5 : 0.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (isConfirmed) ...[
                      const SizedBox(height: 10),
                      Container(
                        height: 1,
                        color: isClose
                            ? fieldGray200
                            : Colors.white.withValues(alpha: 0.18),
                      ),
                      const SizedBox(height: 10),
                      OpenQueueKitIndicator(booking: booking),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.location_on_outlined,
                    color: Colors.white70,
                    size: 16,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      game.venue,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (isConfirmed)
                    if (booking.assignedTeam case final team?)
                      Text(
                        '$team · ${_bookingTeamAverage(booking)} AVG SR',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                ],
              ),
              const SizedBox(height: 13),
              const Text(
                'View booking  ›',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _bookingTeamAverage(OpenQueueBooking booking) {
  final rating = switch (booking.assignedTeam) {
    openQueueWhiteTeamId => booking.game.whiteAverageSr,
    openQueueBlackTeamId => booking.game.blackAverageSr,
    _ => null,
  };
  return rating?.toString() ?? '—';
}

class _MyClanSection extends StatelessWidget {
  const _MyClanSection({
    required this.clan,
    required this.nextFixture,
    required this.regionalRank,
    required this.onTap,
  });
  final Clan clan;
  final Fixture? nextFixture;
  final int regionalRank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _HomeSectionLabel('YOUR CLAN'),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: fieldGray100),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: fieldGray100,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Center(
                      child: Text(
                        clan.emblem,
                        style: const TextStyle(fontSize: 22),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          clan.name,
                          style: const TextStyle(
                            color: fieldGray900,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text.rich(
                          TextSpan(
                            children: [
                              const TextSpan(
                                text: 'CLAN RATING ',
                                style: TextStyle(
                                  color: fieldBlue600,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              TextSpan(
                                text:
                                    '${clan.skillRating} · #$regionalRank Bahrain',
                                style: const TextStyle(
                                  color: fieldGray500,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: fieldEmerald50,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      clan.rank.label,
                      style: const TextStyle(
                        color: fieldEmerald700,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: fieldGray100,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  nextFixture == null
                      ? 'No upcoming fixture'
                      : 'Next fixture · ${nextFixture!.homeClanId == clan.id ? 'vs ${nextFixture!.awayClan?.tag ?? 'TBD'}' : 'vs ${nextFixture!.homeClan.tag}'} · ${nextFixture!.day} ${_fixtureStart(nextFixture!)}',
                  style: const TextStyle(
                    color: fieldGray600,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 11),
              FilledButton(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(45),
                  backgroundColor: fieldGray900,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'View Clan',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FindClanSection extends StatelessWidget {
  const _FindClanSection({required this.recruitingCount, required this.onTap});
  final int recruitingCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _HomeSectionLabel('FIND YOUR CLAN'),
        const SizedBox(height: 10),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: fieldGray100),
              ),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: const Icon(
                      Icons.groups_rounded,
                      color: fieldBlue600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Join a Clan',
                          style: TextStyle(
                            color: fieldGray900,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          '$recruitingCount clans are currently recruiting',
                          style: const TextStyle(
                            color: fieldGray500,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: fieldGray300),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeMatchdayGroup {
  const _HomeMatchdayGroup({
    required this.date,
    required this.isUpcoming,
    required this.items,
  });

  final DateTime date;
  final bool isUpcoming;
  final List<_HomeActivityItem> items;
}

class _HomeActivityItem {
  const _HomeActivityItem._({this.fixture, this.soloGame});

  factory _HomeActivityItem.clan(Fixture fixture) {
    return _HomeActivityItem._(fixture: fixture);
  }

  factory _HomeActivityItem.solo(OpenQueueGame game) {
    return _HomeActivityItem._(soloGame: game);
  }

  final Fixture? fixture;
  final OpenQueueGame? soloGame;

  bool get isSolo => soloGame != null;

  bool get canJoinSolo {
    final game = soloGame;
    if (game == null) return false;
    return status == FixtureStatus.open &&
        !game.isFull &&
        !game.hasMyBooking &&
        game.startsAt.isAfter(DateTime.now());
  }

  String get id => fixture?.id ?? soloGame!.id;

  DateTime get matchDate {
    final clanFixture = fixture;
    if (clanFixture != null) return _calendarDate(clanFixture.matchDate);
    final startsAt = soloGame!.bahrainStartsAt;
    return DateTime(startsAt.year, startsAt.month, startsAt.day);
  }

  FixtureStatus get status {
    final clanFixture = fixture;
    if (clanFixture != null) return clanFixture.status;
    final game = soloGame!;
    return switch (game.status.toUpperCase()) {
      'FULL' => FixtureStatus.scheduled,
      'LIVE' => FixtureStatus.live,
      'FINAL' => FixtureStatus.finalResult,
      'CANCELLED' => FixtureStatus.cancelled,
      _ when game.isFull => FixtureStatus.scheduled,
      _ => FixtureStatus.open,
    };
  }

  int get sortMinutes {
    final game = soloGame;
    if (game != null) {
      final startsAt = game.bahrainStartsAt;
      return startsAt.hour * 60 + startsAt.minute;
    }
    return fixture!.timeSlot.startsWith('8:30') ? 20 * 60 + 30 : 19 * 60;
  }

  String get matchup {
    final clanFixture = fixture;
    if (clanFixture != null) {
      final away = clanFixture.awayClan?.tag ?? 'TBD';
      if (clanFixture.isFinal || clanFixture.isLive) {
        return '${clanFixture.homeClan.tag}  ${clanFixture.homeScore}–${clanFixture.awayScore}  $away';
      }
      return '${clanFixture.homeClan.tag} vs $away';
    }
    final game = soloGame!;
    if (status == FixtureStatus.finalResult || status == FixtureStatus.live) {
      return 'WHITE  ${game.whiteScore ?? 0}–${game.blackScore ?? 0}  BLACK';
    }
    if (canJoinSolo) return 'Spots open — join this game';
    return 'Open Queue Game';
  }

  String get venue => fixture?.venue ?? soloGame!.venue;

  String get timeLabel {
    final game = soloGame;
    return game?.timeLabel ?? _fixtureStart(fixture!);
  }

  String get typeLabel => isSolo ? 'SOLO' : 'CLAN';

  String get statusLabel {
    if (status == FixtureStatus.finalResult) return 'FT';
    if (status == FixtureStatus.live) return 'LIVE';
    if (isSolo && status == FixtureStatus.open) {
      final game = soloGame!;
      return '${game.confirmedCount}/${game.capacity}';
    }
    return switch (status) {
      FixtureStatus.open => 'OPEN',
      FixtureStatus.scheduled => 'CONFIRMED',
      FixtureStatus.cancelled => 'CANCELLED',
      _ => 'UPCOMING',
    };
  }
}

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({
    required this.matchdays,
    required this.onSeeAll,
    required this.onMatch,
  });
  final List<_HomeMatchdayGroup> matchdays;
  final VoidCallback onSeeAll;
  final ValueChanged<_HomeActivityItem> onMatch;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            const _HomeSectionLabel('ACTIVITY'),
            const Spacer(),
            TextButton.icon(
              onPressed: onSeeAll,
              icon: const Icon(Icons.chevron_right_rounded, size: 16),
              iconAlignment: IconAlignment.end,
              label: const Text('See all'),
              style: TextButton.styleFrom(foregroundColor: fieldEmerald600),
            ),
          ],
        ),
        const SizedBox(height: 7),
        if (matchdays.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: fieldGray100),
            ),
            child: const Text(
              'No matchday activity yet.',
              style: TextStyle(color: fieldGray500),
            ),
          )
        else
          for (var index = 0; index < matchdays.length; index++) ...[
            _ActivityMatchdayCard(matchday: matchdays[index], onMatch: onMatch),
            if (index != matchdays.length - 1) const SizedBox(height: 12),
          ],
      ],
    );
  }
}

class _ActivityMatchdayCard extends StatelessWidget {
  const _ActivityMatchdayCard({required this.matchday, required this.onMatch});

  final _HomeMatchdayGroup matchday;
  final ValueChanged<_HomeActivityItem> onMatch;

  @override
  Widget build(BuildContext context) {
    final isToday = _sameCalendarDate(matchday.date, _bahrainTodayDate());
    final heading = matchday.isUpcoming
        ? isToday
              ? 'TODAY'
              : 'NEXT MATCHDAY'
        : 'LAST MATCHDAY';
    final accent = matchday.isUpcoming ? fieldEmerald600 : fieldBlue600;
    final accentBackground = matchday.isUpcoming
        ? fieldEmerald50
        : const Color(0xFFEFF6FF);

    return Container(
      key: ValueKey('home-activity-matchday-${_dateKey(matchday.date)}'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: fieldGray100),
        boxShadow: [
          BoxShadow(
            color: fieldGray900.withValues(alpha: 0.035),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 14, 15, 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: accentBackground,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    matchday.isUpcoming
                        ? Icons.event_available_rounded
                        : Icons.sports_score_rounded,
                    color: accent,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        heading,
                        style: TextStyle(
                          color: accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _matchdayDateLabel(matchday.date),
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${matchday.items.length} GAME${matchday.items.length == 1 ? '' : 'S'}',
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: fieldGray100),
          for (var index = 0; index < matchday.items.length; index++) ...[
            _ActivityRow(
              item: matchday.items[index],
              onTap: () => onMatch(matchday.items[index]),
            ),
            if (index != matchday.items.length - 1)
              const Divider(height: 1, indent: 70, color: fieldGray100),
          ],
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item, required this.onTap});
  final _HomeActivityItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final typeColor = item.isSolo ? fieldBlue600 : fieldEmerald600;
    final typeBackground = item.isSolo
        ? const Color(0xFFEFF6FF)
        : fieldEmerald50;
    final statusColor = switch (item.status) {
      FixtureStatus.live => const Color(0xFFDC2626),
      FixtureStatus.finalResult => fieldGray600,
      FixtureStatus.open => fieldBlue600,
      _ => fieldEmerald700,
    };
    final statusBackground = switch (item.status) {
      FixtureStatus.live => const Color(0xFFFEF2F2),
      FixtureStatus.finalResult => fieldGray100,
      FixtureStatus.open => const Color(0xFFEFF6FF),
      _ => fieldEmerald50,
    };

    return Semantics(
      button: true,
      label: item.canJoinSolo
          ? 'Join open queue match, ${item.statusLabel} players confirmed'
          : 'Open ${item.typeLabel.toLowerCase()} match ${item.matchup}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey(
            'home-activity-${item.isSolo ? 'solo' : 'clan'}-${item.id}',
          ),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: typeBackground,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    item.isSolo ? Icons.person_rounded : Icons.shield_rounded,
                    color: typeColor,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 11),
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
                              color: typeBackground,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              item.typeLabel,
                              style: TextStyle(
                                color: typeColor,
                                fontSize: 8,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.7,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item.matchup,
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
                        '${item.timeLabel} · ${item.venue}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: fieldGray400,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 9),
                if (item.canJoinSolo)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${item.statusLabel} JOINED',
                        style: const TextStyle(
                          color: fieldEmerald700,
                          fontSize: 8,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.35,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        key: ValueKey('home-activity-join-${item.id}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [fieldEmerald500, fieldEmerald700],
                          ),
                          borderRadius: BorderRadius.circular(11),
                          boxShadow: [
                            BoxShadow(
                              color: fieldEmerald500.withValues(alpha: 0.25),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.bolt_rounded,
                              color: Colors.white,
                              size: 13,
                            ),
                            SizedBox(width: 2),
                            Text(
                              'JOIN',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.7,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: statusBackground,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          item.statusLabel,
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: fieldGray100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.arrow_forward_rounded,
                          color: fieldGray500,
                          size: 13,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeSectionLabel extends StatelessWidget {
  const _HomeSectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: fieldGray500,
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.25,
      ),
    );
  }
}

class _HomeError extends StatelessWidget {
  const _HomeError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_rounded, color: fieldGray400, size: 38),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

String _fixtureStart(Fixture fixture) {
  return fixture.timeSlot.split(' - ').first;
}

List<_HomeActivityItem> _matchdayItems(
  List<_HomeActivityItem> candidates,
  DateTime date,
) {
  final rows =
      candidates
          .where((item) => _sameCalendarDate(item.matchDate, date))
          .toList()
        ..sort((left, right) {
          final time = left.sortMinutes.compareTo(right.sortMinutes);
          return time != 0 ? time : left.id.compareTo(right.id);
        });
  return rows.take(2).toList();
}

DateTime _bahrainTodayDate() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 3));
  return DateTime(now.year, now.month, now.day);
}

DateTime _calendarDate(DateTime value) {
  return DateTime(value.year, value.month, value.day);
}

bool _sameCalendarDate(DateTime left, DateTime right) {
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

String _dateKey(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

String _matchdayDateLabel(DateTime value) {
  const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
  const months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];
  return '${weekdays[value.weekday - 1]}, ${months[value.month - 1]} ${value.day}';
}
