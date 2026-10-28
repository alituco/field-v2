import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/match_replay_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 19, 18);

  test(
    'removed goal retains audit score then reverses only its linked goal',
    () {
      final fixture = _fixture(
        broadcast: FixtureBroadcast(
          status: 'REPLAY_READY',
          streamStartedAt: start,
        ),
        awayScore: 1,
        events: [
          _event(
            'replacement',
            'GOAL',
            seconds: 237,
            side: 'away',
            occurred: start.add(const Duration(seconds: 260)),
            playerId: 'me',
            goalId: 'valid',
          ),
          _event(
            'removed',
            'DISALLOWED_GOAL',
            seconds: 132,
            side: 'away',
            occurred: start.add(const Duration(seconds: 132)),
            playerId: 'me',
            goalId: 'removed-goal',
            isGoalValid: false,
          ),
          _event(
            'correction',
            'CORRECTION',
            seconds: 224,
            side: 'away',
            occurred: start.add(const Duration(seconds: 247)),
            goalId: 'removed-goal',
          ),
          _event(
            'reopen',
            'CORRECTION',
            seconds: 237,
            occurred: start.add(const Duration(seconds: 280)),
            note: 'Reopened',
          ),
          _event(
            'duplicate-correction',
            'CORRECTION',
            seconds: 237,
            occurred: start.add(const Duration(seconds: 290)),
            goalId: 'removed-goal',
          ),
        ],
      );
      final replay = MatchReplayTimeline.fromFixture(
        fixture,
        currentUserId: 'me',
      );
      expect(replay.moments.map((m) => m.awayScore), [1, 0, 1, 1, 1]);
      expect(replay.moments.first.description, 'Goal disallowed');
      expect(replay.moments.first.isGoal, isFalse);
      expect(replay.moments.where((m) => m.isMeGoal).map((m) => m.event.id), [
        'replacement',
      ]);
      expect(fixture.highlightMoments.map((m) => m.event.id), ['replacement']);
    },
  );

  test('linked correction removes own goal credit from the opposite side', () {
    final replay = MatchReplayTimeline.fromFixture(
      _fixture(
        events: [
          _event(
            'own',
            'OWN_GOAL',
            seconds: 1,
            side: 'home',
            goalId: 'own-goal',
          ),
          _event(
            'undo',
            'CORRECTION',
            seconds: 2,
            side: 'home',
            goalId: 'own-goal',
          ),
          _event('ordinary', 'CORRECTION', seconds: 3, side: 'home'),
        ],
      ),
    );
    expect(replay.moments.map((m) => m.awayScore), [1, 0, 0]);
    expect(replay.moments.map((m) => m.homeScore), [0, 0, 0]);
    expect(replay.moments.any((m) => m.isMeGoal || m.isGoal), isFalse);
  });

  test(
    'correction before tied original cannot make a negative or resurrected score',
    () {
      final replay = MatchReplayTimeline.fromFixture(
        _fixture(
          events: [
            _event(
              'undo',
              'CORRECTION',
              seconds: 2,
              side: 'away',
              goalId: 'goal',
            ),
            _event('goal', 'GOAL', seconds: 2, side: 'away', goalId: 'goal'),
          ],
        ),
      );
      expect(replay.moments.map((m) => m.awayScore), [0, 0]);
    },
  );

  test(
    'public event JSON preserves server goal validity and correction identity',
    () {
      final event = FixtureTimelineEvent.fromJson({
        'id': 'removed',
        'event_type': 'DISALLOWED_GOAL',
        'goal_id': 'goal',
        'is_goal_valid': false,
      });
      expect(event.goalId, 'goal');
      expect(event.isGoalValid, isFalse);
      expect(event.isCreditedGoal, isFalse);
    },
  );

  test(
    'wall time includes pre-kickoff recording and prefers actual occurrence',
    () {
      final projection = MatchReplayTimeline.fromFixture(
        _fixture(
          broadcast: FixtureBroadcast(
            status: 'REPLAY_READY',
            streamStartedAt: start,
          ),
          events: [
            _event(
              'goal',
              'GOAL',
              seconds: 7 * 60,
              occurred: start.add(const Duration(minutes: 10)),
              created: start.add(const Duration(minutes: 10, seconds: 5)),
              side: 'home',
            ),
            _event(
              'kickoff',
              'MATCH_STARTED',
              occurred: start.add(const Duration(minutes: 2)),
            ),
          ],
        ),
      );
      expect(projection.moments.map((moment) => moment.event.id), [
        'kickoff',
        'goal',
      ]);
      expect(projection.moments.last.position, const Duration(minutes: 10));
      expect(projection.moments.last.matchSeconds, 7 * 60);
      expect(projection.moments.last.homeScore, 1);
      expect(
        projection.currentMomentAt(const Duration(minutes: 9))?.event.id,
        'kickoff',
      );
    },
  );

  test(
    'reuses finalized highlight alignment after delayed stream notification',
    () {
      final fixture = _fixture(
        broadcast: FixtureBroadcast(
          status: 'REPLAY_READY',
          streamStartedAt: DateTime.parse('2026-07-13T00:51:25.848Z'),
          streamStoppedAt: DateTime.parse('2026-07-13T00:55:08.653Z'),
        ),
        events: [
          _event(
            'goal',
            'GOAL',
            seconds: 60,
            side: 'home',
            occurred: DateTime.parse('2026-07-13T00:53:03.443Z'),
          ),
        ],
      );
      const duration = Duration(milliseconds: 262930);
      final projection = MatchReplayTimeline.fromFixture(
        fixture,
        videoDuration: duration,
      );
      final expected =
          fixture.highlightMomentsForReplay(duration).single.end -
          const Duration(seconds: 20);
      expect(projection.moments.single.position, expected);
      expect(expected, const Duration(milliseconds: 137720));
    },
  );

  test(
    'a stale stop boundary cannot replace a start that recovers more goals',
    () {
      final fixture = _fixture(
        broadcast: FixtureBroadcast(
          status: 'REPLAY_READY',
          streamStartedAt: start,
          streamStoppedAt: start.add(const Duration(hours: 2)),
        ),
        events: [
          _event(
            'goal',
            'GOAL',
            seconds: 60,
            side: 'home',
            occurred: start.add(const Duration(minutes: 1)),
          ),
        ],
      );
      final projection = MatchReplayTimeline.fromFixture(
        fixture,
        videoDuration: const Duration(minutes: 3),
      );
      expect(projection.moments.single.position, const Duration(minutes: 1));
    },
  );

  test('missing timestamps use recorded kickoff and resume clock anchors', () {
    final projection = MatchReplayTimeline.fromFixture(
      _fixture(
        broadcast: FixtureBroadcast(
          status: 'REPLAY_READY',
          streamStartedAt: start,
        ),
        events: [
          _event(
            'kickoff',
            'MATCH_STARTED',
            occurred: start.add(const Duration(minutes: 2)),
          ),
          _event('first-goal', 'GOAL', seconds: 60, side: 'home'),
          _event(
            'pause',
            'MATCH_PAUSED',
            seconds: 1800,
            occurred: start.add(const Duration(minutes: 32)),
          ),
          _event(
            'resume',
            'MATCH_RESUMED',
            seconds: 1800,
            occurred: start.add(const Duration(minutes: 37)),
          ),
          _event('second-goal', 'GOAL', seconds: 1860, side: 'away'),
        ],
      ),
    );
    expect(projection.moments[1].position, const Duration(minutes: 3));
    expect(projection.moments.last.position, const Duration(minutes: 38));
    expect(projection.halftimeMatchSeconds, 1800);
    expect(projection.halftimeVideoPosition, const Duration(minutes: 32));
    expect(projection.moments[2].description, 'Half-time');
    expect(projection.moments[3].description, 'Second half');
  });

  test('known wall timestamp without recording origin is unseekable', () {
    final projection = MatchReplayTimeline.fromFixture(
      _fixture(
        events: [
          _event('known-time', 'BLUE_CARD', seconds: 60, occurred: start),
          _event('clock-only', 'GOAL', seconds: 750, side: 'home'),
        ],
      ),
    );
    expect(projection.moments.first.position, isNull);
    expect(
      projection.moments.last.position,
      const Duration(minutes: 12, seconds: 30),
    );
    expect(projection.currentMomentAt(const Duration(seconds: 60)), isNull);
  });

  test(
    'events outside the recording stay visible but cannot seek or become current',
    () {
      final projection = MatchReplayTimeline.fromFixture(
        _fixture(
          broadcast: FixtureBroadcast(
            status: 'REPLAY_READY',
            streamStartedAt: start,
          ),
          events: [
            _event(
              'before',
              'BLUE_CARD',
              occurred: start.subtract(const Duration(seconds: 1)),
            ),
            _event(
              'inside',
              'GOAL',
              seconds: 60,
              side: 'home',
              occurred: start.add(const Duration(minutes: 1)),
            ),
            _event(
              'after',
              'MATCH_ENDED',
              seconds: 180,
              occurred: start.add(const Duration(minutes: 3)),
            ),
          ],
        ),
        videoDuration: const Duration(minutes: 2),
      );
      expect(projection.moments.first.position, isNull);
      expect(projection.moments.last.position, isNull);
      expect(
        projection.currentMomentAt(const Duration(minutes: 2))?.event.id,
        'inside',
      );
    },
  );

  test(
    'score progression follows recorded goals and attributes personal events',
    () {
      final projection = MatchReplayTimeline.fromFixture(
        _fixture(
          events: [
            _event(
              'own',
              'OWN_GOAL',
              seconds: 240,
              side: 'home',
              playerId: 'me',
            ),
            _event(
              'home-goal',
              'GOAL',
              seconds: 180,
              side: 'home',
              playerId: 'me',
            ),
            _event(
              'correction',
              'GOAL',
              seconds: 300,
              side: 'home',
              note: 'Admin correction',
            ),
            _event(
              'away-goal',
              'GOAL',
              seconds: 120,
              side: 'away',
              assistId: 'me',
            ),
            _event('unknown-side', 'GOAL', seconds: 360),
          ],
        ),
        currentUserId: 'me',
      );
      expect(
        projection.moments.map(
          (moment) => '${moment.homeScore}-${moment.awayScore}',
        ),
        ['0-1', '1-1', '1-2', '1-2', '1-2'],
      );
      expect(projection.moments.first.isMeAssist, isTrue);
      expect(projection.moments[1].isMeGoal, isTrue);
      expect(projection.moments[2].isOwnGoal, isTrue);
      expect(projection.moments[2].isMeGoal, isFalse);
      expect(projection.moments[3].isGoal, isFalse);
      expect(projection.moments[3].description, 'Score correction');
    },
  );

  test(
    'under-review results never manufacture events or backfill final scores',
    () {
      final projection = MatchReplayTimeline.fromFixture(
        _fixture(
          operationalState: MatchOperationalState.underReview,
          homeScore: 9,
          awayScore: 7,
          events: [_event('goal', 'GOAL', seconds: 60, side: 'home')],
        ),
      );
      expect(projection.hasVerifiedScore, isFalse);
      expect(projection.moments, hasLength(1));
      expect(projection.moments.single.homeScore, 1);
      expect(projection.moments.single.awayScore, 0);
    },
  );

  test(
    'half length follows configured clock but no break event is invented',
    () {
      final projection = MatchReplayTimeline.fromFixture(
        _fixture(
          matchDurationSeconds: 2400,
          events: [_event('goal', 'GOAL', seconds: 1300, side: 'home')],
        ),
      );
      expect(projection.halftimeMatchSeconds, 1200);
      expect(projection.halftimeVideoPosition, isNull);
      expect(projection.moments, hasLength(1));
    },
  );

  test(
    'current selection is latest reached and stable for simultaneous events',
    () {
      final projection = MatchReplayTimeline.fromFixture(
        _fixture(
          events: [
            _event('first', 'BLUE_CARD', seconds: 10),
            _event('same-time', 'BLUE_CARD_EXPIRED', seconds: 10),
            _event('future', 'RED_CARD', seconds: 20),
          ],
        ),
      );
      expect(projection.currentMomentAt(const Duration(seconds: 9)), isNull);
      expect(
        projection.currentMomentAt(const Duration(seconds: 10))?.event.id,
        'same-time',
      );
      expect(
        projection.currentMomentAt(const Duration(seconds: 19))?.event.id,
        'same-time',
      );
      expect(
        projection.currentMomentAt(const Duration(seconds: 20))?.event.id,
        'future',
      );
      expect(projection.moments.first.isBlueCard, isTrue);
      expect(projection.moments[1].isBlueCard, isFalse);
      expect(projection.moments.last.isRedCard, isTrue);
      expect(projection.moments.map((moment) => moment.description), [
        'Blue card',
        'Returned',
        'Red card',
      ]);
    },
  );

  test(
    'all published event kinds survive without synthetic player identities',
    () {
      final types = [
        'MATCH_STARTED',
        'YELLOW_CARD',
        'SUBSTITUTION',
        'PLAYER_RETURNED',
        'MATCH_STOPPED',
        'CORRECTION',
        'FORFEIT_PROVISIONAL',
        'FORFEIT_CONFIRMED',
        'FORFEIT_OVERTURNED',
        'MATCH_ENDED',
      ];
      final projection = MatchReplayTimeline.fromFixture(
        _fixture(
          events: [
            for (var index = 0; index < types.length; index++)
              _event('event-$index', types[index], seconds: index),
          ],
        ),
      );
      expect(projection.moments, hasLength(types.length));
      expect(
        projection.moments.any(
          (moment) => moment.description.contains('Unknown'),
        ),
        isFalse,
      );
      expect(projection.moments[1].isYellowCard, isTrue);
    },
  );
}

