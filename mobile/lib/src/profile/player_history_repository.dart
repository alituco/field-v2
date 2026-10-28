import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/read_timeout.dart';
import '../open_queue/open_queue.dart' show gameLocalDateTime;

/// A stable descending-history position. For cancelled games [createdAt] is
/// the advertised match start, so merged match history retains calendar order.
class PlayerHistoryCursor {
  const PlayerHistoryCursor({required this.createdAt, required this.id});

  final DateTime createdAt;
  final String id;

  factory PlayerHistoryCursor.fromJson(Map<String, dynamic> json) =>
      PlayerHistoryCursor(
        createdAt: _date(json, 'created_at'),
        id: _string(json, 'id'),
      );
}

class PlayerHistoryPage<T> {
  const PlayerHistoryPage({required this.items, this.nextCursor});

  final List<T> items;
  final PlayerHistoryCursor? nextCursor;
}

class PlayerPaymentHistoryEntry {
  const PlayerPaymentHistoryEntry({
    required this.id,
    required this.paidAt,
    required this.amountMinor,
    this.currency = 'USD',
    this.paymentMethod = 'CARD',
    this.purpose = 'SOLO_BOOKING',
    this.gameId,
    this.bookingId,
    this.gameStartsAt,
    this.timezone,
    this.venue,
    this.refundedMinor = 0,
    this.pendingRefundMinor = 0,
    this.failedRefundMinor = 0,
    this.refundNeedsReview = false,
    this.gameCancelled = false,
    this.refundDestination = 'ORIGINAL_PAYMENT_METHOD',
  });

  final String id;
  final DateTime paidAt;
  final int amountMinor;
  final String currency;
  final String paymentMethod;
  final String purpose;
  final String? gameId;
  final String? bookingId;
  final DateTime? gameStartsAt;
  final String? timezone;
  final String? venue;
  final int refundedMinor;
  final int pendingRefundMinor;
  final int failedRefundMinor;
  final bool refundNeedsReview;
  final bool gameCancelled;
  final String refundDestination;

  String get amountLabel => playerHistoryMoney(amountMinor, currency);
  String get refundAmountLabel => playerHistoryMoney(refundedMinor, currency);
  String get paymentMethodLabel => playerHistoryPaymentMethod(paymentMethod);
  String get refundDestinationLabel =>
      refundDestination == 'FIELD_WALLET' ? 'Field Wallet' : paymentMethodLabel;
  bool get isFullyRefunded => amountMinor > 0 && refundedMinor >= amountMinor;
  bool get isPartiallyRefunded => refundedMinor > 0 && !isFullyRefunded;
  bool get hasPendingRefund => pendingRefundMinor > 0;
  bool get hasFailedRefund => failedRefundMinor > 0 || refundNeedsReview;
  DateTime get localPaidAt => paidAt.toLocal();
  DateTime? get localGameStartsAt =>
      gameStartsAt == null ? null : _localDate(gameStartsAt!, timezone);

  factory PlayerPaymentHistoryEntry.fromJson(Map<String, dynamic> json) =>
      PlayerPaymentHistoryEntry(
        id: _string(json, 'id'),
        paidAt: _date(json, 'paid_at'),
        amountMinor: _money(json, 'amount_minor', required: true),
        currency: _currency(json),
        paymentMethod: _optionalString(json['payment_method']) ?? 'CARD',
        purpose: _optionalString(json['purpose']) ?? 'SOLO_BOOKING',
        gameId: _optionalString(json['game_id']),
        bookingId: _optionalString(json['booking_id']),
        gameStartsAt: _optionalDate(json['game_starts_at']),
        timezone: _optionalString(json['timezone']),
        venue: _optionalString(json['venue']),
        refundedMinor: _money(json, 'refunded_minor'),
        pendingRefundMinor: _money(json, 'pending_refund_minor'),
        failedRefundMinor: _money(json, 'failed_refund_minor'),
        refundNeedsReview: json['refund_needs_review'] == true,
        gameCancelled: json['game_cancelled'] == true,
        refundDestination:
            _optionalString(json['refund_destination']) ??
            'ORIGINAL_PAYMENT_METHOD',
      );
}

