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
    expect(fixture.highlightMoments.first.end, const Duration(seconds: 23));
    expect(fixture.highlightMoments.last.event.id, 'late');
    expect(
      fixture.highlightMoments.last.start,
      const Duration(minutes: 17, seconds: 45),
    );
    expect(
      fixture.highlightMoments.last.end,
      const Duration(minutes: 18, seconds: 15),
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
  String? note,
}) {
  return FixtureTimelineEvent(
    id: id,
    fixtureId: 'fixture',
    eventType: 'GOAL',
    minute: minute,
    second: 0,
    createdAt: createdAt,
    note: note,
  );
}
