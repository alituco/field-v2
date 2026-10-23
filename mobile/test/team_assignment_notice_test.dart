import 'dart:ui' show SemanticsAction;

import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/team_assignment_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cutoff = DateTime.utc(2026, 10, 23, 0, 30);

  testWidgets('countdown uses the saved deadline and venue-local clock', (
    tester,
  ) async {
    var now = cutoff.subtract(const Duration(hours: 2, minutes: 14));
    await _pump(
      tester,
      FieldrushTeamAssignmentNotice(
        game: _game(cutoff: cutoff),
        now: () => now,
      ),
    );
    expect(find.text('2:14:00'), findsOneWidget);
    expect(find.text('UNTIL ASSIGNED'), findsOneWidget);
    expect(
      find.text("You'll be assigned White or Black at 5:30 PM"),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('team-assignment-ticket')))
          .height,
      66,
    );
    for (final side in ['white', 'black']) {
      final half = tester.getSize(
        find.byKey(ValueKey('team-assignment-$side-half')),
      );
      expect(half.height, 66);
      expect(half.width, 195);
    }
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2:13:59'), findsOneWidget);
  });

  testWidgets(
    'deadline refresh fires once and never pretends teams are assigned',
    (tester) async {
      var now = cutoff.subtract(const Duration(seconds: 1));
      var refreshes = 0;
      final game = _game(cutoff: cutoff);
      Widget notice() => FieldrushTeamAssignmentNotice(
        game: game,
        team: openQueueWhiteTeamId,
        now: () => now,
        onAssignmentDue: () => refreshes++,
      );
      await _pump(tester, notice());
      expect(find.text('0:00:01'), findsOneWidget);
      now = cutoff;
      await tester.pump(const Duration(seconds: 1));
      expect(refreshes, 1);
      expect(find.text('ASSIGNMENT UPDATING'), findsOneWidget);
      expect(find.text("YOU'RE ON"), findsNothing);
      expect(find.text('0:00:00'), findsNothing);
      await tester.pump(const Duration(hours: 1));
      await _pump(tester, notice());
      expect(refreshes, 1);
      expect(find.text('ASSIGNMENT UPDATING'), findsOneWidget);
    },
  );

  testWidgets(
    'already expired deadline refreshes once without a negative clock',
    (tester) async {
      var refreshes = 0;
      await _pump(
        tester,
        FieldrushTeamAssignmentNotice(
          game: _game(cutoff: cutoff),
          now: () => cutoff.add(const Duration(hours: 1)),
          onAssignmentDue: () => refreshes++,
        ),
      );
      expect(refreshes, 1);
      expect(find.text('ASSIGNMENT UPDATING'), findsOneWidget);
      expect(find.text('UNTIL ASSIGNED'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(refreshes, 1);
    },
  );

  testWidgets('missing cutoff has no invented countdown or refresh', (
    tester,
  ) async {
    var refreshes = 0;
    await _pump(
      tester,
      FieldrushTeamAssignmentNotice(
        game: _game(),
        now: () => cutoff,
        onAssignmentDue: () => refreshes++,
      ),
    );
    expect(find.text('TEAMS PENDING'), findsOneWidget);
    expect(find.text('UNTIL ASSIGNED'), findsNothing);
    await tester.pump(const Duration(hours: 1));
    expect(refreshes, 0);
  });

  testWidgets('expired assignment waits honestly when the minimum is not met', (
    tester,
  ) async {
    await _pump(
      tester,
      FieldrushTeamAssignmentNotice(
        game: _game(cutoff: cutoff, confirmed: 8),
        now: () => cutoff,
      ),
    );
    expect(find.text('WAITING FOR PLAYERS'), findsOneWidget);
    expect(find.text('ASSIGNMENT UPDATING'), findsNothing);
    expect(find.text("YOU'RE ON"), findsNothing);
  });

  for (final team in [openQueueWhiteTeamId, openQueueBlackTeamId]) {
    testWidgets('server-assigned $team opens its team with hidden ratings', (
      tester,
    ) async {
      var opened = 0;
      var refreshes = 0;
      final game = _game(cutoff: DateTime.utc(2000), assigned: true);
      await _pump(
        tester,
        FieldrushTeamAssignmentNotice(
          game: game,
          team: team,
          onSeeTeam: () => opened++,
          onAssignmentDue: () => refreshes++,
        ),
      );
      expect(find.text("YOU'RE ON"), findsOneWidget);
      expect(find.text(team), findsOneWidget);
      expect(find.text('See your team ›'), findsOneWidget);
      expect(find.text('UNTIL ASSIGNED'), findsNothing);
      expect(game.whiteAverageSr, isNull);
      expect(game.blackAverageSr, isNull);
      await tester.tap(find.byKey(const ValueKey('team-assignment-see-team')));
      expect(opened, 1);
      expect(refreshes, 0);
    });
  }

  testWidgets('a stale side cannot activate the team action', (tester) async {
    var opened = 0;
    await _pump(
      tester,
      FieldrushTeamAssignmentNotice(
        game: _game(cutoff: cutoff),
        team: openQueueWhiteTeamId,
        now: () => cutoff.subtract(const Duration(hours: 1)),
        onSeeTeam: () => opened++,
      ),
    );
    expect(find.text("YOU'RE ON"), findsNothing);
    expect(find.text('See your team ›'), findsNothing);
    await tester.tap(find.text('WHITE'));
    expect(opened, 0);
  });

  testWidgets('assigned team is actionable with a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var opened = 0;
      await _pump(
        tester,
        FieldrushTeamAssignmentNotice(
          game: _game(cutoff: DateTime.utc(2000), assigned: true),
          team: openQueueWhiteTeamId,
          onSeeTeam: () => opened++,
        ),
      );
      final node = tester.getSemantics(
        find.bySemanticsLabel("You're on White. See your team"),
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      expect(opened, 1);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('an unknown side never guesses the assigned player team', (
    tester,
  ) async {
    await _pump(
      tester,
      FieldrushTeamAssignmentNotice(
        game: _game(cutoff: DateTime.utc(2000), assigned: true),
        team: 'UNKNOWN',
        onSeeTeam: () => fail('The player has no confirmed side'),
      ),
    );
    expect(find.text('ASSIGNMENT UPDATING'), findsOneWidget);
    expect(find.text('See your team ›'), findsNothing);
  });

  testWidgets('unmount cancels the local clock and due callback', (
    tester,
  ) async {
    var now = cutoff.subtract(const Duration(seconds: 1));
    var refreshes = 0;
    await _pump(
      tester,
      FieldrushTeamAssignmentNotice(
        game: _game(cutoff: cutoff),
        now: () => now,
        onAssignmentDue: () => refreshes++,
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    now = cutoff;
    await tester.pump(const Duration(seconds: 5));
    expect(refreshes, 0);
    expect(tester.takeException(), isNull);
  });

  for (final team in [null, openQueueWhiteTeamId, openQueueBlackTeamId]) {
    testWidgets('notice fits at 320px and 2x text for ${team ?? 'pending'}', (
      tester,
    ) async {
      await _pump(
        tester,
        FieldrushTeamAssignmentNotice(
          game: _game(cutoff: DateTime.utc(2000), assigned: team != null),
          team: team,
          onSeeTeam: () {},
        ),
        width: 320,
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      if (team != null) {
        expect(
          tester
              .getSize(find.byKey(const ValueKey('team-assignment-see-team')))
              .width,
          tester
              .getSize(find.byKey(const ValueKey('team-assignment-ticket')))
              .width,
        );
      }
      expect(
        find.byKey(const ValueKey('team-assignment-ticket')),
        findsOneWidget,
      );
    });
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pump();
}

OpenQueueGame _game({
  DateTime? cutoff,
  bool assigned = false,
  int confirmed = 10,
}) => OpenQueueGame(
  id: 'game',
  status: 'OPEN',
  venue: 'Reach 11 Fields',
  startsAt: DateTime.utc(2099, 1, 1),
  endsAt: DateTime.utc(2099, 1, 1, 1),
  timezone: 'America/Phoenix',
  priceFils: 13000,
  ageLabel: '18+',
  capacity: 14,
  minimumPlayers: 10,
  participationRulesVersion: 's0-configurable-v1',
  confirmedCount: confirmed,
  spots: const {},
  teamAssignmentAt: cutoff,
  teamsAssignedAt: assigned ? DateTime.utc(2000) : null,
);