class PlayerCancelledGame {
  const PlayerCancelledGame({
    required this.gameId,
    required this.bookingId,
    required this.startsAt,
    required this.endsAt,
    required this.cancelledAt,
    required this.venue,
    required this.timezone,
    this.checkInAt,
    this.reason,
    this.currency = 'USD',
    this.amountPaidMinor = 0,
    this.refundedMinor = 0,
    this.pendingRefundMinor = 0,
    this.failedRefundMinor = 0,
    this.refundNeedsReview = false,
    this.paymentMethod = 'CARD',
    this.refundDestination = 'ORIGINAL_PAYMENT_METHOD',
    this.ratingChange,
    this.ratingHidden = false,
    this.strikeChange,
    this.streakKept,
  });

  final String gameId;
  final String bookingId;
  final DateTime startsAt;
  final DateTime endsAt;
  final DateTime cancelledAt;
  final DateTime? checkInAt;
  final String venue;
  final String timezone;
  final String? reason;
  final String currency;
  final int amountPaidMinor;
  final int refundedMinor;
  final int pendingRefundMinor;
  final int failedRefundMinor;
  final bool refundNeedsReview;
  final String paymentMethod;
  final String refundDestination;
  final int? ratingChange;
  final bool ratingHidden;
  final int? strikeChange;
  final bool? streakKept;

  String get id => gameId;
  DateTime? get localStartsAt => _localDate(startsAt, timezone);
  DateTime? get localCancelledAt => _localDate(cancelledAt, timezone);
  DateTime? get localCheckInAt => _localDate(
    checkInAt ?? startsAt.subtract(const Duration(minutes: 30)),
    timezone,
  );
  DateTime? get localDisplayStartsAt => localCheckInAt;
  String get refundSummary {
    if (amountPaidMinor == 0) return 'No payment taken';
    final destination = refundDestination == 'FIELD_WALLET'
        ? 'Field Wallet'
        : playerHistoryPaymentMethod(paymentMethod);
    if (refundedMinor >= amountPaidMinor) {
      return '${playerHistoryMoney(refundedMinor, currency)} back to $destination';
    }
    if (pendingRefundMinor > 0) {
      if (refundedMinor > 0) {
        return '${playerHistoryMoney(refundedMinor, currency)} back to $destination · '
            '${playerHistoryMoney(pendingRefundMinor, currency)} pending';
      }
      return '${playerHistoryMoney(pendingRefundMinor, currency)} refund pending';
    }
    if (failedRefundMinor > 0 || refundNeedsReview) {
      if (refundedMinor > 0) {
        return '${playerHistoryMoney(refundedMinor, currency)} back to $destination · '
            'refund needs review';
      }
      return 'Refund needs review';
    }
    if (refundedMinor > 0) {
      return '${playerHistoryMoney(refundedMinor, currency)} back to $destination';
    }
    return 'No refund recorded';
  }

  String get ratingSummary => ratingHidden
      ? 'Placement in progress'
      : switch (ratingChange) {
          null => 'Not recorded',
          0 => 'No change',
          final value => '${value > 0 ? '+' : ''}$value SR',
        };
  String get strikesSummary => switch (strikeChange) {
    null => 'Not recorded',
    0 => 'No change',
    final value => '${value > 0 ? '+' : ''}$value',
  };
  String get streakSummary => switch (streakKept) {
    true => 'Kept',
    false => 'Not kept',
    null => 'Not recorded',
  };

  factory PlayerCancelledGame.fromJson(Map<String, dynamic> json) =>
      PlayerCancelledGame(
        gameId: _string(json, 'game_id'),
        bookingId: _string(json, 'booking_id'),
        startsAt: _date(json, 'starts_at'),
        endsAt: _date(json, 'ends_at'),
        cancelledAt: _date(json, 'cancelled_at'),
        checkInAt: _optionalDate(json['check_in_at']),
        venue: _optionalString(json['venue']) ?? '',
        timezone: _string(json, 'timezone'),
        reason: _optionalString(json['reason']),
        currency: _currency(json),
        amountPaidMinor: _money(json, 'amount_paid_minor', required: true),
        refundedMinor: _money(json, 'refunded_minor'),
        pendingRefundMinor: _money(json, 'pending_refund_minor'),
        failedRefundMinor: _money(json, 'failed_refund_minor'),
        refundNeedsReview: json['refund_needs_review'] == true,
        paymentMethod: _optionalString(json['payment_method']) ?? 'CARD',
        refundDestination:
            _optionalString(json['refund_destination']) ??
            'ORIGINAL_PAYMENT_METHOD',
        ratingChange: _optionalInt(json['rating_change']),
        ratingHidden: json['rating_hidden'] == true,
        strikeChange: _optionalInt(json['strike_change']),
        streakKept: json['streak_kept'] as bool?,
      );
}

