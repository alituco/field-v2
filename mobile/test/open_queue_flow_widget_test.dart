import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_games_screen.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/open_queue/open_queue_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('role selection follows the Concept formation and role order', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _FakeOpenQueueRepository(_games());

    await tester.pumpWidget(
      MaterialApp(home: OpenQueueScreen(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('open-queue-pitch'))),
      const Size(300, 400),
    );
    expect(find.text('Tap your main position'), findsOneWidget);
    expect(find.textContaining('games'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Attacker')).dy,
      lessThan(tester.getTopLeft(find.text('Defender')).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('main-position-grid'))).dy -
          tester.getBottomLeft(find.text('MAIN POSITION')).dy,
      lessThan(20),
    );

    await tester.tap(find.text('Attacker'));
    await tester.pumpAndSettle();

    expect(find.text('MAIN'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.text('Anywhere'), findsOneWidget);
    expect(find.text('See matching games'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Fixtures'), findsOneWidget);
    expect(find.text('Clans'), findsOneWidget);
    expect(find.text('Ranks'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
  });

  testWidgets('games screen separates the main role from faster backup games', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueGamesScreen(
          repository: _FakeOpenQueueRepository(_delayedMainGames()),
          mainRole: OpenQueueRole.attacker,
          backupRoles: const {OpenQueueRole.defender},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MAIN POSITION'), findsOneWidget);
    expect(find.text('BACKUP'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('FASTEST WAY TO PLAY'), findsOneWidget);
    expect(find.textContaining('Your next attacker option'), findsOneWidget);
    expect(find.text('Next Week Arena'), findsOneWidget);
    expect(find.text('BEST MATCHES FOR YOU'), findsOneWidget);
    expect(find.text('MORE GAMES YOU CAN JOIN'), findsOneWidget);
    expect(find.text('Using your backup positions'), findsOneWidget);
    expect(find.text('Join as Defender'), findsWidgets);
    expect(find.textContaining('waitlist', findRichText: true), findsNothing);
  });
}

List<OpenQueueGame> _delayedMainGames() {
  final base = DateTime.now().add(const Duration(days: 2));
  OpenQueueGame game({
    required String id,
    required int days,
    required String venue,
    required int confirmed,
    required Map<OpenQueueRole, int> spots,
  }) {
    final startsAt = DateTime(base.year, base.month, base.day + days, 18, 30);
    return OpenQueueGame(
      id: id,
      status: 'OPEN',
      venue: venue,
      startsAt: startsAt,
      endsAt: startsAt.add(const Duration(hours: 1)),
      timezone: 'Asia/Bahrain',
      priceFils: 3000,
      ageLabel: 'Ages 16–20',
      capacity: 12,
      confirmedCount: confirmed,
      spots: spots,
    );
  }

  const backupOnly = {
    OpenQueueRole.goalkeeper: 0,
    OpenQueueRole.defender: 2,
    OpenQueueRole.midfielder: 0,
    OpenQueueRole.attacker: 0,
  };
  const neither = {
    OpenQueueRole.goalkeeper: 1,
    OpenQueueRole.defender: 0,
    OpenQueueRole.midfielder: 1,
    OpenQueueRole.attacker: 0,
  };
  return [
    game(
      id: 'early-backup',
      days: 0,
      venue: 'Sooner Midfield',
      confirmed: 6,
      spots: backupOnly,
    ),
    for (var index = 1; index < 5; index++)
      game(
        id: 'unavailable-$index',
        days: index,
        venue: 'Other Arena $index',
        confirmed: 7,
        spots: neither,
      ),
    game(
      id: 'delayed-main',
      days: 7,
      venue: 'Next Week Arena',
      confirmed: 8,
      spots: const {
        OpenQueueRole.goalkeeper: 1,
        OpenQueueRole.defender: 0,
        OpenQueueRole.midfielder: 1,
        OpenQueueRole.attacker: 1,
      },
    ),
  ];
}

class _FakeOpenQueueRepository implements OpenQueueRepository {
  _FakeOpenQueueRepository(this.games);

  final List<OpenQueueGame> games;

  @override
  Future<List<OpenQueueGame>> listGames() async => games;

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => games;

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) =>
      throw UnimplementedError();

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async => null;

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) => throw UnimplementedError();

  @override
  Future<OpenQueueBooking> cancelBooking(String bookingId) =>
      throw UnimplementedError();

  @override
  Future<OpenQueueCancellationPreview> previewCancellation(String bookingId) =>
      throw UnimplementedError();
}

List<OpenQueueGame> _games() {
  final base = DateTime.now().add(const Duration(days: 1));
  OpenQueueGame game(
    String id,
    int hour,
    int confirmed,
    Map<OpenQueueRole, int> spots,
  ) {
    final startsAt = DateTime(base.year, base.month, base.day, hour, 30);
    return OpenQueueGame(
      id: id,
      status: confirmed == 12 ? 'FULL' : 'OPEN',
      venue: 'TFA, Saar',
      startsAt: startsAt,
      endsAt: startsAt.add(const Duration(hours: 1)),
      timezone: 'Asia/Bahrain',
      priceFils: 3000,
      ageLabel: 'Ages 16–20',
      capacity: 12,
      confirmedCount: confirmed,
      spots: spots,
    );
  }

  return [
    game('backup-needed', 18, 10, const {
      OpenQueueRole.goalkeeper: 1,
      OpenQueueRole.defender: 2,
      OpenQueueRole.midfielder: 1,
      OpenQueueRole.attacker: 0,
    }),
    game('backup-last', 19, 9, const {
      OpenQueueRole.goalkeeper: 1,
      OpenQueueRole.defender: 1,
      OpenQueueRole.midfielder: 1,
      OpenQueueRole.attacker: 0,
    }),
    game('main-last', 20, 8, const {
      OpenQueueRole.goalkeeper: 1,
      OpenQueueRole.defender: 0,
      OpenQueueRole.midfielder: 1,
      OpenQueueRole.attacker: 1,
    }),
    game('full', 21, 12, const {
      OpenQueueRole.goalkeeper: 0,
      OpenQueueRole.defender: 0,
      OpenQueueRole.midfielder: 0,
      OpenQueueRole.attacker: 0,
    }),
  ];
}
