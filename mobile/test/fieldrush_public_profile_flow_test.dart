import 'dart:async';
import 'dart:convert';

import 'package:field/src/leaderboard/fieldrush_rating_tracks.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/moderation/report_issue_sheet.dart';
import 'package:field/src/profile/fieldrush_player_profile.dart';
import 'package:field/src/profile/fieldrush_match_history_screen.dart';
import 'package:field/src/profile/fieldrush_you_widgets.dart';
import 'package:field/src/profile/profile_clip_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:field/src/ui/field_loading.dart';
import 'package:field/src/ui/fieldrush_toast.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// Supabase's injected worker keeps this widget test independent of real isolates.
// ignore: depend_on_referenced_packages
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

void main() {
  testWidgets(
    'real public identity and reporting survive a stalled legacy rating read',
    (tester) async {
      final stalled = Completer<http.Response>();
      http.Request? stalledRequest;
      var holdRating = true;
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-anon-key',
        isolate: _ImmediateJsonWorker(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final path = request.url.path;
          Object? payload = [];
          if (path.endsWith('/profiles')) {
            payload = {
              'id': 'other',
              'display_name': 'Other Player',
              'username': 'other',
              'bio': '',
            };
          } else if (path.endsWith('/get_player_rating_history')) {
            if (holdRating) {
              stalledRequest = request;
              return stalled.future;
            }
            payload = null;
          } else if (path.endsWith('/clan_members')) {
            payload = null;
          } else if (path.endsWith('/profile_follows') &&
              request.url.queryParameters.containsKey('following_id') &&
              request.url.queryParameters.containsKey('follower_id')) {
            payload = {'follower_id': 'viewer'};
          } else if (path.endsWith('/list_profile_previous_games')) {
            payload = [
              {
                'match_id': 'played',
                'match_type': 'SOLO',
                'played_at': '2026-10-01T18:00:00Z',
                'venue': 'Field',
                'home_score': 1,
                'away_score': 0,
                'player_side': 'WHITE',
                'player_role': 'DEF',
              },
            ];
          } else if (path.endsWith('/open_queue_games')) {
            payload = [
              {'id': 'played', 'timezone': 'America/Phoenix'},
            ];
          }
          return http.Response(
            jsonEncode(payload),
            200,
            headers: {
              'content-type': 'application/json',
              if (request.headers['prefer']?.contains('count=exact') == true)
                'content-range': '*/0',
            },
            request: request,
          );
        }),
      );
      addTearDown(() => tester.runAsync(client.dispose));
      await tester.runAsync(
        () => client.auth.recoverSession(jsonEncode(_session())),
      );
      await _pump(
        tester,
        SupabaseProfileRepository(client: client),
        ratings: _Ratings(),
      );
      await tester.pumpAndSettle();
      var content = _content(tester);
      expect(content.profile.id, 'other');
      expect(content.profile.displayName, 'Other Player');
      expect(content.ratings, isNotNull);
      expect(content.onFollow, isNull);
      expect(find.byKey(const ValueKey('player-follow')), findsNothing);
      expect(find.byKey(const ValueKey('player-match-record')), findsNothing);
      expect(find.byKey(const ValueKey('player-clan')), findsNothing);
      expect(find.byKey(const ValueKey('player-clips')), findsNothing);
      expect(find.text('Loading player details…'), findsOneWidget);
      content.onReport!();
      await tester.pumpAndSettle();
      expect(find.byType(ReportIssueSheet), findsOneWidget);
      expect(
        tester
            .widget<ReportIssueSheet>(find.byType(ReportIssueSheet))
            .subjectId,
        'other',
      );
      Navigator.of(tester.element(find.byType(ReportIssueSheet))).pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(_content(tester).profile.displayName, 'Other Player');
      expect(
        find.text('Player details unavailable. Try again to load them.'),
        findsOneWidget,
      );
      holdRating = false;
      await tester.ensureVisible(find.byKey(const ValueKey('player-retry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-retry')));
      await tester.pumpAndSettle();
      content = _content(tester);
      expect(content.profile.playedCount, 1);
      expect(content.isFollowing, isTrue);
      expect(content.onFollow, isNotNull);
      expect(content.detailsUnavailable, isFalse);
      expect(find.byKey(const ValueKey('player-refresh-error')), findsNothing);
      stalled.complete(http.Response('null', 200, request: stalledRequest));
      await tester.pumpAndSettle();
      expect(_content(tester).profile.playedCount, 1);
      expect(_content(tester).isFollowing, isTrue);
    },
  );

  testWidgets(
    'independent rating response survives a completed follow action',
    (tester) async {
      final repository = _SummaryRepository();
      final ratings = _Ratings()..pending = Completer<FieldrushPlayerRatings>();
      await _pump(tester, repository, ratings: ratings);
      await tester.pumpAndSettle();
      expect(_content(tester).ratingLoading, isTrue);
      await tester.tap(find.text('Follow'));
      await tester.pumpAndSettle();
      expect(repository.following, isTrue);
      ratings.pending!.complete(_ratings());
      await tester.pumpAndSettle();
      expect(_content(tester).ratings, isNotNull);
      expect(_content(tester).isFollowing, isTrue);
      expect(_content(tester).ratingLoading, isFalse);
    },
  );

  testWidgets(
    'an old viewer follow failure cannot replace the new viewer profile',
    (tester) async {
      final old = _SummaryRepository()..mutation = Completer<void>();
      await _pump(tester, old);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Follow'));
      await tester.pumpAndSettle();
      final next = _SummaryRepository()..following = true;
      await _pump(tester, next);
      await tester.pumpAndSettle();
      old.mutation!.completeError(StateError('Old request failed'));
      await tester.pumpAndSettle();
      expect(_content(tester).isFollowing, isTrue);
      expect(_content(tester).followBusy, isFalse);
      expect(find.byType(FieldrushToast), findsNothing);
    },
  );

  for (final selectOutfield in [false, true]) {
    testWidgets(
      'keeper default is independent of rating arrival; explicit selection $selectOutfield',
      (tester) async {
        final repository = _SummaryRepository()
          ..load = Completer<PlayerProfile>();
        await _pump(tester, repository, ratings: _Ratings());
        await tester.pumpAndSettle();
        expect(_content(tester).ratings, isNotNull);
        if (selectOutfield) _content(tester).onTrack!(RatingTrack.outfield);
        repository.load!.complete(
          _profile('other', games: [_historyGame('keeper', role: 'GK')]),
        );
        await tester.pumpAndSettle();
        expect(
          _content(tester).track,
          selectOutfield ? RatingTrack.outfield : RatingTrack.goalkeeper,
        );
      },
    );
  }

  testWidgets(
    'rating timeout keeps cached details and retries without resetting following',
    (tester) async {
      final repository = _SummaryRepository()..following = true;
      final ratings = _Ratings()..pending = Completer<FieldrushPlayerRatings>();
      await _pump(tester, repository, ratings: ratings);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(_content(tester).isFollowing, isTrue);
      expect(_content(tester).ratingUnavailable, isTrue);
      ratings.pending = null;
      await tester.ensureVisible(find.byKey(const ValueKey('player-retry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-retry')));
      await tester.pumpAndSettle();
      expect(_content(tester).ratings, isNotNull);
      expect(_content(tester).isFollowing, isTrue);
    },
  );

  for (final newId in ['other', 'new-player']) {
    testWidgets(
      'new profile context $newId never reuses old FutureBuilder data',
      (tester) async {
        await _pump(tester, _SummaryRepository()..following = true);
        await tester.pumpAndSettle();
        expect(_content(tester).isFollowing, isTrue);
        final next = _SummaryRepository()
          ..summary = Completer<PlayerProfile>()
          ..load = Completer<PlayerProfile>();
        await _pump(tester, next, id: newId);
        await tester.pumpAndSettle();
        expect(find.byType(FieldrushPlayerProfileContent), findsNothing);
        expect(find.byKey(const ValueKey('player-report')), findsNothing);
        next.summary!.complete(_profile(newId));
        await tester.pumpAndSettle();
        expect(_content(tester).profile.id, newId);
        expect(_content(tester).onFollow, isNull);
        next.load!.complete(_profile(newId));
        await tester.pumpAndSettle();
        expect(_content(tester).isFollowing, isFalse);
      },
    );
  }

  testWidgets('public profile has skeletons until its own data arrives', (
    tester,
  ) async {
    final repository = _Repository()..load = Completer<PlayerProfile>();
    await _pump(tester, repository);
    expect(find.byType(FieldSkeleton), findsWidgets);
    expect(find.byType(FieldrushPlayerProfileContent), findsNothing);
    repository.load!.complete(_profile('other'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushPlayerProfileContent), findsOneWidget);
    expect(find.text('@other'), findsOneWidget);
    expect(find.text('secret phone'), findsNothing);
    expect(find.text('Follow'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('follow is optimistic, guarded, and rolls back on failure', (
    tester,
  ) async {
    final repository = _Repository()..mutation = Completer<void>();
    await _pump(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();
    var content = tester.widget<FieldrushPlayerProfileContent>(
      find.byType(FieldrushPlayerProfileContent),
    );
    expect(content.isFollowing, isTrue);
    expect(content.followBusy, isTrue);
    content.onFollow?.call();
    expect(repository.followCalls, 1);
    repository.mutation!.completeError(StateError('Network unavailable'));
    await tester.pumpAndSettle();
    content = tester.widget<FieldrushPlayerProfileContent>(
      find.byType(FieldrushPlayerProfileContent),
    );
    expect(content.isFollowing, isFalse);
    expect(content.followBusy, isFalse);
    expect(find.byType(FieldrushToast), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(FieldrushToast),
        matching: find.text('Network unavailable.'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing follow state loads and successful unfollow persists', (
    tester,
  ) async {
    final repository = _Repository()..following = true;
    await _pump(tester, repository);
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);
    await tester.tap(find.text('Following'));
    await tester.pumpAndSettle();
    expect(repository.unfollowCalls, 1);
    expect(repository.following, isFalse);
    expect(find.text('Follow'), findsOneWidget);
  });

  testWidgets('a stale refresh cannot overwrite a newer confirmed follow', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    await tester.pumpAndSettle();
    repository.load = Completer<PlayerProfile>();
    final refresh = tester
        .widget<FieldRefreshIndicator>(find.byType(FieldRefreshIndicator))
        .onRefresh();
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();
    expect(repository.following, isTrue);
    repository.load!.complete(_profile('other', following: false));
    await refresh;
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);
    await tester.tap(find.text('Following'));
    await tester.pumpAndSettle();
    expect(repository.unfollowCalls, 1);
  });

  testWidgets('button and system back wait for a follow to settle', (
    tester,
  ) async {
    final repository = _Repository()..mutation = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(
                    profileId: 'other',
                    profileRepository: repository,
                  ),
                ),
              ),
              child: const Text('Open profile'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FieldrushPlayerProfileContent>(
            find.byType(FieldrushPlayerProfileContent),
          )
          .onBack,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('@other'), findsOneWidget);
    repository.mutation!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-back')));
    await tester.pumpAndSettle();
    expect(find.text('Open profile'), findsOneWidget);
    expect(find.text('@other'), findsNothing);
  });

  testWidgets(
    'changing player reloads identity and self cannot follow or report',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.pumpAndSettle();
      expect(find.text('@other'), findsOneWidget);
      await _pump(tester, repository, id: 'me');
      await tester.pumpAndSettle();
      expect(find.text('@me'), findsOneWidget);
      expect(find.text('@other'), findsNothing);
      final content = tester.widget<FieldrushPlayerProfileContent>(
        find.byType(FieldrushPlayerProfileContent),
      );
      expect(content.onFollow, isNull);
      expect(content.onReport, isNull);
      expect(find.text('Report player'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed load can retry without exposing another profile', (
    tester,
  ) async {
    final repository = _Repository()..failLoad = true;
    await _pump(tester, repository);
    await tester.pumpAndSettle();
    expect(find.text('Player unavailable'), findsOneWidget);
    expect(find.byType(FieldrushPlayerProfileContent), findsNothing);
    repository.failLoad = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('@other'), findsOneWidget);
    expect(find.text('Player unavailable'), findsNothing);
  });

  testWidgets(
    'empty public profile shares themed record and clips without a made-up role',
    (tester) async {
      final repository = _Repository()
        ..result = _profile('other', position: 'Goalkeeper');
      await _pump(tester, repository);
      await tester.pumpAndSettle();
      expect(find.text('VIEW ONLY'), findsNothing);
      expect(
        find.byKey(const ValueKey('player-played-position')),
        findsNothing,
      );
      expect(find.text('Position unavailable'), findsNothing);
      expect(find.text('No clan · plays solo'), findsNothing);
      expect(find.text('Not in a clan'), findsOneWidget);
      expect(find.byType(FieldrushProfileClips), findsOneWidget);
      expect(find.byType(FieldrushMatchRecordCard), findsOneWidget);
      expect(find.text('PLAYED'), findsNothing);
      expect(find.text('WIN RATE'), findsNothing);
      expect(find.text('SHOW-UP'), findsNothing);
      final record = tester.getRect(find.byType(FieldrushMatchRecordCard));
      final rating = tester.getRect(
        find.byKey(const ValueKey('player-rating-section')),
      );
      expect(record.top, greaterThanOrEqualTo(rating.bottom));
      expect(
        record.bottom,
        lessThan(tester.getTopLeft(find.text('LAST FIVE')).dy),
      );
      expect(
        record.bottom,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('player-clips'))).dy,
        ),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('player-clips'))).dy,
        greaterThan(
          tester.getBottomLeft(find.byKey(const ValueKey('player-no-clan'))).dy,
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('player-match-history')),
        240,
      );
      await tester.pumpAndSettle();
      expect(find.text('No clips yet.'), findsOneWidget);
      expect(find.text('0 played · 0% won'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-match-history')));
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushMatchHistoryScreen), findsOneWidget);
      expect(find.text('No finished games yet.'), findsOneWidget);
      expect(find.text('Your finished games will appear here.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'public clips open the existing viewer directly with ownership controls disabled',
    (tester) async {
      final repository = _Repository()
        ..result = _profile(
          'other',
          highlights: const [
            ProfileHighlight(
              id: 'public-clip',
              title: 'Top corner',
              thumbnailUrl: '',
              duration: '0:12',
              views: 3,
              status: ProfileHighlightStatus.processing,
            ),
          ],
        );
      await _pump(tester, repository);
      await tester.pumpAndSettle();
      final clip = find.byKey(const ValueKey('player-clip-public-clip'));
      await tester.scrollUntilVisible(
        clip,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(clip);
      // A processing clip intentionally keeps its activity indicator running.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final screen = tester.widget<ProfileClipScreen>(
        find.byType(ProfileClipScreen),
      );
      expect(screen.highlight.id, 'public-clip');
      expect(screen.canManage, isFalse);
      expect(
        find.byKey(const ValueKey('clip-visibility-selector')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing public match scores stay unavailable instead of inventing a draw',
    (tester) async {
      final game = ProfilePreviousGame.fromJson({
        'match_id': 'unknown-result',
        'match_type': 'SOLO',
        'played_at': '2026-10-10T02:00:00Z',
        'timezone': 'America/Phoenix',
        'player_side': 'WHITE',
        'player_role': 'DEF',
      });
      final repository = _Repository()
        ..result = _profile('other', games: [game]);
      await _pump(tester, repository);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('player-match-history')),
        240,
      );
      await tester.pumpAndSettle();
      expect(find.text('1 played · Results incomplete'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-match-history')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Score unavailable'), findsOneWidget);
      expect(find.textContaining('0–0'), findsNothing);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('D'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'public lifetime record uses themed history and opens the current solo match screen',
    (tester) async {
      final game = _historyGame('game-one', role: 'DEF');
      final repository = _Repository()
        ..result = _profile(
          'other',
          position: 'Goalkeeper',
          games: [game, game],
        );
      final matches = _Matches();
      await _pump(tester, repository, matches: matches);
      await tester.pumpAndSettle();
      expect(find.text('Defender'), findsOneWidget);
      expect(find.text('Goalkeeper'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('player-match-history')),
        240,
      );
      await tester.pumpAndSettle();
      expect(find.text('1 played · 100% won'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-match-history')));
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushMatchHistoryScreen), findsOneWidget);
      expect(find.text('1 played · 1W 0D 0L'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-history-game-one')));
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
      expect(find.byType(FixtureDetailScreen), findsNothing);
      expect(
        tester
            .widget<FieldrushGameDetailScreen>(
              find.byType(FieldrushGameDetailScreen),
            )
            .gameId,
        'game-one',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  ProfileRepository repository, {
  TrackLeaderboardRepository? ratings,
  String id = 'other',
  OpenQueueRepository? matches,
}) => tester.pumpWidget(
  MaterialApp(
    home: ProfileScreen(
      profileId: id,
      profileRepository: repository,
      ratingRepository: ratings,
      openQueueRepository: matches,
    ),
  ),
);

PlayerProfile _profile(
  String id, {
  bool following = false,
  String? position,
  List<ProfilePreviousGame> games = const [],
  List<ProfileHighlight> highlights = const [],
}) => PlayerProfile(
  id: id,
  displayName: '$id P.',
  username: id,
  bio: '',
  phone: 'secret phone',
  followingCount: 0,
  fansCount: 0,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: highlights,
  position: position,
  previousGames: games,
  career: const [],
  isFollowedByMe: following,
  playerRating: const ProfilePlayerRating(
    skillRating: 1200,
    matchesPlayed: 0,
    wins: 0,
    losses: 0,
    draws: 0,
    lastChange: 0,
    region: 'phoenix',
    events: [],
  ),
);

class _Repository extends Fake implements ProfileRepository {
  PlayerProfile? result;
  Completer<PlayerProfile>? load;
  Completer<void>? mutation;
  bool following = false, failLoad = false;
  int followCalls = 0, unfollowCalls = 0;

  @override
  String? get currentUserId => 'me';
  @override
  Future<PlayerProfile> getProfile(String id) async {
    if (failLoad) throw StateError('Offline');
    if (load != null) return load!.future;
    return result ?? _profile(id, following: following);
  }

  @override
  Future<void> followProfile(String profileId) async {
    followCalls++;
    if (mutation != null) await mutation!.future;
    following = true;
  }

  @override
  Future<void> unfollowProfile(String profileId) async {
    unfollowCalls++;
    if (mutation != null) await mutation!.future;
    following = false;
  }
}

ProfilePreviousGame _historyGame(String id, {String role = 'DEF'}) =>
    ProfilePreviousGame(
      id: id,
      type: ProfileGameType.solo,
      playedAt: DateTime.utc(2026, 10, 10, 2),
      venue: 'Phoenix Field',
      homeName: 'White Team',
      homeTag: 'WHITE',
      homeEmblem: '',
      awayName: 'Black Team',
      awayTag: 'BLACK',
      awayEmblem: '',
      homeScore: 2,
      awayScore: 1,
      playerSide: 'WHITE',
      playerRole: role,
    );

class _Matches extends Fake implements OpenQueueRepository {
  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async =>
      OpenQueueMatchDetail(
        game: OpenQueueGame(
          id: gameId,
          status: 'FINAL',
          venue: 'Phoenix Field',
          startsAt: DateTime.utc(2026, 10, 10, 2),
          endsAt: DateTime.utc(2026, 10, 10, 3),
          timezone: 'America/Phoenix',
          priceFils: 13000,
          currency: 'USD',
          ageLabel: '18+',
          capacity: 14,
          confirmedCount: 14,
          spots: const {},
          whiteScore: 2,
          blackScore: 1,
        ),
        scorers: const [],
        timeline: const [],
      );

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => const [];
}

FieldrushPlayerProfileContent _content(WidgetTester tester) =>
    tester.widget<FieldrushPlayerProfileContent>(
      find.byType(FieldrushPlayerProfileContent),
    );

class _SummaryRepository extends _Repository
    implements PublicProfileSummaryRepository {
  Completer<PlayerProfile>? summary;
  @override
  Future<PlayerProfile> getProfileSummary(String profileId) async =>
      summary == null ? _profile(profileId) : summary!.future;
}

class _Ratings extends Fake implements TrackLeaderboardRepository {
  Completer<FieldrushPlayerRatings>? pending;
  @override
  Future<FieldrushPlayerRatings> loadPlayerRatings({
    LeaderboardSeason? season,
    String? profileId,
  }) async => pending == null ? _ratings() : pending!.future;
}

FieldrushPlayerRatings _ratings() => const FieldrushPlayerRatings(
  outfield: PlayerRatingLeaderboardEntry(
    rank: 1,
    profileId: 'other',
    displayName: 'Other Player',
    username: 'other',
    skillRating: 1250,
    matchesPlayed: 2,
    wins: 2,
    losses: 0,
    draws: 0,
    lastChange: 25,
    region: 'phoenix',
  ),
  goalkeeper: PlayerRatingLeaderboardEntry(
    rank: 1,
    profileId: 'other',
    displayName: 'Other Player',
    username: 'other',
    skillRating: 1300,
    matchesPlayed: 2,
    wins: 2,
    losses: 0,
    draws: 0,
    lastChange: 30,
    region: 'phoenix',
  ),
);

Map<String, dynamic> _session() {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  String encoded(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': 'viewer', 'exp': expires})}.test',
    'refresh_token': 'test-refresh',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': 'viewer',
      'aud': 'authenticated',
      'role': 'authenticated',
      'created_at': '2026-10-01T00:00:00Z',
      'app_metadata': {},
      'user_metadata': {},
    },
  };
}

class _ImmediateJsonWorker extends Fake implements YAJsonIsolate {
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
}
