import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_detail_screen.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/moderation/moderation.dart';
import 'package:field/src/moderation/moderation_repository.dart';
import 'package:field/src/moderation/report_issue_sheet.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('report RPC payload contains only the public submission contract', () {
    const report = ModerationReportDraft(
      subjectType: ModerationSubjectType.player,
      subjectId: '  player-id  ',
      category: ModerationReportCategory.harassment,
      details: '  Repeated abusive messages after the match.  ',
      fixtureId: '  fixture-id  ',
    );

    final params = report.toRpcParams();

    expect(params, {
      'subject_type_to_use': 'PLAYER',
      'subject_id_to_use': 'player-id',
      'category_to_use': 'HARASSMENT',
      'details_to_use': 'Repeated abusive messages after the match.',
      'fixture_id_to_use': 'fixture-id',
      'open_queue_game_id_to_use': null,
    });
    for (final privilegedKey in [
      'reporter_id',
      'source_role',
      'status',
      'priority',
      'assigned_admin_id',
    ]) {
      expect(params.containsKey(privilegedKey), isFalse);
    }
  });

  testWidgets('a viewed player has Share and Report, but self does not', (
    tester,
  ) async {
    final moderationRepository = _FakeModerationRepository();
    final viewedRepository = _FakeProfileRepository(
      currentUserId: 'viewer-id',
      profile: _profile(id: 'player-id', name: 'Noor Saleh'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepository: viewedRepository,
            profileId: 'player-id',
            moderationRepository: moderationRepository,
          ),
        ),
      ),
    );
    await tester.pump();

    // The reference exposes reporting directly rather than hiding it in a menu.
    expect(find.byKey(const ValueKey('profile-options-menu')), findsNothing);
    await tester.ensureVisible(find.text('Report player'));
    expect(find.text('Report player'), findsOneWidget);

    await tester.tap(find.text('Report player'));
    await tester.pumpAndSettle();
    expect(find.byKey(moderationReportSheetKey), findsOneWidget);
    expect(find.text('Report Noor Saleh'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('moderation-category-harassment')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('moderation-report-details')),
      'Repeated abuse after the match.',
    );
    tester.testTextInput.hide();
    await tester.pump();
    final submit = find.byKey(const ValueKey('moderation-report-submit'));
    await tester.ensureVisible(submit);
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(moderationRepository.reports, hasLength(1));
    expect(
      moderationRepository.reports.single.subjectType,
      ModerationSubjectType.player,
    );
    expect(moderationRepository.reports.single.subjectId, 'player-id');
    expect(find.byKey(moderationReportSheetKey), findsNothing);

    final selfRepository = _FakeProfileRepository(
      currentUserId: 'viewer-id',
      profile: _profile(id: 'viewer-id', name: 'Viewer'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepository: selfRepository,
            profileId: 'viewer-id',
            moderationRepository: moderationRepository,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('profile-options-menu')), findsNothing);
    expect(find.text('Share profile'), findsOneWidget);
    expect(find.text('Report player'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clan owner menu keeps management actions and adds reporting', (
    tester,
  ) async {
    await _pumpClan(tester, role: 'owner');
    await _openClanMenu(tester);
    expect(find.text('Edit clan'), findsOneWidget);
    expect(find.text('Delete clan'), findsOneWidget);
    expect(find.text('Report clan'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clan leader menu keeps edit and adds reporting', (tester) async {
    await _pumpClan(tester, role: 'leader');
    await _openClanMenu(tester);
    expect(find.text('Edit clan'), findsOneWidget);
    expect(find.text('Delete clan'), findsNothing);
    expect(find.text('Report clan'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clan visitor menu offers reporting without management', (
    tester,
  ) async {
    await _pumpClan(tester);
    await _openClanMenu(tester);
    expect(find.text('Edit clan'), findsNothing);
    expect(find.text('Delete clan'), findsNothing);
    expect(find.text('Report clan'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpClan(WidgetTester tester, {String? role}) async {
  final membership = role == null
      ? null
      : ClanMembership(clanId: _clan.id, role: role);
  await tester.pumpWidget(
    MaterialApp(
      home: ClanDetailScreen(
        clan: _clan,
        clanRepository: _FakeClanRepository(membership),
        fixtureRepository: _FakeFixtureRepository(),
        currentMembership: membership,
        moderationRepository: _FakeModerationRepository(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _openClanMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('clan-options-menu')));
  await tester.pumpAndSettle();
}

PlayerProfile _profile({required String id, required String name}) {
  return PlayerProfile(
    id: id,
    displayName: name,
    username: name.toLowerCase().replaceAll(' ', '.'),
    bio: '',
    followingCount: 0,
    fansCount: 0,
    appearances: 0,
    goals: 0,
    assists: 0,
    highlights: const [],
    career: const [],
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

class _FakeModerationRepository implements ModerationRepository {
  final List<ModerationReportDraft> reports = [];

  @override
  Future<ModerationStatus> getMyModerationStatus() async {
    return const ModerationStatus.active();
  }

  @override
  Future<ModerationReportReceipt> submitReport(
    ModerationReportDraft report,
  ) async {
    reports.add(report);
    return const ModerationReportReceipt(id: 'report-id');
  }
}

class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository({required this.currentUserId, required this.profile});

  @override
  final String currentUserId;
  final PlayerProfile profile;

  @override
  Future<PlayerProfile> getCurrentProfile() async => profile;

  @override
  Future<PlayerProfile> getProfile(String profileId) async => profile;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClanRepository implements ClanRepository {
  _FakeClanRepository(this.membership);

  final ClanMembership? membership;

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
