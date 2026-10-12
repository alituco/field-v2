import 'dart:async';
import 'dart:io';

import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/helpers/staging_test_helpers.dart';

void main() {
  setUpAll(() async {
    for (final font in ['Outfit', 'PlusJakartaSans']) {
      await (FontLoader(
        font,
      )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  Future<void> show(
    WidgetTester tester,
    _Repository repository, {
    Future<void> Function(OpenQueueGame)? onJoin,
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: FieldrushGameDetailScreen(
          repository: repository,
          gameId: 'game',
          onJoin: onJoin,
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('join opens selection flow without making a booking', (
    tester,
  ) async {
    final repository = _Repository(_detail());
    OpenQueueGame? selected;
    await show(
      tester,
      repository,
      onJoin: (game) async {
        selected = game;
      },
    );
    expect(find.text('Solo game'), findsOneWidget);
    expect(find.text('Join · \$10.00'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('game-main-action')));
    await tester.pumpAndSettle();
    expect(selected?.id, 'game');
    expect(repository.bookCalls, 0);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        'goldens/${Platform.operatingSystem}/fieldrush_game_detail_open.png',
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('full fixture cannot enter checkout', (tester) async {
    final repository = _Repository(_detail(status: 'FULL', count: 14));
    var joins = 0;
    await show(
      tester,
      repository,
      onJoin: (_) async {
        joins++;
      },
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('game-main-action')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Game full'), findsOneWidget);
    expect(joins, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saved field address is shown without changing legacy layouts', (
    tester,
  ) async {
    await show(tester, _Repository(_detail(withLocation: true)));
    expect(
      find.byKey(const ValueKey('fieldrush-game-address')),
      findsOneWidget,
    );
    expect(
      find.text('2425 E Deer Valley Road, Phoenix, AZ, US'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Saturday fixture shows the actual kickoff and 90-minute slot', (
    tester,
  ) async {
    final detail = _detail(
      start: DateTime.utc(2030, 1, 13, 1, 15),
      durationMinutes: 90,
    );
    await show(tester, _Repository(detail));
    expect(find.textContaining('SAT, 12 JAN'), findsOneWidget);
    expect(find.text('6:15 PM', findRichText: true), findsOneWidget);
    final format = find.text('7-a-side · 90 min slot');
    await tester.scrollUntilVisible(format, 250);
    expect(format, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('empty data does not invent ratings, events or a video', (
    tester,
  ) async {
    final repository = _Repository(_detail());
    await show(tester, repository);
    expect(
      find.text('Skill ratings appear when player ratings are available.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('game-tab-timeline')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Nothing yet. Match events appear here once they are recorded by the referee.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('game-tab-watch')));
    await tester.pumpAndSettle();
    expect(find.text('No video available yet'), findsOneWidget);
    expect(find.text('Clip'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('roster groups real players with their real skill ratings', (
    tester,
  ) async {
    final repository = _Repository(
      _detail(
        players: const [
          OpenQueuePlayer(
            id: 'ada',
            displayName: 'Ada Player',
            role: OpenQueueRole.attacker,
            team: '',
            played: false,
            isMe: true,
            ratingAtMatchStart: 1375,
          ),
          OpenQueuePlayer(
            id: 'sam',
            displayName: 'Sam Keeper',
            role: OpenQueueRole.goalkeeper,
            team: '',
            played: false,
            isMe: false,
          ),
        ],
      ),
    );
    await show(tester, repository);
    await tester.scrollUntilVisible(find.text('See all ›'), 180);
    await tester.tap(find.text('See all ›'));
    await tester.pumpAndSettle();
    expect(find.text('Players'), findsOneWidget);
    expect(find.text('ATTACKERS'), findsOneWidget);
    expect(find.text('GOALKEEPERS'), findsOneWidget);
    expect(find.text('Ada Player'), findsOneWidget);
    expect(find.text('1375'), findsOneWidget);
    expect(find.text('Sam Keeper'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('final result with missing score does not invent zero goals', (
    tester,
  ) async {
    final repository = _Repository(_detail(status: 'FINAL'));
    await show(tester, repository);
    expect(find.text('FULL TIME'), findsOneWidget);
    expect(find.text('Result not published yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('game-main-action')), findsNothing);
    expect(find.text('0'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelled game removes booking CTA', (tester) async {
    await show(tester, _Repository(_detail(status: 'CANCELLED')));
    expect(find.text('Game cancelled'), findsOneWidget);
    expect(find.byKey(const ValueKey('game-main-action')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending review suppresses stored score and join action', (
    tester,
  ) async {
    await show(
      tester,
      _Repository(_detail(status: 'FINAL', review: true, white: 4, black: 2)),
    );
    expect(find.text('Under review'), findsOneWidget);
    expect(find.text('FULL TIME'), findsNothing);
    expect(find.byKey(const ValueKey('game-main-action')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final destination in ['ORIGINAL_PAYMENT_METHOD', 'FIELD_WALLET']) {
    testWidgets('cancellation narrative respects $destination refund routing', (
      tester,
    ) async {
      const explanation =
          'Cancellation outcome: Cancelled early. No reliability strike is added. '
          '100% of the match fee returns to your Field Wallet.';
      final repository = _Repository(_detail(booked: true));
      repository.booking = _booking(repository.detail.game);
      repository.previews = [
        OpenQueueCancellationPreview(
          canCancel: true,
          refundPercent: 100,
          refundAmountFils: 10000,
          refundCutoffAt: null,
          currency: 'USD',
          refundDestination: destination,
          explanation: explanation,
        ),
      ];
      await show(tester, repository);
      await tester.tap(find.text('Leave game'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Leave this game?'), findsOneWidget);
      final expected = destination == 'ORIGINAL_PAYMENT_METHOD'
          ? explanation.replaceAll('Field Wallet', 'original payment method')
          : explanation;
      expect(find.text(expected), findsOneWidget);
      if (destination == 'ORIGINAL_PAYMENT_METHOD') {
        expect(find.text(explanation), findsNothing);
        expect(
          find.textContaining('100% to your original payment method'),
          findsOneWidget,
        );
      }
      expect(repository.cancelCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Stay in game'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('cancellation revalidates changed terms before writing', (
    tester,
  ) async {
    final repository = _Repository(_detail(booked: true));
    repository.booking = _booking(repository.detail.game);
    repository.previews = [
      const OpenQueueCancellationPreview(
        canCancel: true,
        refundPercent: 100,
        refundAmountFils: 10000,
        refundCutoffAt: null,
        currency: 'USD',
      ),
      const OpenQueueCancellationPreview(
        canCancel: true,
        refundPercent: 50,
        refundAmountFils: 5000,
        refundCutoffAt: null,
        strikeDelta: 1,
        currency: 'USD',
      ),
    ];
    await show(tester, repository);
    await tester.tap(find.text('Leave game'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Leave this game?'), findsOneWidget);
    expect(repository.cancelCalls, 0);
    await tester.tap(find.text('Confirm cancellation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Cancellation terms changed'), findsOneWidget);
    expect(repository.cancelCalls, 0);
    await tester.tap(find.text('Confirm cancellation'));
    await tester.pumpAndSettle();
    expect(repository.previewCalls, 3);
    expect(repository.cancelCalls, 1);
    expect(find.text('Leave game'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('party starts with viewer and uses server cutoff in venue time', (
    tester,
  ) async {
    final repository = _PartyRepository(_detail(booked: true));
    repository.booking = _booking(repository.detail.game);
    await show(tester, repository);
    await tester.scrollUntilVisible(find.text('PLAY TOGETHER'), 150);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Invite'), findsNWidgets(3));
    expect(find.text('Invites close 5:30 PM'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        'goldens/${Platform.operatingSystem}/fieldrush_game_detail_party.png',
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('locked party does not offer invitation actions', (tester) async {
    final repository = _PartyRepository(_detail(booked: true), locked: true);
    repository.booking = _booking(repository.detail.game);
    await show(tester, repository);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('fieldrush-game-party')),
      150,
    );
    expect(find.text('Invite'), findsNothing);
    expect(
      find.text(
        'Party changes are closed for this game. Your confirmed booking is unchanged.',
      ),
      findsOneWidget,
    );
    Object? failure;
    try {
      await tapAfterScroll(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('fieldrush-game-party')),
          matching: find.text('Invite'),
        ),
        timeout: const Duration(milliseconds: 500),
      );
    } catch (error) {
      failure = error;
    }
    expect(failure, isA<TestFailure>());
    expect(repository.createPartyCalls, 0);
    expect(
      find.byKey(const ValueKey('party-invite-sheet-close')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('party invitation waits for delayed slots and creates once', (
    tester,
  ) async {
    final ready = Completer<void>();
    final repository = _PartyRepository(
      _detail(booked: true),
      initialLoad: ready.future,
    );
    repository.booking = _booking(repository.detail.game);
    await show(tester, repository, settle: false);
    final party = find.byKey(const ValueKey('fieldrush-game-party'));
    await scrollUntilFound(tester, party);
    // Keep the finder unsliced: .first throws while the async slots are absent,
    // before tapAfterScroll can wait for the real party controls to appear.
    final inviteSlots = find.descendant(
      of: party,
      matching: find.text('Invite'),
    );
    expect(inviteSlots, findsNothing);
    expect(repository.createPartyCalls, 0);
    final timer = Timer(
      const Duration(milliseconds: 600),
      () => ready.complete(),
    );
    addTearDown(timer.cancel);

    await tapAfterScroll(tester, inviteSlots);
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('party-invite-sheet-close')),
    );

    expect(inviteSlots, findsNWidgets(3));
    expect(find.text('Invite confirmed players'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('invite-party-player-target')),
      findsOneWidget,
    );
    expect(repository.createPartyCalls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

OpenQueueMatchDetail _detail({
  String status = 'OPEN',
  int count = 3,
  bool booked = false,
  bool review = false,
  bool withLocation = false,
  DateTime? start,
  int durationMinutes = 60,
  int? white,
  int? black,
  List<OpenQueuePlayer> players = const [],
}) => OpenQueueMatchDetail(
  game: OpenQueueGame(
    id: 'game',
    status: status,
    venue: 'Reach 11 Fields · Field 2',
    fieldId: withLocation ? 'field-1' : null,
    locationAddress: withLocation ? '2425 E Deer Valley Road' : null,
    locationCity: withLocation ? 'Phoenix' : null,
    locationState: withLocation ? 'AZ' : null,
    locationCountryCode: withLocation ? 'US' : null,
    locationLatitude: withLocation ? 33.6849 : null,
    locationLongitude: withLocation ? -112.0308 : null,
    startsAt: start ?? DateTime.utc(2030, 1, 12, 1),
    endsAt: (start ?? DateTime.utc(2030, 1, 12, 1)).add(
      Duration(minutes: durationMinutes),
    ),
    timezone: 'America/Phoenix',
    priceFils: 10000,
    currency: 'USD',
    ageLabel: '18+',
    capacity: 14,
    confirmedCount: count,
    spots: const {
      OpenQueueRole.goalkeeper: 2,
      OpenQueueRole.defender: 4,
      OpenQueueRole.attacker: 5,
    },
    myBookingId: booked ? 'booking' : null,
    myBookingRole: booked ? OpenQueueRole.attacker : null,
    operationalState: review
        ? MatchOperationalState.underReview
        : MatchOperationalState.normal,
    whiteScore: white,
    blackScore: black,
  ),
  scorers: const [],
  timeline: const [],
  players: players,
);

OpenQueueBooking _booking(OpenQueueGame game) => OpenQueueBooking(
  id: 'booking',
  gameId: game.id,
  profileId: 'me',
  role: OpenQueueRole.attacker,
  status: 'CONFIRMED',
  amountPaidFils: 10000,
  bookedAt: DateTime.utc(2029, 12),
  game: game,
);

class _Repository implements OpenQueueRepository {
  _Repository(this.detail);
  OpenQueueMatchDetail detail;
  OpenQueueBooking? booking;
  int bookCalls = 0;
  int cancelCalls = 0;
  int previewCalls = 0;
  List<OpenQueueCancellationPreview> previews = [];
  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async => detail;
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => [
    if (booking != null) booking!,
  ];
  @override
  Future<OpenQueueCancellationPreview> previewCancellation(
    String bookingId,
  ) async {
    final index = previewCalls++;
    return previews[index.clamp(0, previews.length - 1)];
  }

  @override
  Future<OpenQueueBooking> cancelBooking(String bookingId) async {
    cancelCalls++;
    final cancelled = booking!;
    booking = null;
    detail = _detail();
    return cancelled;
  }

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async {
    bookCalls++;
    return _booking(game);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PartyRepository extends _Repository implements OpenQueuePartyRepository {
  _PartyRepository(super.detail, {this.locked = false, this.initialLoad});
  final bool locked;
  final Future<void>? initialLoad;
  int createPartyCalls = 0;
  @override
  Future<OpenQueuePartyContext> getPartyContext(String gameId) async {
    if (initialLoad != null) await initialLoad;
    return OpenQueuePartyContext(
      gameId: gameId,
      gameStatus: 'OPEN',
      canUseParties: !locked,
      maxPartySize: 4,
      receivedInvites: const [],
      eligiblePlayers: const [
        OpenQueuePartyPlayer(
          profileId: 'target',
          displayName: 'Target Player',
          role: OpenQueueRole.defender,
        ),
      ],
      myParty: createPartyCalls == 0
          ? null
          : const OpenQueueParty(
              id: 'party',
              ownerProfileId: 'me',
              isOwner: true,
              acceptedCount: 1,
              members: [
                OpenQueuePartyMember(
                  membershipId: 'owner-member',
                  profileId: 'me',
                  displayName: 'Main Player',
                  role: OpenQueueRole.attacker,
                  status: OpenQueuePartyMemberStatus.accepted,
                  isOwner: true,
                  invitedAt: null,
                ),
              ],
            ),
      partyLockAt: DateTime.utc(2030, 1, 12, 0, 30),
    );
  }

  @override
  Future<String> createParty(String gameId) async {
    createPartyCalls++;
    return 'party';
  }
}
