import 'package:field/src/open_queue/fieldrush_booking_flow.dart';
import 'package:field/src/open_queue/fieldrush_checkout_sheet.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/payments/payment_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rapid Continue taps open only one checkout route', (
    tester,
  ) async {
    final observer = _RouteObserver();
    final repository = _Queue();
    await _phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: FieldrushBookingFlow(
          repository: repository,
          initialGame: repository.game,
          now: DateTime.utc(2099, 6, 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('booking-review-position-DEF')));
    await tester.pump();
    final continueButton = find.byKey(
      const ValueKey('booking-continue-payment'),
    );
    await tester.ensureVisible(continueButton);
    await tester.tap(continueButton);
    // The modal barrier must intercept the second physical tap.
    await tester.tap(continueButton, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(observer.checkoutRoutes, 1);
    expect(repository.bookCalls, 0);
  });

  testWidgets(
    'ambiguous payment recovers booking even when new quote rejects duplicate',
    (tester) async {
      final repository = _Queue()..ambiguousCapture = true;
      OpenQueueBooking? result;
      await _phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return FilledButton(
                  onPressed: () async {
                    result = await showModalBottomSheet<OpenQueueBooking>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => FieldrushCheckoutSheet(
                        repository: repository,
                        game: repository.game,
                        role: OpenQueueRole.defender,
                      ),
                    );
                  },
                  child: const Text('Open checkout'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open checkout'));
      await tester.pumpAndSettle();
      final pay = find.byKey(const ValueKey('open-queue-confirm-payment'));
      await tester.ensureVisible(pay);
      await tester.tap(pay);
      await tester.pumpAndSettle();
      if (result == null) {
        await tester.ensureVisible(pay);
        await tester.tap(pay);
        await tester.pumpAndSettle();
      }
      expect(result?.id, 'verified-booking');
      expect(
        repository.bookCalls,
        1,
        reason: 'Recover the confirmed booking without a replacement payment.',
      );
    },
  );

  testWidgets('pending retry reaches the existing payment before requoting', (
    tester,
  ) async {
    final repository = _Queue()
      ..ambiguousCapture = true
      ..lookupAvailable = false;
    await _phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FieldrushCheckoutSheet(
            repository: repository,
            game: repository.game,
            role: OpenQueueRole.defender,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pay = find.byKey(const ValueKey('open-queue-confirm-payment'));
    await tester.ensureVisible(pay);
    await tester.tap(pay);
    await tester.pumpAndSettle();
    expect(repository.bookCalls, 1);
    expect(repository.quoteCalls, 2);
    await tester.ensureVisible(pay);
    await tester.tap(pay);
    await tester.pumpAndSettle();
    expect(repository.bookCalls, 2);
    expect(
      repository.quoteCalls,
      2,
      reason:
          'The existing payment must be resolved even if a fresh quote would reject the game.',
    );
  });
}

Future<void> _phone(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 1100);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

class _RouteObserver extends NavigatorObserver {
  int checkoutRoutes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is ModalBottomSheetRoute) checkoutRoutes++;
    super.didPush(route, previousRoute);
  }
}

class _Queue
    implements
        OpenQueueRepository,
        OpenQueueBookingCostPreviewRepository,
        OpenQueueBookingLookupRepository {
  bool ambiguousCapture = false;
  bool lookupAvailable = true;
  int bookCalls = 0;
  int quoteCalls = 0;
  final game = OpenQueueGame(
    id: 'game',
    status: 'OPEN',
    venue: 'Reach 11 Fields',
    startsAt: DateTime.utc(2099, 6, 3, 3),
    endsAt: DateTime.utc(2099, 6, 3, 4),
    timezone: 'America/Phoenix',
    priceFils: 13000,
    currency: 'USD',
    ageLabel: '18+',
    capacity: 14,
    confirmedCount: 8,
    spots: const {
      OpenQueueRole.goalkeeper: 1,
      OpenQueueRole.defender: 3,
      OpenQueueRole.attacker: 2,
    },
  );
  OpenQueueBooking get booking => OpenQueueBooking(
    id: 'verified-booking',
    gameId: game.id,
    profileId: 'me',
    role: OpenQueueRole.defender,
    status: 'CONFIRMED',
    amountPaidFils: 13000,
    bookedAt: DateTime.utc(2099, 6, 1),
    game: game,
  );
  @override
  Future<List<OpenQueueGame>> listGames() async => [game];
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async =>
      bookCalls > 0 ? [booking] : [];
  @override
  Future<OpenQueueBooking?> getMyUpcomingBookingForGame(String gameId) async =>
      lookupAvailable && bookCalls > 0 ? booking : null;
  @override
  Future<OpenQueueBookingCostPreview> previewBookingCost({
    required String gameId,
    required OpenQueueRole role,
  }) async {
    quoteCalls++;
    if (bookCalls > 0) {
      throw StateError('You already booked this Open Queue game.');
    }
    return const OpenQueueBookingCostPreview(
      currency: 'USD',
      standardMatchFeeFils: 13000,
      replacementDiscountBps: 0,
      discountAmountFils: 0,
      matchFeeFils: 13000,
      reliabilityDepositRequired: false,
      reliabilityDepositBps: 0,
      reliabilityDepositFils: 0,
      totalFils: 13000,
    );
  }

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async {
    bookCalls++;
    if (ambiguousCapture) throw const PaymentPendingException();
    return booking;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
