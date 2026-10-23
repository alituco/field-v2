import 'dart:async';
import 'dart:convert';

import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  for (final status in ['OPEN', 'FULL', 'LIVE']) {
    for (final targeted in [false, true]) {
      test(
        '$status confirmed booking survives stalled optional detail (${targeted ? 'targeted' : 'list'})',
        () async {
          final detail = Completer<http.Response>();
          final now = DateTime.now();
          var detailReads = 0;
          final row = {
            'id': 'booking',
            'game_id': 'game',
            'profile_id': 'viewer',
            'role': 'ATT',
            'status': 'CONFIRMED',
            'team': 'BLACK',
            'amount_paid_fils': 13000,
            'booked_at': now
                .subtract(const Duration(days: 1))
                .toIso8601String(),
            'game': {
              'id': 'game',
              'status': status,
              'venue': 'Test field',
              'operational_state': 'NORMAL',
              'starts_at': now
                  .subtract(const Duration(minutes: 1))
                  .toIso8601String(),
              'ends_at': now.add(const Duration(minutes: 59)).toIso8601String(),
              'timezone': 'America/Phoenix',
              'price_fils': 13000,
              'currency': 'USD',
              'age_label': '18+',
              'capacity': 14,
            },
          };
          final client = SupabaseClient(
            'https://fieldrush-tests.invalid',
            'test-anon-key-not-a-secret',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((request) async {
              if (request.url.path == '/rest/v1/open_queue_bookings') {
                expectSync(
                  request.url.queryParameters['profile_id'],
                  'eq.viewer',
                );
                expectSync(
                  request.url.queryParameters['status'],
                  'eq.CONFIRMED',
                );
                return http.Response(
                  jsonEncode(targeted ? row : [row]),
                  200,
                  headers: {'content-type': 'application/json'},
                  request: request,
                );
              }
              expectSync(
                request.url.path,
                '/rest/v1/rpc/get_open_queue_match_detail',
              );
              detailReads++;
              return detail.future;
            }),
          );
          addTearDown(client.dispose);
          await client.auth.recoverSession(jsonEncode(_session()));
          final repository = SupabaseOpenQueueRepository(client: client);
          final result = targeted
              ? repository
                    .getMyUpcomingBookingForGame('game')
                    .then((booking) => [booking!])
              : repository.getMyUpcomingBookings();
          final bookings = await result;
          expect(detailReads, 1);
          expect(bookings.single.id, 'booking');
          expect(bookings.single.game.status, status);
          expect(bookings.single.game.currency, 'USD');
          expect(bookings.single.game.venue, 'Test field');
          expect(bookings.single.game.matchAverageSr, isNull);
          detail.complete(http.Response('{"message":"Stopped"}', 400));
          await Future<void>.delayed(Duration.zero);
        },
      );
    }
  }
}

Map<String, dynamic> _session() {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  String encoded(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': 'viewer', 'exp': expires})}.local-test-signature',
    'refresh_token': 'local-test-refresh-token',
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
