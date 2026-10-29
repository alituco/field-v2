import 'dart:convert';

import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/ranking/player_rating_visibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'unknown fixture clan SR remains unknown without a seed or division',
    () {
      for (final json in [
        {'id': 'clan'},
        {'id': 'clan', 'skill_rating': null},
      ]) {
        final clan = FixtureClan.fromJson(json);
        expect(clan.skillRating, isNull);
        expect(clan.rank, isNull);
        expect(clan.copyWith(regionRank: 2).skillRating, isNull);
      }
      expect(
        FixtureClan.fromJson({'id': 'clan', 'skill_rating': 1500}).skillRating,
        1500,
      );
    },
  );

  test('solo adapter never replaces hidden team averages with 1200', () {
    final fixture = OpenQueueMatchDetail.fromJson({
      'game': {
        'starts_at': '2026-10-14T19:00:00Z',
        'ends_at': '2026-10-14T20:00:00Z',
        'white_average_sr': null,
        'black_average_sr': null,
        'match_average_sr': null,
        'team_sr_spread': null,
      },
    }).toFixture();
    expect(fixture.homeClan.skillRating, isNull);
    expect(fixture.awayClan?.skillRating, isNull);
    expect(fixture.homeAveragePlayerRating, isNull);
    expect(fixture.awayAveragePlayerRating, isNull);
    expect(fixture.matchAveragePlayerRating, isNull);
    expect(fixture.teamRatingSpread, isNull);
  });

  test(
    'explicit null fixture aggregates cannot be reconstructed from lineups',
    () {
      final fixture = Fixture.fromJson({
        ..._fixtureJson(),
        'home_average_player_rating': null,
        'away_average_player_rating': null,
        'match_average_player_rating': null,
        'team_rating_spread': null,
        'fixture_player_appearances': [
          _appearance('home', 'HOME', 1300),
          _appearance('away', 'AWAY', 1200),
        ],
      });
      expect(fixture.homeAveragePlayerRating, isNull);
      expect(fixture.awayAveragePlayerRating, isNull);
      expect(fixture.matchAveragePlayerRating, isNull);
      expect(fixture.teamRatingSpread, isNull);
    },
  );

  test('hidden fixture snapshots mask deltas and prevent partial averages', () {
    final fixture = Fixture.fromJson({
      ..._fixtureJson(),
      'fixture_player_appearances': [
        _appearance('home-visible', 'HOME', 1300),
        {
          ..._appearance('home-hidden', 'HOME', 1000),
          'rating_visible': false,
          'rating_change': 20,
        },
        _appearance('away', 'AWAY', 1200),
      ],
    });
    final hidden = fixture.homeLineup.singleWhere((p) => p.id == 'home-hidden');
    expect(hidden.displayedRating, isNull);
    expect(hidden.ratingChange, isNull);
    expect(fixture.homeAveragePlayerRating, isNull);
    expect(fixture.awayAveragePlayerRating, 1200);
    expect(fixture.matchAveragePlayerRating, isNull);
    expect(fixture.teamRatingSpread, isNull);
  });

  for (final status in ['HELD', 'NOT_RATED', 'UNSETTLED']) {
    test('$status does not expose a fixture rating result', () {
      final fixture = Fixture.fromJson({
        ..._fixtureJson(),
        'rating_status': status,
        'fixture_player_appearances': [
          {..._appearance('home', 'HOME', 1300), 'rating_change': 20},
        ],
      });
      expect(fixture.homeLineup.single.ratingChange, isNull);
      expect(permitsPublicRatingResult(status), isFalse);
      expect(publicRatingStatusLabel(status), isNotNull);
    });
  }

  test(
    'fixture query omits protected appearance SR while keeping lineups',
    () async {
      var queriedFixtures = false;
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-anon-key-not-a-secret',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final path = request.url.path;
          final Object? payload;
          if (path.endsWith('/cancel_underfilled_fixtures')) {
            payload = null;
          } else if (path.endsWith('/list_fieldrush_profile_identities')) {
            payload = [
              {'id': 'home', 'display_name': 'home', 'content_hidden': false},
            ];
          } else if (path.endsWith('/list_fieldrush_clan_identities')) {
            payload = [
              for (final id in ['home', 'away'])
                {
                  'id': id,
                  'name': id == 'home' ? 'Home' : 'Away',
                  'content_hidden': false,
                },
            ];
          } else if (path.endsWith('/clans')) {
            payload = [];
          } else if (path.endsWith('/fixtures')) {
            queriedFixtures = true;
            final selection = request.url.queryParameters['select']!;
            expect(selection, contains('fixture_player_appearances('));
            expect(selection, isNot(contains('rating_at_start')));
            expect(selection, isNot(contains('rating_change')));
            final appearance = _appearance('home', 'HOME', 1300)
              ..remove('rating_at_start');
            payload = {
              ..._fixtureJson(),
              'fixture_player_appearances': [appearance],
            };
          } else {
            throw StateError('Unexpected request: $path');
          }
          return http.Response(
            jsonEncode(payload),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final fixture = await SupabaseFixtureRepository(
        client: client,
      ).getFixture('fixture');
      expect(queriedFixtures, isTrue);
      expect(fixture.homeLineup.single.id, 'home');
      expect(fixture.homeLineup.single.displayedRating, isNull);
      expect(fixture.homeLineup.single.ratingChange, isNull);
      expect(fixture.homeAveragePlayerRating, isNull);
    },
  );
}

Map<String, dynamic> _fixtureJson() => {
  'id': 'fixture',
  'status': 'FINAL',
  'home_clan_id': 'home',
  'away_clan_id': 'away',
  'home_clan': {'id': 'home', 'name': 'Home'},
  'away_clan': {'id': 'away', 'name': 'Away'},
  'match_date': '2026-10-14',
};

Map<String, dynamic> _appearance(String id, String side, int rating) => {
  'profile_id': id,
  'side': side,
  'played': true,
  'rating_at_start': rating,
  'player': {'id': id, 'display_name': id},
};
