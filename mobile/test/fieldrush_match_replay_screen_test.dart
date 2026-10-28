import 'dart:async';

import 'package:field/src/fixtures/fieldrush_match_replay_screen.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/ui/fieldrush_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  late _ReplayVideoPlatform platform;
  late VideoPlayerPlatform originalPlatform;

  setUp(() {
    originalPlatform = VideoPlayerPlatform.instance;
    platform = _ReplayVideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() => VideoPlayerPlatform.instance = originalPlatform);

  testWidgets(
    'latest reached moment is highlighted and future moments are grey',
    (tester) async {
      await _pumpReplay(
        tester,
        _fixture(),
        initialPosition: const Duration(minutes: 7),
      );

      final goalRow = find.byKey(const ValueKey('replay-moment-my-goal'));
      final blueRow = find.byKey(const ValueKey('replay-moment-blue'));
      expect(tester.widget<Material>(goalRow).color, const Color(0xFFEDF5E3));
      expect(tester.widget<Material>(blueRow).color, Colors.transparent);
      final futureText = tester.widget<Text>(
        find.descendant(of: blueRow, matching: find.textContaining('Jax')),
      );
      expect(futureText.style?.color, const Color(0xFF9B9886));
      expect(
        find.byKey(const ValueKey('replay-marker-my-goal')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('replay-marker-blue')), findsOneWidget);

      final controller = tester
          .widget<FieldrushVideoPlayer>(find.byType(FieldrushVideoPlayer))
          .controller;
      await controller.seekTo(const Duration(minutes: 11));
      await tester.pump();
      expect(tester.widget<Material>(blueRow).color, const Color(0xFFEDF5E3));
      expect(tester.widget<Material>(goalRow).color, Colors.transparent);
      final nextGoal = find.byKey(const ValueKey('replay-moment-my-assist'));
      expect(tester.widget<Material>(nextGoal).color, Colors.transparent);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: nextGoal,
                matching: find.textContaining('Max'),
              ),
            )
            .style
            ?.color,
        const Color(0xFF9B9886),
      );
      expect(tester.takeException(), isNull);
      await _closeReplay(tester);
    },
  );

  testWidgets(
    'moment taps seek exact recording time and fullscreen retains one controller',
    (tester) async {
      await _pumpReplay(
        tester,
        _fixture(),
        initialPosition: const Duration(minutes: 7),
      );
      final controller = tester
          .widget<FieldrushVideoPlayer>(find.byType(FieldrushVideoPlayer))
          .controller;
      await tester.tap(find.byKey(const ValueKey('replay-moment-blue')));
      await tester.pumpAndSettle();

      expect(platform.seeks.last, const Duration(minutes: 8));
      expect(controller.value.position, const Duration(minutes: 8));
      expect(controller.value.isPlaying, isTrue);
      expect(platform.created, 1);
      expect(platform.disposed, 0);
      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('replay-moment-blue')))
            .color,
        const Color(0xFFEDF5E3),
      );

      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('fullscreen-video-player')),
        findsOneWidget,
      );
      final fullscreen = tester.widget<FieldrushVideoPlayer>(
        find.byType(FieldrushVideoPlayer).last,
      );
      expect(fullscreen.controller, same(controller));
      expect(platform.created, 1);
      expect(platform.disposed, 0);
      await tester.tap(find.byKey(const ValueKey('fullscreen-exit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('fullscreen-video-player')),
        findsNothing,
      );
      expect(
        tester
            .widget<FieldrushVideoPlayer>(find.byType(FieldrushVideoPlayer))
            .controller,
        same(controller),
      );
      expect(controller.value.position, const Duration(minutes: 8));
      expect(platform.created, 1);
      expect(platform.disposed, 0);
      expect(tester.takeException(), isNull);
      await _closeReplay(tester);
    },
  );

  testWidgets(
    'personal goals and assists are clear and half-time appears once',
    (tester) async {
      await _pumpReplay(tester, _fixture());
      expect(find.text('You scored · Tyler assist'), findsOneWidget);
      expect(find.text('Max scored · your assist'), findsOneWidget);
      expect(find.text('HALF TIME'), findsOneWidget);
      expect(find.text('Half time 30:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _closeReplay(tester);
    },
  );

  testWidgets(
    'a replay without recorded moments still plays with a useful empty state',
    (tester) async {
      await _pumpReplay(tester, _fixture(empty: true));
      expect(find.text('No match moments were recorded.'), findsOneWidget);
      expect(find.text('THE MATCH'), findsOneWidget);
      expect(find.byKey(const ValueKey('match-replay-seek')), findsOneWidget);
      expect(find.byTooltip('Fullscreen'), findsOneWidget);
      expect(find.text('HALF TIME'), findsNothing);
      expect(platform.created, 1);
      expect(tester.takeException(), isNull);
      await _closeReplay(tester);
    },
  );

  testWidgets('unreviewed final results hide all score assertions', (
    tester,
  ) async {
    await _pumpReplay(tester, _fixture(underReview: true));
    expect(find.textContaining('Result under review'), findsOneWidget);
    expect(find.text('White vs Black'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\d+–\d+')), findsNothing);
    expect(find.byKey(const ValueKey('replay-moment-my-goal')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _closeReplay(tester);
  });

  testWidgets(
    'leaving during stalled initialization releases the native player',
    (tester) async {
      platform.holdInitialization = true;
      await tester.pumpWidget(
        MaterialApp(
          home: FieldrushMatchReplayScreen(
            fixture: _fixture(),
            fixtureRepository: _FixtureRepository(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(platform.created, 1);
      expect(platform.disposed, 0);
      expect(find.byType(FieldrushVideoPlayer), findsNothing);

      // There is deliberately no native initialized event to unblock the await.
      // Back/unmount still must dispose the in-flight player immediately.
      await _closeReplay(tester);
      expect(platform.disposed, 1);
      expect(platform.hasNativePlayer, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retry refreshes the same fixture and rejects a different match before loading its URL',
    (tester) async {
      var refreshCalls = 0;
      const updatedUrl = 'https://example.com/new-replay.m3u8';
      await tester.pumpWidget(
        MaterialApp(
          home: FieldrushMatchReplayScreen(
            fixture: _fixture(replayUrl: null),
            fixtureRepository: _FixtureRepository(),
            refreshFixture: () async {
              refreshCalls++;
              return refreshCalls == 1
                  ? _fixture(
                      id: 'different-match',
                      replayUrl: 'https://example.com/wrong-match.m3u8',
                    )
                  : _fixture(replayUrl: updatedUrl);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      expect(platform.created, 0);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(refreshCalls, 1);
      expect(platform.created, 0);
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(refreshCalls, 2);
      expect(platform.created, 1);
      expect(platform.sourceUrls, [updatedUrl]);
      expect(find.byType(FieldrushVideoPlayer), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(tester.takeException(), isNull);
      await _closeReplay(tester);
    },
  );

  testWidgets(
    'clip editor cancel and system Back return directly to the same paused replay',
    (tester) async {
      const originalPosition = Duration(minutes: 7);
      await _pumpReplay(tester, _fixture(), initialPosition: originalPosition);
      final controller = tester
          .widget<FieldrushVideoPlayer>(find.byType(FieldrushVideoPlayer))
          .controller;

      for (final useSystemBack in [false, true]) {
        await tester.tap(find.byTooltip('Replay options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create match clip'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('custom-clip-video-preview')),
          findsOneWidget,
        );
        expect(
          find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
          findsNothing,
        );
        expect(
          find.byType(FieldrushMatchReplayScreen, skipOffstage: false),
          findsOneWidget,
        );
        expect(platform.created, 1);
        // Moving the shared controller simulates a trim/preview before cancelling.
        await controller.seekTo(const Duration(minutes: 7, seconds: 10));
        await tester.pump();
        if (useSystemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byKey(const ValueKey('custom-clip-cancel')));
        }
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('custom-clip-video-preview')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('fieldrush-match-replay-screen')),
          findsOneWidget,
        );
        expect(
          find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
          findsNothing,
        );
        expect(
          tester
              .widget<FieldrushVideoPlayer>(find.byType(FieldrushVideoPlayer))
              .controller,
          same(controller),
        );
        expect(controller.value.position, originalPosition);
        expect(controller.value.isPlaying, isFalse);
        expect(platform.created, 1);
        expect(platform.disposed, 0);
        expect(tester.takeException(), isNull);
      }
      await _closeReplay(tester);
    },
  );

  testWidgets(
    'direct Clip entry continues to an outcome over the replay and cancelling keeps that replay',
    (tester) async {
      const originalPosition = Duration(minutes: 7);
      await _pumpReplay(
        tester,
        _fixture(),
        initialPosition: originalPosition,
        openClipEditor: true,
      );
      expect(
        find.byKey(const ValueKey('custom-clip-video-preview')),
        findsOneWidget,
      );
      expect(
        find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
        findsNothing,
      );
      final controller = tester
          .widget<FieldrushVideoPlayer>(
            find.byType(FieldrushVideoPlayer, skipOffstage: false).first,
          )
          .controller;
      await tester.ensureVisible(
        find.byKey(const ValueKey('custom-clip-continue')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('custom-clip-continue')));
      await tester.pumpAndSettle();

      expect(find.text('WHAT DO YOU WANT TO DO?'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('custom-clip-video-preview')),
        findsNothing,
      );
      expect(
        find.byType(FieldrushMatchReplayScreen, skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
        findsNothing,
      );
      expect(platform.created, 1);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('WHAT DO YOU WANT TO DO?'), findsNothing);
      expect(
        find.byKey(const ValueKey('fieldrush-match-replay-screen')),
        findsOneWidget,
      );
      expect(
        find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
        findsNothing,
      );
      expect(
        tester
            .widget<FieldrushVideoPlayer>(find.byType(FieldrushVideoPlayer))
            .controller,
        same(controller),
      );
      expect(controller.value.position, originalPosition);
      expect(controller.value.isPlaying, isFalse);
      expect(platform.created, 1);
      expect(platform.disposed, 0);
      expect(tester.takeException(), isNull);
      await _closeReplay(tester);
    },
  );
}

Future<void> _pumpReplay(
  WidgetTester tester,
  Fixture fixture, {
  Duration initialPosition = Duration.zero,
  bool openClipEditor = false,
}) async {
  tester.view.physicalSize = const Size(430, 1450);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: FieldrushMatchReplayScreen(
        fixture: fixture,
        fixtureRepository: _FixtureRepository(),
        profileRepository: _ProfileRepository(),
        initialPosition: initialPosition,
        openClipEditor: openClipEditor,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _closeReplay(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

Fixture _fixture({
  bool empty = false,
  bool underReview = false,
  String id = 'match',
  String? replayUrl = 'https://example.com/full-match.m3u8',
}) {
  final start = DateTime.utc(2026, 10, 19, 18);
  FixtureTimelineEvent event(
    String id,
    String type,
    int matchMinutes,
    int videoMinutes, {
    String? side,
    String? playerId,
    String? playerName,
    String? assistId,
    String? assistName,
  }) => FixtureTimelineEvent(
    id: id,
    fixtureId: 'match',
    eventType: type,
    minute: matchMinutes,
    second: 0,
    createdAt: start.add(Duration(minutes: videoMinutes, seconds: 1)),
    occurredAt: start.add(Duration(minutes: videoMinutes)),
    clanId: side,
    profileId: playerId,
    assistProfileId: assistId,
    player: playerId == null
        ? null
        : FixtureParticipant(id: playerId, displayName: playerName!),
    assist: assistId == null
        ? null
        : FixtureParticipant(id: assistId, displayName: assistName!),
  );
  return Fixture(
    id: id,
    status: FixtureStatus.finalResult,
    homeClanId: 'home',
    awayClanId: 'away',
    venue: 'Diablo',
    day: 'MONDAY',
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: DateTime.utc(2026, 10, 19),
    createdBy: 'referee',
    homeScore: underReview ? 9 : 1,
    awayScore: underReview ? 7 : 2,
    operationalState: underReview
        ? MatchOperationalState.underReview
        : MatchOperationalState.normal,
    homeClan: const FixtureClan(
      id: 'home',
      name: 'White',
      tag: 'WHT',
      emblem: '⚪',
      themeId: 'pitch',
      patternId: 'solid',
      skillRating: 1200,
    ),
    awayClan: const FixtureClan(
      id: 'away',
      name: 'Black',
      tag: 'BLK',
      emblem: '⚫',
      themeId: 'pitch',
      patternId: 'solid',
      skillRating: 1200,
    ),
    clock: const FixtureClock(
      status: 'ENDED',
      startedAt: null,
      accumulatedSeconds: 3600,
      durationSeconds: 3600,
    ),
    broadcast: FixtureBroadcast(
      status: 'REPLAY_READY',
      streamStartedAt: start,
      replayHlsUrl: replayUrl,
    ),
    timeline: empty
        ? []
        : [
            event('kickoff', 'MATCH_STARTED', 0, 2),
            event(
              'my-goal',
              'GOAL',
              3,
              5,
              side: 'home',
              playerId: 'me',
              playerName: 'Ali',
              assistId: 'tyler',
              assistName: 'Tyler',
            ),
            event(
              'blue',
              'BLUE_CARD',
              6,
              8,
              side: 'away',
              playerId: 'jax',
              playerName: 'Jax',
            ),
            event(
              'my-assist',
              'GOAL',
              10,
              12,
              side: 'away',
              playerId: 'max',
              playerName: 'Max',
              assistId: 'me',
              assistName: 'Ali',
            ),
            event('half-pause', 'MATCH_PAUSED', 30, 32),
            event('half-resume', 'MATCH_RESUMED', 30, 37),
            event(
              'late-goal',
              'GOAL',
              43,
              50,
              side: 'away',
              playerId: 'max',
              playerName: 'Max',
            ),
            event('fulltime', 'MATCH_ENDED', 60, 67),
          ],
  );
}

class _FixtureRepository implements FixtureRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProfileRepository implements ProfileRepository {
  @override
  String? get currentUserId => 'me';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReplayVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _positions = {};
  final List<Duration> seeks = [];
  final List<String?> sourceUrls = [];
  bool holdInitialization = false;
  int created = 0;
  int disposed = 0;
  bool get hasNativePlayer => _events.isNotEmpty;

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = created++;
    final events = StreamController<VideoEvent>();
    sourceUrls.add(options.dataSource.uri);
    _events[id] = events;
    _positions[id] = Duration.zero;
    if (!holdInitialization) {
      events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(1920, 1080),
          duration: const Duration(minutes: 70),
        ),
      );
    }
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;
  @override
  Widget buildView(int playerId) => const ColoredBox(color: Color(0xFF202820));
  @override
  Future<void> dispose(int playerId) async {
    disposed++;
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seeks.add(position);
    _positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      _positions[playerId] ?? Duration.zero;
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
}
