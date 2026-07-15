import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_booking_screen.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/open_queue/open_queue_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Go back home clears the open queue navigation stack', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakeOpenQueueRepository();
    final booking = _booking();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (context) => Scaffold(
                        body: Center(
                          child: FilledButton(
                            onPressed: () {
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => OpenQueueBookingScreen(
                                    repository: repository,
                                    booking: booking,
                                    newlyBooked: true,
                                  ),
                                ),
                              );
                            },
                            child: const Text('Reserve spot'),
                          ),
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('Open queue'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open queue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reserve spot'));
    await tester.pumpAndSettle();

    expect(find.text('MATCH PENDING'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('booking-player-status-card')),
      findsOneWidget,
    );
    expect(find.text('10'), findsOneWidget);
    expect(find.text('/ 12'), findsOneWidget);
    expect(find.text('PLAYERS CONFIRMED'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('booking-average-player-rating')),
      findsNothing,
    );
    expect(
      find.text('2 more players needed to confirm this match.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('match-day-kit-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('kit-instruction')), findsNothing);
    expect(find.byKey(const ValueKey('kit-assignment-updating')), findsNothing);

    final homeButton = find.widgetWithText(FilledButton, 'Go back home');
    await _bringAboveFloatingNav(tester, homeButton);
    await tester.tap(homeButton);
    await tester.pumpAndSettle();

    expect(find.text('Open queue'), findsOneWidget);
    expect(find.text('Reserve spot'), findsNothing);
    expect(find.text('MATCH PENDING'), findsNothing);
  });

  testWidgets('Go back home after checkout keeps the app root route alive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakeOpenQueueRepository();
    var selectedTab = 1;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            if (selectedTab == 0) {
              return const Scaffold(
                backgroundColor: Colors.white,
                body: Center(child: Text('HOME PAGE')),
              );
            }
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => OpenQueueReviewScreen(
                          repository: repository,
                          game: _booking().game,
                          role: OpenQueueRole.defender,
                          onNavigateTab: (index) {
                            setState(() => selectedTab = index);
                          },
                        ),
                      ),
                    );
                  },
                  child: const Text('Start booking'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Start booking'));
    await tester.pumpAndSettle();
    final checkoutButton = find.widgetWithText(
      FilledButton,
      'Continue to Test Checkout',
    );
    await tester.scrollUntilVisible(
      checkoutButton,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(checkoutButton);
    await tester.pumpAndSettle();
    final bookButton = find.widgetWithText(
      FilledButton,
      'Book Test Spot · 3 BHD',
    );
    await tester.scrollUntilVisible(
      bookButton,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(bookButton);
    await tester.pumpAndSettle();

    final homeButton = find.widgetWithText(FilledButton, 'Go back home');
    await _bringAboveFloatingNav(tester, homeButton);
    await tester.tap(homeButton);
    await tester.pumpAndSettle();

    expect(find.text('HOME PAGE'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('assigned booking shows persisted team averages and spread', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueBookingScreen(
          repository: _FakeOpenQueueRepository(),
          booking: _booking(assigned: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('WHITE TEAM'), findsOneWidget);
    expect(find.text('WEAR WHITE'), findsOneWidget);
    expect(find.byKey(const ValueKey('kit-instruction')), findsOneWidget);
    expect(find.text('MATCH CONFIRMED'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('/ 12'), findsOneWidget);
    expect(
      find.text('Full squad confirmed. This match is on.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('booking-average-player-rating')),
      findsOneWidget,
    );
    expect(find.text('1210 AVG PLAYER RATING'), findsOneWidget);
    expect(find.text('White 1211 · Black 1209 · 2 SR spread'), findsOneWidget);
    final teamInfo = find.text(
      'Teams assigned. The two team averages are only 2 SR apart.',
    );
    await _bringAboveFloatingNav(tester, teamInfo);
    expect(teamInfo, findsOneWidget);
    expect(find.textContaining("We'll notify you"), findsNothing);
  });

  testWidgets('black team assignment clearly says what kit to wear', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueBookingScreen(
          repository: _FakeOpenQueueRepository(),
          booking: _booking(assigned: true, assignedTeam: openQueueBlackTeamId),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('BLACK TEAM'), findsOneWidget);
    expect(find.text('WEAR BLACK'), findsOneWidget);
    expect(find.text('WEAR WHITE'), findsNothing);
    expect(find.byKey(const ValueKey('kit-instruction')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending booking hides stale team and rating snapshots', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueBookingScreen(
          repository: _FakeOpenQueueRepository(),
          booking: _booking(staleAssignment: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MATCH PENDING'), findsOneWidget);
    expect(find.text('WHITE TEAM'), findsNothing);
    expect(find.text('WEAR WHITE'), findsNothing);
    expect(find.byKey(const ValueKey('kit-instruction')), findsNothing);
    expect(
      find.byKey(const ValueKey('booking-average-player-rating')),
      findsNothing,
    );
    expect(find.textContaining('White 1211'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('booking details refreshes the live player count on entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueBookingScreen(
          repository: _FakeOpenQueueRepository(
            upcomingBooking: _booking(assigned: true),
          ),
          booking: _booking(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MATCH CONFIRMED'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('WEAR WHITE'), findsOneWidget);
    expect(
      find.text('2 more players needed to confirm this match.'),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('refresh-booking-player-count')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling a booking uses the themed refund confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakeOpenQueueRepository(
      cancellationPreview: OpenQueueCancellationPreview(
        canCancel: true,
        refundPercent: 50,
        refundAmountFils: 1500,
        refundCutoffAt: DateTime.now().add(const Duration(days: 1)),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueBookingScreen(
          repository: repository,
          booking: _booking(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cancelBooking = find.text('Cancel booking');
    await _bringAboveFloatingNav(tester, cancelBooking);
    await tester.tap(cancelBooking);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('field-confirmation-dialog')),
      findsOneWidget,
    );
    expect(find.text('Cancel your spot?'), findsOneWidget);
    expect(find.text('50% refund · 1.500 BHD refund'), findsOneWidget);
    expect(find.text('Keep my spot'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('field-confirmation-cancel')));
    await tester.pumpAndSettle();

    expect(repository.cancelCalls, 0);
    expect(find.text('BOOKING DETAILS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _bringAboveFloatingNav(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      240,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await Scrollable.ensureVisible(
    tester.element(target),
    alignment: 0.7,
    duration: Duration.zero,
  );
  await tester.pump();
}

OpenQueueBooking _booking({
  bool assigned = false,
  bool staleAssignment = false,
  String assignedTeam = openQueueWhiteTeamId,
}) {
  final hasAssignmentMetadata = assigned || staleAssignment;
  final startsAt = DateTime.now().add(const Duration(days: 2));
  final game = OpenQueueGame(
    id: 'game-1',
    status: assigned ? 'FULL' : 'OPEN',
    venue: 'TFA, Saar',
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: 'Ages 16-20',
    capacity: 12,
    confirmedCount: assigned ? 12 : 10,
    spots: const {
      OpenQueueRole.goalkeeper: 1,
      OpenQueueRole.defender: 1,
      OpenQueueRole.midfielder: 0,
      OpenQueueRole.attacker: 0,
    },
    whiteAverageSr: hasAssignmentMetadata ? 1211 : null,
    blackAverageSr: hasAssignmentMetadata ? 1209 : null,
    matchAverageSr: hasAssignmentMetadata ? 1210 : null,
    teamSrSpread: hasAssignmentMetadata ? 2 : null,
    teamsAssignedAt: hasAssignmentMetadata ? DateTime.now() : null,
  );
  return OpenQueueBooking(
    id: 'booking-1',
    gameId: game.id,
    profileId: 'profile-1',
    role: OpenQueueRole.defender,
    status: 'CONFIRMED',
    amountPaidFils: game.priceFils,
    bookedAt: DateTime.now(),
    team: hasAssignmentMetadata ? assignedTeam : null,
    game: game,
  );
}

class _FakeOpenQueueRepository implements OpenQueueRepository {
  _FakeOpenQueueRepository({this.upcomingBooking, this.cancellationPreview});

  final OpenQueueBooking? upcomingBooking;
  final OpenQueueCancellationPreview? cancellationPreview;
  int cancelCalls = 0;

  @override
  Future<List<OpenQueueGame>> listGames() async => const [];

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => const [];

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) =>
      throw UnimplementedError();

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async => upcomingBooking;

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async => _booking();

  @override
  Future<OpenQueueBooking> cancelBooking(String bookingId) async {
    cancelCalls += 1;
    return _booking();
  }

  @override
  Future<OpenQueueCancellationPreview> previewCancellation(
    String bookingId,
  ) async =>
      cancellationPreview ??
      OpenQueueCancellationPreview(
        canCancel: true,
        refundPercent: 0,
        refundAmountFils: 0,
        refundCutoffAt: DateTime.now(),
      );
}
