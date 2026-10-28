import 'dart:convert';

import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('public record includes solo and former-clan games, newest first', () {
    final latest = _game('shared-id', day: 7, home: 3, away: 1);
    final games = [
      _game('old-win', day: 2, type: 'CLAN', home: 2, away: 0),
      _game('loss', day: 3, home: 0, away: 1),
      latest,
      _game('clan-win', day: 4, type: 'CLAN', home: 2, away: 0),
      _game('draw', day: 5, home: 1, away: 1),
      _game('shared-id', day: 6, type: 'CLAN', home: 0, away: 1),
      latest,
    ];
    final profile = _profile(games);

    // Legacy appearances and the current SR period are deliberately unrelated.
    expect(profile.appearances, 99);
    expect(profile.playerRating!.matchesPlayed, 0);
    expect(profile.playedCount, 6);
    expect(profile.winRatePercent, 50);
    expect(profile.lastFiveResults, [
      ProfileGameOutcome.win,
      ProfileGameOutcome.loss,
      ProfileGameOutcome.draw,
      ProfileGameOutcome.win,
      ProfileGameOutcome.loss,
    ]);
    expect(
      games.first.id,
      'old-win',
      reason: 'Getters must not sort in place.',
    );
  });

  test('an empty public record does not manufacture rate or form', () {
    final profile = _profile([]);
    expect(profile.playedCount, 0);
    expect(profile.winRatePercent, isNull);
    expect(profile.lastFiveResults, isEmpty);
    expect(profile.position, isNull);
    expect(profile.showUpPercent, isNull);
    expect(profile.isFollowedByMe, isFalse);
  });

  ProfilePreviousGame positionedGame(String id, int day, String? role) =>
      ProfilePreviousGame.fromJson({
        ..._gameJson(id, day: day, home: 1, away: 0),
        'player_role': role,
      });

  test(
    'displayed position uses the most played role, not preference or latest alone',
    () {
      final profile = _profile([
        positionedGame('latest-gk', 9, 'GK'),
        positionedGame('def-two', 5, 'DEF'),
        positionedGame('def-one', 2, 'DEF'),
      ], position: 'Attacker');
      expect(profile.playedPosition, 'DEF');
      expect(profile.playedPositionLabel, 'Defender');
    },
  );

  test(
    'equal role counts use the latest played role across the full history',
    () {
      final profile = _profile([
        positionedGame('old-gk', 1, 'GK'),
        positionedGame('latest-def', 9, 'DEF'),
        positionedGame('newer-gk', 8, 'GK'),
        positionedGame('old-def', 2, 'DEF'),
      ]);
      expect(profile.playedPosition, 'DEF');
      expect(profile.copyWith(isFollowedByMe: true).playedPosition, 'DEF');
    },
  );

  test('duplicate history rows do not change the displayed role', () {
    final defender = positionedGame('def', 8, 'DEF');
    expect(
      _profile([
        defender,
        defender,
        positionedGame('keeper', 9, 'GK'),
      ]).playedPosition,
      'GK',
    );
  });

  test('no played or known positions never display preferred metadata', () {
    expect(_profile([], position: 'Goalkeeper').playedPositionLabel, isNull);
    expect(
      _profile([
        positionedGame('unknown', 8, null),
        positionedGame('invalid', 9, 'Captain'),
      ], position: 'Defender').playedPositionLabel,
      isNull,
    );
  });

  test(
    'played positions normalize roles and retain known historical midfield',
    () {
      for (final (role, label) in [
        (' gk ', 'Goalkeeper'),
        ('defender', 'Defender'),
        ('ATT', 'Attacker'),
        ('MID', 'Midfielder'),
      ]) {
        expect(
          _profile([positionedGame('game', 9, role)]).playedPositionLabel,
          label,
        );
      }
    },
  );

  test('missing score is unknown, not an artificial goalless draw', () {
    final unknown = ProfilePreviousGame.fromJson({
      'match_id': 'missing-score',
      'match_type': 'SOLO',
      'played_at': '2026-10-08T18:00:00Z',
      'player_side': 'WHITE',
      'home_score': null,
      'away_score': null,
    });
    final profile = _profile([
      _game('known-win', day: 7, home: 1, away: 0),
      unknown,
    ]);
    expect(unknown.hasFinalScore, isFalse);
    expect(unknown.outcome, isNull);
    expect(profile.playedCount, 2);
    expect(profile.winRatePercent, isNull);
    expect(profile.lastFiveResults, [null, ProfileGameOutcome.win]);
    expect(_game('negative', day: 1, home: -1, away: 0).outcome, isNull);
  });

  test('unknown historical side remains an unknown form slot', () {
    final profile = _profile([
      _game('unknown-side', day: 2, home: 1, away: 0, side: ''),
      _game('known-win', day: 1, home: 0, away: 1, side: 'BLACK'),
    ]);
    expect(profile.playedCount, 2);
    expect(profile.winRatePercent, isNull);
    expect(profile.lastFiveResults, [null, ProfileGameOutcome.win]);
  });

  test('follow copy preserves public metadata and history', () {
    final original = _profile(
      [_game('win', day: 1, home: 1, away: 0)],
      position: 'Midfielder',
      showUpPercent: 92.5,
    );
    final followed = original.copyWith(isFollowedByMe: true, fansCount: 1);
    expect(followed.isFollowedByMe, isTrue);
    expect(followed.fansCount, 1);
    expect(followed.position, 'Midfielder');
    expect(followed.showUpPercent, 92.5);
    expect(followed.playedCount, 1);
    expect(followed.winRatePercent, 100);
    expect(followed.copyWith(highlights: []).isFollowedByMe, isTrue);
    expect(followed.copyWith(isFollowedByMe: false).isFollowedByMe, isFalse);
    expect(original.isFollowedByMe, isFalse);
  });

  for (final available in [true, false]) {
    test(
      'position ties use actual kickoff metadata when available: $available',
      () async {
        final client = SupabaseClient(
          'https://fieldrush-tests.invalid',
          'test-anon-key-not-a-secret',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            final path = request.url.path;
            final Object? payload;
            if (path.endsWith('/profiles')) {
              payload = {'id': 'player', 'display_name': 'Player'};
            } else if (path.endsWith('/clan_members') ||
                path.endsWith('/get_player_rating_history')) {
              payload = null;
            } else if (path.endsWith('/list_profile_previous_games')) {
              payload = [
                {
                  ..._gameJson('keeper', day: 9, home: 1, away: 0),
                  'player_role': 'GK',
                },
                {
                  ..._gameJson('defender', day: 8, home: 1, away: 0),
                  'player_role': 'DEF',
                },
              ];
            } else if (path.endsWith('/open_queue_games')) {
              expect(
                request.url.queryParameters['select'],
                'id,timezone,open_queue_events(occurred_at)',
              );
              expect(
                request.url.queryParameters['open_queue_events.event_type'],
                'eq.MATCH_STARTED',
              );
              if (!available) {
                return http.Response(
                  'Metadata unavailable',
                  503,
                  request: request,
                );
              }
              payload = [
                {
                  'id': 'keeper',
                  'timezone': 'America/Phoenix',
                  'open_queue_events': [
                    {'occurred_at': 'invalid'},
                    {'occurred_at': '2026-10-07T19:00:00Z'},
                    {'occurred_at': '2026-10-07T18:00:00Z'},
                  ],
                },
                {
                  'id': 'defender',
                  'timezone': 'America/Phoenix',
                  'open_queue_events': [
                    {'occurred_at': '2026-10-09T18:00:00Z'},
                  ],
                },
              ];
            } else if (path.endsWith('/profile_follows') ||
                path.endsWith('/profile_highlights') ||
                path.endsWith('/list_profile_career_entries')) {
              payload = [];
            } else {
              throw StateError('Unexpected public-profile request: $path');
            }
            return http.Response(
              jsonEncode(payload),
              200,
              request: request,
              headers: {
                'content-type': 'application/json',
                if (request.headers['prefer']?.contains('count=exact') == true)
                  'content-range': '*/0',
              },
            );
          }),
        );
        addTearDown(client.dispose);
        final profile = await SupabaseProfileRepository(
          client: client,
        ).getProfile('player');
        expect(profile.playedCount, 2);
        expect(profile.playedPosition, available ? 'DEF' : 'GK');
        if (available) {
          expect(
            profile.previousGames.first.playedAt.toUtc(),
            DateTime.utc(2026, 10, 7, 18),
          );
        }
      },
    );
  }

  for (final gameCount in [1000, 1001]) {
    test(
      'public history loads all $gameCount matches in bounded pages',
      () async {
        final historyRequests = <http.Request>[];
        final client = SupabaseClient(
          'https://fieldrush-tests.invalid',
          'test-anon-key-not-a-secret',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            final path = request.url.path;
            Object? payload;
            if (path.endsWith('/profiles')) {
              payload = {'id': 'player', 'display_name': 'Player'};
            } else if (path.endsWith('/clan_members') ||
                path.endsWith('/get_player_rating_history')) {
              payload = null;
            } else if (path.endsWith('/list_profile_previous_games')) {
              historyRequests.add(request);
              final offset = int.parse(request.url.queryParameters['offset']!);
              expect(request.url.queryParameters['limit'], '500');
              final end = (offset + 500).clamp(0, gameCount);
              // A missing trailing response terminates an exact-size history;
              // a partial trailing page terminates a larger history.
              payload = offset >= gameCount
                  ? null
                  : [
                      for (var index = offset; index < end; index++)
                        _gameJson(
                          'clan-game-$index',
                          day: gameCount - index,
                          home: index.isEven ? 1 : 0,
                          away: index.isEven ? 0 : 1,
                          type: 'CLAN',
                        ),
                    ];
            } else {
              payload = [];
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
        addTearDown(client.dispose);

        final profile = await SupabaseProfileRepository(
          client: client,
        ).getProfile('player');
        expect(profile.previousGames, hasLength(gameCount));
        expect(profile.playedCount, gameCount);
        expect(
          profile.winRatePercent,
          closeTo((gameCount / 2).ceil() * 100 / gameCount, 0.0001),
        );
        expect(
          historyRequests.map(
            (request) => request.url.queryParameters['offset'],
          ),
          ['0', '500', '1000'],
        );
        expect(profile.lastFiveResults, [
          ProfileGameOutcome.win,
          ProfileGameOutcome.loss,
          ProfileGameOutcome.win,
          ProfileGameOutcome.loss,
          ProfileGameOutcome.win,
        ]);
      },
    );
  }

  for (final viewerId in <String?>['viewer', 'other', null, 'player']) {
    test(
      'public repository follows are relative to viewer $viewerId',
      () async {
        final requests = <http.Request>[];
        final client = SupabaseClient(
          'https://fieldrush-tests.invalid',
          'test-anon-key-not-a-secret',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            requests.add(request);
            final path = request.url.path;
            final Object? payload;
            if (path.endsWith('/profiles')) {
              payload = {
                'id': 'player',
                'display_name': 'Public Player',
                'username': 'public.player',
                'bio': 'Plays solo',
                // Even if an unexpected payload includes private data, the
                // public repository must neither select nor hydrate it.
                'phone': '+16025550101',
                'email': 'private@example.com',
              };
            } else if (path.endsWith('/clan_members')) {
              payload = null;
            } else if (path.endsWith('/profile_follows')) {
              final query = request.url.queryParameters;
              if (query['following_id'] == 'eq.player' &&
                  query.containsKey('follower_id')) {
                payload = query['follower_id'] == 'eq.viewer'
                    ? {'follower_id': 'viewer'}
                    : null;
              } else if (query['following_id'] == 'eq.player') {
                // Simulate a full server page that does not contain this
                // viewer; their relationship must still resolve correctly.
                payload = [
                  for (var index = 0; index < 1000; index++)
                    {'follower_id': 'fan-$index'},
                ];
              } else {
                payload = [
                  {'following_id': 'friend'},
                ];
              }
            } else if (path.endsWith('/list_profile_previous_games')) {
              payload = [
                _gameJson('win', day: 7, home: 3, away: 1),
                _gameJson('loss', day: 6, home: 0, away: 1),
                _gameJson('draw', day: 5, home: 1, away: 1),
              ];
            } else if (path.endsWith('/get_player_rating_history')) {
              payload = {'skill_rating': 1200, 'matches_played': 0};
            } else if (path.endsWith('/open_queue_games')) {
              payload = [
                for (final id in ['win', 'loss', 'draw'])
                  {'id': id, 'timezone': 'America/Phoenix'},
              ];
            } else if (path.endsWith('/profile_highlights') ||
                path.endsWith('/list_profile_career_entries')) {
              payload = [];
            } else {
              throw StateError('Unexpected public-profile request: $path');
            }
            return http.Response(
              jsonEncode(payload),
              200,
              headers: {
                'content-type': 'application/json',
                if (request.headers['prefer']?.contains('count=exact') == true)
                  'content-range':
                      request.url.queryParameters['following_id'] == 'eq.player'
                      ? '0-0/1000'
                      : '0-0/1',
              },
              request: request,
            );
          }),
        );
        addTearDown(client.dispose);
        if (viewerId != null) {
          await client.auth.recoverSession(jsonEncode(_session(viewerId)));
        }

        final profile = await SupabaseProfileRepository(
          client: client,
        ).getProfile('player');
        expect(profile.isFollowedByMe, viewerId == 'viewer');
        expect(profile.followingCount, 1);
        expect(profile.fansCount, 1000);
        expect(profile.clan, isNull);
        expect(profile.appearances, 0);
        expect(profile.playedCount, 3);
        expect(profile.winRatePercent, closeTo(100 / 3, 0.001));
        expect(profile.lastFiveResults, [
          ProfileGameOutcome.win,
          ProfileGameOutcome.loss,
          ProfileGameOutcome.draw,
        ]);
        expect(profile.phone, isNull);
        expect(profile.position, isNull);
        expect(profile.showUpPercent, isNull);
        final profileRequest = requests.singleWhere(
          (request) => request.url.path.endsWith('/profiles'),
        );
        expect(
          profileRequest.url.queryParameters['select'],
          'id,display_name,username,bio,avatar_url',
        );
        final exactFollowRequests = requests.where(
          (request) =>
              request.url.path.endsWith('/profile_follows') &&
              request.url.queryParameters.containsKey('following_id') &&
              request.url.queryParameters.containsKey('follower_id'),
        );
        if (viewerId == null || viewerId == 'player') {
          expect(exactFollowRequests, isEmpty);
        } else {
          expect(exactFollowRequests, hasLength(1));
          expect(exactFollowRequests.single.url.queryParameters, {
            'select': 'follower_id',
            'following_id': 'eq.player',
            'follower_id': 'eq.$viewerId',
          });
        }
      },
    );
  }
}

