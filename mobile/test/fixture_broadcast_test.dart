import 'package:field/src/fixtures/fixture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('broadcast keeps polling through shutdown and replay processing', () {
    expect(const FixtureBroadcast(status: 'STOPPING').shouldPoll, isTrue);
    expect(const FixtureBroadcast(status: 'PROCESSING').shouldPoll, isTrue);
    expect(const FixtureBroadcast(status: 'REPLAY_READY').shouldPoll, isFalse);
  });

  test('broadcast prefers the finished replay over the live input', () {
    const broadcast = FixtureBroadcast(
      status: 'REPLAY_READY',
      hlsUrl: 'https://example.com/live.m3u8',
      replayHlsUrl: 'https://example.com/replay.m3u8',
    );

    expect(broadcast.playbackUrl, 'https://example.com/replay.m3u8');
  });

  test('fixture keeps live and full-game playback sources separate', () {
    final live = _fixture(
      status: FixtureStatus.live,
      broadcast: const FixtureBroadcast(
        status: 'LIVE',
        hlsUrl: ' https://example.com/live.m3u8 ',
        replayHlsUrl: 'https://example.com/replay.m3u8',
      ),
      videoUrl: 'https://example.com/legacy.m3u8',
    );
    final finalFixture = _fixture(
      status: FixtureStatus.finalResult,
      broadcast: const FixtureBroadcast(
        status: 'REPLAY_READY',
        hlsUrl: 'https://example.com/live.m3u8',
        replayHlsUrl: ' https://example.com/replay.m3u8 ',
      ),
      videoUrl: 'https://example.com/legacy.m3u8',
    );

    expect(live.livePlaybackUrl, 'https://example.com/live.m3u8');
    expect(finalFixture.fullGamePlaybackUrl, 'https://example.com/replay.m3u8');
  });

  test('full-game playback falls back to the legacy fixture video', () {
    final fixture = _fixture(
      status: FixtureStatus.finalResult,
      videoUrl: ' https://example.com/legacy.m3u8 ',
    );

    expect(fixture.fullGamePlaybackUrl, 'https://example.com/legacy.m3u8');
  });

  test('finished match builds ordered goal highlight windows', () {
    final streamStartedAt = DateTime.utc(2026, 7, 11, 18);
    final fixture = _fixture(
      status: FixtureStatus.finalResult,
      broadcast: FixtureBroadcast(
        status: 'REPLAY_READY',
        streamStartedAt: streamStartedAt,
      ),
      timeline: [
        _goal(
          id: 'late',
          minute: 18,
          createdAt: streamStartedAt.add(const Duration(minutes: 18)),
        ),
        _goal(
          id: 'early',
          minute: 1,
          createdAt: streamStartedAt.add(const Duration(seconds: 8)),
        ),
        _goal(
          id: 'correction',
          minute: 4,
          createdAt: streamStartedAt.add(const Duration(hours: 2)),
          note: 'Admin correction',
        ),
      ],
    );

    expect(fixture.highlightMoments, hasLength(2));
    expect(fixture.highlightMoments.first.event.id, 'early');
    expect(fixture.highlightMoments.first.start, Duration.zero);
    expect(fixture.highlightMoments.first.end, const Duration(seconds: 18));
    expect(fixture.highlightMoments.last.event.id, 'late');
    expect(
      fixture.highlightMoments.last.start,
      const Duration(minutes: 17, seconds: 50),
    );
    expect(
      fixture.highlightMoments.last.end,
      const Duration(minutes: 18, seconds: 10),
    );
  });

  test('highlights stay unavailable until the match is final', () {
    final streamStartedAt = DateTime.utc(2026, 7, 11, 18);
    final fixture = _fixture(
      status: FixtureStatus.live,
      broadcast: FixtureBroadcast(
        status: 'LIVE',
        streamStartedAt: streamStartedAt,
      ),
      timeline: [
        _goal(
          id: 'goal',
          minute: 1,
          createdAt: streamStartedAt.add(const Duration(minutes: 1)),
        ),
      ],
    );

    expect(fixture.highlightMoments, isEmpty);
  });

  test('highlights prefer occurrence time and retain paused wall time', () {
    final streamStartedAt = DateTime.utc(2026, 7, 11, 18);
    final fixture = _fixture(
      status: FixtureStatus.finalResult,
      broadcast: FixtureBroadcast(
        status: 'REPLAY_READY',
        streamStartedAt: streamStartedAt,
      ),
      timeline: [
        _goal(
          id: 'after-break',
          minute: 5,
          occurredAt: streamStartedAt.add(const Duration(minutes: 15)),
          createdAt: streamStartedAt.add(
            const Duration(minutes: 15, seconds: 4),
          ),
        ),
      ],
    );

    expect(
      fixture.highlightMoments.single.start,
      const Duration(minutes: 14, seconds: 50),
    );
    expect(
      fixture.highlightMoments.single.end,
      const Duration(minutes: 15, seconds: 10),
    );
  });

  test('final replay duration repairs a delayed live-stream origin', () {
    final incorrectLiveOrigin = DateTime.parse('2026-07-13T00:51:25.848Z');
    final streamStoppedAt = DateTime.parse('2026-07-13T00:55:08.653Z');
    final fixture = _fixture(
      status: FixtureStatus.finalResult,
      broadcast: FixtureBroadcast(
        status: 'REPLAY_READY',
        streamStartedAt: incorrectLiveOrigin,
        streamStoppedAt: streamStoppedAt,
      ),
      timeline: [
        _goal(
          id: 'mint-goal',
          minute: 1,
          occurredAt: DateTime.parse('2026-07-13T00:53:03.443Z'),
          createdAt: DateTime.parse('2026-07-13T00:53:04.727704Z'),
        ),
        _goal(
          id: 'riffa-goal',
          minute: 2,
          occurredAt: DateTime.parse('2026-07-13T00:54:20.868Z'),
          createdAt: DateTime.parse('2026-07-13T00:54:22.148953Z'),
        ),
      ],
    );

    final highlights = fixture.highlightMomentsForReplay(
      const Duration(milliseconds: 262930),
    );

    expect(highlights, hasLength(2));
    expect(highlights.first.start, const Duration(milliseconds: 127720));
    expect(highlights.first.end, const Duration(milliseconds: 147720));
    expect(highlights.last.start, const Duration(milliseconds: 205145));
    expect(highlights.last.end, const Duration(milliseconds: 225145));
  });

  test('clan fixture appearances become balanced formation lineups', () {
    final fixture = Fixture.fromJson({
      'id': 'clan-fixture',
      'status': 'FINAL',
      'home_clan_id': 'home',
      'away_clan_id': 'away',
      'venue': 'Field',
      'day': 'TUESDAY',
      'time_slot': FixtureTimeSlot.early.label,
      'match_date': '2026-07-11',
      'created_by': 'owner',
      'home_clan': _clanJson('home', 'Home', 'HOM'),
      'away_clan': _clanJson('away', 'Away', 'AWY'),
      'fixture_player_appearances': [
        _appearanceJson(
          profileId: 'home-player',
          side: 'HOME',
          rating: 1300,
          played: true,
          isMe: true,
        ),
        _appearanceJson(
          profileId: 'home-dnp',
          side: 'HOME',
          rating: 900,
          played: false,
        ),
        _appearanceJson(
          profileId: 'away-player',
          side: 'AWAY',
          rating: 1200,
          played: true,
        ),
      ],
    });

    expect(fixture.homeLineup, hasLength(2));
    expect(fixture.awayLineup.single.id, 'away-player');
    expect(fixture.homeLineup.first.isMe, isTrue);
    expect(fixture.homeAveragePlayerRating, 1300);
    expect(fixture.awayAveragePlayerRating, 1200);
    expect(fixture.matchAveragePlayerRating, 1250);
    expect(fixture.teamRatingSpread, 100);
  });
}

