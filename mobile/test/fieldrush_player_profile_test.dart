import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/profile/fieldrush_player_profile.dart';
import 'package:field/src/profile/fieldrush_you_widgets.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/ranking/player_rating_visibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'revealed lifetime rating survives season rollover without a status label',
    (tester) async {
      await _pump(
        tester,
        FieldrushPlayerProfileContent(
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
          isFollowing: false,
          followBusy: false,
          onBack: () {},
        ),
      );
      expect(find.text('1199'), findsOneWidget);
      expect(find.text('Provisional'), findsNothing);
      expect(find.text('PLACEMENT'), findsNothing);
      expect(find.textContaining('placement games'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'public profile renders verified values and actionable controls',
    (tester) async {
      final actions = <String>[];
      await _pump(tester, _content(actions: actions));
      expect(find.text('VIEW ONLY'), findsNothing);
      expect(find.text('DIVISION 4'), findsOneWidget);
      expect(find.text('1199'), findsOneWidget);
      expect(find.text('Position unavailable'), findsNothing);
      expect(find.byType(FieldrushMatchRecordCard), findsOneWidget);
      expect(find.text('0 played · 0% won'), findsOneWidget);
      expect(find.text('PLAYED'), findsNothing);
      expect(find.text('WIN RATE'), findsNothing);
      expect(find.text('SHOW-UP'), findsNothing);
      expect(find.text('99%'), findsNothing);
      expect(find.textContaining('private'), findsNothing);
      expect(find.textContaining('+1602'), findsNothing);
      expect(find.text('9999'), findsNothing);
      expect(find.text('LAST FIVE'), findsOneWidget);
      expect(find.text('Ball Club'), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);
      final resultLabels = <String>[];
      for (var i = 0; i < 5; i++) {
        resultLabels.add(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byKey(ValueKey('player-result-$i')),
                  matching: find.byType(Text),
                ),
              )
              .data!,
        );
      }
      expect(resultLabels, ['W', 'L', 'D', '—', 'W']);
      await tester.tap(find.byKey(const ValueKey('player-follow')));
      await tester.tap(find.byKey(const ValueKey('player-clan')));
      await tester.tap(find.byKey(const ValueKey('player-report')));
      await tester.tap(find.byKey(const ValueKey('player-back')));
      expect(actions, ['follow', 'clan', 'report', 'back']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unavailable public data does not become invented zeroes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      FieldrushPlayerProfileContent(
        profile: _profile(rating: null, clan: null),
        isFollowing: false,
        followBusy: false,
        onBack: () {},
      ),
    );
    expect(find.text('RATING UNAVAILABLE'), findsOneWidget);
    expect(find.text('Not in a clan'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-no-clan')), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.text('0%'), findsNothing);
    expect(find.text('D'), findsNothing);
    expect(find.text('Report player'), findsNothing);
    expect(find.byType(FieldrushDivisionShield), findsNothing);
    expect(find.bySemanticsLabel(RegExp('SHOW-UP:')), findsNothing);
    expect(find.bySemanticsLabel('No completed game'), findsNWidgets(5));
    semantics.dispose();
  });

  testWidgets('placement has a neutral shield and no revealed rating', (
    tester,
  ) async {
    await _pump(tester, _content(matches: 0));
    expect(find.text('PLACEMENT'), findsOneWidget);
    expect(find.text('????'), findsOneWidget);
    expect(find.text('0/2 placement games'), findsOneWidget);
    expect(find.text('1199'), findsNothing);
    final shield = tester.widget<FieldrushDivisionShield>(
      find.byType(FieldrushDivisionShield),
    );
    expect(shield.placement, isTrue);
    expect(find.textContaining('DIVISION'), findsNothing);
  });

  testWidgets('a failed avatar image falls back to player initials', (
    tester,
  ) async {
    await _pump(
      tester,
      FieldrushPlayerProfileContent(
        profile: _profile(avatarUrl: 'https://invalid.example/avatar.png'),
        isFollowing: false,
        followBusy: false,
        onBack: () {},
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('JA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('following and busy state prevent duplicate actions accessibly', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final actions = <String>[];
    await _pump(
      tester,
      _content(following: true, busy: true, actions: actions),
    );
    expect(find.text('Following'), findsOneWidget);
    final busy = find.bySemanticsLabel('Updating follow status');
    final data = tester.getSemantics(busy).getSemanticsData();
    expect(data.flagsCollection.isLiveRegion, isTrue);
    expect(data.hasAction(ui.SemanticsAction.tap), isFalse);
    await tester.tap(find.byKey(const ValueKey('player-follow')));
    expect(actions, isEmpty);
    await _pump(tester, _content(following: true, actions: actions));
    final following = find.bySemanticsLabel('Following. Tap to unfollow');
    expect(
      tester
          .getSemantics(following)
          .getSemanticsData()
          .hasAction(ui.SemanticsAction.tap),
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('all divisions and placement fit 320 pixels with large text', (
    tester,
  ) async {
    for (final rating in [900, 1199, 1388, 1563, 1742]) {
      for (final matches in [0, 8]) {
        await _pump(
          tester,
          _content(rating: rating, matches: matches, following: true),
          width: 320,
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('narrow enlarged text keeps the record and initials readable', (
    tester,
  ) async {
    for (final scale in [1.3, 2.0]) {
      await _pump(
        tester,
        FieldrushPlayerProfileContent(
          profile: _profile(),
          isFollowing: false,
          followBusy: false,
          onBack: () {},
          onMatchHistory: () {},
        ),
        width: 320,
        textScale: scale,
      );
      expect(find.byType(FieldrushMatchRecordCard), findsOneWidget);
      expect(find.text('WON'), findsOneWidget);
      expect(find.text('DRAWN'), findsOneWidget);
      expect(find.text('LOST'), findsOneWidget);
      expect(find.text('PLAYED'), findsNothing);
      expect(find.text('WIN RATE'), findsNothing);
      expect(find.text('SHOW-UP'), findsNothing);
      final initials = tester.widget<Text>(find.text('JA'));
      expect(initials.maxLines, 1);
      expect(initials.softWrap, isFalse);
      expect(
        find.ancestor(of: find.text('JA'), matching: find.byType(FittedBox)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('loading skeleton is static and retains working back control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var backs = 0;
    await _pump(
      tester,
      FieldrushPlayerProfileLoadingContent(onBack: () => backs++),
      width: 320,
      textScale: 2,
    );
    final loading = find.bySemanticsLabel('Loading player profile');
    expect(loading, findsOneWidget);
    expect(
      tester
          .getSemantics(loading)
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('player-record-loading')), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.tap(find.byKey(const ValueKey('player-back')));
    expect(backs, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('optional public profile visual previews use bundled fonts', (
    tester,
  ) async {
    final directory = Platform.environment['FIELDRUSH_PLAYER_SCREENSHOT_DIR'];
    if (directory == null) return;
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
    for (final (name, rating, matches, scale, width) in [
      ('player-bronze', 1046, 8, 1.0, 390.0),
      ('player-silver', 1199, 8, 1.0, 390.0),
      ('player-gold', 1388, 8, 1.0, 390.0),
      ('player-royal', 1563, 8, 1.0, 390.0),
      ('player-black-gold', 1742, 8, 1.0, 390.0),
      ('player-placement', 1200, 0, 1.0, 390.0),
      ('player-large-text', 1199, 8, 2.0, 320.0),
    ]) {
      final key = GlobalKey();
      await _pump(
        tester,
        RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: FieldrushAuthTheme.cream,
            child: _content(rating: rating, matches: matches),
          ),
        ),
        width: width,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 2);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
    }
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Theme(
          data: FieldrushAuthTheme.theme(context),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FieldrushPlayerProfileContent _content({
  int rating = 1199,
  int matches = 8,
  bool following = false,
  bool busy = false,
  List<String>? actions,
}) => FieldrushPlayerProfileContent(
  profile: _profile(rating: rating, matches: matches),
  isFollowing: following,
  followBusy: busy,
  onBack: () => actions?.add('back'),
  onFollow: () => actions?.add('follow'),
  onReport: () => actions?.add('report'),
  onOpenClan: () => actions?.add('clan'),
  onMatchHistory: () => actions?.add('history'),
  recentResults: const [
    ProfileGameOutcome.win,
    null,
    ProfileGameOutcome.draw,
    ProfileGameOutcome.loss,
    ProfileGameOutcome.win,
    ProfileGameOutcome.loss,
  ],
);

const _clan = ProfileClan(
  id: 'clan',
  name: 'Ball Club',
  tag: 'BC',
  emblem: '⚽',
  themeId: 'pitch',
  patternId: 'solid',
  skillRating: 1300,
);

PlayerProfile _profile({
  int? rating = 1199,
  int matches = 8,
  ProfileClan? clan = _clan,
  String? avatarUrl,
  PlayerRatingVisibility? visibility,
}) => PlayerProfile(
  id: 'player',
  displayName: 'Jordan A.',
  username: 'jalvarez',
  bio: 'private bio',
  phone: '+16025551212',
  avatarUrl: avatarUrl,
  clan: clan,
  followingCount: 12,
  fansCount: 28,
  appearances: 9999,
  goals: 9999,
  assists: 9999,
  highlights: const [],
  career: const [],
  playerRating: rating == null
      ? null
      : ProfilePlayerRating(
          skillRating: rating,
          matchesPlayed: matches,
          wins: 5,
          losses: 2,
          draws: 1,
          lastChange: 10,
          region: 'phoenix',
          events: const [],
          visibility: visibility,
        ),
);
