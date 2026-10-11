import 'dart:async';

import 'package:field/src/open_queue/fieldrush_checkout_sheet.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/payments/fieldrush_embedded_payment.dart';
import 'package:field/src/payments/payment_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2099, 6, 1);
const _payKey = ValueKey('open-queue-confirm-payment');

void main() {
  testWidgets('preview and selecting a method never begin a booking', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);

    expect(repository.quoteCalls, 1);
    expect(repository.embeddedBookCalls, 0);
    expect(repository.legacyBookCalls, 0);
    expect(sessions.created, hasLength(1));
    expect(sessions.current.amountFils, 13000);
    expect(sessions.current.currency, 'USD');
    expect(sessions.current.initializeCalls, 1);
    expect(find.text('Fake embedded payment element'), findsOneWidget);
    expect(find.text(r'Pay · $13.00'), findsOneWidget);
    expect(_payButton(tester).onPressed, isNull);

    sessions.current.select();
    await tester.pump();
    expect(_payButton(tester).onPressed, isNotNull);
    expect(repository.embeddedBookCalls, 0);
    expect(sessions.current.collectCalls, 0);
    expect(result.completed, isFalse);

    await tester.tap(find.byTooltip('Close checkout'));
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.booking, isNull);
    expect(repository.embeddedBookCalls, 0);
  });

  testWidgets('Pay requires both a loaded element and selected method', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions()..readyOnInitialize = false;
    await _openCheckout(tester, repository, sessions);
    expect(_payButton(tester).onPressed, isNull);

    sessions.current.select();
    await tester.pump();
    expect(_payButton(tester).onPressed, isNull);

    sessions.current.setReady(true);
    await tester.pump();
    expect(_payButton(tester).onPressed, isNotNull);

    sessions.current.select(false);
    await tester.pump();
    expect(_payButton(tester).onPressed, isNull);
    expect(repository.embeddedBookCalls, 0);
  });

  testWidgets('duplicate taps collect once and await server verification', (
    tester,
  ) async {
    final repository = _Repository()
      ..verification = Completer<OpenQueueBooking>();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    sessions.current.select();
    await tester.pump();
    await tester.ensureVisible(find.byKey(_payKey));

    // Keep the original callback to exercise same-frame duplicate dispatches,
    // before a rebuild has a chance to disable the button.
    final onPay = _payButton(tester).onPressed!;
    onPay();
    onPay();
    await tester.pump();
    expect(repository.embeddedBookCalls, 1);
    expect(repository.legacyBookCalls, 0);
    expect(sessions.current.collectCalls, 1);
    expect(sessions.current.lastRequest!.amountFils, 13000);
    expect(sessions.current.lastRequest!.amountMinor, 1300);
    expect(sessions.current.lastRequest!.currency, 'USD');
    expect(result.completed, isFalse);
    expect(find.byType(FieldrushCheckoutSheet), findsOneWidget);
    expect(_payButton(tester).onPressed, isNull);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Close checkout',
            ),
          )
          .onPressed,
      isNull,
    );

    repository.verification!.complete(_booking(repository.game));
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.booking!.status, 'CONFIRMED');
    expect(result.booking!.gameId, repository.game.id);
    expect(sessions.current.closeCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('a changed quote resets method selection before another Pay', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    final original = sessions.current;
    original.select();
    await tester.pump();
    repository.price = 15000;

    await _tapPay(tester);
    expect(repository.embeddedBookCalls, 0);
    expect(original.collectCalls, 0);
    expect(original.closeCalls, greaterThanOrEqualTo(1));
    expect(sessions.created, hasLength(2));
    expect(sessions.current.amountFils, 15000);
    expect(sessions.current.hasSelection, isFalse);
    expect(find.textContaining('Your booking terms changed'), findsOneWidget);
    expect(find.text(r'Pay · $15.00'), findsOneWidget);
    expect(_payButton(tester).onPressed, isNull);
    expect(result.completed, isFalse);

    sessions.current.select();
    await tester.pump();
    await _tapPay(tester);
    expect(repository.embeddedBookCalls, 1);
    expect(sessions.current.collectCalls, 1);
    expect(result.booking!.status, 'CONFIRMED');
  });

  testWidgets('server prepared total mismatch requires a refreshed review', (
    tester,
  ) async {
    final repository = _Repository()..preparedAmountFils = 15000;
    repository.beforeCollect = () => repository.price = 15000;
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    final original = sessions.current;
    original.select();
    await tester.pump();

    await _tapPay(tester);
    expect(repository.embeddedBookCalls, 1);
    expect(original.collectCalls, 0);
    expect(result.completed, isFalse);
    expect(sessions.created, hasLength(2));
    expect(sessions.current.amountFils, 15000);
    expect(sessions.current.hasSelection, isFalse);
    expect(find.text(r'Pay · $15.00'), findsOneWidget);
    expect(_payButton(tester).onPressed, isNull);

    sessions.current.select();
    await tester.pump();
    await _tapPay(tester);
    expect(repository.embeddedBookCalls, 2);
    expect(sessions.current.collectCalls, 1);
    expect(result.booking!.status, 'CONFIRMED');
  });

  testWidgets(
    'changed policy requires review even when the total is unchanged',
    (tester) async {
      final repository = _Repository();
      final sessions = _Sessions();
      final result = await _openCheckout(tester, repository, sessions);
      final original = sessions.current;
      original.select();
      await tester.pump();
      repository.policyVersionId = 'policy-2';

      await _tapPay(tester);
      expect(repository.embeddedBookCalls, 0);
      expect(original.collectCalls, 0);
      expect(original.closeCalls, greaterThanOrEqualTo(1));
      expect(sessions.created, hasLength(2));
      expect(sessions.current.amountFils, 13000);
      expect(sessions.current.hasSelection, isFalse);
      expect(find.textContaining('Your booking terms changed'), findsOneWidget);
      expect(_payButton(tester).onPressed, isNull);
      expect(result.completed, isFalse);
    },
  );

  testWidgets('cancelled native payment keeps checkout open and unconfirmed', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    sessions.current
      ..collectionError = const PaymentCancelledException()
      ..select();
    await tester.pump();

    await _tapPay(tester);
    expect(repository.embeddedBookCalls, 1);
    expect(sessions.current.collectCalls, 1);
    expect(result.completed, isFalse);
    expect(result.booking, isNull);
    expect(find.byType(FieldrushCheckoutSheet), findsOneWidget);
    expect(find.textContaining('Payment was cancelled'), findsOneWidget);
    expect(find.text(r'Pay · $13.00'), findsOneWidget);
    expect(_payButton(tester).onPressed, isNotNull);
  });

  testWidgets('pending payment resumes without selection or another quote', (
    tester,
  ) async {
    final repository = _Repository()
      ..afterCollectionError = const PaymentPendingException();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    sessions.current.select();
    await tester.pump();
    await _tapPay(tester);
    expect(result.completed, isFalse);
    expect(find.text(r'Resume payment · $13.00'), findsOneWidget);
    final quoteCalls = repository.quoteCalls;

    repository
      ..quoteFails = true
      ..collectOnBook = false
      ..afterCollectionError = null;
    sessions.current
      ..select(false)
      ..setReady(false);
    await tester.pump();
    expect(_payButton(tester).onPressed, isNotNull);

    await _tapPay(tester);
    expect(repository.quoteCalls, quoteCalls);
    expect(repository.embeddedBookCalls, 2);
    expect(sessions.current.collectCalls, 1);
    expect(result.booking!.status, 'CONFIRMED');
  });

  testWidgets('pending recovery can return an already verified booking', (
    tester,
  ) async {
    final repository = _Repository()
      ..afterCollectionError = const PaymentPendingException();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    sessions.current.select();
    await tester.pump();
    await _tapPay(tester);
    final quoteCalls = repository.quoteCalls;

    repository
      ..quoteFails = true
      ..recoveredBooking = _booking(repository.game);
    sessions.current.select(false);
    await tester.pump();
    await _tapPay(tester);
    expect(repository.quoteCalls, quoteCalls);
    expect(repository.embeddedBookCalls, 1);
    expect(sessions.current.collectCalls, 1);
    expect(result.booking!.status, 'CONFIRMED');
  });

  for (final failure in <String, Object>{
    'pending verification': const PaymentPendingException(),
    'payment verification error': const PaymentException(
      'Booking verification is temporarily unavailable.',
    ),
    'booking hydration error': StateError('Booking details unavailable'),
  }.entries) {
    testWidgets(
      'submitted payment stays visible and resumes after ${failure.key}',
      (tester) async {
        final repository = _Repository()..afterCollectionError = failure.value;
        final sessions = _Sessions();
        final result = await _openCheckout(tester, repository, sessions);
        sessions.current
          ..consumeOnCollection = true
          ..select();
        await tester.pump();

        await _tapPay(tester);
        expect(sessions.current.collectCalls, 1);
        expect(sessions.current.isReady, isFalse);
        expect(sessions.current.hasSelection, isFalse);
        expect(result.completed, isFalse);
        expect(find.text(r'Resume payment · $13.00'), findsOneWidget);
        expect(_payButton(tester).onPressed, isNotNull);
        final element = find.text('Fake embedded payment element');
        expect(element, findsOneWidget);
        expect(
          tester
              .widget<Opacity>(
                find.ancestor(of: element, matching: find.byType(Opacity)),
              )
              .opacity,
          1,
        );
        expect(
          tester
              .widget<AbsorbPointer>(
                find.ancestor(
                  of: element,
                  matching: find.descendant(
                    of: find.byType(FieldrushCheckoutSheet),
                    matching: find.byType(AbsorbPointer),
                  ),
                ),
              )
              .absorbing,
          isTrue,
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label == 'Loading secure payment options',
          ),
          findsNothing,
        );

        final quoteCalls = repository.quoteCalls;
        repository
          ..quoteFails = true
          ..recoveredBooking = _booking(repository.game);
        await _tapPay(tester);
        expect(repository.quoteCalls, quoteCalls);
        expect(repository.embeddedBookCalls, 1);
        expect(sessions.created, hasLength(1));
        expect(sessions.current.collectCalls, 1);
        expect(result.completed, isTrue);
        expect(result.booking!.status, 'CONFIRMED');
      },
    );
  }

  testWidgets('non-confirmed server result never completes the checkout', (
    tester,
  ) async {
    final repository = _Repository()..returnedStatus = 'PENDING';
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    sessions.current.select();
    await tester.pump();

    await _tapPay(tester);
    expect(sessions.current.collectCalls, 1);
    expect(result.completed, isFalse);
    expect(result.booking, isNull);
    expect(find.byType(FieldrushCheckoutSheet), findsOneWidget);
  });

  testWidgets('failed price lookup creates no element and can be retried', (
    tester,
  ) async {
    final repository = _Repository()..quoteFails = true;
    final sessions = _Sessions();
    await _openCheckout(tester, repository, sessions);
    expect(sessions.created, isEmpty);
    expect(_payButton(tester).onPressed, isNull);
    expect(repository.embeddedBookCalls, 0);

    repository.quoteFails = false;
    await tester.ensureVisible(find.text('Retry price check'));
    await tester.tap(find.text('Retry price check'));
    await tester.pumpAndSettle();
    expect(sessions.created, hasLength(1));
    expect(_payButton(tester).onPressed, isNull);
    expect(repository.embeddedBookCalls, 0);
  });

  testWidgets('element loading failure offers retry without booking', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions()
      ..initializationError = 'Payment methods could not load.';
    await _openCheckout(tester, repository, sessions);
    expect(
      find.textContaining('Payment methods could not load'),
      findsOneWidget,
    );
    expect(_payButton(tester).onPressed, isNull);
    expect(repository.embeddedBookCalls, 0);

    sessions.initializationError = null;
    final retry = find.byKey(const ValueKey('retry-payment-options'));
    expect(retry, findsOneWidget);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(sessions.current.isReady, isTrue);
    expect(sessions.current.loadingError, isNull);
    expect(sessions.current.hasSelection, isFalse);
    expect(_payButton(tester).onPressed, isNull);
    expect(repository.embeddedBookCalls, 0);
  });

  testWidgets('free quote uses no native element and only books on confirm', (
    tester,
  ) async {
    final repository = _Repository()..price = 0;
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    expect(sessions.created, isEmpty);
    expect(find.text('Fake embedded payment element'), findsNothing);
    expect(find.text('Confirm booking'), findsOneWidget);
    expect(_payButton(tester).onPressed, isNotNull);
    expect(repository.embeddedBookCalls, 0);

    await _tapPay(tester);
    expect(repository.embeddedBookCalls, 1);
    expect(repository.legacyBookCalls, 0);
    expect(sessions.created, isEmpty);
    expect(result.booking!.status, 'CONFIRMED');
  });

  testWidgets('native session closes before checkout route is dismissed', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    final session = sessions.current;
    session.closeBarrier = Completer<void>();

    await tester.tap(find.byTooltip('Close checkout'));
    await tester.pump();
    expect(session.closeCalls, 1);
    expect(session.closed, isFalse);
    expect(result.completed, isFalse);
    expect(find.byType(FieldrushCheckoutSheet), findsOneWidget);
    expect(repository.embeddedBookCalls, 0);

    session.closeBarrier!.complete();
    await tester.pumpAndSettle();
    expect(session.closed, isTrue);
    expect(result.completed, isTrue);
    expect(result.nativeClosedAtCompletion, isTrue);
    expect(result.booking, isNull);
  });

  testWidgets('embedded checkout fits narrow screens with enlarged text', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions();
    await _openCheckout(
      tester,
      repository,
      sessions,
      size: const Size(320, 740),
      scale: 1.6,
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Fake embedded payment element'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    sessions.current.select();
    await tester.pump();
    await tester.ensureVisible(find.byKey(_payKey));
    await tester.pumpAndSettle();
    expect(find.text(r'Pay · $13.00'), findsOneWidget);
    expect(_payButton(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    expect(repository.embeddedBookCalls, 0);
  });
}

FilledButton _payButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(_payKey));

