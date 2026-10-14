import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/clans/clan.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/leaderboard/fieldrush_rating_tracks.dart';
import 'package:field/src/leaderboard/fieldrush_rating_role_tabs.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/leaderboard/leaderboard_screen.dart';
import 'package:field/src/markets/fieldrush_city.dart';
import 'package:field/src/markets/fieldrush_city_repository.dart';
import 'package:field/src/profile/fieldrush_city_picker.dart';
import 'package:field/src/profile/fieldrush_player_profile.dart';
import 'package:field/src/profile/fieldrush_you_widgets.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'recent role snapshots refresh details without truncating full history',
    () {
      ProfileRatingEvent event(String id, String match, int delta) =>
          ProfileRatingEvent.fromJson({
            'id': id,
            'source_type': 'OPEN_QUEUE',
            'source_id': match,
            'played_at': '2026-10-13T00:00:00Z',
            'rating_change': delta,
            'rating_track': 'GOALKEEPER',
          });
      final ratings = FieldrushPlayerRatings(
        outfield: _ratings.outfield,
        goalkeeper: _ratings.goalkeeper,
        events: {
          RatingTrack.goalkeeper: [event('updated', 'recent-game', 12)],
        },
      );
      final history = ratings.mergeHistory([
        event('older', 'older-game', 4),
        event('stale', 'recent-game', 2),
      ]);
      expect(history.map((e) => e.id), containsAll(['older', 'updated']));
      expect(history.length, 2);
      expect(
        history.where((e) => e.sourceId == 'recent-game').single.ratingChange,
        12,
      );
    },
  );

  test(
    'dual snapshot keeps placements, records and global ranks independent',
    () {
      final snapshot = FieldrushPlayerRatings.fromJson({
        'primary_city_id': 'phoenix',
        'primary_city_name': 'Phoenix',
        'preferred_city_id': 'new-york',
        'ratings': {
          'OUTFIELD': {
            'profile_id': 'me',
            'skill_rating': 1680,
            'matches_played': 5,
            'wins': 3,
            'city_rank': 1,
            'rank': 1,
            'global_rank': 7,
            'region': 'phoenix',
          },
          'GOALKEEPER': {
            'profile_id': 'me',
            'skill_rating': 1210,
            'matches_played': 1,
            'wins': 1,
            'rank': null,
            'global_rank': null,
            'region': 'phoenix',
          },
        },
      });
      expect(snapshot.outfield.division.number, 1);
      expect(snapshot.goalkeeper.gamesNeededToRank, 1);
      expect(snapshot.forScope(RatingTrack.outfield, null).rank, 7);
      expect(snapshot.forScope(RatingTrack.goalkeeper, null).rank, 0);
      expect(snapshot.forScope(RatingTrack.outfield, 'new-york').rank, 0);
      expect(snapshot.forScope(RatingTrack.outfield, 'phoenix').rank, 1);
      expect(snapshot.primaryCityId, 'phoenix');
      expect(snapshot.preferredCityId, 'new-york');
    },
  );

  test(
    'keeper global RPC carries scope, role and cursor without guessing a city',
    () async {
      final client = SupabaseClient(
        'https://fieldrush-test.invalid',
        'key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/rest/v1/rpc/list_fieldrush_rating_page');
          expect(jsonDecode(request.body), {
            'scope_to_use': 'GLOBAL',
            'city_id_to_use': null,
            'rating_track_to_use': 'GOALKEEPER',
            'season_starts_on': '2026-10-01',
            'season_ends_on': '2026-12-31',
            'offset_to_use': 23,
            'page_size_to_use': 20,
          });
          return http.Response(
            jsonEncode({
              'players': [],
              'around_me': [],
              'total_count': 0,
              'next_offset': null,
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      await SupabaseLeaderboardRepository(client: client).loadRatingPage(
        season: leaderboardSeasons[1],
        track: RatingTrack.goalkeeper,
        offset: 23,
        pageSize: 20,
      );
    },
  );

  testWidgets(
    'live role-aware ranks switches Keeper and Global without borrowing Outfield standings',
    (tester) async {
      final repo = _Rankings();
      await _pump(
        tester,
        LeaderboardScreen(
          clanRepository: _Clans(),
          fixtureRepository: _Fixtures(),
          leaderboardRepository: repo,
          profileRepository: _Profiles(),
          cityRepository: _Cities(),
        ),
      );
      expect(repo.requests, [(RatingTrack.outfield, 'phoenix')]);
      expect(find.text('#2'), findsWidgets);
      await tester.tap(find.text('Keepers'));
      await tester.pumpAndSettle();
      expect(repo.requests.last, (RatingTrack.goalkeeper, 'phoenix'));
      expect(find.text('RANKED'), findsOneWidget);
      expect(find.text('0 keepers'), findsOneWidget);
      expect(find.text('1 of 2 games in goal'), findsOneWidget);
      expect(
        find.text('1 game in goal to reveal your division'),
        findsOneWidget,
      );
      expect(find.text('#?'), findsOneWidget);
      expect(find.text('1680'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ranks-city')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Global').last);
      await tester.pumpAndSettle();
      expect(repo.requests.last, (RatingTrack.goalkeeper, null));
      expect(find.text('Worldwide · ???? keeper skill rating'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Home placement matches compact HTML and keeps role progress separate',
    (tester) async {
      var track = RatingTrack.outfield;
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => FieldrushHomeRating(
            profile: _profile,
            ratings: _ratings,
            rating: _ratings.forTrack(track),
            track: track,
            onTrack: (value) => setState(() => track = value),
            onTap: () {},
          ),
        ),
      );
      expect(find.textContaining('1680', findRichText: true), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rating-track-GOALKEEPER')));
      await tester.pumpAndSettle();
      expect(find.text('PLACEMENT'), findsOneWidget);
      expect(find.text('1680'), findsNothing);
      expect(
        find.text('1 game in goal to reveal your division'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.text('1 game in goal to reveal your division'))
            .maxLines,
        1,
      );
      expect(find.text('1 / 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'home-keeper-placement');
    },
  );

  testWidgets(
    'Home Keeper card opens Keeper ranks and shared role survives returning Home',
    (tester) async {
      final role = ValueNotifier(RatingTrack.outfield);
      addTearDown(role.dispose);
      final repo = _Rankings();
      var index = 0;
      late StateSetter navigate;
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            navigate = setState;
            return SizedBox(
              height: 1100,
              child: IndexedStack(
                index: index,
                children: [
                  DashboardHome(
                    profileRepository: _Profiles(),
                    clanRepository: _Clans(),
                    fixtureRepository: _Fixtures(),
                    leaderboardRepository: repo,
                    openQueueRepository: _Queue(),
                    ratingTrackController: role,
                    onOpenRanks: () => setState(() => index = 1),
                    onOpenClans: () {},
                    onOpenFixtures: () {},
                    onOpenProfile: () {},
                    onNavigateTab: (_) {},
                  ),
                  LeaderboardScreen(
                    clanRepository: _Clans(),
                    fixtureRepository: _Fixtures(),
                    leaderboardRepository: repo,
                    profileRepository: _Profiles(),
                    cityRepository: _Cities(),
                    ratingTrackController: role,
                  ),
                ],
              ),
            );
          },
        ),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('rating-track-GOALKEEPER')),
      );
      await tester.tap(find.byKey(const ValueKey('rating-track-GOALKEEPER')));
      await tester.pumpAndSettle();
      expect(role.value, RatingTrack.goalkeeper);
      await tester.tap(find.byKey(const ValueKey('home-rating-placement')));
      await tester.pumpAndSettle();
      expect(find.text('RANKED'), findsOneWidget);
      expect(repo.requests.last.$1, RatingTrack.goalkeeper);
      await tester.tap(find.text('Outfield'));
      await tester.pumpAndSettle();
      expect(role.value, RatingTrack.outfield);
      navigate(() => index = 0);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(FieldrushHomeRating),
          matching: find.textContaining('1680', findRichText: true),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('You keeps full mystery card and Keeper switch for new players', (
    tester,
  ) async {
    await _pump(tester, _you(_freshRatings), width: 393);
    expect(find.text('Outfield'), findsOneWidget);
    expect(find.text('Keeper'), findsOneWidget);
    expect(find.text('????'), findsOneWidget);
    expect(find.text('NOT RANKED YET'), findsOneWidget);
    expect(find.textContaining('IN PHOENIX'), findsNothing);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'you-new-ladders');
  });

  testWidgets('public profile switches score and placement with its role', (
    tester,
  ) async {
    var track = RatingTrack.outfield;
    await _pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => FieldrushPlayerProfileContent(
          profile: _profile,
          isFollowing: false,
          followBusy: false,
          onBack: () {},
          onMatchHistory: () {},
          ratings: _ratings,
          track: track,
          onTrack: (value) => setState(() => track = value),
        ),
      ),
    );
    expect(find.text('1680'), findsOneWidget);
    expect(find.byType(FieldrushMatchRecordCard), findsOneWidget);
    expect(find.text('WIN RATE'), findsNothing);
    expect(find.text('SHOW-UP'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rating-track-GOALKEEPER')));
    await tester.pumpAndSettle();
    expect(find.text('1680'), findsNothing);
    expect(find.text('????'), findsOneWidget);
    expect(find.text('1/2 placement games'), findsOneWidget);
    expect(find.byType(FieldrushMatchRecordCard), findsOneWidget);
    expect(find.text('WIN RATE'), findsNothing);
    expect(find.text('SHOW-UP'), findsNothing);
    final pillAlignment = tester.widget<Align>(
      find
          .ancestor(
            of: find.byType(FieldrushRatingRoleTabs),
            matching: find.byType(Align),
          )
          .first,
    );
    expect(pillAlignment.alignment, Alignment.centerLeft);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'public-keeper-placement');
  });

  testWidgets('role pills and cards fit narrow and large text phone widths', (
    tester,
  ) async {
    for (final width in [320.0, 393.0]) {
      await _pump(tester, _you(_ratings), width: width, scale: 1.6);
      expect(tester.takeException(), isNull);
      await _pump(
        tester,
        FieldrushHomeRating(
          profile: _profile,
          ratings: _freshRatings,
          rating: _freshRatings.goalkeeper,
          track: RatingTrack.goalkeeper,
          onTrack: (_) {},
          onTap: () {},
        ),
        width: width,
        scale: 1.6,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'city picker lists server cities and surfaces save failure without closing',
    (tester) async {
      final cities = _Cities()..failSave = true;
      await _pump(
        tester,
        FieldrushCityPicker(repository: cities, currentCityId: 'phoenix'),
      );
      expect(find.text('Phoenix, AZ'), findsOneWidget);
      expect(find.text('New York'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('city-option-phoenix')));
      await tester.pumpAndSettle();
      expect(cities.saved, ['phoenix']);
      expect(find.text('Choose your city'), findsOneWidget);
      expect(find.textContaining('save failed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 393,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  for (final font in ['Outfit', 'PlusJakartaSans']) {
    final filename = '$font.ttf';
    // Real fonts make opt-in visual captures useful, not platform test boxes.
    final file = File('assets/fonts/$filename');
    if (file.existsSync()) {
      final loader = FontLoader(font)
        ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      await loader.load();
    }
  }
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Theme(
          data: FieldrushAuthTheme.theme(context),
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              backgroundColor: FieldrushAuthTheme.cream,
              body: RepaintBoundary(
                key: const ValueKey('capture'),
                child: Material(
                  color: FieldrushAuthTheme.cream,
                  child:
                      child is LeaderboardScreen || child is FieldrushCityPicker
                      ? child
                      : SingleChildScrollView(child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['FIELDRUSH_CAPTURE_DIR'] case final String path) {
    await tester.runAsync(() async {
      final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')),
      );
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(path).create(recursive: true);
      await File('$path/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  }
}

Widget _you(FieldrushPlayerRatings ratings) => FieldrushYouContent(
  profile: _profile,
  rating: ratings.outfield,
  ratings: ratings,
  onTrack: (_) {},
  onEdit: () {},
  onFollowing: () {},
  onFans: () {},
  onRanks: () {},
  onMatchHistory: () {},
  onClip: (_) {},
  onReliability: () {},
  onNotifications: () {},
  onWallet: () {},
  onPaymentMethods: () {},
  onSignOut: () {},
);

PlayerRatingLeaderboardEntry _entry({
  int matches = 5,
  int sr = 1680,
  int rank = 2,
  String region = 'phoenix',
}) => PlayerRatingLeaderboardEntry(
  rank: rank,
  profileId: 'me',
  displayName: 'Alex A.',
  username: 'alex',
  skillRating: sr,
  matchesPlayed: matches,
  wins: 3,
  losses: 1,
  draws: 1,
  lastChange: 12,
  region: region,
);
final _ratings = FieldrushPlayerRatings(
  outfield: _entry(),
  goalkeeper: _entry(matches: 1, sr: 1210, rank: 0),
  primaryCityId: 'phoenix',
  primaryCityName: 'Phoenix',
  preferredCityId: 'phoenix',
  globalRanks: {RatingTrack.outfield: 8},
);
final _freshRatings = FieldrushPlayerRatings(
  outfield: _entry(matches: 0, sr: 1200, rank: 0, region: ''),
  goalkeeper: _entry(matches: 0, sr: 1200, rank: 0, region: ''),
  preferredCityId: 'phoenix',
);
const _profile = PlayerProfile(
  id: 'me',
  displayName: 'Alex A.',
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

class _Rankings extends Fake
    implements LeaderboardRepository, TrackLeaderboardRepository {
  final requests = <(RatingTrack, String?)>[];
  @override
  Future<FieldrushPlayerRatings> loadPlayerRatings({
    required LeaderboardSeason season,
    String? profileId,
  }) async => _ratings;
  @override
  Future<PlayerRatingLeaderboardPage> loadRatingPage({
    required LeaderboardSeason season,
    required RatingTrack track,
    String? cityId,
    int offset = 0,
    int pageSize = 23,
  }) async {
    requests.add((track, cityId));
    return PlayerRatingLeaderboardPage(
      players: track == RatingTrack.outfield
          ? [_ratings.forScope(track, cityId)]
          : [],
      aroundMe: [],
      totalCount: track == RatingTrack.outfield ? 1 : 0,
      nextOffset: null,
    );
  }
}

class _Cities extends Fake implements FieldrushCityRepository {
  bool failSave = false;
  final saved = <String>[];
  @override
  Future<List<FieldrushCity>> listCities() async => [FieldrushCity.phoenix];
  @override
  Future<FieldrushCity> setPreferredCity(String id) async {
    saved.add(id);
    if (failSave) throw StateError('save failed');
    return FieldrushCity.phoenix;
  }
}

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

class _Fixtures extends Fake implements FixtureRepository {
  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;
  @override
  Future<List<Fixture>> listFixtures() async => [];
}

class _Queue extends Fake implements OpenQueueRepository {
  @override
  Future<List<OpenQueueGame>> listGames() async => [];
  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => [];
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => [];
}
