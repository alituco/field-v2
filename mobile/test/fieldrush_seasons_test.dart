import 'dart:convert';

import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/leaderboard/fieldrush_leaderboard_widgets.dart';
import 'package:field/src/leaderboard/fieldrush_rating_tracks.dart';
import 'package:field/src/leaderboard/fieldrush_seasons.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/leaderboard/leaderboard_screen.dart';
import 'package:field/src/markets/fieldrush_city.dart';
import 'package:field/src/markets/fieldrush_city_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/fieldrush_you_screen.dart';
import 'package:field/src/profile/fieldrush_you_settings.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'live season repository reads the server catalog and market day',
    () async {
      final client = SupabaseClient(
        'https://fieldrush-test.invalid',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/rest/v1/rpc/list_fieldrush_seasons');
          return http.Response(
            jsonEncode({
              'today': '2027-02-20',
              'current_season_id': 's2',
              'seasons': [
                _seasonJson('s2', '2027-01-10', '2027-03-28'),
                _seasonJson('s3', '2027-04-01', '2027-06-30'),
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final catalog = await SupabaseLeaderboardRepository(
        client: client,
      ).loadSeasons();
      expect(catalog.currentSeason.startsOn, '2027-01-10');
      expect(catalog.currentSeason.endsOn, '2027-03-28');
      expect(catalog.visibleSeasons.map((s) => s.id), ['s2']);
    },
  );

  test('server seasons preserve admin dates and prize minimum separately', () {
    final season = LeaderboardSeason.fromJson({
      'id': 's8',
      'label': 'S8',
      'starts_on': '2028-11-03',
      'ends_on': '2029-02-17',
      'minimum_rated_games': 5,
    });
    expect(season.fullLabel, 'Season 8');
    expect(season.rangeLabel, 'Nov 2028 - Feb 2029');
    expect(season.startsOn, '2028-11-03');
    expect(season.endsOn, '2029-02-17');
    expect(season.minimumRatedGames, 5);
    expect(minimumPlayerLeaderboardMatches, 2);
  });

  test('catalog uses the server current ID and excludes future ladders', () {
    final catalog = FieldrushSeasonCatalog.fromJson({
      'current_season_id': 'custom',
      'seasons': [
        _seasonJson('next', '2027-02-01', '2027-04-30'),
        _seasonJson('custom', '2026-11-01', '2027-01-31'),
        _seasonJson('old', '2026-08-01', '2026-10-31'),
      ],
    }, today: DateTime.utc(2026, 12, 1));
    expect(catalog.currentSeason.id, 'custom');
    expect(catalog.currentSeason.fullLabel, 'custom');
    expect(catalog.visibleSeasons.map((s) => s.id), ['old', 'custom']);
    expect(catalog.seasons.map((s) => s.id), ['old', 'custom', 'next']);
  });

  test('a gap shows the last real season, never a fabricated quarter', () {
    final catalog = FieldrushSeasonCatalog.fromJson({
      'current_season_id': null,
      'seasons': [
        _seasonJson('old', '2026-06-01', '2026-08-12'),
        _seasonJson('next', '2026-11-01', '2027-01-31'),
      ],
    }, today: DateTime.utc(2026, 10, 13));
    expect(catalog.currentSeason.id, 'old');
    expect(catalog.visibleSeasons.map((s) => s.id), ['old']);
  });

  test('server day overrides a skewed device clock for visible seasons', () {
    final catalog = FieldrushSeasonCatalog.fromJson({
      'today': '2027-02-20',
      'current_season_id': 'current',
      'seasons': [
        _seasonJson('past', '2026-09-01', '2026-12-31'),
        _seasonJson('current', '2027-01-01', '2027-03-31'),
        _seasonJson('future', '2027-04-01', '2027-06-30'),
      ],
    }, today: DateTime.utc(2030, 1, 1));
    expect(catalog.currentSeason.id, 'current');
    expect(catalog.visibleSeasons.map((s) => s.id), ['past', 'current']);
  });

  test('future-only and invalid current catalogs do not invent a season', () {
    final future = FieldrushSeasonCatalog.fromJson({
      'seasons': [_seasonJson('future', '2027-01-01', '2027-03-31')],
    }, today: DateTime.utc(2026, 10, 13));
    expect(() => future.currentSeason, throwsStateError);
    final invalid = FieldrushSeasonCatalog.fromJson({
      'current_season_id': 'missing',
      'seasons': [],
    });
    expect(() => invalid.currentSeason, throwsFormatException);
  });

  test('only repositories without a catalog use legacy fallback', () async {
    final legacy = await loadActiveLeaderboardSeason(Object());
    expect(legacy.id, activeLeaderboardSeason.id);
    final live = _Ratings();
    expect((await loadActiveLeaderboardSeason(live)).id, _serverSeason.id);
    live.failCatalog = true;
    await expectLater(loadActiveLeaderboardSeason(live), throwsStateError);
  });

  testWidgets('Home loads role statistics with the server season dates', (
    tester,
  ) async {
    final ratings = _Ratings();
    await _pump(
      tester,
      DashboardHome(
        profileRepository: _Profiles(),
        clanRepository: _Clans(),
        fixtureRepository: _Fixtures(),
        leaderboardRepository: ratings,
        openQueueRepository: _Queue(),
        onOpenClans: () {},
        onOpenFixtures: () {},
        onOpenRanks: () {},
        onOpenProfile: () {},
        onNavigateTab: (_) {},
      ),
    );
    expect(ratings.requested, [_serverSeason]);
    expect(
      find.text('Could not refresh rating. Pull down to try again.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('You loads role statistics with the server season dates', (
    tester,
  ) async {
    final ratings = _Ratings();
    await _pump(
      tester,
      FieldrushYouScreen(
        profileRepository: _Profiles(),
        leaderboardRepository: ratings,
        clanRepository: _Clans(),
        fixtureRepository: _Fixtures(),
        openQueueRepository: _Queue(),
        settingsRepository: _Settings(),
        onOpenAccount: () async {},
        onOpenRanks: () {},
        onSignOut: () async {},
      ),
    );
    expect(ratings.requested, [_serverSeason]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'public Profile loads role statistics with the server season dates',
    (tester) async {
      final ratings = _Ratings();
      await _pump(
        tester,
        ProfileScreen(
          profileId: 'me',
          profileRepository: _Profiles(),
          ratingRepository: ratings,
          clanRepository: _Clans(),
          fixtureRepository: _Fixtures(),
          openQueueRepository: _Queue(),
        ),
      );
      expect(ratings.requested, [_serverSeason]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed live catalog never queries guessed quarter statistics', (
    tester,
  ) async {
    final ratings = _Ratings()..failCatalog = true;
    await _pump(
      tester,
      FieldrushYouScreen(
        profileRepository: _Profiles(),
        leaderboardRepository: ratings,
        clanRepository: _Clans(),
        fixtureRepository: _Fixtures(),
        openQueueRepository: _Queue(),
        settingsRepository: _Settings(),
        onOpenAccount: () async {},
        onOpenRanks: () {},
        onSignOut: () async {},
      ),
    );
    expect(ratings.requested, isEmpty);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (
      name: 'earned city before preference',
      primary: 'phoenix',
      preferred: 'new-york',
      expected: 'phoenix',
    ),
    (
      name: 'preferred city before placement',
      primary: null,
      preferred: 'new-york',
      expected: 'new-york',
    ),
    (
      name: 'inactive earned city remains viewable',
      primary: 'new-york',
      preferred: 'phoenix',
      expected: 'new-york',
    ),
  ]) {
    testWidgets(
      'Ranks restores ${scenario.name} on reactivation, not refresh or role change',
      (tester) async {
        final ratings = _Ratings(
          primaryCityId: scenario.primary,
          preferredCityId: scenario.preferred,
        );
        final profiles = _Profiles();
        final cities = _Cities(
          newYorkActive:
              scenario.name != 'inactive earned city remains viewable',
        );
        Widget screen(int tick) => LeaderboardScreen(
          activationTick: tick,
          clanRepository: _Clans(),
          fixtureRepository: _Fixtures(),
          leaderboardRepository: ratings,
          profileRepository: profiles,
          cityRepository: cities,
        );
        await _pump(tester, screen(0));
        expect(ratings.pageScopes.single, (
          RatingTrack.outfield,
          scenario.expected,
        ));
        await tester.tap(find.byKey(const ValueKey('ranks-city')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Global').last);
        await tester.pumpAndSettle();
        expect(ratings.pageScopes.last, (RatingTrack.outfield, null));

        await tester.tap(find.text('Keepers'));
        await tester.pumpAndSettle();
        expect(ratings.pageScopes.last, (RatingTrack.goalkeeper, null));
        final beforeRefresh = ratings.pageScopes.length;
        await tester
            .widget<FieldrushLeaderboardContent>(
              find.byType(FieldrushLeaderboardContent),
            )
            .onRefresh();
        await tester.pumpAndSettle();
        expect(ratings.pageScopes.length, beforeRefresh + 1);
        expect(ratings.pageScopes.last, (RatingTrack.goalkeeper, null));

        await _pump(tester, screen(1));
        expect(ratings.pageScopes.last, (
          RatingTrack.goalkeeper,
          scenario.expected,
        ));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Map<String, Object> _seasonJson(String id, String start, String end) => {
  'id': id,
  'label': id,
  'starts_on': start,
  'ends_on': end,
};

Future<void> _pump(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: widget)));
  await tester.pumpAndSettle();
}

const _serverSeason = LeaderboardSeason(
  id: 'admin-season',
  label: 'S99',
  rangeLabel: 'Nov 2026 - Jan 2027',
  startsOn: '2026-11-09',
  endsOn: '2027-01-24',
  minimumRatedGames: 5,
);

class _Ratings extends Fake
    implements
        LeaderboardRepository,
        TrackLeaderboardRepository,
        SeasonLeaderboardRepository {
  _Ratings({this.primaryCityId = 'phoenix', this.preferredCityId});
  final String? primaryCityId, preferredCityId;
  bool failCatalog = false;
  final requested = <LeaderboardSeason>[];
  final pageScopes = <(RatingTrack, String?)>[];
  @override
  Future<FieldrushSeasonCatalog> loadSeasons() async {
    if (failCatalog) throw StateError('Catalog unavailable');
    return FieldrushSeasonCatalog(
      seasons: [_serverSeason],
      currentSeasonId: _serverSeason.id,
      today: DateTime.utc(2026, 11, 10),
    );
  }

  @override
  Future<FieldrushPlayerRatings> loadPlayerRatings({
    required LeaderboardSeason season,
    String? profileId,
  }) async {
    requested.add(season);
    return FieldrushPlayerRatings(
      outfield: _rating,
      goalkeeper: _rating,
      primaryCityId: primaryCityId,
      preferredCityId: preferredCityId,
    );
  }

  @override
  Future<PlayerRatingLeaderboardPage> loadRatingPage({
    required LeaderboardSeason season,
    required RatingTrack track,
    String? cityId,
    int offset = 0,
    int pageSize = 23,
  }) async {
    pageScopes.add((track, cityId));
    return const PlayerRatingLeaderboardPage(
      players: [],
      aroundMe: [],
      totalCount: 0,
      nextOffset: null,
    );
  }
}

class _Cities extends Fake implements FieldrushCityRepository {
  _Cities({this.newYorkActive = true});
  final bool newYorkActive;
  @override
  Future<List<FieldrushCity>> listCities() async => [
    FieldrushCity.phoenix,
    FieldrushCity(
      id: 'new-york',
      displayName: 'New York',
      state: 'NY',
      countryCode: 'US',
      timezone: 'America/New_York',
      active: newYorkActive,
    ),
  ];
}

const _rating = PlayerRatingLeaderboardEntry(
  rank: 0,
  profileId: 'me',
  displayName: 'Alex P.',
  username: 'alex',
  skillRating: 1200,
  matchesPlayed: 0,
  wins: 0,
  losses: 0,
  draws: 0,
  lastChange: 0,
  region: 'phoenix',
);

const _profile = PlayerProfile(
  id: 'me',
  displayName: 'Alex P.',
  username: 'alex',
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
  String get currentUserId => 'me';
  @override
  Future<PlayerProfile> getCurrentProfile() async => _profile;
  @override
  Future<PlayerProfile> getProfile(String profileId) async => _profile;
}

class _Clans extends Fake implements ClanRepository {
  @override
  Future<List<Clan>> listClans() async => [];
  @override
  Future<ClanMembership?> getMyClanMembership() async => null;
}

class _Fixtures extends Fake implements FixtureRepository {
  @override
  Future<List<Fixture>> listFixtures() async => [];
  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;
}

class _Queue extends Fake implements OpenQueueRepository {
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => [];
  @override
  Future<List<OpenQueueGame>> listGames() async => [];
  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => [];
}

class _Settings extends Fake implements YouSettingsRepository {
  @override
  Future<YouNotificationPreferences> loadNotifications() async =>
      const YouNotificationPreferences();
  @override
  Future<YouWallet> loadWallet() async =>
      YouWallet.fromJson({'currency': 'USD', 'balance_fils': 0});
}
