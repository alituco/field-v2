import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/open_queue/fieldrush_booking_flow.dart';
import 'package:field/src/open_queue/fieldrush_checkout_sheet.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2099, 6, 1);

void main() {
  test('matching chooses most needed selected position, never midfield', () {
    final game = _game('one');
    expect(fieldrushSuggestedRole(game, {}, _now), OpenQueueRole.defender);
    expect(
      fieldrushSuggestedRole(game, {
        OpenQueueRole.attacker,
        OpenQueueRole.goalkeeper,
      }, _now),
      OpenQueueRole.attacker,
    );
    expect(
      fieldrushSuggestedRole(game, {OpenQueueRole.midfielder}, _now),
      isNull,
    );
    expect(
      fieldrushSuggestedRole(_game('full', status: 'FULL'), {}, _now),
      isNull,
    );
    expect(
      fieldrushSuggestedRole(_game('cancelled', status: 'CANCELLED'), {}, _now),
      isNull,
    );
  });

  testWidgets(
    'three steps keep preferences and do not book until real checkout',
    (tester) async {
      final repository = _Repository([_game('one')]);
      await _pump(
        tester,
        FieldrushBookingFlow(repository: repository, now: _now),
      );
      expect(find.text('STEP 1 OF 3'), findsOneWidget);
      expect(find.text('MID'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('booking-position-ATT')));
      await tester.tap(find.byKey(const ValueKey('booking-position-GK')));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('booking-see-games')));
      await tester.pumpAndSettle();
      expect(find.text('STEP 2 OF 3'), findsOneWidget);
      expect(find.text('Your spot · Attacker'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('booking-game-one')));
      await tester.pumpAndSettle();
      expect(find.text('STEP 3 OF 3'), findsOneWidget);
      expect(find.text('Attacker'), findsOneWidget);
      expect(find.text('7v7'), findsOneWidget);
      expect(find.textContaining('60 min'), findsOneWidget);
      expect(repository.bookCalls, 0);
      await tester.ensureVisible(
        find.byKey(const ValueKey('booking-continue-payment')),
      );
      await tester.tap(find.byKey(const ValueKey('booking-continue-payment')));
      await tester.pumpAndSettle();
      expect(find.text('Pay for your spot'), findsOneWidget);
      expect(repository.bookCalls, 0);
      await tester.ensureVisible(
        find.byKey(const ValueKey('open-queue-confirm-payment')),
      );
      await tester.tap(
        find.byKey(const ValueKey('open-queue-confirm-payment')),
      );
      await tester.pumpAndSettle();
      expect(repository.bookCalls, 1);
      expect(repository.bookedRole, OpenQueueRole.attacker);
      expect(find.text('You’re in'), findsOneWidget);
      expect(find.text('View game'), findsOneWidget);
    },
  );

  for (final minimum in [2, 10]) {
    testWidgets('review shows capacity and $minimum-player minimum', (
      tester,
    ) async {
      final repository = _Repository([
        _game('minimum', minimumPlayers: minimum),
      ]);
      await _pump(
        tester,
        FieldrushBookingFlow(
          repository: repository,
          now: _now,
          startAtGames: true,
          initialRoles: const {OpenQueueRole.attacker},
        ),
      );
      await tester.tap(find.byKey(const ValueKey('booking-game-minimum')));
      await tester.pumpAndSettle();
      expect(find.text('STEP 3 OF 3'), findsOneWidget);
      expect(find.text('Up to 7v7'), findsOneWidget);
      expect(find.text('7v7'), findsNothing);
      expect(find.text('Players needed'), findsOneWidget);
      expect(find.text('$minimum minimum · 14 maximum'), findsOneWidget);
      expect(repository.bookCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Home starts at game choice with all selected positions', (
    tester,
  ) async {
    final repository = _Repository([_game('one'), _game('two', days: 5)]);
    await _pump(
      tester,
      FieldrushBookingFlow(
        repository: repository,
        now: _now,
        initialRoles: const {OpenQueueRole.attacker, OpenQueueRole.defender},
        startAtGames: true,
      ),
    );
    expect(find.text('STEP 2 OF 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('booking-game-one')), findsOneWidget);
    expect(find.byKey(const ValueKey('booking-game-two')), findsOneWidget);
    expect(repository.bookCalls, 0);
  });

  testWidgets('Saturday game keeps its configured kickoff and 90-minute slot', (
    tester,
  ) async {
    // Sunday UTC is still Saturday evening at the Phoenix field.
    final game = _game(
      'saturday',
      start: DateTime.utc(2099, 6, 7, 1, 15),
      durationMinutes: 90,
    );
    final repository = _Repository([game]);
    await _pump(
      tester,
      FieldrushBookingFlow(
        repository: repository,
        now: _now,
        startAtGames: true,
        initialRoles: const {OpenQueueRole.defender},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('booking-game-saturday')));
    await tester.pumpAndSettle();
    expect(find.text('STEP 3 OF 3'), findsOneWidget);
    expect(find.text('SAT, 6 JUN'), findsOneWidget);
    expect(find.text('SOLO SLOT · 6:15 PM'), findsOneWidget);
    expect(find.text('Reach 11 Fields · 90 min'), findsOneWidget);
    expect(find.text('7v7'), findsOneWidget);
    expect(repository.bookCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'no preference matches offers explicit sooner out-of-position game',
    (tester) async {
      final repository = _Repository([_game('one', keeper: 0)]);
      await _pump(
        tester,
        FieldrushBookingFlow(
          repository: repository,
          now: _now,
          initialRoles: const {OpenQueueRole.goalkeeper},
          startAtGames: true,
        ),
      );
      expect(find.text('OR PLAY SOONER'), findsOneWidget);
      expect(find.text('Out of position · Defender'), findsOneWidget);
      expect(find.byKey(const ValueKey('booking-game-one')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('booking-game-one-sooner')));
      await tester.pumpAndSettle();
      expect(find.text('Defender'), findsOneWidget);
      expect(repository.bookCalls, 0);
    },
  );

  testWidgets(
    'specific fixture requires a position and stops after an existing booking',
    (tester) async {
      final game = _game('one');
      final repository = _Repository([game]);
      await _pump(
        tester,
        FieldrushBookingFlow(
          repository: repository,
          now: _now,
          initialGame: game,
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('booking-continue-payment')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('booking-review-position-DEF')),
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('booking-continue-payment')),
            )
            .onPressed,
        isNotNull,
      );
      repository.bookings = [_booking(game)];
      await tester.drag(find.byType(ListView), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('booking-active-game-limit')),
        findsOneWidget,
      );
      expect(repository.bookCalls, 0);
      expect(find.byType(FieldrushCheckoutSheet), findsNothing);
      expect(
        find.byKey(const ValueKey('booking-continue-payment')),
        findsNothing,
      );
    },
  );

  testWidgets('one upcoming game blocks a different-day second checkout', (
    tester,
  ) async {
    final current = _game('already-booked');
    final next = _game('different-day', days: 5);
    final repository = _Repository([current, next])
      ..bookings = [_booking(current)];
    await _pump(
      tester,
      FieldrushBookingFlow(
        repository: repository,
        initialGame: next,
        now: _now,
      ),
    );
    expect(find.text('You’re already in a game'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('booking-view-active-game')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('booking-continue-payment')),
      findsNothing,
    );
    expect(find.byType(FieldrushCheckoutSheet), findsNothing);
    expect(repository.bookCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finalized and cancelled games do not block a new booking flow', (
    tester,
  ) async {
    final finished = _game('finished', status: 'FINAL');
    final cancelled = _game('cancelled', status: 'CANCELLED');
    final next = _game('next');
    final repository = _Repository([next])
      ..bookings = [_booking(finished), _booking(cancelled)];
    await _pump(
      tester,
      FieldrushBookingFlow(
        repository: repository,
        initialGame: next,
        now: _now,
      ),
    );
    expect(
      find.byKey(const ValueKey('booking-active-game-limit')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('booking-continue-payment')),
      findsOneWidget,
    );
    expect(repository.bookCalls, 0);
  });

  testWidgets('empty feed has no invented games or checkout', (tester) async {
    await _pump(
      tester,
      FieldrushBookingFlow(
        repository: _Repository([]),
        now: _now,
        startAtGames: true,
      ),
    );
    expect(
      find.text('No upcoming games are open yet. Check back soon.'),
      findsOneWidget,
    );
    expect(find.text('Confirm and pay'), findsNothing);
  });

  testWidgets('changed price stops payment until reviewed again', (
    tester,
  ) async {
    final repository = _Repository([_game('one')]);
    await _pump(
      tester,
      FieldrushCheckoutSheet(
        repository: repository,
        game: repository.games.first,
        role: OpenQueueRole.attacker,
      ),
    );
    repository.price = 15000;
    await tester.ensureVisible(
      find.byKey(const ValueKey('open-queue-confirm-payment')),
    );
    await tester.tap(find.byKey(const ValueKey('open-queue-confirm-payment')));
    await tester.pumpAndSettle();
    expect(repository.bookCalls, 0);
    expect(find.textContaining('Your booking terms changed'), findsOneWidget);
    expect(find.textContaining(r'$15.00'), findsWidgets);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      'checkout keeps $platform methods and the quoted CTA',
      (tester) async {
        final walletName = switch (platform) {
          TargetPlatform.android => 'Google Pay',
          TargetPlatform.iOS => 'Apple Pay',
          _ => null,
        };
        final repository = _Repository([_game('one')]);
        await _pump(
          tester,
          FieldrushCheckoutSheet(
            repository: repository,
            game: repository.games.first,
            role: OpenQueueRole.attacker,
          ),
          size: const Size(320, 740),
          scale: 1.6,
        );
        expect(
          find.text(walletName == null ? 'Card' : 'Card or $walletName'),
          findsOneWidget,
        );
        expect(
          find.text(
            walletName == null
                ? 'Choose securely in the app.'
                : 'Choose securely in the app. $walletName appears on supported devices.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Choose securely in Stripe'), findsNothing);
        expect(find.text(r'Continue to Pay · $13.00'), findsOneWidget);
        await tester.ensureVisible(find.text('Secure payments by Stripe'));
        await tester.pumpAndSettle();
        expect(find.text('Secure payments by Stripe'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(repository.bookCalls, 0);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('quote failure disables checkout and can be retried', (
    tester,
  ) async {
    final repository = _Repository([_game('one')])..quoteFails = true;
    await _pump(
      tester,
      FieldrushCheckoutSheet(
        repository: repository,
        game: repository.games.first,
        role: OpenQueueRole.attacker,
      ),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('open-queue-confirm-payment')),
          )
          .onPressed,
      isNull,
    );
    repository.quoteFails = false;
    await tester.ensureVisible(find.text('Retry price check'));
    await tester.tap(find.text('Retry price check'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('open-queue-confirm-payment')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'double taps do not duplicate payment and failure does not confirm',
    (tester) async {
      final repository = _Repository([_game('one')])
        ..pending = Completer<OpenQueueBooking>();
      await _pump(
        tester,
        FieldrushCheckoutSheet(
          repository: repository,
          game: repository.games.first,
          role: OpenQueueRole.attacker,
        ),
      );
      final button = find.byKey(const ValueKey('open-queue-confirm-payment'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      expect(repository.bookCalls, 1);
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
      repository.pending!.completeError(StateError('Payment declined'));
      await tester.pumpAndSettle();
      expect(find.text('You’re in'), findsNothing);
      expect(find.textContaining('Payment declined'), findsOneWidget);
    },
  );

  testWidgets('small screen and large text have no layout exceptions', (
    tester,
  ) async {
    await _pump(
      tester,
      FieldrushBookingFlow(repository: _Repository([_game('one')]), now: _now),
      size: const Size(320, 740),
      scale: 1.6,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('booking-see-games')),
      200,
    );
    await tester.tap(find.byKey(const ValueKey('booking-see-games')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('booking-step-2')), findsOneWidget);
    final game = find.byKey(const ValueKey('booking-game-one'));
    await tester.scrollUntilVisible(game, 150);
    await tester.ensureVisible(game);
    await tester.pumpAndSettle();
    await tester.tap(game);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('booking-step-3')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('render booking flow with bundled fonts', (tester) async {
    if (!const bool.fromEnvironment('WRITE_FIELDRUSH_PREVIEWS')) return;
    await tester.runAsync(() async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        final loader = FontLoader(font)
          ..addFont(rootBundle.load('assets/fonts/$font.ttf'));
        await loader.load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    await _pump(
      tester,
      RepaintBoundary(
        key: const ValueKey('preview'),
        child: FieldrushBookingFlow(
          repository: _Repository([_game('one'), _game('two', days: 5)]),
          now: _now,
          onNavigateTab: (_) {},
        ),
      ),
    );
    final directory = Directory('build/fieldrush-previews')
      ..createSync(recursive: true);
    for (var step = 1; step <= 3; step++) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${directory.path}/booking-step-$step.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      if (step == 1) {
        await tester.tap(find.byKey(const ValueKey('booking-see-games')));
      }
      if (step == 2) {
        await tester.tap(find.byKey(const ValueKey('booking-game-one')));
      }
      await tester.pumpAndSettle();
    }
  });

  testWidgets('bottom navigation leaves selection without making a booking', (
    tester,
  ) async {
    final repository = _Repository([_game('one')]);
    int? selectedTab;
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FieldrushBookingFlow(
                repository: repository,
                now: _now,
                startAtGames: true,
                onNavigateTab: (index) => selectedTab = index,
              ),
            ),
          ),
          child: const Text('Open flow'),
        ),
      ),
    );
    await tester.tap(find.text('Open flow'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('field-bottom-nav-item-4')));
    await tester.pumpAndSettle();
    expect(selectedTab, 4);
    expect(find.byType(FieldrushBookingFlow), findsNothing);
    expect(repository.bookCalls, 0);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, body) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: body!,
      ),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

OpenQueueGame _game(
  String id, {
  int days = 2,
  int keeper = 2,
  String status = 'OPEN',
  DateTime? start,
  int durationMinutes = 60,
  int? minimumPlayers,
}) => OpenQueueGame(
  id: id,
  status: status,
  venue: 'Reach 11 Fields',
  startsAt: start ?? _now.add(Duration(days: days, hours: 3, minutes: 30)),
  endsAt: (start ?? _now.add(Duration(days: days, hours: 3, minutes: 30))).add(
    Duration(minutes: durationMinutes),
  ),
  timezone: 'America/Phoenix',
  currency: 'USD',
  priceFils: 13000,
  ageLabel: '18+',
  capacity: 14,
  minimumPlayers: minimumPlayers ?? 10,
  participationRulesVersion: minimumPlayers == null
      ? 'legacy-fixed-v1'
      : 's0-configurable-v1',
  confirmedCount: 3,
  spots: {
    OpenQueueRole.goalkeeper: keeper,
    OpenQueueRole.defender: 5,
    OpenQueueRole.attacker: 4,
  },
  teamAssignmentLeadMinutes: 180,
);

OpenQueueBooking _booking(
  OpenQueueGame game, {
  OpenQueueRole role = OpenQueueRole.attacker,
}) => OpenQueueBooking(
  id: 'booking-${game.id}',
  gameId: game.id,
  profileId: 'me',
  role: role,
  status: 'CONFIRMED',
  amountPaidFils: 13000,
  bookedAt: _now,
  game: game,
);

class _Repository
    implements
        OpenQueueRepository,
        OpenQueueMarketRepository,
        OpenQueueBookingCostPreviewRepository {
  _Repository(this.games);
  List<OpenQueueGame> games;
  List<OpenQueueBooking> bookings = [];
  int bookCalls = 0;
  int price = 13000;
  bool quoteFails = false;
  OpenQueueRole? bookedRole;
  Completer<OpenQueueBooking>? pending;
  @override
  Future<List<OpenQueueGame>> listGames() async => games;
  @override
  Future<List<OpenQueueGame>> listMarketGames(String timezone) async => games;
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => bookings;
  @override
  Future<OpenQueueBookingCostPreview> previewBookingCost({
    required String gameId,
    required OpenQueueRole role,
  }) async {
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
      policyVersionId: 'policy-1',
    );
  }

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async {
    bookCalls++;
    bookedRole = role;
    return pending != null ? pending!.future : _booking(game, role: role);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
