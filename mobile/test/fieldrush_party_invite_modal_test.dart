import 'dart:async';

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_card.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('party invitations use the shared theme and preserve retry', (
    tester,
  ) async {
    var calls = 0;
    await _open(
      tester,
      _context(),
      onInvite: (player) async {
        expect(player.profileId, 'player-0');
        calls++;
        return calls == 1 ? 'Could not send invitation. Try again.' : null;
      },
    );
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Invite to your party'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Invite to your party')).style!.fontFamily,
      'Outfit',
    );
    expect(
      Theme.of(
        tester.element(find.text('Invite to your party')),
      ).colorScheme.surface,
      FieldrushAuthTheme.cream,
    );
    final invite = find.byKey(const ValueKey('invite-party-player-player-0'));
    await tester.tap(invite);
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(
      find.byKey(const ValueKey('party-invite-confirmation')),
      findsOneWidget,
    );
    expect(find.textContaining('Player gets a notification.'), findsOneWidget);
    final send = find.byKey(const ValueKey('party-invite-send'));
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text('Could not send invitation. Try again.'), findsOneWidget);
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(FieldrushModal), findsNothing);
    expect(find.text('Invite sent to Player'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      find.byKey(const ValueKey('party-invite-sheet-error')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('a full party cannot send another invite and can close', (
    tester,
  ) async {
    var calls = 0;
    await _open(
      tester,
      _context(memberCount: 4),
      onInvite: (_) async {
        calls++;
        return null;
      },
    );
    expect(find.text('0 spots left'), findsOneWidget);
    expect(
      tester
          .widget<InkWell>(
            find.byKey(const ValueKey('invite-party-player-player-0')),
          )
          .onTap,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('party-invite-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsNothing);
    expect(calls, 0);
    await _finish(tester);
  });

  testWidgets('the picker scrolls through all players on a narrow phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var invited = '';
    await _open(
      tester,
      _context(playerCount: 14),
      scale: 1.4,
      onInvite: (player) async {
        invited = player.profileId;
        return null;
      },
    );
    final last = find.byKey(const ValueKey('invite-party-player-player-13'));
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(invited, isEmpty);
    expect(
      find.textContaining(
        'They will leave their current party only if they accept.',
      ),
      findsOneWidget,
    );
    final send = find.byKey(const ValueKey('party-invite-send'));
    await tester.ensureVisible(send);
    await tester.pumpAndSettle();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(invited, 'player-13');
    expect(tester.takeException(), isNull);
    expect(find.byType(FieldrushModal), findsNothing);
    await _finish(tester);
  });

  testWidgets('an empty invite picker uses the same modal', (tester) async {
    await _open(tester, _context(playerCount: 0), onInvite: (_) async => null);
    expect(find.text('No one is available to invite'), findsOneWidget);
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('cancel confirmation does not send an invitation', (
    tester,
  ) async {
    var calls = 0;
    await _open(
      tester,
      _context(),
      onInvite: (_) async {
        calls++;
        return null;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('invite-party-player-player-0')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('party-invite-sheet-close')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(FieldrushModal), findsNothing);
    await _finish(tester);
  });

  testWidgets('sending locks duplicate actions and recovers a thrown error', (
    tester,
  ) async {
    final pending = Completer<String?>();
    var calls = 0;
    await _open(
      tester,
      _context(),
      onInvite: (_) async {
        calls++;
        return pending.future;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('invite-party-player-player-0')),
    );
    await tester.pumpAndSettle();
    final send = find.byKey(const ValueKey('party-invite-send'));
    await tester.tap(send);
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('party-invite-sheet-close')),
          )
          .onPressed,
      isNull,
    );
    pending.completeError(StateError('network interruption'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('party-invite-sheet-error')),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets(
    'confirmation Profile action opens the real player without sending',
    (tester) async {
      var opened = '';
      var calls = 0;
      await _open(
        tester,
        _context(),
        onInvite: (_) async {
          calls++;
          return null;
        },
        onViewProfile: (id) async {
          opened = id;
        },
      );
      await tester.tap(
        find.byKey(const ValueKey('invite-party-player-player-0')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Profile ›'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('party-invite-player-profile')),
      );
      await tester.pumpAndSettle();
      expect(opened, 'player-0');
      expect(calls, 0);
      expect(find.byType(FieldrushModal), findsNothing);
      await _finish(tester);
    },
  );

  testWidgets('role chips show real match capacities and fallback to counts', (
    tester,
  ) async {
    final game = OpenQueueGame(
      id: 'game',
      status: 'OPEN',
      venue: 'Test pitch',
      startsAt: DateTime.utc(2030, 1, 1),
      endsAt: DateTime.utc(2030, 1, 1, 1),
      timezone: 'America/Phoenix',
      priceFils: 13000,
      currency: 'USD',
      ageLabel: '18+',
      capacity: 14,
      confirmedCount: 2,
      spots: const {
        OpenQueueRole.goalkeeper: 2,
        OpenQueueRole.defender: 6,
        OpenQueueRole.attacker: 6,
      },
    );
    await _open(tester, _context(), game: game, onInvite: (_) async => null);
    expect(find.text('Attackers 0/3'), findsOneWidget);
    expect(find.text('Defenders 1/3'), findsOneWidget);
    expect(find.text('Keeper 0/1'), findsOneWidget);
    await _finish(tester);
    await _open(tester, _context(), onInvite: (_) async => null);
    expect(find.text('Attackers 0'), findsOneWidget);
    expect(find.text('Defenders 1'), findsOneWidget);
    expect(find.text('Keeper 0'), findsOneWidget);
    expect(find.textContaining('/3'), findsNothing);
    await _finish(tester);
  });

  testWidgets('closed server party context cannot select a candidate', (
    tester,
  ) async {
    await _open(
      tester,
      _context(canUseParties: false),
      onInvite: (_) async => null,
    );
    expect(find.text('Closed'), findsOneWidget);
    expect(
      tester
          .widget<InkWell>(
            find.byKey(const ValueKey('invite-party-player-player-0')),
          )
          .onTap,
      isNull,
    );
    await _finish(tester);
  });

  testWidgets('existing party members are not offered as new invitees', (
    tester,
  ) async {
    final data = _context(includeMemberCandidate: true);
    await _open(tester, data, onInvite: (_) async => null);
    expect(
      find.byKey(const ValueKey('invite-party-player-member-0')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('invite-party-player-player-0')),
      findsOneWidget,
    );
    await _finish(tester);
  });
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

Future<void> _open(
  WidgetTester tester,
  OpenQueuePartyContext partyContext, {
  required Future<String?> Function(OpenQueuePartyPlayer) onInvite,
  double scale = 1,
  OpenQueueGame? game,
  Future<void> Function(String profileId)? onViewProfile,
}) async {
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
            onPressed: () => showOpenQueuePartyInviteSheet(
              context: context,
              partyContext: partyContext,
              onInvite: onInvite,
              game: game,
              onViewProfile: onViewProfile,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

OpenQueuePartyContext _context({
  int memberCount = 1,
  int playerCount = 1,
  bool canUseParties = true,
  bool includeMemberCandidate = false,
}) => OpenQueuePartyContext(
  gameId: 'game',
  gameStatus: 'OPEN',
  canUseParties: canUseParties,
  maxPartySize: 4,
  receivedInvites: const [],
  myParty: OpenQueueParty(
    id: 'party',
    ownerProfileId: 'owner',
    isOwner: true,
    acceptedCount: memberCount,
    members: [
      for (var index = 0; index < memberCount; index++)
        OpenQueuePartyMember(
          membershipId: 'member-$index',
          profileId: 'member-$index',
          displayName: 'Member $index',
          role: OpenQueueRole.defender,
          status: OpenQueuePartyMemberStatus.accepted,
          isOwner: index == 0,
          invitedAt: null,
        ),
    ],
  ),
  eligiblePlayers: [
    if (includeMemberCandidate)
      const OpenQueuePartyPlayer(
        profileId: 'member-0',
        displayName: 'Member 0',
        role: OpenQueueRole.defender,
      ),
    for (var index = 0; index < playerCount; index++)
      OpenQueuePartyPlayer(
        profileId: 'player-$index',
        displayName: 'Player $index',
        username: 'player$index',
        role: OpenQueueRole.attacker,
        isInParty: index.isOdd,
        currentPartySize: index.isOdd ? 2 : 0,
      ),
  ],
);
