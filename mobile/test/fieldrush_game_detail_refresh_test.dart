import 'dart:async';

import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fieldrush_match_replay_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_party.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/ui/fieldrush_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  setUpAll(() async {
    for (final font in ['Outfit', 'PlusJakartaSans']) {
      await (FontLoader(
        font,
      )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
    }
  });

  for (final owner in [true, false]) {
    testWidgets(
      'switching party discloses ${owner ? 'owner disband' : 'member departure'} and can be declined',
      (tester) async {
        final repository = _Parties(_context(owner: owner));
        await _party(tester, repository);
        await tester.tap(find.text('Accept'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            owner
                ? 'Cancel your party and switch?'
                : 'Leave your party and switch?',
          ),
          findsOneWidget,
        );
        expect(repository.responses, isEmpty);
        if (owner) {
          expect(find.textContaining('for all members'), findsOneWidget);
        }
        expect(
          find.text('Everyone keeps their individual game booking.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Keep current party'));
        await tester.pumpAndSettle();
        expect(repository.responses, isEmpty);
        await tester.tap(find.text('Accept'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Switch parties'));
        await tester.pumpAndSettle();
        expect(repository.responses, [('invite', true)]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('accept fails closed when current party context cannot refresh', (
    tester,
  ) async {
    final repository = _Parties(_context());
    await _party(tester, repository);
    repository.fail = true;
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(repository.responses, isEmpty);
    expect(find.text('Try again'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale party read cannot restore a party after disbanding', (
    tester,
  ) async {
    final old = _context(invites: false);
    final repository = _Parties(old);
    var changes = 0;
    await _party(
      tester,
      repository,
      onChanged: () async {
        changes++;
      },
    );
    final ownPartySeat = find.byKey(
      const ValueKey('fieldrush-party-member-mine'),
    );
    expect(ownPartySeat, findsOneWidget);
    expect(find.text('Cancel party'), findsOneWidget);
    final stale = Completer<OpenQueuePartyContext>();
    repository.next = stale;
    await _party(
      tester,
      repository,
      onChanged: () async {
        changes++;
      },
      settle: false,
    );
    await tester.tap(find.text('Cancel party'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Cancel party'));
    await tester.pumpAndSettle();
    expect(repository.disbands, 1);
    expect(changes, 1);
    expect(ownPartySeat, findsNothing);
    expect(find.text('Cancel party'), findsNothing);
    stale.complete(old);
    await tester.pumpAndSettle();
    expect(ownPartySeat, findsNothing);
    expect(find.text('Cancel party'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disposed party action never refreshes the departed detail route',
    (tester) async {
      final repository = _Parties(_context(invites: false));
      final action = Completer<void>();
      repository.action = action;
      var changes = 0;
      await _party(
        tester,
        repository,
        onChanged: () async {
          changes++;
        },
      );
      await tester.tap(find.text('Cancel party'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel party'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      action.complete();
      await tester.pumpAndSettle();
      expect(changes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'post-cancellation refresh supersedes an in-flight booking lookup',
    (tester) async {
      final repository = _Games();
      await _game(tester, repository);
      final stale = Completer<OpenQueueBooking?>();
      repository.nextLookup = stale;
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(repository.lookups, 2);
      await tester.tap(find.text('Leave game'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Confirm cancellation'));
      await tester.pumpAndSettle();
      expect(repository.cancellations, 1);
      expect(repository.lookups, 3);
      expect(find.text('Leave game'), findsNothing);
      stale.complete(_booking());
      await tester.pumpAndSettle();
      expect(find.text('Leave game'), findsNothing);
      expect(find.text(r'Join · $13.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('fresh game flag clears stale booking when its lookup fails', (
    tester,
  ) async {
    final repository = _Games();
    await _game(tester, repository);
    repository.booked = false;
    repository.failLookup = true;
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(find.text('Leave game'), findsNothing);
    expect(find.text(r'Join · $13.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('completed solo Play opens replay and preserves clip position', (
    tester,
  ) async {
    final original = VideoPlayerPlatform.instance;
    final video = _VideoPlatform();
    VideoPlayerPlatform.instance = video;
    addTearDown(() => VideoPlayerPlatform.instance = original);
    await _game(
      tester,
      _Games()
        ..status = 'FINAL'
        ..videoUrl = 'https://example.test/replay.mp4',
    );
    await tester.tap(find.byKey(const ValueKey('game-tab-watch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Watch replay'));
    await tester.pumpAndSettle();
    expect(video.playing[0], isTrue);
    expect(video.sourceUrls, hasLength(1));
    final replay = tester.widget<FieldrushMatchReplayScreen>(
      find.byType(FieldrushMatchReplayScreen),
    );
    expect(replay.fixture.id, 'game');
    expect(
      replay.fixture.fullGamePlaybackUrl,
      'https://example.test/replay.mp4',
    );
    expect(replay.sourceLabel, 'SOLO');
    final player = tester.widget<FieldrushVideoPlayer>(
      find.byType(FieldrushVideoPlayer),
    );
    await player.controller.seekTo(const Duration(minutes: 12, seconds: 34));
    await tester.pump();
    await tester.tap(find.byTooltip('Replay options'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create match clip'));
    await tester.pumpAndSettle();
    expect(find.text('Create match clip'), findsOneWidget);
    expect(find.byType(FixtureDetailScreen), findsNothing);
    expect(
      find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
      findsNothing,
    );
    expect(video.sourceUrls, hasLength(1));
    expect(video.playing[0], isFalse);
    await tester.tap(find.byKey(const ValueKey('custom-clip-cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushMatchReplayScreen), findsOneWidget);
    expect(
      find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
      findsNothing,
    );
    expect(video.sourceUrls, hasLength(1));
    expect(
      player.controller.value.position,
      const Duration(minutes: 12, seconds: 34),
    );
    expect(video.playing[0], isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('solo Clip opens editor directly over the new replay', (
    tester,
  ) async {
    final original = VideoPlayerPlatform.instance;
    final video = _VideoPlatform();
    VideoPlayerPlatform.instance = video;
    addTearDown(() => VideoPlayerPlatform.instance = original);
    await _game(
      tester,
      _Games()
        ..status = 'FINAL'
        ..videoUrl = 'https://example.test/replay.mp4',
    );
    await tester.tap(find.byKey(const ValueKey('game-tab-watch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('solo-watch-clip')));
    await tester.pumpAndSettle();
    final replay = tester.widget<FieldrushMatchReplayScreen>(
      find.byType(FieldrushMatchReplayScreen, skipOffstage: false),
    );
    expect(replay.openClipEditor, isTrue);
    expect(find.byKey(const ValueKey('custom-clip-range')), findsOneWidget);
    expect(
      find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
      findsNothing,
    );
    expect(video.sourceUrls, hasLength(1));
    expect(video.playing[0], isFalse);
    await tester.tap(find.byKey(const ValueKey('custom-clip-cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushMatchReplayScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('custom-clip-range')), findsNothing);
    expect(video.sourceUrls, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('highlights opens the replay timeline without the clip editor', (
    tester,
  ) async {
    final original = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = _VideoPlatform();
    addTearDown(() => VideoPlayerPlatform.instance = original);
    await _game(
      tester,
      _Games()
        ..status = 'FINAL'
        ..videoUrl = 'https://example.test/replay.mp4',
    );
    await tester.tap(find.byKey(const ValueKey('game-tab-watch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('solo-watch-clip')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('solo-watch-highlights')));
    await tester.pumpAndSettle();
    final screen = tester.widget<FieldrushMatchReplayScreen>(
      find.byType(FieldrushMatchReplayScreen),
    );
    expect(screen.openClipEditor, isFalse);
    expect(find.byKey(const ValueKey('custom-clip-range')), findsNothing);
    expect(find.byType(FixtureDetailScreen), findsNothing);
    expect(
      find.byType(FieldrushMatchWatchScreen, skipOffstage: false),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('solo replay navigates before creating the only video player', (
    tester,
  ) async {
    final original = VideoPlayerPlatform.instance;
    final video = _VideoPlatform()..autoInitialize = false;
    VideoPlayerPlatform.instance = video;
    addTearDown(() => VideoPlayerPlatform.instance = original);
    await _game(
      tester,
      _Games()
        ..status = 'FINAL'
        ..videoUrl = 'https://example.test/replay.mp4',
    );
    await tester.tap(find.byKey(const ValueKey('game-tab-watch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Watch replay'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(FieldrushMatchReplayScreen), findsOneWidget);
    expect(find.byType(FieldrushMatchWatchScreen), findsNothing);
    expect(video.sourceUrls, ['https://example.test/replay.mp4']);
    video.initialize(0);
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushVideoPlayer), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('solo replay refresh stays on its original injected game', (
    tester,
  ) async {
    final original = VideoPlayerPlatform.instance;
    final video = _VideoPlatform();
    VideoPlayerPlatform.instance = video;
    addTearDown(() => VideoPlayerPlatform.instance = original);
    final repository = _Games()
      ..status = 'FINAL'
      ..videoUrl = 'https://example.test/original.mp4';
    await _game(tester, repository);
    await tester.tap(find.byKey(const ValueKey('game-tab-watch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Watch replay'));
    await tester.pumpAndSettle();
    final replay = tester.widget<FieldrushMatchReplayScreen>(
      find.byType(FieldrushMatchReplayScreen),
    );
    repository.videoUrl = 'https://example.test/replacement.mp4';
    final refreshed = await replay.refreshFixture!();
    expect(refreshed.id, 'game');
    expect(
      refreshed.fullGamePlaybackUrl,
      'https://example.test/replacement.mp4',
    );
    expect(repository.requestedGameIds.every((id) => id == 'game'), isTrue);
    await tester.pump(const Duration(seconds: 20));
    expect(find.byType(FieldrushMatchReplayScreen), findsOneWidget);
    expect(find.byType(FieldrushMatchWatchScreen), findsNothing);
    expect(video.sourceUrls, hasLength(1));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Solo game'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live solo Stream keeps playback inline', (tester) async {
    final original = VideoPlayerPlatform.instance;
    final video = _VideoPlatform();
    VideoPlayerPlatform.instance = video;
    addTearDown(() => VideoPlayerPlatform.instance = original);
    await _game(
      tester,
      _Games()
        ..status = 'LIVE'
        ..broadcast = const FixtureBroadcast(
          status: 'LIVE',
          hlsUrl: 'https://example.test/live.m3u8',
        ),
    );
    await tester.tap(find.byKey(const ValueKey('game-tab-watch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Watch live'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushMatchReplayScreen), findsNothing);
    expect(find.byType(FieldrushVideoPlayer), findsOneWidget);
    expect(video.sourceUrls, ['https://example.test/live.m3u8']);
    expect(video.playing[0], isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('roster identifies its snapshot and refreshes game on return', (
    tester,
  ) async {
    final repository = _Games();
    await _game(tester, repository);
    await tester.tap(find.text('See all ›'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Roster at the time you opened this page. Return to the game for updates.',
      ),
      findsOneWidget,
    );
    final before = repository.lookups;
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(repository.lookups, before + 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _size(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _party(
  WidgetTester tester,
  _Parties repository, {
  Future<void> Function()? onChanged,
  bool settle = true,
}) async {
  await _size(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FieldrushGameDetailParty(
          repository: repository,
          game: _gameModel(),
          viewerProfileId: 'me',
          onChanged: onChanged ?? () async {},
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _game(WidgetTester tester, _Games repository) async {
  await _size(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: FieldrushGameDetailScreen(
        repository: repository,
        gameId: 'game',
        onJoin: (_) async {},
        fixtureRepository: _Fixtures(),
        profileRepository: _Profiles(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OpenQueueGame _gameModel({bool booked = true, String status = 'OPEN'}) =>
    OpenQueueGame(
      id: 'game',
      status: status,
      venue: 'Phoenix',
      startsAt: DateTime.utc(2030, 10, 12, 3, 30),
      endsAt: DateTime.utc(2030, 10, 12, 4, 30),
      timezone: 'America/Phoenix',
      priceFils: 13000,
      currency: 'USD',
      ageLabel: '18+',
      capacity: 14,
      confirmedCount: booked ? 3 : 2,
      myBookingId: booked ? 'booking' : null,
      myBookingRole: booked ? OpenQueueRole.attacker : null,
      spots: const {
        OpenQueueRole.goalkeeper: 2,
        OpenQueueRole.defender: 6,
        OpenQueueRole.attacker: 4,
      },
    );
OpenQueueBooking _booking() => OpenQueueBooking(
  id: 'booking',
  gameId: 'game',
  profileId: 'me',
  role: OpenQueueRole.attacker,
  status: 'CONFIRMED',
  amountPaidFils: 13000,
  bookedAt: DateTime.utc(2030, 10),
  game: _gameModel(),
  refundAmountFils: 13000,
  refundDestination: 'ORIGINAL_PAYMENT_METHOD',
  refundStatus: 'PENDING',
);
OpenQueuePartyContext _context({
  bool owner = true,
  bool party = true,
  bool invites = true,
}) => OpenQueuePartyContext(
  gameId: 'game',
  gameStatus: 'OPEN',
  canUseParties: true,
  maxPartySize: 4,
  myParty: !party
      ? null
      : OpenQueueParty(
          id: 'old-party',
          ownerProfileId: owner ? 'me' : 'friend',
          isOwner: owner,
          acceptedCount: 1,
          members: [
            OpenQueuePartyMember(
              membershipId: 'mine',
              profileId: 'me',
              displayName: 'Current Player',
              role: OpenQueueRole.attacker,
              status: OpenQueuePartyMemberStatus.accepted,
              isOwner: owner,
              invitedAt: null,
            ),
          ],
        ),
  receivedInvites: !invites
      ? const []
      : const [
          OpenQueuePartyInvite(
            membershipId: 'invite',
            partyId: 'new-party',
            invitedAt: null,
            owner: OpenQueuePartyPlayer(
              profileId: 'new-owner',
              displayName: 'Alex',
              role: OpenQueueRole.defender,
            ),
            acceptedCount: 1,
            members: [],
          ),
        ],
  eligiblePlayers: const [],
);

class _Parties extends Fake
    implements OpenQueueRepository, OpenQueuePartyRepository {
  _Parties(this.data);
  OpenQueuePartyContext data;
  Completer<OpenQueuePartyContext>? next;
  Completer<void>? action;
  bool fail = false;
  int disbands = 0;
  final responses = <(String, bool)>[];
  @override
  Future<OpenQueuePartyContext> getPartyContext(String gameId) async {
    if (fail) throw StateError('Network unavailable');
    if (next case final pending?) {
      next = null;
      return pending.future;
    }
    return data;
  }

  @override
  Future<void> respondToPartyInvite({
    required String membershipId,
    required bool accept,
  }) async {
    responses.add((membershipId, accept));
    data = _context(party: false, invites: false);
  }

  @override
  Future<void> disbandParty(String partyId) async {
    disbands++;
    if (action != null) await action!.future;
    data = _context(party: false, invites: false);
  }
}

class _Games extends Fake
    implements OpenQueueRepository, OpenQueueBookingLookupRepository {
  bool booked = true, failLookup = false;
  String status = 'OPEN';
  String? videoUrl;
  FixtureBroadcast? broadcast;
  int lookups = 0, cancellations = 0;
  final requestedGameIds = <String>[];
  Completer<OpenQueueBooking?>? nextLookup;
  Completer<OpenQueueMatchDetail>? nextDetail;
  OpenQueueMatchDetail get detail => OpenQueueMatchDetail(
    game: _gameModel(booked: booked, status: status),
    scorers: const [],
    timeline: const [],
    players: const [],
    videoUrl: videoUrl,
    broadcast: broadcast,
  );
  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async {
    requestedGameIds.add(gameId);
    if (nextDetail case final pending?) {
      nextDetail = null;
      return pending.future;
    }
    return detail;
  }

  @override
  Future<OpenQueueBooking?> getMyUpcomingBookingForGame(String gameId) async {
    lookups++;
    if (nextLookup case final pending?) {
      nextLookup = null;
      return pending.future;
    }
    if (failLookup) throw StateError('Lookup unavailable');
    return booked ? _booking() : null;
  }

  @override
  Future<OpenQueueCancellationPreview> previewCancellation(
    String bookingId,
  ) async => const OpenQueueCancellationPreview(
    canCancel: true,
    refundPercent: 100,
    refundAmountFils: 13000,
    refundCutoffAt: null,
    currency: 'USD',
    refundDestination: 'ORIGINAL_PAYMENT_METHOD',
  );
  @override
  Future<OpenQueueBooking> cancelBooking(String bookingId) async {
    cancellations++;
    booked = false;
    return _booking();
  }
}

class _Fixtures extends Fake implements FixtureRepository {}

class _Profiles extends Fake implements ProfileRepository {
  @override
  String? get currentUserId => 'me';
}

class _VideoPlatform extends VideoPlayerPlatform {
  final _events = <int, StreamController<VideoEvent>>{};
  final playing = <int, bool>{};
  final positions = <int, Duration>{};
  final sourceUrls = <String?>[];
  final disposed = <int>[];
  bool autoInitialize = true;
  int _nextId = 0;

  void initialize(int id) => _events[id]!.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      size: const Size(1920, 1080),
      duration: const Duration(hours: 1),
    ),
  );

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sourceUrls.add(options.dataSource.uri);
    final id = _nextId++;
    _events[id] = StreamController<VideoEvent>();
    playing[id] = false;
    positions[id] = Duration.zero;
    if (autoInitialize) initialize(id);
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;
  @override
  Widget buildView(int playerId) => const SizedBox.expand();
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await _events.remove(playerId)?.close();
    playing.remove(playerId);
    positions.remove(playerId);
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;
  @override
  Future<void> pause(int playerId) async => playing[playerId] = false;
  @override
  Future<void> play(int playerId) async => playing[playerId] = true;
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    positions[playerId] = position;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
}
