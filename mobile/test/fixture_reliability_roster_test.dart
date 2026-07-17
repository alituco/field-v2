import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_reliability_roster.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('roster response parses secure fixture-scoped member state', () {
    final roster = FixtureReliabilityRoster.fromJson({
      'fixture_id': 'fixture-1',
      'clan_id': 'home',
      'side': 'HOME',
      'required_count': 7,
      'confirmed_count': 1,
      'is_complete': false,
      'locks_at': '2026-07-21T18:45:00Z',
      'locked': false,
      'can_manage': true,
      'can_edit': true,
      'members': [
        {
          'profile_id': 'player-1',
          'display_name': 'Dana Alawi',
          'username': 'dana',
          'avatar_url': null,
          'role': 'leader',
          'selected': true,
          'eligible': true,
          'unavailable_reason': null,
        },
        {
          'profile_id': 'player-2',
          'display_name': 'Restricted Player',
          'role': 'member',
          'selected': false,
          'eligible': false,
          'unavailable_reason': 'Unavailable for this fixture',
        },
      ],
    });

    expect(roster.fixtureId, 'fixture-1');
    expect(roster.requiredCount, 7);
    expect(roster.confirmedCount, 1);
    expect(roster.remainingCount, 6);
    expect(roster.canEdit, isTrue);
    expect(roster.selectedMembers.single.displayName, 'Dana Alawi');
    expect(roster.selectedMembers.single.initials, 'DA');
    expect(roster.members.last.isEligible, isFalse);
    expect(
      roster.members.last.unavailableReason,
      'Unavailable for this fixture',
    );
  });

  testWidgets('leader can review and confirm the seven-player fixture roster', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = _fixture();
    final repository = _RosterFixtureRepository(
      fixture: fixture,
      roster: _roster(canManage: true, canEdit: true),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FixtureDetailScreen(
          fixture: fixture,
          fixtureRepository: repository,
          myClanMembership: const MyClanMembership(
            clan: _homeClan,
            role: 'leader',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final card = find.byKey(const ValueKey('fixture-reliability-roster-card'));
    expect(card, findsOneWidget);
    expect(find.textContaining('Bahrain time'), findsOneWidget);
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(find.text('Confirm matchday roster'), findsOneWidget);
    expect(
      find.textContaining('referee records final attendance'),
      findsOneWidget,
    );
    expect(find.text('7/7'), findsAtLeastNWidgets(1));
    expect(
      find.byKey(const ValueKey('save-fixture-reliability-roster')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('save-fixture-reliability-roster')),
    );
    await tester.pumpAndSettle();

    expect(repository.savedProfileIds, hasLength(7));
    expect(repository.savedFixtureId, fixture.id);
    expect(repository.savedClanId, _homeClan.id);
    expect(find.text('7 players confirmed for matchday.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('clan member gets a read-only view of the confirmed roster', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = _fixture();
    final repository = _RosterFixtureRepository(
      fixture: fixture,
      roster: _roster(canManage: false, canEdit: false),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FixtureDetailScreen(
          fixture: fixture,
          fixtureRepository: repository,
          myClanMembership: const MyClanMembership(
            clan: _homeClan,
            role: 'member',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final card = find.byKey(const ValueKey('fixture-reliability-roster-card'));
    await tester.ensureVisible(card);
    expect(find.text('View roster'), findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(find.text('Matchday roster'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('save-fixture-reliability-roster')),
      findsNothing,
    );
    expect(find.text('Done'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

Fixture _fixture() {
  return Fixture(
    id: 'fixture-1',
    status: FixtureStatus.scheduled,
    homeClanId: _homeClan.id,
    awayClanId: _awayClan.id,
    venue: 'TFA, Saar',
    day: 'TUESDAY',
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: DateTime.now().add(const Duration(days: 5)),
    createdBy: 'owner',
    homeClan: _homeClan,
    awayClan: _awayClan,
  );
}

FixtureReliabilityRoster _roster({
  required bool canManage,
  required bool canEdit,
}) {
  return FixtureReliabilityRoster(
    fixtureId: 'fixture-1',
    clanId: _homeClan.id,
    side: 'HOME',
    requiredCount: 7,
    confirmedCount: 7,
    isComplete: true,
    locksAt: DateTime.now().add(const Duration(days: 4)),
    isLocked: false,
    canManage: canManage,
    canEdit: canEdit,
    members: [
      for (var index = 1; index <= 8; index++)
        FixtureReliabilityRosterMember(
          profileId: 'player-$index',
          displayName: 'Player $index',
          username: 'player$index',
          role: index == 1 ? 'leader' : 'member',
          isSelected: index <= 7,
          isEligible: true,
        ),
    ],
  );
}

const _homeClan = FixtureClan(
  id: 'home',
  name: 'Mint Mavericks',
  tag: 'MMAV',
  emblem: '⚡',
  themeId: 'mint',
  patternId: 'solid',
  skillRating: 1500,
);

const _awayClan = FixtureClan(
  id: 'away',
  name: 'Riffa Raiders',
  tag: 'RIFR',
  emblem: '🏴',
  themeId: 'shadow',
  patternId: 'solid',
  skillRating: 1500,
);

class _RosterFixtureRepository
    implements FixtureRepository, FixtureReliabilityRosterRepository {
  _RosterFixtureRepository({required this.fixture, required this.roster});

  final Fixture fixture;
  FixtureReliabilityRoster roster;
  List<String>? savedProfileIds;
  String? savedFixtureId;
  String? savedClanId;

  @override
  Future<Fixture> getFixture(String fixtureId) async => fixture;

  @override
  Future<FixtureReliabilityRoster> getMyFixtureReliabilityRoster(
    String fixtureId,
  ) async => roster;

  @override
  Future<FixtureReliabilityRoster> saveMyFixtureReliabilityRoster({
    required String fixtureId,
    required String clanId,
    required List<String> profileIds,
  }) async {
    savedFixtureId = fixtureId;
    savedClanId = clanId;
    savedProfileIds = List<String>.from(profileIds);
    return roster;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
