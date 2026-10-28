import 'dart:async';

import 'package:field/src/core/read_timeout.dart';
import 'package:field/src/fixtures/fieldrush_fixture_page.dart';
import 'package:field/src/leaderboard/fieldrush_leaderboard_widgets.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/open_queue/fieldrush_booking_flow.dart';
import 'package:field/src/open_queue/fieldrush_checkout_sheet.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/fieldrush_game_loading.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/ui/field_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(FieldSkeleton), findsWidgets);
    expect(tester.takeException(), isNull);
    // A slow server must not leave an animation scheduling frames forever.
    expect(tester.binding.hasScheduledFrame, isFalse);
  }

  Future<void> disposePendingRead(WidgetTester tester) async {
    // These visual tests intentionally hold the request open. Dispose the view
    // before letting its read deadline expire so no timeout timer is left behind.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(fieldReadTimeout);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('fixtures skeleton resolves into a real empty state', (
    tester,
  ) async {
    final repository = _PendingGames();
    await show(tester, FieldrushFixturePage(repository: repository));
    expect(
      find.byKey(const ValueKey('fixtures-loading-skeleton')),
      findsOneWidget,
    );
    repository.games.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('No games yet'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixtures-loading-skeleton')),
      findsNothing,
    );
  });

  testWidgets('rankings show standing, podium and list placeholders', (
    tester,
  ) async {
    await show(
      tester,
      FieldrushLeaderboardContent(
        season: activeLeaderboardSeason,
        onSeason: (_) {},
        players: const [],
        neighbors: const [],
        currentRating: null,
        currentProfileId: 'me',
        totalCount: null,
        hasMore: false,
        visibleCount: 0,
        loading: true,
        loadingMore: false,
        error: null,
        pageError: null,
        clans: false,
        onBoard: (_) {},
        onPlayer: (_) {},
        onSearch: () {},
        onRefresh: () async {},
        onMore: () {},
        onCollapse: () {},
      ),
    );
    expect(
      find.byKey(const ValueKey('ranks-loading-skeleton')),
      findsOneWidget,
    );
  });

  testWidgets('game overview loading keeps a hero and lineup skeleton', (
    tester,
  ) async {
    await show(
      tester,
      FieldrushGameDetailScreen(repository: _PendingGames(), gameId: 'game'),
    );
    expect(find.byType(FieldrushGameLoading), findsOneWidget);
    await disposePendingRead(tester);
  });

  testWidgets('position flow uses placeholders before availability arrives', (
    tester,
  ) async {
    await show(tester, FieldrushBookingFlow(repository: _PendingGames()));
    expect(find.byType(FieldLoadingContent), findsOneWidget);
    await disposePendingRead(tester);
  });

  testWidgets('checkout keeps price shape and cannot pay before a quote', (
    tester,
  ) async {
    await show(
      tester,
      FieldrushCheckoutSheet(
        repository: _PendingGames(),
        game: _game(),
        role: OpenQueueRole.defender,
      ),
    );
    expect(find.byType(FieldrushPriceLoading), findsOneWidget);
    final pay = tester.widget<FilledButton>(
      find.byKey(const ValueKey('open-queue-confirm-payment')),
    );
    expect(pay.onPressed, isNull);
    await disposePendingRead(tester);
  });
}

OpenQueueGame _game() => OpenQueueGame(
  id: 'game',
  status: 'OPEN',
  venue: 'Reach 11',
  startsAt: DateTime.now().add(const Duration(days: 2)),
  endsAt: DateTime.now().add(const Duration(days: 2, hours: 1)),
  timezone: 'America/Phoenix',
  currency: 'USD',
  priceFils: 13000,
  ageLabel: '18+',
  capacity: 14,
  confirmedCount: 0,
  spots: const {
    OpenQueueRole.goalkeeper: 2,
    OpenQueueRole.defender: 6,
    OpenQueueRole.attacker: 6,
  },
);

class _PendingGames extends Fake
    implements OpenQueueRepository, OpenQueueBookingCostPreviewRepository {
  final games = Completer<List<OpenQueueGame>>();
  @override
  Future<List<OpenQueueGame>> listGames() => games.future;
  @override
  Future<List<OpenQueueGame>> listFixtureGames() => games.future;
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => [];
  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) =>
      Completer<OpenQueueMatchDetail>().future;
  @override
  Future<OpenQueueBookingCostPreview> previewBookingCost({
    required String gameId,
    required OpenQueueRole role,
  }) => Completer<OpenQueueBookingCostPreview>().future;
}
