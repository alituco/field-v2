import 'dart:async';

import 'package:field/src/clans/clan_widgets.dart';
import 'package:field/src/fixtures/fixture_reliability_roster_panel.dart';
import 'package:field/src/moderation/account_restriction_screen.dart';
import 'package:field/src/reliability/reliability.dart';
import 'package:field/src/reliability/reliability_repository.dart';
import 'package:field/src/reliability/reliability_status_card.dart';
import 'package:field/src/ui/field_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('legacy skeleton boxes keep their dimensions without animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: FieldSkeletonBox(width: 120, height: 22, borderRadius: 6),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(FieldSkeletonBox)), const Size(120, 22));
    expect(find.byType(FieldSkeleton), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('roster card uses readable skeletons at narrow widths', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: FixtureReliabilityRosterLoadingCard(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FieldSkeleton), findsNWidgets(5));
    expect(
      find.bySemanticsLabel('Loading your matchday roster'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('reliability loading stays quiet until real data arrives', (
    tester,
  ) async {
    final repository = _PendingReliabilityRepository();
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: ReliabilityStatusCard(repository: repository),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('profile-reliability-loading')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Loading reliability status'), findsOneWidget);
    expect(find.byType(FieldSkeleton), findsNWidgets(3));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    repository.pending.complete(ReliabilityStatus.fromJson({}));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('profile-reliability-loading')),
      findsNothing,
    );
    semantics.dispose();
  });

  testWidgets('account checks show placeholders without spinning', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ModerationStatusLoadingScreen()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FieldSkeleton), findsNWidgets(2));
    expect(find.text('Checking your account…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}

class _PendingReliabilityRepository implements ReliabilityRepository {
  final pending = Completer<ReliabilityStatus>();

  @override
  Future<ReliabilityStatus> getMyStatus() => pending.future;

  @override
  Future<void> submitAppeal({
    required String attendanceRecordId,
    required ReliabilityAppealCategory category,
    required String message,
  }) async {}
}
