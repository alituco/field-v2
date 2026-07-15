import 'dart:async';

import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/profile/goal_clip_downloader.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_clip_screen.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  testWidgets('current profile keeps an inviting empty CLIPS section', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _FakeProfileRepository(profile: _emptyProfile);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ProfileScreen(profileRepository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('CLIPS'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('CLIPS'), findsOneWidget);
    expect(find.text('0 clips'), findsOneWidget);
    expect(find.textContaining('Your goals will live here'), findsOneWidget);
    expect(
      find.textContaining('choose one of your goal chapters'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('playing a ready clip records one view across pause and replay', (
    tester,
  ) async {
    final videoPlatform = _installFakeVideoPlatform();
    final repository = _FakeProfileRepository(
      profile: _emptyProfile,
      recordedViews: 8,
    );

    await _pumpClip(
      tester,
      repository: repository,
      downloader: _FakeGoalClipDownloader(),
    );

    final playIcon = find.byIcon(Icons.play_arrow_rounded);
    expect(playIcon, findsOneWidget);
    final initialPlayCalls = videoPlatform.playCalls;
    final initialPauseCalls = videoPlatform.pauseCalls;

    await tester.tap(playIcon);
    await tester.pump();
    expect(videoPlatform.playCalls, initialPlayCalls + 1);
    expect(repository.recordViewCalls, 1);
    expect(repository.recordedHighlightIds, ['clip-one']);
    expect(find.text('8 views'), findsOneWidget);

    final video = find.byType(AspectRatio).first;
    await tester.tap(video);
    await tester.pump();
    expect(videoPlatform.pauseCalls, initialPauseCalls + 1);

    await tester.tap(video);
    await tester.pump();
    expect(videoPlatform.playCalls, initialPlayCalls + 2);
    expect(repository.recordViewCalls, 1);
    expect(find.text('8 views'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download saves the ready goal through the injected downloader', (
    tester,
  ) async {
    _installFakeVideoPlatform();
    final repository = _FakeProfileRepository(profile: _emptyProfile);
    final downloader = _FakeGoalClipDownloader();

    await _pumpClip(tester, repository: repository, downloader: downloader);

    final downloadButton = find.byKey(const ValueKey('download-goal-clip'));
    await tester.ensureVisible(downloadButton);
    await tester.pump();
    await tester.tap(downloadButton);
    await tester.pumpAndSettle();

    expect(downloader.calls, 1);
    expect(downloader.lastUrl, 'https://cdn.example.com/clip-one.mp4');
    expect(downloader.lastFileName, startsWith('Top_corner_finish_'));
    expect(downloader.lastFileName, endsWith('.mp4'));
    expect(find.text('Goal saved to your Photos.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner can make a profile clip private', (tester) async {
    _installFakeVideoPlatform();
    final repository = _FakeProfileRepository(profile: _emptyProfile);

    await _pumpClip(
      tester,
      repository: repository,
      downloader: _FakeGoalClipDownloader(),
    );

    expect(
      find.byKey(const ValueKey('clip-visibility-selector')),
      findsOneWidget,
    );
    await _scrollClipControlIntoView(
      tester,
      find.byKey(const ValueKey('clip-visibility-selector')),
    );
    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();

    expect(repository.visibilityUpdates, [
      (highlightId: 'clip-one', isPublic: false),
    ]);
    expect(
      find.text('Only you can see this clip on your profile.'),
      findsOneWidget,
    );
    expect(
      find.text('Clip is now private. Only you can see it.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed visibility change keeps the previous clip state', (
    tester,
  ) async {
    _installFakeVideoPlatform();
    final repository = _FakeProfileRepository(
      profile: _emptyProfile,
      visibilityError: StateError('Internal server error'),
    );

    await _pumpClip(
      tester,
      repository: repository,
      downloader: _FakeGoalClipDownloader(),
    );
    await _scrollClipControlIntoView(
      tester,
      find.byKey(const ValueKey('clip-visibility-selector')),
    );
    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();

    expect(repository.visibilityUpdates, [
      (highlightId: 'clip-one', isPublic: false),
    ]);
    expect(
      find.text('Anyone can watch this clip from your profile.'),
      findsOneWidget,
    );
    expect(
      find.text('We could not change this clip’s visibility.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'clip deletion uses the themed confirmation and can be cancelled',
    (tester) async {
      _installFakeVideoPlatform();
      final repository = _FakeProfileRepository(profile: _emptyProfile);

      await _pumpClipOnRoute(tester, repository: repository);

      final deleteButton = find.byKey(const ValueKey('delete-profile-clip'));
      await _scrollClipControlIntoView(tester, deleteButton);
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('field-confirmation-dialog')),
        findsOneWidget,
      );
      expect(find.text('Delete this clip?'), findsOneWidget);
      expect(find.text('This cannot be undone.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('field-confirmation-cancel')));
      await tester.pumpAndSettle();
      expect(repository.deletedHighlightIds, isEmpty);
      expect(find.byKey(const ValueKey('delete-profile-clip')), findsOneWidget);
    },
  );

  testWidgets(
    'confirmed clip deletion removes the clip through the repository',
    (tester) async {
      _installFakeVideoPlatform();
      final repository = _FakeProfileRepository(profile: _emptyProfile);

      await _pumpClipOnRoute(tester, repository: repository);

      final deleteButton = find.byKey(const ValueKey('delete-profile-clip'));
      await _scrollClipControlIntoView(tester, deleteButton);
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('field-confirmation-confirm')),
      );
      await tester.pumpAndSettle();

      expect(repository.deletedHighlightIds, ['clip-one']);
      expect(find.byType(ProfileClipScreen), findsNothing);
      expect(find.byKey(const ValueKey('open-profile-clip')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed clip deletion keeps the clip and restores its action', (
    tester,
  ) async {
    _installFakeVideoPlatform();
    final repository = _FakeProfileRepository(
      profile: _emptyProfile,
      deleteError: StateError('Internal server error'),
    );

    await _pumpClipOnRoute(tester, repository: repository);
    final deleteButton = find.byKey(const ValueKey('delete-profile-clip'));
    await _scrollClipControlIntoView(tester, deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('field-confirmation-confirm')));
    await tester.pumpAndSettle();

    expect(repository.deletedHighlightIds, ['clip-one']);
    expect(find.byType(ProfileClipScreen), findsOneWidget);
    expect(
      find.text('We could not delete this clip. Try again.'),
      findsOneWidget,
    );
    expect(tester.widget<OutlinedButton>(deleteButton).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('other players cannot manage a profile clip', (tester) async {
    _installFakeVideoPlatform();
    final repository = _FakeProfileRepository(profile: _emptyProfile);

    await tester.pumpWidget(
      MaterialApp(
        home: ProfileClipScreen(
          highlight: _readyClip,
          profileRepository: repository,
          canManage: false,
          downloader: _FakeGoalClipDownloader(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      find.byKey(const ValueKey('clip-visibility-selector')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('delete-profile-clip')), findsNothing);
    expect(find.byKey(const ValueKey('download-goal-clip')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an owned goal chapter can be titled and added to the profile', (
    tester,
  ) async {
    _installFakeVideoPlatform();
    final repository = _FakeProfileRepository(profile: _emptyProfile);
    final fixture = _ownedGoalFixture();

    await tester.pumpWidget(
      MaterialApp(
        home: FixtureDetailScreen(
          fixture: fixture,
          fixtureRepository: _FakeFixtureRepository(fixture),
          profileRepository: repository,
          myClanMembership: null,
          initiallyShowWatch: true,
          sourceLabel: 'CLAN',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    final addButton = find.byKey(const ValueKey('add-goal-to-profile'));
    await tester.ensureVisible(addButton);
    await tester.pumpAndSettle();
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    final titleField = find.byKey(const ValueKey('goal-clip-title-field'));
    expect(titleField, findsOneWidget);
    await tester.enterText(titleField, 'Volley into the top corner');
    await tester.tap(find.byKey(const ValueKey('save-goal-clip')));
    await tester.pumpAndSettle();

    expect(repository.createdRequests, hasLength(1));
    final request = repository.createdRequests.single;
    expect(request.sourceType, ProfileHighlightSource.clan);
    expect(request.matchId, 'fixture-one');
    expect(request.eventId, 'goal-one');
    expect(request.title, 'Volley into the top corner');
    expect(find.text('Goal added to your profile.'), findsOneWidget);
    expect(find.text('Added to your profile'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpClip(
  WidgetTester tester, {
  required _FakeProfileRepository repository,
  required GoalClipDownloader downloader,
}) async {
  _configurePhoneViewport(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: ProfileClipScreen(
        highlight: _readyClip,
        profileRepository: repository,
        canManage: true,
        downloader: downloader,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _pumpClipOnRoute(
  WidgetTester tester, {
  required _FakeProfileRepository repository,
}) async {
  _configurePhoneViewport(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open-profile-clip'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => ProfileClipScreen(
                  highlight: _readyClip,
                  profileRepository: repository,
                  canManage: true,
                  downloader: _FakeGoalClipDownloader(),
                ),
              ),
            ),
            child: const Text('Open clip'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-profile-clip')));
  await tester.pumpAndSettle();
}

void _configurePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _scrollClipControlIntoView(
  WidgetTester tester,
  Finder control,
) async {
  await tester.scrollUntilVisible(
    control,
    180,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
}

_FakeVideoPlayerPlatform _installFakeVideoPlatform() {
  final originalPlatform = VideoPlayerPlatform.instance;
  final platform = _FakeVideoPlayerPlatform();
  VideoPlayerPlatform.instance = platform;
  addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);
  return platform;
}

const _readyClip = ProfileHighlight(
  id: 'clip-one',
  title: 'Top corner finish',
  thumbnailUrl: '',
  videoUrl: 'https://cdn.example.com/clip-one/video.m3u8',
  downloadUrl: 'https://cdn.example.com/clip-one.mp4',
  duration: '0:30',
  views: 7,
  status: ProfileHighlightStatus.ready,
  sourceType: ProfileHighlightSource.clan,
  sourceMatchId: 'fixture-one',
  sourceEventId: 'goal-one',
  providerVideoId: 'cloudflare-clip-one',
);

const _emptyProfile = PlayerProfile(
  id: 'player-one',
  displayName: 'Player One',
  username: 'player.one',
  bio: '',
  followingCount: 0,
  fansCount: 0,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: [],
  career: [],
);

Fixture _ownedGoalFixture() {
  final streamStartedAt = DateTime.utc(2026, 7, 14, 16);
  final goalTime = streamStartedAt.add(const Duration(seconds: 12));
  return Fixture(
    id: 'fixture-one',
    status: FixtureStatus.finalResult,
    homeClanId: 'home',
    awayClanId: 'away',
    venue: 'Field',
    day: 'TUESDAY',
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: DateTime.utc(2026, 7, 14),
    homeScore: 1,
    awayScore: 0,
    createdBy: 'owner',
    homeClan: const FixtureClan(
      id: 'home',
      name: 'Home',
      tag: 'HOM',
      emblem: '⚽',
      themeId: 'pitch',
      patternId: 'solid',
      skillRating: 1500,
    ),
    awayClan: const FixtureClan(
      id: 'away',
      name: 'Away',
      tag: 'AWY',
      emblem: '⚽',
      themeId: 'shadow',
      patternId: 'solid',
      skillRating: 1500,
    ),
    broadcast: FixtureBroadcast(
      status: 'REPLAY_READY',
      activeVideoId: 'recording-one',
      replayHlsUrl: 'https://cdn.example.com/full-game.m3u8',
      streamStartedAt: streamStartedAt,
    ),
    timeline: [
      FixtureTimelineEvent(
        id: 'goal-one',
        fixtureId: 'fixture-one',
        eventType: 'GOAL',
        profileId: 'player-one',
        minute: 1,
        second: 12,
        occurredAt: goalTime,
        createdAt: goalTime,
        player: const FixtureParticipant(
          id: 'player-one',
          displayName: 'Player One',
        ),
      ),
    ],
  );
}

class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository({
    required this.profile,
    this.recordedViews = 1,
    this.visibilityError,
    this.deleteError,
  });

  final PlayerProfile profile;
  final int recordedViews;
  final Object? visibilityError;
  final Object? deleteError;
  int recordViewCalls = 0;
  final List<String> recordedHighlightIds = [];
  final List<ProfileGoalClipRequest> createdRequests = [];
  final List<({String highlightId, bool isPublic})> visibilityUpdates = [];
  final List<String> deletedHighlightIds = [];

  @override
  String? get currentUserId => profile.id;

  @override
  Future<PlayerProfile> getCurrentProfile() async => profile;

  @override
  Future<PlayerProfile> getProfile(String profileId) async => profile;

  @override
  Future<int> recordHighlightView(String highlightId) async {
    recordViewCalls += 1;
    recordedHighlightIds.add(highlightId);
    return recordedViews;
  }

  @override
  Future<ProfileHighlight> refreshHighlight(String highlightId) async =>
      _readyClip;

  @override
  Future<ProfileHighlight> updateHighlightVisibility({
    required String highlightId,
    required bool isPublic,
  }) async {
    visibilityUpdates.add((highlightId: highlightId, isPublic: isPublic));
    if (visibilityError case final error?) throw error;
    return _readyClip.copyWith(isPublic: isPublic);
  }

  @override
  Future<void> deleteHighlight(String highlightId) async {
    deletedHighlightIds.add(highlightId);
    if (deleteError case final error?) throw error;
  }

  @override
  Future<ProfileHighlight> createGoalClip(
    ProfileGoalClipRequest request,
  ) async {
    createdRequests.add(request);
    return _readyClip;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFixtureRepository implements FixtureRepository {
  const _FakeFixtureRepository(this.fixture);

  final Fixture fixture;

  @override
  Future<Fixture> getFixture(String fixtureId) async => fixture;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeGoalClipDownloader implements GoalClipDownloader {
  int calls = 0;
  String? lastUrl;
  String? lastFileName;

  @override
  Future<void> downloadToGallery({
    required String url,
    required String fileName,
    ValueChanged<double>? onProgress,
  }) async {
    calls += 1;
    lastUrl = url;
    lastFileName = fileName;
    onProgress?.call(0.4);
    onProgress?.call(1);
  }
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _positions = {};
  int _nextPlayerId = 0;
  int playCalls = 0;
  int pauseCalls = 0;

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
        duration: const Duration(seconds: 30),
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
  Future<Duration> getPosition(int playerId) async =>
      _positions[playerId] ?? Duration.zero;

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
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}
}
