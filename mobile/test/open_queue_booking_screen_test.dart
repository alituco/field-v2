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

    final homeButton = find.widgetWithText(FilledButton, 'Go back home');
    await tester.scrollUntilVisible(
      homeButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(homeButton);
    await tester.pumpAndSettle();

    expect(find.text('Open queue'), findsOneWidget);
    expect(find.text('Reserve spot'), findsNothing);
    expect(find.text('YOUR SPOT IS RESERVED'), findsNothing);
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
    await tester.scrollUntilVisible(
      homeButton,
      220,
      scrollable: find.byType(Scrollable).first,
    );
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

    expect(find.text('WHITE'), findsOneWidget);
    expect(find.text('White 1211 · Black 1209 · Avg 1210'), findsOneWidget);
    expect(
      find.text('Teams assigned. The two team averages are only 2 SR apart.'),
      findsOneWidget,
    );
    expect(find.textContaining("We'll notify you"), findsNothing);
  });
}

OpenQueueBooking _booking({bool assigned = false}) {
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
    whiteAverageSr: assigned ? 1211 : null,
    blackAverageSr: assigned ? 1209 : null,
    matchAverageSr: assigned ? 1210 : null,
    teamSrSpread: assigned ? 2 : null,
    teamsAssignedAt: assigned ? DateTime.now() : null,
  );
  return OpenQueueBooking(
    id: 'booking-1',
    gameId: game.id,
    profileId: 'profile-1',
    role: OpenQueueRole.defender,
    status: 'CONFIRMED',
    amountPaidFils: game.priceFils,
    bookedAt: DateTime.now(),
    team: assigned ? openQueueWhiteTeamId : null,
    game: game,
  );
}

class _FakeOpenQueueRepository implements OpenQueueRepository {
  @override
  Future<List<OpenQueueGame>> listGames() async => const [];

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => const [];

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) =>
      throw UnimplementedError();

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async => null;

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async => _booking();

  @override
  Future<OpenQueueBooking> cancelBooking(String bookingId) {
    throw UnimplementedError();
  }

  @override
  Future<OpenQueueCancellationPreview> previewCancellation(String bookingId) {
    throw UnimplementedError();
  }
}