Fixture _fixture({
  List<FixtureTimelineEvent> events = const [],
  FixtureBroadcast? broadcast,
  int matchDurationSeconds = 3600,
  MatchOperationalState operationalState = MatchOperationalState.normal,
  int homeScore = 0,
  int awayScore = 0,
}) => Fixture(
  id: 'match',
  status: FixtureStatus.finalResult,
  homeClanId: 'home',
  awayClanId: 'away',
  venue: 'Pitch',
  day: 'MONDAY',
  timeSlot: FixtureTimeSlot.early.label,
  matchDate: DateTime.utc(2026, 10, 19),
  createdBy: 'referee',
  homeScore: homeScore,
  awayScore: awayScore,
  homeClan: const FixtureClan(
    id: 'home',
    name: 'Home',
    tag: 'HOM',
    emblem: '⚽',
    themeId: 'pitch',
    patternId: 'solid',
    skillRating: 1000,
  ),
  awayClan: const FixtureClan(
    id: 'away',
    name: 'Away',
    tag: 'AWY',
    emblem: '⚽',
    themeId: 'pitch',
    patternId: 'solid',
    skillRating: 1000,
  ),
  clock: FixtureClock(
    status: 'ENDED',
    startedAt: null,
    accumulatedSeconds: matchDurationSeconds,
    durationSeconds: matchDurationSeconds,
  ),
  broadcast: broadcast,
  timeline: events,
  operationalState: operationalState,
);

FixtureTimelineEvent _event(
  String id,
  String type, {
  int seconds = 0,
  String? side,
  DateTime? occurred,
  DateTime? created,
  String? playerId,
  String? assistId,
  String? note,
  String? goalId,
  bool? isGoalValid,
}) => FixtureTimelineEvent(
  id: id,
  fixtureId: 'match',
  eventType: type,
  minute: seconds ~/ 60,
  second: seconds % 60,
  createdAt: created,
  occurredAt: occurred,
  clanId: side,
  profileId: playerId,
  assistProfileId: assistId,
  note: note,
  goalId: goalId,
  isGoalValid: isGoalValid,
);
