import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/home/home_discovery_repository.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'empty Home shows the reference position picker and placement card',
    (tester) async {
      await _pump(tester, _Queue());
      expect(find.byType(FieldrushHomeHeader), findsOneWidget);
      expect(find.byType(FieldrushQuickGameCard), findsOneWidget);
      expect(find.byType(FieldrushHomeRating), findsOneWidget);
      expect(find.byType(FieldrushSoloHero), findsNothing);
      expect(find.textContaining('Dana'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'confirmed booking replaces discovery and preserves the E2E booking key',
    (tester) async {
      await _pump(tester, _Queue(bookings: [_booking(_game('first'))]));
      expect(
        find.byKey(const ValueKey('home-solo-booking-booking-first')),
        findsOneWidget,
      );
      expect(find.byType(FieldrushQuickGameCard), findsNothing);
      final hero = tester.widget<FieldrushSoloHero>(
        find.byType(FieldrushSoloHero),
      );
      expect(hero.booking.game.capacity, 14);
      expect(hero.booking.assignedTeam, isNull);
      expect(find.textContaining('Streak'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bookings are sorted and later games use the compact also-booked row',
    (tester) async {
      final later = _booking(_game('later', days: 3));
      final earlier = _booking(_game('earlier', days: 1));
      await _pump(tester, _Queue(bookings: [later, earlier]));
      expect(
        tester
            .widget<FieldrushSoloHero>(find.byType(FieldrushSoloHero))
            .booking
            .id,
        earlier.id,
      );
      expect(
        find.byKey(const ValueKey('home-also-booked-later')),
        findsOneWidget,
      );
      expect(find.byType(FieldrushSoloHero), findsOneWidget);
    },
  );

  testWidgets('reactivating Home reloads a newly made booking', (tester) async {
    final repo = _Queue();
    await _pump(tester, repo);
    expect(find.byType(FieldrushQuickGameCard), findsOneWidget);
    repo.bookings = [_booking(_game('new'))];
    await _pump(tester, repo, tick: 1);
    expect(
      find.byKey(const ValueKey('home-solo-booking-booking-new')),
      findsOneWidget,
    );
    expect(find.byType(FieldrushQuickGameCard), findsNothing);
  });

  testWidgets(
    'cancelled or unresolved games never become bookable Home heroes',
    (tester) async {
      final cancelled = _game('cancelled', status: 'CANCELLED');
      final noData = _game('missing', state: MatchOperationalState.noData);
      await _pump(
        tester,
        _Queue(
          bookings: [_booking(cancelled), _booking(noData)],
          games: [cancelled, noData],
        ),
      );
      expect(find.byType(FieldrushSoloHero), findsNothing);
      expect(
        tester
            .widget<FieldrushQuickGameCard>(find.byType(FieldrushQuickGameCard))
            .games,
        isEmpty,
      );
    },
  );

  testWidgets(
    'a currently live booked game stays accessible after upcoming API stops returning it',
    (tester) async {
      await _pump(
        tester,
        _Queue(
          fixtures: [_game('live', status: 'LIVE', bookingId: 'live-booking')],
        ),
      );
      expect(find.byKey(const ValueKey('home-live-game-live')), findsOneWidget);
      expect(find.text('Your game is live'), findsOneWidget);
      expect(find.byType(FieldrushQuickGameCard), findsNothing);
    },
  );

  testWidgets('noncritical ranking failure does not hide a confirmed booking', (
    tester,
  ) async {
    await _pump(
      tester,
      _Queue(bookings: [_booking(_game('safe'))]),
      ratingFails: true,
      profile: _profileWithLifetimeRating,
    );
    expect(
      find.byKey(const ValueKey('home-solo-booking-booking-safe')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('home-rating-unavailable')), findsOneWidget);
    expect(find.byType(FieldrushHomeRating), findsNothing);
    expect(find.textContaining('Placement'), findsNothing);
    expect(find.textContaining('1700'), findsNothing);
    expect(
      tester
          .widget<FieldrushHomeHeader>(find.byType(FieldrushHomeHeader))
          .ratingUnavailable,
      isTrue,
    );
    await tester.drag(
      find.byKey(const Key('fieldrush-home-scroll')),
      const Offset(0, -700),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not refresh rating'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home requests Phoenix discovery before the server feed limit', (
    tester,
  ) async {
    final game = _game('phoenix-market');
    final queue = _MarketQueue(game);
    await _pump(tester, queue);
    expect(queue.markets, ['America/Phoenix']);
    expect(queue.allMarketCalls, 0);
    expect(
      tester
          .widget<FieldrushQuickGameCard>(find.byType(FieldrushQuickGameCard))
          .games,
      [game],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'booked games are excluded from discovery options even if listGames includes them',
    (tester) async {
      final game = _game('booked', bookingId: 'existing');
      await _pump(tester, _Queue(games: [game]));
      expect(
        tester
            .widget<FieldrushQuickGameCard>(find.byType(FieldrushQuickGameCard))
            .games,
        isEmpty,
      );
    },
  );

  testWidgets(
    'party invitation for a later game is not lost behind the first booking',
    (tester) async {
      final repo = _Invites(
        bookings: [
          _booking(_game('first')),
          _booking(_game('invited', days: 3)),
        ],
      );
      await _pump(tester, repo);
      await tester.drag(
        find.byKey(const Key('fieldrush-home-scroll')),
        const Offset(0, -650),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-party-invite-invited')),
        findsOneWidget,
      );
      expect(find.textContaining('Sami invited'), findsOneWidget);
    },
  );

  testWidgets('header search works and empty activity is honest', (
    tester,
  ) async {
    final discovery = _Discovery();
    await _pump(tester, _Queue(), discovery: discovery);
    tester
        .widget<FieldrushHomeHeader>(find.byType(FieldrushHomeHeader))
        .onSearch();
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('home-player-search')), 'Dana');
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pumpAndSettle();
    expect(discovery.query, 'Dana');
    expect(find.text('No players found'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    tester
        .widget<FieldrushHomeHeader>(find.byType(FieldrushHomeHeader))
        .onActivity();
    await tester.pumpAndSettle();
    expect(find.text('You’re all caught up'), findsOneWidget);
  });
}

Future<void> _pump(
  WidgetTester tester,
  _Queue queue, {
  int tick = 0,
  bool ratingFails = false,
  PlayerProfile profile = _profile,
  HomeDiscoveryRepository? discovery,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DashboardHome(
          activationTick: tick,
          profileRepository: _Profiles(profile),
          clanRepository: _Clans(),
          fixtureRepository: _Fixtures(),
          leaderboardRepository: _Ranks(ratingFails),
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
}

OpenQueueGame _game(
  String id, {
  int days = 2,
  String status = 'OPEN',
  String? bookingId,
  MatchOperationalState state = MatchOperationalState.normal,
}) => OpenQueueGame(
  id: id,
  status: status,
  venue: 'Phoenix Sports Park',
  startsAt: DateTime.now().add(Duration(days: days)),
  endsAt: DateTime.now().add(Duration(days: days, hours: 1)),
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
  myBookingId: bookingId,
  operationalState: state,
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

const _profileWithLifetimeRating = PlayerProfile(
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
  playerRating: ProfilePlayerRating(
    skillRating: 1700,
    matchesPlayed: 60,
    wins: 40,
    losses: 10,
    draws: 10,
    lastChange: 20,
    region: 'phoenix',
    events: [],
  ),
);

class _Profiles extends Fake implements ProfileRepository {
  _Profiles(this.profile);
  final PlayerProfile profile;
  @override
  Future<PlayerProfile> getCurrentProfile() async => profile;
}

class _Ranks extends Fake implements LeaderboardRepository {
  _Ranks(this.fails);
  final bool fails;
  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async {
    if (fails) throw Exception('offline');
    return const PlayerRatingLeaderboardEntry(
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
}

class _Queue extends Fake implements OpenQueueRepository {
  _Queue({
    this.bookings = const [],
    this.games = const [],
    this.fixtures = const [],
  });
  List<OpenQueueBooking> bookings;
  List<OpenQueueGame> games;
  List<OpenQueueGame> fixtures;
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => bookings;
  @override
  Future<List<OpenQueueGame>> listGames() async => games;
  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => fixtures;
}

class _Invites extends _Queue implements OpenQueuePartyRepository {
  _Invites({super.bookings});
  @override
  Future<OpenQueuePartyContext> getPartyContext(String id) async =>
      OpenQueuePartyContext.fromJson({
        'game_id': id,
        'game_status': 'OPEN',
        'can_use_parties': true,
        'max_party_size': 4,
        'received_invites': id != 'invited'
            ? []
            : [
                {
                  'id': 'membership',
                  'party_id': 'party',
                  'owner': {
                    'profile_id': 'sami',
                    'display_name': 'Sami',
                    'username': 'sami',
                    'role': 'DEF',
                  },
                },
              ],
      });
}

class _MarketQueue extends _Queue implements OpenQueueMarketRepository {
  _MarketQueue(this.game);
  final OpenQueueGame game;
  final markets = <String>[];
  int allMarketCalls = 0;
  @override
  Future<List<OpenQueueGame>> listGames() async {
    allMarketCalls++;
    throw StateError('Home should use the market-filtered API');
  }

  @override
  Future<List<OpenQueueGame>> listMarketGames(String timezone) async {
    markets.add(timezone);
    return [game];
  }
}

class _Clans extends Fake implements ClanRepository {
  @override
  Future<List<Clan>> listClans() async => [];
  @override
  Future<ClanMembership?> getMyClanMembership() async => null;
}

class _Fixtures extends Fake implements FixtureRepository {
  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;
  @override
  Future<List<Fixture>> listFixtures() async => [];
}

class _Discovery implements HomeDiscoveryRepository {
  String? query;
  @override
  Future<List<HomePlayerResult>> searchPlayers(String value) async {
    query = value;
    return [];
  }

  @override
  Future<List<HomeNotification>> notifications() async => [];
  @override
  Future<void> markRead(String id) async {}
}
