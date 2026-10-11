import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/fixtures/fieldrush_fixture_page.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/fixtures/fixtures_screen.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 10, 10, 17);

void main() {
  testWidgets('overflowing date strip centers the selected matchday', (
    tester,
  ) async {
    await _pump(
      tester,
      _Repository(
        fixtures: [
          for (var day = 1; day <= 22; day++)
            _game('day-$day', start: DateTime.utc(2026, 10, day, 3)),
        ],
      ),
      width: 320,
    );
    final selected = tester.getRect(
      find.byKey(const ValueKey('fixtures-date-2026-10-10')),
    );
    final strip = tester.getRect(
      find.byKey(const ValueKey('fixtures-date-strip')),
    );
    expect(selected.center.dx, closeTo(strip.center.dx, .1));
  });
  testWidgets('short matchday row is centered and lobby crest retains stars', (
    tester,
  ) async {
    await _pump(
      tester,
      _Repository(
        upcoming: [
          _game('one', average: 1700),
          _game('two', start: DateTime.utc(2026, 10, 14, 3)),
        ],
      ),
    );
    final first = tester.getRect(
      find.byKey(const ValueKey('fixtures-date-2026-10-10')),
    );
    final last = tester.getRect(
      find.byKey(const ValueKey('fixtures-date-2026-10-13')),
    );
    final strip = tester.getRect(
      find.byKey(const ValueKey('fixtures-date-strip')),
    );
    expect((first.left + last.right) / 2, closeTo(strip.center.dx, .01));
    final crest = tester.widget<FieldrushDivisionShield>(
      find.byType(FieldrushDivisionShield).first,
    );
    expect(crest.division, 1);
    expect(crest.mini, isFalse);
    expect(crest.size, 20);
  });
  testWidgets(
    'production FixturesScreen exposes Fieldrush, not legacy clan scheduling',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final repository = _Repository(upcoming: [_game('production')]);
      final legacy = _UnusedFixtureRepository();
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FixturesScreen(
              fixtureRepository: legacy,
              openQueueRepository: repository,
              now: _now,
              onOpenGame: (_) async {
                opened++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushFixturePage), findsOneWidget);
      expect(find.byType(LegacyFixturesScreen), findsNothing);
      expect(find.text('Phoenix, AZ'), findsOneWidget);
      expect(find.text('Clan games are coming soon'), findsOneWidget);
      expect(find.text('Match Calendar'), findsNothing);
      expect(legacy.calls, 0);
      await tester.tap(
        find.byKey(const ValueKey('fixture-game-action-production')),
      );
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(repository.bookCalls, 0);
    },
  );
  testWidgets(
    'calendar uses only real Phoenix USD dates and Phoenix wall clock',
    (tester) async {
      final repository = _Repository(
        fixtures: [
          _game(
            'history',
            start: DateTime.utc(2026, 10, 8, 3),
            status: 'FINAL',
          ),
          _game('later', start: DateTime.utc(2026, 10, 14, 3)),
          _game(
            'foreign',
            start: DateTime.utc(2026, 10, 11, 3),
            timezone: 'Asia/Bahrain',
            currency: 'BHD',
          ),
          _game(
            'wrong-currency',
            start: DateTime.utc(2026, 10, 11, 3),
            currency: 'BHD',
          ),
        ],
        upcoming: [_game('next', start: DateTime.utc(2026, 10, 11, 3))],
      );
      await _pump(tester, repository);
      expect(find.text('Phoenix, AZ'), findsOneWidget);
      expect(repository.marketRequested, 'America/Phoenix');
      expect(repository.listGamesCalls, 0);
      expect(find.byKey(const ValueKey('solo-fixture-next')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fixtures-date-2026-10-07')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('fixtures-date-2026-10-10')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('fixtures-date-2026-10-13')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('fixtures-date-2026-10-11')),
        findsNothing,
      );
      expect(find.textContaining('8:00 PM'), findsOneWidget);
      expect(find.text('Sat, Oct 10'), findsOneWidget);
      expect(find.textContaining('BHD'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('fixtures-next-day')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('solo-fixture-later')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fixtures-date-2026-10-07')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('solo-fixture-history')),
        findsOneWidget,
      );
      expect(find.text('PAST MATCHDAY'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty fixtures invent neither dates nor scheduled games', (
    tester,
  ) async {
    await _pump(tester, _Repository());
    expect(find.text('No games yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('fixtures-next-day')), findsNothing);
    expect(find.text('Clan games are coming soon'), findsOneWidget);
    expect(find.text('COMING SOON'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fixtures-city-picker')));
    await tester.pumpAndSettle();
    expect(find.text('Phoenix, AZ'), findsNWidgets(2));
    expect(find.textContaining('Austin'), findsNothing);
    expect(find.textContaining('Tuesday'), findsNothing);
  });

  testWidgets(
    'error and retry are explicit and do not masquerade as no games',
    (tester) async {
      final repository = _Repository()..fail = true;
      await _pump(tester, repository);
      expect(find.text('Fixtures unavailable'), findsOneWidget);
      expect(find.text('No games yet'), findsNothing);
      repository.fail = false;
      repository.upcoming = [_game('retry')];
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('solo-fixture-retry')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('whole card and Join game both open that game without booking', (
    tester,
  ) async {
    final repository = _Repository(upcoming: [_game('exact')]);
    final opened = <String>[];
    var played = 0;
    await _pump(
      tester,
      repository,
      onOpen: (game) async => opened.add(game.id),
      onPlay: (_) async => played++,
    );
    await tester.tap(find.byKey(const ValueKey('solo-fixture-exact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fixture-game-action-exact')));
    await tester.pumpAndSettle();
    expect(opened, ['exact', 'exact']);
    expect(played, 0);
    expect(repository.bookCalls, 0);
  });

  testWidgets(
    'Play opens mode sheet and Solo starts the flow without booking',
    (tester) async {
      final repository = _Repository();
      var called = 0;
      OpenQueueGame? selected;
      await _pump(
        tester,
        repository,
        onPlay: (game) async {
          called++;
          selected = game;
        },
      );
      await tester.tap(find.byKey(const ValueKey('fixtures-play-action')));
      await tester.pumpAndSettle();
      expect(find.text('Start a game'), findsOneWidget);
      expect(find.text('Solo game'), findsOneWidget);
      expect(find.text('Clan game'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('play-clan-choice')));
      await tester.pumpAndSettle();
      expect(called, 0);
      expect(find.text('Start a game'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('play-solo-choice')));
      await tester.pumpAndSettle();
      expect(called, 1);
      expect(selected, isNull);
      expect(repository.bookCalls, 0);
    },
  );

  testWidgets('confirmed bookings missing from feed still show View game', (
    tester,
  ) async {
    final game = _game('booked');
    final repository = _Repository(bookings: [_booking(game)]);
    await _pump(tester, repository);
    expect(find.byKey(const ValueKey('solo-fixture-booked')), findsOneWidget);
    expect(find.text('View game'), findsOneWidget);
    expect(find.text('Join game'), findsNothing);
    expect(find.textContaining('YOU’RE IN'), findsOneWidget);
  });

  testWidgets(
    'past-only data defaults to latest real fixture and shows actual result',
    (tester) async {
      await _pump(
        tester,
        _Repository(
          fixtures: [
            _game(
              'old',
              start: DateTime.utc(2026, 9, 30, 3),
              status: 'FINAL',
              white: 2,
              black: 1,
            ),
            _game(
              'recent',
              start: DateTime.utc(2026, 10, 7, 3),
              status: 'FINAL',
              white: 4,
              black: 2,
              average: 1230,
            ),
          ],
        ),
      );
      expect(find.byKey(const ValueKey('solo-fixture-recent')), findsOneWidget);
      expect(find.text('White'), findsOneWidget);
      expect(find.text('Black'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.textContaining('1230 SR'), findsOneWidget);
      expect(find.text('PLAYED'), findsOneWidget);
      expect(find.text('Join game'), findsNothing);
    },
  );

  testWidgets('pending operational result never displays recorded scores', (
    tester,
  ) async {
    await _pump(
      tester,
      _Repository(
        fixtures: [
          _game(
            'pending',
            status: 'FINAL',
            white: 6,
            black: 1,
            operational: MatchOperationalState.underReview,
          ),
        ],
      ),
    );
    expect(find.text('UNDER REVIEW'), findsOneWidget);
    expect(find.text('White'), findsNothing);
    expect(find.text('Join game'), findsNothing);
    expect(find.textContaining('Admin review'), findsOneWidget);
  });

  testWidgets('activation refresh preserves selected date', (tester) async {
    final repository = _Repository(
      fixtures: [
        _game('first'),
        _game('second', start: DateTime.utc(2026, 10, 14, 3)),
      ],
    );
    await _pump(tester, repository);
    await tester.tap(find.byKey(const ValueKey('fixtures-next-day')));
    await tester.pumpAndSettle();
    final calls = repository.fixtureCalls;
    await _pump(tester, repository, activation: 1);
    expect(repository.fixtureCalls, calls + 1);
    expect(find.byKey(const ValueKey('solo-fixture-second')), findsOneWidget);
  });

  testWidgets('compact width and enlarged text do not overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      _Repository(upcoming: [_game('narrow')]),
      width: 320,
      scale: 1.3,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('fixtures-play-action')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('optional native-render fixture preview', (tester) async {
    final path = Platform.environment['FIELDRUSH_FIXTURES_SCREENSHOT'];
    if (path == null) return;
    await tester.runAsync(() async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        await (FontLoader(
          font,
        )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    final boundaryKey = GlobalKey();
    await _pump(
      tester,
      _Repository(
        fixtures: [
          _game(
            'past',
            start: DateTime.utc(2026, 10, 7, 3),
            status: 'FINAL',
            white: 4,
            black: 2,
          ),
          _game('next', average: 1230),
          _game('later', start: DateTime.utc(2026, 10, 14, 3)),
          _game('later2', start: DateTime.utc(2026, 10, 17, 3)),
          _game('later3', start: DateTime.utc(2026, 10, 21, 3)),
          _game('later4', start: DateTime.utc(2026, 10, 24, 3)),
        ],
      ),
      boundaryKey: boundaryKey,
      width: 430,
    );
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  });
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  Future<void> Function(OpenQueueGame)? onOpen,
  Future<void> Function(OpenQueueGame?)? onPlay,
  int activation = 0,
  double width = 390,
  double scale = 1,
  GlobalKey? boundaryKey,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: RepaintBoundary(
        key: boundaryKey,
        child: Scaffold(
          body: FieldrushFixturePage(
            repository: repository,
            onOpenGame: onOpen,
            onPlay: onPlay,
            now: _now,
            activationTick: activation,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OpenQueueGame _game(
  String id, {
  DateTime? start,
  String status = 'OPEN',
  String timezone = 'America/Phoenix',
  String currency = 'USD',
  int? white,
  int? black,
  int? average,
  MatchOperationalState operational = MatchOperationalState.normal,
}) {
  final at = start ?? DateTime.utc(2026, 10, 11, 3);
  return OpenQueueGame(
    id: id,
    status: status,
    venue: 'Reach 11 Fields',
    startsAt: at,
    endsAt: at.add(const Duration(hours: 1)),
    timezone: timezone,
    priceFils: 13000,
    currency: currency,
    ageLabel: '18+',
    capacity: 14,
    confirmedCount: 8,
    spots: const {
      OpenQueueRole.goalkeeper: 1,
      OpenQueueRole.defender: 3,
      OpenQueueRole.attacker: 2,
    },
    whiteScore: white,
    blackScore: black,
    matchAverageSr: average,
    operationalState: operational,
  );
}

OpenQueueBooking _booking(OpenQueueGame game) => OpenQueueBooking(
  id: 'booking-${game.id}',
  gameId: game.id,
  profileId: 'me',
  role: OpenQueueRole.defender,
  status: 'CONFIRMED',
  amountPaidFils: 13000,
  bookedAt: _now,
  game: game,
);

class _Repository implements OpenQueueRepository, OpenQueueMarketRepository {
  _Repository({
    this.fixtures = const [],
    this.upcoming = const [],
    this.bookings = const [],
  });
  List<OpenQueueGame> fixtures;
  List<OpenQueueGame> upcoming;
  List<OpenQueueBooking> bookings;
  bool fail = false;
  int bookCalls = 0;
  int fixtureCalls = 0;
  int listGamesCalls = 0;
  String? marketRequested;
  @override
  Future<List<OpenQueueGame>> listFixtureGames() async {
    fixtureCalls++;
    if (fail) throw StateError('offline');
    return fixtures;
  }

  @override
  Future<List<OpenQueueGame>> listMarketGames(String timezone) async {
    marketRequested = timezone;
    return upcoming;
  }

  @override
  Future<List<OpenQueueGame>> listGames() async {
    listGamesCalls++;
    return upcoming;
  }

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => bookings;
  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async {
    bookCalls++;
    throw StateError('Fixtures must never directly book');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedFixtureRepository implements FixtureRepository {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Launch fixtures must not query legacy clan data');
  }
}