Map<String, dynamic> _gameJson(
  String id, {
  required int day,
  required int home,
  required int away,
  String type = 'SOLO',
  String? side,
}) => {
  'match_id': id,
  'match_type': type,
  'played_at': DateTime.utc(2026, 10, day, 18).toIso8601String(),
  'home_score': home,
  'away_score': away,
  'player_side': side ?? (type == 'SOLO' ? 'WHITE' : 'HOME'),
  'player_role': type == 'SOLO' ? 'GK' : null,
};

ProfilePreviousGame _game(
  String id, {
  required int day,
  required int home,
  required int away,
  String type = 'SOLO',
  String? side,
}) => ProfilePreviousGame.fromJson(
  _gameJson(id, day: day, home: home, away: away, type: type, side: side),
);

PlayerProfile _profile(
  List<ProfilePreviousGame> games, {
  String? position,
  double? showUpPercent,
}) => PlayerProfile(
  id: 'player',
  displayName: 'Player',
  username: 'player',
  bio: '',
  followingCount: 0,
  fansCount: 0,
  appearances: 99,
  goals: 0,
  assists: 0,
  highlights: const [],
  career: const [],
  previousGames: games,
  position: position,
  showUpPercent: showUpPercent,
  playerRating: ProfilePlayerRating.fromJson({'matches_played': 0}),
);

Map<String, dynamic> _session(String id) {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  String encoded(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': id, 'exp': expires})}.local-test-signature',
    'refresh_token': 'local-test-refresh-token',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': id,
      'aud': 'authenticated',
      'role': 'authenticated',
      'created_at': '2026-10-01T00:00:00Z',
      'app_metadata': {},
      'user_metadata': {},
    },
  };
}
