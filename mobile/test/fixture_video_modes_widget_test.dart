import 'dart:async';

import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  testWidgets('match scoreboard owns the full top edge', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpDetail(tester, _fixture(status: FixtureStatus.finalResult));

    final scoreboardFinder = find.byKey(const ValueKey('fixture-scoreboard'));
    final scoreboard = tester.widget<Container>(scoreboardFinder);
    final decoration = scoreboard.decoration! as BoxDecoration;
    final radius = decoration.borderRadius!.resolve(TextDirection.ltr);

    expect(tester.getTopLeft(scoreboardFinder), Offset.zero);
    expect(tester.getSize(scoreboardFinder).width, 390);
    expect(radius.topLeft, Radius.zero);
    expect(radius.topRight, Radius.zero);
    expect(radius.bottomLeft, const Radius.circular(26));
    expect(radius.bottomRight, const Radius.circular(26));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('fixture-detail-header'))).dy,
      0,
    );
    expect(find.text('MATCH DETAILS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('highlight keeps its reaction window after the visible goal', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final originalPlatform = VideoPlayerPlatform.instance;
    final videoPlatform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = videoPlatform;
    addTearDown(() {
      VideoPlayerPlatform.instance = originalPlatform;
    });

    final playbackStartedAt = DateTime.utc(2026, 7, 11, 18);
    final fixture = _fixture(
      status: FixtureStatus.finalResult,
      broadcast: FixtureBroadcast(
        status: 'REPLAY_READY',
        streamStartedAt: playbackStartedAt,
        streamStoppedAt: playbackStartedAt.add(const Duration(hours: 1)),
        replayHlsUrl: 'https://example.com/replay.m3u8',
      ),
      timeline: [
        _goal(
          id: 'goal',
          minute: 8,
          occurredAt: playbackStartedAt.add(const Duration(minutes: 8)),
        ),
      ],
    );

    await _pumpDetail(tester, fixture);
    await _scrollToBroadcast(tester, 'WATCH MATCH');
    await tester.pumpAndSettle();

    final restart = find.byKey(const ValueKey('highlight-restart'));
    await tester.ensureVisible(restart);
    await tester.tap(restart);
    await tester.pump();
    expect(videoPlatform.playCalls, 1);
    final pausesBeforeOldCutoff = videoPlatform.pauseCalls;

    // The old cutoff was 8:10. Playback must continue through that point.
    videoPlatform.setPosition(const Duration(minutes: 8, seconds: 10));
    await tester.pump(const Duration(milliseconds: 600));
    expect(videoPlatform.pauseCalls, pausesBeforeOldCutoff);

    // The compensated tail ends at 8:20 and only pauses there.
    videoPlatform.setPosition(const Duration(minutes: 8, seconds: 20));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(videoPlatform.pauseCalls, pausesBeforeOldCutoff + 1);
    expect(
      videoPlatform.seekPositions.last,
      const Duration(minutes: 8, seconds: 20),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'finished video has goal navigation and a draggable full timeline',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final originalPlatform = VideoPlayerPlatform.instance;
      final videoPlatform = _FakeVideoPlayerPlatform();
      VideoPlayerPlatform.instance = videoPlatform;
      addTearDown(() {
        VideoPlayerPlatform.instance = originalPlatform;
      });

      final playbackStartedAt = DateTime.utc(2026, 7, 11, 18);
      final fixture = _fixture(
        status: FixtureStatus.finalResult,
        broadcast: FixtureBroadcast(
          status: 'REPLAY_READY',
          streamStartedAt: playbackStartedAt.add(const Duration(seconds: 50)),
          streamStoppedAt: playbackStartedAt.add(const Duration(hours: 1)),
          replayHlsUrl: 'https://example.com/replay.m3u8',
        ),
        timeline: [
          _goal(
            id: 'first',
            minute: 8,
            occurredAt: playbackStartedAt.add(const Duration(minutes: 8)),
          ),
          _goal(
            id: 'second',
            minute: 18,
            occurredAt: playbackStartedAt.add(const Duration(minutes: 18)),
          ),
        ],
      );

      await _pumpDetail(tester, fixture);
      await _scrollToBroadcast(tester, 'WATCH MATCH');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.text("Goal 1 · 8'"), findsOneWidget);
      expect(find.text("Goal 2 · 18'"), findsOneWidget);
      expect(find.byKey(const ValueKey('highlight-restart')), findsOneWidget);
      expect(
        videoPlatform.seekPositions.last,
        const Duration(minutes: 7, seconds: 50),
      );

      final secondGoal = find.byKey(const ValueKey('highlight-goal-1'));
      await tester.ensureVisible(secondGoal);
      await tester.pump();
      await tester.tap(secondGoal);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);

      expect(
        videoPlatform.seekPositions.last,
        const Duration(minutes: 17, seconds: 50),
      );
      expect(videoPlatform.playCalls, greaterThan(0));

      final restart = find.byKey(const ValueKey('highlight-restart'));
      await tester.ensureVisible(restart);
      await tester.pump();
      final playsBeforeRestart = videoPlatform.playCalls;
      await tester.tap(restart);
      await tester.pump();
      await tester.pump();
      expect(
        videoPlatform.seekPositions.last,
        const Duration(minutes: 17, seconds: 50),
      );
      expect(videoPlatform.playCalls, greaterThan(playsBeforeRestart));

      await tester.tap(find.text('Previous'));
      await tester.pump();
      await tester.pump();
      expect(
        videoPlatform.seekPositions.last,
        const Duration(minutes: 7, seconds: 50),
      );

      await tester.tap(find.text('Next'));
      await tester.pump();
      await tester.pump();
      expect(
        videoPlatform.seekPositions.last,
        const Duration(minutes: 17, seconds: 50),
      );

      final fullscreen = find.byTooltip('Fullscreen');
      await tester.ensureVisible(fullscreen);
      await tester.pump();
      await tester.tap(fullscreen);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.byKey(const ValueKey('fullscreen-controls-opacity')),
        findsOneWidget,
      );
      expect(find.text('17:50 / 1:00:00'), findsOneWidget);
      expect(find.byKey(const ValueKey('full-game-seek')), findsNothing);
      expect(_fullscreenControlsOpacity(tester), 1);

      await tester.pump(const Duration(seconds: 3, milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 180));
      expect(_fullscreenControlsOpacity(tester), 0);

      final tapTarget = find.byKey(
        const ValueKey('fullscreen-video-tap-target'),
      );
      final tapBounds = tester.getRect(tapTarget);
      await tester.tapAt(Offset(tapBounds.right - 24, tapBounds.center.dy));
      await tester.pump(const Duration(milliseconds: 180));
      expect(_fullscreenControlsOpacity(tester), 1);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, 220));
      await tester.pump();
      await tester.tap(find.text('Full Game'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.byKey(const ValueKey('full-game-seek')), findsOneWidget);
      expect(find.text('0:00 / 1:00:00'), findsOneWidget);

      final forwardTen = find.byTooltip('Forward 10 seconds');
      await tester.ensureVisible(forwardTen);
      await tester.pump();
      await tester.tap(forwardTen);
      await tester.pump();
      expect(videoPlatform.seekPositions.last, const Duration(seconds: 10));

      final slider = find.byKey(const ValueKey('full-game-seek'));
      await tester.ensureVisible(slider);
      await tester.pump();
      final sliderBounds = tester.getRect(slider);
      final gesture = await tester.startGesture(
        Offset(sliderBounds.left + 20, sliderBounds.center.dy),
      );
      await gesture.moveTo(
        Offset(sliderBounds.right - 20, sliderBounds.center.dy),
      );
      await gesture.up();
      await tester.pump();

      expect(
        videoPlatform.seekPositions.last,
        greaterThan(const Duration(minutes: 50)),
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
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

double _fullscreenControlsOpacity(WidgetTester tester) {
  return tester
      .widget<AnimatedOpacity>(
        find.byKey(const ValueKey('fullscreen-controls-opacity')),
      )
      .opacity;
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

FixtureTimelineEvent _goal({
  required String id,
  required int minute,
  required DateTime occurredAt,
}) {
  return FixtureTimelineEvent(
    id: id,
    fixtureId: 'fixture',
    eventType: 'GOAL',
    minute: minute,
    second: 0,
    occurredAt: occurredAt,
    createdAt: occurredAt,
  );
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _positions = {};
  final List<Duration> seekPositions = [];
  int _nextPlayerId = 0;
  int playCalls = 0;
  int pauseCalls = 0;

  void setPosition(Duration position) {
    for (final playerId in _positions.keys) {
      _positions[playerId] = position;
    }
  }

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    final events = StreamController<VideoEvent>();
    _events[playerId] = events;
    _positions[playerId] = Duration.zero;
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(1920, 1080),
        duration: const Duration(hours: 1),
      ),
    );
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Widget buildView(int playerId) => const SizedBox.expand();

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
    _positions.remove(playerId);
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    return _positions[playerId] ?? Duration.zero;
  }

  @override
  Future<void> pause(int playerId) async {
    pauseCalls += 1;
    _events[playerId]?.add(
      VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: false,
      ),
    );
  }

  @override
  Future<void> play(int playerId) async {
    playCalls += 1;
    _events[playerId]?.add(
      VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: true,
      ),
    );
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    _positions[playerId] = position;
    seekPositions.add(position);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}
}
