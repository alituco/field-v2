import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/fixtures/fieldrush_fixture_page.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/fixtures/fixtures_screen.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/markets/fieldrush_city.dart';
import 'package:field/src/markets/fieldrush_city_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 10, 10, 17);

void main() {
  testWidgets('small games show their minimum separately from maximum places', (
    tester,
  ) async {
    await _pump(
      tester,
      _Repository(
        fixtures: [
          _game(
            'small',
            confirmedCount: 2,
            minimumPlayers: 2,
            participationRulesVersion: 's0-configurable-v1',
          ),
        ],
      ),
      width: 320,
      scale: 1.3,
    );
    expect(
      find.text('Minimum reached · 2 minimum · 14 maximum'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('solo-fixture-small')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'preferred city scopes discovery and browsing never changes preference',
    (tester) async {
      final repository = _CityGamesRepository(
        upcoming: [
          _game('phoenix-game', marketCityId: 'phoenix'),
          _game(
            'new-york-game',
            marketCityId: 'new-york',
            timezone: 'America/New_York',
          ),
          _game(
            'same-zone-wrong-city',
            marketCityId: 'boston',
            timezone: 'America/New_York',
          ),
        ],
      );
      final cities = _CitiesRepository();
      await _pump(tester, repository, cityRepository: cities);
      expect(repository.requestedCity, 'new-york');
      expect(
        find.byKey(const ValueKey('solo-fixture-new-york-game')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('solo-fixture-same-zone-wrong-city')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('solo-fixture-phoenix-game')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('fixtures-city-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phoenix, AZ'));
      await tester.pumpAndSettle();
      expect(repository.requestedCity, 'phoenix');
      expect(
        find.byKey(const ValueKey('solo-fixture-phoenix-game')),
        findsOneWidget,
      );
      expect(cities.savedCities, isEmpty);
      fieldrushCityRevision.value++;
      await tester.pumpAndSettle();
      expect(repository.requestedCity, 'new-york');
      expect(tester.takeException(), isNull);
    },
  );

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

  for (final width in [375.0, 390.0, 430.0]) {
    testWidgets('matchday chips have a five-to-six day density at $width', (
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
        width: width,
      );
      final chip = tester.getRect(
        find.byKey(const ValueKey('fixtures-date-2026-10-10')),
      );
      final strip = tester.getRect(
        find.byKey(const ValueKey('fixtures-date-strip')),
      );
      expect(chip.width, 58);
      expect(chip.height, 70);
      expect((strip.width / (chip.width + 7)).ceil(), inInclusiveRange(5, 6));
      expect(chip.center.dx, closeTo(strip.center.dx, .1));
      expect(find.textContaining('· CLAN'), findsNothing);
      expect(find.text('Clan games are coming soon'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('previous and next clamp long-strip dates at the natural edges', (
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
    );
    final previous = find.byKey(const ValueKey('fixtures-previous-day'));
    final next = find.byKey(const ValueKey('fixtures-next-day'));
    for (var index = 0; index < 10; index++) {
      await tester.tap(previous);
      await tester.pumpAndSettle();
    }
    final strip = tester.getRect(
      find.byKey(const ValueKey('fixtures-date-strip')),
    );
    expect(tester.widget<IconButton>(previous).onPressed, isNull);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('fixtures-date-2026-09-30')))
          .left,
      closeTo(strip.left, .1),
    );
    for (var index = 0; index < 21; index++) {
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    expect(tester.widget<IconButton>(next).onPressed, isNull);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('fixtures-date-2026-10-21')))
          .right,
      closeTo(strip.right - 7, .1),
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 430.0]) {
    testWidgets('first selected date starts at the left at $width', (
      tester,
    ) async {
      await _pump(
        tester,
        _Repository(
          upcoming: [
            for (var day = 11; day <= 22; day++)
              _game('day-$day', start: DateTime.utc(2026, 10, day, 3)),
          ],
        ),
        width: width,
      );
      final stripFinder = find.byKey(const ValueKey('fixtures-date-strip'));
      final strip = tester.getRect(stripFinder);
      final first = tester.getRect(
        find.byKey(const ValueKey('fixtures-date-2026-10-10')),
      );
      expect(tester.widget<ListView>(stripFinder).controller!.offset, 0);
      expect(first.left, closeTo(strip.left, .1));
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('fixtures-previous-day')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const ValueKey('fixtures-date-2026-10-11')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'horizontal browsing and tapping a date preserve centered selection',
    (tester) async {
      final repository = _Repository(
        fixtures: [
          for (var day = 1; day <= 22; day++)
            _game('day-$day', start: DateTime.utc(2026, 10, day, 3)),
        ],
      );
      await _pump(tester, repository);
      final stripFinder = find.byKey(const ValueKey('fixtures-date-strip'));
      final controller = tester.widget<ListView>(stripFinder).controller!;
      final offset = controller.offset;
      await tester.drag(stripFinder, const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(offset));
      await tester.tap(find.byKey(const ValueKey('fixtures-date-2026-10-13')));
      await tester.pumpAndSettle();
      expect(find.text('Tue, Oct 13'), findsOneWidget);
      expect(find.byKey(const ValueKey('solo-fixture-day-14')), findsOneWidget);
      expect(
        tester
            .getCenter(find.byKey(const ValueKey('fixtures-date-2026-10-13')))
            .dx,
        closeTo(tester.getRect(stripFinder).center.dx, .1),
      );
      expect(repository.bookCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resizing and enlarged text re-center the same selected matchday',
    (tester) async {
      final repository = _Repository(
        fixtures: [
          for (var day = 1; day <= 22; day++)
            _game('day-$day', start: DateTime.utc(2026, 10, day, 3)),
        ],
      );
      await _pump(tester, repository);
      await tester.tap(find.byKey(const ValueKey('fixtures-next-day')));
      await tester.pumpAndSettle();
      for (final (width, scale) in [(430.0, 1.0), (320.0, 1.3)]) {
        await _pump(tester, repository, width: width, scale: scale);
        final chip = tester.getRect(
          find.byKey(const ValueKey('fixtures-date-2026-10-11')),
        );
        final strip = tester.getRect(
          find.byKey(const ValueKey('fixtures-date-strip')),
        );
        expect(find.text('Sun, Oct 11'), findsOneWidget);
        expect(chip.center.dx, closeTo(strip.center.dx, .1));
        expect(chip.width, closeTo(58 * scale, .1));
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'short matchday row is centered and division artwork retains stars',
    (tester) async {
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
    },
  );

  testWidgets(
    'fixture admission range shows all five divisions without ratings',
    (tester) async {
      final repository = _Repository(upcoming: [_game('all-divisions')]);
      await _pump(tester, repository);
      final card = find.byKey(const ValueKey('solo-fixture-all-divisions'));
      final range = find.descendant(
        of: card,
        matching: find.byType(FieldrushGameDivisionRange),
      );
      expect(range, findsOneWidget);
      expect(
        find.descendant(of: range, matching: find.text('DIV 1–5')),
        findsOneWidget,
      );
      final shields = tester.widgetList<FieldrushDivisionShield>(
        find.descendant(
          of: range,
          matching: find.byType(FieldrushDivisionShield),
        ),
      );
      expect(shields.map((shield) => shield.division), [1, 2, 3, 4, 5]);
      expect(
        shields.every((shield) => !shield.mini && shield.size == 20),
        isTrue,
      );
      expect(
        tester.getRect(range).right,
        closeTo(tester.getRect(card).right - 18, .1),
      );
      expect(repository.bookCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'each fixture keeps its configured band separate from lobby rating',
    (tester) async {
      final repository = _Repository(
        upcoming: [
          _game(
            'middle-band',
            highestDivision: 2,
            lowestDivision: 4,
            average: 1700,
          ),
          _game(
            'single-division',
            highestDivision: 3,
            lowestDivision: 3,
            average: 1700,
          ),
        ],
      );
      await _pump(tester, repository);
      for (final (id, label, divisions) in [
        ('middle-band', 'DIV 2–4', [2, 3, 4]),
        ('single-division', 'DIV 3', [3]),
      ]) {
        final card = find.byKey(ValueKey('solo-fixture-$id'));
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        final range = find.descendant(
          of: card,
          matching: find.byType(FieldrushGameDivisionRange),
        );
        expect(range, findsOneWidget);
        expect(
          find.descendant(of: range, matching: find.text(label)),
          findsOneWidget,
        );
        expect(
          tester
              .widgetList<FieldrushDivisionShield>(
                find.descendant(
                  of: range,
                  matching: find.byType(FieldrushDivisionShield),
                ),
              )
              .map((shield) => shield.division),
          divisions,
        );
      }
      expect(repository.bookCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
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
      expect(find.text('Clan games are coming soon'), findsNothing);
      expect(find.textContaining('· CLAN'), findsNothing);
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
      expect(find.textContaining('Check-in 7:30 PM'), findsOneWidget);
      expect(find.textContaining('8:00 PM'), findsNothing);
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

  testWidgets('midnight kickoff groups upcoming arrival on the previous day', (
    tester,
  ) async {
    final midnight = DateTime.utc(2026, 10, 11, 7, 10);
    final repository = _Repository(
      fixtures: [
        _game('upcoming-midnight', start: midnight),
        _game('final-midnight', start: midnight, status: 'FINAL'),
      ],
    );
    await _pump(tester, repository);
    expect(
      find.byKey(const ValueKey('solo-fixture-upcoming-midnight')),
      findsOneWidget,
    );
    expect(find.textContaining('Check-in 11:40 PM'), findsOneWidget);
    expect(find.text('Sat, Oct 10'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('solo-fixture-final-midnight')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('fixtures-date-2026-10-11')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('solo-fixture-final-midnight')),
      findsOneWidget,
    );
    expect(find.textContaining('12:10 AM'), findsOneWidget);
    expect(find.textContaining('Check-in '), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty fixtures invent neither dates nor scheduled games', (
    tester,
  ) async {
    await _pump(tester, _Repository());
    expect(find.text('No games yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('fixtures-next-day')), findsNothing);
    expect(find.text('Clan games are coming soon'), findsNothing);
    expect(find.text('COMING SOON'), findsNothing);
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

  testWidgets(
    'fixture refresh keeps loaded games visible until fresh data arrives',
    (tester) async {
      final repository = _Repository(fixtures: [_game('cached')]);
      await _pump(tester, repository);
      final response = Completer<List<OpenQueueGame>>();
      repository.fixtureResponse = response;
      await _pump(tester, repository, activation: 1);
      expect(find.byKey(const ValueKey('solo-fixture-cached')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fixtures-loading-skeleton')),
        findsNothing,
      );
      response.complete([_game('fresh')]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('solo-fixture-fresh')), findsOneWidget);
      expect(find.byKey(const ValueKey('solo-fixture-cached')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a pending bookings read does not hide a live fixture', (
    tester,
  ) async {
    final bookings = Completer<List<OpenQueueBooking>>();
    final repository = _Repository(fixtures: [_game('live', status: 'LIVE')])
      ..bookingResponse = bookings;
    await _pump(tester, repository);
    expect(find.byKey(const ValueKey('solo-fixture-live')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixtures-loading-skeleton')),
      findsNothing,
    );

    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('solo-fixture-live')), findsOneWidget);
    expect(find.textContaining('Could not refresh bookings'), findsOneWidget);
    expect(find.text('No games yet'), findsNothing);

    repository.bookingResponse = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fixtures-refresh-error')), findsNothing);
    bookings.complete([]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stalled city lookup falls back with a retryable notice', (
    tester,
  ) async {
    final cities = _PendingCitiesRepository();
    await _pump(
      tester,
      _Repository(fixtures: [_game('live', status: 'LIVE')]),
      cityRepository: cities,
    );
    expect(
      find.byKey(const ValueKey('fixtures-loading-skeleton')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('solo-fixture-live')), findsOneWidget);
    expect(find.text('Phoenix, AZ'), findsOneWidget);
    expect(find.textContaining('your city'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixtures-loading-skeleton')),
      findsNothing,
    );

    // A timed-out response must not change the city after the fallback renders.
    cities.preferred.complete(_CitiesRepository.newYork);
    cities.options.complete([_CitiesRepository.newYork]);
    await tester.pumpAndSettle();
    expect(find.text('Phoenix, AZ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('city options do not delay the preferred city fixtures', (
    tester,
  ) async {
    final cities = _PendingCitiesRepository()
      ..preferred.complete(_CitiesRepository.newYork);
    await _pump(
      tester,
      _Repository(
        fixtures: [
          _game(
            'new-york-live',
            status: 'LIVE',
            marketCityId: 'new-york',
            timezone: 'America/New_York',
          ),
        ],
      ),
      cityRepository: cities,
    );
    expect(
      find.byKey(const ValueKey('solo-fixture-new-york-live')),
      findsOneWidget,
    );
    expect(find.text('New York, NY'), findsOneWidget);
    cities.options.complete([FieldrushCity.phoenix, _CitiesRepository.newYork]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed feed and pending sibling keep a successful game visible',
    (tester) async {
      final bookings = Completer<List<OpenQueueBooking>>();
      final repository = _Repository(fixtures: [_game('live', status: 'LIVE')])
        ..failDiscovery = true
        ..bookingResponse = bookings;
      await _pump(tester, repository);
      expect(find.byKey(const ValueKey('solo-fixture-live')), findsOneWidget);
      expect(
        find.textContaining('Could not refresh available games'),
        findsOneWidget,
      );
      expect(find.text('Fixtures unavailable'), findsNothing);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('solo-fixture-live')), findsOneWidget);
      expect(find.textContaining('bookings'), findsOneWidget);
      expect(find.text('No games yet'), findsNothing);
      bookings.complete([]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed refresh preserves its cached rows and offers retry', (
    tester,
  ) async {
    final repository = _Repository(fixtures: [_game('cached', status: 'LIVE')]);
    await _pump(tester, repository);
    repository.fail = true;
    await _pump(tester, repository, activation: 1);
    expect(find.byKey(const ValueKey('solo-fixture-cached')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixtures-refresh-error')),
      findsOneWidget,
    );
    expect(find.text('Fixtures unavailable'), findsNothing);
    repository.fail = false;
    repository.fixtures = [_game('fresh', status: 'LIVE')];
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('solo-fixture-fresh')), findsOneWidget);
    expect(find.byKey(const ValueKey('solo-fixture-cached')), findsNothing);
    expect(find.byKey(const ValueKey('fixtures-refresh-error')), findsNothing);
  });

  for (final stalled in [false, true]) {
    testWidgets(
      'fresh discovery overrides ${stalled ? 'pending' : 'failed'} cached fixture data',
      (tester) async {
        final repository = _Repository(fixtures: [_game('same-game')]);
        await _pump(tester, repository);
        expect(find.text('Join game'), findsOneWidget);
        final pending = Completer<List<OpenQueueGame>>();
        repository.fail = !stalled;
        repository.fixtureResponse = stalled ? pending : null;
        repository.upcoming = [
          _game('same-game', status: 'FULL', confirmedCount: 14),
        ];
        await _pump(tester, repository, activation: 1);
        expect(
          find.byKey(const ValueKey('solo-fixture-same-game')),
          findsOneWidget,
        );
        expect(find.text('0 SPOTS LEFT'), findsOneWidget);
        expect(find.text('Join game'), findsNothing);
        if (stalled) {
          pending.complete([
            _game('same-game', status: 'LIVE', white: 2, black: 1),
          ]);
          await tester.pumpAndSettle();
          expect(find.text('LIVE'), findsWidgets);
          expect(find.text('White'), findsOneWidget);
          expect(find.text('0 SPOTS LEFT'), findsNothing);
        } else {
          // Starting another retry must not briefly restore the older OPEN
          // fixture while the latest successful discovery remains cached.
          final retry = Completer<List<OpenQueueGame>>();
          repository.discoveryResponse = retry;
          await _pump(tester, repository, activation: 2);
          expect(find.text('0 SPOTS LEFT'), findsOneWidget);
          expect(find.text('Join game'), findsNothing);
          retry.complete(repository.upcoming);
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('superseded pending reads cannot overwrite a newer refresh', (
    tester,
  ) async {
    final oldFixtures = Completer<List<OpenQueueGame>>();
    final repository = _Repository()..fixtureResponse = oldFixtures;
    await _pump(tester, repository);
    repository.fixtureResponse = null;
    repository.fixtures = [_game('current', status: 'LIVE')];
    await _pump(tester, repository, activation: 1);
    expect(find.byKey(const ValueKey('solo-fixture-current')), findsOneWidget);
    oldFixtures.complete([_game('stale')]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('solo-fixture-current')), findsOneWidget);
    expect(find.byKey(const ValueKey('solo-fixture-stale')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing the repository clears cached games and bookings', (
    tester,
  ) async {
    final first = _Repository(bookings: [_booking(_game('old-player'))]);
    await _pump(tester, first);
    expect(
      find.byKey(const ValueKey('solo-fixture-old-player')),
      findsOneWidget,
    );
    final bookings = Completer<List<OpenQueueBooking>>();
    final replacement = _Repository()
      ..fail = true
      ..bookingResponse = bookings;
    await _pump(tester, replacement);
    expect(find.byKey(const ValueKey('solo-fixture-old-player')), findsNothing);
    expect(
      find.byKey(const ValueKey('fixtures-loading-skeleton')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('solo-fixture-old-player')), findsNothing);
    expect(find.text('Fixtures unavailable'), findsOneWidget);
    expect(find.text('No games yet'), findsNothing);
    bookings.complete([]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'city selection immediately filters cached rows during a stalled refresh',
    (tester) async {
      final repository = _CityGamesRepository(
        fixtures: [
          _game('phoenix-live', status: 'LIVE', marketCityId: 'phoenix'),
          _game(
            'new-york-live',
            status: 'LIVE',
            marketCityId: 'new-york',
            timezone: 'America/New_York',
          ),
        ],
      );
      final cities = _CitiesRepository();
      await _pump(tester, repository, cityRepository: cities);
      expect(
        find.byKey(const ValueKey('solo-fixture-new-york-live')),
        findsOneWidget,
      );
      final fixtures = Completer<List<OpenQueueGame>>();
      final discovery = Completer<List<OpenQueueGame>>();
      final bookings = Completer<List<OpenQueueBooking>>();
      repository.fixtureResponse = fixtures;
      repository.discoveryResponse = discovery;
      repository.bookingResponse = bookings;
      await tester.tap(find.byKey(const ValueKey('fixtures-city-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phoenix, AZ'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('solo-fixture-phoenix-live')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('solo-fixture-new-york-live')),
        findsNothing,
      );
      expect(find.text('Phoenix, AZ'), findsOneWidget);
      fixtures.complete(repository.fixtures);
      discovery.complete([]);
      bookings.complete([]);
      await tester.pumpAndSettle();
      expect(cities.savedCities, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a date chosen while loading survives a later discovery response',
    (tester) async {
      final discovery = Completer<List<OpenQueueGame>>();
      final repository = _Repository(
        fixtures: [
          _game(
            'history',
            status: 'FINAL',
            start: DateTime.utc(2026, 10, 8, 3),
          ),
          _game('later', start: DateTime.utc(2026, 10, 14, 3)),
        ],
      )..discoveryResponse = discovery;
      await _pump(tester, repository);
      await tester.tap(find.byKey(const ValueKey('fixtures-date-2026-10-07')));
      await tester.pumpAndSettle();
      discovery.complete([_game('next')]);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('solo-fixture-history')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('solo-fixture-next')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact width and enlarged text do not overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      _Repository(upcoming: [_game('narrow')]),
      width: 320,
      scale: 1.3,
    );
    expect(find.text('DIV 1–5'), findsOneWidget);
    expect(find.byType(FieldrushGameDivisionRange), findsOneWidget);
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
  FieldrushCityRepository? cityRepository,
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
            cityRepository: cityRepository,
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
  String? marketCityId,
  int? white,
  int? black,
  int? average,
  int highestDivision = 1,
  int lowestDivision = 5,
  int confirmedCount = 8,
  int minimumPlayers = 10,
  String participationRulesVersion = 's0-standard-v1',
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
    marketCityId: marketCityId,
    priceFils: 13000,
    currency: currency,
    ageLabel: '18+',
    capacity: 14,
    confirmedCount: confirmedCount,
    minimumPlayers: minimumPlayers,
    participationRulesVersion: participationRulesVersion,
    spots: const {
      OpenQueueRole.goalkeeper: 1,
      OpenQueueRole.defender: 3,
      OpenQueueRole.attacker: 2,
    },
    whiteScore: white,
    blackScore: black,
    matchAverageSr: average,
    highestDivision: highestDivision,
    lowestDivision: lowestDivision,
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
  bool failDiscovery = false;
  int bookCalls = 0;
  int fixtureCalls = 0;
  int listGamesCalls = 0;
  String? marketRequested;
  Completer<List<OpenQueueGame>>? fixtureResponse;
  Completer<List<OpenQueueGame>>? discoveryResponse;
  Completer<List<OpenQueueBooking>>? bookingResponse;
  @override
  Future<List<OpenQueueGame>> listFixtureGames() async {
    fixtureCalls++;
    if (fail) throw StateError('offline');
    if (fixtureResponse != null) return fixtureResponse!.future;
    return fixtures;
  }

  @override
  Future<List<OpenQueueGame>> listMarketGames(String timezone) async {
    marketRequested = timezone;
    if (failDiscovery) throw StateError('offline');
    return discoveryResponse?.future ?? upcoming;
  }

  @override
  Future<List<OpenQueueGame>> listGames() async {
    listGamesCalls++;
    return upcoming;
  }

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async =>
      bookingResponse?.future ?? bookings;
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

class _CityGamesRepository extends _Repository
    implements OpenQueueCityRepository {
  _CityGamesRepository({super.fixtures, super.upcoming});
  String? requestedCity;
  @override
  Future<List<OpenQueueGame>> listCityGames(String cityId) async {
    requestedCity = cityId;
    // Return mixed rows deliberately to verify the defensive client filter too.
    return discoveryResponse?.future ?? upcoming;
  }
}

class _CitiesRepository implements FieldrushCityRepository {
  final savedCities = <String>[];
  static const newYork = FieldrushCity(
    id: 'new-york',
    displayName: 'New York',
    state: 'NY',
    countryCode: 'US',
    timezone: 'America/New_York',
  );
  @override
  Future<List<FieldrushCity>> listCities() async => [
    FieldrushCity.phoenix,
    newYork,
  ];
  @override
  Future<FieldrushCity> loadPreferredCity() async => newYork;
  @override
  Future<FieldrushCity> setPreferredCity(String id) async {
    savedCities.add(id);
    return id == 'new-york' ? newYork : FieldrushCity.phoenix;
  }
}

class _PendingCitiesRepository extends _CitiesRepository {
  final preferred = Completer<FieldrushCity>();
  final options = Completer<List<FieldrushCity>>();

  @override
  Future<FieldrushCity> loadPreferredCity() => preferred.future;

  @override
  Future<List<FieldrushCity>> listCities() => options.future;
}
