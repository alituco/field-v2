import 'dart:async';

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/profile/goal_clip_downloader.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_clip_screen.dart';
import 'package:field/src/profile/profile_clips_screen.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:field/src/ui/fieldrush_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  testWidgets(
    'clip gallery opens the cream watch page with video and actions',
    (tester) async {
      _configurePhoneViewport(tester);
      final video = _installFakeVideoPlatform();
      final profile = _emptyProfile.copyWith(highlights: [_readyClip]);
      final repository = _FakeProfileRepository(profile: profile);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileClipsScreen(
            profile: profile,
            repository: repository,
            canManage: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      expect(find.text('7 views'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('profile-grid-clip-clip-one')))
            .width,
        greaterThan(180),
      );
      expect(video.createdPlayers, 0);
      expect(repository.recordViewCalls, 0);
      await tester.tap(
        find.byKey(const ValueKey('profile-grid-clip-clip-one')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProfileClipScreen), findsOneWidget);
      expect(find.text('@player.one'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Fullscreen'), findsOneWidget);
      expect(video.createdPlayers, 1);
      expect(repository.recordViewCalls, 1);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('profile-clip-post-media')))
            .height,
        closeTo(390 * 9 / 16 + 48, 1),
      );
      expect(find.text('Private'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-clips-gallery')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'public clip gallery excludes private clips; owner gallery includes them',
    (tester) async {
      final profile = _emptyProfile.copyWith(
        highlights: [_readyClip.copyWith(isPublic: false)],
      );
      final repository = _FakeProfileRepository(profile: profile);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileClipsScreen(
            profile: profile,
            repository: repository,
            canManage: false,
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('profile-grid-clip-clip-one')),
        findsNothing,
      );
      expect(find.text('No clips yet.'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileClipsScreen(
            profile: profile,
            repository: repository,
            canManage: true,
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('profile-grid-clip-clip-one')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Up next pauses this clip, opens its creator, and removes watched recommendations',
    (tester) async {
      _installFakeVideoPlatform();
      const nextClip = ProfileHighlight(
        id: 'next-clip',
        title: 'Another finish',
        thumbnailUrl: '',
        duration: '0:30',
        views: 15,
        videoUrl: 'https://cdn.example.com/next.m3u8',
      );
      final repository = _FakeProfileRepository(
        profile: _emptyProfile,
        recommendations: const [
          ProfileClipRecommendation(
            highlight: nextClip,
            profileId: 'another-player',
            username: 'next.player',
            displayName: 'Next Player',
          ),
        ],
      );
      await _pumpClip(
        tester,
        repository: repository,
        downloader: _FakeGoalClipDownloader(),
      );
      expect(find.text('UP NEXT'), findsOneWidget);
      final controller = tester
          .widget<FieldrushVideoPlayer>(find.byType(FieldrushVideoPlayer))
          .controller;
      final next = find.byKey(const ValueKey('up-next-clip-next-clip'));
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(controller.value.isPlaying, isFalse);
      expect(find.text('@next.player'), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-clip-options')), findsNothing);
      expect(repository.recordedHighlightIds, ['clip-one', 'next-clip']);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(next, findsNothing);
      expect(controller.value.isPlaying, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
    await tester.tap(find.text('View all clips'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileClipsScreen), findsOneWidget);
    expect(find.text('No clips yet.'), findsOneWidget);
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

    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(repository.recordViewCalls, 1);
    final initialPlayCalls = videoPlatform.playCalls;
    final initialPauseCalls = videoPlatform.pauseCalls;

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(videoPlatform.playCalls, initialPlayCalls + 1);
    expect(repository.recordViewCalls, 1);
    expect(repository.recordedHighlightIds, ['clip-one']);
    expect(find.text('8 views'), findsOneWidget);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(videoPlatform.pauseCalls, initialPauseCalls + 2);

    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(videoPlatform.playCalls, initialPlayCalls + 2);
    expect(repository.recordViewCalls, 1);
    expect(find.text('8 views'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a profile clip keeps its player and view count in fullscreen', (
    tester,
  ) async {
    final videoPlatform = _installFakeVideoPlatform();
    final repository = _FakeProfileRepository(profile: _emptyProfile);
    await _pumpClip(
      tester,
      repository: repository,
      downloader: _FakeGoalClipDownloader(),
    );

    final controller = tester
        .widget<FieldrushVideoPlayer>(find.byType(FieldrushVideoPlayer))
        .controller;
    await controller.seekTo(const Duration(seconds: 12));
    await tester.pump();
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pumpAndSettle();

    expect(videoPlatform.createdPlayers, 1);
    expect(controller.value.position, const Duration(seconds: 12));
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(repository.recordViewCalls, 1);

    await tester.tap(find.byKey(const ValueKey('fullscreen-exit')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileClipScreen), findsOneWidget);
    expect(
      tester
          .widget<FieldrushVideoPlayer>(find.byType(FieldrushVideoPlayer))
          .controller,
      same(controller),
    );
    expect(controller.value.isPlaying, isTrue);
    expect(repository.recordViewCalls, 1);
    expect(videoPlatform.createdPlayers, 1);
    await controller.pause();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('download saves the ready goal through the injected downloader', (
    tester,
  ) async {
    _installFakeVideoPlatform();
    final repository = _FakeProfileRepository(profile: _emptyProfile);
    final downloader = _FakeGoalClipDownloader();

    await _pumpClip(tester, repository: repository, downloader: downloader);

    final clipScreen = find.byKey(
      const ValueKey('fieldrush-profile-clip-screen'),
    );
    expect(
      tester.widget<Scaffold>(clipScreen).backgroundColor,
      FieldrushAuthTheme.cream,
    );
    expect(
      Theme.of(tester.element(clipScreen)).textTheme.bodyMedium?.fontFamily,
      'PlusJakartaSans',
    );
    expect(tester.widget<Text>(find.text('Clip')).style?.fontFamily, 'Outfit');
    expect(
      tester
          .widget<Text>(find.text('Top corner finish').last)
          .style
          ?.fontFamily,
      'Outfit',
    );

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
      findsNothing,
    );
    expect(find.byKey(const ValueKey('delete-profile-clip')), findsNothing);
    expect(find.byType(FieldrushVideoPlayer), findsOneWidget);
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

  testWidgets(
    'opening options before initialization prevents covered autoplay',
    (tester) async {
      final video = _installFakeVideoPlatform(holdInitialization: true);
      final repository = _FakeProfileRepository(profile: _emptyProfile);
      await _pumpClip(
        tester,
        repository: repository,
        downloader: _FakeGoalClipDownloader(),
      );
      await tester.tap(find.byKey(const ValueKey('profile-clip-options')));
      // Initialization is held, so the video loader keeps animating.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      video.completeInitialization();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(video.playCalls, 0);
      expect(repository.recordViewCalls, 0);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Play'), findsOneWidget);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(video.playCalls, 1);
      expect(repository.recordViewCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
      expect(find.byKey(const ValueKey('delete-profile-clip')), findsNothing);
      expect(
        find.byKey(const ValueKey('profile-clip-options')),
        findsOneWidget,
      );
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
    await _scrollClipControlIntoView(tester, deleteButton);
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
  if (control.evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('profile-clip-options')));
    await tester.pumpAndSettle();
  }
  await tester.scrollUntilVisible(
    control,
    180,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
}

_FakeVideoPlayerPlatform _installFakeVideoPlatform({
  bool holdInitialization = false,
}) {
  final originalPlatform = VideoPlayerPlatform.instance;
  final platform = _FakeVideoPlayerPlatform(
    holdInitialization: holdInitialization,
  );
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

class _FakeProfileRepository
    implements ProfileRepository, ProfileClipRecommendationsRepository {
  _FakeProfileRepository({
    required this.profile,
    this.recordedViews = 1,
    this.visibilityError,
    this.deleteError,
    this.recommendations = const [],
  });

  final PlayerProfile profile;
  final int recordedViews;
  final Object? visibilityError;
  final Object? deleteError;
  final List<ProfileClipRecommendation> recommendations;
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
  Future<List<ProfileClipRecommendation>> getClipRecommendations({
    required String highlightId,
    int limit = 8,
  }) async => recommendations
      .where(
        (next) =>
            next.highlight.id != highlightId &&
            !recordedHighlightIds.contains(next.highlight.id),
      )
      .take(limit)
      .toList();

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
  _FakeVideoPlayerPlatform({this.holdInitialization = false});
  final bool holdInitialization;
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _positions = {};
  int _nextPlayerId = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  int get createdPlayers => _nextPlayerId;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    final events = StreamController<VideoEvent>();
    _events[playerId] = events;
    _positions[playerId] = Duration.zero;
    if (!holdInitialization) events.add(_initializedEvent());
    return playerId;
  }

  VideoEvent _initializedEvent() => VideoEvent(
    eventType: VideoEventType.initialized,
    size: const Size(1920, 1080),
    duration: const Duration(seconds: 30),
  );

  void completeInitialization() {
    for (final events in _events.values) {
      events.add(_initializedEvent());
    }
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
