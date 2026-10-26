import 'dart:convert';

import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late SupabaseClient client;
  late SupabaseOpenQueueRepository repository;
  late List<http.Request> requests;
  late List<Map<String, dynamic>> bookingRows;
  late Map<String, Map<String, dynamic>> detailGames;
  late Set<String> detailFailures;
  late Set<String> metadataFailures;

  setUp(() async {
    requests = [];
    bookingRows = [_booking(_game('own-game'))];
    detailGames = {'own-game': _game('own-game')};
    detailFailures = {};
    metadataFailures = {};
    client = SupabaseClient(
      'https://upcoming-bookings.invalid',
      'public-test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/rest/v1/open_queue_bookings') {
          final single = request.url.queryParameters.containsKey('game_id');
          return _json(
            single ? bookingRows.singleOrNull : bookingRows,
            request,
          );
        }
        if (path == '/rest/v1/rpc/list_open_queue_games') {
          // This is precisely the old discovery cap that must not constrain
          // the caller's own reservations, including games in another city.
          return _json([
            for (var index = 0; index < 40; index++) _game('other-city-$index'),
          ], request);
        }
        if (path == '/rest/v1/rpc/get_open_queue_match_detail') {
          final gameId = (jsonDecode(request.body) as Map)['game_id_to_use'];
          if (detailFailures.contains(gameId)) {
            return _unavailable(request);
          }
          return _json({'game': detailGames[gameId]}, request);
        }
        if (path == '/rest/v1/open_queue_games') {
          final gameId = request.url.queryParameters['id']!.substring(3);
          if (metadataFailures.contains(gameId)) return _unavailable(request);
          return _json({
            'currency': detailGames[gameId]!['currency'],
            'field_id': 'saved-field',
            'location_address': '2425 E Deer Valley Road',
            'location_city': 'Phoenix',
            'location_state': 'AZ',
          }, request);
        }
        throw StateError('Unexpected mock request: ${request.method} $path');
      }),
    );
    repository = SupabaseOpenQueueRepository(client: client);
    await client.auth.recoverSession(jsonEncode(_session));
  });

  tearDown(() => client.dispose());

  test(
    'loads own booking outside discovery with canonical private detail',
    () async {
      detailGames['own-game'] = {
        ..._game('own-game'),
        'status': 'FULL',
        'confirmed_count': 14,
        'teams_assigned_at': '2000-01-01T00:00:00Z',
        'team_assignment_at': '2000-01-01T00:00:00Z',
        'white_average_sr': null,
        'black_average_sr': null,
        'match_average_sr': null,
        'team_sr_spread': null,
      };
      final bookings = await repository.getMyUpcomingBookings();
      final booking = bookings.single;
      expect(booking.id, 'booking-own-game');
      expect(booking.game.id, 'own-game');
      expect(booking.game.confirmedCount, 14);
      expect(booking.game.currency, 'USD');
      expect(booking.game.priceFils, 8000);
      expect(booking.game.priceLabel, r'$8.00');
      expect(booking.game.fieldId, 'saved-field');
      expect(booking.game.locationCity, 'Phoenix');
      expect(booking.kitInstruction, 'WEAR BLACK');
      expect(booking.game.whiteAverageSr, isNull);
      expect(booking.game.blackAverageSr, isNull);
      expect(booking.game.matchAverageSr, isNull);
      expect(
        requests.any((r) => r.url.path.contains('list_open_queue')),
        isFalse,
      );
      final ownQuery = requests.first.url.queryParameters;
      expect(ownQuery['profile_id'], 'eq.profile');
      expect(ownQuery['status'], 'eq.CONFIRMED');
      expect(ownQuery.containsKey('limit'), isFalse);
    },
  );

  test(
    'detail outage retains validated joined price, currency and reservation',
    () async {
      detailFailures.add('own-game');
      final booking = (await repository.getMyUpcomingBookings()).single;
      expect(booking.game.id, 'own-game');
      expect(booking.game.priceLabel, r'$8.00');
      expect(booking.game.locationCity, 'Phoenix');
      expect(booking.game.whiteAverageSr, isNull);
      expect(booking.game.teamsAssignedAt, isNull);
      expect(booking.kitInstruction, isNull);
      expect(
        requests.any((r) => r.url.path.contains('list_open_queue')),
        isFalse,
      );
    },
  );

  test('optional detail metadata outage cannot erase own booking', () async {
    metadataFailures.add('own-game');
    final booking = (await repository.getMyUpcomingBookings()).single;
    expect(booking.game.currency, 'USD');
    expect(booking.game.priceFils, 8000);
    expect(booking.game.locationCity, 'Phoenix');
  });

  for (final invalid in <Map<String, Object?>>[
    {'currency': null},
    {'currency': 'EUR'},
    {'price_fils': null},
    {'price_fils': -1},
    {'id': 'another-game'},
  ]) {
    test('incomplete joined metadata fails honestly: $invalid', () async {
      bookingRows = [
        _booking({..._game('own-game'), ...invalid}),
      ];
      // Keep the booking's reference canonical when testing a mismatched join.
      bookingRows.single['game_id'] = 'own-game';
      await expectLater(
        repository.getMyUpcomingBookings(),
        throwsA(isA<StateError>()),
      );
      expect(requests, hasLength(1));
    });
  }

  for (final invalid in <Map<String, Object?>>[
    {'status': 'CANCELLED'},
    {'status': 'FINAL'},
    {'white_score': 1, 'black_score': 0},
  ]) {
    test(
      'canonical detail excludes resolved or invalid active game: $invalid',
      () async {
        detailGames['own-game'] = {..._game('own-game'), ...invalid};
        expect(await repository.getMyUpcomingBookings(), isEmpty);
      },
    );
  }

  for (final state in ['NO_DATA', 'UNDER_REVIEW']) {
    test(
      'canonical unresolved $state booking stays visible without blocking',
      () async {
        detailGames['own-game'] = {
          ..._game('own-game'),
          'operational_state': state,
        };
        final booking = (await repository.getMyUpcomingBookings()).single;
        expect(booking.gameId, 'own-game');
        expect(booking.game.isActiveReservation, isTrue);
        expect(booking.game.hasPendingOperationalResolution, isTrue);
        expect(booking.game.blocksNewBooking, isFalse);
        expect(booking.game.supportedRoles.any(booking.game.canBook), isFalse);
        expect(
          (await repository.getMyUpcomingBookingForGame('own-game'))?.id,
          booking.id,
        );
      },
    );
  }

  for (final status in ['OPEN', 'FULL', 'LIVE']) {
    test('past kickoff retains a confirmed $status reservation', () async {
      detailGames['own-game'] = {
        ..._game('own-game'),
        'status': status,
        'starts_at': '2000-01-01T00:00:00Z',
      };
      final booking = (await repository.getMyUpcomingBookings()).single;
      expect(booking.id, 'booking-own-game');
      expect(booking.game.status, status);
      expect(booking.game.isActiveReservation, isTrue);
      expect(booking.game.isUpcomingReservation, isFalse);
    });
  }

  test(
    'one detail failure does not drop other reservations or change order',
    () async {
      final earlier = _game('earlier', startsAt: '2098-12-01T01:00:00Z');
      bookingRows.add(_booking(earlier));
      detailGames['earlier'] = earlier;
      detailFailures.add('earlier');
      final bookings = await repository.getMyUpcomingBookings();
      expect(bookings.map((b) => b.gameId), ['earlier', 'own-game']);
    },
  );

  test(
    'foreign detail identity is never substituted into own booking',
    () async {
      detailGames['own-game'] = _game('different-game');
      final booking = (await repository.getMyUpcomingBookings()).single;
      expect(booking.game.id, 'own-game');
      expect(booking.game.priceFils, 8000);
    },
  );

  test('specific booking lookup has the same validated fallback', () async {
    detailFailures.add('own-game');
    final booking = await repository.getMyUpcomingBookingForGame('own-game');
    expect(booking?.gameId, 'own-game');
    expect(booking?.game.currency, 'USD');
    expect(
      requests.any((r) => r.url.path.contains('list_open_queue')),
      isFalse,
    );
  });

  test(
    'specific lookup does not retain a canonically cancelled game',
    () async {
      detailGames['own-game'] = {..._game('own-game'), 'status': 'CANCELLED'};
      expect(await repository.getMyUpcomingBookingForGame('own-game'), isNull);
    },
  );

  test('signed-out lookup makes no booking or discovery request', () async {
    final signedOut = SupabaseClient(
      'https://signed-out.invalid',
      'public-key',
    );
    addTearDown(signedOut.dispose);
    expect(
      await SupabaseOpenQueueRepository(
        client: signedOut,
      ).getMyUpcomingBookings(),
      isEmpty,
    );
    expect(requests, isEmpty);
  });
}

