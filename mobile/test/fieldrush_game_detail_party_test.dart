import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_party.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
                myBookingRole: repository.data.myParty!.isOwner
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

class _Repository implements OpenQueueRepository, OpenQueuePartyRepository {
  _Repository(this.data);
  final OpenQueuePartyContext data;
  int cancelCalls = 0;
  @override
  Future<OpenQueuePartyContext> getPartyContext(String gameId) async => data;
  @override
  Future<void> cancelPartyInvite(String membershipId) async {
    cancelCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
