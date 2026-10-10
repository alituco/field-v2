import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/fixtures/fixtures_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Fixtures combines clan and solo games in kickoff order', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final date = _nextMatchDay(DateTime.now());
    final clan = _clanFixture(date);
    final solo = _soloGame(
      id: 'solo-open',
      date: date,
      status: 'OPEN',
      confirmedCount: 8,
    );

    await _pumpFixtures(tester, fixtures: [clan], soloGames: [solo]);
    await _showCard(tester, 'solo-fixture-solo-open');

    expect(
      find.byKey(const ValueKey('clan-fixture-clan-game')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('solo-fixture-solo-open')),
      findsOneWidget,
    );
    expect(find.text('CLAN'), findsOneWidget);
    expect(find.text('SOLO'), findsOneWidget);
    expect(find.text('8/12'), findsOneWidget);
    expect(find.text('8:30 PM–9:30 PM'), findsOneWidget);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('clan-fixture-clan-game')))
          .dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('solo-fixture-solo-open')))
            .dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed solo history defaults to its latest actual game', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final pastDate = _previousMatchDay(DateTime.now());
    final finalGame = _soloGame(
      id: 'solo-final',
      date: pastDate,
      status: 'FINAL',
      confirmedCount: 12,
      whiteScore: 4,
      blackScore: 2,
      whiteAverageSr: 1232,
      blackAverageSr: 1228,
      matchAverageSr: 1230,
      teamSrSpread: 4,
    );

    await _pumpFixtures(tester, fixtures: const [], soloGames: [finalGame]);
    await _showCard(tester, 'solo-fixture-solo-final');

    expect(
      find.byKey(const ValueKey('solo-fixture-solo-final')),
      findsOneWidget,
    );
    expect(find.text('Final'), findsOneWidget);
    expect(find.text('White'), findsOneWidget);
    expect(find.text('Black'), findsOneWidget);
    expect(find.text('4 - 2'), findsOneWidget);
    expect(find.text('1232 AVG SR'), findsOneWidget);
    expect(find.text('1228 AVG SR'), findsOneWidget);
    expect(find.text('Match avg 1230 SR · 4 SR spread'), findsOneWidget);
    expect(find.text('No matches yet'), findsNothing);
  });

  testWidgets('completed solo fixture opens full match detail, not booking', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final pastDate = _previousMatchDay(DateTime.now());
    final finalGame = _soloGame(
      id: 'solo-detail',
      date: pastDate,
      status: 'FINAL',
      confirmedCount: 12,
      whiteScore: 3,
      blackScore: 2,
      whiteAverageSr: 1232,
      blackAverageSr: 1228,
      matchAverageSr: 1230,
      teamSrSpread: 4,
    );
    final goalTime = finalGame.startsAt.add(const Duration(minutes: 18));
    final scorer = const FixtureParticipant(
      id: 'player-one',
      displayName: 'Solo Scorer',
      username: 'solo.scorer',
    );
    final goal = FixtureTimelineEvent(
      id: 'solo-goal',
      fixtureId: finalGame.id,
      eventType: 'GOAL',
      clanId: openQueueWhiteTeamId,
      profileId: scorer.id,
      minute: 18,
      second: 7,
      occurredAt: goalTime,
      createdAt: goalTime,
      player: scorer,
    );
    final detail = OpenQueueMatchDetail(
      game: finalGame,
      broadcast: FixtureBroadcast(
        status: 'REPLAY_READY',
        streamStartedAt: finalGame.startsAt,
        streamStoppedAt: finalGame.endsAt,
      ),
      scorers: [
        FixtureScorer(
          id: goal.id,
          fixtureId: finalGame.id,
          clanId: openQueueWhiteTeamId,
          profileId: scorer.id,
          minute: goal.minute,
          createdAt: goalTime,
          scorer: scorer,
        ),
      ],
      timeline: [goal],
      players: const [
        OpenQueuePlayer(
          id: 'player-one',
          displayName: 'Solo Scorer',
          username: 'solo.scorer',
          role: OpenQueueRole.attacker,
          team: openQueueWhiteTeamId,
          played: true,
          isMe: true,
          ratingAtTeamAssignment: 1238,
          ratingAtMatchStart: 1240,
          ratingChange: 12,
        ),
        OpenQueuePlayer(
          id: 'player-two',
          displayName: 'Black Keeper',
          username: 'black.keeper',
          role: OpenQueueRole.goalkeeper,
          team: openQueueBlackTeamId,
          played: true,
          isMe: false,
          ratingAtTeamAssignment: 1228,
          ratingAtMatchStart: 1229,
          ratingChange: -11,
        ),
      ],
    );

    await _pumpFixtures(
      tester,
      fixtures: const [],
      soloGames: [finalGame],
      soloDetails: {finalGame.id: detail},
    );
    await _showCard(tester, 'solo-fixture-solo-detail');
    await tester.tap(find.byKey(const ValueKey('solo-fixture-solo-detail')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('SOLO MATCH'), findsOneWidget);
    expect(find.text('White Team'), findsOneWidget);
    expect(find.text('Black Team'), findsOneWidget);
    expect(find.text('1232 AVG PLAYER RATING'), findsOneWidget);
    expect(find.text('1228 AVG PLAYER RATING'), findsOneWidget);
    expect(find.text('MATCH AVG 1230 SR  ·  4 SR SPREAD'), findsOneWidget);
    expect(find.byKey(const ValueKey('fixture-main-switcher')), findsOneWidget);
    expect(find.text('GOALS & ASSISTS'), findsNothing);
    expect(find.text('PLAYER RATING UPDATE'), findsOneWidget);
    expect(find.text('+12 SR'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fixture-section-lineups')));
    await tester.pumpAndSettle();
    expect(find.text('TEAM LINEUPS'), findsOneWidget);
    expect(find.text('Solo Scorer (You)'), findsOneWidget);
    expect(find.text('Black Keeper'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixture-formation-pitch')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('lineup-team-switcher')), findsNothing);
    expect(find.text('BOTH'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('fixture-section-timeline')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('fixture-section-timeline')),
      findsOneWidget,
    );
    expect(find.textContaining('Solo Scorer'), findsWidgets);
    expect(find.text('GOALS & ASSISTS'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('fixture-section-watch')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('WATCH MATCH'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('WATCH MATCH'), findsOneWidget);
    expect(find.text('AVAILABLE SPOTS'), findsNothing);
    expect(find.text('OPEN QUEUE BOOKING'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('solo FULL games are grouped by the Scheduled filter', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final date = _nextMatchDay(DateTime.now());
    final fullGame = _soloGame(
      id: 'solo-full',
      date: date,
      status: 'FULL',
      confirmedCount: 12,
    );

    await _pumpFixtures(tester, fixtures: const [], soloGames: [fullGame]);
    await tester.ensureVisible(find.text('Scheduled'));
    await tester.tap(find.text('Scheduled'));
    await tester.pump(const Duration(milliseconds: 220));
    await _showCard(tester, 'solo-fixture-solo-full');

    expect(
      find.byKey(const ValueKey('solo-fixture-solo-full')),
      findsOneWidget,
    );
    expect(find.text('Full'), findsOneWidget);
  });

  testWidgets(
    'tapping a solo fixture shows its spots and books that exact game',
    (tester) async {
      await _setPhoneSize(tester);
      final date = _nextMatchDay(DateTime.now().add(const Duration(days: 1)));
      final game = _soloGame(
        id: 'specific-solo-game',
        date: date,
        status: 'OPEN',
        confirmedCount: 9,
        venue: 'Specific Match Arena',
        spots: const {
          OpenQueueRole.goalkeeper: 0,
          OpenQueueRole.defender: 2,
          OpenQueueRole.midfielder: 1,
          OpenQueueRole.attacker: 0,
        },
      );

      await _pumpFixtures(tester, fixtures: const [], soloGames: [game]);
      await _showCard(tester, 'solo-fixture-specific-solo-game');
      await tester.tap(
        find.byKey(const ValueKey('solo-fixture-specific-solo-game')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('AVAILABLE SPOTS'), findsOneWidget);
      expect(find.text('2 spots left'), findsOneWidget);
      expect(find.text('1 spot left'), findsOneWidget);
      expect(find.text('Full'), findsNWidgets(2));
      expect(find.text('Specific Match Arena'), findsWidgets);
      expect(find.text('WHERE DO YOU PLAY?'), findsNothing);
      expect(find.text('Choose your main position.'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('solo-spot-DEF')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.text('OPEN QUEUE BOOKING'), findsOneWidget);
      expect(find.text('Defender'), findsOneWidget);
      expect(find.text('Specific Match Arena'), findsWidgets);
      expect(find.text('WHERE DO YOU PLAY?'), findsNothing);
      expect(find.text('Choose your main position.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a full solo fixture opens its assigned balanced teams', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final date = _nextMatchDay(DateTime.now().add(const Duration(days: 1)));
    final game = _soloGame(
      id: 'full-specific-game',
      date: date,
      status: 'FULL',
      confirmedCount: 12,
      spots: const {
        OpenQueueRole.goalkeeper: 0,
        OpenQueueRole.defender: 0,
        OpenQueueRole.midfielder: 0,
        OpenQueueRole.attacker: 0,
      },
      whiteAverageSr: 1204,
      blackAverageSr: 1202,
      matchAverageSr: 1203,
      teamSrSpread: 2,
    );
    final detail = OpenQueueMatchDetail(
      game: game,
      scorers: const [],
      timeline: const [],
      players: const [
        OpenQueuePlayer(
          id: 'white-player',
          displayName: 'White Player',
          role: OpenQueueRole.defender,
          team: openQueueWhiteTeamId,
          played: false,
          isMe: true,
          ratingAtTeamAssignment: 1204,
        ),
        OpenQueuePlayer(
          id: 'black-player',
          displayName: 'Black Player',
          role: OpenQueueRole.defender,
          team: openQueueBlackTeamId,
          played: false,
          isMe: false,
          ratingAtTeamAssignment: 1202,
        ),
      ],
    );

    await _pumpFixtures(
      tester,
      fixtures: const [],
      soloGames: [game],
      soloDetails: {game.id: detail},
    );
    await _showCard(tester, 'solo-fixture-full-specific-game');
    await tester.tap(
      find.byKey(const ValueKey('solo-fixture-full-specific-game')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('SOLO MATCH'), findsOneWidget);
    expect(find.text('1204 AVG PLAYER RATING'), findsOneWidget);
    expect(find.text('1202 AVG PLAYER RATING'), findsOneWidget);
    expect(find.text('MATCH AVG 1203 SR  ·  2 SR SPREAD'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fixture-section-lineups')));
    await tester.pumpAndSettle();
    expect(find.text('White Player (You)'), findsOneWidget);
    expect(find.text('Black Player'), findsOneWidget);
    expect(find.text('AVAILABLE SPOTS'), findsNothing);
    expect(find.text('OPEN QUEUE BOOKING'), findsNothing);
  });

  testWidgets('past unresolved matches show operational state, not a result', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final date = _previousMatchDay(DateTime.now());
    final clan = _clanFixture(
      date,
      operationalState: MatchOperationalState.noData,
      homeScore: 3,
      awayScore: 0,
    );
    final solo = _soloGame(
      id: 'solo-review',
      date: date,
      status: 'FINAL',
      confirmedCount: 12,
      operationalState: MatchOperationalState.underReview,
      whiteScore: 4,
      blackScore: 2,
    );

    await _pumpFixtures(tester, fixtures: [clan], soloGames: [solo]);
    await _showCard(tester, 'solo-fixture-solo-review');

    expect(find.text('No data'), findsOneWidget);
    expect(find.text('Under review'), findsOneWidget);
    expect(find.text('3 - 0'), findsNothing);
    expect(find.text('4 - 2'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled clan and solo games remain visible and labelled', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final date = _nextMatchDay(DateTime.now());
    final clan = _clanFixture(date, status: FixtureStatus.cancelled);
    final solo = _soloGame(
      id: 'solo-cancelled',
      date: date,
      status: 'CANCELLED',
      confirmedCount: 0,
    );

    await _pumpFixtures(tester, fixtures: [clan], soloGames: [solo]);
    await _showCard(tester, 'solo-fixture-solo-cancelled');

    expect(
      find.byKey(const ValueKey('clan-fixture-clan-game')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('solo-fixture-solo-cancelled')),
      findsOneWidget,
    );
    expect(find.text('Cancelled'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setPhoneSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpFixtures(
  WidgetTester tester, {
  required List<Fixture> fixtures,
  required List<OpenQueueGame> soloGames,
  Map<String, OpenQueueMatchDetail> soloDetails = const {},
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FixturesScreen(
          fixtureRepository: _FakeFixtureRepository(fixtures),
          openQueueRepository: _FakeOpenQueueRepository(
            soloGames,
            details: soloDetails,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
}

Future<void> _showCard(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump(const Duration(milliseconds: 300));
}

DateTime _nextMatchDay(DateTime from) {
  var date = DateTime(from.year, from.month, from.day);
  while (!isFixtureMatchDay(date)) {
    date = date.add(const Duration(days: 1));
  }
  return date;
}

DateTime _previousMatchDay(DateTime from) {
  var date = DateTime(
    from.year,
    from.month,
    from.day,
  ).subtract(const Duration(days: 1));
  while (!isFixtureMatchDay(date)) {
    date = date.subtract(const Duration(days: 1));
  }
  return date;
}

Fixture _clanFixture(
  DateTime date, {
  FixtureStatus status = FixtureStatus.scheduled,
  MatchOperationalState operationalState = MatchOperationalState.normal,
  int? homeScore,
  int? awayScore,
}) {
  return Fixture(
    id: 'clan-game',
    status: status,
    operationalState: operationalState,
    homeClanId: _homeClan.id,
    awayClanId: _awayClan.id,
    venue: 'TFA, Saar',
    day: date.weekday == DateTime.tuesday ? 'TUESDAY' : 'FRIDAY',
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: date,
    homeScore: homeScore,
    awayScore: awayScore,
    createdBy: 'leader-1',
    homeClan: _homeClan,
    awayClan: _awayClan,
  );
}

OpenQueueGame _soloGame({
  required String id,
  required DateTime date,
  required String status,
  required int confirmedCount,
  String venue = 'TFA, Saar',
  Map<OpenQueueRole, int> spots = const {
    OpenQueueRole.goalkeeper: 1,
    OpenQueueRole.defender: 1,
    OpenQueueRole.midfielder: 1,
    OpenQueueRole.attacker: 1,
  },
  int? whiteScore,
  int? blackScore,
  int? whiteAverageSr,
  int? blackAverageSr,
  int? matchAverageSr,
  int? teamSrSpread,
  MatchOperationalState operationalState = MatchOperationalState.normal,
}) {
  final startsAt = DateTime.utc(date.year, date.month, date.day, 17, 30);
  return OpenQueueGame(
    id: id,
    status: status,
    operationalState: operationalState,
    venue: venue,
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: 'All ages',
    capacity: 12,
    confirmedCount: confirmedCount,
    spots: spots,
    whiteScore: whiteScore,
    blackScore: blackScore,
    whiteAverageSr: whiteAverageSr,
    blackAverageSr: blackAverageSr,
    matchAverageSr: matchAverageSr,
    teamSrSpread: teamSrSpread,
    teamsAssignedAt: matchAverageSr == null
        ? null
        : startsAt.subtract(const Duration(days: 1)),
  );
}

const _homeClan = FixtureClan(
  id: 'mint',
  name: 'Mint Mavericks',
  tag: 'MINT',
  emblem: '⚽',
  themeId: 'pitch',
  patternId: 'solid',
  skillRating: 1600,
);

const _awayClan = FixtureClan(
  id: 'riffa',
  name: 'Riffa Raiders',
  tag: 'RIF',
  emblem: '🛡️',
  themeId: 'ocean',
  patternId: 'solid',
  skillRating: 1550,
);

class _FakeFixtureRepository implements FixtureRepository {
  const _FakeFixtureRepository(this.fixtures);

  final List<Fixture> fixtures;

  @override
  Future<List<Fixture>> listFixtures() async => fixtures;

  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOpenQueueRepository implements OpenQueueRepository {
  const _FakeOpenQueueRepository(this.games, {this.details = const {}});

  final List<OpenQueueGame> games;
  final Map<String, OpenQueueMatchDetail> details;

  @override
  Future<List<OpenQueueGame>> listGames() async => games
      .where((game) => game.status == 'OPEN' || game.status == 'FULL')
      .toList();

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => games;

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async {
    final detail = details[gameId];
    if (detail == null) throw StateError('Solo detail not found.');
    return detail;
  }

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
