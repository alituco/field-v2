import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/fixtures/match_resolution.dart';
import 'package:field/src/fixtures/match_resolution_panel.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses participant-safe resolution, refund, and dispute details', () {
    final resolutionCase = MatchResolutionCase.fromJson({
      'id': 'case-1',
      'match_kind': 'SOLO',
      'match_id': 'game-1',
      'state': 'UNDER_REVIEW',
      'reason_code': 'REFUND_FAILED',
      'detected_at': '2026-07-29T18:00:00Z',
      'high_priority_at': '2026-07-30T18:00:00Z',
      'current_revision': 2,
      'resolution': {
        'id': 'revision-2',
        'revision': 2,
        'resolution_type': 'AWAY_NO_SHOW',
        'reason': 'Black team did not attend.',
        'consequences': {
          'home_score': 3,
          'away_score': 0,
          'home_strikes': 0,
          'away_strikes': 1,
        },
        'created_at': '2026-07-29T19:00:00Z',
      },
      'refunds': [
        {
          'id': 'refund-1',
          'side': 'WHITE',
          'amount_fils': 0,
          'target_amount_fils': 3500,
          'refund_bps': 10000,
          'destination': 'FIELD_WALLET',
          'status': 'FAILED',
          'failure_reason': 'Wallet credit needs retry.',
          'created_at': '2026-07-29T19:01:00Z',
        },
      ],
      'my_disputes': [
        {
          'id': 'dispute-1',
          'revision_id': 'revision-2',
          'reason': 'I attended this match.',
          'status': 'OPEN',
          'submitted_at': '2026-07-29T20:00:00Z',
          'resolved_at': null,
          'resolution_note': null,
        },
      ],
      'dispute_due_at': '2026-07-30T19:00:00Z',
      'can_dispute': false,
      'refunds_continue_during_dispute': true,
    });

    expect(resolutionCase.matchKind, MatchResolutionKind.solo);
    expect(resolutionCase.outcomeLabel, 'Away side did not show');
    expect(resolutionCase.resolution?.scoreLabel, '3–0');
    expect(resolutionCase.refunds, hasLength(1));
    expect(resolutionCase.refunds.single.amountLabel, '3.500 BHD');
    expect(resolutionCase.refunds.single.statusLabel, 'Refund needs attention');
    expect(resolutionCase.latestDispute?.statusLabel, 'Under review');
    expect(resolutionCase.refundsContinueDuringDispute, isTrue);
  });

  testWidgets(
    'dispute sheet validates the reason and refreshes participant status',
    (tester) async {
      final repository = _FakeResolutionRepository(
        initial: _resolutionCase(canDispute: true),
        afterDispute: _resolutionCase(
          canDispute: false,
          disputes: const [
            MatchResolutionDispute(
              id: 'dispute-1',
              revisionId: 'revision-1',
              reason: 'I was present before kickoff.',
              status: 'OPEN',
              submittedAt: null,
              resolvedAt: null,
              resolutionNote: null,
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: MatchResolutionPanel(
                resolutionCase: repository.initial,
                repository: repository,
                matchKind: MatchResolutionKind.clan,
                matchId: 'fixture-1',
              ),
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('open-match-resolution-dispute')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('match-resolution-dispute-sheet')),
        findsOneWidget,
      );
      expect(find.byType(FieldrushModal), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.text('Tell us what needs another look.'))
            .style
            ?.fontFamily,
        'Outfit',
      );
      final sendButton = tester.widget<FilledButton>(
        find.byKey(const ValueKey('submit-match-resolution-dispute')),
      );
      expect(
        sendButton.style?.backgroundColor?.resolve({}),
        FieldrushAuthTheme.forest,
      );
      expect(find.text('Send to Fieldrush'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(repository.submittedReasons, isEmpty);
      expect(find.byType(FieldrushModal), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('open-match-resolution-dispute')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('match-resolution-dispute-reason')),
        'Too short',
      );
      await tester.tap(
        find.byKey(const ValueKey('submit-match-resolution-dispute')),
      );
      await tester.pump();
      expect(find.textContaining('at least 10 characters'), findsOneWidget);
      expect(repository.submittedReasons, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('match-resolution-dispute-reason')),
        'I was present before kickoff.',
      );
      await tester.tap(
        find.byKey(const ValueKey('submit-match-resolution-dispute')),
      );
      await tester.pumpAndSettle();

      expect(repository.submittedReasons, ['I was present before kickoff.']);
      expect(
        find.byKey(const ValueKey('match-resolution-dispute-status')),
        findsOneWidget,
      );
      expect(find.textContaining('UNDER REVIEW'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('open-match-resolution-dispute')),
        findsNothing,
      );
    },
  );
}

MatchResolutionCase _resolutionCase({
  required bool canDispute,
  List<MatchResolutionDispute> disputes = const [],
}) {
  return MatchResolutionCase(
    id: 'case-1',
    matchKind: MatchResolutionKind.clan,
    matchId: 'fixture-1',
    state: 'RESOLVED',
    reasonCode: 'NO_ACTIVITY',
    detectedAt: null,
    highPriorityAt: null,
    currentRevision: 1,
    resolution: const MatchResolution(
      id: 'revision-1',
      revision: 1,
      resolutionType: 'HOME_NO_SHOW',
      reason: 'The home clan did not attend.',
      consequences: {'home_score': 0, 'away_score': 3},
      createdAt: null,
    ),
    refunds: const [
      MatchResolutionRefund(
        id: 'refund-1',
        side: 'HOME',
        amountFils: 0,
        targetAmountFils: 0,
        refundBps: 0,
        destination: 'FIELD_WALLET',
        status: 'NOT_DUE',
        failureReason: null,
        createdAt: null,
      ),
    ],
    myDisputes: disputes,
    disputeDueAt: DateTime(2026, 7, 31),
    canDispute: canDispute,
    refundsContinueDuringDispute: true,
  );
}

class _FakeResolutionRepository implements MatchResolutionRepository {
  _FakeResolutionRepository({
    required this.initial,
    required this.afterDispute,
  });

  final MatchResolutionCase initial;
  final MatchResolutionCase afterDispute;
  final List<String> submittedReasons = [];

  @override
  Future<MatchResolutionCase?> getMatchResolutionCase({
    required MatchResolutionKind matchKind,
    required String matchId,
  }) async {
    return submittedReasons.isEmpty ? initial : afterDispute;
  }

  @override
  Future<void> submitMatchResolutionDispute({
    required String caseId,
    required String reason,
  }) async {
    submittedReasons.add(reason);
  }
}
