import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('completed fixtures default to highlights and allow full game', (
    tester,
  ) async {
    final streamStartedAt = DateTime.utc(2026, 7, 11, 18);
    final fixture = _fixture(
      status: FixtureStatus.finalResult,
      broadcast: FixtureBroadcast(
        status: 'REPLAY_READY',
        streamStartedAt: streamStartedAt,
      ),
      timeline: [
        FixtureTimelineEvent(
          id: 'goal',
          fixtureId: 'fixture',
          eventType: 'GOAL',
          minute: 8,
          second: 0,
          createdAt: streamStartedAt.add(const Duration(minutes: 8)),
        ),
      ],
    );

    await _pumpDetail(tester, fixture);
    await _scrollToBroadcast(tester, 'WATCH MATCH');

    expect(find.text('Highlights'), findsOneWidget);
    expect(find.text('Full Game'), findsOneWidget);
    expect(find.text('Highlights are not available yet'), findsOneWidget);
    expect(find.text('Full game replay is not available yet'), findsNothing);

    await tester.tap(find.text('Full Game'));
    await tester.pump();

    expect(find.text('Highlights are not available yet'), findsNothing);
    expect(find.text('Full game replay is not available yet'), findsOneWidget);
  });

  testWidgets('live fixtures only show live video and the after-game note', (
    tester,
  ) async {
    final fixture = _fixture(
      status: FixtureStatus.live,
      broadcast: const FixtureBroadcast(status: 'LIVE'),
    );

    await _pumpDetail(tester, fixture);
    await _scrollToBroadcast(tester, 'LIVE STREAM');

    expect(find.text('LIVE STREAM'), findsOneWidget);
    expect(find.text('Highlights'), findsNothing);
    expect(find.text('Full Game'), findsNothing);
    expect(
      find.text('Highlights will be available after the game'),
      findsOneWidget,
    );

    // Removing the live detail screen cancels its periodic refresh timer.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

Future<void> _pumpDetail(WidgetTester tester, Fixture fixture) async {
  await tester.pumpWidget(
    MaterialApp(
      home: FixtureDetailScreen(
        fixture: fixture,
        fixtureRepository: _FakeFixtureRepository(fixture),
        myClanMembership: null,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _scrollToBroadcast(WidgetTester tester, String heading) async {
  await tester.scrollUntilVisible(
    find.text(heading),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

Fixture _fixture({
  required FixtureStatus status,
  FixtureBroadcast? broadcast,
  List<FixtureTimelineEvent> timeline = const [],
}) {
  return Fixture(
    id: 'fixture',
    status: status,
    homeClanId: 'home',
    awayClanId: 'away',
    venue: 'Field',
    day: 'SATURDAY',
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: DateTime.utc(2026, 7, 11),
    homeScore: status == FixtureStatus.finalResult ? 1 : null,
    awayScore: status == FixtureStatus.finalResult ? 0 : null,
    createdBy: 'owner',
    homeClan: _homeClan,
    awayClan: _awayClan,
    broadcast: broadcast,
    timeline: timeline,
  );
}

const _homeClan = FixtureClan(
  id: 'home',
  name: 'Home',
  tag: 'HOM',
  emblem: '⚽',
  themeId: 'pitch',
  patternId: 'solid',
  skillRating: 1500,
);

const _awayClan = FixtureClan(
  id: 'away',
  name: 'Away',
  tag: 'AWY',
  emblem: '⚽',
  themeId: 'ocean',
  patternId: 'solid',
  skillRating: 1500,
);

class _FakeFixtureRepository implements FixtureRepository {
  const _FakeFixtureRepository(this.fixture);

  final Fixture fixture;

  @override
  Future<Fixture> getFixture(String fixtureId) async => fixture;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
