import 'dart:convert';

import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('saved field location', () {
    test('feed and booking snapshots preserve the saved field and map pin', () {
      for (final game in [
        OpenQueueGame.fromJson({..._game, ..._location}),
        OpenQueueGame.fromBookingJson({..._game, ..._location}),
      ]) {
        expect(game.fieldId, 'field-1');
        expect(game.locationLabel, '2425 E Deer Valley Road, Phoenix, AZ, US');
        expect(game.directionsUri?.host, 'www.google.com');
        expect(
          game.directionsUri?.queryParameters['query'],
          '33.6849,-112.0308',
        );
      }
    });

    test('invalid or partial coordinates fall back to the saved address', () {
      for (final coordinates in [
        {'location_latitude': null},
        {'location_longitude': null},
        {'location_latitude': 91},
        {'location_longitude': -181},
        {'location_latitude': 'NaN'},
        {'location_longitude': 'Infinity'},
      ]) {
        final game = OpenQueueGame.fromJson({
          ..._game,
          ..._location,
          ...coordinates,
        });
        expect(
          game.directionsUri?.queryParameters['query'],
          '2425 E Deer Valley Road, Phoenix, AZ, US',
        );
      }
    });

    test('zero is a real coordinate and numeric strings are supported', () {
      final game = OpenQueueGame.fromJson({
        ..._game,
        ..._location,
        'location_latitude': '0',
        'location_longitude': '0',
      });
      expect(game.directionsUri?.queryParameters['query'], '0.0,0.0');
    });

    test('legacy games do not invent field IDs, addresses, or map pins', () {
      final game = OpenQueueGame.fromJson(_game);
      expect(game.fieldId, isNull);
      expect(game.locationLabel, isNull);
      expect(game.locationLatitude, isNull);
      expect(game.locationLongitude, isNull);
      expect(
        game.directionsUri?.queryParameters['query'],
        'Reach 11 Fields · Pitch 2 Phoenix AZ',
      );
      expect(
        OpenQueueGame.fromJson({..._game, 'venue': ''}).directionsUri,
        isNull,
      );
    });
  });

  group('saved game metadata hydration', () {
    late SupabaseClient client;
    late SupabaseOpenQueueRepository repository;
    late List<http.Request> requests;
    String? nestedGameKey;
    Map<String, Object?>? metadata;

    setUp(() {
      requests = [];
      nestedGameKey = null;
      metadata = {'id': 'game-1', 'currency': 'USD', ..._location};
      client = SupabaseClient(
        'https://fieldrush-location-tests.invalid',
        'public-test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/rest/v1/rpc/get_open_queue_match_detail') {
            return _json(
              nestedGameKey == null ? _game : {nestedGameKey!: _game},
              request,
            );
          }
          if (request.url.path.startsWith('/rest/v1/rpc/list_open_queue')) {
            return _json([_game], request);
          }
          if (request.url.path == '/rest/v1/open_queue_games') {
            final isSingle = request.url.queryParameters['id'] == 'eq.game-1';
            return _json(isSingle ? metadata : [metadata], request);
          }
          throw StateError('Unexpected request: ${request.url.path}');
        }),
      );
      repository = SupabaseOpenQueueRepository(client: client);
    });

    tearDown(() async => client.dispose());

    void assertLocation(OpenQueueGame game) {
      expect(game.fieldId, 'field-1');
      expect(game.locationLatitude, 33.6849);
      expect(game.locationLongitude, -112.0308);
      expect(game.currency, 'USD');
      final lookup = requests.last.url;
      expect(lookup.path, '/rest/v1/open_queue_games');
      expect(lookup.queryParameters['select'], contains('location_address'));
      expect(lookup.queryParameters['select'], contains('location_latitude'));
      expect(lookup.queryParameters['select'], contains('location_longitude'));
      expect(requests.any((r) => r.url.path == '/rest/v1/fields'), isFalse);
    }

    test(
      'all discovery feeds hydrate location without reading the catalog',
      () async {
        for (final load in [
          repository.listGames,
          () => repository.listMarketGames('America/Phoenix'),
          repository.listFixtureGames,
        ]) {
          final games = await load();
          assertLocation(games.single);
        }
      },
    );

    test('all detail response shapes preserve location snapshots', () async {
      for (final key in [null, 'game', 'open_queue_game']) {
        nestedGameKey = key;
        final detail = await repository.getMatchDetail('game-1');
        assertLocation(detail.game);
      }
    });

    test('legacy null snapshots continue to load', () async {
      metadata = {'id': 'game-1', 'currency': 'USD'};
      final game = (await repository.listGames()).single;
      expect(game.venue, 'Reach 11 Fields · Pitch 2');
      expect(game.locationLabel, isNull);
      expect(game.fieldId, isNull);
    });
  });
}

http.Response _json(Object? value, http.Request request) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
  request: request,
);

const _game = {
  'id': 'game-1',
  'status': 'OPEN',
  'venue': 'Reach 11 Fields · Pitch 2',
  'starts_at': '2030-01-12T01:00:00Z',
  'ends_at': '2030-01-12T02:00:00Z',
  'timezone': 'America/Phoenix',
  'currency': 'USD',
};

const _location = {
  'field_id': 'field-1',
  'location_address': '2425 E Deer Valley Road',
  'location_city': 'Phoenix',
  'location_state': 'AZ',
  'location_country_code': 'US',
  'location_latitude': 33.6849,
  'location_longitude': -112.0308,
};
