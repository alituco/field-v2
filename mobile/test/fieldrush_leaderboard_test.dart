import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/home_discovery_repository.dart';
import 'package:field/src/home/home_discovery_screen.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/leaderboard/leaderboard_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'bounded page RPC carries exact season, offset, region, and count',
    () async {
      final client = SupabaseClient(
        'https://fieldrush-test.invalid',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(
            request.url.path,
            '/rest/v1/rpc/list_fieldrush_player_rating_page',
          );
          expect(jsonDecode(request.body), {
            'region_to_use': 'phoenix',
            'season_starts_on': '2026-10-01',
            'season_ends_on': '2026-12-31',
            'offset_to_use': 103,
            'page_size_to_use': 20,
          });
          return http.Response(
            jsonEncode({
              'players': [
                {
                  'profile_id': 'rank-104',
                  'rank': 104,
                  'matches_played': 2,
                  'skill_rating': 1234,
                  'region': 'phoenix',
                },
              ],
              'around_me': [
                {
                  'profile_id': 'me',
                  'rank': 140,
                  'matches_played': 4,
                  'skill_rating': 1182,
                  'region': 'phoenix',
                },
              ],
              'total_count': 156,
              'next_offset': 123,
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final page = await SupabaseLeaderboardRepository(client: client)
          .loadPlayerRatingPage(
            season: leaderboardSeasons[1],
            offset: 103,
            pageSize: 20,
          );
      expect(page.players.single.rank, 104);
      expect(page.aroundMe.single.rank, 140);
      expect(page.totalCount, 156);
      expect(page.nextOffset, 123);
    },
  );

  testWidgets('Solo defaults to real top three and current-season standing', (
    tester,
  ) async {
    final rankings = _Rankings(total: 150, ownRank: 138);
    await _pump(tester, rankings: rankings);
    expect(find.text('Ranks'), findsOneWidget);
    expect(find.text('YOUR STANDING'), findsOneWidget);
    expect(find.text('#138'), findsOneWidget);
    expect(find.text('150 ranked players'), findsOneWidget);
    expect(find.text('+7 SR last game'), findsOneWidget);
    expect(find.text('AROUND YOU'), findsOneWidget);
    expect(find.byKey(const ValueKey('ranks-player-me')), findsOneWidget);
    expect(find.text('9000'), findsNothing);
    expect(find.textContaining('this week'), findsNothing);
    expect(rankings.requests.single, (0, 23, 'phoenix'));
    final third = tester.getTopLeft(
      find.byKey(const ValueKey('ranks-podium-p3')),
    );
    final first = tester.getTopLeft(
      find.byKey(const ValueKey('ranks-podium-p1')),
    );
    final second = tester.getTopLeft(
      find.byKey(const ValueKey('ranks-podium-p2')),
    );
    expect(third.dx, lessThan(first.dx));
    expect(first.dx, lessThan(second.dx));
    expect(first.dy, lessThan(third.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('placement uses two games and never reveals provisional SR', (
    tester,
  ) async {
    for (final count in [0, 1]) {
      await _pump(tester, rankings: _Rankings(matches: count));
      expect(find.text('#?'), findsOneWidget);
      expect(find.text('in Phoenix · ???? skill rating'), findsOneWidget);
      expect(find.text('Placement · $count of 2 played'), findsOneWidget);
      expect(
        find.text(
          '${2 - count} ${count == 1 ? 'game' : 'games'} to reveal your division',
        ),
        findsOneWidget,
      );
      expect(find.text('1234'), findsNothing);
      expect(find.textContaining('SR last game'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Phoenix picker does not move a legacy player into Phoenix', (
    tester,
  ) async {
    final rankings = _Rankings(region: 'bahrain');
    await _pump(tester, rankings: rankings);
    expect(rankings.requests.single.$3, 'phoenix');
    expect(
      find.text('Your rating is in Bahrain. This ladder is view only.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('ranks-standing')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ranks-city')));
    await tester.pumpAndSettle();
    expect(find.text('Solo ladder is live'), findsOneWidget);
    expect(find.text('Los Angeles'), findsNothing);
    expect(find.text('Bahrain'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Clans is the prototype coming-soon state without clan requests',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Clans'));
      await tester.pumpAndSettle();
      expect(find.text('Clan ladders are coming'), findsOneWidget);
      expect(find.text('COMING SOON'), findsOneWidget);
      expect(find.text('YOUR STANDING'), findsNothing);
      await tester.tap(find.text('See solo ladder'));
      await tester.pumpAndSettle();
      expect(find.text('YOUR STANDING'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty, rating-unavailable, and retry states do not invent rows',
    (tester) async {
      final rankings = _Rankings(total: 0, matches: 0, fail: true);
      await _pump(tester, rankings: rankings);
      expect(find.text('Ranks unavailable'), findsOneWidget);
      expect(find.text('TOP PLAYERS'), findsNothing);
      rankings.fail = false;
      rankings.ratingFail = true;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('The ladder starts here'), findsOneWidget);
      expect(find.text('0 ranked players'), findsOneWidget);
      expect(find.text('Your standing is unavailable'), findsOneWidget);
      expect(find.text('#?'), findsNothing);
      expect(find.text('????'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'full ladder paginates beyond 100 and collapse restores neighbors',
    (tester) async {
      final rankings = _Rankings(total: 143, ownRank: 138);
      await _pump(tester, rankings: rankings, height: 2400);
      for (var page = 0; page < 7; page++) {
        final more = find.byKey(const ValueKey('ranks-more'));
        await tester.scrollUntilVisible(
          more,
          900,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('ranks-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.tap(more);
        await tester.pumpAndSettle();
      }
      expect(rankings.requests.map((r) => r.$1), [0, 23, 43, 63, 83, 103, 123]);
      expect(find.byKey(const ValueKey('ranks-more')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('ranks-collapse')),
        900,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('ranks-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('ranks-collapse')));
      await tester.pumpAndSettle();
      expect(find.text('AROUND YOU'), findsOneWidget);
      expect(find.byKey(const ValueKey('ranks-player-me')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pagination failure preserves rows and retry uses same cursor', (
    tester,
  ) async {
    final rankings = _Rankings(total: 50);
    await _pump(tester, rankings: rankings, height: 2600);
    await tester.tap(find.byKey(const ValueKey('ranks-more')));
    await tester.pumpAndSettle();
    rankings.fail = true;
    await tester.ensureVisible(find.byKey(const ValueKey('ranks-more')));
    await tester.tap(find.byKey(const ValueKey('ranks-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ranks-player-p4')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    rankings.fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(rankings.requests.map((r) => r.$1), [0, 23, 23]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'podium/profile taps open public profile, own standing opens You',
    (tester) async {
      final profiles = _Profiles();
      var you = 0;
      await _pump(tester, profiles: profiles, onYou: () => you++);
      await tester.tap(find.byKey(const ValueKey('ranks-standing')));
      await tester.pumpAndSettle();
      expect(you, 1);
      await tester.tap(find.byKey(const ValueKey('ranks-podium-p1')));
      await tester.pumpAndSettle();
      expect(profiles.requested, ['p1']);
      expect(
        tester.widget<ProfileScreen>(find.byType(ProfileScreen)).profileId,
        'p1',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('search uses live repository and returns to ranks', (
    tester,
  ) async {
    final discovery = _Discovery();
    await _pump(tester, discovery: discovery);
    await tester.tap(find.bySemanticsLabel('Search players'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeDiscoveryScreen), findsOneWidget);
    await tester.enterText(find.byKey(const Key('home-player-search')), 'alex');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(discovery.queries, ['alex']);
    expect(find.text('Alex Real'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Ranks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('activation discards stale data and refreshes current season', (
    tester,
  ) async {
    final first = Completer<PlayerRatingLeaderboardPage>();
    final rankings = _Rankings(first: first);
    await _pump(tester, rankings: rankings, settle: false);
    await _pump(tester, rankings: rankings, tick: 1);
    expect(find.text('30 ranked players'), findsOneWidget);
    first.complete(
      const PlayerRatingLeaderboardPage(
        players: [],
        aroundMe: [],
        totalCount: 0,
        nextOffset: null,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('30 ranked players'), findsOneWidget);
    expect(find.text('The ladder starts here'), findsNothing);
  });

  testWidgets('narrow large-text ranks layouts remain usable', (tester) async {
    await _pump(tester, width: 320, textScale: 1.6, height: 2600);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Clans'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('optional native ranks previews use prototype fonts', (
    tester,
  ) async {
    final directory = Platform.environment['FIELDRUSH_RANKS_SCREENSHOT_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        await (FontLoader(
          font,
        )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    for (final (name, count) in [('ranked', 8), ('placement', 1)]) {
      final key = GlobalKey();
      await _pump(
        tester,
        rankings: _Rankings(matches: count, total: 150, ownRank: 138),
        height: 1350,
        boundary: key,
      );
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 2);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File(
          '$directory/ranks-$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
    }
  });
}

Future<void> _pump(
  WidgetTester tester, {
  _Rankings? rankings,
  _Profiles? profiles,
  _Discovery? discovery,
  VoidCallback? onYou,
  int tick = 0,
  double width = 390,
  double height = 1600,
  double textScale = 1,
  bool settle = true,
  GlobalKey? boundary,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, height),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          backgroundColor: FieldrushAuthTheme.cream,
          body: RepaintBoundary(
            key: boundary,
            child: LeaderboardScreen(
              key: ValueKey(rankings),
              clanRepository: _Clans(),
              fixtureRepository: _Fixtures(),
              leaderboardRepository: rankings ?? _Rankings(),
              profileRepository: profiles ?? _Profiles(),
              discoveryRepository: discovery ?? _Discovery(),
              onOpenYou: onYou,
              activationTick: tick,
            ),
          ),
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

PlayerRatingLeaderboardEntry _player(
  int rank, {
  int ownRank = 15,
  int matches = 8,
  String region = 'phoenix',
}) => PlayerRatingLeaderboardEntry(
  rank: matches < 2 ? 0 : rank,
  profileId: rank == ownRank ? 'me' : 'p$rank',
  displayName: rank == ownRank ? 'Alex Current' : 'Player $rank',
  username: rank == ownRank ? 'current' : 'player_$rank',
  skillRating: rank == ownRank ? 1234 : 1800 - rank,
  matchesPlayed: matches,
  wins: 4,
  losses: 3,
  draws: 1,
  lastChange: 7,
  region: region,
);

class _Rankings extends Fake
    implements LeaderboardRepository, PagedLeaderboardRepository {
  _Rankings({
    this.total = 30,
    this.ownRank = 15,
    this.matches = 8,
    this.region = 'phoenix',
    this.fail = false,
    this.first,
  });
  final int total, ownRank, matches;
  final String region;
  bool fail, ratingFail = false;
  final Completer<PlayerRatingLeaderboardPage>? first;
  final requests = <(int, int, String)>[];

  @override
  Future<PlayerRatingLeaderboardPage> loadPlayerRatingPage({
    required LeaderboardSeason season,
    String region = 'phoenix',
    int offset = 0,
    int pageSize = 23,
  }) async {
    requests.add((offset, pageSize, region));
    if (requests.length == 1 && first != null) return first!.future;
    if (fail) throw StateError('Network unavailable');
    return PlayerRatingLeaderboardPage(
      players: [
        for (
          var rank = offset + 1;
          rank <= total && rank <= offset + pageSize;
          rank++
        )
          if (rank != ownRank || matches >= 2) _player(rank, ownRank: ownRank),
      ],
      aroundMe: this.region != 'phoenix' || matches < 2
          ? []
          : [
              for (var rank = ownRank - 2; rank <= ownRank + 2; rank++)
                if (rank > 0 && rank <= total) _player(rank, ownRank: ownRank),
            ],
      totalCount: total,
      nextOffset: offset + pageSize < total ? offset + pageSize : null,
    );
  }

  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async {
    if (ratingFail) throw StateError('Rating unavailable');
    return _player(ownRank, ownRank: ownRank, matches: matches, region: region);
  }
}

class _Profiles extends Fake implements ProfileRepository {
  final requested = <String>[];
  @override
  String? get currentUserId => 'me';
  @override
  Future<PlayerProfile> getCurrentProfile() async => _profile('me');
  @override
  Future<PlayerProfile> getProfile(String profileId) async {
    requested.add(profileId);
    return _profile(profileId);
  }
}

PlayerProfile _profile(String id) => PlayerProfile(
  id: id,
  displayName: 'Player $id',
  username: 'player_$id',
  bio: '',
  followingCount: 0,
  fansCount: 0,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: const [],
  career: const [],
  playerRating: const ProfilePlayerRating(
    skillRating: 9000,
    matchesPlayed: 100,
    wins: 100,
    losses: 0,
    draws: 0,
    lastChange: 200,
    region: 'phoenix',
    events: [],
  ),
);

class _Clans extends Fake implements ClanRepository {}

class _Fixtures extends Fake implements FixtureRepository {}

class _Discovery extends Fake implements HomeDiscoveryRepository {
  final queries = <String>[];
  @override
  Future<List<HomePlayerResult>> searchPlayers(String query) async {
    queries.add(query);
    return const [
      HomePlayerResult(id: 'alex', name: 'Alex Real', username: 'alex_real'),
    ];
  }
}
