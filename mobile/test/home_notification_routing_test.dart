import 'dart:convert';

import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/home/home_discovery_repository.dart';
import 'package:field/src/home/home_discovery_screen.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_booking_screen.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/open_queue/open_queue_review_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('notification payload maps only explicitly supported entity types', () {
    final party = HomeNotification.fromJson(
      _notificationJson(
        type: 'OPEN_QUEUE_PARTY_MEMBERSHIP',
        id: 'membership-id',
        data: {'game_id': 'actual-game'},
      ),
    );
    expect(party.entityId, 'membership-id');
    expect(party.openQueueGameId, 'actual-game');
    expect(party.fixtureId, isNull);

    final incident = HomeNotification.fromJson(
      _notificationJson(
        type: 'CLAN_RELIABILITY_INCIDENT',
        id: 'incident-id',
        data: {'fixture_id': 'actual-fixture'},
      ),
    );
    expect(incident.fixtureId, 'actual-fixture');
    expect(incident.openQueueGameId, isNull);

    for (final payload in [
      null,
      [],
      {'game_id': 42},
      {'game_id': '  '},
    ]) {
      final item = HomeNotification.fromJson(
        _notificationJson(
          type: 'OPEN_QUEUE_PARTY_MEMBERSHIP',
          id: 'membership-id',
          data: payload,
        ),
      );
      expect(item.openQueueGameId, isNull);
    }
    final unsupported = HomeNotification.fromJson(
      _notificationJson(
        type: 'SUPPORT_TICKET',
        id: 'actual-game',
        data: {'game_id': 'actual-game', 'fixture_id': 'actual-fixture'},
      ),
    );
    expect(unsupported.openQueueGameId, isNull);
    expect(unsupported.fixtureId, isNull);
  });

  test(
    'repository loads owned unresolved activity including JSON data',
    () async {
      final requests = <http.Request>[];
      final client = _client(
        requests,
        (request) => [
          _notificationJson(
            type: 'OPEN_QUEUE_PARTY_MEMBERSHIP',
            id: 'membership-id',
            data: {'game_id': 'actual-game'},
          ),
        ],
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(_session));
      final items = await SupabaseHomeDiscoveryRepository(
        client: client,
      ).notifications();
      expect(items.single.openQueueGameId, 'actual-game');
      final query = requests.single.url.queryParameters;
      expect(query['select'], contains('data'));
      expect(query['recipient_profile_id'], 'eq.profile');
      expect(query['resolved_at'], 'is.null');
      expect(query['order'], startsWith('created_at.desc'));
    },
  );

  test(
    'public search normalizes blank avatar URLs without private fields',
    () async {
      final requests = <http.Request>[];
      final client = _client(
        requests,
        (_) => [
          {
            'id': 'a',
            'display_name': 'Dana',
            'username': 'dana',
            'avatar_url': '  ',
          },
          {
            'id': 'b',
            'display_name': 'Sam',
            'username': 'sam',
            'avatar_url': null,
          },
        ],
      );
      addTearDown(client.dispose);
      final players = await SupabaseHomeDiscoveryRepository(
        client: client,
      ).searchPlayers('da');
      expect(players.map((player) => player.avatarUrl), [null, null]);
      expect(
        requests.single.url.queryParameters['select'],
        'id,display_name,username,avatar_url',
      );
    },
  );

  testWidgets(
    'nonempty player search renders a tappable card without assertions',
    (tester) async {
      String? openedId;
      final repository = _Discovery(
        _notice('SUPPORT_TICKET', 'support'),
        readFails: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: HomeDiscoveryScreen(
            repository: repository,
            search: true,
            onPlayer: (id) async {
              openedId = id;
            },
            onNotification: (_) async {},
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('home-player-search')),
        'Dana',
      );
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      final tile = find.byKey(
        const ValueKey('home-search-player-found-player'),
      );
      expect(tile, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(openedId, 'found-player');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('game activity opens a known booking instead of checkout', (
    tester,
  ) async {
    final game = _game('booked');
    final queue = _Queue(bookings: [_booking(game)]);
    await _openActivity(tester, queue, _notice('OPEN_QUEUE_GAME', game.id));
    expect(find.byType(OpenQueueBookingScreen), findsOneWidget);
    expect(
      tester
          .widget<OpenQueueBookingScreen>(find.byType(OpenQueueBookingScreen))
          .booking
          .gameId,
      game.id,
    );
    expect(queue.detailRequests, isEmpty);
    expect(find.byType(OpenQueueReviewScreen), findsNothing);
  });

  testWidgets('party activity uses game_id, not the membership entity ID', (
    tester,
  ) async {
    final game = _game('party-game');
    final queue = _Queue(bookings: [_booking(game)]);
    await _openActivity(
      tester,
      queue,
      _notice(
        'OPEN_QUEUE_PARTY_MEMBERSHIP',
        'membership-id',
        data: {'game_id': game.id},
      ),
    );
    expect(
      tester
          .widget<OpenQueueBookingScreen>(find.byType(OpenQueueBookingScreen))
          .booking
          .gameId,
      game.id,
    );
    expect(queue.detailRequests, isEmpty);
  });

  testWidgets('historical cancelled game opens by ID outside the Home feed', (
    tester,
  ) async {
    final game = _game('old-game', status: 'CANCELLED', past: true);
    final queue = _Queue(detail: _detail(game));
    await _openActivity(tester, queue, _notice('OPEN_QUEUE_GAME', game.id));
    final screen = tester.widget<FixtureDetailScreen>(
      find.byType(FixtureDetailScreen),
    );
    expect(screen.fixture.id, game.id);
    expect(screen.fixture.isCancelled, isTrue);
    expect(screen.sourceLabel, 'SOLO');
    expect(queue.detailRequests, everyElement(game.id));
    expect(find.byType(OpenQueueReviewScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('game activity opens details even when that game is bookable', (
    tester,
  ) async {
    final game = _game('available');
    final queue = _Queue(games: [game], detail: _detail(game));
    await _openActivity(tester, queue, _notice('OPEN_QUEUE_GAME', game.id));
    expect(find.byType(FixtureDetailScreen), findsOneWidget);
    expect(queue.detailRequests, isNotEmpty);
    expect(find.byType(OpenQueueReviewScreen), findsNothing);
  });

  testWidgets('clan activity fetches a fixture absent from the Home feed', (
    tester,
  ) async {
    final fixture = _fixture('old-fixture');
    final fixtures = _Fixtures(detail: fixture);
    await _openActivity(
      tester,
      _Queue(),
      _notice('FIXTURE', fixture.id),
      fixtures: fixtures,
    );
    expect(
      tester
          .widget<FixtureDetailScreen>(find.byType(FixtureDetailScreen))
          .fixture
          .id,
      fixture.id,
    );
    expect(fixtures.requests, isNotEmpty);
    expect(fixtures.requests, everyElement(fixture.id));
  });

  testWidgets(
    'fixture entity type wins over a same-ID booking and uses the loaded fixture',
    (tester) async {
      final fixture = _fixture('shared-id');
      final fixtures = _Fixtures(detail: fixture, feed: [fixture]);
      final queue = _Queue(bookings: [_booking(_game(fixture.id))]);
      await _openActivity(
        tester,
        queue,
        _notice('FIXTURE', fixture.id),
        fixtures: fixtures,
      );
      expect(find.byType(OpenQueueBookingScreen), findsNothing);
      final screen = tester.widget<FixtureDetailScreen>(
        find.byType(FixtureDetailScreen),
      );
      expect(screen.fixture, same(fixture));
      expect(screen.sourceLabel, isNull);
      // Only the detail screen's quiet refresh fetches; routing uses the cache.
      expect(fixtures.requests, [fixture.id]);
      expect(queue.detailRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reliability incident activity uses its fixture payload ID', (
    tester,
  ) async {
    final fixture = _fixture('incident-fixture');
    final fixtures = _Fixtures(detail: fixture);
    await _openActivity(
      tester,
      _Queue(),
      _notice(
        'CLAN_RELIABILITY_INCIDENT',
        'incident-id',
        data: {'fixture_id': fixture.id},
      ),
      fixtures: fixtures,
    );
    expect(
      tester
          .widget<FixtureDetailScreen>(find.byType(FixtureDetailScreen))
          .fixture
          .id,
      fixture.id,
    );
    expect(fixtures.requests, everyElement(fixture.id));
  });

  testWidgets(
    'unsupported activity shows the full message despite ID collision',
    (tester) async {
      final game = _game('same-id');
      final queue = _Queue(bookings: [_booking(game)], games: [game]);
      final notice = _notice(
        'SUPPORT_TICKET',
        game.id,
        data: {'game_id': game.id},
      );
      await _openActivity(tester, queue, notice);
      expect(
        find.byKey(const Key('home-notification-details')),
        findsOneWidget,
      );
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect((dialog.title! as Text).data, notice.title);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        notice.body,
      );
      expect(find.byType(OpenQueueBookingScreen), findsNothing);
      expect(find.byType(FixtureDetailScreen), findsNothing);
      expect(queue.detailRequests, isEmpty);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-notification-details')), findsNothing);
    },
  );

  testWidgets('malformed party activity still displays its full message', (
    tester,
  ) async {
    await _openActivity(
      tester,
      _Queue(),
      _notice('OPEN_QUEUE_PARTY_MEMBERSHIP', 'membership'),
    );
    expect(find.byKey(const Key('home-notification-details')), findsOneWidget);
    expect(find.byType(OpenQueueBookingScreen), findsNothing);
  });

  for (final type in ['OPEN_QUEUE_GAME', 'FIXTURE']) {
    testWidgets(
      '$type fetch errors show feedback instead of silently doing nothing',
      (tester) async {
        await _openActivity(
          tester,
          _Queue(),
          _notice(type, 'missing'),
          fixtures: _Fixtures(),
        );
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.textContaining('Could not open'), findsOneWidget);
        expect(find.byType(FixtureDetailScreen), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'read receipt failure never blocks the notification destination',
    (tester) async {
      final game = _game('booked');
      await _openActivity(
        tester,
        _Queue(bookings: [_booking(game)]),
        _notice('OPEN_QUEUE_GAME', game.id),
        readFails: true,
      );
      expect(find.byType(OpenQueueBookingScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _openActivity(
  WidgetTester tester,
  _Queue queue,
  HomeNotification item, {
  _Fixtures? fixtures,
  bool readFails = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final discovery = _Discovery(item, readFails: readFails);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DashboardHome(
          profileRepository: _Profiles(),
          clanRepository: _Clans(),
          fixtureRepository: fixtures ?? _Fixtures(),
          leaderboardRepository: _Ranks(),
          openQueueRepository: queue,
          discoveryRepository: discovery,
          onOpenClans: () {},
          onOpenFixtures: () {},
          onOpenRanks: () {},
          onOpenProfile: () {},
          onNavigateTab: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  tester
      .widget<FieldrushHomeHeader>(find.byType(FieldrushHomeHeader))
      .onActivity();
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('home-notification-${item.id}')));
  await tester.pumpAndSettle();
  expect(discovery.readIds, [item.id]);
}

HomeNotification _notice(
  String type,
  String id, {
  Map<String, dynamic> data = const {},
}) => HomeNotification(
  id: 'notification',
  title: 'A complete activity title',
  body:
      'The full notification body is available here, including all of its details.',
  createdAt: DateTime.utc(2026, 10, 10),
  entityType: type,
  entityId: id,
  data: data,
);

Map<String, dynamic> _notificationJson({
  required String type,
  required String id,
  Object? data,
}) => {
  'id': 'notification',
  'title': 'Activity',
  'body': 'Complete message',
  'created_at': '2026-10-10T12:00:00Z',
  'read_at': null,
  'related_entity_type': type,
  'related_entity_id': id,
  'data': data,
};

SupabaseClient _client(
  List<http.Request> requests,
  Object Function(http.Request) response,
) => SupabaseClient(
  'https://fieldrush-tests.invalid',
  'test-anon-key-not-a-secret',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
  httpClient: MockClient((request) async {
    requests.add(request);
    return http.Response(
      jsonEncode(response(request)),
      200,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }),
);

final _session = {
  'access_token': 'test-access-token',
  'token_type': 'bearer',
  'expires_in': 3600,
  'refresh_token': 'test-refresh-token',
  'user': {
    'id': 'profile',
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': '',
    'phone': '',
    'created_at': '2026-10-10T12:00:00Z',
    'app_metadata': {},
    'user_metadata': {},
  },
};

OpenQueueGame _game(String id, {String status = 'OPEN', bool past = false}) =>
    OpenQueueGame(
      id: id,
      status: status,
      venue: 'Phoenix Sports Park',
      startsAt: DateTime.now().add(Duration(days: past ? -2 : 2)),
      endsAt: DateTime.now().add(Duration(days: past ? -2 : 2, hours: 1)),
      timezone: 'America/Phoenix',
      currency: 'USD',
      priceFils: 13000,
      ageLabel: '18+',
      capacity: 14,
      confirmedCount: 8,
      spots: const {
        OpenQueueRole.goalkeeper: 1,
        OpenQueueRole.defender: 3,
        OpenQueueRole.attacker: 2,
      },
    );

OpenQueueBooking _booking(OpenQueueGame game) => OpenQueueBooking(
  id: 'booking-${game.id}',
  gameId: game.id,
  profileId: 'profile',
  role: OpenQueueRole.defender,
  status: 'CONFIRMED',
  amountPaidFils: game.priceFils,
  bookedAt: DateTime.now(),
  game: game,
);

OpenQueueMatchDetail _detail(OpenQueueGame game) =>
    OpenQueueMatchDetail(game: game, scorers: const [], timeline: const []);

Fixture _fixture(String id) => Fixture(
  id: id,
  status: FixtureStatus.finalResult,
  homeClanId: 'clan',
  venue: 'Legacy Stadium',
  day: 'Tuesday',
  timeSlot: '7:00 PM - 8:00 PM',
  matchDate: DateTime(2026, 1, 6),
  createdBy: 'profile',
  homeClan: const FixtureClan(
    id: 'clan',
    name: 'Falcons',
    tag: 'FLC',
    emblem: '⚽',
    themeId: 'pitch',
    patternId: 'solid',
    skillRating: 1200,
  ),
);

const _profile = PlayerProfile(
  id: 'profile',
  displayName: 'Dana A.',
  username: 'dana',
  bio: '',
  followingCount: 0,
  fansCount: 0,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: [],
  career: [],
);

class _Profiles extends Fake implements ProfileRepository {
  @override
  Future<PlayerProfile> getCurrentProfile() async => _profile;
}

class _Clans extends Fake implements ClanRepository {
  @override
  Future<List<Clan>> listClans() async => [];
  @override
  Future<ClanMembership?> getMyClanMembership() async => null;
}

class _Ranks extends Fake implements LeaderboardRepository {
  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async => const PlayerRatingLeaderboardEntry(
    rank: 0,
    profileId: 'profile',
    displayName: 'Dana A.',
    username: 'dana',
    skillRating: 1200,
    matchesPlayed: 0,
    wins: 0,
    losses: 0,
    draws: 0,
    lastChange: 0,
    region: 'phoenix',
  );
}

class _Queue extends Fake implements OpenQueueRepository {
  _Queue({this.bookings = const [], this.games = const [], this.detail});
  final List<OpenQueueBooking> bookings;
  final List<OpenQueueGame> games;
  final OpenQueueMatchDetail? detail;
  final detailRequests = <String>[];
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => bookings;
  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async =>
      bookings.firstOrNull;
  @override
  Future<List<OpenQueueGame>> listGames() async => games;
  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => [];
  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String id) async {
    detailRequests.add(id);
    if (detail == null) throw Exception('internal server error');
    return detail!;
  }
}

class _Fixtures extends Fake implements FixtureRepository {
  _Fixtures({this.detail, this.feed = const []});
  final Fixture? detail;
  final List<Fixture> feed;
  final requests = <String>[];
  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;
  @override
  Future<List<Fixture>> listFixtures() async => feed;
  @override
  Future<Fixture> getFixture(String id) async {
    requests.add(id);
    if (detail == null) throw Exception('internal server error');
    return detail!;
  }
}

class _Discovery implements HomeDiscoveryRepository {
  _Discovery(this.item, {required this.readFails});
  final HomeNotification item;
  final bool readFails;
  final readIds = <String>[];
  @override
  Future<List<HomePlayerResult>> searchPlayers(String query) async => [
    const HomePlayerResult(id: 'found-player', name: 'Dana', username: 'dana'),
  ];
  @override
  Future<List<HomeNotification>> notifications() async => [item];
  @override
  Future<void> markRead(String id) async {
    readIds.add(id);
    if (readFails) throw Exception('test read receipt failed');
  }
}
