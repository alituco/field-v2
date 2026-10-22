import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/leaderboard/fieldrush_rating_tracks.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/ranking/fieldrush_divisions_screen.dart';
import 'package:field/src/ranking/player_rating_visibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _season = LeaderboardSeason(
  id: 'season-zero',
  label: 'Season 0',
  rangeLabel: '',
  startsOn: '2026-10-01',
  endsOn: '2026-12-31',
);

void main() {
  testWidgets('HTML ranges descend from Division 1 and highlight actual SR', (
    tester,
  ) async {
    var openedRanks = 0;
    await _pump(
      tester,
      FieldrushDivisionsScreen(
        rating: _rating(1018),
        season: _season,
        cityName: 'Phoenix',
        onOpenRanks: () => openedRanks++,
      ),
    );

    expect(find.text('Divisions'), findsOneWidget);
    expect(find.text('Season 0 · Outfield'), findsOneWidget);
    for (final range in [
      '1650+ skill rating',
      '1500 to 1649 skill rating',
      '1300 to 1499 skill rating',
      '1100 to 1299 skill rating',
      'Under 1100 skill rating',
    ]) {
      expect(find.text(range), findsOneWidget);
    }
    expect(
      tester.getTopLeft(find.text('Division 1')).dy,
      lessThan(tester.getTopLeft(find.text('Division 5')).dy),
    );
    final badge = find.byKey(const ValueKey('division-current-rating'));
    expect(
      find.descendant(of: badge, matching: find.text('You · 1018')),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: badge,
        matching: find.byKey(const ValueKey('division-row-5')),
      ),
      findsOneWidget,
    );
    expect(find.text('82 to Division 4'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('division-progress'))).width /
          tester
              .getSize(find.byKey(const ValueKey('division-progress-track')))
              .width,
      closeTo(.59, .001),
    );
    expect(find.textContaining('Provisional'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('divisions-open-ranks')));
    expect(openedRanks, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Keeper placement uses only owner prediction with dashed progress',
    (tester) async {
      await _pump(
        tester,
        FieldrushDivisionsScreen(
          rating: _rating(8888, visible: false, counted: 1),
          prediction: const FieldrushPlacementPrediction(
            skillRating: 1270,
            countedMatches: 1,
          ),
          track: RatingTrack.goalkeeper,
          season: _season,
          cityName: 'Phoenix',
          onOpenRanks: () {},
        ),
      );
      expect(find.text('Season 0 · Keeper'), findsOneWidget);
      expect(find.text('Predicted 1270'), findsOneWidget);
      expect(
        find.text(
          'Predicted until your real rating comes in, after 1 more game in goal.',
        ),
        findsOneWidget,
      );
      expect(find.text('30 to Division 3'), findsOneWidget);
      expect(find.textContaining('8888'), findsNothing);
      expect(find.textContaining('You ·'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hidden official SR without owner prediction is never revealed', (
    tester,
  ) async {
    await _pump(
      tester,
      FieldrushDivisionsScreen(
        rating: _rating(1270, visible: false, counted: 0),
        onOpenRanks: () {},
      ),
    );
    expect(find.textContaining('1270'), findsNothing);
    expect(find.byKey(const ValueKey('division-current-rating')), findsNothing);
    expect(find.byKey(const ValueKey('division-progress')), findsNothing);
    expect(find.text('Play 2 games to reveal your division.'), findsOneWidget);
    expect(find.text('See ranks'), findsOneWidget);
  });

  testWidgets('revealed rating wins over stale placement prediction', (
    tester,
  ) async {
    await _pump(
      tester,
      FieldrushDivisionsScreen(
        rating: _rating(1650),
        prediction: const FieldrushPlacementPrediction(
          skillRating: 1000,
          countedMatches: 0,
        ),
        onOpenRanks: () {},
      ),
    );
    expect(find.text('You · 1650'), findsOneWidget);
    expect(find.text('Top division'), findsOneWidget);
    expect(find.textContaining('Predicted'), findsNothing);
    expect(find.textContaining('to Division 0'), findsNothing);
  });

  testWidgets('division highlights use canonical rating boundaries', (
    tester,
  ) async {
    for (final (sr, division) in [
      (0, 5),
      (1099, 5),
      (1100, 4),
      (1300, 3),
      (1500, 2),
      (1650, 1),
    ]) {
      await _pump(
        tester,
        FieldrushDivisionsScreen(rating: _rating(sr), onOpenRanks: () {}),
      );
      final row = find.byKey(ValueKey('division-row-$division'));
      expect(
        find.descendant(of: row, matching: find.text('You · $sr')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('division-current-rating')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('missing data shows the guide without inventing personal state', (
    tester,
  ) async {
    await _pump(tester, FieldrushDivisionsScreen(onOpenRanks: () {}));
    expect(find.text('Current season · Outfield'), findsOneWidget);
    expect(find.byKey(const ValueKey('division-current-rating')), findsNothing);
    expect(find.textContaining('Predicted'), findsNothing);
    expect(find.text('See ranks'), findsOneWidget);
  });

  testWidgets('divisions fit narrow screens with large text', (tester) async {
    for (final sr in [1018, 1650]) {
      await _pump(
        tester,
        FieldrushDivisionsScreen(
          rating: _rating(sr),
          season: _season,
          onOpenRanks: () {},
        ),
        width: 320,
        scale: 1.8,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('divisions-open-ranks')),
        150,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('optional local divisions visual QA', (tester) async {
    final path = Platform.environment['FIELDRUSH_DIVISIONS_SCREENSHOT'];
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
    final boundary = GlobalKey();
    await _pump(
      tester,
      RepaintBoundary(
        key: boundary,
        child: FieldrushDivisionsScreen(
          rating: _rating(1046),
          season: _season,
          cityName: 'Phoenix',
          onOpenRanks: () {},
          onNavigateTab: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final screenshot = await render.toImage(pixelRatio: 1);
      final bytes = await screenshot.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(bytes!.buffer.asUint8List());
      screenshot.dispose();
    });
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 844),
          textScaler: TextScaler.linear(scale),
        ),
        child: Theme(
          data: ThemeData(scaffoldBackgroundColor: FieldrushAuthTheme.cream),
          child: child,
        ),
      ),
    ),
  );
  await tester.pump();
}

PlayerRatingLeaderboardEntry _rating(
  int sr, {
  bool visible = true,
  int counted = 2,
}) => PlayerRatingLeaderboardEntry(
  rank: 13,
  profileId: 'self',
  displayName: 'Ali A.',
  username: 'ali',
  skillRating: sr,
  matchesPlayed: counted,
  wins: 1,
  losses: 0,
  draws: 1,
  lastChange: 18,
  region: 'phoenix',
  visibility: PlayerRatingVisibility(
    lifetimeCountedMatches: counted,
    seasonCountedMatches: counted,
    ratingVisible: visible,
    provisional: visible && counted < 10,
    placementMatchesRemaining: visible ? 0 : 2 - counted,
  ),
);
