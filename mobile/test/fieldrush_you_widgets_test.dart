import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/profile/fieldrush_you_widgets.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/reliability/reliability.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('new player has real people counts and a two-game placement', (
    tester,
  ) async {
    await _pump(tester, _content(rating: _rating(matches: 0)));
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Jordan A.'), findsOneWidget);
    expect(find.text('@jalvarez · Phoenix, AZ'), findsOneWidget);
    expect(find.text('FOLLOWING ›'), findsOneWidget);
    expect(find.text('FANS ›'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('28'), findsOneWidget);
    expect(find.text('PLACEMENT'), findsOneWidget);
    expect(find.text('????'), findsOneWidget);
    expect(find.text('2 games to reveal your division'), findsOneWidget);
    expect(find.text('0 / 2'), findsOneWidget);
    expect(find.text('WON'), findsNothing);
    expect(find.text('LAST FIVE'), findsNothing);
    expect(
      find.text('Open the replay of a finished match and tap Clip.'),
      findsOneWidget,
    );
    expect(find.textContaining('Streak'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('season rating and record never use lifetime profile totals', (
    tester,
  ) async {
    await _pump(
      tester,
      _content(
        rating: _rating(),
        results: [for (var day = 1; day <= 7; day++) _event(day)],
      ),
    );
    expect(find.text('DIVISION FOUR'), findsOneWidget);
    expect(find.text('#38 IN PHOENIX'), findsOneWidget);
    expect(find.text('1199'), findsOneWidget);
    expect(find.text('101 SR to Division 3'), findsOneWidget);
    expect(find.text('1300 · D3 ›'), findsOneWidget);
    expect(find.text('8 played · 50% won'), findsOneWidget);
    expect(find.text('9999'), findsNothing);
    expect(find.byKey(const ValueKey('you-result-1')), findsNothing);
    expect(find.byKey(const ValueKey('you-result-2')), findsNothing);
    expect(find.byKey(const ValueKey('you-result-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('you-result-7')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('you-result-3'))).dx,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('you-result-7'))).dx,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('rating and reliability outages show honest unavailable states', (
    tester,
  ) async {
    await _pump(
      tester,
      _content(ratingUnavailable: true, reliabilityUnavailable: true),
    );
    expect(find.text('Rating unavailable'), findsOneWidget);
    expect(find.text('PLACEMENT'), findsNothing);
    expect(find.text('9999'), findsNothing);
    expect(find.text('WON'), findsNothing);
    expect(find.text('Good standing'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('you-reliability')));
    await tester.pump();
    expect(find.textContaining('could not be loaded'), findsOneWidget);
    expect(find.text('View attendance & appeals'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reliability expands actual status and opens the full record', (
    tester,
  ) async {
    final actions = <String>[];
    await _pump(
      tester,
      _content(
        rating: _rating(),
        reliability: _reliability(strikes: 2),
        actions: actions,
      ),
    );
    expect(find.text('2 active strikes'), findsOneWidget);
    expect(find.text('Your two strikes are under review.'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('you-reliability')));
    await tester.pump();
    expect(find.text('Your two strikes are under review.'), findsOneWidget);
    expect(find.textContaining('eight weeks'), findsNothing);
    expect(find.textContaining('3h'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('you-reliability-details')));
    expect(actions, ['reliability']);
    await tester.tap(find.byKey(const ValueKey('you-reliability')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('you-reliability-expanded')),
      findsNothing,
    );
  });

  testWidgets(
    'profile, settings, ranking, history and clip callbacks are connected',
    (tester) async {
      final actions = <String>[];
      await _pump(
        tester,
        _content(rating: _rating(), actions: actions, clips: [_clip()]),
      );
      for (final key in [
        'you-edit',
        'you-following',
        'you-fans',
        'you-rating-ranked',
        'you-match-history',
        'you-clip-clip',
        'you-account-details',
        'you-notifications',
        'you-wallet',
        'you-payment-methods',
        'you-sign-out',
      ]) {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pump();
      }
      expect(actions, [
        'edit',
        'following',
        'fans',
        'ranks',
        'history',
        'clip:clip',
        'edit',
        'notifications',
        'wallet',
        'payments',
        'signout',
      ]);
      expect(find.text('VERIFY EMAIL'), findsOneWidget);
      expect(find.text(r'$13.00'), findsOneWidget);
      expect(find.text('Sat, Oct 10'), findsOneWidget);
      expect(find.byKey(const ValueKey('you-switch-user')), findsNothing);
    },
  );

  testWidgets('sign-out is disabled while it is in progress', (tester) async {
    final actions = <String>[];
    await _pump(
      tester,
      _content(rating: _rating(matches: 1), actions: actions, signingOut: true),
    );
    expect(find.text('1 game to reveal your division'), findsOneWidget);
    expect(find.text('Signing out…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('you-sign-out')));
    expect(actions, isEmpty);
  });

  testWidgets('content remains usable at 320px and larger text', (
    tester,
  ) async {
    for (final matches in [0, 8]) {
      await _pump(
        tester,
        _content(
          rating: _rating(matches: matches),
          reliability: _reliability(strikes: 2),
          clips: [_clip()],
        ),
        width: 320,
        textScale: 1.6,
      );
      await tester.tap(find.byKey(const ValueKey('you-reliability')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('optional native visual previews use the real fonts', (
    tester,
  ) async {
    final directory = Platform.environment['FIELDRUSH_YOU_SCREENSHOT_DIR'];
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
    for (final (name, rating) in [
      ('you-placement', _rating(matches: 0)),
      ('you-ranked', _rating()),
    ]) {
      final boundaryKey = GlobalKey();
      await _pump(
        tester,
        RepaintBoundary(
          key: boundaryKey,
          child: ColoredBox(
            color: FieldrushAuthTheme.cream,
            child: _content(
              rating: rating,
              reliability: _reliability(),
              results: [for (var day = 3; day <= 7; day++) _event(day)],
              clips: [_clip()],
            ),
          ),
        ),
        height: 1700,
      );
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
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
  double height = 2600,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Theme(
          data: FieldrushAuthTheme.theme(context),
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FieldrushYouContent _content({
  PlayerRatingLeaderboardEntry? rating,
  bool ratingUnavailable = false,
  bool reliabilityUnavailable = false,
  ReliabilityStatus? reliability,
  List<ProfileRatingEvent> results = const [],
  List<ProfileHighlight> clips = const [],
  List<String>? actions,
  bool signingOut = false,
}) => FieldrushYouContent(
  profile: _profile(clips: clips),
  rating: rating,
  ratingUnavailable: ratingUnavailable,
  recentResults: results,
  reliability: reliability,
  reliabilityUnavailable: reliabilityUnavailable,
  emailUnverified: true,
  walletLabel: r'$13.00',
  notificationLabel: 'On',
  onEdit: () => actions?.add('edit'),
  onFollowing: () => actions?.add('following'),
  onFans: () => actions?.add('fans'),
  onRanks: () => actions?.add('ranks'),
  onMatchHistory: () => actions?.add('history'),
  onClip: (clip) => actions?.add('clip:${clip.id}'),
  onReliability: () => actions?.add('reliability'),
  onNotifications: () => actions?.add('notifications'),
  onWallet: () => actions?.add('wallet'),
  onPaymentMethods: () => actions?.add('payments'),
  onSignOut: () => actions?.add('signout'),
  isSigningOut: signingOut,
);

PlayerProfile _profile({List<ProfileHighlight> clips = const []}) =>
    PlayerProfile(
      id: 'player',
      displayName: 'Jordan A.',
      username: 'jalvarez',
      bio: '',
      followingCount: 12,
      fansCount: 28,
      appearances: 9999,
      goals: 9999,
      assists: 9999,
      highlights: clips,
      career: const [],
      playerRating: const ProfilePlayerRating(
        skillRating: 9999,
        matchesPlayed: 9999,
        wins: 9999,
        losses: 0,
        draws: 0,
        lastChange: 99,
        region: 'phoenix',
        events: [],
      ),
    );

PlayerRatingLeaderboardEntry _rating({int matches = 8}) =>
    PlayerRatingLeaderboardEntry(
      rank: matches >= 2 ? 38 : 0,
      profileId: 'player',
      displayName: 'Jordan A.',
      username: 'jalvarez',
      skillRating: 1199,
      matchesPlayed: matches,
      wins: matches >= 2 ? 4 : 0,
      losses: matches >= 2 ? 2 : 0,
      draws: matches >= 2 ? 2 : 0,
      lastChange: -13,
      region: 'phoenix',
    );

ProfileRatingEvent _event(int day) => ProfileRatingEvent(
  id: '$day',
  sourceType: 'OPEN_QUEUE',
  sourceId: 'game-$day',
  playedAt: DateTime.utc(2026, 10, day),
  opponentLabel: 'Team $day',
  side: 'WHITE',
  result: day.isEven ? 'LOSS' : 'WIN',
  ratingBefore: 1188,
  ratingChange: 11,
  ratingAfter: 1199,
);

ProfileHighlight _clip() => ProfileHighlight(
  id: 'clip',
  title: 'My goal · 47′',
  thumbnailUrl: '',
  duration: '0:20',
  views: 14,
  videoUrl: 'https://example.com/clip.m3u8',
  createdAt: DateTime.utc(2026, 10, 11, 2),
);

ReliabilityStatus _reliability({int strikes = 0}) => ReliabilityStatus(
  serverNow: DateTime.utc(2026, 10, 10),
  policyVersionId: 'policy',
  activeStrikes: strikes,
  depositRequired: false,
  depositBps: 0,
  bookingRestrictedUntil: null,
  participationSuspendedUntil: null,
  indefiniteSuspension: false,
  message: strikes > 0 ? 'Your two strikes are under review.' : null,
  incidents: const [],
  allowedAppealCategories: const [],
);
