import 'dart:async';

import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_party.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/profile_repository.dart';
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

  testWidgets('opening clips pauses the detail replay before navigation', (
    tester,
  ) async {
    final original = VideoPlayerPlatform.instance;
    final video = _VideoPlatform();
    VideoPlayerPlatform.instance = video;
    addTearDown(() => VideoPlayerPlatform.instance = original);
    await _game(tester, _Games()..videoUrl = 'https://example.test/replay.mp4');
    await tester.tap(find.byKey(const ValueKey('game-tab-watch')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Watch replay'));
    await tester.pumpAndSettle();
    expect(video.playing[0], isTrue);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Clip'));
    await tester.pumpAndSettle();
    expect(find.byType(FixtureDetailScreen), findsOneWidget);
    expect(video.playing[0], isFalse);
    Navigator.of(tester.element(find.byType(FixtureDetailScreen))).pop();
    await tester.pumpAndSettle();
    expect(video.playing[0], isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clip navigation waits until replay initialization finishes', (
    tester,
  ) async {
    final original = VideoPlayerPlatform.instance;
    final video = _VideoPlatform()..autoInitialize = false;
    VideoPlayerPlatform.instance = video;
    addTearDown(() => VideoPlayerPlatform.instance = original);
    await _game(tester, _Games()..videoUrl = 'https://example.test/replay.mp4');
    await tester.tap(find.byKey(const ValueKey('game-tab-watch')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Watch replay'));
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Clip'))
          .onPressed,
      isNull,
    );
    video.initialize(0);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Clip'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
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

OpenQueueGame _gameModel({bool booked = true}) => OpenQueueGame(
  id: 'game',
  status: 'OPEN',
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
  String? videoUrl;
  int lookups = 0, cancellations = 0;
  Completer<OpenQueueBooking?>? nextLookup;
  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async =>
      OpenQueueMatchDetail(
        game: _gameModel(booked: booked),
        scorers: const [],
        timeline: const [],
        players: const [],
        videoUrl: videoUrl,
      );
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
    final id = _nextId++;
    _events[id] = StreamController<VideoEvent>();
    playing[id] = false;
    if (autoInitialize) initialize(id);
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;
  @override
  Widget buildView(int playerId) => const SizedBox.expand();
  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
    playing.remove(playerId);
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> pause(int playerId) async => playing[playerId] = false;
  @override
  Future<void> play(int playerId) async => playing[playerId] = true;
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
}
