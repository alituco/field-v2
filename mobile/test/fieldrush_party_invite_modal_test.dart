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
    expect(find.text('Invite confirmed players'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.text('Invite confirmed players'))
          .style!
          .fontFamily,
      'Outfit',
    );
    expect(
      Theme.of(
        tester.element(find.text('Invite confirmed players')),
      ).colorScheme.surface,
      FieldrushAuthTheme.cream,
    );
    final invite = find.byKey(const ValueKey('invite-party-player-player-0'));
    await tester.tap(invite);
    await tester.pumpAndSettle();
    expect(find.text('Could not send invitation. Try again.'), findsOneWidget);
    expect(tester.widget<FilledButton>(invite).onPressed, isNotNull);
    await tester.tap(invite);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Sent'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('party-invite-sheet-error')),
      findsNothing,
    );
    expect(tester.widget<FilledButton>(invite).onPressed, isNull);
    expect(
      find.text('2 party spots available · this game only'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
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
    expect(
      find.text('0 party spots available · this game only'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('invite-party-player-player-0')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('party-invite-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsNothing);
    expect(calls, 0);
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
    expect(invited, 'player-13');
    expect(tester.takeException(), isNull);
    final close = find.byKey(const ValueKey('party-invite-sheet-close'));
    await tester.ensureVisible(close);
    await tester.pumpAndSettle();
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsNothing);
  });

  testWidgets('an empty invite picker uses the same modal', (tester) async {
    await _open(tester, _context(playerCount: 0), onInvite: (_) async => null);
    expect(find.text('No one is available to invite'), findsOneWidget);
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _open(
  WidgetTester tester,
  OpenQueuePartyContext partyContext, {
  required Future<String?> Function(OpenQueuePartyPlayer) onInvite,
  double scale = 1,
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

OpenQueuePartyContext _context({int memberCount = 1, int playerCount = 1}) =>
    OpenQueuePartyContext(
      gameId: 'game',
      gameStatus: 'OPEN',
      canUseParties: true,
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
