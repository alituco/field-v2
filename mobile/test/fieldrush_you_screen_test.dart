import 'dart:async';

import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/profile/fieldrush_match_history_screen.dart';
import 'package:field/src/profile/fieldrush_you_screen.dart';
import 'package:field/src/profile/fieldrush_you_settings.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_connections_screen.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/reliability/reliability.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'first You load shows a skeleton until profile and rating arrive',
    (tester) async {
      final response = Completer<PlayerProfile>();
      await tester.pumpWidget(_app(profiles: _Profiles(first: response)));
      await tester.pump();
      expect(find.text('You'), findsOneWidget);
      expect(find.byKey(const ValueKey('you-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('you-rating-loading')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Rating unavailable'), findsNothing);

      response.complete(_profile(name: 'Ali A.'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('you-loading')), findsNothing);
      expect(find.byKey(const ValueKey('you-rating-loading')), findsNothing);
      expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
      expect(find.text('Ali A.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed first load leaves the skeleton for a usable retry', (
    tester,
  ) async {
    final response = Completer<PlayerProfile>();
    await tester.pumpWidget(_app(profiles: _Profiles(first: response)));
    await tester.pump();
    response.completeError(StateError('Unavailable'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('you-rating-loading')), findsNothing);
    expect(find.text('Could not load your profile'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Ali A.'), findsOneWidget);
    expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reactivating You keeps identity visible with a rank skeleton', (
    tester,
  ) async {
    final response = Completer<PlayerRatingLeaderboardEntry>();
    final profiles = _Profiles();
    final ratings = _Ratings(refresh: response);
    await tester.pumpWidget(_app(profiles: profiles, ratings: ratings));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);

    await tester.pumpWidget(
      _app(profiles: profiles, ratings: ratings, activationTick: 1),
    );
    await tester.pump();
    expect(find.text('Ali A.'), findsOneWidget);
    expect(find.byKey(const ValueKey('you-rating-loading')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('you-rating-unavailable')), findsNothing);

    response.complete(
      await _Ratings().loadCurrentPlayerRating(activeLeaderboardSeason),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('you-rating-loading')), findsNothing);
    expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('You uses season stats and refreshes identity after Edit', (
    tester,
  ) async {
    final profiles = _Profiles();
    var editCount = 0;
    await tester.pumpWidget(
      _app(
        profiles: profiles,
        onEdit: () async {
          editCount++;
          profiles.name = 'Alex R.';
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ali A.'), findsOneWidget);
    expect(find.text('1700'), findsNothing);
    expect(find.text('2 played · 50% won'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('you-edit')));
    await tester.pumpAndSettle();
    expect(editCount, 1);
    expect(find.text('Alex R.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'optional section failures keep profile and account access working',
    (tester) async {
      var edits = 0;
      await tester.pumpWidget(
        _app(
          ratings: _Ratings(fail: true),
          settings: _Settings(fail: true),
          onEdit: () async {
            edits++;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ali A.'), findsOneWidget);
      expect(find.text('Rating unavailable'), findsOneWidget);
      expect(find.text('1700'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('you-edit')));
      await tester.pumpAndSettle();
      expect(edits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a stale activation load cannot overwrite the latest profile', (
    tester,
  ) async {
    final first = Completer<PlayerProfile>();
    final profiles = _Profiles(first: first);
    await tester.pumpWidget(_app(profiles: profiles));
    await tester.pump();
    profiles.name = 'Latest P.';
    await tester.pumpWidget(_app(profiles: profiles, activationTick: 1));
    await tester.pumpAndSettle();
    expect(find.text('Latest P.'), findsOneWidget);
    first.complete(_profile(name: 'Outdated P.'));
    await tester.pumpAndSettle();
    expect(find.text('Latest P.'), findsOneWidget);
    expect(find.text('Outdated P.'), findsNothing);
  });

  testWidgets(
    'zero BHD wallet retains its currency when account and rating fail',
    (tester) async {
      await tester.pumpWidget(
        _app(
          ratings: _Ratings(fail: true),
          accounts: _UnavailableAccounts(),
          settings: _Settings(
            wallet: YouWallet(
              primaryBalance: const FieldWalletBalance(
                currency: 'BHD',
                balanceFils: 0,
              ),
              balances: const [
                FieldWalletBalance(currency: 'BHD', balanceFils: 0),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ali A.'), findsOneWidget);
      expect(find.text('Rating unavailable'), findsOneWidget);
      final walletRow = find.byKey(const ValueKey('you-wallet'));
      await tester.ensureVisible(walletRow);
      expect(
        find.descendant(of: walletRow, matching: find.text('0.000 BHD')),
        findsOneWidget,
      );
      expect(find.text(r'$0.00'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving match history discards an in-flight detail response', (
    tester,
  ) async {
    final response = Completer<OpenQueueMatchDetail>();
    final queue = _Queue(response: response);
    await tester.pumpWidget(
      _app(
        profiles: _Profiles(games: [_historyGame()]),
        queue: queue,
      ),
    );
    await tester.pumpAndSettle();
    final historyButton = find.byKey(const ValueKey('you-match-history'));
    await tester.ensureVisible(historyButton);
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('you-history-older-solo')));
    await tester.pump();
    expect(queue.requested, ['older-solo']);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushMatchHistoryScreen), findsNothing);
    response.complete(_matchDetail());
    await tester.pumpAndSettle();
    expect(find.byType(FixtureDetailScreen), findsNothing);
    expect(find.byType(FieldrushYouScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('match history remains reachable during a rating outage', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        profiles: _Profiles(games: [_historyGame()]),
        ratings: _Ratings(fail: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Rating unavailable'), findsOneWidget);
    final historyButton = find.byKey(const ValueKey('you-match-history'));
    await tester.ensureVisible(historyButton);
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushMatchHistoryScreen), findsOneWidget);
    expect(
      find.byKey(const ValueKey('you-history-older-solo')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an older solo match keeps the detail response player rating', (
    tester,
  ) async {
    final detail = _matchDetail();
    final profiles = _Profiles(games: [_historyGame()]);
    await tester.pumpWidget(
      _app(
        profiles: profiles,
        queue: _Queue(detail: detail),
      ),
    );
    await tester.pumpAndSettle();
    final historyButton = find.byKey(const ValueKey('you-match-history'));
    await tester.ensureVisible(historyButton);
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('you-history-older-solo')));
    await tester.pumpAndSettle();
    final screen = tester.widget<FixtureDetailScreen>(
      find.byType(FixtureDetailScreen),
    );
    expect(screen.fixture.id, 'older-solo');
    expect(screen.playerRatingUpdate?.ratingBefore, 1188);
    expect(screen.playerRatingUpdate?.ratingChange, 11);
    expect(screen.playerRatingUpdate?.ratingAfter, 1199);
    expect(screen.showTeamRatings, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fans route closes with counts and returns to You safely', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('you-fans')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileConnectionsScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('You'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'last five follows market season boundaries and actual played order',
    () {
      final profile = _profile(
        events: [
          _event('late', '2026-10-08T10:00:00Z'),
          _event('old-season', '2026-10-01T06:59:59Z'),
          _event('first', '2026-10-01T07:00:00Z'),
          _event('new-season', '2027-01-01T07:00:00Z'),
          _event('end', '2027-01-01T06:59:59Z'),
        ],
      );
      expect(
        fieldrushSeasonResults(
          profile,
          leaderboardSeasons[1],
          region: 'phoenix',
        ).map((e) => e.id),
        ['end', 'late', 'first'],
      );
    },
  );

  test('last five excludes archived results after a ranking reset', () {
    final profile = _profile(
      resetAt: DateTime.parse('2026-10-10T12:00:00Z'),
      events: [
        _event('archived', '2026-10-09T12:00:00Z'),
        _event('current', '2026-10-11T12:00:00Z'),
      ],
    );
    expect(
      fieldrushSeasonResults(
        profile,
        leaderboardSeasons[1],
      ).map((event) => event.id),
      ['current'],
    );
    expect(profile.playerRating!.events.length, 2);
  });

  testWidgets(
    'history opens the actual match and preserves player SR meaning',
    (tester) async {
      ProfilePreviousGame? opened;
      final game = ProfilePreviousGame(
        id: 'solo-real',
        type: ProfileGameType.solo,
        playedAt: DateTime(2026, 10, 9),
        venue: 'Phoenix',
        homeName: 'White',
        homeTag: 'WHITE',
        homeEmblem: '',
        awayName: 'Black',
        awayTag: 'BLACK',
        awayEmblem: '',
        homeScore: 2,
        awayScore: 3,
        playerSide: 'BLACK',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: FieldrushMatchHistoryScreen(
            profile: _profile(
              games: [game],
              events: [
                _event('rated', '2026-10-09T10:00:00Z', gameId: game.id),
              ],
            ),
            onOpenGame: (game) async {
              opened = game;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 played · 1W 0D 0L'), findsOneWidget);
      expect(find.text('PLAYER SR'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('you-history-solo-real')));
      await tester.pumpAndSettle();
      expect(identical(opened, game), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _app({
  _Profiles? profiles,
  _Ratings? ratings,
  _Settings? settings,
  FieldrushAccountRepository? accounts,
  _Queue? queue,
  Future<void> Function()? onEdit,
  int activationTick = 0,
}) => MaterialApp(
  home: Scaffold(
    body: FieldrushYouScreen(
      activationTick: activationTick,
      profileRepository: profiles ?? _Profiles(),
      leaderboardRepository: ratings ?? _Ratings(),
      settingsRepository: settings ?? _Settings(),
      accountRepository: accounts,
      clanRepository: _Clans(),
      fixtureRepository: _Fixtures(),
      openQueueRepository: queue ?? _Queue(),
      onOpenAccount: onEdit ?? () async {},
      onOpenRanks: () {},
      onSignOut: () async {},
    ),
  ),
);

class _Profiles implements ProfileRepository {
  _Profiles({this.first, this.games = const []});
  final Completer<PlayerProfile>? first;
  final List<ProfilePreviousGame> games;
  String name = 'Ali A.';
  int loads = 0;
  @override
  String get currentUserId => 'me';
  @override
  Future<PlayerProfile> getCurrentProfile() async {
    loads++;
    if (loads == 1 && first != null) return first!.future;
    return _profile(name: name, games: games);
  }

  @override
  Future<ProfileConnections> getConnections() async =>
      const ProfileConnections(following: [], fans: [], discover: []);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ratings implements LeaderboardRepository {
  _Ratings({this.fail = false, this.refresh});
  final bool fail;
  final Completer<PlayerRatingLeaderboardEntry>? refresh;
  int loads = 0;
  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async {
    loads++;
    if (loads > 1 && refresh != null) return refresh!.future;
    if (fail) throw StateError('Unavailable');
    return const PlayerRatingLeaderboardEntry(
      rank: 38,
      profileId: 'me',
      displayName: 'Ali A.',
      username: 'ali',
      skillRating: 1199,
      matchesPlayed: 2,
      wins: 1,
      losses: 1,
      draws: 0,
      lastChange: -13,
      region: 'phoenix',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings implements YouSettingsRepository {
  _Settings({this.fail = false, this.wallet});
  final bool fail;
  final YouWallet? wallet;
  @override
  Future<YouNotificationPreferences> loadNotifications() async {
    if (fail) throw StateError('Unavailable');
    return const YouNotificationPreferences();
  }

  @override
  Future<YouWallet> loadWallet() async {
    if (fail) throw StateError('Unavailable');
    if (wallet != null) return wallet!;
    return YouWallet(
      primaryBalance: const FieldWalletBalance(
        currency: 'USD',
        balanceFils: 13000,
      ),
      balances: const [FieldWalletBalance(currency: 'USD', balanceFils: 13000)],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Clans implements ClanRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixtures implements FixtureRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Queue implements OpenQueueRepository {
  _Queue({this.response, this.detail});
  final Completer<OpenQueueMatchDetail>? response;
  final OpenQueueMatchDetail? detail;
  final List<String> requested = [];

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async {
    requested.add(gameId);
    if (response != null) return response!.future;
    return detail!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnavailableAccounts implements FieldrushAccountRepository {
  @override
  Future<FieldrushAccount> loadAccount() async =>
      throw StateError('Unavailable');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProfilePreviousGame _historyGame() => ProfilePreviousGame(
  id: 'older-solo',
  type: ProfileGameType.solo,
  playedAt: DateTime.utc(2026, 9, 10, 3, 30),
  venue: 'Phoenix',
  homeName: 'White',
  homeTag: 'WHITE',
  homeEmblem: '',
  awayName: 'Black',
  awayTag: 'BLACK',
  awayEmblem: '',
  homeScore: 4,
  awayScore: 3,
  playerSide: 'WHITE',
);

OpenQueueMatchDetail _matchDetail() => OpenQueueMatchDetail(
  game: OpenQueueGame(
    id: 'older-solo',
    status: 'FINAL',
    venue: 'Phoenix',
    startsAt: DateTime.utc(2026, 9, 10, 3, 30),
    endsAt: DateTime.utc(2026, 9, 10, 4, 30),
    timezone: 'America/Phoenix',
    currency: 'USD',
    priceFils: 13000,
    ageLabel: '18+',
    capacity: 14,
    confirmedCount: 14,
    spots: const {},
    whiteScore: 4,
    blackScore: 3,
  ),
  scorers: const [],
  timeline: const [],
  players: const [
    OpenQueuePlayer(
      id: 'me',
      displayName: 'Ali A.',
      role: OpenQueueRole.attacker,
      team: 'WHITE',
      played: true,
      isMe: true,
      ratingAtMatchStart: 1188,
      ratingChange: 11,
    ),
  ],
);

PlayerProfile _profile({
  String name = 'Ali A.',
  DateTime? resetAt,
  List<ProfileRatingEvent> events = const [],
  List<ProfilePreviousGame> games = const [],
}) => PlayerProfile(
  id: 'me',
  displayName: name,
  username: 'ali',
  bio: '',
  followingCount: 2,
  fansCount: 3,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: const [],
  career: const [],
  previousGames: games,
  playerRating: ProfilePlayerRating(
    ratingsResetAt: resetAt,
    skillRating: 1700,
    matchesPlayed: 100,
    wins: 70,
    losses: 20,
    draws: 10,
    lastChange: 30,
    region: 'phoenix',
    events: events,
  ),
);
ProfileRatingEvent _event(String id, String date, {String gameId = 'game'}) =>
    ProfileRatingEvent(
      id: id,
      sourceType: 'OPEN_QUEUE',
      sourceId: gameId,
      playedAt: DateTime.parse(date),
      opponentLabel: 'White',
      side: 'BLACK',
      result: 'WIN',
      ratingBefore: 1188,
      ratingChange: 11,
      ratingAfter: 1199,
    );
