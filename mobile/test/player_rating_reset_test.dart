import 'dart:convert';

import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/profile/profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('reset retains archived history but excludes it from current form', () {
    final rating = ProfilePlayerRating.fromJson({
      'ratings_reset_at': '2026-10-10T12:00:00Z',
      'events': [
        {'event_id': 'old', 'played_at': '2026-10-10T11:59:59Z'},
        {'event_id': 'boundary', 'played_at': '2026-10-10T12:00:00Z'},
        {'event_id': 'new', 'played_at': '2026-10-11T00:00:00Z'},
      ],
    });
    expect(rating.ratingsResetAt, DateTime.utc(2026, 10, 10, 12));
    expect(rating.events.length, 3);
    expect(rating.currentPeriodEvents.map((event) => event.id), [
      'boundary',
      'new',
    ]);
  });

  test('accounts without a reset retain all current history', () {
    final rating = ProfilePlayerRating.fromJson({
      'events': [
        {'event_id': 'old', 'played_at': '2026-10-09T00:00:00Z'},
      ],
    });
    expect(rating.ratingsResetAt, isNull);
    expect(rating.currentPeriodEvents, same(rating.events));
  });

  test('preexisting future-dated events cannot leak across the reset', () {
    final rating = ProfilePlayerRating.fromJson({
      'ratings_reset_at': '2026-10-10T12:00:00Z',
      'ratings_reset_sequence': 50,
      'events': [
        {
          'event_id': 'old-future',
          'played_at': '2026-10-20T12:00:00Z',
          'applied_sequence': 50,
        },
        {
          'event_id': 'new',
          'played_at': '2026-10-11T12:00:00Z',
          'applied_sequence': 51,
        },
      ],
    });
    expect(rating.events.length, 2);
    expect(rating.currentPeriodEvents.single.id, 'new');
  });

  for (final accountRegion in ['', 'phoenix']) {
    test(
      'dual rating lookup preserves ${accountRegion.isEmpty ? 'unearned city' : 'earned city'} without legacy data',
      () async {
        final requests = <http.Request>[];
        final client = SupabaseClient(
          'https://fieldrush-tests.invalid',
          'test-anon-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            requests.add(request);
            final Object data;
            switch (request.url.path) {
              case '/rest/v1/rpc/get_fieldrush_player_ratings':
                expect(jsonDecode(request.body), {
                  'profile_id_to_use': 'user-a',
                  'season_starts_on': '2026-10-01',
                  'season_ends_on': '2026-12-31',
                });
                data = {
                  'primary_city_id': accountRegion.isEmpty
                      ? null
                      : accountRegion,
                  'ratings': {
                    for (final track in ['OUTFIELD', 'GOALKEEPER'])
                      track: {
                        'profile_id': 'user-a',
                        'matches_played': 0,
                        'rank': 0,
                        'skill_rating': 1200,
                        'region': accountRegion,
                      },
                  },
                };
              default:
                throw StateError(
                  'Unexpected mock request: ${request.url.path}',
                );
            }
            return http.Response(
              jsonEncode(data),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        addTearDown(client.dispose);
        String encoded(Object value) => base64Url
            .encode(utf8.encode(jsonEncode(value)))
            .replaceAll('=', '');
        final expires =
            DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000;
        await client.auth.recoverSession(
          jsonEncode({
            'access_token':
                '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': 'user-a', 'exp': expires})}.test-signature',
            'refresh_token': 'test-refresh-token',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': 'user-a',
              'aud': 'authenticated',
              'role': 'authenticated',
              'created_at': '2026-10-09T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          }),
        );
        final rating = await SupabaseLeaderboardRepository(
          client: client,
        ).loadCurrentPlayerRating(leaderboardSeasons[1]);
        expect(rating.matchesPlayed, 0);
        expect(rating.isRanked, isFalse);
        expect(rating.gamesNeededToRank, 2);
        expect(
          requests
              .where((request) => request.url.path == '/rest/v1/player_ratings')
              .length,
          0,
        );
        expect(requests.length, 1);
        expect(rating.region, accountRegion);
      },
    );
  }
}
