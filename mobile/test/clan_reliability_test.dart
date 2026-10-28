import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_detail_screen.dart';
import 'package:field/src/clans/clan_reliability.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/moderation/moderation.dart';
import 'package:field/src/moderation/moderation_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reliability summary parses the RPC JSON contract', () {
    final summary = ClanReliabilitySummary.fromJson({
      'clan_id': _clan.id,
      'active_strikes': 2,
      'is_member': true,
      'consequence_summary': {
        'deposit_required': true,
        'active_sanctions': [
          {'kind': 'WARNING'},
          {'kind': 'SUSPENSION'},
        ],
      },
      'incidents': [
        {
          'id': 'incident-1',
          'outcome': 'NO_SHOW',
          'strike_delta': 2,
          'occurred_at': '2026-07-20T18:00:00Z',
          'expires_at': '2026-08-19T18:00:00Z',
          'reason': 'Nobody checked in.',
          'fixture_id': 'fixture-1',
          'fixture_label': 'MMAV vs RIV',
          'issuer_label': 'Field Operations',
          'is_active': true,
        },
      ],
    });

    expect(summary.clanId, _clan.id);
    expect(summary.activeStrikes, 2);
    expect(summary.isMember, isTrue);
    expect(summary.consequenceSummary.depositRequired, isTrue);
    expect(summary.consequenceSummary.activeSanctionCount, 2);
    expect(summary.incidents, hasLength(1));

    final incident = summary.incidents.single;
    expect(incident.id, 'incident-1');
    expect(incident.outcomeLabel, 'No-show');
    expect(incident.strikeDelta, 2);
    expect(incident.occurredAt, DateTime.utc(2026, 7, 20, 18));
    expect(incident.expiresAt, DateTime.utc(2026, 8, 19, 18));
    expect(incident.fixtureId, 'fixture-1');
    expect(incident.fixtureLabel, 'MMAV vs RIV');
    expect(incident.issuerLabel, 'Field Operations');
    expect(incident.isActive, isTrue);
    expect(
      const ClanReliabilityIncident(
        id: 'short-roster',
        outcome: 'PARTIAL_LATE',
        strikeDelta: 1,
        isActive: true,
      ).outcomeLabel,
      'Short roster',
    );
  });

  testWidgets('clan reliability is hidden from visitors for now', (
    tester,
  ) async {
    await _pumpClan(
      tester,
      repository: _FakeClanRepository(summary: _summary(isMember: false)),
    );

    expect(find.byKey(const ValueKey('clan-reliability-card')), findsNothing);
    expect(find.byKey(const ValueKey('clan-active-strikes')), findsNothing);
    expect(find.text('2 ACTIVE'), findsNothing);
    expect(
      find.byKey(const ValueKey('clan-reliability-private-note')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('clan-reliability-private-history')),
      findsNothing,
    );
    expect(find.text('Nobody checked in.'), findsNothing);
    expect(find.text('Deposit required'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clan reliability is hidden from members for now', (
    tester,
  ) async {
    const membership = ClanMembership(clanId: 'clan-id', role: 'member');
    await _pumpClan(
      tester,
      repository: _FakeClanRepository(
        membership: membership,
        summary: _summary(isMember: true),
      ),
      membership: membership,
    );

    expect(find.byKey(const ValueKey('clan-reliability-card')), findsNothing);
    expect(
      find.byKey(const ValueKey('clan-reliability-private-history')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('clan-reliability-incident-incident-1')),
      findsNothing,
    );
    expect(find.text('No-show'), findsNothing);
    expect(find.text('Nobody checked in.'), findsNothing);
    expect(find.text('Deposit required'), findsNothing);
    expect(find.text('1 active sanction'), findsNothing);
    expect(find.textContaining('Issued by Field Operations'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden reliability cannot show an error on the clan page', (
    tester,
  ) async {
    await _pumpClan(
      tester,
      repository: _FakeClanRepository(
        reliabilityError: StateError('Reliability RPC unavailable'),
      ),
    );

    expect(find.text(_clan.name), findsWidgets);
    expect(find.byKey(const ValueKey('clan-reliability-error')), findsNothing);
    expect(find.text('Reliability unavailable'), findsNothing);
    expect(find.byKey(const ValueKey('retry-clan-reliability')), findsNothing);
    expect(find.text('Clan games'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpClan(
  WidgetTester tester, {
  required _FakeClanRepository repository,
  ClanMembership? membership,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ClanDetailScreen(
        clan: _clan,
        clanRepository: repository,
        fixtureRepository: _FakeFixtureRepository(),
        currentMembership: membership,
        moderationRepository: _FakeModerationRepository(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

ClanReliabilitySummary _summary({required bool isMember}) {
  return ClanReliabilitySummary(
    clanId: _clan.id,
    activeStrikes: 2,
    isMember: isMember,
    consequenceSummary: const ClanReliabilityConsequenceSummary(
      depositRequired: true,
      activeSanctionCount: 1,
    ),
    incidents: [
      ClanReliabilityIncident(
        id: 'incident-1',
        outcome: 'NO_SHOW',
        strikeDelta: 2,
        occurredAt: DateTime.utc(2026, 7, 20, 18),
        expiresAt: DateTime.utc(2026, 8, 19, 18),
        reason: 'Nobody checked in.',
        fixtureId: 'fixture-1',
        fixtureLabel: 'MMAV vs RIV',
        issuerLabel: 'Field Operations',
        isActive: true,
      ),
    ],
  );
}

const _clan = Clan(
  id: 'clan-id',
  name: 'Mint Mavericks',
  tag: 'MMAV',
  motto: 'Play together',
  emblem: '⚡',
  themeId: 'mint',
  patternId: 'solid',
  skillRating: 1500,
  wins: 2,
  losses: 1,
  memberCount: 7,
  createdBy: 'owner-id',
);

class _FakeClanRepository implements ClanRepository, ClanReliabilityRepository {
  _FakeClanRepository({this.membership, this.summary, this.reliabilityError});

  final ClanMembership? membership;
  final ClanReliabilitySummary? summary;
  final Object? reliabilityError;

  @override
  Future<ClanReliabilitySummary> getClanReliabilitySummary(
    String clanId,
  ) async {
    final error = reliabilityError;
    if (error != null) throw error;
    return summary!;
  }

  @override
  Future<ClanMembership?> getMyClanMembership() async => membership;

  @override
  Future<List<Clan>> listClans() async => const [_clan];

  @override
  Future<List<ClanMember>> listClanMembers(String clanId) async => const [];

  @override
  Future<List<Fixture>> listClanFixtures(String clanId) async => const [];

  @override
  Future<List<ClanJoinRequest>> listPendingJoinRequests(String clanId) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFixtureRepository implements FixtureRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeModerationRepository implements ModerationRepository {
  @override
  Future<ModerationStatus> getMyModerationStatus() async =>
      const ModerationStatus.active();

  @override
  Future<ModerationReportReceipt> submitReport(
    ModerationReportDraft report,
  ) async {
    return const ModerationReportReceipt(id: 'report-id');
  }
}
