import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/profile/fieldrush_cancelled_game_screen.dart';
import 'package:field/src/profile/fieldrush_match_history_screen.dart';
import 'package:field/src/profile/player_history_repository.dart';
import 'package:field/src/profile/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Fieldrush cancellations join history without changing record', (
    tester,
  ) async {
    final repository = _HistoryRepository([_cancelled()]);
    var findAnother = 0;
    await tester.pumpWidget(_app(repository, onFind: () => findAnother++));
    await tester.pumpAndSettle();
    expect(find.text('1 played · 1W 0D 0L'), findsOneWidget);
    expect(find.text('Tue, Sep 1 · Cancelled'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(repository.cancellationCalls, 1);

    await tester.tap(find.byKey(const Key('you-cancelled-history-cancelled')));
    await tester.pumpAndSettle();
    expect(find.text('CANCELLED'), findsOneWidget);
    expect(find.text('by Fieldrush'), findsOneWidget);
    expect(find.text('Tue, Sep 1'), findsOneWidget);
    expect(find.text('8:30 PM · Reach 11 Fields · Field 2'), findsOneWidget);
    expect(
      find.text('Lightning in the area. The city closed the fields.'),
      findsOneWidget,
    );
    expect(find.text(r'$8.00 back to Visa'), findsOneWidget);
    expect(find.text('No change'), findsNWidgets(2));
    expect(find.text('Kept'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancelled-game-find-another')));
    expect(findAnother, 1);
  });

  testWidgets('public match history never requests private cancellations', (
    tester,
  ) async {
    final repository = _HistoryRepository([_cancelled()]);
    await tester.pumpWidget(_app(repository, playerName: 'Another player'));
    await tester.pumpAndSettle();
    expect(repository.cancellationCalls, 0);
    expect(find.text('1 played · 1W 0D 0L'), findsOneWidget);
    expect(find.textContaining('Cancelled'), findsNothing);
    expect(find.textContaining('Refund'), findsNothing);
  });

  testWidgets('cancelled-only history has no played or win/loss credit', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_HistoryRepository([_cancelled()]), empty: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('0 played · 0W 0D 0L'), findsOneWidget);
    expect(find.text('Tue, Sep 1 · Cancelled'), findsOneWidget);
    expect(find.textContaining('will appear here'), findsNothing);
  });

  testWidgets('failed private history retains played matches and retries', (
    tester,
  ) async {
    final repository = _HistoryRepository([_cancelled()])..fail = true;
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();
    expect(find.text('1 played · 1W 0D 0L'), findsOneWidget);
    expect(find.byKey(const Key('you-history-played')), findsOneWidget);
    expect(find.text('Could not load cancelled games.'), findsOneWidget);
    repository.fail = false;
    await tester.tap(find.byKey(const Key('retry-cancelled-history')));
    await tester.pumpAndSettle();
    expect(find.text('Could not load cancelled games.'), findsNothing);
    expect(find.text('Tue, Sep 1 · Cancelled'), findsOneWidget);
  });

  testWidgets('stalled cancellation reads time out without trapping history', (
    tester,
  ) async {
    final stalled = Completer<PlayerHistoryPage<PlayerCancelledGame>>();
    final repository = _HistoryRepository([_cancelled()])..barrier = stalled;
    await tester.pumpWidget(_app(repository));
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('Could not load cancelled games.'), findsOneWidget);
    repository.barrier = null;
    await tester.tap(find.byKey(const Key('retry-cancelled-history')));
    await tester.pumpAndSettle();
    stalled.complete(PlayerHistoryPage(items: [_cancelled(id: 'stale')]));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('you-cancelled-history-stale')), findsNothing);
    expect(
      find.byKey(const Key('you-cancelled-history-cancelled')),
      findsOneWidget,
    );
  });

  testWidgets('older cancellations page into the same chronology', (
    tester,
  ) async {
    final rows = [
      for (var i = 0; i < 35; i++)
        _cancelled(id: 'cancel-$i', startsAt: DateTime.utc(2026, 9, 30 - i, 4)),
    ];
    final repository = _HistoryRepository(rows);
    await tester.pumpWidget(_app(repository, empty: true));
    await tester.pumpAndSettle();
    expect(repository.cancellationCalls, 1);
    Future<void> older() async {
      await tester.scrollUntilVisible(find.text('Show older games'), 400);
      await tester.tap(find.text('Show older games'));
      await tester.pumpAndSettle();
    }

    await older();
    expect(repository.cancellationCalls, 1);
    await older();
    expect(repository.cancellationCalls, 2);
    expect(repository.cursors.last?.id, 'cancel-19');
    await older();
    expect(repository.cancellationCalls, 2);
    expect(find.text('Show older games'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a previous owner response cannot replace the current history', (
    tester,
  ) async {
    final pending = Completer<PlayerHistoryPage<PlayerCancelledGame>>();
    final old = _HistoryRepository([])..barrier = pending;
    await tester.pumpWidget(_app(old));
    await tester.pump();
    await tester.pumpWidget(
      _app(_HistoryRepository([_cancelled(id: 'new-owner')])),
    );
    await tester.pumpAndSettle();
    pending.complete(PlayerHistoryPage(items: [_cancelled(id: 'old-owner')]));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('you-cancelled-history-new-owner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('you-cancelled-history-old-owner')),
      findsNothing,
    );
  });

  testWidgets('cancelled receipts preserve placement rating privacy', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FieldrushCancelledGameScreen(
          game: _cancelled(rating: 12, ratingHidden: true),
        ),
      ),
    );
    expect(find.text('Placement in progress'), findsOneWidget);
    expect(find.text('+12 SR'), findsNothing);
  });

  testWidgets('administrative consequences are shown rather than invented', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FieldrushCancelledGameScreen(
          game: _cancelled(rating: 12, strikes: 1, streak: false),
        ),
      ),
    );
    expect(find.text('+12 SR'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('Not kept'), findsOneWidget);
    expect(find.text('No change'), findsNothing);
  });

  testWidgets(
    'unknown dates and consequences are not presented as guarantees',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FieldrushCancelledGameScreen(
            game: _cancelled(
              zone: 'Unknown/location',
              rating: null,
              strikes: null,
              streak: null,
            ),
          ),
        ),
      );
      expect(find.text('Date unavailable'), findsOneWidget);
      expect(find.textContaining('Time unavailable'), findsOneWidget);
      expect(find.text('Not recorded'), findsNWidgets(3));
      expect(find.text('Kept'), findsNothing);
    },
  );

  testWidgets('cancellation receipt fits narrow screens with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.7)),
          child: child!,
        ),
        home: FieldrushCancelledGameScreen(game: _cancelled()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Find another game'), 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('render cancelled history and receipt with bundled fonts', (
    tester,
  ) async {
    final directory = Platform.environment['FIELDRUSH_HISTORY_SCREENSHOT_DIR'];
    if (directory == null) return;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    final key = GlobalKey();
    await tester.pumpWidget(
      _app(_HistoryRepository([_cancelled()]), boundary: key, onFind: () {}),
    );
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        await Directory(directory).create(recursive: true);
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('cancelled-match-history');
    await tester.tap(find.byKey(const Key('you-cancelled-history-cancelled')));
    await tester.pumpAndSettle();
    await capture('cancelled-game');
  });
}

