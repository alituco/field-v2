import 'dart:async';

import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/home/activity_revision.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/home/home_discovery_repository.dart';
import 'package:field/src/home/home_discovery_screen.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/leaderboard/fieldrush_seasons.dart';
import 'package:field/src/markets/fieldrush_city.dart';
import 'package:field/src/markets/fieldrush_city_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/fieldrush_booking_flow.dart';
import 'package:field/src/open_queue/fieldrush_checkout_sheet.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/helpers/staging_test_helpers.dart';

void main() {
  setUp(clearFieldrushActivityOpenRequest);
  tearDown(clearFieldrushActivityOpenRequest);

  testWidgets('a cold push tap opens canonical Activity after Home mounts', (
    tester,
  ) async {
    requestFieldrushActivityOpen();
    await _pump(tester, _Queue(), discovery: _Discovery());
    expect(find.byType(HomeDiscoveryScreen), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(fieldrushActivityOpenRequested.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('push taps do not stack duplicate Activity screens', (
    tester,
  ) async {
    await _pump(tester, _Queue(), discovery: _Discovery());
    requestFieldrushActivityOpen();
    await tester.pumpAndSettle();
    requestFieldrushActivityOpen();
    await tester.pumpAndSettle();
    expect(find.byType(HomeDiscoveryScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(HomeDiscoveryScreen), findsNothing);
    expect(find.byType(DashboardHome), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Home Take a spot opens the game and Join goes straight to position checkout',
    (tester) async {
      final queue = _Queue(games: [_game('night')]);
      await _pump(tester, queue);
      final night = find.byKey(const ValueKey('home-open-night-night'));
      await tester.ensureVisible(night);
      await tester.tap(night);
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('game-main-action')),
      );
      await tester.tap(find.byKey(const ValueKey('game-main-action')));
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushCheckoutSheet), findsOneWidget);
      expect(find.byType(FieldrushBookingFlow), findsNothing);
      expect(find.text('Pay for your spot'), findsOneWidget);
      expect(find.text('Pick a position'), findsOneWidget);
      expect(
        tester
            .widget<FieldrushCheckoutSheet>(find.byType(FieldrushCheckoutSheet))
            .role,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
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
    'cancelled games stay excluded and unresolved games show a nonbooking notice',
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
        find.byKey(const ValueKey('home-live-game-cancelled')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-live-game-missing')),
        findsOneWidget,
      );
      expect(find.text('No data'), findsOneWidget);
      expect(find.textContaining('You can book another game'), findsOneWidget);
      expect(noData.supportedRoles.any(noData.canBook), isFalse);
      expect(cancelled.isActiveReservation, isFalse);
      expect(noData.blocksNewBooking, isFalse);
    },
  );

  testWidgets(
    'a live booked game stays accessible when the booking lookup fails',
    (tester) async {
      await _pump(
        tester,
        _Queue(
          bookingsFail: true,
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

  testWidgets(
    'View invitation opens the invited game and exposes its response controls',
    (tester) async {
      final invitedBooking = _booking(_game('invited', days: 3));
      final repo = _Invites(
        bookings: [_booking(_game('first')), invitedBooking],
      );
      await _pump(tester, repo);
      final alert = find.byKey(const ValueKey('home-party-invite-invited'));
      // Use the same scoped action finder as the hosted journey. The card's
      // container is hit-testable, but only this button opens the booking.
      await tapAfterScroll(
        tester,
        find.descendant(of: alert, matching: find.byType(FilledButton)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
      expect(
        tester
            .widget<FieldrushGameDetailScreen>(
              find.byType(FieldrushGameDetailScreen),
            )
            .gameId,
        invitedBooking.gameId,
      );
      await tester.scrollUntilVisible(find.text('Accept'), 250);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.textContaining('Sami'), findsWidgets);
      expect(tester.takeException(), isNull);
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
    expect(find.text('No player @Dana'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    tester
        .widget<FieldrushHomeHeader>(find.byType(FieldrushHomeHeader))
        .onActivity();
    await tester.pumpAndSettle();
    expect(find.text("You're all caught up."), findsOneWidget);
  });

  testWidgets(
    'a booked invitation opens while season, city, fixtures and activity remain pending',
    (tester) async {
      final ranks = _PendingSeasons();
      final city = _PendingCity();
      final fixtures = _PendingFixtures();
      final discovery = _PendingDiscovery();
      final invited = _booking(_game('invited'));
      final queue = _Invites(bookings: [invited]);
      await _pump(
        tester,
        queue,
        ranks: ranks,
        city: city,
        fixtures: fixtures,
        discovery: discovery,
      );

      expect(find.byType(FieldrushHomeHeader), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-solo-booking-booking-invited')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-loading-skeleton')), findsNothing);
      await tapAfterScroll(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('home-party-invite-invited')),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
      expect(
        tester
            .widget<FieldrushGameDetailScreen>(
              find.byType(FieldrushGameDetailScreen),
            )
            .gameId,
        invited.gameId,
      );
      await tester.scrollUntilVisible(find.text('Accept'), 250);
      expect(find.text('Accept'), findsOneWidget);

      // These never completed while the real invitation was opened. Resolve
      // only after assertions to retire their bounded-read timers in the test.
      ranks.pending.complete(_catalog());
      city.pending.complete(FieldrushCity.phoenix);
      fixtures.pending.complete([]);
      discovery.pending.complete([]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('slow rating and profile history do not gate core Home data', (
    tester,
  ) async {
    final ranks = _PendingRating();
    final profiles = _SummaryProfiles();
    await _pump(
      tester,
      _Invites(bookings: [_booking(_game('invited'))]),
      ranks: ranks,
      profiles: profiles,
    );
    expect(profiles.summaryReads, 1);
    expect(profiles.fullReads, 0);
    expect(find.byType(FieldrushHomeHeader), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('fieldrush-home-scroll')),
      const Offset(0, -650),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('home-party-invite-invited')),
      findsOneWidget,
    );
    ranks.pending.complete(
      await _Ranks(false).loadCurrentPlayerRating(activeLeaderboardSeason),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late responses from an older Home refresh never replace newer sections',
    (tester) async {
      final oldProfile = Completer<PlayerProfile>();
      final newProfile = Completer<PlayerProfile>();
      final oldBookings = Completer<List<OpenQueueBooking>>();
      final newBookings = Completer<List<OpenQueueBooking>>();
      final profiles = _ControlledProfiles([
        oldProfile.future,
        newProfile.future,
      ]);
      final queue = _ControlledBookings([
        oldBookings.future,
        newBookings.future,
      ]);
      await _pump(tester, queue, profiles: profiles);
      await _pump(tester, queue, profiles: profiles, tick: 1);
      newProfile.complete(
        const PlayerProfile(
          id: 'profile',
          displayName: 'Newer Player',
          username: 'newer',
          bio: '',
          followingCount: 0,
          fansCount: 0,
          appearances: 0,
          goals: 0,
          assists: 0,
          highlights: [],
          career: [],
        ),
      );
      newBookings.complete([_booking(_game('newer'))]);
      await tester.pumpAndSettle();
      expect(find.textContaining('Newer'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-solo-booking-booking-newer')),
        findsOneWidget,
      );
      oldProfile.complete(_profile);
      oldBookings.complete([_booking(_game('older'))]);
      await tester.pumpAndSettle();
      expect(find.textContaining('Newer'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-solo-booking-booking-newer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-solo-booking-booking-older')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('refresh failures retain an existing booking and invitation', (
    tester,
  ) async {
    final queue = _FailingRefreshInvites(
      bookings: [_booking(_game('invited'))],
    );
    final profiles = _FailingRefreshProfiles();
    await _pump(tester, queue, profiles: profiles);
    queue.fails = true;
    profiles.fails = true;
    await _pump(tester, queue, profiles: profiles, tick: 1);
    expect(find.byType(FieldrushHomeHeader), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-solo-booking-booking-invited')),
      findsOneWidget,
    );
    await tester.drag(
      find.byKey(const Key('fieldrush-home-scroll')),
      const Offset(0, -650),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('home-party-invite-invited')),
      findsOneWidget,
    );
    expect(find.textContaining('Could not refresh'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-loading-skeleton')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a stalled core profile read ends in a retryable error, never an endless skeleton',
    (tester) async {
      final pending = Completer<PlayerProfile>();
      await _pump(
        tester,
        _Queue(),
        profiles: _ControlledProfiles([pending.future, Future.value(_profile)]),
      );
      expect(
        find.byKey(const ValueKey('home-loading-skeleton')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-loading-skeleton')), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.textContaining('your profile'), findsOneWidget);
      pending.complete(_profile);
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushHomeHeader), findsNothing);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushHomeHeader), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a stalled booking read reports an error and ignores a late response',
    (tester) async {
      final pending = Completer<List<OpenQueueBooking>>();
      await _pump(tester, _ControlledBookings([pending.future]));
      expect(find.byType(FieldrushHomeHeader), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('fieldrush-home-scroll')),
        const Offset(0, -650),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not refresh bookings'), findsOneWidget);
      pending.complete([_booking(_game('late'))]);
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushSoloHero), findsNothing);
      expect(find.byKey(const ValueKey('home-loading-skeleton')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Queue queue, {
  int tick = 0,
  bool ratingFails = false,
  PlayerProfile profile = _profile,
  HomeDiscoveryRepository? discovery,
  ProfileRepository? profiles,
  LeaderboardRepository? ranks,
  FieldrushCityRepository? city,
  FixtureRepository? fixtures,
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
          profileRepository: profiles ?? _Profiles(profile),
          clanRepository: _Clans(),
          fixtureRepository: fixtures ?? _Fixtures(),
          leaderboardRepository: ranks ?? _Ranks(ratingFails),
          cityRepository: city,
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

class _SummaryProfiles extends _Profiles implements ProfileSummaryRepository {
  _SummaryProfiles() : super(_profile);
  int summaryReads = 0;
  int fullReads = 0;
  @override
  Future<PlayerProfile> getCurrentProfileSummary() async {
    summaryReads++;
    return profile;
  }

  @override
  Future<PlayerProfile> getCurrentProfile() {
    fullReads++;
    throw StateError('Full profile history must not be requested by Home.');
  }
}

class _ControlledProfiles extends _Profiles {
  _ControlledProfiles(this.responses) : super(_profile);
  final List<Future<PlayerProfile>> responses;
  @override
  Future<PlayerProfile> getCurrentProfile() => responses.removeAt(0);
}

class _FailingRefreshProfiles extends _Profiles {
  _FailingRefreshProfiles() : super(_profile);
  bool fails = false;
  @override
  Future<PlayerProfile> getCurrentProfile() async {
    if (fails) throw StateError('Profile temporarily unavailable');
    return profile;
  }
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

class _PendingSeasons extends _Ranks implements SeasonLeaderboardRepository {
  _PendingSeasons() : super(false);
  final pending = Completer<FieldrushSeasonCatalog>();
  @override
  Future<FieldrushSeasonCatalog> loadSeasons() => pending.future;
}

class _PendingRating extends _Ranks {
  _PendingRating() : super(false);
  final pending = Completer<PlayerRatingLeaderboardEntry>();
  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) => pending.future;
}

FieldrushSeasonCatalog _catalog() => FieldrushSeasonCatalog(
  seasons: [activeLeaderboardSeason],
  currentSeasonId: activeLeaderboardSeason.id,
  today: DateTime.parse(activeLeaderboardSeason.startsOn),
);

class _PendingCity extends Fake implements FieldrushCityRepository {
  final pending = Completer<FieldrushCity>();
  @override
  Future<FieldrushCity> loadPreferredCity() => pending.future;
}

class _PendingFixtures extends _Fixtures {
  final pending = Completer<List<Fixture>>();
  @override
  Future<List<Fixture>> listFixtures() => pending.future;
}

class _PendingDiscovery extends _Discovery {
  final pending = Completer<List<HomeNotification>>();
  @override
  Future<List<HomeNotification>> notifications() => pending.future;
}

class _Queue extends Fake implements OpenQueueRepository {
  _Queue({
    this.bookings = const [],
    this.games = const [],
    this.fixtures = const [],
    this.bookingsFail = false,
  });
  List<OpenQueueBooking> bookings;
  List<OpenQueueGame> games;
  List<OpenQueueGame> fixtures;
  final bool bookingsFail;
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async {
    if (bookingsFail) throw StateError('Bookings temporarily unavailable');
    return bookings;
  }

  @override
  Future<List<OpenQueueGame>> listGames() async => games;
  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => fixtures;
  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async =>
      OpenQueueMatchDetail(
        game: [
          ...games,
          ...fixtures,
          ...bookings.map((booking) => booking.game),
        ].firstWhere((game) => game.id == gameId),
        scorers: const [],
        timeline: const [],
      );
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

class _ControlledBookings extends _Queue {
  _ControlledBookings(this.responses);
  final List<Future<List<OpenQueueBooking>>> responses;
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() =>
      responses.removeAt(0);
}

class _FailingRefreshInvites extends _Invites {
  _FailingRefreshInvites({super.bookings});
  bool fails = false;
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async {
    if (fails) throw StateError('Bookings temporarily unavailable');
    return bookings;
  }

  @override
  Future<OpenQueuePartyContext> getPartyContext(String id) {
    if (fails) throw StateError('Invitations temporarily unavailable');
    return super.getPartyContext(id);
  }
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
  @override
  Future<void> dismiss(String id) async {}
}
