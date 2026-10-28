import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/referrals/fieldrush_referral_screens.dart';
import 'package:field/src/referrals/fieldrush_referral_widgets.dart';
import 'package:field/src/referrals/referral_repository.dart';
import 'package:field/src/referrals/referrals.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _season = ReferralSeason(id: 's1', label: 'S0', ended: false);
const _me = ReferralPerson(
  id: 'me',
  name: 'Jordan A.',
  username: 'jalvarez',
  division: 5,
  ratingVisible: true,
);
const _marcus = ReferralPerson(
  id: 'marcus',
  name: 'Marcus K.',
  username: 'marcus.k',
  division: 4,
  ratingVisible: true,
);
const _sean = ReferralPerson(
  id: 'sean',
  name: 'Sean D.',
  username: 'sean_d',
  division: 2,
  ratingVisible: true,
);
final _now = DateTime.utc(2026, 10, 24, 12);

ReferralSummary _summary({
  ReferralPerson? referrer,
  bool canAdd = true,
  bool credited = false,
  Duration expiresIn = const Duration(days: 5),
  int count = 0,
  List<ReferralFriend> friends = const [],
  int? friendOffset,
}) => ReferralSummary(
  serverNow: _now,
  entryExpiresAt: _now.add(expiresIn),
  canAddCode: canAdd,
  ownCode: 'JALVAREZ',
  referrer: referrer,
  referrerCredited: credited,
  season: _season,
  referralCount: count,
  waitingCount: friends.where((friend) => !friend.qualified).length,
  rank: count >= 2 ? 12 : null,
  referrals: friends,
  referralsTotal: friends.length,
  referralsNextOffset: friendOffset,
);

ReferralLeaderboard _board({
  int count = 0,
  List<ReferralEntry> prizes = const [],
  List<ReferralEntry> entries = const [],
  int? next,
}) => ReferralLeaderboard(
  season: _season,
  prizeEntries: prizes,
  entries: entries,
  me: ReferralEntry(
    person: _me,
    referralCount: count,
    rank: count >= 2 ? 12 : null,
  ),
  qualifiedTotal: prizes.length + entries.length,
  nextOffset: next,
);