Future<void> _tapPay(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_payKey));
  await tester.tap(find.byKey(_payKey));
  await tester.pumpAndSettle();
}

Future<_CheckoutResult> _openCheckout(
  WidgetTester tester,
  _Repository repository,
  _Sessions sessions, {
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  final result = _CheckoutResult();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result.booking = await showModalBottomSheet<OpenQueueBooking>(
                context: context,
                isScrollControlled: true,
                builder: (_) => FieldrushCheckoutSheet(
                  repository: repository,
                  game: repository.game,
                  role: OpenQueueRole.attacker,
                  embeddedPaymentSessionFactory: sessions.create,
                ),
              );
              result.nativeClosedAtCompletion = sessions.created.every(
                (session) => session.closed,
              );
              result.completed = true;
            },
            child: const Text('Open checkout'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open checkout'));
  await tester.pumpAndSettle();
  return result;
}

class _CheckoutResult {
  bool completed = false;
  bool nativeClosedAtCompletion = false;
  OpenQueueBooking? booking;
}

class _Sessions {
  final created = <_FakeSession>[];
  bool readyOnInitialize = true;
  String? initializationError;

  _FakeSession get current => created.last;

  FieldrushEmbeddedPaymentSession create({
    required int amountFils,
    required String currency,
  }) {
    final session = _FakeSession(
      amountFils: amountFils,
      currency: currency,
      readyOnInitialize: readyOnInitialize,
      initializationError: initializationError,
    );
    created.add(session);
    return session;
  }
}

class _FakeSession extends FieldrushEmbeddedPaymentSession {
  _FakeSession({
    required this.amountFils,
    required this.currency,
    required this.readyOnInitialize,
    this.initializationError,
  });

  final int amountFils;
  final String currency;
  final bool readyOnInitialize;
  final String? initializationError;
  int initializeCalls = 0;
  int collectCalls = 0;
  int closeCalls = 0;
  bool closed = false;
  bool _ready = false;
  bool _selected = false;
  String? _loadingError;
  Object? collectionError;
  bool consumeOnCollection = false;
  PaymentCollectionRequest? lastRequest;
  Completer<void>? closeBarrier;
  Future<void>? _closing;

  @override
  bool get isReady => _ready;
  @override
  bool get hasSelection => _selected;
  @override
  String? get loadingError => _loadingError;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    _loadingError = initializationError;
    _ready = readyOnInitialize && _loadingError == null;
    notifyListeners();
  }

  void setReady(bool ready) {
    _ready = ready;
    notifyListeners();
  }

  void select([bool selected = true]) {
    _selected = selected;
    notifyListeners();
  }

  @override
  Widget buildView() => const SizedBox(
    height: 100,
    child: Center(child: Text('Fake embedded payment element')),
  );

  @override
  Future<void> collectPayment(PaymentCollectionRequest request) async {
    collectCalls++;
    lastRequest = request;
    if (collectionError != null) throw collectionError!;
    if (consumeOnCollection) {
      _ready = false;
      _selected = false;
      notifyListeners();
    }
  }

  @override
  Future<void> close() {
    return _closing ??= _close();
  }

  Future<void> _close() async {
    closeCalls++;
    if (closeBarrier != null) await closeBarrier!.future;
    closed = true;
  }
}

