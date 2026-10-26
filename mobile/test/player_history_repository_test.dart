import 'dart:async';
import 'dart:convert';

import 'package:field/src/core/read_timeout.dart';
import 'package:field/src/profile/player_history_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _payment({String id = 'payment-1'}) => {
  'id': id,
  'paid_at': '2026-10-25T03:00:00Z',
  'amount_minor': 1300,
  'currency': 'USD',
  'payment_method': 'VISA',
  'purpose': 'SOLO_BOOKING',
  'game_starts_at': '2026-11-01T03:30:00Z',
  'timezone': 'America/Phoenix',
};

Map<String, dynamic> _cancelled() => {
  'game_id': 'game-1',
  'booking_id': 'booking-1',
  'starts_at': '2026-11-01T03:30:00Z',
  'ends_at': '2026-11-01T04:30:00Z',
  'cancelled_at': '2026-10-30T23:00:00Z',
  'check_in_at': '2026-11-01T03:00:00Z',
  'venue': 'Reach 11 Fields',
  'timezone': 'America/Phoenix',
  'amount_paid_minor': 1300,
  'currency': 'USD',
  'payment_method': 'APPLE_PAY',
};

http.Response _response(Object data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);

SupabasePlayerHistoryRepository _repository(
  Future<http.Response> Function(http.Request) handler,
) => SupabasePlayerHistoryRepository(
  client: SupabaseClient(
    'https://history.example.test',
    'test-public-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      final response = await handler(request);
      return http.Response(
        response.body,
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    }),
  ),
);

