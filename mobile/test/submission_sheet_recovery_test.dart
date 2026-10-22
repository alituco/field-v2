import 'dart:async';

import 'package:field/src/moderation/moderation.dart';
import 'package:field/src/moderation/moderation_repository.dart';
import 'package:field/src/moderation/report_issue_sheet.dart';
import 'package:field/src/support/contact_support_sheet.dart';
import 'package:field/src/support/support.dart';
import 'package:field/src/support/support_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final support in [true, false]) {
    final name = support ? 'support' : 'report';
    final sheetKey = support
        ? contactSupportSheetKey
        : moderationReportSheetKey;
    final detailsKey = ValueKey(
      support ? 'support-details' : 'moderation-report-details',
    );
    final submitKey = ValueKey(
      support ? 'support-submit' : 'moderation-report-submit',
    );

    testWidgets('$name protects pending submission and retains failed draft', (
      tester,
    ) async {
      final repository = _PendingSubmissions();
      Object? receipt;
      await _open(
        tester,
        support: support,
        repository: repository,
        onReceipt: (value) => receipt = value,
      );
      await tester.tap(
        find.byKey(
          ValueKey(
            support
                ? 'support-category-booking_or_payment'
                : 'moderation-category-harassment',
          ),
        ),
      );
      const draft = 'Please investigate what happened during this game.';
      await tester.enterText(find.byKey(detailsKey), draft);
      tester.testTextInput.hide();
      await tester.pump();
      await tester.ensureVisible(find.byKey(submitKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(submitKey));
      await tester.pump();

      await tester.tapAt(const Offset(8, 8));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(sheetKey), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('fieldrush-modal-handle')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.drag(
        find.byKey(const ValueKey('fieldrush-modal-handle')),
        const Offset(0, 500),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(sheetKey), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(sheetKey), findsOneWidget);
      expect(receipt, isNull);
      expect(repository.submissions, 1);

      repository.first.completeError(StateError('Internal server error'));
      await tester.pumpAndSettle();
      expect(find.byKey(sheetKey), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(detailsKey)).controller!.text,
        draft,
      );
      expect(
        find.text(
          support
              ? 'We could not send your request. Try again.'
              : 'We could not send this report. Try again.',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(submitKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(submitKey));
      await tester.pump();
      expect(repository.submissions, 2);
      expect(repository.details, [draft, draft]);
      if (support) {
        expect(repository.requestIds[1], repository.requestIds[0]);
      }
      repository.second.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(sheetKey), findsNothing);
      expect(
        support
            ? (receipt as SupportRequestReceipt).id
            : (receipt as ModerationReportReceipt).id,
        'receipt',
      );
      expect(tester.takeException(), isNull);
    });

    for (final useBack in [true, false]) {
      testWidgets(
        '$name can close while idle using ${useBack ? 'back' : 'Close'}',
        (tester) async {
          final repository = _PendingSubmissions();
          await _open(tester, support: support, repository: repository);
          if (useBack) {
            await tester.binding.handlePopRoute();
          } else {
            await tester.tap(
              find.byKey(
                ValueKey(
                  support ? 'contact-support-close' : 'moderation-report-close',
                ),
              ),
            );
          }
          await tester.pumpAndSettle();
          expect(find.byKey(sheetKey), findsNothing);
          expect(repository.submissions, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

Future<void> _open(
  WidgetTester tester, {
  required bool support,
  required _PendingSubmissions repository,
  ValueChanged<Object?>? onReceipt,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final Object? receipt = support
                  ? await showContactSupportSheet(
                      context: context,
                      repository: repository,
                    )
                  : await showReportIssueSheet(
                      context: context,
                      repository: repository,
                      subjectType: ModerationSubjectType.player,
                      subjectId: 'player',
                      subjectName: 'Player',
                    );
              onReceipt?.call(receipt);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

class _PendingSubmissions implements SupportRepository, ModerationRepository {
  final first = Completer<void>();
  final second = Completer<void>();
  final details = <String>[];
  final requestIds = <String>[];
  var submissions = 0;

  Future<void> _submit(String draft) async {
    details.add(draft);
    submissions++;
    await (submissions == 1 ? first.future : second.future);
  }

  @override
  Future<SupportRequestReceipt> submitRequest(
    SupportRequestDraft request,
  ) async {
    requestIds.add(request.clientRequestId);
    await _submit(request.details);
    return const SupportRequestReceipt(id: 'receipt');
  }

  @override
  Future<ModerationReportReceipt> submitReport(
    ModerationReportDraft report,
  ) async {
    await _submit(report.details);
    return const ModerationReportReceipt(id: 'receipt');
  }

  @override
  Future<ModerationStatus> getMyModerationStatus() async =>
      const ModerationStatus.active();
}
