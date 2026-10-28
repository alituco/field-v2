import 'dart:async';

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_party.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/helpers/staging_party_navigation.dart';

void main() {
  testWidgets('staging member assertion uses the exact accepted slot', (
    tester,
  ) async {
    final repository = _Repository(_context(isOwner: false));
    await _show(tester, repository);
    expect(find.text('KEVIN’S PARTY'), findsOneWidget);
    expect(find.text('YOUR PARTY'), findsNothing);
    final membership = repository.data.myParty!.members.singleWhere(
      (member) => member.profileId == 'me',
    );

    await expectAcceptedPartyMembershipVisible(tester, membership: membership);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first plus creates the party before loading its invite picker', (
    tester,
  ) async {
    final create = Completer<String>();
    final repository = _Repository(_soloContext())
      ..createdContext = _context()
      ..createResult = create.future;
    await _show(tester, repository);
    final plus = find.byKey(const ValueKey('fieldrush-party-empty-slot')).first;
    expect(find.text('Invite'), findsNWidgets(3));
    await tester.tap(plus);
    await tester.pump();
    expect(repository.createCalls, 1);
    expect(find.byKey(const ValueKey('party-invite-sheet')), findsNothing);
    await tester.tap(plus);
    await tester.pump();
    expect(repository.createCalls, 1);
    create.complete('party');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('party-invite-sheet')), findsOneWidget);
    expect(find.text('Alex Smith'), findsWidgets);
    expect(repository.contextCalls, 2);
    expect(repository.inviteCalls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a creation failure leaves plus available for a successful retry',
    (tester) async {
      final repository = _Repository(_soloContext())
        ..createdContext = _context()
        ..createError = StateError('Unable to create party');
      await _show(tester, repository);
      final plus = find
          .byKey(const ValueKey('fieldrush-party-empty-slot'))
          .first;
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(repository.createCalls, 1);
      expect(find.byKey(const ValueKey('party-invite-sheet')), findsNothing);
      expect(find.text('Invite'), findsNWidgets(3));
      repository.createError = null;
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(repository.createCalls, 2);
      expect(find.byKey(const ValueKey('party-invite-sheet')), findsOneWidget);
      expect(repository.inviteCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'plus opens the empty picker when no booked players are available',
    (tester) async {
      final repository = _Repository(_soloContext())
        ..createdContext = _soloContext(party: _context().myParty);
      await _show(tester, repository);
      await tester.tap(
        find.byKey(const ValueKey('fieldrush-party-empty-slot')).first,
      );
      await tester.pumpAndSettle();
      expect(repository.createCalls, 1);
      expect(find.byKey(const ValueKey('party-invite-sheet')), findsOneWidget);
      expect(find.text('No one is available to invite'), findsOneWidget);
      expect(repository.inviteCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a cutoff crossed during creation does not open the invite picker',
    (tester) async {
      final repository = _Repository(_soloContext())
        ..createdContext = _soloContext(
          party: _context().myParty,
          canUseParties: false,
        );
      await _show(tester, repository);
      await tester.tap(
        find.byKey(const ValueKey('fieldrush-party-empty-slot')).first,
      );
      await tester.pumpAndSettle();
      expect(repository.createCalls, 1);
      expect(find.byKey(const ValueKey('party-invite-sheet')), findsNothing);
      expect(find.text('Invite'), findsNothing);
      expect(repository.inviteCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'party slots use reference role words and real player navigation',
    (tester) async {
      var opened = '';
      final repository = _Repository(_context());
      await _show(
        tester,
        repository,
        onViewProfile: (id) async {
          opened = id;
        },
      );
      expect(find.text('YOUR PARTY'), findsOneWidget);
      expect(find.text('LEAD'), findsOneWidget);
      expect(find.text('OWNER'), findsNothing);
      expect(find.text('IN'), findsNothing);
      expect(find.text('INVITED'), findsNothing);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Attacker'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Invite'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('fieldrush-party-member-owner-seat')),
      );
      await tester.pumpAndSettle();
      expect(opened, 'me');
      expect(repository.cancelCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending slot opens themed cancellation without changing booking',
    (tester) async {
      final repository = _Repository(_context());
      await _show(tester, repository);
      await tester.tap(
        find.byKey(const ValueKey('fieldrush-party-member-pending-seat')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cancel Layla Abbas’s invite?'), findsOneWidget);
      expect(find.text('Their game booking will not change.'), findsOneWidget);
      expect(repository.cancelCalls, 0);
      await tester.tap(find.byKey(const ValueKey('field-confirmation-cancel')));
      await tester.pumpAndSettle();
      expect(repository.cancelCalls, 0);
      expect(find.text('Pending'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('member party names its lead and shows a themed leave action', (
    tester,
  ) async {
    final repository = _Repository(_context(isOwner: false));
    await _show(tester, repository);
    expect(find.text('KEVIN’S PARTY'), findsOneWidget);
    expect(find.text('Only the party lead can invite.'), findsOneWidget);
    expect(find.text('Invite'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    final leave = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Leave party'),
    );
    expect(
      leave.style!.foregroundColor!.resolve({}),
      FieldrushAuthTheme.danger,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _show(
  WidgetTester tester,
  _Repository repository, {
  Future<void> Function(String profileId)? onViewProfile,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FieldrushGameDetailParty(
              repository: repository,
              game: OpenQueueGame(
                id: 'game',
                status: 'OPEN',
                venue: 'Test pitch',
                startsAt: DateTime.utc(2030, 1, 12, 3, 30),
                endsAt: DateTime.utc(2030, 1, 12, 4, 30),
                timezone: 'America/Phoenix',
                priceFils: 13000,
                currency: 'USD',
                ageLabel: '18+',
                capacity: 14,
                confirmedCount: 2,
                myBookingId: 'booking',
                myBookingRole: repository.data.myParty?.isOwner != false
                    ? OpenQueueRole.attacker
                    : OpenQueueRole.defender,
                spots: const {
                  OpenQueueRole.goalkeeper: 2,
                  OpenQueueRole.defender: 6,
                  OpenQueueRole.attacker: 4,
                },
              ),
              viewerProfileId: 'me',
              onChanged: () async {},
              onViewProfile: onViewProfile,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OpenQueuePartyContext _context({bool isOwner = true}) => OpenQueuePartyContext(
  gameId: 'game',
  gameStatus: 'OPEN',
  canUseParties: true,
  maxPartySize: 4,
  partyLockAt: DateTime.utc(2030, 1, 12, 0, 30),
  receivedInvites: const [],
  eligiblePlayers: const [
    OpenQueuePartyPlayer(
      profileId: 'target',
      displayName: 'Alex Smith',
      role: OpenQueueRole.defender,
    ),
  ],
  myParty: OpenQueueParty(
    id: 'party',
    ownerProfileId: isOwner ? 'me' : 'kevin',
    isOwner: isOwner,
    acceptedCount: 2,
    members: [
      OpenQueuePartyMember(
        membershipId: 'owner-seat',
        profileId: isOwner ? 'me' : 'kevin',
        displayName: isOwner ? 'Main Player' : 'Kevin Davis',
        role: OpenQueueRole.attacker,
        status: OpenQueuePartyMemberStatus.accepted,
        isOwner: true,
        invitedAt: null,
      ),
      OpenQueuePartyMember(
        membershipId: 'accepted-seat',
        profileId: isOwner ? 'alex' : 'me',
        displayName: isOwner ? 'Alex Smith' : 'Main Player',
        role: OpenQueueRole.defender,
        status: OpenQueuePartyMemberStatus.accepted,
        isOwner: false,
        invitedAt: null,
      ),
      const OpenQueuePartyMember(
        membershipId: 'pending-seat',
        profileId: 'layla',
        displayName: 'Layla Abbas',
        role: OpenQueueRole.defender,
        status: OpenQueuePartyMemberStatus.invited,
        isOwner: false,
        invitedAt: null,
      ),
    ],
  ),
);

OpenQueuePartyContext _soloContext({
  OpenQueueParty? party,
  bool canUseParties = true,
}) => OpenQueuePartyContext(
  gameId: 'game',
  gameStatus: 'OPEN',
  canUseParties: canUseParties,
  maxPartySize: 4,
  partyLockAt: DateTime.utc(2030, 1, 12, 0, 30),
  receivedInvites: const [],
  eligiblePlayers: const [],
  myParty: party,
);

class _Repository implements OpenQueueRepository, OpenQueuePartyRepository {
  _Repository(this.data);
  OpenQueuePartyContext data;
  OpenQueuePartyContext? createdContext;
  Future<String>? createResult;
  Object? createError;
  int createCalls = 0;
  int contextCalls = 0;
  int inviteCalls = 0;
  int cancelCalls = 0;
  @override
  Future<OpenQueuePartyContext> getPartyContext(String gameId) async {
    contextCalls++;
    return data;
  }

  @override
  Future<String> createParty(String gameId) async {
    createCalls++;
    if (createError case final error?) throw error;
    final id = await (createResult ?? Future.value('party'));
    data = createdContext ?? data;
    return id;
  }

  @override
  Future<String> invitePartyMember({
    required String partyId,
    required String profileId,
  }) async {
    inviteCalls++;
    return 'invitation';
  }

  @override
  Future<void> cancelPartyInvite(String membershipId) async {
    cancelCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
