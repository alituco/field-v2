import 'dart:async';

import 'package:field/src/profile/fieldrush_player_profile.dart';
import 'package:field/src/profile/fieldrush_match_history_screen.dart';
import 'package:field/src/profile/fieldrush_you_widgets.dart';
import 'package:field/src/profile/profile_clip_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:field/src/ui/field_loading.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(find.byType(SnackBar), findsOneWidget);
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
      await tester.pumpAndSettle();
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
  _Repository repository, {
  String id = 'other',
  OpenQueueRepository? matches,
}) => tester.pumpWidget(
  MaterialApp(
    home: ProfileScreen(
      profileId: id,
      profileRepository: repository,
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
