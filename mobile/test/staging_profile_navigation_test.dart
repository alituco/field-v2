import 'package:field/src/moderation/moderation.dart';
import 'package:field/src/moderation/moderation_repository.dart';
import 'package:field/src/moderation/report_issue_sheet.dart';
import 'package:field/src/profile/fieldrush_player_profile.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/helpers/staging_profile_navigation.dart';

void main() {
  testWidgets('staging back waits for the loaded public player and returns', (
    tester,
  ) async {
    final repository = _DelayedProfileRepository();
    await _openViewedProfile(tester, repository);

    expect(find.byType(FieldrushPlayerProfileContent), findsNothing);
    expect(find.byKey(const ValueKey('player-back')), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);

    await returnFromViewedPlayerProfile(tester, expectedProfileId: 'player-id');
    await tester.pumpAndSettle();

    expect(repository.loadFinished, isTrue);
    expect(repository.requestedIds, ['player-id']);
    expect(find.byKey(const ValueKey('previous-route')), findsOneWidget);
    expect(find.byType(ProfileScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('staging report scrolls to the direct action and submits', (
    tester,
  ) async {
    final repository = _DelayedProfileRepository();
    final moderation = _ModerationRepository();
    await _openViewedProfile(tester, repository, moderation: moderation);

    expect(find.byType(FieldrushPlayerProfileContent), findsNothing);
    expect(find.byKey(const ValueKey('profile-options-menu')), findsNothing);
    expect(find.byKey(const ValueKey('profile-report-action')), findsNothing);

    await openViewedPlayerReport(tester, expectedProfileId: 'player-id');
    await tester.pumpAndSettle();

    expect(repository.loadFinished, isTrue);
    expect(repository.requestedIds, ['player-id']);
    expect(find.byKey(moderationReportSheetKey), findsOneWidget);
    expect(find.text('Report Noor Saleh'), findsOneWidget);
    final profileScrollable = find.descendant(
      of: find.byKey(const ValueKey('profile-content')),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(profileScrollable).position.pixels,
      greaterThan(0),
      reason: 'The direct report action must be reached below the viewport.',
    );
    expect(
      tester.widget<ReportIssueSheet>(find.byType(ReportIssueSheet)).subjectId,
      'player-id',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('moderation-category-harassment')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('moderation-category-harassment')),
    );
    const details = 'Repeated abuse after the staging match.';
    await tester.enterText(
      find.byKey(const ValueKey('moderation-report-details')),
      details,
    );
    tester.testTextInput.hide();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    final submit = find.byKey(const ValueKey('moderation-report-submit'));
    await tester.ensureVisible(submit);
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(moderation.reports, hasLength(1));
    final report = moderation.reports.single;
    expect(report.subjectType, ModerationSubjectType.player);
    expect(report.subjectId, 'player-id');
    expect(report.category, ModerationReportCategory.harassment);
    expect(report.details, details);
    expect(find.byKey(moderationReportSheetKey), findsNothing);
    expect(
      find.text('Report sent privately · reference REPORTID'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final action in <String, Future<void> Function(WidgetTester)>{
    'back': (tester) =>
        returnFromViewedPlayerProfile(tester, expectedProfileId: 'player-id'),
    'report': (tester) =>
        openViewedPlayerReport(tester, expectedProfileId: 'player-id'),
  }.entries) {
    testWidgets('staging ${action.key} rejects a different loaded player', (
      tester,
    ) async {
      final repository = _DelayedProfileRepository(loadedId: 'wrong-player');
      final moderation = _ModerationRepository();
      await _openViewedProfile(tester, repository, moderation: moderation);

      Object? failure;
      try {
        await action.value(tester);
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<TestFailure>());
      await tester.pumpAndSettle();

      expect(repository.loadFinished, isTrue);
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(
        tester
            .widget<FieldrushPlayerProfileContent>(
              find.byType(FieldrushPlayerProfileContent),
            )
            .profile
            .id,
        'wrong-player',
      );
      expect(find.byKey(moderationReportSheetKey), findsNothing);
      expect(moderation.reports, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _openViewedProfile(
  WidgetTester tester,
  _DelayedProfileRepository repository, {
  _ModerationRepository? moderation,
}) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          key: const ValueKey('previous-route'),
          body: Center(
            child: TextButton(
              key: const ValueKey('open-profile'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => ProfileScreen(
                    profileId: 'player-id',
                    profileRepository: repository,
                    moderationRepository: moderation ?? _ModerationRepository(),
                  ),
                ),
              ),
              child: const Text('Open profile'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-profile')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

class _DelayedProfileRepository extends Fake implements ProfileRepository {
  _DelayedProfileRepository({this.loadedId = 'player-id'});

  final String loadedId;
  final List<String> requestedIds = [];
  bool loadFinished = false;

  @override
  String get currentUserId => 'viewer-id';

  @override
  Future<PlayerProfile> getProfile(String profileId) async {
    requestedIds.add(profileId);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    loadFinished = true;
    return PlayerProfile(
      id: loadedId,
      displayName: 'Noor Saleh',
      username: 'noor.saleh',
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
}

class _ModerationRepository extends Fake implements ModerationRepository {
  final List<ModerationReportDraft> reports = [];

  @override
  Future<ModerationReportReceipt> submitReport(
    ModerationReportDraft report,
  ) async {
    reports.add(report);
    return const ModerationReportReceipt(id: 'report-id');
  }
}
