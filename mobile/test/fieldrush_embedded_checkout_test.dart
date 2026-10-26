import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/open_queue/fieldrush_checkout_sheet.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/payments/fieldrush_embedded_payment.dart';
import 'package:field/src/payments/payment_service.dart';
import 'package:field/src/support/contact_support_sheet.dart';
import 'package:field/src/support/support.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2099, 6, 1);
const _payKey = ValueKey('open-queue-confirm-payment');

void main() {
  testWidgets(
    'only a verified foreground booking acknowledges the confirmation push',
    (tester) async {
      final repository = _Repository()
        ..verification = Completer<OpenQueueBooking>();
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      await tester.ensureVisible(find.byKey(_payKey));
      await tester.tap(find.byKey(_payKey));
      await tester.pump();
      expect(repository.acknowledgedOutcomes, isEmpty);
      repository.verification!.complete(_booking(repository.game));
      await tester.pumpAndSettle();
      expect(repository.acknowledgedOutcomes, ['embedded-attempt:CONFIRMED']);
    },
  );

  testWidgets(
    'confirmation while backgrounded remains eligible for phone push',
    (tester) async {
      final repository = _Repository()
        ..verification = Completer<OpenQueueBooking>();
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      await tester.ensureVisible(find.byKey(_payKey));
      await tester.tap(find.byKey(_payKey));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      repository.verification!.complete(_booking(repository.game));
      await tester.pumpAndSettle();
      expect(repository.acknowledgedOutcomes, isEmpty);
    },
  );

  testWidgets(
    'seeing a pending refund does not acknowledge later refunded outcome',
    (tester) async {
      final repository = _Repository()
        ..afterCollectionError = PaymentRefundException(_refund());
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      await _tapPay(tester);
      expect(repository.acknowledgedOutcomes, [
        'refund-attempt:REFUND_PENDING',
      ]);
      expect(find.text('Refund processing'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stalled price lookup times out and retries without creating a payment',
    (tester) async {
      final pending = Completer<OpenQueueBookingCostPreview>();
      final repository = _Repository()..quoteBarrier = pending;
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('Retry price check'), findsOneWidget);
      expect(_payButton(tester).onPressed, isNull);
      expect(repository.embeddedBookCalls, 0);
      expect(sessions.created, isEmpty);
      repository.quoteBarrier = null;
      await tester.ensureVisible(find.text('Retry price check'));
      await tester.tap(find.text('Retry price check'));
      await tester.pumpAndSettle();
      expect(sessions.created, hasLength(1));
      expect(repository.embeddedBookCalls, 0);
      final stale = await (_Repository()..price = 99000).previewBookingCost(
        gameId: repository.game.id,
        role: OpenQueueRole.attacker,
      );
      pending.complete(stale);
      await tester.pumpAndSettle();
      expect(find.text(r'$99.00'), findsNothing);
      expect(sessions.created, hasLength(1));
    },
  );

  testWidgets(
    'failed position requote retains old price but cannot pay against it',
    (tester) async {
      final repository = _Repository();
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions, choosePosition: true);
      await tester.tap(find.byKey(const ValueKey('checkout-position-DEF')));
      await tester.pumpAndSettle();
      sessions.current.select();
      await tester.pump();
      expect(_payButton(tester).onPressed, isNotNull);
      repository.quoteFails = true;
      await tester.tap(find.byKey(const ValueKey('checkout-position-ATT')));
      await tester.pumpAndSettle();
      expect(find.text(r'$13.00'), findsWidgets);
      expect(_payButton(tester).onPressed, isNull);
      expect(repository.embeddedBookCalls, 0);
    },
  );

  testWidgets(
    'Join previews actual available pricing without selecting or booking a spot',
    (tester) async {
      final repository = _Repository()..game = _game(keeperSpots: 0);
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions, choosePosition: true);

      expect(find.text('Pay for your spot'), findsOneWidget);
      expect(find.text('Tuesday, June 2'), findsOneWidget);
      expect(find.text('Goalkeeper'), findsOneWidget);
      expect(find.text('Pick a position'), findsOneWidget);
      expect(repository.detailCalls, 1);
      expect(repository.quotedRoles, [OpenQueueRole.defender]);
      expect(sessions.created, hasLength(1));
      expect(find.text(r'$13.00'), findsWidgets);
      expect(_payButton(tester).onPressed, isNull);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('checkout-position-GK')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Full'), findsOneWidget);
      expect(repository.embeddedBookCalls, 0);
      expect(find.textContaining('wallet'), findsNothing);
      expect(find.textContaining('Visa •'), findsNothing);
      expect(
        find.byKey(const ValueKey('checkout-division-range')),
        findsOneWidget,
      );
      sessions.current.select();
      await tester.pump();
      expect(_payButton(tester).onPressed, isNull);
      expect(sessions.current.collectCalls, 0);

      await tester.tap(find.byKey(const ValueKey('checkout-position-DEF')));
      await tester.pumpAndSettle();
      expect(repository.quotedRoles, [
        OpenQueueRole.defender,
        OpenQueueRole.defender,
      ]);
      expect(sessions.created, hasLength(2));
      expect(_payButton(tester).onPressed, isNull);
      expect(repository.embeddedBookCalls, 0);
    },
  );

  testWidgets(
    'changing position requotes and replaces the old native selection',
    (tester) async {
      final repository = _Repository();
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions, choosePosition: true);
      await tester.tap(find.byKey(const ValueKey('checkout-position-DEF')));
      await tester.pumpAndSettle();
      final previous = sessions.current;
      previous.select();
      await tester.pump();
      repository.price = 15000;
      await tester.tap(find.byKey(const ValueKey('checkout-position-ATT')));
      await tester.pumpAndSettle();
      expect(repository.quotedRoles, [
        OpenQueueRole.goalkeeper,
        OpenQueueRole.defender,
        OpenQueueRole.attacker,
      ]);
      expect(previous.closed, isTrue);
      expect(sessions.created, hasLength(3));
      expect(sessions.current.amountFils, 15000);
      expect(sessions.current.hasSelection, isFalse);
      expect(_payButton(tester).onPressed, isNull);
      expect(repository.embeddedBookCalls, 0);
    },
  );

  testWidgets('freshly filled position is not selected or silently replaced', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions();
    await _openCheckout(tester, repository, sessions, choosePosition: true);
    repository.game = _game(defenderSpots: 0);
    await tester.tap(find.byKey(const ValueKey('checkout-position-DEF')));
    await tester.pumpAndSettle();
    expect(repository.quotedRoles, [
      OpenQueueRole.goalkeeper,
      OpenQueueRole.goalkeeper,
    ]);
    expect(sessions.created, hasLength(2));
    expect(find.text('Pick a position'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('checkout-position-DEF')),
          )
          .onPressed,
      isNull,
    );
    expect(_payButton(tester).onPressed, isNull);
  });

  testWidgets(
    'closing during fresh availability load never mounts a payment session',
    (tester) async {
      final repository = _Repository()
        ..detailBarrier = Completer<OpenQueueMatchDetail>();
      final sessions = _Sessions();
      final result = await _openCheckout(
        tester,
        repository,
        sessions,
        choosePosition: true,
      );
      await tester.tap(find.byTooltip('Close checkout'));
      await tester.pumpAndSettle();
      repository.detailBarrier!.complete(
        OpenQueueMatchDetail(
          game: repository.game,
          scorers: const [],
          timeline: const [],
        ),
      );
      await tester.pumpAndSettle();
      expect(result.completed, isTrue);
      expect(result.booking, isNull);
      expect(repository.quoteCalls, 0);
      expect(sessions.created, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('position checkout fits narrow screens with enlarged text', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions();
    await _openCheckout(
      tester,
      repository,
      sessions,
      choosePosition: true,
      size: const Size(320, 740),
      scale: 1.6,
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('checkout-position-ATT')),
    );
    await tester.tap(find.byKey(const ValueKey('checkout-position-ATT')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(_payKey));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(repository.bookedRoles, isEmpty);
  });

  testWidgets(
    'ambiguous payment locks the selected position and resumes the same role',
    (tester) async {
      final repository = _Repository()
        ..afterCollectionError = const PaymentPendingException();
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions, choosePosition: true);
      await tester.tap(find.byKey(const ValueKey('checkout-position-DEF')));
      await tester.pumpAndSettle();
      sessions.current.select();
      await tester.pump();
      await _tapPay(tester);
      final quoteCalls = repository.quoteCalls;
      for (final code in ['GK', 'DEF', 'ATT']) {
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(ValueKey('checkout-position-$code')),
              )
              .onPressed,
          isNull,
        );
      }
      await _tapPay(tester);
      expect(repository.bookedRoles, [
        OpenQueueRole.defender,
        OpenQueueRole.defender,
      ]);
      expect(repository.quoteCalls, quoteCalls);
      expect(sessions.created, hasLength(2));
    },
  );

  testWidgets(
    'Join checkout does not offer another booking when an active game exists',
    (tester) async {
      final repository = _Repository()..recoveredBooking = _booking(_game());
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions, choosePosition: true);
      expect(
        find.textContaining('already have an upcoming or active game'),
        findsOneWidget,
      );
      expect(repository.quoteCalls, 0);
      expect(sessions.created, isEmpty);
      expect(_payButton(tester).onPressed, isNull);
    },
  );

  for (final status in ['OPEN', 'FULL']) {
    testWidgets(
      'unstarted $status game stays visible but releases checkout after its end',
      (tester) async {
        final current = _game(
          status: status,
          start: DateTime.now().subtract(const Duration(hours: 3)),
        );
        final repository = _Repository()..recoveredBooking = _booking(current);
        final sessions = _Sessions();
        await _openCheckout(tester, repository, sessions, choosePosition: true);
        expect(
          find.textContaining('already have an upcoming or active game'),
          findsNothing,
        );
        expect(current.isActiveReservation, isTrue);
        expect(repository.quoteCalls, 1);
        expect(repository.embeddedBookCalls, 0);
        expect(sessions.created, hasLength(1));
        expect(_payButton(tester).onPressed, isNull);
      },
    );
  }

  for (final status in ['REQUIRES_REFUND', 'REFUNDED']) {
    for (final submitted in [false, true]) {
      testWidgets(
        '$status locks checkout even when native submission is $submitted',
        (tester) async {
          final refundError = PaymentRefundException(
            PaymentRefundState(intentId: 'refund-attempt', status: status),
          );
          final repository = _Repository();
          if (submitted) {
            repository.afterCollectionError = refundError;
          } else {
            repository.beforeCollectionError = refundError;
          }
          final sessions = _Sessions();
          final result = await _openCheckout(
            tester,
            repository,
            sessions,
            choosePosition: true,
          );
          await tester.tap(find.byKey(const ValueKey('checkout-position-DEF')));
          await tester.pumpAndSettle();
          sessions.current.select();
          await tester.pump();
          await _tapPay(tester);
          expect(
            find.text(status == 'REFUNDED' ? 'Refunded' : 'Refund processing'),
            findsOneWidget,
          );
          expect(find.text('refund-attempt'), findsOneWidget);
          expect(find.byKey(_payKey), findsNothing);
          expect(find.textContaining('Resume payment'), findsNothing);
          expect(find.text('Fake embedded payment element'), findsNothing);
          expect(sessions.current.closed, isTrue);
          for (final code in ['GK', 'DEF', 'ATT']) {
            expect(
              tester
                  .widget<OutlinedButton>(
                    find.byKey(ValueKey('checkout-position-$code')),
                  )
                  .onPressed,
              isNull,
            );
          }
          expect(repository.embeddedBookCalls, 1);
          expect(sessions.current.collectCalls, submitted ? 1 : 0);
          await tester.ensureVisible(find.byTooltip('Close checkout'));
          await tester.tap(find.byTooltip('Close checkout'));
          await tester.pumpAndSettle();
          expect(result.completed, isTrue);
          await tester.pump(const Duration(seconds: 30));
          expect(repository.refundChecks, isEmpty);
        },
      );
    }
  }

  testWidgets(
    'refund status refresh updates to refunded using only the original attempt',
    (tester) async {
      final repository = _Repository()
        ..afterCollectionError = PaymentRefundException(_refund())
        ..refundResponse = _refund(status: 'REFUNDED');
      final sessions = _Sessions();
      final result = await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      await _tapPay(tester);
      final quotes = repository.quoteCalls;
      final sessionCount = sessions.created.length;
      await tester.ensureVisible(
        find.byKey(const ValueKey('check-refund-status')),
      );
      await tester.tap(find.byKey(const ValueKey('check-refund-status')));
      await tester.pumpAndSettle();
      expect(find.text('Refunded'), findsOneWidget);
      expect(find.byKey(const ValueKey('check-refund-status')), findsNothing);
      expect(find.byKey(_payKey), findsNothing);
      expect(repository.refundChecks, ['refund-attempt']);
      expect(repository.embeddedBookCalls, 1);
      expect(repository.quoteCalls, quotes);
      expect(sessions.created, hasLength(sessionCount));
      expect(result.completed, isFalse);
      await tester.pump(const Duration(seconds: 30));
      expect(repository.refundChecks, hasLength(1));
    },
  );

  testWidgets(
    'refund polling is bounded and never prepares or recollects a payment',
    (tester) async {
      final repository = _Repository()
        ..afterCollectionError = PaymentRefundException(_refund());
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      await _tapPay(tester);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }
      expect(repository.refundChecks, List.filled(3, 'refund-attempt'));
      expect(repository.embeddedBookCalls, 1);
      expect(sessions.current.collectCalls, 1);
      expect(find.text('Refund processing'), findsOneWidget);
      expect(find.byKey(_payKey), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('automatic refund refresh stops after completion', (
    tester,
  ) async {
    final repository = _Repository()
      ..afterCollectionError = PaymentRefundException(_refund())
      ..refundResponse = _refund(status: 'REFUNDED');
    final sessions = _Sessions();
    await _openCheckout(tester, repository, sessions);
    sessions.current.select();
    await tester.pump();
    await _tapPay(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Refunded'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(repository.refundChecks, ['refund-attempt']);
    expect(repository.embeddedBookCalls, 1);
    expect(sessions.current.collectCalls, 1);
  });

  testWidgets(
    'a confirmed booking is recovered before showing a terminal refund report',
    (tester) async {
      final repository = _Repository()
        ..afterCollectionError = PaymentRefundException(_refund());
      repository.beforeCollect = () =>
          repository.recoveredBooking = _booking(repository.game);
      final sessions = _Sessions();
      final result = await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      await _tapPay(tester);
      expect(result.booking?.status, 'CONFIRMED');
      expect(result.completed, isTrue);
      expect(find.text('Refund processing'), findsNothing);
      expect(repository.refundChecks, isEmpty);
    },
  );

  testWidgets(
    'refund support includes the original payment and game reference',
    (tester) async {
      final repository = _Repository()
        ..afterCollectionError = PaymentRefundException(
          _refund(status: 'REFUNDED'),
        );
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      await _tapPay(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('refund-contact-support')),
      );
      await tester.tap(find.byKey(const ValueKey('refund-contact-support')));
      await tester.pumpAndSettle();
      final support = tester.widget<ContactSupportSheet>(
        find.byType(ContactSupportSheet),
      );
      expect(support.initialCategory, SupportRequestCategory.bookingOrPayment);
      expect(support.requestContext, {
        'source': 'checkout_refund',
        'payment_intent_id': 'refund-attempt',
        'game_id': repository.game.id,
      });
      expect(repository.embeddedBookCalls, 1);
    },
  );

  testWidgets(
    'refund refresh failure retains the terminal lock and review information',
    (tester) async {
      final repository = _Repository()
        ..afterCollectionError = PaymentRefundException(
          _refund(refundStatus: 'FAILED'),
        )
        ..refundCheckError = StateError('network unavailable');
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      await _tapPay(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('check-refund-status')),
      );
      await tester.tap(find.byKey(const ValueKey('check-refund-status')));
      await tester.pumpAndSettle();
      expect(find.text('Refund needs review'), findsOneWidget);
      expect(
        find.textContaining('Could not refresh the refund status'),
        findsOneWidget,
      );
      expect(find.byKey(_payKey), findsNothing);
      expect(repository.embeddedBookCalls, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
      expect(repository.refundChecks, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing during refund refresh ignores its later response', (
    tester,
  ) async {
    final repository = _Repository()
      ..afterCollectionError = PaymentRefundException(_refund())
      ..refundBarrier = Completer<PaymentRefundState>();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    sessions.current.select();
    await tester.pump();
    await _tapPay(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('check-refund-status')),
    );
    await tester.tap(find.byKey(const ValueKey('check-refund-status')));
    await tester.pumpAndSettle();
    expect(find.text('Checking refund status…'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Close checkout'));
    await tester.tap(find.byTooltip('Close checkout'));
    await tester.pumpAndSettle();
    repository.refundBarrier!.complete(_refund(status: 'REFUNDED'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(result.completed, isTrue);
    expect(result.booking, isNull);
    expect(repository.refundChecks, hasLength(1));
    expect(tester.takeException(), isNull);
  });

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

  testWidgets(
    'verified unpaid recovery rebuilds the broken selector and recollects the same intent',
    (tester) async {
      final repository = _Repository();
      final sessions = _Sessions();
      final result = await _openCheckout(tester, repository, sessions);
      final interrupted = sessions.current;
      interrupted
        ..interruptOnCollection = true
        ..select();
      await tester.pump();
      await _tapPay(tester);
      final quotes = repository.quoteCalls;
      expect(interrupted.isReady, isFalse);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('retry-payment-options')),
            )
            .onPressed,
        isNull,
      );

      await _tapPay(tester);
      expect(sessions.created, hasLength(2));
      expect(interrupted.closed, isTrue);
      expect(sessions.current.collectCalls, 0);
      expect(_payButton(tester).onPressed, isNull);
      expect(
        find.textContaining('Your earlier payment is unpaid'),
        findsOneWidget,
      );

      sessions.current.select();
      await tester.pump();
      await _tapPay(tester);
      expect(repository.resumeIntents, [
        'embedded-attempt',
        'embedded-attempt',
      ]);
      expect(repository.quoteCalls, quotes);
      expect(interrupted.collectCalls, 1);
      expect(sessions.current.collectCalls, 1);
      expect(sessions.current.lastRequest?.intentId, 'embedded-attempt');
      expect(
        sessions.current.lastRequest?.clientSecret,
        interrupted.lastRequest?.clientSecret,
      );
      expect(result.booking?.status, 'CONFIRMED');
    },
  );

  for (final state in [
    'UNKNOWN',
    'PROCESSING',
    'FINALIZED',
    'REQUIRES_REFUND',
  ]) {
    testWidgets(
      '$state recovery never rebuilds or recollects an interrupted session',
      (tester) async {
        final repository = _Repository();
        final sessions = _Sessions();
        final result = await _openCheckout(tester, repository, sessions);
        final interrupted = sessions.current;
        interrupted
          ..interruptOnCollection = true
          ..select();
        await tester.pump();
        await _tapPay(tester);
        repository.resumeState = state;
        await _tapPay(tester);
        expect(sessions.created, hasLength(1));
        expect(interrupted.collectCalls, 1);
        expect(repository.resumeIntents, ['embedded-attempt']);
        if (state == 'FINALIZED') {
          expect(result.booking?.status, 'CONFIRMED');
        } else if (state == 'REQUIRES_REFUND') {
          expect(find.text('Refund processing'), findsOneWidget);
        } else {
          expect(result.completed, isFalse);
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('retry-payment-options')),
                )
                .onPressed,
            isNull,
          );
        }
      },
    );
  }

  testWidgets(
    'a disposed checkout cannot collect from a delayed earlier callback',
    (tester) async {
      final repository = _Repository()
        ..beforeCollectionBarrier = Completer<void>();
      final sessions = _Sessions();
      await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      _payButton(tester).onPressed!();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      repository.beforeCollectionBarrier!.complete();
      await tester.pumpAndSettle();
      expect(sessions.current.collectCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a lost prepare acknowledgement resumes read-only even without an intent ID',
    (tester) async {
      final repository = _Repository()
        ..beforeCollectionError = const PaymentPendingException();
      final sessions = _Sessions();
      final result = await _openCheckout(tester, repository, sessions);
      sessions.current.select();
      await tester.pump();
      await _tapPay(tester);
      expect(sessions.current.collectCalls, 0);
      repository
        ..beforeCollectionError = null
        ..resumeState = 'UNKNOWN';
      await _tapPay(tester);
      expect(repository.resumeRequests, [null]);
      expect(sessions.current.collectCalls, 0);
      expect(result.completed, isFalse);
      repository.resumeState = 'COLLECTABLE';
      await _tapPay(tester);
      expect(repository.resumeRequests, [null, null]);
      expect(sessions.current.lastRequest?.verifiedUnpaidResume, isTrue);
      expect(sessions.current.collectCalls, 1);
      expect(result.booking?.status, 'CONFIRMED');
    },
  );

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

  testWidgets(
    'closing a declined checkout cancels its exact prepared attempt',
    (tester) async {
      final repository = _Repository();
      final sessions = _Sessions();
      final result = await _openCheckout(tester, repository, sessions);
      sessions.current
        ..collectionError = const PaymentException('Your card was declined.')
        ..select();
      await tester.pump();
      await _tapPay(tester);
      expect(result.completed, isFalse);

      repository.checkoutCancelBarrier = Completer<OpenQueueBooking?>();
      await tester.ensureVisible(find.byTooltip('Close checkout'));
      await tester.tap(find.byTooltip('Close checkout'));
      await tester.pump();
      expect(sessions.current.closed, isTrue);
      expect(repository.cancelledCheckouts, ['embedded-attempt']);
      expect(repository.cancelledGames, [repository.game.id]);
      expect(result.completed, isFalse);

      repository.checkoutCancelBarrier!.complete(null);
      await tester.pumpAndSettle();
      expect(result.completed, isTrue);
      expect(result.booking, isNull);
      expect(repository.embeddedBookCalls, 1);
    },
  );

  testWidgets('server cancellation does not wait for native view teardown', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    sessions.current
      ..collectionError = const PaymentException('Your card was declined.')
      ..select();
    await tester.pump();
    await _tapPay(tester);
    sessions.current.closeBarrier = Completer<void>();
    repository.checkoutCancelBarrier = Completer<OpenQueueBooking?>();
    await tester.ensureVisible(find.byTooltip('Close checkout'));
    await tester.tap(find.byTooltip('Close checkout'));
    await tester.pump();
    expect(repository.cancelledCheckouts, ['embedded-attempt']);
    expect(sessions.current.closed, isFalse);
    repository.checkoutCancelBarrier!.complete(null);
    await tester.pump();
    expect(result.completed, isFalse);
    sessions.current.closeBarrier!.complete();
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.booking, isNull);
  });

  testWidgets('closing returns the verified booking when capture wins cancel', (
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

    repository.checkoutCancelResponse = _booking(repository.game);
    await tester.ensureVisible(find.byTooltip('Close checkout'));
    await tester.tap(find.byTooltip('Close checkout'));
    await tester.pumpAndSettle();
    expect(repository.cancelledCheckouts, ['embedded-attempt']);
    expect(result.completed, isTrue);
    expect(result.booking?.status, 'CONFIRMED');
    expect(result.booking?.gameId, repository.game.id);
  });

  testWidgets('unknown cancellation stays recoverable and Close retries it', (
    tester,
  ) async {
    final repository = _Repository()
      ..afterCollectionError = const PaymentPendingException()
      ..checkoutCancelError = const PaymentPendingException();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    sessions.current.select();
    await tester.pump();
    await _tapPay(tester);
    await tester.ensureVisible(find.byTooltip('Close checkout'));
    await tester.tap(find.byTooltip('Close checkout'));
    await tester.pumpAndSettle();
    expect(result.completed, isFalse);
    expect(
      find.textContaining('Could not confirm checkout cancellation'),
      findsOneWidget,
    );
    expect(repository.cancelledCheckouts, ['embedded-attempt']);
    expect(repository.embeddedBookCalls, 1);

    repository.checkoutCancelError = null;
    await tester.ensureVisible(find.byTooltip('Close checkout'));
    await tester.tap(find.byTooltip('Close checkout'));
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.booking, isNull);
    expect(repository.cancelledCheckouts, [
      'embedded-attempt',
      'embedded-attempt',
    ]);
    expect(repository.embeddedBookCalls, 1);
  });

  testWidgets('a completed booking never sends the checkout cancel action', (
    tester,
  ) async {
    final repository = _Repository();
    final sessions = _Sessions();
    final result = await _openCheckout(tester, repository, sessions);
    sessions.current.select();
    await tester.pump();
    await _tapPay(tester);
    expect(result.booking?.status, 'CONFIRMED');
    expect(repository.cancelledCheckouts, isEmpty);
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

  testWidgets('render Join checkout with bundled fonts for visual review', (
    tester,
  ) async {
    final directory = Platform.environment['FIELDRUSH_CHECKOUT_SCREENSHOT_DIR'];
    if (directory == null) return;
    tester.view.physicalSize = const Size(390, 1100);
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
    final repository = _Repository()
      ..game = _game(keeperSpots: 0, defenderSpots: 3);
    final sessions = _Sessions()..visualPaymentStub = true;
    final boundaryKey = GlobalKey();
    await _openCheckout(
      tester,
      repository,
      sessions,
      choosePosition: true,
      boundaryKey: boundaryKey,
      size: const Size(390, 1100),
    );
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
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

    await capture('checkout-no-position');
    await tester.tap(find.byKey(const ValueKey('checkout-position-DEF')));
    await tester.pumpAndSettle();
    sessions.current.select();
    await tester.pumpAndSettle();
    await capture('checkout-defender');
    expect(repository.embeddedBookCalls, 0);
    expect(
      sessions.created.every((session) => session.collectCalls == 0),
      isTrue,
    );
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
  bool choosePosition = false,
  GlobalKey? boundaryKey,
}) async {
  final result = _CheckoutResult();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => RepaintBoundary(
        key: boundaryKey,
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
      home: Scaffold(
        backgroundColor: boundaryKey == null ? null : FieldrushAuthTheme.cream,
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result.booking = await showModalBottomSheet<OpenQueueBooking>(
                context: context,
                isScrollControlled: true,
                backgroundColor: FieldrushAuthTheme.cream,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                ),
                builder: (_) => FieldrushCheckoutSheet(
                  repository: repository,
                  game: repository.game,
                  role: choosePosition ? null : OpenQueueRole.attacker,
                  embeddedPaymentSessionFactory: sessions.create,
                ),
              );
              result.nativeClosedAtCompletion = sessions.created.every(
                (session) => session.closed,
              );
              result.completed = true;
            },
            child: Text(
              'Open checkout',
              style: boundaryKey == null
                  ? null
                  : const TextStyle(color: Colors.transparent),
            ),
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
  bool visualPaymentStub = false;

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
      visualPaymentStub: visualPaymentStub,
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
    this.visualPaymentStub = false,
  });

  final int amountFils;
  final String currency;
  final bool readyOnInitialize;
  final String? initializationError;
  final bool visualPaymentStub;
  int initializeCalls = 0;
  int collectCalls = 0;
  int closeCalls = 0;
  bool closed = false;
  bool _ready = false;
  bool _selected = false;
  String? _loadingError;
  Object? collectionError;
  bool consumeOnCollection = false;
  bool interruptOnCollection = false;
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
  Widget buildView() => visualPaymentStub
      // Only used by opt-in visual QA. Real builds use Stripe's native element.
      ? Column(
          children: [
            for (final label in ['Card', 'Apple Pay'])
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 15,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: FieldrushAuthTheme.border),
                ),
                child: Row(
                  children: [
                    Icon(
                      label == 'Card' ? Icons.credit_card : Icons.apple,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
              ),
          ],
        )
      : const SizedBox(
          height: 100,
          child: Center(child: Text('Fake embedded payment element')),
        );

  @override
  Future<void> collectPayment(PaymentCollectionRequest request) async {
    collectCalls++;
    lastRequest = request;
    if (interruptOnCollection) {
      _ready = false;
      _selected = false;
      _loadingError =
          'Payment connection interrupted. Reload payment methods to check this payment.';
      notifyListeners();
      throw const PaymentPendingException();
    }
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
        OpenQueueCheckoutCancellationRepository,
        OpenQueueCheckoutNotificationRepository,
        OpenQueuePaymentStatusRepository,
        OpenQueueEmbeddedCheckoutRepository {
  final acknowledgedOutcomes = <String>[];
  @override
  Future<void> acknowledgeCheckoutNotification({
    required String paymentId,
    required String outcome,
  }) async {
    acknowledgedOutcomes.add('$paymentId:$outcome');
  }

  OpenQueueGame game = _game();
  int detailCalls = 0;
  Completer<OpenQueueMatchDetail>? detailBarrier;
  final quotedRoles = <OpenQueueRole>[];
  final bookedRoles = <OpenQueueRole>[];
  int quoteCalls = 0;
  int embeddedBookCalls = 0;
  int legacyBookCalls = 0;
  int price = 13000;
  int? preparedAmountFils;
  bool quoteFails = false;
  Completer<OpenQueueBookingCostPreview>? quoteBarrier;
  bool collectOnBook = true;
  String returnedStatus = 'CONFIRMED';
  String policyVersionId = 'policy-1';
  VoidCallback? beforeCollect;
  Object? afterCollectionError;
  Object? beforeCollectionError;
  String resumeState = 'COLLECTABLE';
  final resumeIntents = <String>[];
  final resumeRequests = <String?>[];
  Completer<void>? beforeCollectionBarrier;
  final refundChecks = <String>[];
  PaymentRefundState refundResponse = _refund();
  Object? refundCheckError;
  Completer<PaymentRefundState>? refundBarrier;
  OpenQueueBooking? recoveredBooking;
  Completer<OpenQueueBooking>? verification;
  final cancelledCheckouts = <String>[];
  final cancelledGames = <String>[];
  Completer<OpenQueueBooking?>? checkoutCancelBarrier;
  OpenQueueBooking? checkoutCancelResponse;
  Object? checkoutCancelError;

  @override
  Future<OpenQueueBooking?> cancelCheckout({
    required String intentId,
    required String gameId,
  }) async {
    cancelledCheckouts.add(intentId);
    cancelledGames.add(gameId);
    if (checkoutCancelError != null) throw checkoutCancelError!;
    if (checkoutCancelBarrier != null) return checkoutCancelBarrier!.future;
    return checkoutCancelResponse;
  }

  @override
  Future<OpenQueueBookingCostPreview> previewBookingCost({
    required String gameId,
    required OpenQueueRole role,
  }) async {
    quoteCalls++;
    quotedRoles.add(role);
    if (quoteBarrier != null) return quoteBarrier!.future;
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
    String? resumeIntentId,
    bool resumeOnly = false,
  }) async {
    embeddedBookCalls++;
    bookedRoles.add(role);
    if (resumeOnly || resumeIntentId != null) {
      resumeRequests.add(resumeIntentId);
      if (resumeIntentId != null) resumeIntents.add(resumeIntentId);
      if (resumeState == 'UNKNOWN' || resumeState == 'PROCESSING') {
        throw const PaymentPendingException();
      }
      if (resumeState == 'FINALIZED') return _booking(game);
      if (resumeState == 'REQUIRES_REFUND') {
        throw PaymentRefundException(_refund());
      }
    }
    if (beforeCollectionError != null) throw beforeCollectionError!;
    beforeCollect?.call();
    await beforeCollectionBarrier?.future;
    final amountFils = preparedAmountFils ?? price;
    if (collectOnBook && amountFils > 0) {
      await collectPayment(
        PaymentCollectionRequest(
          clientSecret: 'pi_embedded_test_secret_not_real',
          amountFils: amountFils,
          currency: 'USD',
          intentId: 'embedded-attempt',
          stripePaymentIntentId: 'pi_embedded_test',
          verifiedUnpaidResume: resumeOnly || resumeIntentId != null,
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
  Future<PaymentRefundState> checkRefundStatus(String intentId) async {
    refundChecks.add(intentId);
    if (refundCheckError != null) throw refundCheckError!;
    if (refundBarrier != null) return refundBarrier!.future;
    return refundResponse;
  }

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => [
    if (recoveredBooking != null) recoveredBooking!,
  ];

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async {
    detailCalls++;
    if (detailBarrier != null) return detailBarrier!.future;
    return OpenQueueMatchDetail(
      game: game,
      scorers: const [],
      timeline: const [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

OpenQueueGame _game({
  int keeperSpots = 2,
  int defenderSpots = 5,
  String status = 'OPEN',
  DateTime? start,
}) => OpenQueueGame(
  id: 'embedded-checkout-game',
  status: status,
  venue: 'Reach 11 Fields',
  startsAt: start ?? _now.add(const Duration(days: 2, hours: 3, minutes: 30)),
  endsAt: (start ?? _now.add(const Duration(days: 2, hours: 3, minutes: 30)))
      .add(const Duration(hours: 1)),
  timezone: 'America/Phoenix',
  currency: 'USD',
  priceFils: 13000,
  ageLabel: '18+',
  capacity: 14,
  confirmedCount: 3,
  spots: {
    OpenQueueRole.goalkeeper: keeperSpots,
    OpenQueueRole.defender: defenderSpots,
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

PaymentRefundState _refund({
  String status = 'REQUIRES_REFUND',
  String? refundStatus,
}) => PaymentRefundState(
  intentId: 'refund-attempt',
  status: status,
  refundStatus: refundStatus,
);