void main() {
  test('history initializes market timezones without another game screen', () {
    final payment = PlayerPaymentHistoryEntry.fromJson(_payment());
    expect(payment.localPaidAt, payment.paidAt.toLocal());
    expect(payment.localGameStartsAt?.day, 31);
    expect(payment.localGameStartsAt?.hour, 20);
  });

  test('USD and historical BHD retain their actual minor-unit precision', () {
    expect(
      PlayerPaymentHistoryEntry.fromJson(_payment()).amountLabel,
      r'$13.00',
    );
    final legacy = PlayerPaymentHistoryEntry.fromJson({
      ..._payment(),
      'currency': 'BHD',
      'amount_minor': 1299,
      'refunded_minor': 1299,
      'refund_destination': 'FIELD_WALLET',
    });
    expect(legacy.amountLabel, 'BHD 1.299');
    expect(legacy.refundAmountLabel, 'BHD 1.299');
    expect(legacy.refundDestinationLabel, 'Field Wallet');
    expect(legacy.isFullyRefunded, isTrue);
  });

  test(
    'full settled external refund remains full despite admin review flag',
    () {
      final entry = PlayerPaymentHistoryEntry.fromJson({
        ..._payment(),
        'refunded_minor': 1300,
        'refund_needs_review': true,
        'failed_refund_minor': 0,
      });
      expect(entry.isFullyRefunded, isTrue);
      expect(entry.isPartiallyRefunded, isFalse);
      expect(entry.amountLabel, r'$13.00');
    },
  );

  test('partial, pending and failed refunds never become fully refunded', () {
    final entry = PlayerPaymentHistoryEntry.fromJson({
      ..._payment(),
      'refunded_minor': 650,
      'pending_refund_minor': 300,
      'failed_refund_minor': 350,
    });
    expect(entry.isFullyRefunded, isFalse);
    expect(entry.isPartiallyRefunded, isTrue);
    expect(entry.hasPendingRefund, isTrue);
    expect(entry.hasFailedRefund, isTrue);
  });

  test('payment labels do not invent card last digits', () {
    expect(
      PlayerPaymentHistoryEntry.fromJson(_payment()).paymentMethodLabel,
      'Visa',
    );
    expect(playerHistoryPaymentMethod('APPLE_PAY'), 'Apple Pay');
    expect(playerHistoryPaymentMethod('GOOGLE_PAY'), 'Google Pay');
    expect(playerHistoryPaymentMethod('UNKNOWN'), 'Card');
  });

  test('cancelled receipts preserve unknown consequences', () {
    final entry = PlayerCancelledGame.fromJson(_cancelled());
    expect(entry.ratingSummary, 'Not recorded');
    expect(entry.strikesSummary, 'Not recorded');
    expect(entry.streakSummary, 'Not recorded');
    expect(entry.refundSummary, 'No refund recorded');
  });

  test('neutral and preserved rating consequences are distinct', () {
    final neutral = PlayerCancelledGame.fromJson({
      ..._cancelled(),
      'rating_change': 0,
      'strike_change': 0,
      'streak_kept': true,
      'refunded_minor': 1300,
    });
    expect(neutral.ratingSummary, 'No change');
    expect(neutral.strikesSummary, 'No change');
    expect(neutral.streakSummary, 'Kept');
    expect(neutral.refundSummary, r'$13.00 back to Apple Pay');
    final adjusted = PlayerCancelledGame.fromJson({
      ..._cancelled(),
      'rating_change': 32,
      'strike_change': 1,
    });
    expect(adjusted.ratingSummary, '+32 SR');
    expect(adjusted.strikesSummary, '+1');
  });

  test('hidden placement SR is not represented as a missing receipt', () {
    final entry = PlayerCancelledGame.fromJson({
      ..._cancelled(),
      'rating_hidden': true,
    });
    expect(entry.ratingSummary, 'Placement in progress');
  });

  test(
    'partial cancellation refunds retain settled and outstanding results',
    () {
      final partial = {..._cancelled(), 'refunded_minor': 400};
      expect(
        PlayerCancelledGame.fromJson({
          ...partial,
          'pending_refund_minor': 400,
        }).refundSummary,
        r'$4.00 back to Apple Pay · $4.00 pending',
      );
      expect(
        PlayerCancelledGame.fromJson({
          ...partial,
          'failed_refund_minor': 400,
        }).refundSummary,
        r'$4.00 back to Apple Pay · refund needs review',
      );
    },
  );

  test(
    'financial calendar is consistent across games in different markets',
    () {
      final phoenix = PlayerPaymentHistoryEntry.fromJson({
        ..._payment(),
        'paid_at': '2026-11-01T01:00:00Z',
      });
      final bahrain = PlayerPaymentHistoryEntry.fromJson({
        ..._payment(),
        'paid_at': '2026-11-01T01:00:00Z',
        'timezone': 'Asia/Bahrain',
      });
      expect(phoenix.localPaidAt, bahrain.localPaidAt);
    },
  );

  test('cancelled cards use saved check-in time and the game calendar', () {
    final entry = PlayerCancelledGame.fromJson(_cancelled());
    expect(entry.localStartsAt?.day, 31);
    expect(entry.localDisplayStartsAt?.hour, 20);
    expect(entry.localDisplayStartsAt?.minute, 0);
    final fallback = PlayerCancelledGame.fromJson(
      {..._cancelled()}..remove('check_in_at'),
    );
    expect(fallback.localCheckInAt, entry.localCheckInAt);
    final unknown = PlayerCancelledGame.fromJson({
      ..._cancelled(),
      'timezone': 'Not/A_Zone',
    });
    expect(unknown.localStartsAt, isNull);
    expect(unknown.localCheckInAt, isNull);
  });

  test('free cancelled booking never claims a refund was transferred', () {
    final entry = PlayerCancelledGame.fromJson({
      ..._cancelled(),
      'amount_paid_minor': 0,
    });
    expect(entry.refundSummary, 'No payment taken');
  });

  test('malformed monetary data cannot silently become a free charge', () {
    expect(
      () => PlayerPaymentHistoryEntry.fromJson(
        {..._payment()}..remove('amount_minor'),
      ),
      throwsFormatException,
    );
    expect(
      () => PlayerPaymentHistoryEntry.fromJson({
        ..._payment(),
        'amount_minor': -1,
      }),
      throwsFormatException,
    );
    expect(
      () => PlayerPaymentHistoryEntry.fromJson({
        ..._payment(),
        'currency': 'EUR',
      }),
      throwsFormatException,
    );
  });

  test(
    'owner payment RPC carries cursor and limit without any profile override',
    () async {
      final repository = _repository((request) async {
        expect(request.url.path, '/rest/v1/rpc/list_my_player_payments');
        expect(jsonDecode(request.body), {
          'before_at': '2026-10-25T03:00:00.000Z',
          'before_id': 'previous-payment',
          'page_size': 3,
        });
        return _response({
          'items': [_payment()],
          'next_cursor': {
            'created_at': '2026-10-25T03:00:00Z',
            'id': 'payment-1',
          },
        });
      });
      final page = await repository.getPayments(
        cursor: PlayerHistoryCursor(
          createdAt: DateTime.utc(2026, 10, 25, 3),
          id: 'previous-payment',
        ),
        limit: 3,
      );
      expect(page.items.single.id, 'payment-1');
      expect(page.nextCursor?.id, 'payment-1');
    },
  );

  test(
    'cancelled history cursor represents advertised start, not cancellation',
    () async {
      final repository = _repository((request) async {
        expect(request.url.path, '/rest/v1/rpc/list_my_cancelled_games');
        expect(
          jsonDecode(request.body)['before_at'],
          '2026-11-01T03:30:00.000Z',
        );
        return _response({
          'items': [_cancelled()],
          'next_cursor': null,
        });
      });
      final page = await repository.getCancelledGames(
        cursor: PlayerHistoryCursor(
          createdAt: DateTime.utc(2026, 11, 1, 3, 30),
          id: 'game-2',
        ),
      );
      expect(page.items.single.id, 'game-1');
      expect(page.items.single.bookingId, 'booking-1');
      expect(page.nextCursor, isNull);
    },
  );

  test('repository has no cross-session cached financial records', () async {
    var calls = 0;
    final repository = _repository(
      (request) async => _response({
        'items': [_payment(id: 'owner-${++calls}')],
        'next_cursor': null,
      }),
    );
    expect((await repository.getPayments()).items.single.id, 'owner-1');
    expect((await repository.getPayments()).items.single.id, 'owner-2');
  });

  test(
    'invalid page shape, item or cursor fails instead of dropping records',
    () async {
      for (final body in [
        <dynamic>[],
        {
          'items': ['invalid'],
          'next_cursor': null,
        },
        {
          'items': [_payment()],
          'next_cursor': {'created_at': '2026-10-25T03:00:00Z'},
        },
      ]) {
        final repository = _repository((request) async => _response(body));
        await expectLater(repository.getPayments(), throwsFormatException);
      }
    },
  );

  test('invalid page limits fail before invoking the network', () async {
    var called = false;
    final repository = _repository((request) async {
      called = true;
      return _response({'items': [], 'next_cursor': null});
    });
    await expectLater(repository.getPayments(limit: 0), throwsRangeError);
    await expectLater(
      repository.getCancelledGames(limit: 101),
      throwsRangeError,
    );
    expect(called, isFalse);
  });

  testWidgets('history requests time out and ignore a late response', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final repository = _repository((request) => pending.future);
    Object? failure;
    var loaded = false;
    unawaited(
      repository.getPayments().then<void>(
        (_) => loaded = true,
        onError: (Object error) => failure = error,
      ),
    );
    await tester.pump();
    await tester.pump(fieldReadTimeout);
    await tester.pump();
    expect(failure, isA<TimeoutException>());
    expect(loaded, isFalse);
    pending.complete(
      _response({
        'items': [_payment()],
        'next_cursor': null,
      }),
    );
    await tester.pumpAndSettle();
    expect(loaded, isFalse);
  });
}