Map<String, Object> _clanJson(String id, String name, String tag) {
  return {
    'id': id,
    'name': name,
    'tag': tag,
    'emblem': '⚽',
    'theme_id': 'pitch',
    'pattern_id': 'solid',
    'skill_rating': 1500,
  };
}

Map<String, Object> _appearanceJson({
  required String profileId,
  required String side,
  required int rating,
  required bool played,
  bool isMe = false,
}) {
  return {
    'profile_id': profileId,
    'clan_id': side == 'HOME' ? 'home' : 'away',
    'side': side,
    'played': played,
    'rating_at_start': rating,
    'is_me': isMe,
    'player': {
      'id': profileId,
      'display_name': profileId,
      'username': profileId,
      'avatar_url': '',
    },
  };
}

Fixture _fixture({
  required FixtureStatus status,
  FixtureBroadcast? broadcast,
  String? videoUrl,
  List<FixtureTimelineEvent> timeline = const [],
}) {
  return Fixture(
    id: 'fixture',
    status: status,
    homeClanId: 'home',
    venue: 'Field',
    day: 'SATURDAY',
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: DateTime.utc(2026, 7, 11),
    createdBy: 'owner',
    homeClan: const FixtureClan(
      id: 'home',
      name: 'Home',
      tag: 'HOM',
      emblem: '⚽',
      themeId: 'pitch',
      patternId: 'solid',
      skillRating: 1000,
    ),
    broadcast: broadcast,
    videoUrl: videoUrl,
    timeline: timeline,
  );
}

FixtureTimelineEvent _goal({
  required String id,
  required int minute,
  required DateTime createdAt,
  DateTime? occurredAt,
  String? note,
}) {
  return FixtureTimelineEvent(
    id: id,
    fixtureId: 'fixture',
    eventType: 'GOAL',
    minute: minute,
    second: 0,
    createdAt: createdAt,
    occurredAt: occurredAt,
    note: note,
  );
}
