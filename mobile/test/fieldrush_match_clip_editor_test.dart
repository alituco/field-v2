import 'dart:async';

import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/profile/goal_clip_downloader.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  late VideoPlayerPlatform originalPlatform;
  late _VideoPlatform platform;
  late VideoPlayerController video;
  late _Profiles profiles;
  late _Downloader downloader;
  late Future<void> Function() openEditor;

  setUp(() async {
    originalPlatform = VideoPlayerPlatform.instance;
    platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    video = VideoPlayerController.networkUrl(
      Uri.parse('https://example.com/match.m3u8'),
    );
    await video.initialize();
    await video.seekTo(const Duration(seconds: 40));
    profiles = _Profiles();
    downloader = _Downloader();
  });
  tearDown(() async {
    await video.dispose();
    VideoPlayerPlatform.instance = originalPlatform;
  });

  Future<void> launchEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            openEditor = () => openFieldrushMatchClipEditor(
              context,
              controller: video,
              fixture: _fixture,
              profileRepository: profiles,
              goalClipDownloader: downloader,
              sourceLabel: 'SOLO',
            );
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => unawaited(openEditor()),
                  child: const Text('Replay caller'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Replay caller'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('custom-clip-continue')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('custom-clip-continue')));
    await tester.pumpAndSettle();
    expect(video.value.position, const Duration(seconds: 40));
    expect(video.value.isPlaying, isFalse);
  }

  testWidgets(
    'saving blocks dismissal and duplicate flows then returns to caller',
    (tester) async {
      await launchEditor(tester);
      await tester.tap(find.byKey(const ValueKey('custom-clip-save')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('goal-clip-title-field')),
        'Top corner',
      );
      await tester.tap(find.byKey(const ValueKey('save-goal-clip')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('match-clip-processing')),
        findsOneWidget,
      );
      expect(profiles.saved, hasLength(1));
      expect(profiles.saved.single.title, 'Top corner');
      expect(profiles.saved.single.sourceType, ProfileHighlightSource.solo);
      expect(profiles.saved.single.matchId, 'fixture-one');
      expect(profiles.saved.single.startSeconds, 30);
      expect(profiles.saved.single.endSeconds, 60);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('match-clip-processing')),
        findsOneWidget,
      );
      await openEditor();
      await tester.pumpAndSettle();
      expect(profiles.saved, hasLength(1));
      profiles.save.complete(_savedClip);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('match-clip-processing')), findsNothing);
      expect(find.text('Replay caller'), findsOneWidget);
      expect(find.text('Clip added to your profile.'), findsOneWidget);
      expect(
        find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
        findsNothing,
      );
      expect(video.value.position, const Duration(seconds: 40));
      expect(platform.disposed, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'download reports gallery progress and closes only its processing sheet',
    (tester) async {
      await launchEditor(tester);
      await tester.tap(find.byKey(const ValueKey('custom-clip-download')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('match-clip-processing')),
        findsOneWidget,
      );
      expect(profiles.downloads, hasLength(1));
      expect(downloader.urls, ['https://example.com/clip.mp4']);
      downloader.progress!(.4);
      await tester.pump();
      expect(find.text('Saving to Photos 40%'), findsOneWidget);
      downloader.finished.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('match-clip-processing')), findsNothing);
      expect(find.text('Replay caller'), findsOneWidget);
      expect(find.text('Clip saved to your Photos.'), findsOneWidget);
      expect(platform.disposed, 0);
      // A late platform progress callback is harmless after the sheet closes.
      downloader.progress!(1);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed preparation removes progress and keeps caller accessible',
    (tester) async {
      profiles.downloadError = StateError(
        'internal server error: private server details',
      );
      await launchEditor(tester);
      await tester.tap(find.byKey(const ValueKey('custom-clip-download')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('match-clip-processing')), findsNothing);
      expect(find.text('Replay caller'), findsOneWidget);
      expect(
        find.text('We could not create this clip. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('private server details'), findsNothing);
      expect(downloader.urls, isEmpty);
      expect(video.value.position, const Duration(seconds: 40));
      expect(platform.disposed, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final saveToProfile in [true, false]) {
    testWidgets(
      'stalled ${saveToProfile ? 'profile save' : 'gallery save'} times out without retry or late success',
      (tester) async {
        await launchEditor(tester);
        await tester.tap(
          find.byKey(
            ValueKey(
              saveToProfile ? 'custom-clip-save' : 'custom-clip-download',
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (saveToProfile) {
          await tester.tap(find.byKey(const ValueKey('save-goal-clip')));
          await tester.pumpAndSettle();
        }
        await tester.pump(const Duration(minutes: 2, seconds: 59));
        expect(
          find.byKey(const ValueKey('match-clip-processing')),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('match-clip-processing')),
          findsNothing,
        );
        expect(find.text('Replay caller'), findsOneWidget);
        expect(
          find.textContaining(
            saveToProfile
                ? 'Check your profile before trying again'
                : 'Check Photos before trying again',
          ),
          findsOneWidget,
        );
        expect(profiles.saved, hasLength(saveToProfile ? 1 : 0));
        expect(profiles.downloads, hasLength(saveToProfile ? 0 : 1));
        if (saveToProfile) {
          profiles.save.complete(_savedClip);
        } else {
          downloader.progress!(1);
          downloader.finished.complete();
        }
        await tester.pumpAndSettle();
        expect(find.text('Clip added to your profile.'), findsNothing);
        expect(find.text('Clip saved to your Photos.'), findsNothing);
        expect(video.value.position, const Duration(seconds: 40));
        expect(platform.disposed, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

final _fixture = Fixture(
  id: 'fixture-one',
  status: FixtureStatus.finalResult,
  homeClanId: 'home',
  venue: 'Field',
  day: 'MONDAY',
  timeSlot: 'EARLY',
  matchDate: DateTime.utc(2026, 10, 19),
  createdBy: 'owner',
  homeClan: const FixtureClan(
    id: 'home',
    name: 'White',
    tag: 'WHT',
    emblem: '⚽',
    themeId: 'pitch',
    patternId: 'solid',
    skillRating: 1500,
  ),
);

const _savedClip = ProfileHighlight(
  id: 'saved',
  title: 'Top corner',
  thumbnailUrl: '',
  duration: '0:30',
  views: 0,
  status: ProfileHighlightStatus.processing,
);

class _Profiles implements ProfileRepository {
  late final save = Completer<ProfileHighlight>();
  final saved = <ProfileCustomClipRequest>[];
  final downloads = <ProfileCustomClipRequest>[];
  Object? downloadError;

  @override
  Future<ProfileHighlight> createCustomClip(ProfileCustomClipRequest request) {
    saved.add(request);
    return save.future;
  }

  @override
  Future<ProfileClipMedia> getCustomClipDownload(
    ProfileCustomClipRequest request,
  ) async {
    downloads.add(request);
    if (downloadError != null) throw downloadError!;
    return const ProfileClipMedia(
      videoUrl: 'https://example.com/clip.m3u8',
      downloadUrl: 'https://example.com/clip.mp4',
      thumbnailUrl: '',
      duration: '0:30',
      startSeconds: 30,
      endSeconds: 60,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloader implements GoalClipDownloader {
  late final finished = Completer<void>();
  final urls = <String>[];
  ValueChanged<double>? progress;

  @override
  Future<void> downloadToGallery({
    required String url,
    required String fileName,
    ValueChanged<double>? onProgress,
  }) {
    urls.add(url);
    progress = onProgress;
    return finished.future;
  }
}

class _VideoPlatform extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>();
  Duration position = Duration.zero;
  int disposed = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(1920, 1080),
        duration: const Duration(minutes: 2),
      ),
    );
    return 0;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events.stream;
  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);
  @override
  Future<void> dispose(int playerId) async {
    disposed++;
    await events.close();
  }

  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> seekTo(int playerId, Duration value) async {
    position = value;
  }

  @override
  Future<Duration> getPosition(int playerId) async => position;
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
}
