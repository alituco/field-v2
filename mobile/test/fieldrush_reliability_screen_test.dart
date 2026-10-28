import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/reliability/fieldrush_reliability_screen.dart';
import 'package:field/src/reliability/reliability.dart';
import 'package:field/src/reliability/reliability_repository.dart';
import 'package:field/src/home/field_bottom_nav.dart';
import 'package:field/src/ui/field_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'effective policy keeps actual penalties and all active decisions',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      expect(find.text('Good standing'), findsOneWidget);
      expect(find.text('Late arrival · Tue, Sep 8'), findsOneWidget);
      expect(
        find.text('Checked in at 8:27 PM · Diablo Soccer Field 07'),
        findsOneWidget,
      );
      expect(find.text('Clears Mon, Dec 7'), findsOneWidget);
      expect(find.text('Appeal'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('WHAT HAPPENS'), 250);
      expect(find.text('Cancelling inside 24 hours'), findsOneWidget);
      expect(find.text('Cancelling after kickoff'), findsOneWidget);
      expect(find.text('20% refundable deposit'), findsOneWidget);
      expect(find.text('7-day booking restriction'), findsOneWidget);
      expect(find.text('14-day booking restriction'), findsOneWidget);
      expect(find.text('Permanent ban'), findsNothing);
      expect(find.text('Cancelling inside 3 hours'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'reversals, expired strikes and pending appeals keep server meaning',
    () {
      final now = DateTime.utc(2026, 9, 11);
      expect(
        ReliabilityIncident.fromJson({
          ..._incident,
          'strike_active': false,
        }).isActiveAt(now),
        isFalse,
      );
      expect(
        ReliabilityIncident.fromJson({
          ..._incident,
          'strike_expires_at': '2026-09-10T00:00:00Z',
        }).isActiveAt(now),
        isFalse,
      );
      final overturned = ReliabilityIncident.fromJson({
        ..._incident,
        'appeal_status': 'OVERTURNED',
      });
      expect(overturned.excused, isTrue);
      expect(overturned.isActiveAt(now), isFalse);
      expect(
        ReliabilityIncident.fromJson({
          ..._incident,
          'appeal_status': 'REVIEWING',
        }).appealPending,
        isTrue,
      );
    },
  );

  testWidgets(
    'all active strikes show while excused and expired findings stay separate',
    (tester) async {
      final repository = _Repository();
      repository.value = ReliabilityStatus.fromJson({
        ..._status,
        'active_strikes': 4,
        'incidents': [
          _incident,
          {
            ..._incident,
            'attendance_record_id': 'two',
            'outcome': 'NO_SHOW',
            'strike_delta': 2,
          },
          {
            ..._incident,
            'attendance_record_id': 'three',
            'outcome': 'CANCELLED_LATE',
          },
          _excused,
          {
            ..._incident,
            'attendance_record_id': 'expired',
            'strike_active': false,
            'strike_expires_at': '2026-09-10T00:00:00Z',
          },
        ],
      });
      await _pump(tester, repository);
      expect(find.text('No-show · Tue, Sep 8'), findsOneWidget);
      expect(find.text('Cancelled late · Tue, Sep 8'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('Late arrival · Fri, Aug 21'), findsNothing);
      await tester.tap(find.text('Excused'));
      await tester.pumpAndSettle();
      expect(find.text('Late arrival · Fri, Aug 21'), findsOneWidget);
      expect(find.textContaining('Excused after review.'), findsOneWidget);
      expect(find.text('Past strikes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending appeal is under review without another appeal button', (
    tester,
  ) async {
    final repository = _Repository();
    repository.value = ReliabilityStatus.fromJson({
      ..._status,
      'incidents': [
        {
          ..._incident,
          'appeal_status': 'OPEN',
          'appeal_submitted_at': '2026-09-10T20:00:00Z',
        },
      ],
    });
    await _pump(tester, repository);
    expect(find.text('UNDER REVIEW'), findsOneWidget);
    expect(find.text('Appeal sent Thu, Sep 10'), findsOneWidget);
    expect(find.text('Appeal'), findsNothing);
  });

  for (final standing in [
    (
      value: <String, dynamic>{'active_strikes': 0, 'incidents': <Object>[]},
      title: 'Spotless',
    ),
    (
      value: <String, dynamic>{
        'booking_restricted_until': '2026-09-15T20:00:00Z',
      },
      title: 'You can’t book new games',
    ),
    (
      value: <String, dynamic>{
        'participation_suspended_until': '2026-10-11T20:00:00Z',
      },
      title: 'You can’t play right now',
    ),
    (
      value: <String, dynamic>{'indefinite_suspension': true},
      title: 'Your participation is suspended',
    ),
  ]) {
    testWidgets('standing uses actual ${standing.title} state', (tester) async {
      final repository = _Repository()
        ..value = ReliabilityStatus.fromJson({..._status, ...standing.value});
      await _pump(tester, repository);
      expect(find.text(standing.title), findsOneWidget);
      expect(find.text('Permanent ban'), findsNothing);
    });
  }

  testWidgets(
    'stalled status read times out, retries and ignores stale response',
    (tester) async {
      final barrier = Completer<ReliabilityStatus>();
      final repository = _Repository()..barrier = barrier;
      await tester.pumpWidget(_app(repository));
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      repository.barrier = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      barrier.complete(
        ReliabilityStatus.fromJson({..._status, 'indefinite_suspension': true}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Good standing'), findsOneWidget);
      expect(find.text('Your participation is suspended'), findsNothing);
    },
  );

  testWidgets(
    'appeal keeps allowed categories, draft and validation on failure',
    (tester) async {
      final repository = _Repository()
        ..submitError = StateError('Temporary failure');
      await _pump(tester, repository);
      await tester.tap(find.text('Appeal'));
      await tester.pumpAndSettle();
      expect(find.text('Appeal a strike'), findsOneWidget);
      expect(find.text('Medical emergency'), findsOneWidget);
      expect(find.text('Wrong player was checked in'), findsOneWidget);
      expect(find.text('Incorrect venue information'), findsNothing);
      final submit = find.byKey(const ValueKey('submit-reliability-appeal'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(find.text('Medical emergency'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.textContaining('at least 10 characters'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reliability-appeal-details')),
        'A medical emergency prevented my arrival.',
      );
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(
        find.text('A medical emergency prevented my arrival.'),
        findsOneWidget,
      );
      expect(
        repository.appeals.single.category,
        ReliabilityAppealCategory.medicalEmergency,
      );
      repository.submitError = null;
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Appeal a strike'), findsNothing);
      expect(repository.appeals.last.record, 'attendance-one');
      expect(find.text('UNDER REVIEW'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reliability and appeal fit narrow screens with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository();
    await tester.pumpWidget(_app(repository, textScale: 1.7));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Appeal'), 200);
    await tester.tap(find.text('Appeal'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Send appeal'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shared dock stays on You and cannot leave during appeal submission',
    (tester) async {
      final submitted = Completer<void>();
      final repository = _Repository()..submitBarrier = submitted;
      final tabs = <int>[];
      await tester.pumpWidget(_app(repository, onNavigateTab: tabs.add));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FieldBottomNav>(find.byType(FieldBottomNav))
            .selectedIndex,
        4,
      );
      await tester.tap(find.text('Appeal'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FieldBottomNav>(find.byType(FieldBottomNav))
            .selectedIndex,
        4,
      );
      await tester.tap(find.text('Medical emergency'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reliability-appeal-details')),
        'A documented emergency prevented my arrival.',
      );
      final send = find.byKey(const ValueKey('submit-reliability-appeal'));
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pump(const Duration(milliseconds: 200));
      tester.widget<FieldBottomNav>(find.byType(FieldBottomNav)).onSelected(0);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tabs, isEmpty);
      expect(
        find.descendant(of: send, matching: find.byType(FieldLoadingIndicator)),
        findsOneWidget,
      );
      submitted.complete();
      await tester.pumpAndSettle();
      expect(find.text('Appeal a strike'), findsNothing);
      tester.widget<FieldBottomNav>(find.byType(FieldBottomNav)).onSelected(0);
      expect(tabs, [0]);
    },
  );

  testWidgets('render reliability and appeal with bundled fonts', (
    tester,
  ) async {
    final directory =
        Platform.environment['FIELDRUSH_RELIABILITY_SCREENSHOT_DIR'];
    if (directory == null) return;
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        await (FontLoader(
          font,
        )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    final key = GlobalKey();
    await tester.pumpWidget(
      _app(_Repository(), boundary: key, onNavigateTab: (_) {}),
    );
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        await Directory(directory).create(recursive: true);
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('reliability-page');
    await tester.tap(find.text('Appeal'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await capture('reliability-appeal');
  });
}

Future<void> _pump(WidgetTester tester, _Repository repository) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(repository));
  await tester.pumpAndSettle();
}

Widget _app(
  _Repository repository, {
  GlobalKey? boundary,
  double textScale = 1,
  ValueChanged<int>? onNavigateTab,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: RepaintBoundary(key: boundary, child: child!),
  ),
  home: FieldrushReliabilityScreen(
    repository: repository,
    onNavigateTab: onNavigateTab,
  ),
);

class _Repository implements ReliabilityRepository {
  ReliabilityStatus value = ReliabilityStatus.fromJson(_status);
  Completer<ReliabilityStatus>? barrier;
  Object? submitError;
  Completer<void>? submitBarrier;
  final appeals =
      <({String record, ReliabilityAppealCategory category, String message})>[];

  @override
  Future<ReliabilityStatus> getMyStatus() async =>
      barrier == null ? value : await barrier!.future;

  @override
  Future<void> submitAppeal({
    required String attendanceRecordId,
    required ReliabilityAppealCategory category,
    required String message,
  }) async {
    appeals.add((
      record: attendanceRecordId,
      category: category,
      message: message,
    ));
    if (submitError case final error?) throw error;
    if (submitBarrier case final barrier?) await barrier.future;
    value = ReliabilityStatus.fromJson({
      ..._status,
      'incidents': [
        {..._incident, 'appeal_status': 'OPEN', 'can_appeal': false},
        _excused,
      ],
    });
  }
}

const _incident = <String, dynamic>{
  'attendance_record_id': 'attendance-one',
  'outcome': 'LATE',
  'strike_delta': 1,
  'occurred_at': '2026-09-09T04:30:00Z',
  'checked_in_at': '2026-09-09T03:27:00Z',
  'check_in_deadline_at': '2026-09-09T03:20:00Z',
  'strike_expires_at': '2026-12-08T04:30:00Z',
  'appeal_deadline_at': '2026-09-15T22:00:00Z',
  'can_appeal': true,
  'allowed_appeal_categories': [
    'VERIFIED_MEDICAL_EMERGENCY',
    'WRONG_PLAYER_CHECKED_IN',
  ],
  'match_label': 'Diablo Soccer Field 07',
  'timezone': 'America/Phoenix',
};
const _excused = <String, dynamic>{
  'attendance_record_id': 'excused-one',
  'outcome': 'EXCUSED',
  'strike_delta': 0,
  'original_outcome': 'LATE',
  'original_strike_delta': 1,
  'occurred_at': '2026-08-22T04:30:00Z',
  'checked_in_at': '2026-08-22T03:23:00Z',
  'appeal_status': 'OVERTURNED',
  'can_appeal': false,
  'timezone': 'America/Phoenix',
};
const _status = <String, dynamic>{
  'server_now': '2026-09-11T20:00:00Z',
  'active_strikes': 1,
  'timezone': 'America/Phoenix',
  'incidents': [_incident, _excused],
  'policy_display': {
    'strike_lifetime_days': 90,
    'late_strikes': 1,
    'no_show_strikes': 2,
    'cancellations': {
      'early': {'minimumHoursBeforeKickoff': 24, 'strikes': 0},
      'late': {'minimumHoursBeforeKickoff': 10, 'strikes': 1},
      'veryLate': {'strikes': 1},
      'afterKickoff': {'strikes': 2},
    },
    'deposit': {'activeStrikeThreshold': 2, 'depositBps': 2000},
    'sanctions': [
      {
        'threshold': 1,
        'kind': 'WARNING',
        'durationDays': 0,
        'releaseFutureBookings': false,
      },
      {
        'threshold': 3,
        'kind': 'BOOKING_RESTRICTION',
        'durationDays': 7,
        'releaseFutureBookings': false,
      },
      {
        'threshold': 4,
        'kind': 'BOOKING_RESTRICTION',
        'durationDays': 14,
        'releaseFutureBookings': false,
      },
      {
        'threshold': 5,
        'kind': 'PARTICIPATION_SUSPENSION',
        'durationDays': 30,
        'releaseFutureBookings': true,
      },
      {
        'threshold': 6,
        'kind': 'INDEFINITE_SUSPENSION',
        'durationDays': null,
        'releaseFutureBookings': true,
      },
    ],
  },
};