class _Repository
    implements
        OpenQueueRepository,
        OpenQueueBookingCostPreviewRepository,
        OpenQueueBookingLookupRepository,
        OpenQueueEmbeddedCheckoutRepository {
  final game = _game();
  int quoteCalls = 0;
  int embeddedBookCalls = 0;
  int legacyBookCalls = 0;
  int price = 13000;
  int? preparedAmountFils;
  bool quoteFails = false;
  bool collectOnBook = true;
  String returnedStatus = 'CONFIRMED';
  String policyVersionId = 'policy-1';
  VoidCallback? beforeCollect;
  Object? afterCollectionError;
  OpenQueueBooking? recoveredBooking;
  Completer<OpenQueueBooking>? verification;

  @override
  Future<OpenQueueBookingCostPreview> previewBookingCost({
    required String gameId,
    required OpenQueueRole role,
  }) async {
    quoteCalls++;
    if (quoteFails) throw StateError('Price unavailable');
    return OpenQueueBookingCostPreview(
      currency: 'USD',
      standardMatchFeeFils: price,
      replacementDiscountBps: 0,
      discountAmountFils: 0,
      matchFeeFils: price,
      reliabilityDepositRequired: false,
      reliabilityDepositBps: 0,
      reliabilityDepositFils: 0,
      totalFils: price,
      policyVersionId: policyVersionId,
    );
  }

  @override
  Future<OpenQueueBooking> bookGameWithCollector({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required PaymentCollector collectPayment,
  }) async {
    embeddedBookCalls++;
    beforeCollect?.call();
    final amountFils = preparedAmountFils ?? price;
    if (collectOnBook && amountFils > 0) {
      await collectPayment(
        PaymentCollectionRequest(
          clientSecret: 'pi_embedded_test_secret_not_real',
          amountFils: amountFils,
          currency: 'USD',
        ),
      );
    }
    if (afterCollectionError != null) throw afterCollectionError!;
    if (verification != null) return verification!.future;
    return _booking(game, status: returnedStatus);
  }

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async {
    legacyBookCalls++;
    throw StateError('Embedded checkout must not use the legacy presenter.');
  }

  @override
  Future<OpenQueueBooking?> getMyUpcomingBookingForGame(String gameId) async =>
      recoveredBooking;

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => [
    if (recoveredBooking != null) recoveredBooking!,
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

OpenQueueGame _game() => OpenQueueGame(
  id: 'embedded-checkout-game',
  status: 'OPEN',
  venue: 'Reach 11 Fields',
  startsAt: _now.add(const Duration(days: 2, hours: 3, minutes: 30)),
  endsAt: _now.add(const Duration(days: 2, hours: 4, minutes: 30)),
  timezone: 'America/Phoenix',
  currency: 'USD',
  priceFils: 13000,
  ageLabel: '18+',
  capacity: 14,
  confirmedCount: 3,
  spots: const {
    OpenQueueRole.goalkeeper: 2,
    OpenQueueRole.defender: 5,
    OpenQueueRole.attacker: 4,
  },
  teamAssignmentLeadMinutes: 180,
);

OpenQueueBooking _booking(OpenQueueGame game, {String status = 'CONFIRMED'}) =>
    OpenQueueBooking(
      id: 'booking-${game.id}',
      gameId: game.id,
      profileId: 'me',
      role: OpenQueueRole.attacker,
      status: status,
      amountPaidFils: 13000,
      bookedAt: _now,
      game: game,
    );
