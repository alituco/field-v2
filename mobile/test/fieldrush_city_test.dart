import 'dart:convert';

import 'package:field/src/markets/fieldrush_city.dart';
import 'package:field/src/markets/fieldrush_city_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('market city identity is not inferred from address or timezone', () {
    final game = OpenQueueGame.fromJson({
      'id': 'game',
      'starts_at': '2026-10-15T00:00:00Z',
      'ends_at': '2026-10-15T01:00:00Z',
      'timezone': 'America/Phoenix',
      'market_city_id': 'phoenix',
      'location_city': 'Tempe',
    });
    expect(game.belongsToCity('phoenix', 'America/Phoenix'), isTrue);
    expect(game.belongsToCity('tucson', 'America/Phoenix'), isFalse);
    expect(game.locationCity, 'Tempe');
    expect(
      OpenQueueGame.fromBookingJson({
        'id': 'game',
        'starts_at': '2026-10-15T00:00:00Z',
        'ends_at': '2026-10-15T01:00:00Z',
        'market_city_id': 'phoenix',
      }).marketCityId,
      'phoenix',
    );
  });

  test('game calendar uses IANA daylight saving rules, not fixed offsets', () {
    expect(
      gameLocalDateTime(DateTime.utc(2026, 7, 1, 12), 'America/New_York'),
      DateTime.utc(2026, 7, 1, 8),
    );
    expect(
      gameLocalDateTime(DateTime.utc(2026, 12, 1, 12), 'America/New_York'),
      DateTime.utc(2026, 12, 1, 7),
    );
    expect(
      gameLocalDateTime(DateTime.utc(2026, 7, 1, 12), 'America/Phoenix'),
      DateTime.utc(2026, 7, 1, 5),
    );
    expect(
      gameLocalDateTime(DateTime.utc(2026, 12, 1, 12), 'America/Phoenix'),
      DateTime.utc(2026, 12, 1, 5),
    );
    expect(
      gameLocalDateTime(DateTime.utc(2026, 7, 1, 22), 'Asia/Bahrain'),
      DateTime.utc(2026, 7, 2, 1),
    );
  });

  test(
    'preferred city is server owned and successful save invalidates discovery',
    () async {
      final requests = <http.Request>[];
      const city = {
        'id': 'phoenix',
        'display_name': 'Phoenix',
        'state': 'AZ',
        'country_code': 'US',
        'timezone': 'America/Phoenix',
        'active': true,
      };
      final client = SupabaseClient(
        'http://127.0.0.1:54321',
        'local-test',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('list_fieldrush_cities')
                  ? [city]
                  : {'preferred_city_id': 'phoenix'},
            ),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final repository = SupabaseFieldrushCityRepository(client: client);
      expect((await repository.loadPreferredCity()).label, 'Phoenix, AZ');
      final before = fieldrushCityRevision.value;
      expect((await repository.setPreferredCity('phoenix')).id, 'phoenix');
      expect(fieldrushCityRevision.value, before + 1);
      final save = requests.singleWhere(
        (r) => r.url.path.endsWith('set_my_fieldrush_city'),
      );
      expect(jsonDecode(save.body), {'city_id_to_use': 'phoenix'});
      expect(
        requests.any((r) => r.url.path.contains('player_ratings')),
        isFalse,
      );
    },
  );

  test('catalog parser preserves inactive state', () {
    final city = FieldrushCity.fromJson({
      'id': 'phoenix',
      'display_name': 'Phoenix',
      'state': 'AZ',
      'country_code': 'US',
      'timezone': 'America/Phoenix',
      'active': false,
    });
    expect(city.active, isFalse);
    expect(city.label, 'Phoenix, AZ');
  });
}
