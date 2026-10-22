import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/clans/clan.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/home/field_bottom_nav.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/ranking/player_rating_visibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('division shield star counts follow the HTML, including placement', () {
    for (var division = 1; division <= 5; division++) {
      expect(
        FieldrushDivisionShieldPainter(division: division).starCount,
        5 - division,
      );
      expect(
        FieldrushDivisionShieldPainter(
          division: division,
          placement: true,
        ).starCount,
        0,
      );
    }
    expect(
      const FieldrushDivisionShieldPainter(division: 1, mini: true).starCount,
      0,
    );
  });
  final now = DateTime.utc(2099, 6, 1);

  testWidgets('revealed home SR stays visible in a new season', (tester) async {
    await _pump(
      tester,
      FieldrushHomeRating(
        profile: _profile(
          matches: 0,
          visibility: const PlayerRatingVisibility(
            lifetimeCountedMatches: 2,
            seasonCountedMatches: 0,
            ratingVisible: true,
            provisional: true,
            placementMatchesRemaining: 0,
          ),
        ),
        onTap: () {},
      ),
    );
    expect(find.textContaining('1199', findRichText: true), findsOneWidget);
    expect(find.text('Provisional'), findsNothing);
    expect(find.textContaining('games to reveal'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'open nights show every configured division even before teams exist',
    (tester) async {
      await _pump(
        tester,
        FieldrushOpenNights(
          games: [_game(highestDivision: 2, lowestDivision: 4)],
          now: now,
          onGame: (_) {},
        ),
      );
      expect(find.text('DIV 2–4'), findsOneWidget);
      expect(
        tester
            .widgetList<FieldrushDivisionShield>(
              find.byType(FieldrushDivisionShield),
            )
            .map((shield) => shield.division),
        [2, 3, 4],
      );
      expect(find.textContaining('Avg'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('placement footer stays on one line with progress on the right', (
    tester,
  ) async {
    await _pump(
      tester,
      FieldrushHomeRating(
        profile: _profile(matches: 0),
        season: null,
        onTap: () {},
      ),
    );
    final caption = find.text('Real rating after 2 games');
    final text = tester.widget<Text>(caption);
    expect(text.maxLines, 1);
    expect(text.softWrap, isFalse);
    expect(
      find.ancestor(of: caption, matching: find.byType(FittedBox)),
      findsOneWidget,
    );
    final count = find.text('0 / 2');
    expect(
      tester.getCenter(caption).dy,
      closeTo(tester.getCenter(count).dy, 2),
    );
    expect(
      tester.getTopRight(caption).dx,
      lessThan(tester.getTopLeft(count).dx),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'quick picker uses three positions and the soonest real available game',
    (tester) async {
      final later = _game(
        id: 'later',
        startsAt: DateTime.utc(2099, 6, 6, 3, 30),
      );
      final soonest = _game(
        id: 'soonest',
        startsAt: DateTime.utc(2099, 6, 5, 3, 30),
        defenderSpots: 0,
      );
      OpenQueueGame? chosen;
      Set<OpenQueueRole>? roles;
      await _pump(
        tester,
        FieldrushQuickGameCard(
          games: [
            later,
            _game(id: 'past', startsAt: now.subtract(const Duration(days: 1))),
            _game(id: 'cancelled', status: 'CANCELLED'),
            _game(id: 'booked', myBookingId: 'booking'),
            soonest,
          ],
          now: now,
          onPlay: (game, selected) {
            chosen = game;
            roles = selected;
          },
        ),
      );

      expect(find.text('Keeper'), findsOneWidget);
      expect(find.text('Defender'), findsOneWidget);
      expect(find.text('Attacker'), findsOneWidget);
      expect(find.text('Midfielder'), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('home-quick-pitch'))).height,
        118,
      );
      await tester.tap(find.byKey(const ValueKey('home-quick-play')));
      await tester.pump();
      expect(chosen, isNull);
      expect(roles, isNull);
      expect(find.text('✓'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('home-position-DEF')));
      await tester.pump();
      expect(find.text('✓'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-quick-play')));
      expect(chosen?.id, 'later');
      expect(roles, {OpenQueueRole.defender});

      await tester.tap(find.byKey(const ValueKey('home-position-ATT')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('home-quick-play')));
      expect(chosen?.id, 'soonest');
      // Home is a preference shortcut into the matching-game step, not a
      // reservation for only the first game's available position.
      expect(roles, {OpenQueueRole.defender, OpenQueueRole.attacker});
      expect(find.textContaining(soonest.priceLabel), findsOneWidget);
      expect(find.textContaining(r'$13.00'), findsOneWidget);
      expect(find.textContaining('BHD'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('idle Play hints only available positions then clears', (
    tester,
  ) async {
    var playCalls = 0;
    await _pump(
      tester,
      FieldrushQuickGameCard(
        games: [_game(defenderSpots: 0)],
        now: now,
        onPlay: (_, _) => playCalls++,
      ),
    );
    final play = find.byKey(const ValueKey('home-quick-play'));
    final idleButton = tester.widget<FilledButton>(play);
    expect(
      idleButton.style!.backgroundColor!.resolve({}),
      const Color(0xFFF2EFE3),
    );
    expect(_positionHalo(tester, 'GK')?.spreadRadius, 4);
    await tester.tap(play);
    await tester.pump();
    expect(playCalls, 0);
    expect(find.text('✓'), findsNothing);
    for (final role in ['GK', 'ATT']) {
      expect(_positionHalo(tester, role)?.spreadRadius, 9);
      expect(_positionHalo(tester, role)?.color.a, closeTo(.5, .01));
    }
    expect(_positionHalo(tester, 'DEF')?.spreadRadius, 4);
    await tester.pump(const Duration(milliseconds: 899));
    expect(_positionHalo(tester, 'GK')?.spreadRadius, 9);
    await tester.pump(const Duration(milliseconds: 1));
    for (final role in ['GK', 'DEF', 'ATT']) {
      expect(_positionHalo(tester, role)?.spreadRadius, 4);
    }
    expect(playCalls, 0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'repeated Play restarts the hint and choosing a position clears it',
    (tester) async {
      var playCalls = 0;
      Set<OpenQueueRole>? chosen;
      await _pump(
        tester,
        FieldrushQuickGameCard(
          games: [_game()],
          now: now,
          onPlay: (_, roles) {
            playCalls++;
            chosen = roles;
          },
        ),
      );
      final play = find.byKey(const ValueKey('home-quick-play'));
      await tester.tap(play);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(play);
      await tester.pump(const Duration(milliseconds: 600));
      expect(playCalls, 0);
      expect(_positionHalo(tester, 'ATT')?.spreadRadius, 9);

      await tester.tap(find.byKey(const ValueKey('home-position-GK')));
      await tester.pump();
      expect(_positionHalo(tester, 'GK'), isNull);
      expect(_positionHalo(tester, 'DEF')?.spreadRadius, 4);
      expect(_positionHalo(tester, 'ATT')?.spreadRadius, 4);
      expect(find.text('✓'), findsOneWidget);
      expect(playCalls, 0);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.tap(play);
      expect(playCalls, 1);
      expect(chosen, {OpenQueueRole.goalkeeper});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open nights are sorted, limited to two, and exclude unavailable games',
    (tester) async {
      final games = [
        _game(id: 'last', startsAt: DateTime.utc(2099, 6, 8)),
        _game(id: 'first', startsAt: DateTime.utc(2099, 6, 4)),
        _game(id: 'second', startsAt: DateTime.utc(2099, 6, 5)),
        _game(id: 'full', status: 'FULL', confirmed: 14),
      ];
      String? opened;
      await _pump(
        tester,
        FieldrushOpenNights(
          games: games,
          now: now,
          onGame: (game) => opened = game.id,
        ),
      );
      expect(
        find.byKey(const ValueKey('home-open-night-first')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-open-night-second')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-open-night-last')), findsNothing);
      expect(find.byKey(const ValueKey('home-open-night-full')), findsNothing);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('home-open-night-first')))
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('home-open-night-second')))
              .dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('home-open-night-second')));
      expect(opened, 'second');
    },
  );

  testWidgets('empty open nights do not invent dates, fees, or players', (
    tester,
  ) async {
    await _pump(tester, FieldrushOpenNights(games: const [], onGame: (_) {}));
    expect(find.textContaining('No open games right now'), findsOneWidget);
    expect(find.text('Take a spot ›'), findsNothing);
  });

  testWidgets('solo hero uses real capacity and timezone without any streak', (
    tester,
  ) async {
    final game = _game(confirmed: 9);
    await _pump(
      tester,
      FieldrushSoloHero(
        booking: _booking(game, team: openQueueWhiteTeamId),
        onTap: () {},
      ),
    );
    expect(
      find.byKey(const ValueKey('home-solo-booking-booking')),
      findsOneWidget,
    );
    expect(find.text('WAITING ON 5'), findsOneWidget);
    expect(find.text('9/14 in', findRichText: true), findsOneWidget);
    expect(find.text('8:30'), findsOneWidget);
    expect(find.textContaining('THU, 4 JUN'), findsOneWidget);
    expect(find.textContaining('Teams assigned'), findsOneWidget);
    expect(find.text('WEAR WHITE'), findsNothing);
    expect(find.textContaining('Streak'), findsNothing);
    expect(find.textContaining('streak'), findsNothing);
  });

  testWidgets('kit instruction appears only for an active assigned team', (
    tester,
  ) async {
    final game = _game(status: 'FULL', confirmed: 14, assigned: true);
    await _pump(
      tester,
      FieldrushSoloHero(
        booking: _booking(game, team: openQueueBlackTeamId),
        onTap: () {},
      ),
    );
    expect(find.text('ROSTER FULL'), findsOneWidget);
    expect(find.text('WEAR BLACK'), findsOneWidget);
    await _pump(
      tester,
      FieldrushSoloHero(booking: _booking(game), onTap: () {}),
    );
    expect(find.text('WEAR BLACK'), findsNothing);
    expect(find.text('WEAR WHITE'), findsNothing);
    expect(find.text('Kit assignment updating'), findsOneWidget);
  });

  for (final team in [openQueueWhiteTeamId, openQueueBlackTeamId]) {
    testWidgets('Home retains $team kit with privacy-masked ratings', (
      tester,
    ) async {
      final game = _game(
        status: 'FULL',
        confirmed: 14,
        assigned: true,
        hideRatings: true,
      );
      await _pump(
        tester,
        FieldrushSoloHero(
          booking: _booking(game, team: team),
          onTap: () {},
        ),
      );
      expect(find.text('WEAR $team'), findsOneWidget);
      expect(find.text('Kit assignment updating'), findsNothing);
      expect(game.whiteAverageSr, isNull);
      expect(game.blackAverageSr, isNull);
      expect(game.matchAverageSr, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'also booked displays the game local date and opens its callback',
    (tester) async {
      var opened = false;
      await _pump(
        tester,
        FieldrushAlsoBooked(
          key: const ValueKey('second-booking'),
          title: 'Solo game',
          startsAt: DateTime.utc(2099, 6, 5, 3, 30),
          gameTimezone: 'America/Phoenix',
          onTap: () => opened = true,
        ),
      );
      expect(find.text('4'), findsOneWidget);
      expect(find.text('8:30 PM · Solo game'), findsOneWidget);
      await tester.tap(find.text('8:30 PM · Solo game'));
      expect(opened, isTrue);
    },
  );

  testWidgets(
    'rating is real season and rank with chronological last five results',
    (tester) async {
      final events = [
        for (final day in [6, 1, 5, 2, 4, 3]) _event(day),
      ];
      await _pump(
        tester,
        FieldrushHomeRating(
          profile: _profile(events: events, matches: 6),
          rating: _rating(),
          season: leaderboardSeasons[1],
          onTap: () {},
        ),
      );
      expect(find.text('SEASON 1'), findsOneWidget);
      expect(find.text('#7 in Phoenix'), findsOneWidget);
      expect(find.text('SILVER'), findsOneWidget);
      expect(find.text('101 SR to Division 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-rating-event-1')), findsNothing);
      for (var day = 2; day <= 6; day++) {
        expect(find.byKey(ValueKey('home-rating-event-$day')), findsOneWidget);
        if (day < 6) {
          expect(
            tester
                .getTopLeft(find.byKey(ValueKey('home-rating-event-$day')))
                .dx,
            lessThan(
              tester
                  .getTopLeft(
                    find.byKey(ValueKey('home-rating-event-${day + 1}')),
                  )
                  .dx,
            ),
          );
        }
      }
      expect(find.text('+20'), findsOneWidget);
      final shields = tester.widgetList<FieldrushDivisionShield>(
        find.byType(FieldrushDivisionShield),
      );
      expect(shields.where((shield) => shield.size == 36).single.division, 4);
      expect(shields.where((shield) => shield.size == 24).length, 4);
    },
  );

  testWidgets(
    'placement has two real progress games and unknown region is not Phoenix',
    (tester) async {
      await _pump(
        tester,
        FieldrushHomeRating(
          profile: _profile(matches: 1),
          season: null,
          onTap: () {},
        ),
      );
      expect(
        find.byKey(const ValueKey('home-rating-placement')),
        findsOneWidget,
      );
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('????'), findsOneWidget);
      expect(find.byType(FieldrushPlacementRatingCard), findsOneWidget);
      expect(find.textContaining('#? IN'), findsNothing);
      expect(find.text('Real rating after 1 more game'), findsOneWidget);
      expect(find.textContaining('SEASON 0'), findsNothing);
      await _pump(
        tester,
        FieldrushHomeRating(
          profile: _profile(matches: 6),
          rating: _rating(rank: 0, region: ''),
          onTap: () {},
        ),
      );
      expect(find.text('View divisions ›'), findsOneWidget);
      expect(find.textContaining('Phoenix'), findsNothing);
    },
  );

  testWidgets('clan hero never invents an opponent or personal call-up', (
    tester,
  ) async {
    await _pump(
      tester,
      FieldrushClanHero(fixture: _fixture(), clan: _clan(), onTap: () {}),
    );
    expect(find.text('CLAN GAME'), findsOneWidget);
    expect(find.text('Bone Clan vs Opponent TBC'), findsOneWidget);
    expect(find.textContaining("YOU'RE IN"), findsNothing);
    expect(find.textContaining('Called up'), findsNothing);
    expect(find.text('7:00'), findsOneWidget);
  });

  testWidgets('header profile, search, activity, and unread are functional', (
    tester,
  ) async {
    var profile = 0;
    var search = 0;
    var activity = 0;
    await _pump(
      tester,
      FieldrushHomeHeader(
        profile: _profile(),
        onProfile: () => profile++,
        onSearch: () => search++,
        onActivity: () => activity++,
        hasUnread: true,
        now: DateTime(2099, 6, 1, 19),
      ),
    );
    expect(find.text('Evening, Sam'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-unread-activity')), findsOneWidget);
    await tester.tap(find.text('SR'));
    await tester.tap(find.byTooltip('Search players'));
    await tester.tap(find.byTooltip('Activity'));
    expect([profile, search, activity], [1, 1, 1]);
  });

  testWidgets('header shows division and SR without the provisional label', (
    tester,
  ) async {
    const visibility = PlayerRatingVisibility(
      lifetimeCountedMatches: 2,
      seasonCountedMatches: 0,
      ratingVisible: true,
      provisional: true,
      placementMatchesRemaining: 0,
    );
    final profile = _profile(matches: 0, visibility: visibility);
    final leaderboardRating = _rating(visibility: visibility);

    for (final rating in [null, leaderboardRating]) {
      expect((rating ?? profile.playerRating!).provisional, isTrue);
      await _pump(
        tester,
        FieldrushHomeHeader(
          profile: profile,
          rating: rating,
          onProfile: () {},
          onSearch: () {},
          onActivity: () {},
          hasUnread: false,
          now: DateTime(2099, 6, 1, 19),
        ),
      );

      expect(find.text('Evening, Sam'), findsOneWidget);
      expect(find.text('Division 4 · 1199 skill rating'), findsOneWidget);
      expect(find.textContaining('Provisional'), findsNothing);
      expect(find.textContaining('Placement'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('every Home widget fits at 320px and text scale 1.4', (
    tester,
  ) async {
    for (final child in [
      FieldrushHomeHeader(
        profile: _profile(),
        rating: _rating(),
        onProfile: () {},
        onSearch: () {},
        onActivity: () {},
        hasUnread: true,
      ),
      FieldrushQuickGameCard(games: [_game()], now: now, onPlay: (_, _) {}),
      FieldrushOpenNights(games: [_game()], now: now, onGame: (_) {}),
      FieldrushSoloHero(
        booking: _booking(
          _game(status: 'FULL', confirmed: 14, assigned: true),
          team: openQueueWhiteTeamId,
        ),
        onTap: () {},
      ),
      FieldrushClanHero(
        fixture: _fixture(),
        clan: _clan(),
        onTap: () {},
        selectedCount: 7,
      ),
      FieldrushAlsoBooked(
        title: 'Solo game at a longer named venue',
        startsAt: _game().startsAt,
        gameTimezone: 'America/Phoenix',
        onTap: () {},
      ),
      FieldrushHomeRating(
        profile: _profile(
          events: [for (var day = 1; day <= 5; day++) _event(day)],
          matches: 6,
        ),
        rating: _rating(),
        season: leaderboardSeasons[1],
        onTap: () {},
      ),
      FieldrushHomeRating(
        profile: _profile(matches: 1),
        season: leaderboardSeasons[1],
        onTap: () {},
      ),
    ]) {
      await _pump(tester, child, width: 320, scale: 1.4);
      expect(
        tester.takeException(),
        isNull,
        reason: child.runtimeType.toString(),
      );
    }
  });

  testWidgets('renders optional local visual QA previews', (tester) async {
    final directory = Platform.environment['FIELDRUSH_HOME_SCREENSHOT_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        await (FontLoader(
          font,
        )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
      }
    });
    for (final (name, child) in [
      (
        'placement-card',
        FieldrushHomeRating(
          profile: _profile(matches: 0),
          season: null,
          onTap: () {},
        ),
      ),
      (
        'empty-home',
        Column(
          children: [
            FieldrushHomeHeader(
              profile: _profile(matches: 1),
              onProfile: () {},
              onSearch: () {},
              onActivity: () {},
              hasUnread: true,
              now: DateTime(2099, 6, 1, 19),
            ),
            FieldrushQuickGameCard(
              games: [_game()],
              now: now,
              onPlay: (_, _) {},
            ),
            FieldrushOpenNights(
              games: [
                _game(),
                _game(id: 'second', startsAt: DateTime.utc(2099, 6, 7, 3, 30)),
              ],
              now: now,
              onGame: (_) {},
            ),
            FieldrushHomeRating(
              profile: _profile(matches: 1),
              season: leaderboardSeasons[1],
              onTap: () {},
            ),
          ],
        ),
      ),
      (
        'booked-home',
        Column(
          children: [
            FieldrushHomeHeader(
              profile: _profile(matches: 6),
              rating: _rating(),
              onProfile: () {},
              onSearch: () {},
              onActivity: () {},
              hasUnread: false,
              now: DateTime(2099, 6, 1, 19),
            ),
            FieldrushSoloHero(
              booking: _booking(
                _game(status: 'FULL', confirmed: 14, assigned: true),
                team: openQueueWhiteTeamId,
              ),
              onTap: () {},
            ),
            FieldrushAlsoBooked(
              title: 'Clan game',
              startsAt: _game().startsAt,
              gameTimezone: 'America/Phoenix',
              onTap: () {},
            ),
            FieldrushHomeRating(
              profile: _profile(
                events: [for (var day = 1; day <= 5; day++) _event(day)],
                matches: 6,
              ),
              rating: _rating(),
              season: leaderboardSeasons[1],
              onTap: () {},
            ),
          ],
        ),
      ),
      (
        'clan-home',
        Column(
          children: [
            FieldrushHomeHeader(
              profile: _profile(matches: 6),
              rating: _rating(),
              onProfile: () {},
              onSearch: () {},
              onActivity: () {},
              hasUnread: true,
              now: DateTime(2099, 6, 1, 19),
            ),
            FieldrushClanHero(
              fixture: _fixture(),
              clan: _clan(),
              onTap: () {},
              selectedCount: 7,
              isSelected: true,
            ),
            FieldrushAlsoBooked(
              title: 'Solo game',
              startsAt: _game().startsAt,
              gameTimezone: 'America/Phoenix',
              onTap: () {},
            ),
            FieldrushHomeRating(
              profile: _profile(
                events: [for (var day = 1; day <= 5; day++) _event(day)],
                matches: 6,
              ),
              rating: _rating(),
              season: leaderboardSeasons[1],
              onTap: () {},
            ),
          ],
        ),
      ),
    ]) {
      final key = GlobalKey();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              backgroundColor: fieldrushHomeCream,
              body: Stack(
                children: [
                  SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 132),
                      child: child,
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: FieldBottomNav(selectedIndex: 0, onSelected: (_) {}),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, widget) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: widget!,
      ),
      home: Scaffold(
        backgroundColor: fieldrushHomeCream,
        body: SingleChildScrollView(child: child),
      ),
    ),
  );
  await tester.pump();
}

BoxShadow? _positionHalo(WidgetTester tester, String role) {
  final dot = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(ValueKey('home-position-$role')),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (dot.decoration! as BoxDecoration).boxShadow
      ?.where((shadow) => shadow.spreadRadius > 0)
      .firstOrNull;
}

OpenQueueGame _game({
  String id = 'game',
  String status = 'OPEN',
  DateTime? startsAt,
  int confirmed = 8,
  int defenderSpots = 6,
  String? myBookingId,
  bool assigned = false,
  bool hideRatings = false,
  int highestDivision = 1,
  int lowestDivision = 5,
}) => OpenQueueGame(
  id: id,
  status: status,
  venue: 'Reach 11 Fields · Field 2',
  startsAt: startsAt ?? DateTime.utc(2099, 6, 5, 3, 30),
  endsAt: (startsAt ?? DateTime.utc(2099, 6, 5, 3, 30)).add(
    const Duration(hours: 1),
  ),
  timezone: 'America/Phoenix',
  priceFils: 13000,
  currency: 'USD',
  highestDivision: highestDivision,
  lowestDivision: lowestDivision,
  ageLabel: '18+',
  capacity: 14,
  confirmedCount: confirmed,
  spots: {
    OpenQueueRole.goalkeeper: 2,
    OpenQueueRole.defender: defenderSpots,
    OpenQueueRole.attacker: 6,
  },
  myBookingId: myBookingId,
  teamsAssignedAt: assigned ? DateTime.utc(2000) : null,
  teamAssignmentAt: assigned ? DateTime.utc(2000) : DateTime.utc(2099, 6, 5),
  teamAssignmentLeadMinutes: 180,
  whiteAverageSr: assigned && !hideRatings ? 1200 : null,
  blackAverageSr: assigned && !hideRatings ? 1210 : null,
  matchAverageSr: assigned && !hideRatings ? 1205 : null,
);
OpenQueueBooking _booking(OpenQueueGame game, {String? team}) =>
    OpenQueueBooking(
      id: 'booking',
      gameId: game.id,
      profileId: 'profile',
      role: OpenQueueRole.defender,
      status: 'CONFIRMED',
      amountPaidFils: 13000,
      bookedAt: DateTime.utc(2099),
      game: game,
      team: team,
    );
PlayerProfile _profile({
  List<ProfileRatingEvent> events = const [],
  int matches = 0,
  PlayerRatingVisibility? visibility,
}) => PlayerProfile(
  id: 'profile',
  displayName: 'Sam Rivera',
  username: 'sam',
  bio: '',
  followingCount: 0,
  fansCount: 0,
  appearances: matches,
  goals: 0,
  assists: 0,
  highlights: const [],
  career: const [],
  playerRating: ProfilePlayerRating(
    skillRating: 1199,
    matchesPlayed: matches,
    wins: 2,
    losses: 2,
    draws: 2,
    lastChange: 4,
    region: 'phoenix',
    events: events,
    visibility: visibility,
  ),
);
PlayerRatingLeaderboardEntry _rating({
  int rank = 7,
  String region = 'phoenix',
  PlayerRatingVisibility? visibility,
}) => PlayerRatingLeaderboardEntry(
  rank: rank,
  profileId: 'profile',
  displayName: 'Sam Rivera',
  username: 'sam',
  skillRating: 1199,
  matchesPlayed: 6,
  wins: 2,
  losses: 2,
  draws: 2,
  lastChange: 4,
  region: region,
  visibility: visibility,
);
ProfileRatingEvent _event(int day) => ProfileRatingEvent(
  id: '$day',
  sourceType: 'OPEN_QUEUE',
  sourceId: 'game-$day',
  playedAt: DateTime.utc(2099, 5, day),
  opponentLabel: 'Opponent $day',
  side: 'WHITE',
  result: day.isEven ? 'WIN' : 'LOSS',
  ratingBefore: 1100,
  ratingChange: day,
  ratingAfter: 1100 + day,
);
Clan _clan() => const Clan(
  id: 'clan',
  name: 'Bone Clan',
  tag: 'BONE',
  motto: '',
  emblem: '⚽',
  themeId: 'pitch',
  patternId: 'solid',
  skillRating: 1199,
  wins: 0,
  losses: 0,
  memberCount: 7,
  createdBy: 'profile',
  region: 'phoenix',
);
Fixture _fixture() => Fixture(
  id: 'fixture',
  status: FixtureStatus.scheduled,
  homeClanId: 'clan',
  venue: 'Reach 11 Fields · Field 2',
  day: 'Thursday',
  timeSlot: '7:00 PM - 8:00 PM',
  matchDate: DateTime(2099, 6, 4),
  createdBy: 'profile',
  homeClan: const FixtureClan(
    id: 'clan',
    name: 'Bone Clan',
    tag: 'BONE',
    emblem: '⚽',
    themeId: 'pitch',
    patternId: 'solid',
    skillRating: 1199,
  ),
);
