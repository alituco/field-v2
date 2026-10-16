import 'dart:convert';

import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const blocked =
      'Finish or cancel your earlier game checkout before booking another game.';
  const reference = 'd5287b6a-22f6-4e55-a230-5582f8ebf0b4';
  late SupabaseClient client;
  late SupabaseOpenQueueRepository repository;
  var quotes = 0;
  var recoveries = 0;
  String message = blocked;
  Map<String, Object?> recovery = {'recovered': true};
  var recoveryFails = false;
  var stillBlocked = false;

  setUp(() {
    quotes = 0;
    recoveries = 0;
    message = blocked;
    recovery = {'recovered': true};
    recoveryFails = false;
    stillBlocked = false;
    client = SupabaseClient(
      'https://checkout-recovery.invalid',
      'public-fixture-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        Object result;
        var status = 200;
        if (request.url.path.endsWith('preview_open_queue_booking_cost')) {
          quotes++;
          if (quotes == 1 || stillBlocked) {
            result = {'code': 'P0001', 'message': message};
            status = 400;
          } else {
            result = {'currency': 'USD', 'total_fils': 13000};
          }
        } else if (request.url.path.endsWith('stripe-payment')) {
          recoveries++;
          expect(jsonDecode(request.body), {'action': 'recover'});
          result = recoveryFails ? {'error': 'Unavailable'} : recovery;
          status = recoveryFails ? 503 : 200;
        } else {
          fail('Unexpected request: ${request.url.path}');
        }
        return http.Response(
          jsonEncode(result),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    repository = SupabaseOpenQueueRepository(client: client);
  });
  tearDown(() => client.dispose());
  Future<OpenQueueBookingCostPreview> quote() => repository.previewBookingCost(
    gameId: 'game-fixture',
    role: OpenQueueRole.defender,
  );

  test(
    'earlier-checkout block recovers once then reruns every quote guard',
    () async {
      expect((await quote()).totalFils, 13000);
      expect(quotes, 2);
      expect(recoveries, 1);
    },
  );

  test(
    'unresolved provider state keeps the original block and never re-quotes',
    () async {
      recovery = {'recovered': false};
      await expectLater(quote(), throwsA(isA<PostgrestException>()));
      expect(quotes, 1);
      expect(recoveries, 1);
    },
  );

  test(
    'review-required recovery exposes only its stable support reference',
    () async {
      recovery = {'recovered': false, 'review_reference': reference};
      await expectLater(
        quote(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(reference),
          ),
        ),
      );
      expect(quotes, 1);
    },
  );

  test('provider outage does not discard the checkout lease', () async {
    recoveryFails = true;
    await expectLater(quote(), throwsA(isA<PostgrestException>()));
    expect(quotes, 1);
    expect(recoveries, 1);
  });

  test(
    'repeated quote guard does not cause an infinite recovery loop',
    () async {
      stillBlocked = true;
      await expectLater(quote(), throwsA(isA<PostgrestException>()));
      expect(quotes, 2);
      expect(recoveries, 1);
    },
  );

  test(
    'ordinary booking and eligibility failures never invoke payment recovery',
    () async {
      message = 'You can only be registered in one upcoming or active game.';
      await expectLater(quote(), throwsA(isA<PostgrestException>()));
      expect(quotes, 1);
      expect(recoveries, 0);
    },
  );

  test('malformed recovery success and review reference fail closed', () async {
    recovery = {'recovered': 'true', 'review_reference': 'not-a-reference'};
    await expectLater(quote(), throwsA(isA<PostgrestException>()));
    expect(quotes, 1);
    expect(recoveries, 1);
  });
}
