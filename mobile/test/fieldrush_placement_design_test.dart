import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/auth/fieldrush_skill_assessment_step.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/leaderboard/fieldrush_rating_role_tabs.dart';
import 'package:field/src/leaderboard/fieldrush_rating_tracks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'HTML placement cards stay compact and distinguish prediction from rank',
    (tester) async {
      await _pump(tester, _card(compact: true));
      expect(find.text('1000'), findsOneWidget);
      expect(find.text('PREDICTED'), findsOneWidget);
      expect(find.text('Real rating after 2 games'), findsOneWidget);
      expect(find.text('#? IN PHOENIX'), findsNothing);
      expect(
        tester.getSize(find.byType(FieldrushPlacementRatingCard)).height,
        lessThan(170),
      );
      expect(
        tester
            .widgetList<FieldrushDivisionShield>(
              find.byType(FieldrushDivisionShield),
            )
            .length,
        2,
      );
      await _pump(tester, _card(compact: false, games: 1, delta: -12));
      expect(find.text('#? IN PHOENIX'), findsOneWidget);
      expect(find.text('Real rating after 1 more game'), findsOneWidget);
      expect(find.text('−12 after game 1', findRichText: true), findsOneWidget);
      expect(
        tester
            .widgetList<FieldrushDivisionShield>(
              find.byType(FieldrushDivisionShield),
            )
            .length,
        8,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing prediction stays unknown without deriving a seed in the client',
    (tester) async {
      await _pump(
        tester,
        FieldrushPlacementRatingCard(
          matchesPlayed: 0,
          cityLabel: 'Phoenix',
          onTap: () {},
          compact: true,
        ),
      );
      expect(find.text('????'), findsOneWidget);
      expect(find.text('1000'), findsNothing);
      expect(
        find.byKey(const ValueKey('placement-predicted-change')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'level rows match the reference and remain usable with larger text',
    (tester) async {
      await _pump(tester, _level());
      expect(find.text('What’s your\nlevel?'), findsOneWidget);
      expect(find.text('So your first games are fair.'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Not sure'), findsNothing);
      expect(
        find.byKey(const Key('fieldrush-skill-intermediate')),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const Key('fieldrush-back'))),
        const Size(36, 36),
      );
      expect(
        tester.getSize(find.byKey(const Key('fieldrush-continue'))).height,
        52,
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('fieldrush-skill-title'))).dx,
        20,
      );
      expect(tester.takeException(), isNull);
      await _pump(tester, _level(), size: const Size(320, 568), scale: 1.5);
      await tester.ensureVisible(find.byKey(const Key('fieldrush-continue')));
      expect(tester.takeException(), isNull);
      await _pump(
        tester,
        _card(compact: false, games: 1, delta: 0),
        size: const Size(320, 568),
        scale: 1.5,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('render reference-sized visual previews when requested', (
    tester,
  ) async {
    final directory =
        Platform.environment['FIELDRUSH_PLACEMENT_SCREENSHOT_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        await (FontLoader(
          font,
        )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
      }
    });
    for (final (name, child) in [
      ('skill-level', _level()),
      ('placement-home', _card(compact: true)),
      ('placement-you', _card(compact: false, games: 1, delta: 40)),
    ]) {
      await _pump(tester, child);
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('preview')),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$directory/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}

Widget _card({required bool compact, int games = 0, int? delta}) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
  child: Align(
    alignment: Alignment.topCenter,
    child: FieldrushPlacementRatingCard(
      matchesPlayed: games,
      cityLabel: 'Phoenix, AZ',
      onTap: () {},
      compact: compact,
      predictedRating: games == 0 ? 1000 : 1040,
      predictedChange: delta,
      roleTabs: FieldrushRatingRoleTabs(
        selected: RatingTrack.outfield,
        onChanged: (_) {},
        dark: true,
      ),
    ),
  ),
);

Widget _level() => FieldrushSkillAssessmentStep(
  selected: SkillAssessment.intermediate,
  onSelected: (_) {},
  onBack: () {},
  onSkip: () {},
  onContinue: () {},
  stepNumber: 7,
  stepCount: 8,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  tester.view.resetPhysicalSize();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, widget) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: widget!,
      ),
      home: Builder(
        builder: (context) => Theme(
          data: FieldrushAuthTheme.theme(context),
          child: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('preview'),
              child: ColoredBox(color: FieldrushAuthTheme.cream, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
