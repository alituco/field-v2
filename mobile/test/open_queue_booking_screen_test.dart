import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_booking_screen.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
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
      'Continue to Secure Checkout',
    );
    await tester.ensureVisible(checkoutButton);
    await tester.pump();
    await tester.pump();
    await tester.tap(checkoutButton);
    await tester.pumpAndSettle();
    final bookButton = find.widgetWithText(
      FilledButton,
      'Continue to Pay · 3 BHD',
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

  testWidgets('checkout requires reconfirmation when the exact total changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _ChangingCostOpenQueueRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueReviewScreen(
          repository: repository,
          game: _booking().game,
          role: OpenQueueRole.defender,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final checkoutButton = find.widgetWithText(
      FilledButton,
      'Continue to Secure Checkout',
    );
    await _bringAboveFloatingNav(tester, checkoutButton);
    await tester.tap(checkoutButton);
    await tester.pumpAndSettle();

    final initialBookButton = find.widgetWithText(
      FilledButton,
      'Continue to Pay · 3 BHD',
    );
    await _bringAboveFloatingNav(tester, initialBookButton);
    await tester.tap(initialBookButton);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Your booking terms changed. Review the updated total and deposit, then confirm again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Continue to Pay · 4 BHD'), findsOneWidget);
    expect(repository.bookCalls, 0);
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

  testWidgets('confirmed booking renders the server policy kit cutoff', (
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
          booking: _booking(fullBeforeCutoff: true, assignmentLeadMinutes: 90),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MATCH CONFIRMED'), findsOneWidget);
    expect(
      find.text('Assigned 1 hour 30 minutes before kickoff'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('kit-assignment-scheduled')),
      findsOneWidget,
    );
    expect(
      find.text('ASSIGNED 1 HOUR 30 MINUTES BEFORE KICKOFF'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Teams and kits are finalized 1 hour 30 minutes before kickoff',
      ),
      findsOneWidget,
    );
    expect(find.text('WEAR WHITE'), findsNothing);
    expect(find.byKey(const ValueKey('kit-instruction')), findsNothing);
    expect(find.byKey(const ValueKey('kit-assignment-updating')), findsNothing);
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
        outcomeCode: 'CANCELLED_LATE',
        strikeDelta: 1,
        refundBps: 5000,
        refundDestination: 'FIELD_WALLET',
        depositForfeited: true,
        explanation:
            'This booking is inside the late-cancellation policy window.',
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
    expect(find.text('LATE CANCELLATION'), findsOneWidget);
    expect(
      find.text(
        '50% to your Field wallet\n'
        '1.500 BHD to Field wallet\n'
        '+1 reliability strike\n'
        'Reliability deposit forfeited',
      ),
      findsOneWidget,
    );
    expect(find.text('Keep my spot'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('field-confirmation-cancel')));
    await tester.pumpAndSettle();

    expect(repository.cancelCalls, 0);
    expect(find.text('BOOKING DETAILS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new reservation makes the create-party promise prominent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PartyOpenQueueRepository(_emptyPartyContext());

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueBookingScreen(
          repository: repository,
          booking: _booking(),
          newlyBooked: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('SPOT SECURED · NEXT'), findsOneWidget);
    expect(find.text('Bring your people.'), findsOneWidget);
    expect(find.textContaining('up to 4 confirmed players'), findsOneWidget);
    expect(find.textContaining('assigned to the same team'), findsOneWidget);
    expect(
      find.text('Party changes close 3 hours before kickoff.'),
      findsOneWidget,
    );

    final create = find.byKey(const ValueKey('create-open-queue-party'));
    await _bringAboveFloatingNav(tester, create);
    await tester.tap(create);
    await tester.pumpAndSettle();

    expect(repository.createCalls, 1);
    expect(find.text('YOUR PARTY'), findsOneWidget);
    expect(find.text('1/4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('party creation shows the server policy lock cutoff', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PartyOpenQueueRepository(
      _emptyPartyContext(canUseParties: false, partyLockLeadMinutes: 75),
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

    expect(
      find.byKey(const ValueKey('open-queue-party-locked')),
      findsOneWidget,
    );
    expect(
      find.text(
        'Parties close 1 hour 15 minutes before kickoff so teams and kits can be finalized.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('create-open-queue-party')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending party invite is prominent and opens its response flow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PartyOpenQueueRepository(_invitedPartyContext());

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueBookingScreen(
          repository: repository,
          booking: _booking(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('open-queue-party-invite')),
      findsOneWidget,
    );
    expect(
      find.text('Noor Saleh invited you to play together'),
      findsOneWidget,
    );
    expect(find.text('PARTY INVITE · ACTION NEEDED'), findsOneWidget);
    expect(find.byKey(const ValueKey('create-open-queue-party')), findsNothing);
    expect(
      find.byKey(const ValueKey('open-queue-party-invite-response-flow')),
      findsNothing,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('open-queue-party-invite')))
          .dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('match-day-kit-panel'))).dy,
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('open-queue-party-invite-indicator')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('open-queue-party-invite-response-flow')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('decline-open-queue-party-invite')),
      findsOneWidget,
    );

    final accept = find.byKey(const ValueKey('accept-open-queue-party-invite'));
    await _bringAboveFloatingNav(tester, accept);
    await tester.tap(accept);
    await tester.pumpAndSettle();

    expect(repository.acceptedInvites, 1);
    expect(find.text('YOUR PARTY'), findsOneWidget);
    expect(find.text('2/4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('accepting a party refreshes a rebalanced team and kit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PartyOpenQueueRepository(
      _invitedPartyContext(),
      bookingAfterMutation: _booking(
        assigned: true,
        assignedTeam: openQueueBlackTeamId,
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

    expect(find.text('WEAR BLACK'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('open-queue-party-invite-indicator')),
    );
    await tester.pumpAndSettle();
    final accept = find.byKey(const ValueKey('accept-open-queue-party-invite'));
    await _bringAboveFloatingNav(tester, accept);
    await tester.tap(accept);
    await tester.pumpAndSettle();

    final kit = find.text('WEAR BLACK');
    await _bringAboveFloatingNav(tester, kit);
    expect(kit, findsOneWidget);
    final team = find.text('BLACK TEAM');
    await _bringAboveFloatingNav(tester, team);
    expect(team, findsOneWidget);
    expect(find.text('WEAR WHITE'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an invite stays prominent while in another party and can switch',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _PartyOpenQueueRepository(_partySwitchInviteContext());

      await tester.pumpWidget(
        MaterialApp(
          home: OpenQueueBookingScreen(
            repository: repository,
            booking: _booking(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('open-queue-party-invite-indicator')),
        findsOneWidget,
      );
      expect(find.text('YOUR PARTY'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('open-queue-party-invite-indicator')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('open-queue-party-switch-warning')),
        findsOneWidget,
      );
      expect(
        find.textContaining('move you out of your current party'),
        findsOneWidget,
      );
      expect(find.text('Switch & join'), findsOneWidget);

      final accept = find.byKey(
        const ValueKey('accept-open-queue-party-invite'),
      );
      await _bringAboveFloatingNav(tester, accept);
      await tester.tap(accept);
      await tester.pumpAndSettle();

      expect(repository.acceptedInvites, 1);
      expect(find.text('YOUR PARTY'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('open-queue-party-invite')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('party owner sees roles and pending invitation controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PartyOpenQueueRepository(_ownedPartyContext());

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueBookingScreen(
          repository: repository,
          booking: _booking(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('YOUR PARTY'), findsOneWidget);
    expect(find.text('INVITED'), findsOneWidget);
    expect(find.textContaining('Defender'), findsWidgets);
    expect(
      find.byKey(const ValueKey('cancel-party-invite-membership-pending')),
      findsOneWidget,
    );

    final invite = find.byKey(const ValueKey('invite-open-queue-party-player'));
    await _bringAboveFloatingNav(tester, invite);
    await tester.tap(invite);
    await tester.pumpAndSettle();

    expect(find.text('Invite confirmed players'), findsOneWidget);
    expect(find.text('Layla Abbas'), findsOneWidget);
    expect(find.textContaining('Midfielder'), findsOneWidget);
    expect(find.textContaining('IN A PARTY · 2/4'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('invite-party-player-player-layla')),
    );
    await tester.pumpAndSettle();

    expect(repository.sentInvites, 1);
    expect(find.text('Sent'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling a party uses the themed confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PartyOpenQueueRepository(_ownedPartyContext());

    await tester.pumpWidget(
      MaterialApp(
        home: OpenQueueBookingScreen(
          repository: repository,
          booking: _booking(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final disband = find.byKey(const ValueKey('disband-open-queue-party'));
    await _bringAboveFloatingNav(tester, disband);
    await tester.tap(disband);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('field-confirmation-dialog')),
      findsOneWidget,
    );
    expect(find.text('Cancel this party?'), findsOneWidget);
    expect(
      find.text('Everyone keeps their individual match booking.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('field-confirmation-confirm')));
    await tester.pumpAndSettle();
    expect(repository.disbandCalls, 1);
    expect(find.text('PLAY TOGETHER'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing party locks every mutation after the party cutoff', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PartyOpenQueueRepository(
      _ownedPartyContext(canUseParties: false),
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

    final lockNotice = find.byKey(
      const ValueKey('open-queue-party-mutations-locked'),
    );
    await _bringAboveFloatingNav(tester, lockNotice);
    expect(lockNotice, findsOneWidget);
    expect(find.text('Party changes closed'), findsOneWidget);
    expect(find.text('Party locked for this match'), findsOneWidget);
    expect(
      find.text(
        'Party changes close 3 hours before kickoff. Your confirmed group stays together, but no one can be invited, removed, or leave now.',
      ),
      findsOneWidget,
    );

    final invite = tester.widget<FilledButton>(
      find.byKey(const ValueKey('invite-open-queue-party-player')),
    );
    final disband = tester.widget<TextButton>(
      find.byKey(const ValueKey('disband-open-queue-party')),
    );
    expect(invite.onPressed, isNull);
    expect(disband.onPressed, isNull);
    expect(
      find.byKey(const ValueKey('cancel-party-invite-membership-pending')),
      findsNothing,
    );
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
  bool fullBeforeCutoff = false,
  String assignedTeam = openQueueWhiteTeamId,
  int assignmentLeadMinutes = 180,
}) {
  final hasAssignmentMetadata = assigned || staleAssignment;
  final isFull = assigned || fullBeforeCutoff;
  final startsAt = DateTime.now().add(
    assigned ? const Duration(hours: 2) : const Duration(days: 2),
  );
  final game = OpenQueueGame(
    id: 'game-1',
    status: isFull ? 'FULL' : 'OPEN',
    venue: 'TFA, Saar',
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: 'Ages 16-20',
    capacity: 12,
    confirmedCount: isFull ? 12 : 10,
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
    teamAssignmentAt: startsAt.subtract(
      Duration(minutes: assignmentLeadMinutes),
    ),
    partyLockAt: startsAt.subtract(const Duration(hours: 3)),
    teamAssignmentLeadMinutes: assignmentLeadMinutes,
    partyLockLeadMinutes: 180,
    maxPartySize: 4,
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
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => [
    if (upcomingBooking case final booking?) booking,
  ];

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

class _ChangingCostOpenQueueRepository extends _FakeOpenQueueRepository
    implements OpenQueueBookingCostPreviewRepository {
  int previewCalls = 0;
  int bookCalls = 0;

  @override
  Future<OpenQueueBookingCostPreview> previewBookingCost({
    required String gameId,
    required OpenQueueRole role,
  }) async {
    previewCalls += 1;
    final totalFils = previewCalls >= 3 ? 4000 : 3000;
    return OpenQueueBookingCostPreview(
      currency: 'BHD',
      standardMatchFeeFils: totalFils,
      replacementDiscountBps: 0,
      discountAmountFils: 0,
      matchFeeFils: totalFils,
      reliabilityDepositRequired: false,
      reliabilityDepositBps: 0,
      reliabilityDepositFils: 0,
      totalFils: totalFils,
      policyVersionId: 'policy-1',
    );
  }

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async {
    bookCalls += 1;
    return _booking();
  }
}

class _PartyOpenQueueRepository extends _FakeOpenQueueRepository
    implements OpenQueuePartyRepository, OpenQueueBookingLookupRepository {
  _PartyOpenQueueRepository(this.contextData, {this.bookingAfterMutation});

  OpenQueuePartyContext contextData;
  final OpenQueueBooking? bookingAfterMutation;
  bool _mutationCompleted = false;
  int createCalls = 0;
  int acceptedInvites = 0;
  int sentInvites = 0;
  int disbandCalls = 0;

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async {
    return _mutationCompleted ? bookingAfterMutation : null;
  }

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async {
    final booking = bookingAfterMutation;
    return _mutationCompleted && booking != null ? [booking] : const [];
  }

  @override
  Future<OpenQueueBooking?> getMyUpcomingBookingForGame(String gameId) async {
    return _mutationCompleted ? bookingAfterMutation : null;
  }

  @override
  Future<OpenQueuePartyContext> getPartyContext(String gameId) async =>
      contextData;

  @override
  Future<String> createParty(String gameId) async {
    createCalls += 1;
    contextData = _ownedPartyContext(includePending: false);
    return 'party-1';
  }

  @override
  Future<String> invitePartyMember({
    required String partyId,
    required String profileId,
  }) async {
    sentInvites += 1;
    return 'membership-new';
  }

  @override
  Future<void> respondToPartyInvite({
    required String membershipId,
    required bool accept,
  }) async {
    if (accept) {
      acceptedInvites += 1;
      _mutationCompleted = true;
      contextData = _joinedPartyContext();
    } else {
      contextData = _emptyPartyContext();
    }
  }

  @override
  Future<void> cancelPartyInvite(String membershipId) async {}

  @override
  Future<void> leaveParty(String partyId) async {
    contextData = _emptyPartyContext();
  }

  @override
  Future<void> disbandParty(String partyId) async {
    disbandCalls += 1;
    contextData = _emptyPartyContext();
  }
}

OpenQueuePartyContext _emptyPartyContext({
  bool canUseParties = true,
  int partyLockLeadMinutes = 180,
}) {
  return OpenQueuePartyContext(
    gameId: 'game-1',
    gameStatus: 'OPEN',
    canUseParties: canUseParties,
    maxPartySize: 4,
    teamAssignmentLeadMinutes: 180,
    partyLockLeadMinutes: partyLockLeadMinutes,
    receivedInvites: const [],
    eligiblePlayers: const [
      OpenQueuePartyPlayer(
        profileId: 'player-layla',
        displayName: 'Layla Abbas',
        role: OpenQueueRole.midfielder,
        isInParty: true,
        currentPartyId: 'layla-party',
        currentPartySize: 2,
      ),
    ],
  );
}

OpenQueuePartyContext _invitedPartyContext() {
  return OpenQueuePartyContext(
    gameId: 'game-1',
    gameStatus: 'OPEN',
    canUseParties: true,
    maxPartySize: 4,
    teamAssignmentLeadMinutes: 180,
    partyLockLeadMinutes: 180,
    receivedInvites: [
      OpenQueuePartyInvite(
        membershipId: 'membership-incoming',
        partyId: 'party-noor',
        invitedAt: DateTime.now(),
        owner: const OpenQueuePartyPlayer(
          profileId: 'player-noor',
          displayName: 'Noor Saleh',
          role: OpenQueueRole.attacker,
        ),
        acceptedCount: 1,
        members: [
          OpenQueuePartyMember(
            membershipId: 'membership-noor',
            profileId: 'player-noor',
            displayName: 'Noor Saleh',
            role: OpenQueueRole.attacker,
            status: OpenQueuePartyMemberStatus.accepted,
            isOwner: true,
            invitedAt: DateTime.now(),
          ),
        ],
      ),
    ],
    eligiblePlayers: const [],
  );
}

OpenQueuePartyContext _ownedPartyContext({
  bool includePending = true,
  bool canUseParties = true,
}) {
  return OpenQueuePartyContext(
    gameId: 'game-1',
    gameStatus: 'OPEN',
    canUseParties: canUseParties,
    maxPartySize: 4,
    teamAssignmentLeadMinutes: 180,
    partyLockLeadMinutes: 180,
    myParty: OpenQueueParty(
      id: 'party-1',
      ownerProfileId: 'profile-1',
      isOwner: true,
      acceptedCount: 1,
      members: [
        OpenQueuePartyMember(
          membershipId: 'membership-owner',
          profileId: 'profile-1',
          displayName: 'Ali Altaraif',
          role: OpenQueueRole.defender,
          status: OpenQueuePartyMemberStatus.accepted,
          isOwner: true,
          invitedAt: DateTime.now(),
        ),
        if (includePending)
          OpenQueuePartyMember(
            membershipId: 'membership-pending',
            profileId: 'player-sami',
            displayName: 'Sami Nasser',
            role: OpenQueueRole.defender,
            status: OpenQueuePartyMemberStatus.invited,
            isOwner: false,
            invitedAt: DateTime.now(),
          ),
      ],
    ),
    receivedInvites: const [],
    eligiblePlayers: const [
      OpenQueuePartyPlayer(
        profileId: 'player-layla',
        displayName: 'Layla Abbas',
        role: OpenQueueRole.midfielder,
        isInParty: true,
        currentPartyId: 'layla-party',
        currentPartySize: 2,
      ),
    ],
  );
}

OpenQueuePartyContext _partySwitchInviteContext() {
  return OpenQueuePartyContext(
    gameId: 'game-1',
    gameStatus: 'OPEN',
    canUseParties: true,
    maxPartySize: 4,
    teamAssignmentLeadMinutes: 180,
    partyLockLeadMinutes: 180,
    myParty: OpenQueueParty(
      id: 'party-current',
      ownerProfileId: 'player-dana',
      isOwner: false,
      acceptedCount: 2,
      members: [
        OpenQueuePartyMember(
          membershipId: 'membership-dana',
          profileId: 'player-dana',
          displayName: 'Dana Alawi',
          role: OpenQueueRole.midfielder,
          status: OpenQueuePartyMemberStatus.accepted,
          isOwner: true,
          invitedAt: DateTime.now(),
        ),
        OpenQueuePartyMember(
          membershipId: 'membership-me-current',
          profileId: 'profile-1',
          displayName: 'Ali Altaraif',
          role: OpenQueueRole.defender,
          status: OpenQueuePartyMemberStatus.accepted,
          isOwner: false,
          invitedAt: DateTime.now(),
        ),
      ],
    ),
    receivedInvites: _invitedPartyContext().receivedInvites,
    eligiblePlayers: const [],
  );
}

OpenQueuePartyContext _joinedPartyContext() {
  return OpenQueuePartyContext(
    gameId: 'game-1',
    gameStatus: 'OPEN',
    canUseParties: true,
    maxPartySize: 4,
    teamAssignmentLeadMinutes: 180,
    partyLockLeadMinutes: 180,
    myParty: OpenQueueParty(
      id: 'party-noor',
      ownerProfileId: 'player-noor',
      isOwner: false,
      acceptedCount: 2,
      members: [
        OpenQueuePartyMember(
          membershipId: 'membership-noor',
          profileId: 'player-noor',
          displayName: 'Noor Saleh',
          role: OpenQueueRole.attacker,
          status: OpenQueuePartyMemberStatus.accepted,
          isOwner: true,
          invitedAt: DateTime.now(),
        ),
        OpenQueuePartyMember(
          membershipId: 'membership-me',
          profileId: 'profile-1',
          displayName: 'Ali Altaraif',
          role: OpenQueueRole.defender,
          status: OpenQueuePartyMemberStatus.accepted,
          isOwner: false,
          invitedAt: DateTime.now(),
        ),
      ],
    ),
    receivedInvites: const [],
    eligiblePlayers: const [],
  );
}
