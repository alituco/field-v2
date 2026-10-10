import 'package:field/src/reliability/reliability.dart';
import 'package:field/src/reliability/reliability_deadline_notice.dart';
import 'package:field/src/reliability/reliability_repository.dart';
import 'package:field/src/reliability/reliability_status_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reliability status parses server-authored sanctions and appeals', () {
    final status = ReliabilityStatus.fromJson({
      'server_now': '2026-07-21T16:50:00Z',
      'policy_version_id': 'policy-one',
      'active_strike_count': 2,
      'reliability_deposit_required': true,
      'reliability_deposit_bps': 2000,
      'wallet': {'currency': 'BHD', 'balance_fils': 3750},
      'allowed_appeal_categories': [
        'FIELD_OR_VENUE_ERROR',
        'VERIFIED_MEDICAL_EMERGENCY',
      ],
      'attendance_history': [
        {
          'attendance_record_id': 'attendance-one',
          'attendance_outcome': 'late',
          'strike_delta': 1,
          'checked_in_at': '2026-07-21T16:52:00Z',
          'check_in_deadline_at': '2026-07-21T16:45:00Z',
          'appeal_deadline_at': '2026-07-23T17:00:00Z',
          'can_appeal': true,
        },
      ],
    });

    expect(status.activeStrikes, 2);
    expect(status.depositRequired, isTrue);
    expect(status.headline, 'Reliability deposit required');
    expect(status.supportingText, contains('20% refundable deposit'));
    expect(status.supportingText, contains('referee records'));
    expect(status.walletBalanceLabel, '3.750 BHD');
    expect(status.incidents.single.outcomeLabel, 'Late');
    expect(status.incidents.single.canAppeal, isTrue);
    expect(status.incidents.single.allowedAppealCategories, [
      ReliabilityAppealCategory.incorrectVenueInformation,
      ReliabilityAppealCategory.medicalEmergency,
    ]);
  });

  test('match context keeps hard deadlines and server eligibility', () {
    final context = MatchReliabilityContext.fromJson({
      'server_now': '2026-07-21T16:46:00Z',
      'kickoff_at': '2026-07-21T17:00:00Z',
      'check_in_deadline_at': '2026-07-21T16:45:00Z',
      'no_show_cutoff_at': '2026-07-21T17:10:00Z',
      'can_check_in': true,
      'can_finalize_attendance': false,
    });

    expect(context.checkInDeadlineAt, isNotNull);
    expect(context.kickoffAt, isNotNull);
    expect(context.noShowCutoffAt, isNotNull);
    expect(context.canCheckIn, isTrue);
    expect(context.canFinalizeAttendance, isFalse);
  });

  testWidgets('arrival notice makes referee check-in authority explicit', (
    tester,
  ) async {
    final context = MatchReliabilityContext.fromJson({
      'kickoff_at': '2026-07-21T17:00:00Z',
      'check_in_deadline_at': '2026-07-21T16:45:00Z',
      'no_show_cutoff_at': '2026-07-21T17:10:00Z',
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReliabilityDeadlineNotice(
            load: () async => context,
            includeNoShowCutoff: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ARRIVAL DEADLINE'), findsOneWidget);
    expect(find.textContaining('no app check-in is needed'), findsOneWidget);
    expect(
      find.textContaining('Missing players are finalized'),
      findsOneWidget,
    );
    expect(find.widgetWithText(ButtonStyleButton, 'Check in'), findsNothing);
  });

  test('appeal categories use the active policy contract codes', () {
    expect(
      ReliabilityAppealCategory.incorrectVenueInformation.code,
      'FIELD_OR_VENUE_ERROR',
    );
    expect(
      ReliabilityAppealCategory.medicalEmergency.code,
      'VERIFIED_MEDICAL_EMERGENCY',
    );
    expect(
      ReliabilityAppealCategory.seriousEmergency.code,
      'SERIOUS_ACCIDENT_OR_EMERGENCY',
    );
    expect(ReliabilityAppealCategory.otherDocumentedException.code, 'OTHER');
  });

  test('incident appeal options stay pinned to its match policy', () {
    final status = ReliabilityStatus.fromJson({
      'allowed_appeal_categories': ['OTHER'],
      'incidents': [
        {
          'attendance_record_id': 'attendance-one',
          'outcome': 'LATE',
          'can_appeal': true,
          'allowed_appeal_categories': ['WRONG_PLAYER_CHECKED_IN'],
        },
        {
          'attendance_record_id': 'attendance-two',
          'outcome': 'NO_SHOW',
          'can_appeal': true,
          'allowed_appeal_categories': <String>[],
        },
      ],
    });

    expect(status.incidents.first.allowedAppealCategories, [
      ReliabilityAppealCategory.wrongPlayerCheckedIn,
    ]);
    expect(status.incidents.first.canAppeal, isTrue);
    expect(status.incidents.last.allowedAppealCategories, isEmpty);
    expect(status.incidents.last.canAppeal, isFalse);
  });

  testWidgets('profile reliability card exposes eligible attendance appeal', (
    tester,
  ) async {
    final repository = _FakeReliabilityRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReliabilityStatusCard(repository: repository),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reliability deposit required'), findsOneWidget);
    expect(find.text('2 ACTIVE'), findsOneWidget);
    expect(find.text('FIELD WALLET'), findsOneWidget);
    expect(find.text('3.750 BHD'), findsOneWidget);
    expect(find.text('Appeal'), findsOneWidget);

    await tester.tap(find.text('Appeal'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reliability-appeal-sheet')),
      findsOneWidget,
    );
    expect(find.text('Late'), findsWidgets);
  });
}

class _FakeReliabilityRepository implements ReliabilityRepository {
  @override
  Future<ReliabilityStatus> getMyStatus() async {
    return ReliabilityStatus.fromJson({
      'active_strikes': 2,
      'deposit_required': true,
      'deposit_bps': 2000,
      'wallet': {'currency': 'BHD', 'balance_fils': 3750},
      'allowed_appeal_categories': ['VERIFIED_MEDICAL_EMERGENCY'],
      'incidents': [
        {
          'attendance_record_id': 'attendance-one',
          'outcome': 'LATE',
          'strike_delta': 1,
          'can_appeal': true,
          'appeal_deadline_at': '2026-07-23T17:00:00Z',
        },
      ],
    });
  }

  @override
  Future<void> submitAppeal({
    required String attendanceRecordId,
    required ReliabilityAppealCategory category,
    required String message,
  }) async {}
}
