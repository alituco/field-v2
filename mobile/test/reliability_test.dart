import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/reliability/reliability.dart';
import 'package:field/src/reliability/reliability_deadline_notice.dart';
import 'package:field/src/reliability/reliability_repository.dart';
import 'package:field/src/reliability/reliability_status_card.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('USD wallet uses dollars and cents without relabeling legacy BHD', () {
    final usd = ReliabilityStatus.fromJson({
      'wallet': {'currency': 'USD', 'balance_fils': 13520},
    });
    final bhd = ReliabilityStatus.fromJson({
      'wallet': {'currency': 'BHD', 'balance_fils': 13520},
    });
    expect(usd.walletBalanceLabel, r'$13.52');
    expect(bhd.walletBalanceLabel, '13.520 BHD');
  });

  test('wallet preserves exact fractional-cent policy credits', () {
    final status = ReliabilityStatus.fromJson({
      'wallet': {
        'currency': 'USD',
        'balance_fils': 6505,
        'balances': [
          {'currency': 'USD', 'balance_fils': 6505},
          {'currency': 'BHD', 'balance_fils': 3750},
        ],
      },
    });
    expect(status.walletBalanceLabel, r'$6.505');
    expect(status.visibleWalletBalances.map((balance) => balance.label), [
      r'$6.505',
      '3.750 BHD',
    ]);
  });

  testWidgets(
    'wallet shows USD and BHD as separate balances without conversion',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReliabilityStatusCard(
              repository: _FakeReliabilityRepository(
                wallet: {
                  'currency': 'BHD',
                  'balance_fils': 3750,
                  'balances': [
                    {'currency': 'USD', 'balance_fils': 6505},
                    {'currency': 'BHD', 'balance_fils': 3750},
                  ],
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('FIELD WALLET · USD'), findsOneWidget);
      expect(find.text('FIELD WALLET · BHD'), findsOneWidget);
      expect(find.text(r'$6.505'), findsOneWidget);
      expect(find.text('3.750 BHD'), findsOneWidget);
      expect(
        find.text('Balances are separate. No currency conversion.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'USD credit is visible even when the primary BHD wallet is empty',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReliabilityStatusCard(
              repository: _FakeReliabilityRepository(
                wallet: {
                  'currency': 'BHD',
                  'balance_fils': 0,
                  'balances': [
                    {'currency': 'USD', 'balance_fils': 13000},
                    {'currency': 'BHD', 'balance_fils': 0},
                  ],
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('FIELD WALLET · USD'), findsOneWidget);
      expect(find.text(r'$13.00'), findsOneWidget);
      expect(find.text('FIELD WALLET · BHD'), findsNothing);
    },
  );

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

    expect(find.text('CHECK-IN DEADLINE'), findsOneWidget);
    expect(find.textContaining('no app check-in is needed'), findsOneWidget);
    expect(
      find.textContaining('Missing players are finalized'),
      findsOneWidget,
    );
    expect(find.widgetWithText(ButtonStyleButton, 'Check in'), findsNothing);
  });

  for (final venue in [
    (timezone: 'America/Phoenix', deadline: '9:45 AM', cutoff: '10:10 AM'),
    (timezone: 'Asia/Bahrain', deadline: '7:45 PM', cutoff: '8:10 PM'),
  ]) {
    testWidgets(
      'check-in deadline respects ${venue.timezone} and saved policy',
      (tester) async {
        final context = MatchReliabilityContext.fromJson({
          'check_in_deadline_at': '2026-07-21T16:45:00Z',
          'no_show_cutoff_at': '2026-07-21T17:10:00Z',
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReliabilityDeadlineNotice(
                load: () async => context,
                timezone: venue.timezone,
                includeNoShowCutoff: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Check-in deadline: ${venue.deadline}.'),
          findsOneWidget,
        );
        expect(
          find.text('Missing players are finalized at ${venue.cutoff}.'),
          findsOneWidget,
        );
        expect(find.textContaining('Kickoff'), findsNothing);
        expect(find.textContaining('1 strike'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'supplemental attendance information does not repeat the arrival panel',
    (tester) async {
      final context = MatchReliabilityContext.fromJson({
        'check_in_deadline_at': '2026-07-21T16:45:00Z',
        'no_show_cutoff_at': '2026-07-21T17:10:00Z',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReliabilityDeadlineNotice(
              load: () async => context,
              timezone: 'America/Phoenix',
              showDeadline: false,
              includeNoShowCutoff: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('CHECK-IN DEADLINE'), findsNothing);
      expect(find.textContaining('9:45 AM'), findsNothing);
      expect(
        find.byKey(const ValueKey('reliability-check-in-deadline')),
        findsNothing,
      );
      expect(
        find.text('The referee records attendance; no app check-in is needed.'),
        findsOneWidget,
      );
      expect(
        find.text('Missing players are finalized at 10:10 AM.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(find.text('FIELD WALLET · BHD'), findsOneWidget);
    expect(find.text('3.750 BHD'), findsOneWidget);
    expect(find.text('Appeal'), findsOneWidget);

    await tester.tap(find.text('Appeal'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reliability-appeal-sheet')),
      findsOneWidget,
    );
    expect(find.text('Late'), findsWidgets);
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(
      Theme.of(
        tester.element(
          find.byKey(const ValueKey('reliability-appeal-details')),
        ),
      ).colorScheme.surface,
      FieldrushAuthTheme.cream,
    );
  });

  testWidgets('appeal keeps allowed reasons, validation and retry', (
    tester,
  ) async {
    final repository = _FakeReliabilityRepository()..failSubmit = true;
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
    await tester.tap(find.text('Appeal'));
    await tester.pumpAndSettle();
    final reason = tester
        .widget<DropdownButtonFormField<ReliabilityAppealCategory>>(
          find.byKey(const ValueKey('reliability-appeal-reason')),
        );
    expect(reason.initialValue, ReliabilityAppealCategory.medicalEmergency);
    final submit = find.byKey(const ValueKey('submit-reliability-appeal'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('Add at least 10 characters'), findsOneWidget);
    expect(repository.appeals, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('reliability-appeal-details')),
      'An emergency stopped me attending.',
    );
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reliability-appeal-error')),
      findsOneWidget,
    );
    expect(
      repository.appeals.single.category,
      ReliabilityAppealCategory.medicalEmergency,
    );
    repository.failSubmit = false;
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(repository.appeals.length, 2);
    expect(repository.appeals.last.recordId, 'attendance-one');
    expect(
      repository.appeals.last.message,
      'An emergency stopped me attending.',
    );
    expect(find.byType(FieldrushModal), findsNothing);
    expect(
      find.text('Appeal submitted. Field operations will review it.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'appeal actions remain reachable with the keyboard and large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.4),
              viewInsets: const EdgeInsets.only(bottom: 240),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showReliabilityAppealSheet(
                  context: context,
                  repository: _FakeReliabilityRepository(),
                  incident: ReliabilityIncident.fromJson({
                    'id': 'attendance-one',
                    'outcome': 'NO_SHOW',
                    'strike_delta': 1,
                    'checked_in_at': '2026-10-14T01:00:00Z',
                    'check_in_deadline_at': '2026-10-14T01:00:00Z',
                    'allowed_appeal_categories': [
                      'SERIOUS_ACCIDENT_OR_EMERGENCY',
                    ],
                  }),
                ),
                child: const Text('Open appeal'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open appeal'));
      await tester.pumpAndSettle();
      final cancel = find.widgetWithText(OutlinedButton, 'Cancel');
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushModal), findsNothing);
    },
  );
}

class _FakeReliabilityRepository implements ReliabilityRepository {
  _FakeReliabilityRepository({
    this.wallet = const {'currency': 'BHD', 'balance_fils': 3750},
  });
  final Map<String, dynamic> wallet;
  bool failSubmit = false;
  final appeals =
      <
        ({String recordId, ReliabilityAppealCategory category, String message})
      >[];
  @override
  Future<ReliabilityStatus> getMyStatus() async {
    return ReliabilityStatus.fromJson({
      'active_strikes': 2,
      'deposit_required': true,
      'deposit_bps': 2000,
      'wallet': wallet,
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
  }) async {
    appeals.add((
      recordId: attendanceRecordId,
      category: category,
      message: message,
    ));
    if (failSubmit) throw StateError('Service temporarily unavailable');
  }
}
