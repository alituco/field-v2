import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'staging_test_helpers.dart';

/// Exercise the same picker and confirmation that a player uses, rather than
/// assuming an invitation is sent by the initial player-row tap.
Future<void> sendPartyInviteThroughUi(
  WidgetTester tester, {
  required String inviteeId,
  Duration timeout = const Duration(seconds: 35),
}) async {
  final picker = find.byKey(const ValueKey('party-invite-sheet'));
  await pumpUntilFound(tester, picker, timeout: timeout);
  final player = find.descendant(
    of: picker,
    matching: find.byKey(ValueKey('invite-party-player-$inviteeId')),
  );
  await scrollUntilFound(
    tester,
    player,
    timeout: timeout,
    reason: 'The booked invitee was not listed in the party picker.',
  );
  expect(
    tester.widget<InkWell>(player).onTap,
    isNotNull,
    reason: 'The booked invitee was not eligible for this party.',
  );
  await tapWhenVisible(tester, player, timeout: timeout);

  final confirmation = find.byKey(const ValueKey('party-invite-confirmation'));
  await pumpUntilFound(
    tester,
    confirmation,
    timeout: timeout,
    reason: 'Selecting the invitee did not open the invitation confirmation.',
  );
  final send = find.descendant(
    of: confirmation,
    matching: find.byKey(const ValueKey('party-invite-send')),
  );
  expect(
    tester.widget<FilledButton>(send).onPressed,
    isNotNull,
    reason: 'The invitation confirmation did not allow sending.',
  );
  await tapWhenVisible(tester, send, timeout: timeout);
  // Success dismisses the modal automatically. Do not look for the old "Sent"
  // row or tap Cancel/Done after it is gone. The caller separately verifies the
  // exact persisted invitation through the authenticated repository.
  await pumpUntilAbsent(
    tester,
    confirmation,
    timeout: timeout,
    reason:
        'The party invitation was not acknowledged; confirmation stayed open.',
  );
  await pumpUntilAbsent(tester, picker, timeout: timeout);
}

/// Members see the lead's name, not the owner's "YOUR PARTY" heading. Match
/// the current viewer's exact accepted membership rather than transient copy.
Future<void> expectAcceptedPartyMembershipVisible(
  WidgetTester tester, {
  required OpenQueuePartyMember membership,
}) async {
  expect(membership.status, OpenQueuePartyMemberStatus.accepted);
  final slot = find.descendant(
    of: find.byKey(const ValueKey('fieldrush-game-party')),
    matching: find.byKey(
      ValueKey('fieldrush-party-member-${membership.membershipId}'),
    ),
  );
  await pumpUntilFound(
    tester,
    slot,
    reason: 'The accepted membership did not appear in the game party.',
  );
  expect(find.descendant(of: slot, matching: find.text('You')), findsOneWidget);
  final role = switch (membership.role) {
    OpenQueueRole.goalkeeper => 'Keeper',
    OpenQueueRole.defender => 'Defender',
    OpenQueueRole.midfielder => 'Midfielder',
    OpenQueueRole.attacker => 'Attacker',
  };
  expect(find.descendant(of: slot, matching: find.text(role)), findsOneWidget);
  expect(
    find.descendant(of: slot, matching: find.text('Pending')),
    findsNothing,
  );
}
