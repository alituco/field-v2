import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/profile/fieldrush_payment_history_screen.dart';
import 'package:field/src/profile/fieldrush_you_settings.dart';
import 'package:field/src/profile/player_history_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;

void main() {
  tz.initializeTimeZones();

  testWidgets('methods show three recent payments and open all month groups', (
    tester,
  ) async {
    final repository = _Repository([
      _entry('newest'),
      _entry('second'),
      _entry('third'),
      _entry('older', paidAt: DateTime.utc(2026, 8, 20, 12)),
    ]);
    await _show(tester, YouPaymentMethodsScreen(historyRepository: repository));
    expect(find.text('Visa & Mastercard'), findsOneWidget);
    expect(find.text('PAYMENT HISTORY'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('payment-history-newest')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('payment-history-third')), findsOneWidget);
    expect(find.byKey(const ValueKey('payment-history-older')), findsNothing);
    expect(repository.requests.single.limit, 3);

    await tester.ensureVisible(find.byKey(const ValueKey('see-all-payments')));
    await tester.tap(find.byKey(const ValueKey('see-all-payments')));
    await tester.pumpAndSettle();
    expect(find.text('Payment history'), findsOneWidget);
    expect(find.text('SEPTEMBER 2026'), findsOneWidget);
    expect(find.text('AUGUST 2026'), findsOneWidget);
    expect(find.byKey(const ValueKey('payment-history-older')), findsOneWidget);
    expect(repository.requests.map((r) => r.limit), [3, 30]);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Payment methods'), findsOneWidget);
    expect(repository.requests.map((r) => r.limit), [3, 30, 3]);
    expect(find.text('Add a card'), findsNothing);
    expect(find.textContaining('4242'), findsNothing);
  });

  testWidgets('only settled full refunds strike the original charge amount', (
    tester,
  ) async {
    final repository = _Repository([
      _entry('full', refundedMinor: 1300, gameCancelled: true),
      _entry('partial', refundedMinor: 650),
      _entry('pending', pendingRefundMinor: 1300),
      _entry('failed', failedRefundMinor: 1300),
      _entry('review', refundNeedsReview: true),
      _entry('external-full', refundedMinor: 1300, refundNeedsReview: true),
    ]);
    await _show(tester, FieldrushPaymentHistoryScreen(repository: repository));
    expect(find.text('Cancelled · back to Visa'), findsOneWidget);
    expect(find.text(r'$6.50 refunded to Visa'), findsOneWidget);
    expect(find.text('REFUNDED'), findsNWidgets(2));
    expect(find.text('PARTIALLY REFUNDED'), findsOneWidget);
    expect(find.text('REFUND PENDING'), findsOneWidget);
    expect(find.text('REFUND NEEDS REVIEW'), findsNWidgets(2));
    for (final id in ['full', 'external-full']) {
      final amount = tester.widget<Text>(
        find.byKey(ValueKey('payment-history-amount-$id')),
      );
      expect(amount.data, r'$13.00');
      expect(amount.style?.decoration, TextDecoration.lineThrough);
    }
    for (final id in ['partial', 'pending', 'failed', 'review']) {
      final amount = tester.widget<Text>(
        find.byKey(ValueKey('payment-history-amount-$id')),
      );
      expect(amount.style?.decoration, TextDecoration.none);
    }
  });

  testWidgets(
    'legacy refunds name Field Wallet without claiming a card refund',
    (tester) async {
      await _show(
        tester,
        FieldrushPaymentHistoryScreen(
          repository: _Repository([
            _entry(
              'legacy',
              currency: 'BHD',
              amountMinor: 1500,
              refundedMinor: 1500,
              refundDestination: 'FIELD_WALLET',
            ),
          ]),
        ),
      );
      expect(find.text('Refunded to Field Wallet'), findsOneWidget);
      expect(find.textContaining('1.500'), findsOneWidget);
      expect(find.textContaining('4242'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a stalled history read does not block methods and can retry', (
    tester,
  ) async {
    final pending = Completer<PlayerHistoryPage<PlayerPaymentHistoryEntry>>();
    final repository = _Repository([_entry('fresh')]);
    repository.onPayments = (_, _) => pending.future;
    await tester.pumpWidget(
      MaterialApp(home: YouPaymentMethodsScreen(historyRepository: repository)),
    );
    await tester.pump();
    expect(find.text('Visa & Mastercard'), findsOneWidget);
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.textContaining('That took too long'), findsOneWidget);
    expect(find.text('Visa & Mastercard'), findsOneWidget);
    repository.onPayments = null;
    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('payment-history-fresh')), findsOneWidget);
    pending.complete(PlayerHistoryPage(items: [_entry('stale')]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('payment-history-stale')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty history contains no invented transactions or saved cards',
    (tester) async {
      await _show(
        tester,
        YouPaymentMethodsScreen(historyRepository: _Repository(const [])),
      );
      expect(find.text('Your payments will appear here.'), findsOneWidget);
      expect(find.byKey(const ValueKey('see-all-payments')), findsOneWidget);
      expect(find.text('REFUNDED'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Add a card'), findsNothing);
    },
  );

  testWidgets(
    'scrolling loads older payments with its cursor and deduplicates',
    (tester) async {
      final repository = _Repository(_many(31))..overlapNextPage = true;
      await _show(
        tester,
        FieldrushPaymentHistoryScreen(repository: repository),
      );
      expect(repository.requests, hasLength(1));
      await tester.drag(find.byType(ListView), const Offset(0, -5000));
      await tester.pumpAndSettle();
      expect(repository.requests, hasLength(2));
      expect(repository.requests.last.cursor?.id, 'pay-29');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('payment-history-pay-30')),
        200,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('payment-history-pay-30')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('payment-history-pay-29')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed later page retains payments and retries that same page',
    (tester) async {
      final repository = _Repository(_many(31))..failLaterPages = true;
      await _show(
        tester,
        FieldrushPaymentHistoryScreen(repository: repository),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -5000));
      await tester.pumpAndSettle();
      expect(repository.requests, hasLength(2));
      expect(
        find.byKey(const ValueKey('payment-history-pay-29')),
        findsOneWidget,
      );
      repository.failLaterPages = false;
      await tester.ensureVisible(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(repository.requests, hasLength(3));
      expect(repository.requests[1].cursor?.id, 'pay-29');
      expect(repository.requests[2].cursor?.id, 'pay-29');
      expect(
        find.byKey(const ValueKey('payment-history-pay-30')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'replacing the repository immediately discards old owner history',
    (tester) async {
      final first = _Repository([_entry('first-owner')]);
      final second = _Repository([_entry('second-owner')]);
      final pending = Completer<PlayerHistoryPage<PlayerPaymentHistoryEntry>>();
      second.onPayments = (_, _) => pending.future;
      await _show(tester, FieldrushPaymentHistoryScreen(repository: first));
      expect(
        find.byKey(const ValueKey('payment-history-first-owner')),
        findsOneWidget,
      );
      await tester.pumpWidget(
        MaterialApp(home: FieldrushPaymentHistoryScreen(repository: second)),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('payment-history-first-owner')),
        findsNothing,
      );
      pending.complete(PlayerHistoryPage(items: second.entries));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('payment-history-second-owner')),
        findsOneWidget,
      );
    },
  );

  testWidgets('narrow enlarged payment rows stay readable without overflow', (
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
          ).copyWith(textScaler: TextScaler.linear(1.8)),
          child: child!,
        ),
        home: FieldrushPaymentHistoryScreen(
          repository: _Repository([
            _entry('large-review', refundNeedsReview: true),
            _entry('large-partial', refundedMinor: 650),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('REFUND NEEDS REVIEW'), findsOneWidget);
    expect(find.text('PARTIALLY REFUNDED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('different years keep separate month headings', (tester) async {
    await _show(
      tester,
      FieldrushPaymentHistoryScreen(
        repository: _Repository([
          _entry('current'),
          _entry('previous', paidAt: DateTime.utc(2025, 9, 20, 12)),
        ]),
      ),
    );
    expect(find.text('SEPTEMBER 2026'), findsOneWidget);
    expect(find.text('SEPTEMBER 2025'), findsOneWidget);
  });

  testWidgets(
    'render payment history with bundled fonts for review',
    (tester) async {
      final directory =
          Platform.environment['FIELDRUSH_HISTORY_SCREENSHOT_DIR'];
      if (directory == null) return;
      await tester.runAsync(() async {
        for (final family in ['Outfit', 'PlusJakartaSans']) {
          final loader = FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/$family.ttf'));
          await loader.load();
        }
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository([
        for (final sample in [
          (id: 'charge-1', day: 8, month: 9, refunded: false),
          (id: 'charge-2', day: 1, month: 9, refunded: true),
          (id: 'charge-3', day: 25, month: 8, refunded: false),
          (id: 'charge-4', day: 21, month: 8, refunded: false),
        ])
          PlayerPaymentHistoryEntry(
            id: sample.id,
            paidAt: DateTime.utc(2026, sample.month, sample.day, 12),
            amountMinor: 800,
            paymentMethod: 'VISA',
            gameStartsAt: DateTime.utc(2026, sample.month, sample.day, 20),
            timezone: 'America/Phoenix',
            refundedMinor: sample.refunded ? 800 : 0,
            gameCancelled: sample.refunded,
          ),
      ]);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              RepaintBoundary(key: boundaryKey, child: child),
          home: YouPaymentMethodsScreen(historyRepository: repository),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          await Directory(directory).create(recursive: true);
          final bitmap = await boundary.toImage(pixelRatio: 2);
          final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$directory/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          bitmap.dispose();
        });
      }

      await capture('payment-methods');
      await tester.ensureVisible(
        find.byKey(const ValueKey('see-all-payments')),
      );
      await tester.tap(find.byKey(const ValueKey('see-all-payments')));
      await tester.pumpAndSettle();
      await capture('payment-history');
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );
}

Future<void> _show(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

List<PlayerPaymentHistoryEntry> _many(int count) => [
  for (var i = 0; i < count; i++)
    _entry(
      'pay-$i',
      paidAt: DateTime.utc(2026, 9, 30, 12).subtract(Duration(days: i)),
    ),
];

PlayerPaymentHistoryEntry _entry(
  String id, {
  DateTime? paidAt,
  int amountMinor = 1300,
  String currency = 'USD',
  int refundedMinor = 0,
  int pendingRefundMinor = 0,
  int failedRefundMinor = 0,
  bool refundNeedsReview = false,
  bool gameCancelled = false,
  String refundDestination = 'ORIGINAL_PAYMENT_METHOD',
}) => PlayerPaymentHistoryEntry(
  id: id,
  paidAt: paidAt ?? DateTime.utc(2026, 9, 20, 12),
  amountMinor: amountMinor,
  currency: currency,
  paymentMethod: 'VISA',
  gameStartsAt: DateTime.utc(2026, 9, 22, 20),
  timezone: 'America/Phoenix',
  refundedMinor: refundedMinor,
  pendingRefundMinor: pendingRefundMinor,
  failedRefundMinor: failedRefundMinor,
  refundNeedsReview: refundNeedsReview,
  gameCancelled: gameCancelled,
  refundDestination: refundDestination,
);

class _Repository implements PlayerHistoryRepository {
  _Repository(this.entries);

  final List<PlayerPaymentHistoryEntry> entries;
  final requests = <({PlayerHistoryCursor? cursor, int limit})>[];
  bool failLaterPages = false;
  bool overlapNextPage = false;
  Future<PlayerHistoryPage<PlayerPaymentHistoryEntry>> Function(
    PlayerHistoryCursor?,
    int,
  )?
  onPayments;

  @override
  Future<PlayerHistoryPage<PlayerPaymentHistoryEntry>> getPayments({
    PlayerHistoryCursor? cursor,
    int limit = 30,
  }) async {
    requests.add((cursor: cursor, limit: limit));
    if (onPayments != null) return onPayments!(cursor, limit);
    if (cursor != null && failLaterPages) {
      throw StateError('History unavailable');
    }
    final start = cursor == null
        ? 0
        : entries.indexWhere((e) => e.id == cursor.id) +
              (overlapNextPage ? 0 : 1);
    final items = entries.skip(start).take(limit).toList();
    return PlayerHistoryPage(
      items: items,
      nextCursor: start + items.length < entries.length
          ? PlayerHistoryCursor(createdAt: items.last.paidAt, id: items.last.id)
          : null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
