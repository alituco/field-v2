import 'package:field/src/open_queue/fieldrush_check_in_notice.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final json = <String, dynamic>{
    'id': 'game',
    'status': 'OPEN',
    'venue': 'Reach 11 Fields',
    'starts_at': '2099-06-05T03:30:00Z',
    'ends_at': '2099-06-05T04:30:00Z',
    'timezone': 'America/Phoenix',
    'capacity': 14,
    'confirmed_count': 10,
  };

  test('feed, booking and detail preserve saved arrival terms', () {
    final saved = {
      ...json,
      'check_in_opens_at': '2099-06-05T02:45:00Z',
      'check_in_deadline_at': '2099-06-05T03:25:00Z',
    };
    for (final game in [
      OpenQueueGame.fromJson(saved),
      OpenQueueGame.fromBookingJson(saved),
      OpenQueueMatchDetail.fromJson(saved).game,
    ]) {
      expect(game.checkInOpensAt?.toUtc(), DateTime.utc(2099, 6, 5, 2, 45));
      expect(game.checkInDeadlineAt?.toUtc(), DateTime.utc(2099, 6, 5, 3, 25));
      expect(game.checkInTimeLabel, '7:45 PM');
      expect(game.checkInDeadlineTimeLabel, '8:25 PM');
      expect(game.displayTimeLabel, '7:45 PM');
      expect(game.startTimeLabel, '8:30 PM');
      expect(game.startsAt.toUtc(), DateTime.utc(2099, 6, 5, 3, 30));
    }
  });

  test(
    'legacy upcoming cards use T-30 arrival and inclusive T-10 late cutoff',
    () {
      for (final game in [
        OpenQueueGame.fromJson(json),
        OpenQueueGame.fromBookingJson(json),
      ]) {
        expect(game.checkInOpensAt, isNull);
        expect(game.checkInDeadlineAt, isNull);
        expect(game.checkInAt.toUtc(), DateTime.utc(2099, 6, 5, 3));
        expect(game.checkInDeadline.toUtc(), DateTime.utc(2099, 6, 5, 3, 20));
        expect(game.localCheckInAt, DateTime.utc(2099, 6, 4, 20));
        expect(game.displayTimeLabel, '8:00 PM');
        expect(game.checkInDeadlineTimeLabel, '8:20 PM');
        expect(game.displayCalendarDateLabel, 'THU, 4 JUN');
      }
    },
  );

  test(
    'arrival date crosses midnight without changing booking or match instants',
    () {
      final game = OpenQueueGame.fromJson({
        ...json,
        'starts_at': '2099-06-05T07:10:00Z',
        'ends_at': '2099-06-05T08:10:00Z',
      });
      expect(game.checkInTimeLabel, '11:40 PM');
      expect(game.checkInCalendarDateLabel, 'THU, 4 JUN');
      expect(game.displayCalendarDateLabel, 'THU, 4 JUN');
      expect(game.calendarDateLabel, 'FRI, 5 JUN');
      expect(game.startTimeLabel, '12:10 AM');
      expect(game.displayStartsAt.toUtc(), DateTime.utc(2099, 6, 5, 6, 40));
    },
  );

  test(
    'arrival subtraction uses instants across a venue daylight-saving change',
    () {
      final game = OpenQueueGame.fromJson({
        ...json,
        'starts_at': '2026-03-08T07:10:00Z',
        'ends_at': '2026-03-08T08:10:00Z',
        'timezone': 'America/New_York',
      });
      expect(game.checkInAt.toUtc(), DateTime.utc(2026, 3, 8, 6, 40));
      expect(game.checkInTimeLabel, '1:40 AM');
      expect(game.startTimeLabel, '3:10 AM');
      expect(game.checkInDeadlineTimeLabel, '3:00 AM');
    },
  );

  for (final status in ['LIVE', 'FINAL', 'CANCELLED']) {
    test('$status display keeps actual kickoff', () {
      final game = OpenQueueGame.fromJson({...json, 'status': status});
      expect(game.isUpcoming, isFalse);
      expect(game.displayStartsAt, game.startsAt);
      expect(game.displayTimeLabel, '8:30 PM');
    });
  }

  test('a recorded result is not relabeled as a check-in time', () {
    final game = OpenQueueGame.fromJson({
      ...json,
      'white_score': 2,
      'black_score': 1,
    });
    expect(game.isUpcoming, isFalse);
    expect(game.displayTimeLabel, '8:30 PM');
  });

  testWidgets('cream warning shows the venue late threshold inclusively', (
    tester,
  ) async {
    await _pump(tester, OpenQueueGame.fromJson(json));
    expect(
      find.text(
        'Check in before 8:20 PM. Arriving at or after this time is 1 strike.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.textContaining('8:30', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrival warning fits 320px at 2x text with a saved threshold', (
    tester,
  ) async {
    await _pump(
      tester,
      OpenQueueGame.fromJson({
        ...json,
        'check_in_deadline_at': '2099-06-05T03:19:00Z',
      }),
      width: 320,
      scale: 2,
    );
    expect(find.textContaining('8:19 PM.', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  OpenQueueGame game, {
  double width = 390,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 700);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(body: FieldrushCheckInNotice(game: game)),
    ),
  );
  await tester.pump();
}
