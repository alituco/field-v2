import 'dart:async';
import 'dart:io';

import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
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
    double width = 390,
    double textScale = 1,
    String? ratingProfileId,
    FixturePlayerRatingUpdate? playerRatingUpdate,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: FieldrushGameDetailScreen(
          repository: repository,
          gameId: 'game',
          onJoin: onJoin,
          ratingProfileId: ratingProfileId,
          playerRatingUpdate: playerRatingUpdate,
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets(
    'held result explains review without promising a numeric SR update',
    (tester) async {
      await show(
        tester,
        _Repository(
          _detail(
            status: 'FINAL',
            ratingStatus: 'PENDING_REVIEW',
            ratingExplanation: 'Awaiting confirmed participation.',
            players: const [
              OpenQueuePlayer(
                id: 'me',
                displayName: 'Alex',
                role: OpenQueueRole.attacker,
                team: 'WHITE',
                played: true,
                isMe: true,
                ratingAtMatchStart: 1000,
                ratingChange: 40,
              ),
            ],
          ),
        ),
      );
      expect(find.text('Awaiting confirmed participation.'), findsOneWidget);
      expect(find.text('+40 SR'), findsNothing);
      expect(find.text('1000 → 1040'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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

  for (final sample in [
    (
      counted: false,
      delta: 0,
      explanation:
          'No SR change: 8 of the required 10 playing minutes completed.',
    ),
    (
      counted: false,
      delta: -5,
      explanation:
          'Conduct adjustment applied. This appearance is not counted.',
    ),
    (
      counted: true,
      delta: 0,
      explanation: 'This counted appearance settled with no SR change.',
    ),
  ]) {
    testWidgets(
      'settled result counted=${sample.counted} delta=${sample.delta} explains individual eligibility',
      (tester) async {
        await show(
          tester,
          _Repository(
            _detail(
              status: 'FINAL',
              ratingStatus: 'RATED',
              ratingExplanation: 'Match-wide calculation completed.',
              players: [
                OpenQueuePlayer(
                  id: 'me',
                  displayName: 'Alex',
                  role: OpenQueueRole.attacker,
                  team: 'WHITE',
                  played: true,
                  isMe: true,
                  ratingAtMatchStart: 1000,
                  ratingChange: sample.delta,
                  countedAsPlayed: sample.counted,
                  actualPlayedSeconds: 480,
                  ratingExplanation: sample.explanation,
                ),
              ],
            ),
          ),
        );
        expect(find.text(sample.explanation), findsOneWidget);
        expect(find.text('Match-wide calculation completed.'), findsNothing);
        expect(
          find.text('${sample.delta} SR'),
          sample.counted || sample.delta != 0 ? findsOneWidget : findsNothing,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('fieldrush-game-facts')),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.text(
            sample.counted
                ? 'Yes · counted appearance'
                : 'Appearance not counted',
          ),
          findsOneWidget,
        );
        expect(find.text('Yes · counts to skill rating'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

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

  testWidgets('assigned pregame teams remain visible with all SR private', (
    tester,
  ) async {
    final detail = _detail(
      status: 'FULL',
      count: 14,
      teamAssignmentAt: DateTime.utc(2000),
      teamsAssignedAt: DateTime.utc(2000),
      players: const [
        OpenQueuePlayer(
          id: 'white-player',
          displayName: 'White Player',
          role: OpenQueueRole.attacker,
          team: openQueueWhiteTeamId,
          played: false,
          isMe: false,
          ratingVisible: false,
        ),
        OpenQueuePlayer(
          id: 'black-player',
          displayName: 'Black Player',
          role: OpenQueueRole.goalkeeper,
          team: openQueueBlackTeamId,
          played: false,
          isMe: false,
          ratingVisible: false,
        ),
      ],
    );
    await show(tester, _Repository(detail));
    await tester.scrollUntilVisible(
      find.text('TEAMS'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('WHITE'), findsOneWidget);
    expect(find.text('BLACK'), findsOneWidget);
    expect(
      find.text(
        'Wear your assigned team colour. Tap See all for the full roster.',
      ),
      findsOneWidget,
    );
    expect(detail.game.whiteAverageSr, isNull);
    expect(detail.game.blackAverageSr, isNull);
    expect(detail.game.matchAverageSr, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'profile subject eligibility overrides viewer and stale history award',
    (tester) async {
      await show(
        tester,
        _Repository(
          _detail(
            status: 'FINAL',
            ratingStatus: 'RATED',
            players: const [
              OpenQueuePlayer(
                id: 'me',
                displayName: 'Viewer',
                role: OpenQueueRole.attacker,
                team: 'WHITE',
                played: true,
                isMe: true,
                countedAsPlayed: true,
                ratingAtMatchStart: 1000,
                ratingChange: 10,
                ratingExplanation: 'The viewer earned a counted appearance.',
              ),
              OpenQueuePlayer(
                id: 'other',
                displayName: 'Other',
                role: OpenQueueRole.attacker,
                team: 'BLACK',
                played: true,
                isMe: false,
                countedAsPlayed: false,
                actualPlayedSeconds: 480,
                ratingAtMatchStart: 1000,
                ratingChange: 0,
                ratingExplanation:
                    'Other completed fewer than ten playing minutes.',
              ),
            ],
          ),
        ),
        ratingProfileId: 'other',
        playerRatingUpdate: const FixturePlayerRatingUpdate(
          ratingBefore: 1000,
          ratingChange: 25,
          ratingAfter: 1025,
        ),
      );
      expect(
        find.text('Other completed fewer than ten playing minutes.'),
        findsOneWidget,
      );
      expect(
        find.text('The viewer earned a counted appearance.'),
        findsNothing,
      );
      expect(find.text('+25 SR'), findsNothing);
      expect(find.text('+10 SR'), findsNothing);
      expect(find.text('0 SR'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('fieldrush-game-facts')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Appearance not counted'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('configured division crests appear beside the game title', (
    tester,
  ) async {
    await show(
      tester,
      _Repository(_detail(highestDivision: 2, lowestDivision: 4)),
    );
    final band = find.byKey(const ValueKey('game-header-divisions'));
    expect(band, findsOneWidget);
    expect(find.text('DIV 2–4'), findsOneWidget);
    expect(
      tester.getRect(band).bottom,
      lessThan(
        tester.getRect(find.byKey(const ValueKey('fieldrush-game-hero'))).top,
      ),
    );
    expect(tester.widget<FieldrushGameDivisionRange>(band).compact, isTrue);
    expect(
      find.descendant(of: band, matching: find.byType(FieldrushDivisionShield)),
      findsNWidgets(3),
    );
    expect(find.text('Divisions'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('upcoming game details retain only the HTML facts rows', (
    tester,
  ) async {
    await show(
      tester,
      _Repository(
        _detail(
          durationMinutes: 60,
          teamAssignmentAt: DateTime.utc(2030, 1, 11, 23),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('fieldrush-game-facts')),
      200,
    );
    final facts = find.byKey(const ValueKey('fieldrush-game-facts'));
    for (final label in ['Format', 'Rated', 'Teams', 'Cancellation']) {
      expect(
        find.descendant(of: facts, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(find.text('7-a-side · 60 min slot'), findsOneWidget);
    expect(find.text('Yes · counts to skill rating'), findsOneWidget);
    expect(find.text('Drawn 4:00 PM'), findsOneWidget);
    expect(find.text('Shown before payment'), findsOneWidget);
    expect(find.text('Eligibility'), findsNothing);
    expect(find.text('18+'), findsNothing);
    expect(find.text('Divisions'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [(width: 320.0, scale: 1.0), (width: 390.0, scale: 2.0)]) {
    testWidgets('game header fits ${size.width}px with ${size.scale} text', (
      tester,
    ) async {
      await show(
        tester,
        _Repository(_detail(booked: true)),
        width: size.width,
        textScale: size.scale,
      );
      expect(find.text('Solo game'), findsOneWidget);
      expect(find.text('DIV 1–5'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('game-header-divisions')),
          matching: find.byType(FieldrushDivisionShield),
        ),
        findsNWidgets(5),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

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
    await tester.scrollUntilVisible(find.text('YOUR PARTY'), 150);
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
      find.text('Party changes are closed. You’re still in the game.'),
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
    expect(find.text('Invite to your party'), findsOneWidget);
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
  int highestDivision = 1,
  int lowestDivision = 5,
  DateTime? teamAssignmentAt,
  DateTime? teamsAssignedAt,
  int? white,
  int? black,
  List<OpenQueuePlayer> players = const [],
  String? ratingStatus,
  String? ratingExplanation,
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
    highestDivision: highestDivision,
    lowestDivision: lowestDivision,
    teamAssignmentAt: teamAssignmentAt,
    teamsAssignedAt: teamsAssignedAt,
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
  ratingStatus: ratingStatus,
  ratingExplanation: ratingExplanation,
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