http.Response _json(Object? value, http.Request request) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
  request: request,
);

http.Response _unavailable(http.Request request) => http.Response(
  jsonEncode({'code': '503', 'message': 'Temporarily unavailable'}),
  503,
  headers: {'content-type': 'application/json'},
  request: request,
);

Map<String, dynamic> _game(
  String id, {
  String startsAt = '2099-01-01T01:00:00Z',
}) => {
  'id': id,
  'status': 'OPEN',
  'venue': 'Reach 11 Fields',
  'starts_at': startsAt,
  'ends_at': DateTime.parse(
    startsAt,
  ).add(const Duration(hours: 1)).toIso8601String(),
  'timezone': 'America/Phoenix',
  'currency': 'USD',
  'price_fils': 8000,
  'capacity': 14,
  'confirmed_count': 4,
  'age_label': '18+',
  'location_city': 'Phoenix',
};

Map<String, dynamic> _booking(Map<String, dynamic> game) => {
  'id': 'booking-${game['id']}',
  'game_id': game['id'],
  'profile_id': 'profile',
  'status': 'CONFIRMED',
  'role': 'ATT',
  'team': 'BLACK',
  'amount_paid_fils': 8000,
  'booked_at': '2026-10-16T12:00:00Z',
  'game': game,
};

const _session = {
  'access_token': 'test-access-token',
  'token_type': 'bearer',
  'expires_in': 3600,
  'refresh_token': 'test-refresh-token',
  'user': {
    'id': 'profile',
    'aud': 'authenticated',
    'role': 'authenticated',
    'created_at': '2026-10-16T12:00:00Z',
    'app_metadata': {},
    'user_metadata': {},
  },
};
