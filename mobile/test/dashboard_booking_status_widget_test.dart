import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home booking card shows pending count and a prominent TODAY', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _game(
      daysFromToday: 0,
      confirmedCount: 8,
      staleAssignment: true,
    );

    await _pumpDashboard(tester, game, team: openQueueWhiteTeamId);

    expect(find.text('MATCH PENDING'), findsOneWidget);
    expect(find.text('8 / 12 CONFIRMED'), findsOneWidget);
    expect(find.text('MATCH CONFIRMED'), findsNothing);
    expect(find.text('Midfielder · 8:30 PM'), findsOneWidget);
    expect(find.textContaining('TODAY ·'), findsOneWidget);
    expect(find.text('TFA, Saar'), findsOneWidget);
    expect(find.byKey(const ValueKey('kit-instruction')), findsNothing);
    expect(find.byKey(const ValueKey('kit-assignment-updating')), findsNothing);
    expect(find.textContaining('WHITE ·'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full home booking card shows confirmed count and TOMORROW', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _game(daysFromToday: 1, confirmedCount: 12);

    await _pumpDashboard(tester, game, team: openQueueBlackTeamId);

    expect(find.text('MATCH CONFIRMED'), findsOneWidget);
    expect(find.text('12 / 12 CONFIRMED'), findsOneWidget);
    expect(find.text('MATCH PENDING'), findsNothing);
    expect(find.textContaining('TOMORROW ·'), findsOneWidget);
    expect(find.text('WEAR BLACK'), findsOneWidget);
    expect(find.byKey(const ValueKey('kit-instruction')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmed home booking never guesses a missing kit color', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _game(daysFromToday: 2, confirmedCount: 12);

    await _pumpDashboard(tester, game);

    expect(find.text('MATCH CONFIRMED'), findsOneWidget);
    expect(find.text('KIT ASSIGNMENT UPDATING'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('kit-assignment-updating')),
      findsOneWidget,
    );
    expect(find.text('WEAR WHITE'), findsNothing);
    expect(find.text('WEAR BLACK'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('activity shows the last and next clan plus solo matchdays', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final today = _bahrainDateNow();
    final last = today.subtract(const Duration(days: 3));
    final older = last.subtract(const Duration(days: 4));
    final next = today.add(const Duration(days: 3));
    final later = next.add(const Duration(days: 4));
    final lastSolo = _fixtureGame(id: 'solo-last', date: last, status: 'FINAL');
    final nextSolo = _fixtureGame(
      id: 'solo-next',
      date: next,
      status: 'OPEN',
      confirmedCount: 8,
    );
    final detail = OpenQueueMatchDetail(
      game: lastSolo,
      scorers: const [],
      timeline: const [],
      players: const [],
      broadcast: const FixtureBroadcast(status: 'REPLAY_READY'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardHome(
            profileRepository: const _FakeProfileRepository(),
            clanRepository: const _FakeClanRepository(),
            fixtureRepository: _FakeFixtureRepository([
              _clanFixture('clan-older', older, FixtureStatus.finalResult),
              _clanFixture('clan-last', last, FixtureStatus.finalResult),
              _clanFixture('clan-next', next, FixtureStatus.scheduled),
              _clanFixture('clan-later', later, FixtureStatus.scheduled),
            ]),
            leaderboardRepository: const _FakeLeaderboardRepository(),
            openQueueRepository: _FakeOpenQueueRepository(
              null,
              fixtureGames: [
                _fixtureGame(id: 'solo-older', date: older, status: 'FINAL'),
                lastSolo,
                nextSolo,
                _fixtureGame(id: 'solo-later', date: later, status: 'OPEN'),
              ],
              matchDetails: {'solo-last': detail},
            ),
            onOpenClans: () {},
            onOpenFixtures: () {},
            onOpenRanks: () {},
            onOpenProfile: () {},
            onNavigateTab: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('ACTIVITY'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('LAST MATCHDAY'), findsOneWidget);
    expect(find.text('NEXT MATCHDAY'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('NEXT MATCHDAY')).dy,
      lessThan(tester.getTopLeft(find.text('LAST MATCHDAY')).dy),
    );
    expect(find.text('2 GAMES'), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('home-activity-clan-clan-last')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-activity-solo-solo-last')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-activity-clan-clan-next')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-activity-solo-solo-next')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-activity-join-solo-next')),
      findsOneWidget,
    );
    expect(find.text('8/12 JOINED'), findsOneWidget);
    expect(find.text('Spots open — join this game'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-activity-clan-clan-older')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('home-activity-solo-solo-later')),
      findsNothing,
    );

    final joinCta = find.byKey(const ValueKey('home-activity-join-solo-next'));
    await tester.scrollUntilVisible(
      joinCta,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -240));
    await tester.pump();
    await tester.tap(joinCta);
    await tester.pumpAndSettle();
    expect(find.text('AVAILABLE SPOTS'), findsOneWidget);
    expect(find.text('8 of 12 confirmed'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    final lastSoloRow = find.byKey(
      const ValueKey('home-activity-solo-solo-last'),
    );
    await tester.scrollUntilVisible(
      lastSoloRow,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -220));
    await tester.pump();
    await tester.tap(lastSoloRow);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('SOLO MATCH'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixture-section-timeline')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setPhoneSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  OpenQueueGame game, {
  String? team,
}) async {
  final booking = OpenQueueBooking(
    id: 'booking',
    gameId: game.id,
    profileId: 'profile',
    role: OpenQueueRole.midfielder,
    status: 'CONFIRMED',
    amountPaidFils: game.priceFils,
    bookedAt: DateTime.now(),
    team: team,
    game: game,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DashboardHome(
          profileRepository: const _FakeProfileRepository(),
          clanRepository: const _FakeClanRepository(),
          fixtureRepository: const _FakeFixtureRepository(),
          leaderboardRepository: const _FakeLeaderboardRepository(),
          openQueueRepository: _FakeOpenQueueRepository(booking),
          onOpenClans: () {},
          onOpenFixtures: () {},
          onOpenRanks: () {},
          onOpenProfile: () {},
          onNavigateTab: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OpenQueueGame _game({
  required int daysFromToday,
  required int confirmedCount,
  bool staleAssignment = false,
}) {
  final nowInBahrain = DateTime.now().toUtc().add(const Duration(hours: 3));
  final bahrainStart = DateTime.utc(
    nowInBahrain.year,
    nowInBahrain.month,
    nowInBahrain.day + daysFromToday,
    20,
    30,
  );
  final startsAt = bahrainStart.subtract(const Duration(hours: 3));
  final hasAssignmentMetadata = confirmedCount == 12 || staleAssignment;
  return OpenQueueGame(
    id: 'game-$daysFromToday-$confirmedCount',
    status: confirmedCount == 12 ? 'FULL' : 'OPEN',
    venue: 'TFA, Saar',
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: 'Ages 16-20',
    capacity: 12,
    confirmedCount: confirmedCount,
    spots: const {},
    whiteAverageSr: hasAssignmentMetadata ? 1200 : null,
    blackAverageSr: hasAssignmentMetadata ? 1200 : null,
    matchAverageSr: hasAssignmentMetadata ? 1200 : null,
    teamSrSpread: hasAssignmentMetadata ? 0 : null,
    teamsAssignedAt: hasAssignmentMetadata ? DateTime.now() : null,
  );
}

DateTime _bahrainDateNow() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 3));
  return DateTime(now.year, now.month, now.day);
}

OpenQueueGame _fixtureGame({
  required String id,
  required DateTime date,
  required String status,
  int confirmedCount = 12,
}) {
  final startsAt = DateTime.utc(date.year, date.month, date.day, 17, 30);
  return OpenQueueGame(
    id: id,
    status: status,
    venue: 'TFA, Saar',
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: 'Ages 16-20',
    capacity: 12,
    confirmedCount: confirmedCount,
    spots: status == 'OPEN'
        ? const {
            OpenQueueRole.goalkeeper: 1,
            OpenQueueRole.defender: 1,
            OpenQueueRole.midfielder: 1,
            OpenQueueRole.attacker: 1,
          }
        : const {},
    whiteScore: status == 'FINAL' ? 4 : null,
    blackScore: status == 'FINAL' ? 3 : null,
  );
}

Fixture _clanFixture(String id, DateTime date, FixtureStatus status) {
  return Fixture(
    id: id,
    status: status,
    homeClanId: _homeClan.id,
    awayClanId: _awayClan.id,
    venue: 'TFA, Saar',
    day: _weekday(date.weekday),
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: date,
    createdBy: 'owner',
    homeClan: _homeClan,
    awayClan: _awayClan,
    homeScore: status == FixtureStatus.finalResult ? 2 : null,
    awayScore: status == FixtureStatus.finalResult ? 1 : null,
  );
}

String _weekday(int weekday) {
  return const [
    'MONDAY',
    'TUESDAY',
    'WEDNESDAY',
    'THURSDAY',
    'FRIDAY',
    'SATURDAY',
    'SUNDAY',
  ][weekday - 1];
}

const _homeClan = FixtureClan(
  id: 'home',
  name: 'Home Clan',
  tag: 'HOME',
  emblem: '⚡',
  themeId: 'mint',
  patternId: 'solid',
  skillRating: 1200,
);

const _awayClan = FixtureClan(
  id: 'away',
  name: 'Away Clan',
  tag: 'AWAY',
  emblem: '🛡️',
  themeId: 'shadow',
  patternId: 'solid',
  skillRating: 1200,
);

class _FakeProfileRepository implements ProfileRepository {
  const _FakeProfileRepository();

  @override
  Future<PlayerProfile> getCurrentProfile() async => const PlayerProfile(
    id: 'profile',
    displayName: 'Dana Alawi',
    username: 'dana',
    bio: '',
    followingCount: 0,
    fansCount: 0,
    appearances: 0,
    goals: 0,
    assists: 0,
    highlights: [],
    career: [],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLeaderboardRepository implements LeaderboardRepository {
  const _FakeLeaderboardRepository();

  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async => const PlayerRatingLeaderboardEntry(
    rank: 0,
    profileId: 'profile',
    displayName: 'Dana Alawi',
    username: 'dana',
    skillRating: 1200,
    matchesPlayed: 0,
    wins: 0,
    losses: 0,
    draws: 0,
    lastChange: 0,
    region: 'bahrain',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOpenQueueRepository implements OpenQueueRepository {
  const _FakeOpenQueueRepository(
    this.booking, {
    this.fixtureGames = const [],
    this.matchDetails = const {},
  });

  final OpenQueueBooking? booking;
  final List<OpenQueueGame> fixtureGames;
  final Map<String, OpenQueueMatchDetail> matchDetails;

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async => booking;

  @override
  Future<List<OpenQueueGame>> listGames() async => [
    if (booking case final value?) value.game,
  ];

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => fixtureGames;

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async =>
      matchDetails[gameId]!;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClanRepository implements ClanRepository {
  const _FakeClanRepository();

  @override
  Future<List<Clan>> listClans() async => const [];

  @override
  Future<ClanMembership?> getMyClanMembership() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFixtureRepository implements FixtureRepository {
  const _FakeFixtureRepository([this.fixtures = const []]);

  final List<Fixture> fixtures;

  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;

  @override
  Future<List<Fixture>> listFixtures() async => fixtures;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