abstract class PlayerHistoryRepository {
  Future<PlayerHistoryPage<PlayerPaymentHistoryEntry>> getPayments({
    PlayerHistoryCursor? cursor,
    int limit = 30,
  });

  Future<PlayerHistoryPage<PlayerCancelledGame>> getCancelledGames({
    PlayerHistoryCursor? cursor,
    int limit = 30,
  });
}

class SupabasePlayerHistoryRepository implements PlayerHistoryRepository {
  SupabasePlayerHistoryRepository({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;
  SupabaseClient get _supabase => _client ?? Supabase.instance.client;

  @override
  Future<PlayerHistoryPage<PlayerPaymentHistoryEntry>> getPayments({
    PlayerHistoryCursor? cursor,
    int limit = 30,
  }) => _page(
    'list_my_player_payments',
    cursor,
    limit,
    PlayerPaymentHistoryEntry.fromJson,
  );

  @override
  Future<PlayerHistoryPage<PlayerCancelledGame>> getCancelledGames({
    PlayerHistoryCursor? cursor,
    int limit = 30,
  }) => _page(
    'list_my_cancelled_games',
    cursor,
    limit,
    PlayerCancelledGame.fromJson,
  );

  Future<PlayerHistoryPage<T>> _page<T>(
    String rpc,
    PlayerHistoryCursor? cursor,
    int limit,
    T Function(Map<String, dynamic>) parse,
  ) async {
    RangeError.checkValueInInterval(limit, 1, 100, 'limit');
    final response = await _supabase
        .rpc(
          rpc,
          params: {
            'before_at': cursor?.createdAt.toUtc().toIso8601String(),
            'before_id': cursor?.id,
            'page_size': limit,
          },
        )
        .timeout(fieldReadTimeout);
    if (response is! Map || response['items'] is! List) {
      throw const FormatException('History returned an invalid response.');
    }
    final next = response['next_cursor'];
    if (next != null && next is! Map) {
      throw const FormatException('History returned an invalid cursor.');
    }
    return PlayerHistoryPage(
      items: [
        for (final row in response['items'] as List)
          if (row is Map)
            parse(Map<String, dynamic>.from(row))
          else
            throw const FormatException('History returned an invalid item.'),
      ],
      nextCursor: next == null
          ? null
          : PlayerHistoryCursor.fromJson(
              Map<String, dynamic>.from(next as Map),
            ),
    );
  }
}

String playerHistoryPaymentMethod(String method) => switch (method) {
  'APPLE_PAY' => 'Apple Pay',
  'GOOGLE_PAY' => 'Google Pay',
  'VISA' => 'Visa',
  'MASTERCARD' => 'Mastercard',
  'BENEFITPAY' => 'BenefitPay',
  'FIELD_WALLET' => 'Field Wallet',
  'FREE' => 'Free',
  _ => 'Card',
};

String playerHistoryMoney(int amountMinor, String currency) {
  final decimals = currency == 'BHD' ? 3 : 2;
  final divisor = currency == 'BHD' ? 1000 : 100;
  return '${currency == 'USD' ? r'$' : '$currency '}'
      '${(amountMinor / divisor).toStringAsFixed(decimals)}';
}

DateTime? _localDate(DateTime value, String? timezone) {
  if (timezone == null || timezone.isEmpty) return null;
  try {
    return gameLocalDateTime(value, timezone);
  } on tz.LocationNotFoundException {
    return null;
  }
}

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
String _string(Map<String, dynamic> data, String key) =>
    _optionalString(data[key]) ??
    (throw FormatException('History is missing $key.'));
DateTime _date(Map<String, dynamic> data, String key) =>
    _optionalDate(data[key]) ??
    (throw FormatException('History is missing $key.'));
DateTime? _optionalDate(Object? value) => value == null
    ? null
    : value is String
    ? DateTime.parse(value)
    : throw const FormatException('History has an invalid date.');
int? _optionalInt(Object? value) => value == null
    ? null
    : value is int
    ? value
    : value is String
    ? int.parse(value)
    : throw const FormatException('History has an invalid amount.');
int _money(Map<String, dynamic> data, String key, {bool required = false}) {
  if (required && data[key] == null) {
    throw FormatException('History is missing $key.');
  }
  final value = _optionalInt(data[key]) ?? 0;
  if (value < 0) throw FormatException('History has a negative $key.');
  return value;
}

String _currency(Map<String, dynamic> data) {
  final value = _string(data, 'currency');
  if (value != 'USD' && value != 'BHD') {
    throw const FormatException('History has an unsupported currency.');
  }
  return value;
}
