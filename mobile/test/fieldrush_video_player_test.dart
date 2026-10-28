import 'dart:async';

import 'package:field/src/ui/field_loading.dart';
import 'package:field/src/ui/fieldrush_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  late _VideoPlatform platform;
  late VideoPlayerPlatform originalPlatform;

  setUpAll(() async {
    for (final font in ['Outfit', 'PlusJakartaSans']) {
      await (FontLoader(
        font,
      )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  setUp(() {
    originalPlatform = VideoPlayerPlatform.instance;
    platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  tearDown(() {
    VideoPlayerPlatform.instance = originalPlatform;
  });

  Future<VideoPlayerController> controller() async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.com/replay.m3u8'),
    );
    await controller.initialize();
    return controller;
  }

  Future<void> pumpPlayer(
    WidgetTester tester,
    VideoPlayerController controller, {
    bool live = false,
    Duration start = Duration.zero,
    Duration? end,
    VoidCallback? onPlaybackStarted,
    ValueChanged<bool>? onFullscreenChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              height: 220,
              child: FieldrushVideoPlayer(
                controller: controller,
                isLive: live,
                rangeStart: start,
                rangeEnd: end,
                onPlaybackStarted: onPlaybackStarted,
                onFullscreenChanged: onFullscreenChanged,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('scrubbing seeks once on release and resumes inside clip range', (
    tester,
  ) async {
    final video = await controller();
    await video.seekTo(const Duration(seconds: 30));
    await video.play();
    var starts = 0;
    await pumpPlayer(
      tester,
      video,
      start: const Duration(seconds: 20),
      end: const Duration(seconds: 50),
      onPlaybackStarted: () => starts++,
    );
    platform.seeks.clear();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(32000);
    slider.onChanged!(39000);
    slider.onChanged!(45000);
    await tester.pump();
    expect(platform.seeks, isEmpty);
    expect(video.value.isPlaying, isFalse);
    expect(find.text('0:25 / 0:30'), findsOneWidget);
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(45000);
    await tester.pump();
    expect(platform.seeks, [const Duration(seconds: 45)]);
    expect(video.value.isPlaying, isTrue);
    expect(starts, 1);

    await tester.tap(find.byTooltip('Forward 10 seconds'));
    await tester.pump();
    expect(platform.seeks.last, const Duration(seconds: 50));
    await video.pause();
    await tester.pumpWidget(const SizedBox());
    unawaited(video.dispose());
    await tester.pump();
  });

  testWidgets('post controls stay below uncropped video and remain available', (
    tester,
  ) async {
    final video = await controller();
    await video.seekTo(const Duration(seconds: 5));
    await video.play();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              FieldrushVideoPlayer(controller: video, controlsBelowVideo: true),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final surface = tester.getRect(
      find.byKey(const ValueKey('inline-post-video-surface')),
    );
    final controls = tester.getRect(
      find.byKey(const ValueKey('inline-post-video-controls')),
    );
    expect(surface.width / surface.height, closeTo(16 / 9, .001));
    expect(controls.top, surface.bottom);
    expect(find.text('0:05 / 2:00'), findsOneWidget);
    expect(find.text('REPLAY'), findsNothing);
    expect(find.byTooltip('Back 10 seconds'), findsNothing);
    expect(find.byTooltip('Forward 10 seconds'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byTooltip('Pause').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(video.value.isPlaying, isFalse);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(video.value.isPlaying, isTrue);
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    expect(video.value.volume, 0);
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('fullscreen-video-player')),
      findsOneWidget,
    );
    expect(platform.created, 1);
    expect(video.value.isPlaying, isTrue);
    await tester.tap(find.byKey(const ValueKey('fullscreen-exit')));
    await tester.pumpAndSettle();
    expect(platform.disposed, 0);
    expect(find.byTooltip('Pause').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await video.pause();
    await tester.pumpWidget(const SizedBox());
    unawaited(video.dispose());
    await tester.pump();
  });

  testWidgets(
    'post progress seeks once on release and replays the clip range',
    (tester) async {
      final video = await controller();
      await video.seekTo(const Duration(seconds: 30));
      await video.play();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                FieldrushVideoPlayer(
                  controller: video,
                  controlsBelowVideo: true,
                  rangeStart: const Duration(seconds: 20),
                  rangeEnd: const Duration(seconds: 50),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      platform.seeks.clear();
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeStart!(35000);
      slider.onChanged!(45000);
      await tester.pump();
      expect(platform.seeks, isEmpty);
      expect(video.value.isPlaying, isFalse);
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(45000);
      await tester.pump();
      expect(platform.seeks, [const Duration(seconds: 45)]);
      expect(video.value.isPlaying, isTrue);
      expect(find.text('0:25 / 0:30'), findsOneWidget);
      await video.pause();
      await video.seekTo(const Duration(seconds: 50));
      await tester.pump();
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(platform.seeks.last, const Duration(seconds: 20));
      expect(video.value.isPlaying, isTrue);
      await video.pause();
      await tester.pumpWidget(const SizedBox());
      unawaited(video.dispose());
      await tester.pump();
    },
  );

  testWidgets(
    'custom post timeline shares playback and keeps fullscreen seeking',
    (tester) async {
      final video = await controller();
      await video.seekTo(const Duration(seconds: 35));
      await video.play();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: ListView(
                  children: [
                    FieldrushVideoPlayer(
                      controller: video,
                      controlsBelowVideo: true,
                      rangeStart: const Duration(seconds: 20),
                      rangeEnd: const Duration(seconds: 50),
                      showSkipButtons: true,
                      showTimeInControls: false,
                      timelineBuilder: (context, value) => SizedBox(
                        key: const ValueKey('custom-post-timeline'),
                        height: 40,
                        child: Text('At ${value.position.inSeconds}'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final surface = tester.getRect(
        find.byKey(const ValueKey('inline-post-video-surface')),
      );
      final timeline = tester.getRect(
        find.byKey(const ValueKey('custom-post-timeline')),
      );
      final controls = tester.getRect(
        find.byKey(const ValueKey('inline-post-video-controls')),
      );
      expect(timeline.top, surface.bottom);
      expect(controls.top, timeline.bottom);
      expect(find.text('At 35'), findsOneWidget);
      expect(find.text('0:15 / 0:30'), findsNothing);
      expect(find.byType(Slider), findsNothing);
      expect(find.byTooltip('Back 10 seconds'), findsOneWidget);
      expect(find.byTooltip('Forward 10 seconds'), findsOneWidget);

      await tester.tap(find.byTooltip('Back 10 seconds'));
      await tester.pump();
      expect(video.value.position, const Duration(seconds: 25));
      expect(find.text('At 25'), findsOneWidget);
      await tester.tap(find.byTooltip('Back 10 seconds'));
      await tester.pump();
      expect(video.value.position, const Duration(seconds: 20));
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byTooltip('Forward 10 seconds'));
        await tester.pump();
      }
      expect(video.value.position, const Duration(seconds: 50));
      expect(video.value.isPlaying, isTrue);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('fullscreen-video-player')),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('0:30 / 0:30'), findsOneWidget);
      expect(platform.created, 1);
      expect(platform.disposed, 0);
      await tester.tap(find.byKey(const ValueKey('fullscreen-exit')));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      expect(find.text('At 50'), findsOneWidget);
      expect(platform.created, 1);
      expect(platform.disposed, 0);
      expect(video.value.isPlaying, isTrue);
      await video.pause();
      await tester.pumpWidget(const SizedBox());
      unawaited(video.dispose());
      await tester.pump();
    },
  );

  testWidgets('fullscreen preserves controller and playback and restores UI', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final video = await controller();
    await video.seekTo(const Duration(seconds: 25));
    await video.play();
    final fullscreenChanges = <bool>[];
    await pumpPlayer(tester, video, onFullscreenChanged: fullscreenChanges.add);
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('fullscreen-video-player')),
      findsOneWidget,
    );
    expect(platform.created, 1);
    expect(platform.disposed, 0);
    expect(fullscreenChanges, [true]);
    expect(video.value.isPlaying, isTrue);
    expect(video.value.position, const Duration(seconds: 25));
    expect(
      calls.any(
        (call) =>
            call.method == 'SystemChrome.setPreferredOrientations' &&
            (call.arguments as List).contains(
              'DeviceOrientation.landscapeLeft',
            ),
      ),
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('fullscreen-exit')));
    await tester.pumpAndSettle();
    expect(platform.disposed, 0);
    expect(fullscreenChanges, [true, false]);
    expect(video.value.isPlaying, isTrue);
    expect(
      calls
          .where(
            (call) => call.method == 'SystemChrome.setPreferredOrientations',
          )
          .last
          .arguments,
      ['DeviceOrientation.portraitUp'],
    );
    expect(
      calls
          .where((call) => call.method == 'SystemChrome.setEnabledSystemUIMode')
          .last
          .arguments,
      'SystemUiMode.edgeToEdge',
    );
    await video.pause();
    await tester.pumpWidget(const SizedBox());
    unawaited(video.dispose());
    await tester.pump();
  });

  testWidgets('live controls hide, reappear on buffering, and omit seeking', (
    tester,
  ) async {
    final video = await controller();
    await video.play();
    await pumpPlayer(tester, video, live: true);
    expect(find.byType(Slider), findsNothing);
    expect(find.byTooltip('Back 10 seconds'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('inline-video-controls-opacity')),
          )
          .opacity,
      0,
    );
    video.value = video.value.copyWith(isBuffering: true);
    await tester.pump();
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('inline-video-controls-opacity')),
          )
          .opacity,
      1,
    );
    expect(find.bySemanticsLabel('Buffering video'), findsOneWidget);
    expect(find.byType(FieldLoadingIndicator), findsOneWidget);
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    expect(video.value.volume, 0);
    expect(find.byTooltip('Unmute'), findsOneWidget);
    await video.pause();
    await tester.pumpWidget(const SizedBox());
    unawaited(video.dispose());
    await tester.pump();
  });

  testWidgets('uninitialized video shows the accessible activity indicator', (
    tester,
  ) async {
    final video = VideoPlayerController.networkUrl(
      Uri.parse('https://example.com/replay.m3u8'),
    );
    await pumpPlayer(tester, video);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.bySemanticsLabel('Loading video'), findsOneWidget);
    expect(find.byType(FieldLoadingIndicator), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
    unawaited(video.dispose());
    await tester.pump();
  });

  testWidgets('switching controller during scrub never resumes the old video', (
    tester,
  ) async {
    final first = await controller();
    final second = await controller();
    await first.play();
    await pumpPlayer(tester, first);
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(20000);
    await tester.pump();
    await pumpPlayer(tester, second);
    expect(first.value.isPlaying, isFalse);
    expect(second.value.isPlaying, isFalse);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
    expect(platform.disposed, 0);
    await tester.pumpWidget(const SizedBox());
    unawaited(first.dispose());
    unawaited(second.dispose());
    await tester.pump();
  });

  for (final fullscreen in [false, true]) {
    testWidgets(
      '${fullscreen ? 'landscape' : 'compact portrait'} controls fit without overlap',
      (tester) async {
        final size = fullscreen ? const Size(844, 390) : const Size(320, 180);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final video = await controller();
        await video.seekTo(const Duration(seconds: 35));
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('preview'),
                child: fullscreen
                    ? FieldrushVideoPlayer.fullscreen(
                        controller: video,
                        isLive: false,
                        label: 'PHOENIX · MATCH REPLAY',
                        rangeStart: Duration.zero,
                        rangeEnd: null,
                        onTogglePlayback: null,
                        onPlaybackStarted: null,
                      )
                    : FieldrushVideoPlayer(
                        controller: video,
                        label: 'PHOENIX · MATCH REPLAY',
                      ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final play = tester.getRect(find.byTooltip('Play'));
        final slider = tester.getRect(find.byType(Slider));
        expect(play.bottom, lessThanOrEqualTo(slider.top));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        unawaited(video.dispose());
        await tester.pump();
      },
    );
  }
}

class _VideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _positions = {};
  final List<Duration> seeks = [];
  int created = 0;
  int disposed = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = created++;
    final events = StreamController<VideoEvent>();
    _events[id] = events;
    _positions[id] = Duration.zero;
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(1920, 1080),
        duration: const Duration(minutes: 2),
      ),
    );
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
  Future<Duration> getPosition(int playerId) async => _positions[playerId]!;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}
}