Widget _app(
  _HistoryRepository repository, {
  bool empty = false,
  String? playerName,
  VoidCallback? onFind,
  GlobalKey? boundary,
}) => MaterialApp(
  builder: boundary == null
      ? null
      : (_, child) => RepaintBoundary(key: boundary, child: child!),
  home: FieldrushMatchHistoryScreen(
    profile: _profile(empty: empty),
    onOpenGame: (_) async {},
    historyRepository: repository,
    playerName: playerName,
    onFindAnotherGame: onFind,
  ),
);

PlayerProfile _profile({bool empty = false}) => PlayerProfile(
  id: 'me',
  displayName: 'Alex',
  username: 'alex',
  bio: '',
  followingCount: 0,
  fansCount: 0,
  appearances: empty ? 0 : 1,
  goals: 0,
  assists: 0,
  highlights: const [],
  career: const [],
  previousGames: [
    if (!empty)
      ProfilePreviousGame.fromJson({
        'id': 'played',
        'source_type': 'OPEN_QUEUE',
        'played_at': '2026-09-05T03:30:00Z',
        'timezone': 'America/Phoenix',
        'white_score': 1,
        'black_score': 0,
        'player_side': 'WHITE',
      }),
  ],
);

PlayerCancelledGame _cancelled({
  String id = 'cancelled',
  DateTime? startsAt,
  String zone = 'America/Phoenix',
  int? rating = 0,
  int? strikes = 0,
  bool? streak = true,
  bool ratingHidden = false,
}) => PlayerCancelledGame(
  gameId: id,
  bookingId: 'booking-$id',
  startsAt: startsAt ?? DateTime.utc(2026, 9, 2, 4),
  endsAt: (startsAt ?? DateTime.utc(2026, 9, 2, 4)).add(
    const Duration(hours: 1),
  ),
  cancelledAt: DateTime.utc(2026, 9, 1, 18),
  venue: 'Reach 11 Fields · Field 2',
  timezone: zone,
  reason: 'Lightning in the area. The city closed the fields.',
  amountPaidMinor: 800,
  refundedMinor: 800,
  paymentMethod: 'VISA',
  ratingChange: rating,
  ratingHidden: ratingHidden,
  strikeChange: strikes,
  streakKept: streak,
);

class _HistoryRepository implements PlayerHistoryRepository {
  _HistoryRepository(this.rows);
  final List<PlayerCancelledGame> rows;
  bool fail = false;
  int cancellationCalls = 0;
  final cursors = <PlayerHistoryCursor?>[];
  Completer<PlayerHistoryPage<PlayerCancelledGame>>? barrier;

  @override
  Future<PlayerHistoryPage<PlayerCancelledGame>> getCancelledGames({
    PlayerHistoryCursor? cursor,
    int limit = 30,
  }) async {
    cancellationCalls++;
    cursors.add(cursor);
    if (fail) throw StateError('Network unavailable');
    if (barrier != null) return barrier!.future;
    final start = cursor == null
        ? 0
        : rows.indexWhere((row) => row.id == cursor.id) + 1;
    final items = rows.skip(start).take(limit).toList();
    return PlayerHistoryPage(
      items: items,
      nextCursor: start + items.length >= rows.length
          ? null
          : PlayerHistoryCursor(
              createdAt: items.last.startsAt,
              id: items.last.id,
            ),
    );
  }

  @override
  Future<PlayerHistoryPage<PlayerPaymentHistoryEntry>> getPayments({
    PlayerHistoryCursor? cursor,
    int limit = 30,
  }) async => const PlayerHistoryPage(items: []);
}
