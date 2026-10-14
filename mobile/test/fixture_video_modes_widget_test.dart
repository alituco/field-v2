import 'dart:async';

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_detail_screen.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/profile/goal_clip_downloader.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  testWidgets(
    'historical clan cancellation keeps reason and policy safeguards',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _fixture(status: FixtureStatus.open);
      final repository = _ClanCancellationFixtureRepository(fixture);
      await tester.pumpWidget(
        MaterialApp(
          home: FixtureDetailScreen(
            fixture: fixture,
            fixtureRepository: repository,
            profileRepository: _FakeProfileRepository('viewer'),
            myClanMembership: const MyClanMembership(
              clan: _homeClan,
              role: 'owner',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel clan match'));
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushModal), findsOneWidget);
      expect(find.text('Original payment method'), findsOneWidget);
      var confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('clan-cancellation-confirm')),
      );
      expect(confirm.onPressed, isNull);
      expect(
        confirm.style?.backgroundColor?.resolve({}),
        FieldrushAuthTheme.danger,
      );
      await tester.enterText(
        find.byKey(const ValueKey('clan-cancellation-reason')),
        'four',
      );
      await tester.pump();
      confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('clan-cancellation-confirm')),
      );
      expect(confirm.onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('clan-cancellation-reason')),
        'Not enough players',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('clan-cancellation-keep-match')),
      );
      await tester.pumpAndSettle();
      expect(repository.cancelledReasons, isEmpty);
      await tester.tap(find.text('Cancel clan match'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('clan-cancellation-reason')),
        '  Not enough players  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('clan-cancellation-confirm')));
      await tester.pumpAndSettle();
      expect(repository.cancelledReasons, ['Not enough players']);
      // One preview on each open, then a fresh preview before cancelling.
      expect(repository.previewCount, 3);
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(tester.getSize(scoreboardFinder).height, lessThan(320));
    expect(radius.topLeft, Radius.zero);
    expect(radius.topRight, Radius.zero);
    expect(radius.bottomLeft, Radius.zero);
    expect(radius.bottomRight, Radius.zero);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('fixture-detail-header'))).dy,
      0,
    );
    expect(find.text('MATCH DETAILS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('under-review final hides provisional score and rating result', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      _fixture(
        status: FixtureStatus.finalResult,
        operationalState: MatchOperationalState.underReview,
      ),
      playerRatingUpdate: const FixturePlayerRatingUpdate(
        ratingBefore: 1200,
        ratingChange: 14,
        ratingAfter: 1214,
        result: 'WIN',
      ),
    );

    expect(find.text('UNDER REVIEW'), findsWidgets);
    expect(find.text('Under review'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixture-operational-score-state')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('fixture-operational-resolution-panel')),
      findsOneWidget,
    );
    expect(find.text('1'), findsNothing);
    expect(find.text('0'), findsNothing);
    expect(find.text('+14 SR'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixture opens on match timeline with details and rating', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      _fixture(status: FixtureStatus.finalResult),
      playerRatingUpdate: const FixturePlayerRatingUpdate(
        ratingBefore: 1200,
        ratingChange: 14,
        ratingAfter: 1214,
        result: 'WIN',
      ),
    );

    expect(find.text('SATURDAY'), findsOneWidget);
    expect(find.text('Jul 11'), findsOneWidget);
    expect(find.text('Field'), findsOneWidget);
    expect(find.text('PLAYER RATING UPDATE'), findsOneWidget);
    expect(find.text('+14 SR'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixture-player-rating-margin-adjustment')),
      findsNothing,
    );
    expect(find.text('WATCH MATCH'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('fixture-section-watch')));
    await tester.pumpAndSettle();
    expect(find.text('WATCH MATCH'), findsOneWidget);
    expect(find.text('PLAYER RATING UPDATE'), findsNothing);
    expect(find.text('Field'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('decisive solo win explains the extra SR in the rating card', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      _fixture(status: FixtureStatus.finalResult),
      playerRatingUpdate: const FixturePlayerRatingUpdate(
        ratingBefore: 1200,
        ratingChange: 13,
        ratingAfter: 1213,
        result: 'WIN',
        scoreMargin: 3,
        marginMultiplier: 1.1,
        baseRatingChange: 12,
        marginBonusApplied: 1,
      ),
    );

    expect(
      find.byKey(const ValueKey('fixture-player-rating-margin-adjustment')),
      findsOneWidget,
    );
    expect(find.text('3-GOAL WIN BONUS'), findsOneWidget);
    expect(
      find.text('+1 SR included in this update · standard result +12 SR'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('decisive solo loss explains the margin adjustment', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      _fixture(status: FixtureStatus.finalResult),
      playerRatingUpdate: const FixturePlayerRatingUpdate(
        ratingBefore: 1200,
        ratingChange: -14,
        ratingAfter: 1186,
        result: 'LOSS',
        scoreMargin: 4,
        marginMultiplier: 1.15,
        baseRatingChange: -12,
        marginBonusApplied: -2,
      ),
    );

    expect(find.text('4-GOAL MARGIN ADJUSTMENT'), findsOneWidget);
    expect(
      find.text('-2 SR included in this update · standard result -12 SR'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixture can open directly on watch', (tester) async {
    await _pumpDetail(
      tester,
      _fixture(status: FixtureStatus.finalResult),
      initiallyShowWatch: true,
    );

    expect(find.text('WATCH MATCH'), findsOneWidget);
    expect(find.text('Field'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clan fixture teams open their clan details', (tester) async {
    final clanRepository = _FakeClanRepository();
    await _pumpDetail(
      tester,
      _fixture(status: FixtureStatus.scheduled),
      clanRepository: clanRepository,
    );

    expect(
      find.byKey(const ValueKey('fixture-clan-link-home')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('fixture-clan-link-away')),
      findsOneWidget,
    );
    expect(find.text('VIEW CLAN'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('fixture-clan-link-home')));
    await tester.pumpAndSettle();

    expect(find.byType(ClanDetailScreen), findsOneWidget);
    expect(
      tester.widget<ClanDetailScreen>(find.byType(ClanDetailScreen)).clan.id,
      'home',
    );
    expect(find.text('Home'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clan scoreboard shows clan SR and Bahrain rank, not averages', (
    tester,
  ) async {
    final fixture = Fixture(
      id: 'ranked-clan-fixture',
      status: FixtureStatus.scheduled,
      homeClanId: 'home',
      awayClanId: 'away',
      venue: 'Field',
      day: 'FRIDAY',
      timeSlot: FixtureTimeSlot.early.label,
      matchDate: DateTime.utc(2026, 7, 17),
      createdBy: 'owner',
      homeClan: const FixtureClan(
        id: 'home',
        name: 'Home',
        tag: 'HOM',
        emblem: '⚽',
        themeId: 'pitch',
        patternId: 'solid',
        skillRating: 1542,
        regionRank: 3,
      ),
      awayClan: const FixtureClan(
        id: 'away',
        name: 'Away',
        tag: 'AWY',
        emblem: '⚽',
        themeId: 'ocean',
        patternId: 'solid',
        skillRating: 1498,
        regionRank: 8,
      ),
      homeAveragePlayerRating: 1204,
      awayAveragePlayerRating: 1202,
      matchAveragePlayerRating: 1203,
      teamRatingSpread: 2,
    );

    await _pumpDetail(tester, fixture, sourceLabel: 'CLAN');

    expect(find.text('1542 CLAN SR'), findsOneWidget);
    expect(find.text('#3 BAHRAIN'), findsOneWidget);
    expect(find.text('1498 CLAN SR'), findsOneWidget);
    expect(find.text('#8 BAHRAIN'), findsOneWidget);
    expect(find.textContaining('AVG PLAYER RATING'), findsNothing);
    expect(find.textContaining('MATCH AVG'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('solo match teams are not clan links', (tester) async {
    await _pumpDetail(
      tester,
      _fixture(status: FixtureStatus.finalResult),
      sourceLabel: 'SOLO',
    );

    expect(find.byKey(const ValueKey('fixture-clan-link-home')), findsNothing);
    expect(find.byKey(const ValueKey('fixture-clan-link-away')), findsNothing);
    expect(find.text('VIEW CLAN'), findsNothing);
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

    final restart = find.byKey(const ValueKey('highlight-goal-0'));
    await tester.scrollUntilVisible(
      restart,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -70));
    await tester.pump();
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

  testWidgets('a scorer can title and add their active goal to profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final originalPlatform = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();
    addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);

    final playbackStartedAt = DateTime.utc(2026, 7, 11, 18);
    final profileRepository = _FakeProfileRepository('player-one');
    await _pumpDetail(
      tester,
      _fixture(
        status: FixtureStatus.finalResult,
        broadcast: FixtureBroadcast(
          status: 'REPLAY_READY',
          streamStartedAt: playbackStartedAt,
          streamStoppedAt: playbackStartedAt.add(const Duration(hours: 1)),
          replayHlsUrl: 'https://example.com/replay.m3u8',
        ),
        timeline: [
          _goal(
            id: 'my-goal',
            minute: 8,
            occurredAt: playbackStartedAt.add(const Duration(minutes: 8)),
            profileId: 'player-one',
          ),
        ],
      ),
      initiallyShowWatch: true,
      profileRepository: profileRepository,
    );
    await tester.pumpAndSettle();

    final addButton = find.byKey(const ValueKey('add-goal-to-profile'));
    await tester.scrollUntilVisible(
      addButton,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -100));
    await tester.pump();
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    expect(find.text('ADD GOAL TO PROFILE'), findsOneWidget);
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('ADD GOAL TO PROFILE')).style?.fontFamily,
      'Outfit',
    );
    expect(
      Theme.of(
        tester.element(find.byKey(const ValueKey('goal-clip-title-field'))),
      ).inputDecorationTheme.fillColor,
      Colors.white,
    );
    await tester.enterText(
      find.byKey(const ValueKey('goal-clip-title-field')),
      'a',
    );
    await tester.tap(find.byKey(const ValueKey('save-goal-clip')));
    await tester.pumpAndSettle();
    expect(
      find.text('Use a title between 2 and 80 characters.'),
      findsOneWidget,
    );
    expect(profileRepository.createdRequests, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('goal-clip-title-field')),
      'Outside foot finish',
    );
    await tester.tap(find.byKey(const ValueKey('save-goal-clip')));
    await tester.pumpAndSettle();

    expect(profileRepository.createdRequests, hasLength(1));
    final request = profileRepository.createdRequests.single;
    expect(request.sourceType, ProfileHighlightSource.clan);
    expect(request.matchId, 'fixture');
    expect(request.eventId, 'my-goal');
    expect(request.title, 'Outside foot finish');
    expect(find.text('Added to your profile'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a credited assister can add the goal clip to their profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final originalPlatform = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();
    addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);

    final playbackStartedAt = DateTime.utc(2026, 7, 11, 18);
    final profileRepository = _FakeProfileRepository('assistant-one');
    await _pumpDetail(
      tester,
      _fixture(
        status: FixtureStatus.finalResult,
        broadcast: FixtureBroadcast(
          status: 'REPLAY_READY',
          streamStartedAt: playbackStartedAt,
          streamStoppedAt: playbackStartedAt.add(const Duration(hours: 1)),
          replayHlsUrl: 'https://example.com/replay.m3u8',
        ),
        timeline: [
          _goal(
            id: 'assisted-goal',
            minute: 12,
            occurredAt: playbackStartedAt.add(const Duration(minutes: 12)),
            profileId: 'scorer-one',
            assistProfileId: 'assistant-one',
          ),
        ],
      ),
      initiallyShowWatch: true,
      profileRepository: profileRepository,
    );
    await tester.pumpAndSettle();

    final addButton = find.byKey(const ValueKey('add-goal-to-profile'));
    await tester.scrollUntilVisible(
      addButton,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    expect(find.text('ADD ASSIST TO PROFILE'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('goal-clip-title-field')),
          )
          .controller!
          .text,
      "Assist · 12'",
    );
    await tester.tap(find.byKey(const ValueKey('save-goal-clip')));
    await tester.pumpAndSettle();

    expect(profileRepository.createdRequests, hasLength(1));
    expect(profileRepository.createdRequests.single.eventId, 'assisted-goal');
    expect(find.textContaining('Assist'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'any authenticated viewer can download a highlight without posting it',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final originalPlatform = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();
      addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);

      final playbackStartedAt = DateTime.utc(2026, 7, 11, 18);
      final profileRepository = _FakeProfileRepository('unrelated-viewer');
      final downloader = _FakeGoalClipDownloader();
      await _pumpDetail(
        tester,
        _fixture(
          status: FixtureStatus.finalResult,
          broadcast: FixtureBroadcast(
            status: 'REPLAY_READY',
            streamStartedAt: playbackStartedAt,
            streamStoppedAt: playbackStartedAt.add(const Duration(hours: 1)),
            replayHlsUrl: 'https://example.com/replay.m3u8',
          ),
          timeline: [
            _goal(
              id: 'someone-elses-goal',
              minute: 19,
              occurredAt: playbackStartedAt.add(const Duration(minutes: 19)),
              profileId: 'different-player',
            ),
          ],
        ),
        initiallyShowWatch: true,
        profileRepository: profileRepository,
        goalClipDownloader: downloader,
      );
      await tester.pumpAndSettle();

      final downloadButton = find.byKey(
        const ValueKey('download-highlight-clip'),
      );
      await tester.scrollUntilVisible(
        downloadButton,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('add-goal-to-profile')), findsNothing);
      await tester.tap(downloadButton);
      await tester.pumpAndSettle();

      expect(profileRepository.goalDownloadEventIds, ['someone-elses-goal']);
      expect(profileRepository.createdRequests, isEmpty);
      expect(downloader.urls, ['https://cdn.example.com/goal.mp4']);
      expect(find.text('Goal saved to your Photos.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'watch overflow offers full download and custom clip download without posting',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final originalPlatform = VideoPlayerPlatform.instance;
      final videoPlatform = _FakeVideoPlayerPlatform();
      VideoPlayerPlatform.instance = videoPlatform;
      addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);

      final profileRepository = _FakeProfileRepository('viewer');
      final downloader = _FakeGoalClipDownloader();
      await _pumpDetail(
        tester,
        _fixture(
          status: FixtureStatus.finalResult,
          broadcast: const FixtureBroadcast(
            status: 'REPLAY_READY',
            replayHlsUrl: 'https://example.com/replay.m3u8',
          ),
        ),
        initiallyShowWatch: true,
        profileRepository: profileRepository,
        goalClipDownloader: downloader,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Full Game'));
      await tester.pumpAndSettle();

      final menu = find.byKey(const ValueKey('watch-actions-menu'));
      await tester.scrollUntilVisible(
        menu,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      final playerBounds = tester.getRect(
        find.byKey(const ValueKey('inline-video-player')),
      );
      expect(playerBounds.contains(tester.getCenter(menu)), isTrue);

      await tester.tap(menu);
      await tester.pumpAndSettle();

      expect(find.text('Download full game'), findsOneWidget);
      expect(find.text('Create a clip'), findsOneWidget);
      expect(find.text('Choose up to 60 seconds'), findsOneWidget);
      expect(find.byType(FieldrushModal), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) => widget is PopupMenuEntry),
        findsNothing,
      );
      expect(
        tester.widget<Text>(find.text('Match video options')).style?.fontFamily,
        'Outfit',
      );

      // Leaving the action sheet never begins a download or posts a clip.
      Navigator.of(tester.element(find.byType(FieldrushModal))).pop();
      await tester.pumpAndSettle();
      expect(profileRepository.customDownloadRequests, isEmpty);
      expect(profileRepository.createdCustomRequests, isEmpty);
      expect(downloader.urls, isEmpty);
      await tester.tap(menu);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create a clip'));
      await tester.pumpAndSettle();

      expect(find.text('CREATE A MATCH CLIP'), findsOneWidget);
      expect(find.textContaining('trim both ends'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('custom-clip-video-preview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('custom-clip-playhead')),
        findsOneWidget,
      );
      final range = tester.widget<RangeSlider>(
        find.byKey(const ValueKey('custom-clip-range')),
      );
      expect(range.values.end - range.values.start, lessThanOrEqualTo(60));

      final playhead = find.byKey(const ValueKey('custom-clip-playhead'));
      await tester.ensureVisible(playhead);
      await tester.pump();
      final seekCountBeforeDrag = videoPlatform.seekPositions.length;
      await tester.drag(playhead, const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        videoPlatform.seekPositions.length,
        greaterThan(seekCountBeforeDrag),
      );

      final preview = find.byKey(
        const ValueKey('custom-clip-preview-selection'),
      );
      await tester.ensureVisible(preview);
      await tester.pump();
      await tester.tap(preview);
      await tester.pump();
      expect(videoPlatform.playCalls, greaterThan(0));

      final continueButton = find.byKey(const ValueKey('custom-clip-continue'));
      await tester.ensureVisible(continueButton);
      await tester.pump();
      final pauseCountBeforeContinue = videoPlatform.pauseCalls;
      await tester.tap(continueButton);
      await tester.pumpAndSettle();
      expect(videoPlatform.pauseCalls, greaterThan(pauseCountBeforeContinue));
      expect(find.text('WHAT DO YOU WANT TO DO?'), findsOneWidget);
      expect(find.byType(FieldrushModal), findsOneWidget);
      final downloadAction = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('custom-clip-download')),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(
        downloadAction.style?.foregroundColor?.resolve({}),
        FieldrushAuthTheme.ink,
      );

      await tester.tap(find.byKey(const ValueKey('custom-clip-download')));
      await tester.pumpAndSettle();

      expect(profileRepository.customDownloadRequests, hasLength(1));
      expect(
        profileRepository.customDownloadRequests.single.durationSeconds,
        lessThanOrEqualTo(60),
      );
      expect(profileRepository.createdCustomRequests, isEmpty);
      expect(downloader.urls, ['https://cdn.example.com/custom.mp4']);
      expect(find.text('Clip saved to your Photos.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('custom clip save sheet keeps title validation and trim range', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalPlatform = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();
    addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);
    final repository = _FakeProfileRepository('viewer');
    await _pumpDetail(
      tester,
      _fixture(
        status: FixtureStatus.finalResult,
        broadcast: const FixtureBroadcast(
          status: 'REPLAY_READY',
          replayHlsUrl: 'https://example.com/replay.m3u8',
        ),
      ),
      initiallyShowWatch: true,
      profileRepository: repository,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full Game'));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('watch-actions-menu'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-match-clip')));
    await tester.pumpAndSettle();
    final range = tester
        .widget<RangeSlider>(find.byKey(const ValueKey('custom-clip-range')))
        .values;
    final continueButton = find.byKey(const ValueKey('custom-clip-continue'));
    await tester.ensureVisible(continueButton);
    await tester.tap(continueButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('custom-clip-save')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(find.text('SAVE CLIP TO PROFILE'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('goal-clip-title-field')),
      'x',
    );
    await tester.tap(find.byKey(const ValueKey('save-goal-clip')));
    await tester.pumpAndSettle();
    expect(
      find.text('Use a title between 2 and 80 characters.'),
      findsOneWidget,
    );
    expect(repository.createdCustomRequests, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('goal-clip-title-field')),
      '  Our best moment  ',
    );
    await tester.tap(find.byKey(const ValueKey('save-goal-clip')));
    await tester.pumpAndSettle();
    final request = repository.createdCustomRequests.single;
    expect(request.title, 'Our best moment');
    expect(request.startSeconds, range.start);
    expect(request.endSeconds, range.end);
    expect(request.durationSeconds, lessThanOrEqualTo(60));
    expect(repository.customDownloadRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full recording sheet requires confirmation before download', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalPlatform = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();
    addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);
    final repository = _FakeProfileRepository('viewer');
    final downloader = _FakeGoalClipDownloader();
    await _pumpDetail(
      tester,
      _fixture(
        status: FixtureStatus.finalResult,
        broadcast: const FixtureBroadcast(
          status: 'REPLAY_READY',
          replayHlsUrl: 'https://example.com/replay.m3u8',
        ),
      ),
      initiallyShowWatch: true,
      profileRepository: repository,
      goalClipDownloader: downloader,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full Game'));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('watch-actions-menu'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-full-game')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(find.text('Download the full game?'), findsOneWidget);
    expect(find.textContaining('Keep Fieldrush open'), findsOneWidget);
    expect(repository.fullGameDownloadRequests, isEmpty);
    await tester.tap(find.byKey(const ValueKey('field-confirmation-cancel')));
    await tester.pumpAndSettle();
    expect(repository.fullGameDownloadRequests, isEmpty);
    expect(downloader.urls, isEmpty);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-full-game')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('field-confirmation-confirm')));
    await tester.pumpAndSettle();
    expect(repository.fullGameDownloadRequests, ['fixture']);
    expect(downloader.urls, ['https://cdn.example.com/full-game.mp4']);
    expect(repository.createdRequests, isEmpty);
    expect(repository.createdCustomRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'custom clip editor seeks while trimming and stops preview at its end',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final originalPlatform = VideoPlayerPlatform.instance;
      final videoPlatform = _FakeVideoPlayerPlatform();
      VideoPlayerPlatform.instance = videoPlatform;
      addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);

      final profileRepository = _FakeProfileRepository('viewer');
      await _pumpDetail(
        tester,
        _fixture(
          status: FixtureStatus.finalResult,
          broadcast: const FixtureBroadcast(
            status: 'REPLAY_READY',
            replayHlsUrl: 'https://example.com/replay.m3u8',
          ),
        ),
        initiallyShowWatch: true,
        profileRepository: profileRepository,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Full Game'));
      await tester.pumpAndSettle();

      final menu = find.byKey(const ValueKey('watch-actions-menu'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a clip'));
      await tester.pumpAndSettle();

      var range = tester.widget<RangeSlider>(
        find.byKey(const ValueKey('custom-clip-range')),
      );
      final seekCountBeforeTrim = videoPlatform.seekPositions.length;
      range.onChanged!(
        RangeValues(
          range.values.start,
          (range.values.start + 90).clamp(range.min, range.max).toDouble(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));

      range = tester.widget<RangeSlider>(
        find.byKey(const ValueKey('custom-clip-range')),
      );
      expect(range.values.end - range.values.start, lessThanOrEqualTo(60));
      expect(
        videoPlatform.seekPositions.length,
        greaterThan(seekCountBeforeTrim),
      );

      final preview = find.byKey(
        const ValueKey('custom-clip-preview-selection'),
      );
      await tester.ensureVisible(preview);
      await tester.tap(preview);
      await tester.pump();
      expect(videoPlatform.playCalls, 1);

      final expectedEnd = Duration(
        milliseconds: (range.values.end * 1000).round(),
      );
      videoPlatform.setPosition(expectedEnd);
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();

      expect(videoPlatform.pauseCalls, greaterThan(0));
      expect(videoPlatform.seekPositions.last, expectedEnd);

      await tester.tap(preview);
      await tester.pump();
      final pauseCountBeforeCancel = videoPlatform.pauseCalls;
      await tester.tap(find.byKey(const ValueKey('custom-clip-cancel')));
      await tester.pumpAndSettle();

      expect(videoPlatform.pauseCalls, greaterThan(pauseCountBeforeCancel));
      expect(videoPlatform.disposeCalls, 0);
      expect(profileRepository.createdCustomRequests, isEmpty);
      expect(profileRepository.customDownloadRequests, isEmpty);
      expect(find.text('WATCH MATCH'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'finished video has goal chapters and draggable inline timelines',
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
      expect(find.text('Previous'), findsNothing);
      expect(find.text('Restart'), findsNothing);
      expect(find.text('Next'), findsNothing);
      expect(
        find.byKey(const ValueKey('highlight-video-seek')),
        findsOneWidget,
      );
      expect(find.text('0:00 / 0:30'), findsWidgets);
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

      final highlightSlider = find.byKey(
        const ValueKey('highlight-video-seek'),
      );
      await tester.ensureVisible(highlightSlider);
      await tester.pump();
      final highlightSliderBounds = tester.getRect(highlightSlider);
      final highlightGesture = await tester.startGesture(
        Offset(
          highlightSliderBounds.left + 20,
          highlightSliderBounds.center.dy,
        ),
      );
      await highlightGesture.moveTo(
        Offset(
          highlightSliderBounds.right - 20,
          highlightSliderBounds.center.dy,
        ),
      );
      await highlightGesture.up();
      await tester.pump();
      expect(
        videoPlatform.seekPositions.last,
        greaterThan(const Duration(minutes: 18, seconds: 10)),
      );
      expect(
        videoPlatform.seekPositions.last,
        lessThanOrEqualTo(const Duration(minutes: 18, seconds: 20)),
      );

      await tester.tap(secondGoal);
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
      expect(
        find.byKey(const ValueKey('fullscreen-video-seek')),
        findsOneWidget,
      );
      expect(find.text('0:00 / 0:30'), findsWidgets);
      expect(find.byTooltip('Close'), findsNothing);
      expect(find.byKey(const ValueKey('fullscreen-exit')), findsOneWidget);
      expect(_fullscreenControlsOpacity(tester), 1);

      await tester.tap(find.byTooltip('Forward 10 seconds'));
      await tester.pump();
      await tester.pump();
      expect(videoPlatform.seekPositions.last, const Duration(minutes: 18));

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

      await tester.tap(find.byTooltip('Exit fullscreen'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, 220));
      await tester.pump();
      await tester.tap(find.text('Full Game'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.byKey(const ValueKey('full-game-seek')), findsOneWidget);
      expect(find.text('0:00 / 1:00:00'), findsOneWidget);

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

Future<void> _pumpDetail(
  WidgetTester tester,
  Fixture fixture, {
  FixturePlayerRatingUpdate? playerRatingUpdate,
  bool initiallyShowWatch = false,
  ClanRepository? clanRepository,
  ProfileRepository? profileRepository,
  GoalClipDownloader? goalClipDownloader,
  String? sourceLabel,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: FixtureDetailScreen(
        fixture: fixture,
        fixtureRepository: _FakeFixtureRepository(fixture),
        clanRepository: clanRepository,
        myClanMembership: null,
        sourceLabel: sourceLabel,
        playerRatingUpdate: playerRatingUpdate,
        initiallyShowWatch: initiallyShowWatch,
        profileRepository: profileRepository ?? _FakeProfileRepository(null),
        goalClipDownloader: goalClipDownloader,
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
  await tester.tap(find.byKey(const ValueKey('fixture-section-watch')));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.scrollUntilVisible(
    find.text(heading),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

Fixture _fixture({
  required FixtureStatus status,
  MatchOperationalState operationalState = MatchOperationalState.normal,
  FixtureBroadcast? broadcast,
  List<FixtureTimelineEvent> timeline = const [],
}) {
  return Fixture(
    id: 'fixture',
    status: status,
    operationalState: operationalState,
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

const _homeClanDetail = Clan(
  id: 'home',
  name: 'Home',
  tag: 'HOM',
  motto: 'Home together',
  emblem: '⚽',
  themeId: 'pitch',
  patternId: 'solid',
  skillRating: 1500,
  wins: 2,
  losses: 1,
  memberCount: 7,
  createdBy: 'owner',
);

const _awayClanDetail = Clan(
  id: 'away',
  name: 'Away',
  tag: 'AWY',
  motto: 'Away together',
  emblem: '⚽',
  themeId: 'shadow',
  patternId: 'solid',
  skillRating: 1500,
  wins: 1,
  losses: 2,
  memberCount: 7,
  createdBy: 'away-owner',
);

class _FakeClanRepository implements ClanRepository {
  @override
  Future<List<Clan>> listClans() async => const [
    _homeClanDetail,
    _awayClanDetail,
  ];

  @override
  Future<ClanMembership?> getMyClanMembership() async =>
      const ClanMembership(clanId: 'home', role: 'owner');

  @override
  Future<List<ClanMember>> listClanMembers(String clanId) async => const [];

  @override
  Future<List<Fixture>> listClanFixtures(String clanId) async => const [];

  @override
  Future<List<ClanJoinRequest>> listPendingJoinRequests(String clanId) async =>
      const [];

  @override
  Future<ClanJoinRequest?> getMyPendingJoinRequest(String clanId) async => null;

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

class _ClanCancellationFixtureRepository extends _FakeFixtureRepository
    implements FixtureReliabilityBookingRepository {
  _ClanCancellationFixtureRepository(super.fixture);

  int previewCount = 0;
  final List<String> cancelledReasons = [];

  static const quote = ClanFixtureCancellationPreview(
    canCancel: true,
    outcomeCode: 'EARLY_CANCELLATION',
    cancellationBand: 'EARLY',
    strikeDelta: 0,
    refundBps: 10000,
    refundAmountFils: 8000,
    depositForfeited: false,
    opponentRefundAmountFils: 0,
    createsForfeit: false,
    forfeitScore: 3,
    currency: 'USD',
    refundDestination: 'ORIGINAL_PAYMENT_METHOD',
  );

  @override
  Future<ClanFixtureCancellationPreview> previewFixtureCancellation(
    String fixtureId,
  ) async {
    previewCount++;
    return quote;
  }

  @override
  Future<ClanFixtureCancellationPreview> cancelFixtureBooking({
    required String fixtureId,
    required String reason,
  }) async {
    cancelledReasons.add(reason);
    return quote;
  }
}

FixtureTimelineEvent _goal({
  required String id,
  required int minute,
  required DateTime occurredAt,
  String? profileId,
  String? assistProfileId,
}) {
  return FixtureTimelineEvent(
    id: id,
    fixtureId: 'fixture',
    eventType: 'GOAL',
    minute: minute,
    second: 0,
    profileId: profileId,
    assistProfileId: assistProfileId,
    occurredAt: occurredAt,
    createdAt: occurredAt,
  );
}

class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository(this.currentUserId);

  @override
  final String? currentUserId;
  final List<ProfileGoalClipRequest> createdRequests = [];
  final List<String> goalDownloadEventIds = [];
  final List<ProfileCustomClipRequest> createdCustomRequests = [];
  final List<ProfileCustomClipRequest> customDownloadRequests = [];
  final List<String> fullGameDownloadRequests = [];

  @override
  Future<ProfileFullGameDownload> prepareFullGameDownload({
    required ProfileHighlightSource sourceType,
    required String matchId,
  }) async {
    fullGameDownloadRequests.add(matchId);
    return const ProfileFullGameDownload(
      status: ProfileFullGameDownloadStatus.ready,
      downloadUrl: 'https://cdn.example.com/full-game.mp4',
    );
  }

  @override
  Future<ProfileHighlight> createGoalClip(
    ProfileGoalClipRequest request,
  ) async {
    createdRequests.add(request);
    return const ProfileHighlight(
      id: 'clip-one',
      title: 'Outside foot finish',
      thumbnailUrl: '',
      duration: '0:30',
      views: 0,
      sourceType: ProfileHighlightSource.clan,
      sourceMatchId: 'fixture',
      sourceEventId: 'my-goal',
      status: ProfileHighlightStatus.processing,
    );
  }

  @override
  Future<ProfileClipMedia> getGoalClipDownload({
    required ProfileHighlightSource sourceType,
    required String matchId,
    required String eventId,
  }) async {
    goalDownloadEventIds.add(eventId);
    return const ProfileClipMedia(
      videoUrl: 'https://cdn.example.com/goal.m3u8',
      downloadUrl: 'https://cdn.example.com/goal.mp4',
      thumbnailUrl: '',
      duration: '0:30',
      startSeconds: 10,
      endSeconds: 40,
    );
  }

  @override
  Future<ProfileHighlight> createCustomClip(
    ProfileCustomClipRequest request,
  ) async {
    createdCustomRequests.add(request);
    return ProfileHighlight(
      id: 'custom-clip',
      title: request.title,
      thumbnailUrl: '',
      duration: '0:${request.durationSeconds.round()}',
      views: 0,
      sourceType: request.sourceType,
      sourceMatchId: request.matchId,
      status: ProfileHighlightStatus.processing,
    );
  }

  @override
  Future<ProfileClipMedia> getCustomClipDownload(
    ProfileCustomClipRequest request,
  ) async {
    customDownloadRequests.add(request);
    return ProfileClipMedia(
      videoUrl: 'https://cdn.example.com/custom.m3u8',
      downloadUrl: 'https://cdn.example.com/custom.mp4',
      thumbnailUrl: '',
      duration: '0:${request.durationSeconds.round()}',
      startSeconds: request.startSeconds,
      endSeconds: request.endSeconds,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeGoalClipDownloader implements GoalClipDownloader {
  final List<String> urls = [];
  final List<String> fileNames = [];

  @override
  Future<void> downloadToGallery({
    required String url,
    required String fileName,
    ValueChanged<double>? onProgress,
  }) async {
    urls.add(url);
    fileNames.add(fileName);
    onProgress?.call(0.5);
    onProgress?.call(1);
  }
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _positions = {};
  final List<Duration> seekPositions = [];
  int _nextPlayerId = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  int disposeCalls = 0;

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
    disposeCalls += 1;
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