void main() {
  testWidgets('check confirms the exact person before permanent claim', (
    tester,
  ) async {
    final repo = _Repository();
    await _pumpCode(tester, repo);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('referral-check')),
    );
    expect(button.onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('referral-code-input')),
      'marcus.k',
    );
    await tester.pump();
    await tester.tap(find.text('Check code'));
    await tester.pumpAndSettle();
    expect(repo.checked, ['MARCUS.K']);
    expect(repo.claimed, isEmpty);
    expect(find.text('THIS CODE BELONGS TO'), findsOneWidget);
    expect(
      tester
          .getTopLeft(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'Back',
            ),
          )
          .dy,
      closeTo(18, .01),
    );
    expect(find.text('Marcus K.'), findsOneWidget);
    expect(find.text("Add Marcus's code"), findsOneWidget);
    await tester.tap(find.text("Add Marcus's code"));
    await tester.pumpAndSettle();
    expect(repo.claimed, [('MARCUS.K', 'marcus')]);
    expect(find.text('LINKED'), findsOneWidget);
    expect(
      find.text("Linked to your account. It can't be changed."),
      findsOneWidget,
    );
    expect(find.text('Check code'), findsNothing);
    expect(find.text('Share'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalid check preserves the entered code and allows correction',
    (tester) async {
      final repo = _Repository()
        ..checkError = StateError(
          'We couldn’t find that code. Check the spelling.',
        );
      await _pumpCode(tester, repo);
      await tester.enterText(find.byType(TextField), 'MARCUSX');
      await tester.pump();
      await tester.tap(find.text('Check code'));
      await tester.pumpAndSettle();
      expect(
        find.text('We couldn’t find that code. Check the spelling.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'MARCUSX',
      );
      repo.checkError = null;
      await tester.enterText(find.byType(TextField), 'marcus.k');
      await tester.pump();
      await tester.tap(find.text('Check code'));
      await tester.pumpAndSettle();
      expect(find.text('THIS CODE BELONGS TO'), findsOneWidget);
      expect(repo.claimed, isEmpty);
    },
  );

  testWidgets(
    'uncertain claim keeps confirmation and blocks duplicate submissions',
    (tester) async {
      final pending = Completer<ReferralSummary>();
      final repo = _Repository()..claimResult = pending.future;
      await _pumpCode(tester, repo);
      await tester.enterText(find.byType(TextField), 'marcus.k');
      await tester.pump();
      await tester.tap(find.text('Check code'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Add Marcus's code"));
      await tester.pump();
      final confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('referral-confirm')),
      );
      expect(confirm.onPressed, isNull);
      final back = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Back',
        ),
      );
      expect(back.onPressed, isNull);
      expect(repo.claimed, hasLength(1));
      pending.completeError(
        StateError('Could not confirm your referral. Try again.'),
      );
      await tester.pumpAndSettle();
      expect(find.text('MARCUS.K'), findsOneWidget);
      expect(find.text("Add Marcus's code"), findsOneWidget);
      expect(
        find.text('Could not confirm your referral. Try again.'),
        findsOneWidget,
      );
      repo.claimResult = null;
      await tester.tap(find.text("Add Marcus's code"));
      await tester.pumpAndSettle();
      expect(find.text('LINKED'), findsOneWidget);
      expect(repo.claimed, hasLength(2));
    },
  );

  testWidgets('retrospective claim shows the earned referral point', (
    tester,
  ) async {
    final repo = _Repository()
      ..summary = _summary(referrer: _marcus, canAdd: false, credited: true);
    await _pumpCode(tester, repo);
    expect(find.text('Marcus received 1 referral point.'), findsOneWidget);
    expect(
      find.text('Marcus gets credit after your first game.'),
      findsNothing,
    );
  });

  testWidgets(
    'expiry closes a code screen already open and keeps own sharing',
    (tester) async {
      final repo = _Repository()
        ..summary = _summary(expiresIn: const Duration(seconds: 2));
      var shares = 0;
      await _pumpCode(tester, repo, onShare: (_) async => shares++);
      expect(find.text('Check code'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Referral window closed'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Share'));
      await tester.pump();
      expect(shares, 1);
    },
  );

  testWidgets('You card expires without disabling share or leaderboard', (
    tester,
  ) async {
    var shares = 0;
    var boards = 0;
    await _pump(
      tester,
      Scaffold(
        body: FieldrushReferralCard(
          summary: _summary(expiresIn: const Duration(seconds: 2)),
          onShare: () => shares++,
          onOpenLeaderboard: () => boards++,
          onOpenCode: () {},
        ),
      ),
    );
    expect(find.text('Have a referral code?'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Referral window closed'), findsOneWidget);
    expect(find.text('Add ›'), findsNothing);
    await tester.tap(find.text('Share'));
    await tester.tap(find.text('0 friends played'));
    expect(shares, 1);
    expect(boards, 1);
  });

  testWidgets('read timeout gives retry rather than indefinite loading', (
    tester,
  ) async {
    final repo = _Repository()
      ..loadResult = Completer<ReferralSummary>().future;
    await _pumpCode(tester, repo);
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    repo.loadResult = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Check code'), findsOneWidget);
  });

  testWidgets('switching account discards an in-flight check and its draft', (
    tester,
  ) async {
    final pending = Completer<ReferralPerson>();
    final repo = _Repository()..checkResult = pending.future;
    await _pumpCode(tester, repo);
    await tester.enterText(find.byType(TextField), 'marcus.k');
    await tester.pump();
    await tester.tap(find.text('Check code'));
    await tester.pump();
    repo.user = 'different-user';
    repo.summary = _summary(canAdd: false, expiresIn: const Duration(days: -1));
    await tester.pumpWidget(
      _app(FieldrushReferralCodeScreen(repository: repo, onOpenPlayer: (_) {})),
    );
    await tester.pump();
    pending.complete(_marcus);
    await tester.pumpAndSettle();
    expect(find.text('Referral window closed'), findsOneWidget);
    expect(find.text('Marcus K.'), findsNothing);
    expect(repo.claimed, isEmpty);
  });

  testWidgets(
    'empty leaderboard shows real own progress without sample players',
    (tester) async {
      await _pumpBoard(tester, _Repository());
      expect(find.text('No players have qualified yet'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('2 more to qualify'), findsOneWidget);
      expect(find.text('Yusuf M.'), findsNothing);
      expect(find.text('SEASON 0 REFERRALS'), findsOneWidget);
      expect(find.textContaining('paid game'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unresolved prize place shows review instead of a promised award',
    (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: ReferralLeaderboardRow(
            entry: const ReferralEntry(
              person: _marcus,
              rank: 5,
              referralCount: 2,
              needsReview: true,
            ),
            onTap: () {},
            prize: true,
          ),
        ),
      );
      expect(find.text('Review'), findsOneWidget);
      expect(find.text('Awaiting admin review'), findsOneWidget);
      expect(find.text('\$50'), findsNothing);
    },
  );

  testWidgets('hidden divisions stay hidden in referral identity cards', (
    tester,
  ) async {
    await _pump(
      tester,
      Scaffold(
        body: ReferralPersonCard(
          person: const ReferralPerson(
            id: 'hidden',
            name: 'New P.',
            username: 'new_player',
            division: 2,
          ),
          onTap: () {},
        ),
      ),
    );
    expect(find.text('Division 2'), findsNothing);
    expect(find.text('@new_player'), findsOneWidget);
  });

  testWidgets('deleted referrer stays linked without a dead profile action', (
    tester,
  ) async {
    final repo = _Repository()
      ..summary = _summary(
        referrer: const ReferralPerson(
          id: 'deleted',
          name: 'Deleted player',
          username: '',
        ),
        canAdd: false,
        credited: true,
      );
    await _pumpCode(tester, repo);
    expect(find.text('LINKED'), findsOneWidget);
    expect(
      find.text('Your referrer received 1 referral point.'),
      findsOneWidget,
    );
    expect(find.text('@'), findsNothing);
    final tap = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('Deleted player'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(tap.onTap, isNull);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('paged leaderboard and referred list preserve previous rows', (
    tester,
  ) async {
    final repo = _Repository()
      ..summary = _summary(
        friends: [const ReferralFriend(person: _marcus, qualified: false)],
        friendOffset: 1,
      )
      ..board = _board(
        entries: [
          const ReferralEntry(person: _marcus, rank: 6, referralCount: 3),
        ],
        next: 1,
      );
    await _pumpBoard(tester, repo, height: 1400);
    await tester.tap(find.text('Show more').first);
    await tester.pumpAndSettle();
    expect(repo.boardOffsets, [0, 1]);
    expect(find.text('Sean D.'), findsOneWidget);
    await tester.tap(find.text('Show more').last);
    await tester.pumpAndSettle();
    expect(repo.friendOffsets, [1]);
    expect(find.text('Sean D.'), findsNWidgets(2));
    expect(find.text('Marcus K.'), findsNWidgets(2));
  });

  for (final width in [320.0, 430.0]) {
    testWidgets('referral screens fit width $width with larger text', (
      tester,
    ) async {
      final repo = _Repository()
        ..summary = _summary(referrer: _marcus, canAdd: false);
      await _pumpCode(tester, repo, width: width, textScale: 1.5);
      expect(tester.takeException(), isNull);
      await _pump(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: FieldrushReferralCard(
              summary: _summary(),
              onShare: () {},
              onOpenLeaderboard: () {},
              onOpenCode: () {},
            ),
          ),
        ),
        width: width,
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
      await _pumpBoard(tester, repo, width: width, textScale: 1.5);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('export referral design states when requested', (tester) async {
    final directory = Platform.environment['FIELDRUSH_REFERRAL_SCREENSHOT_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      for (final (family, asset) in [
        ('Outfit', 'assets/fonts/Outfit.ttf'),
        ('PlusJakartaSans', 'assets/fonts/PlusJakartaSans.ttf'),
      ]) {
        await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await Directory(directory).create(recursive: true);
    });
    final key = GlobalKey();
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 2);
        final data = await picture.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        picture.dispose();
      });
    }

    Future<void> screen(Widget child) =>
        _pump(tester, RepaintBoundary(key: key, child: child), height: 1000);
    final repo = _Repository();
    await screen(
      Scaffold(
        body: SingleChildScrollView(
          child: FieldrushReferralCard(
            summary: _summary(
              count: 2,
              friends: [
                const ReferralFriend(person: _marcus, qualified: false),
              ],
            ),
            onShare: () {},
            onOpenLeaderboard: () {},
            onOpenCode: () {},
          ),
        ),
      ),
    );
    await capture('you-referral-card');
    await screen(
      FieldrushReferralCodeScreen(
        repository: repo,
        onOpenPlayer: (_) {},
        onNavigateTab: (_) {},
      ),
    );
    await capture('code-entry');
    await tester.enterText(find.byType(TextField), 'marcus.k');
    await tester.pump();
    await tester.tap(find.text('Check code'));
    await capture('code-confirmation');
    await tester.tap(find.text("Add Marcus's code"));
    await capture('code-linked');
    await tester.pumpWidget(const SizedBox());
    repo.summary = _summary(canAdd: false, expiresIn: const Duration(days: -1));
    await screen(
      FieldrushReferralCodeScreen(
        repository: repo,
        onOpenPlayer: (_) {},
        onNavigateTab: (_) {},
      ),
    );
    await capture('code-expired');
    await tester.pumpWidget(const SizedBox());
    repo.summary = _summary();
    await screen(
      FieldrushReferralsScreen(
        repository: repo,
        onOpenPlayer: (_) {},
        onNavigateTab: (_) {},
      ),
    );
    await capture('leaderboard-empty');
    await tester.pumpWidget(const SizedBox());
    repo.board = _board(
      entries: [
        for (var i = 0; i < 6; i++)
          ReferralEntry(
            person: ReferralPerson(
              id: 'tie$i',
              name: 'Player $i',
              username: 'player$i',
            ),
            rank: 1,
            referralCount: 2,
            needsReview: true,
          ),
      ],
    );
    await screen(
      FieldrushReferralsScreen(
        repository: repo,
        onOpenPlayer: (_) {},
        onNavigateTab: (_) {},
      ),
    );
    expect(find.text('Prize places awaiting admin review.'), findsOneWidget);
    expect(find.text('No players have qualified yet'), findsNothing);
    await capture('leaderboard-admin-review');
    await tester.pumpWidget(const SizedBox());
    final people = [
      const ReferralPerson(
        id: 'ym',
        name: 'Yusuf M.',
        username: 'yusufm',
        division: 1,
        ratingVisible: true,
      ),
      const ReferralPerson(
        id: 'jn',
        name: 'Jake N.',
        username: 'jaken',
        division: 2,
        ratingVisible: true,
      ),
      const ReferralPerson(
        id: 'sa',
        name: 'Santi A.',
        username: 'santia',
        division: 3,
        ratingVisible: true,
      ),
      const ReferralPerson(
        id: 'tq',
        name: 'Tyler Q.',
        username: 'tylerq',
        division: 4,
        ratingVisible: true,
      ),
      const ReferralPerson(
        id: 'ml',
        name: 'Miles L.',
        username: 'milesl',
        division: 3,
        ratingVisible: true,
      ),
    ];
    repo.summary = _summary(
      count: 2,
      friends: [
        const ReferralFriend(person: _sean, qualified: true),
        const ReferralFriend(
          person: ReferralPerson(
            id: 'hunter',
            name: 'Hunter M.',
            username: 'hunterm',
          ),
          qualified: true,
        ),
        const ReferralFriend(
          person: ReferralPerson(
            id: 'zach',
            name: 'Zach Q.',
            username: 'zachq',
          ),
          qualified: false,
        ),
      ],
    );
    repo.board = _board(
      count: 2,
      prizes: [
        for (var i = 0; i < people.length; i++)
          ReferralEntry(
            person: people[i],
            rank: i + 1,
            referralCount: [14, 11, 9, 7, 6][i],
            prizeEligible: true,
          ),
      ],
      entries: [
        const ReferralEntry(
          person: ReferralPerson(
            id: 'kevin',
            name: 'Kevin D.',
            username: 'kevind',
            division: 4,
            ratingVisible: true,
          ),
          rank: 6,
          referralCount: 5,
        ),
        const ReferralEntry(person: _marcus, rank: 7, referralCount: 4),
      ],
    );
    await screen(
      FieldrushReferralsScreen(
        repository: repo,
        onOpenPlayer: (_) {},
        onNavigateTab: (_) {},
      ),
    );
    await capture('leaderboard-populated');
    await tester.drag(find.byType(ListView), const Offset(0, -540));
    await capture('leaderboard-populated-lower');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  theme: ThemeData(fontFamily: 'PlusJakartaSans'),
  builder: (context, widget) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: Theme(data: FieldrushAuthTheme.theme(context), child: widget!),
  ),
  home: child,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 430,
  double height = 1000,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(_app(child, textScale: textScale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 30));
}

Future<void> _pumpCode(
  WidgetTester tester,
  _Repository repo, {
  double width = 430,
  double textScale = 1,
  Future<void> Function(String)? onShare,
}) => _pump(
  tester,
  FieldrushReferralCodeScreen(
    repository: repo,
    onOpenPlayer: (_) {},
    onShare: onShare,
  ),
  width: width,
  textScale: textScale,
);

Future<void> _pumpBoard(
  WidgetTester tester,
  _Repository repo, {
  double width = 430,
  double height = 1000,
  double textScale = 1,
}) => _pump(
  tester,
  FieldrushReferralsScreen(repository: repo, onOpenPlayer: (_) {}),
  width: width,
  height: height,
  textScale: textScale,
);

class _Repository implements ReferralRepository {
  String user = 'me';
  ReferralSummary summary = _summary();
  ReferralLeaderboard board = _board();
  Future<ReferralSummary>? loadResult;
  Future<ReferralPerson>? checkResult;
  Future<ReferralSummary>? claimResult;
  Object? checkError;
  final List<String> checked = [];
  final List<(String, String)> claimed = [];
  final List<int> boardOffsets = [];
  final List<int> friendOffsets = [];

  @override
  String? get currentUserId => user;
  @override
  Future<ReferralSummary> load() async =>
      loadResult == null ? summary : await loadResult!;
  @override
  Future<ReferralPerson> checkCode(String code) async {
    checked.add(code);
    if (checkError != null) throw checkError!;
    return checkResult == null ? _marcus : await checkResult!;
  }

  @override
  Future<ReferralSummary> claimCode(
    String code, {
    required String expectedReferrerId,
  }) async {
    claimed.add((code, expectedReferrerId));
    if (claimResult != null) return await claimResult!;
    summary = _summary(referrer: _marcus, canAdd: false);
    return summary;
  }

  @override
  Future<ReferralLeaderboard> loadLeaderboard({
    int offset = 0,
    int limit = 50,
  }) async {
    boardOffsets.add(offset);
    if (offset == 0) return board;
    return _board(
      entries: [
        const ReferralEntry(person: _marcus, rank: 6, referralCount: 3),
        const ReferralEntry(person: _sean, rank: 7, referralCount: 2),
      ],
    );
  }

  @override
  Future<ReferralFriendsPage> loadReferredPlayers({
    int offset = 0,
    int limit = 50,
  }) async {
    friendOffsets.add(offset);
    return const ReferralFriendsPage(
      entries: [
        ReferralFriend(person: _marcus, qualified: false),
        ReferralFriend(person: _sean, qualified: true),
      ],
      total: 2,
    );
  }
}
