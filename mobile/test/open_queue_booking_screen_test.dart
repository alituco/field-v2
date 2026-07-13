import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_booking_screen.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
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
}

OpenQueueBooking _booking() {
  final startsAt = DateTime.now().add(const Duration(days: 2));
  final game = OpenQueueGame(
    id: 'game-1',
    status: 'OPEN',
    venue: 'TFA, Saar',
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: 'Ages 16-20',
    capacity: 12,
    confirmedCount: 10,
    spots: const {
      OpenQueueRole.goalkeeper: 1,
      OpenQueueRole.defender: 1,
      OpenQueueRole.midfielder: 0,
      OpenQueueRole.attacker: 0,
    },
  );
  return OpenQueueBooking(
    id: 'booking-1',
    gameId: game.id,
    profileId: 'profile-1',
    role: OpenQueueRole.defender,
    status: 'CONFIRMED',
    amountPaidFils: game.priceFils,
    bookedAt: DateTime.now(),
    game: game,
  );
}

class _FakeOpenQueueRepository implements OpenQueueRepository {
  @override
  Future<List<OpenQueueGame>> listGames() async => const [];

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async => null;

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<OpenQueueBooking> cancelBooking(String bookingId) {
    throw UnimplementedError();
  }

  @override
  Future<OpenQueueCancellationPreview> previewCancellation(String bookingId) {
    throw UnimplementedError();
  }
}
