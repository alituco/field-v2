import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_games_screen.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/open_queue/open_queue_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('new 14-player games offer only Keeper, Defender, and Attacker', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueScreen(
          repository: _FakeOpenQueueRepository([_fieldrushGame()]),
          initialMainRole: OpenQueueRole.attacker,
          initialBackupRoles: const {
            OpenQueueRole.midfielder,
            OpenQueueRole.defender,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('open-queue-main-role-mid')),
      findsNothing,
    );
    expect(find.text('MID'), findsNothing);
    expect(find.textContaining('Midfielder'), findsNothing);
    for (final role in ['gk', 'def', 'att']) {
      expect(
        find.byKey(ValueKey('open-queue-main-role-$role')),
        findsOneWidget,
      );
    }
    await tester.drag(find.byType(ListView), const Offset(0, -450));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anywhere'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('open-queue-see-matching-games')),
    );
    await tester.pumpAndSettle();
    final screen = tester.widget<OpenQueueGamesScreen>(
      find.byType(OpenQueueGamesScreen),
    );
    expect(screen.mainRole, OpenQueueRole.attacker);
    expect(screen.backupRoles, {
      OpenQueueRole.defender,
      OpenQueueRole.goalkeeper,
    });
  });

  testWidgets(
    'unsupported initial main role is cleared for new or empty feeds',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final games in <List<OpenQueueGame>>[
        [_fieldrushGame()],
        [],
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: OpenQueueScreen(
              repository: _FakeOpenQueueRepository(games),
              initialMainRole: OpenQueueRole.midfielder,
              initialBackupRoles: const {OpenQueueRole.midfielder},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('MID'), findsNothing);
        expect(find.textContaining('Midfielder'), findsNothing);
        expect(
          find.byKey(const ValueKey('open-queue-see-matching-games')),
          findsNothing,
        );
        expect(find.text('Tap your main position'), findsOneWidget);
        for (final role in ['gk', 'def', 'att']) {
          expect(
            find.byKey(ValueKey('open-queue-main-role-$role')),
            findsOneWidget,
          );
        }
      }
    },
  );

  testWidgets(
    'legacy 12-player games preserve midfield and initial selections',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: OpenQueueScreen(
            repository: _FakeOpenQueueRepository([
              _fieldrushGame(),
              ..._games(),
            ]),
            initialMainRole: OpenQueueRole.midfielder,
            initialBackupRoles: const {
              OpenQueueRole.midfielder,
              OpenQueueRole.defender,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('open-queue-main-role-mid')),
        findsOneWidget,
      );
      expect(
        find.text('MID'),
        findsNothing,
      ); // both pitch midfield nodes are selected.
      expect(find.text('MAIN'), findsNWidgets(2));
      await tester.tap(
        find.byKey(const ValueKey('open-queue-see-matching-games')),
      );
      await tester.pumpAndSettle();
      final screen = tester.widget<OpenQueueGamesScreen>(
        find.byType(OpenQueueGamesScreen),
      );
      expect(screen.mainRole, OpenQueueRole.midfielder);
      expect(screen.backupRoles, {OpenQueueRole.defender});
    },
  );

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
    expect(find.text('You'), findsOneWidget);
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

  testWidgets('one existing booking leaves a clear second-game slot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final games = _games();
    final booking = _bookingFor(games.first, id: 'booking-one');

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueScreen(
          repository: _FakeOpenQueueRepository(games, bookings: [booking]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('open-queue-one-of-two-booked')),
      findsOneWidget,
    );
    expect(find.text('1 OF 2 GAMES BOOKED'), findsOneWidget);
    expect(find.textContaining('One slot left'), findsNothing);
    expect(find.textContaining(booking.game.prominentDateLabel), findsNothing);
    expect(find.text('WHERE DO YOU PLAY?'), findsOneWidget);
  });

  testWidgets('two existing bookings replace the wizard with both games', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final games = _games();
    final first = _bookingFor(games.first, id: 'booking-one');
    final second = _bookingFor(
      games[2],
      id: 'booking-two',
      role: OpenQueueRole.attacker,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueScreen(
          repository: _FakeOpenQueueRepository(
            games,
            bookings: [second, first],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('open-queue-two-game-limit')),
      findsOneWidget,
    );
    expect(find.text('2 / 2 SOLO GAME LIMIT'), findsOneWidget);
    expect(find.text('You’re already booked for two games'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-queue-limit-booking-booking-one')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('open-queue-limit-booking-booking-two')),
      findsOneWidget,
    );
    expect(find.text('WHERE DO YOU PLAY?'), findsNothing);
    expect(find.text('See matching games'), findsNothing);
  });

  testWidgets('matching games hide the game already booked', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final games = _delayedMainGames();
    final booked = _bookingFor(
      games.last,
      id: 'booking-delayed-main',
      role: OpenQueueRole.attacker,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueGamesScreen(
          repository: _FakeOpenQueueRepository(games, bookings: [booked]),
          mainRole: OpenQueueRole.attacker,
          backupRoles: const {OpenQueueRole.defender},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Next Week Arena'), findsNothing);
    expect(find.text('Sooner Midfield'), findsWidgets);
    expect(find.textContaining('Your next attacker option'), findsNothing);
  });

  testWidgets(
    'an urgent main-role opening is not hidden by four earlier games',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final base = DateTime.now().add(const Duration(days: 2));
      final games = [
        for (var index = 0; index < 4; index++)
          _roleGame(
            id: 'ordinary-$index',
            venue: 'Ordinary Arena $index',
            startsAt: base.add(Duration(days: index)),
            confirmed: 6,
            defenderSpots: 2,
          ),
        _roleGame(
          id: 'urgent-defender',
          venue: 'One Defender Needed',
          startsAt: base.add(const Duration(days: 7)),
          confirmed: 11,
          defenderSpots: 1,
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: OpenQueueGamesScreen(
            repository: _FakeOpenQueueRepository(games),
            mainRole: OpenQueueRole.defender,
            backupRoles: const {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey('open-queue-join-urgent-defender-def'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(find.text('Ordinary Arena 3', skipOffstage: false), findsNothing);
    },
  );
}

OpenQueueGame _fieldrushGame() {
  final startsAt = DateTime.now().add(const Duration(days: 2));
  return OpenQueueGame(
    id: 'fieldrush',
    status: 'OPEN',
    venue: 'Reach 11 Fields',
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'America/Phoenix',
    currency: 'USD',
    priceFils: 13000,
    ageLabel: 'All ages',
    capacity: 14,
    confirmedCount: 8,
    spots: const {
      OpenQueueRole.goalkeeper: 1,
      OpenQueueRole.defender: 3,
      OpenQueueRole.attacker: 2,
    },
  );
}

OpenQueueGame _roleGame({
  required String id,
  required String venue,
  required DateTime startsAt,
  required int confirmed,
  required int defenderSpots,
}) {
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
    spots: {
      OpenQueueRole.goalkeeper: 0,
      OpenQueueRole.defender: defenderSpots,
      OpenQueueRole.midfielder: 0,
      OpenQueueRole.attacker: 0,
    },
  );
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
  _FakeOpenQueueRepository(this.games, {this.bookings = const []});

  final List<OpenQueueGame> games;
  final List<OpenQueueBooking> bookings;

  @override
  Future<List<OpenQueueGame>> listGames() async => games;

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => games;

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) =>
      throw UnimplementedError();

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async {
    final upcoming = await getMyUpcomingBookings();
    return upcoming.isEmpty ? null : upcoming.first;
  }

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async {
    return [
      ...bookings,
    ]..sort((left, right) => left.game.startsAt.compareTo(right.game.startsAt));
  }

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

OpenQueueBooking _bookingFor(
  OpenQueueGame game, {
  required String id,
  OpenQueueRole role = OpenQueueRole.defender,
}) {
  return OpenQueueBooking(
    id: id,
    gameId: game.id,
    profileId: 'profile-1',
    role: role,
    status: 'CONFIRMED',
    amountPaidFils: game.priceFils,
    bookedAt: DateTime.now(),
    game: game,
  );
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
