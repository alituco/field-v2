import 'package:flutter/material.dart';

import '../clans/clan.dart';
import '../clans/clan_detail_screen.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_detail_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../leaderboard/leaderboard.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../open_queue/open_queue.dart';
import '../open_queue/open_queue_booking_screen.dart';
import '../open_queue/open_queue_repository.dart';
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

  List<Fixture> get _activity {
    final rows = [..._fixtures];
    int priority(Fixture fixture) => switch (fixture.status) {
      FixtureStatus.live => 0,
      FixtureStatus.scheduled => 1,
      FixtureStatus.open => 2,
      FixtureStatus.finalResult => 3,
      FixtureStatus.cancelled => 4,
    };
    rows.sort((a, b) {
      final status = priority(a).compareTo(priority(b));
      if (status != 0) return status;
      if (a.status == FixtureStatus.finalResult) {
        return b.matchDate.compareTo(a.matchDate);
      }
      return a.matchDate.compareTo(b.matchDate);
    });
    return rows.where((fixture) => !fixture.isCancelled).take(4).toList();
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
                fixtures: _activity,
                onSeeAll: widget.onOpenFixtures,
                onFixture: _openFixture,
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
              Text(
                '$playerCount player${playerCount == 1 ? '' : 's'} already booked',
                style: const TextStyle(
                  color: fieldEmerald200,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
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
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const RadialGradient(
              center: Alignment.topLeft,
              radius: 1.4,
              colors: [fieldEmerald500, fieldEmerald600, Color(0xFF0B3D2E)],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x4410B981),
                blurRadius: 22,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: Colors.white,
                    size: 19,
                  ),
                  SizedBox(width: 7),
                  Text(
                    'MATCH CONFIRMED',
                    style: TextStyle(
                      color: fieldEmerald100,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 11),
              Text(
                '${booking.role.label} · ${booking.game.startTimeLabel}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                booking.team == null
                    ? '${booking.game.venue} · ${booking.game.dateGroup}'
                    : '${booking.team} TEAM · ${_bookingTeamAverage(booking)} AVG SR',
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
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
  final rating = booking.team == openQueueWhiteTeamId
      ? booking.game.whiteAverageSr
      : booking.game.blackAverageSr;
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

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({
    required this.fixtures,
    required this.onSeeAll,
    required this.onFixture,
  });
  final List<Fixture> fixtures;
  final VoidCallback onSeeAll;
  final ValueChanged<Fixture> onFixture;

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
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(23),
            border: Border.all(color: fieldGray100),
          ),
          clipBehavior: Clip.antiAlias,
          child: fixtures.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'No fixture activity yet.',
                    style: TextStyle(color: fieldGray500),
                  ),
                )
              : Column(
                  children: [
                    for (var index = 0; index < fixtures.length; index++) ...[
                      _ActivityRow(
                        fixture: fixtures[index],
                        onTap: () => onFixture(fixtures[index]),
                      ),
                      if (index != fixtures.length - 1)
                        const Divider(height: 1, color: fieldGray100),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.fixture, required this.onTap});
  final Fixture fixture;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = switch (fixture.status) {
      FixtureStatus.live => ('LIVE', Colors.orange, Icons.circle),
      FixtureStatus.finalResult => ('FT', fieldGray400, Icons.circle),
      FixtureStatus.open => ('OPEN', fieldBlue600, Icons.group_outlined),
      _ => ('UP', fieldEmerald600, Icons.sensors_rounded),
    };
    final matchup = fixture.isFinal
        ? '${fixture.homeClan.tag}  ${fixture.homeScore}–${fixture.awayScore}  ${fixture.awayClan?.tag ?? 'TBD'}'
        : '${fixture.homeClan.tag}  vs  ${fixture.awayClan?.tag ?? 'TBD'}';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              child: Column(
                children: [
                  Icon(status.$3, color: status.$2, size: 13),
                  Text(
                    status.$1,
                    style: TextStyle(
                      color: status.$2,
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    matchup,
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${fixture.venue} · ${_fixtureStart(fixture)}',
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
            const Icon(
              Icons.chevron_right_rounded,
              color: fieldGray300,
              size: 18,
            ),
          ],
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
