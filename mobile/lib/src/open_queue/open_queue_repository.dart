import 'package:supabase_flutter/supabase_flutter.dart';

import 'open_queue.dart';
import 'open_queue_party_repository.dart';
import '../payments/payment_service.dart';
import '../reliability/reliability.dart';

abstract class OpenQueueRepository {
  Future<List<OpenQueueGame>> listGames();

  Future<List<OpenQueueGame>> listFixtureGames();

  Future<OpenQueueMatchDetail> getMatchDetail(String gameId);

  Future<OpenQueueBooking?> getMyUpcomingBooking();

  Future<List<OpenQueueBooking>> getMyUpcomingBookings();

  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  });

  Future<OpenQueueCancellationPreview> previewCancellation(String bookingId);

  Future<OpenQueueBooking> cancelBooking(String bookingId);
}

abstract interface class OpenQueueBookingLookupRepository {
  Future<OpenQueueBooking?> getMyUpcomingBookingForGame(String gameId);
}

abstract interface class OpenQueueEmbeddedCheckoutRepository {
  Future<OpenQueueBooking> bookGameWithCollector({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required PaymentCollector collectPayment,
  });
}

abstract interface class OpenQueuePaymentStatusRepository {
  Future<PaymentRefundState> checkRefundStatus(String intentId);
}

/// Market discovery applies the market predicate before the server feed limit.
/// The historical, all-market [OpenQueueRepository.listGames] stays available.
abstract interface class OpenQueueMarketRepository {
  Future<List<OpenQueueGame>> listMarketGames(String timezone);
}

/// Canonical competition-city discovery; cities can share a timezone.
abstract interface class OpenQueueCityRepository {
  Future<List<OpenQueueGame>> listCityGames(String cityId);
}

abstract interface class OpenQueueReliabilityLookupRepository {
  Future<MatchReliabilityContext?> getMatchReliabilityContext(String gameId);
}

abstract interface class OpenQueueBookingCostPreviewRepository {
  Future<OpenQueueBookingCostPreview> previewBookingCost({
    required String gameId,
    required OpenQueueRole role,
  });
}

class SupabaseOpenQueueRepository
    with SupabaseOpenQueuePartyRepository
    implements
        OpenQueueRepository,
        OpenQueueMarketRepository,
        OpenQueueCityRepository,
        OpenQueueBookingLookupRepository,
        OpenQueueEmbeddedCheckoutRepository,
        OpenQueuePaymentStatusRepository,
        OpenQueueReliabilityLookupRepository,
        OpenQueueBookingCostPreviewRepository {
  SupabaseOpenQueueRepository({SupabaseClient? client}) : _supabase = client;

  final SupabaseClient? _supabase;
  SupabaseClient get _client => _supabase ?? Supabase.instance.client;

  @override
  SupabaseClient get partyClient => _client;

  static const _gameMetadataSelect = '''
    currency,
    highest_division,
    lowest_division,
    goalkeeper_capacity,
    defender_capacity,
    midfielder_capacity,
    attacker_capacity,
    field_id,
    market_city_id,
    location_address,
    location_city,
    location_state,
    location_country_code,
    location_latitude,
    location_longitude
  ''';

  static const _bookingSelect =
      '''
    id,
    game_id,
    profile_id,
    role,
    status,
    team,
    amount_paid_fils,
    booked_at,
    cancelled_at,
    refund_percent,
    refund_amount_fils,
    refund_destination,
    refund_status,
    game:open_queue_games!open_queue_bookings_game_id_fkey(
      id,
      status,
      operational_state,
      operational_state_updated_at,
      operational_reason_code,
      venue,
      starts_at,
      ends_at,
      timezone,
      price_fils,
      $_gameMetadataSelect,
      age_label,
      capacity,
      white_score,
      black_score,
      teams_assigned_at
    )
  ''';

  @override
  Future<List<OpenQueueGame>> listGames() async {
    final response = await _client.rpc('list_open_queue_games');
    final rows = await _withGameMetadata(response as List<dynamic>);
    return [for (final row in rows) OpenQueueGame.fromJson(row)];
  }

  @override
  Future<List<OpenQueueGame>> listMarketGames(String timezone) async {
    final response = await _client.rpc(
      'list_open_queue_games_for_market',
      params: {'timezone_to_use': timezone},
    );
    final rows = await _withGameMetadata(response as List<dynamic>);
    return [for (final row in rows) OpenQueueGame.fromJson(row)];
  }

  @override
  Future<List<OpenQueueGame>> listCityGames(String cityId) async {
    final response = await _client.rpc(
      'list_open_queue_games_for_city',
      params: {'city_id_to_use': cityId},
    );
    final rows = await _withGameMetadata(response as List<dynamic>);
    return [for (final row in rows) OpenQueueGame.fromJson(row)];
  }

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async {
    final response = await _client.rpc('list_open_queue_fixture_games');
    final rows = await _withGameMetadata(response as List<dynamic>);
    return [for (final row in rows) OpenQueueGame.fromJson(row)];
  }

  Future<List<Map<String, dynamic>>> _withGameMetadata(
    List<dynamic> values,
  ) async {
    final rows = [
      for (final value in values) Map<String, dynamic>.from(value as Map),
    ];
    if (rows.isEmpty) return rows;
    // Existing table-returning RPC signatures remain compatible for history.
    // Enrich with currency, formation and the game's saved location snapshot,
    // without exposing the admin-only fields catalog to player clients.
    final metadata = await _client
        .from('open_queue_games')
        .select('id, $_gameMetadataSelect')
        .inFilter('id', [for (final row in rows) row['id'] as String]);
    final byId = {for (final row in metadata) row['id']: row};
    return [
      for (final row in rows)
        {
          ...row,
          ...?byId[row['id']],
          'currency': _requiredCurrency(byId[row['id']]?['currency']),
        },
    ];
  }

  String _requiredCurrency(Object? value) {
    if (value == 'USD' || value == 'BHD') return value as String;
    throw StateError('The game currency is unavailable. Please try again.');
  }

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async {
    final response = await _client.rpc(
      'get_open_queue_match_detail',
      params: {'game_id_to_use': gameId},
    );
    final row = switch (response) {
      final Map value => Map<String, dynamic>.from(value),
      final List value when value.isNotEmpty => Map<String, dynamic>.from(
        value.first as Map,
      ),
      _ => throw StateError('Solo match not found.'),
    };
    final metadata = await _client
        .from('open_queue_games')
        .select(_gameMetadataSelect)
        .eq('id', gameId)
        .single();
    metadata['currency'] = _requiredCurrency(metadata['currency']);
    final gameKey = row['game'] is Map
        ? 'game'
        : row['open_queue_game'] is Map
        ? 'open_queue_game'
        : null;
    if (gameKey == null) {
      row.addAll(metadata);
    } else {
      row[gameKey] = {
        ...Map<String, dynamic>.from(row[gameKey] as Map),
        ...metadata,
      };
    }
    return OpenQueueMatchDetail.fromJson(row);
  }

  @override
  Future<MatchReliabilityContext?> getMatchReliabilityContext(
    String gameId,
  ) async {
    final response = await _client.rpc(
      'get_match_reliability_context',
      params: {'match_kind_to_use': 'SOLO', 'match_id_to_use': gameId},
    );
    final row = switch (response) {
      final Map value => Map<String, dynamic>.from(value),
      final List value when value.isNotEmpty => Map<String, dynamic>.from(
        value.first as Map,
      ),
      _ => null,
    };
    return row == null ? null : MatchReliabilityContext.fromJson(row);
  }

  @override
  Future<OpenQueueBookingCostPreview> previewBookingCost({
    required String gameId,
    required OpenQueueRole role,
  }) async {
    Future<dynamic> quote() => _client.rpc(
      'preview_open_queue_booking_cost',
      params: {'game_id_to_book': gameId, 'role_to_book': role.code},
    );
    dynamic response;
    try {
      response = await quote();
    } on PostgrestException catch (error) {
      if (error.code != 'P0001' ||
          error.message !=
              'Finish or cancel your earlier game checkout before booking another game.') {
        rethrow;
      }
      // SQL cannot contact Stripe. Ask the authenticated server to recover the
      // caller's earlier lease, never to prepare or collect another payment.
      final FunctionResponse recovery;
      try {
        recovery = await _client.functions
            .invoke('stripe-payment', body: {'action': 'recover'})
            .timeout(const Duration(seconds: 30));
      } catch (_) {
        throw error; // An unavailable provider never establishes non-payment.
      }
      final result = recovery.data;
      if (result is Map && result['recovered'] == true) {
        response = await quote(); // Exactly one retry, with every guard intact.
      } else {
        final reference = result is Map ? result['review_reference'] : null;
        if (reference is String &&
            RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(reference)) {
          throw StateError(
            'Your earlier checkout needs payment review. No new payment was started. Support reference: $reference.',
          );
        }
        rethrow;
      }
    }
    final row = switch (response) {
      final Map value => Map<String, dynamic>.from(value),
      final List value when value.isNotEmpty => Map<String, dynamic>.from(
        value.first as Map,
      ),
      _ => throw StateError('Booking total is unavailable.'),
    };
    return OpenQueueBookingCostPreview.fromJson(row);
  }

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return const [];

    final response = await _client
        .from('open_queue_bookings')
        .select(_bookingSelect)
        .eq('profile_id', userId)
        .eq('status', 'CONFIRMED')
        .order('booked_at', ascending: false);
    final rows = response as List<dynamic>;
    final bookings = [
      for (final row in rows)
        OpenQueueBooking.fromJson(Map<String, dynamic>.from(row as Map)),
    ];

    return hydrateUpcomingOpenQueueBookings(
      bookings: bookings,
      games: await listGames(),
    );
  }

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async {
    final bookings = await getMyUpcomingBookings();
    return bookings.isEmpty ? null : bookings.first;
  }

  @override
  Future<OpenQueueBooking?> getMyUpcomingBookingForGame(String gameId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null || gameId.trim().isEmpty) return null;

    final response = await _client
        .from('open_queue_bookings')
        .select(_bookingSelect)
        .eq('profile_id', userId)
        .eq('game_id', gameId)
        .eq('status', 'CONFIRMED')
        .maybeSingle();
    if (response == null) return null;

    final booking = OpenQueueBooking.fromJson(
      Map<String, dynamic>.from(response),
    );
    if (!booking.game.isUpcomingReservation) return null;
    return _hydrateBookingGame(booking);
  }

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) => _bookGame(game: game, role: role);

  @override
  Future<OpenQueueBooking> bookGameWithCollector({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required PaymentCollector collectPayment,
  }) => _bookGame(game: game, role: role, collectPayment: collectPayment);

  @override
  Future<PaymentRefundState> checkRefundStatus(String intentId) =>
      PaymentService(client: _client).checkRefundStatus(intentId);

  Future<OpenQueueBooking> _bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    PaymentCollector? collectPayment,
  }) async {
    final payment =
        await PaymentService(
          client: _client,
          paymentCollector: collectPayment,
        ).pay(
          purpose: PaymentPurpose.soloBooking,
          payload: {'game_id': game.id, 'role': role.code},
        );
    if (payment.resourceType != 'OPEN_QUEUE_BOOKING') {
      throw const PaymentPendingException();
    }
    final response = await _client
        .from('open_queue_bookings')
        .select(_bookingSelect)
        .eq('id', payment.resourceId)
        .single();
    final booking = OpenQueueBooking.fromJson(
      Map<String, dynamic>.from(response),
    );
    if (booking.gameId != game.id || booking.status != 'CONFIRMED') {
      throw const PaymentPendingException();
    }
    return _hydrateBookingGame(booking);
  }

  @override
  Future<OpenQueueCancellationPreview> previewCancellation(
    String bookingId,
  ) async {
    final response = await _client.rpc(
      'preview_open_queue_cancellation',
      params: {'booking_id_to_preview': bookingId},
    );
    final row = switch (response) {
      final Map value => Map<String, dynamic>.from(value),
      final List value when value.isNotEmpty => Map<String, dynamic>.from(
        value.first as Map,
      ),
      _ => throw StateError('Cancellation preview is unavailable.'),
    };
    final booking = await _client
        .from('open_queue_bookings')
        .select(
          'game:open_queue_games!open_queue_bookings_game_id_fkey(currency)',
        )
        .eq('id', bookingId)
        .single();
    final game = booking['game'];
    final currency = game is Map ? game['currency'] : null;
    return OpenQueueCancellationPreview.fromJson({
      ...row,
      'currency': _requiredCurrency(currency),
    });
  }

  @override
  Future<OpenQueueBooking> cancelBooking(String bookingId) async {
    final cancellation = await _client.rpc(
      'cancel_open_queue_booking',
      params: {'booking_id_to_cancel': bookingId},
    );
    final response = await _client
        .from('open_queue_bookings')
        .select(_bookingSelect)
        .eq('id', bookingId)
        .single();
    return _hydrateBookingGame(
      OpenQueueBooking.fromJson({
        ...Map<String, dynamic>.from(response),
        if (cancellation is Map) ...{
          'refund_destination': cancellation['refund_destination'],
          'refund_status': cancellation['refund_status'],
        },
      }),
    );
  }

  Future<OpenQueueBooking> _hydrateBookingGame(OpenQueueBooking booking) async {
    final games = await listGames();
    for (final game in games) {
      if (game.id == booking.gameId) return booking.copyWith(game: game);
    }
    return booking;
  }
}

List<OpenQueueBooking> hydrateUpcomingOpenQueueBookings({
  required Iterable<OpenQueueBooking> bookings,
  required Iterable<OpenQueueGame> games,
  DateTime? now,
}) {
  final cutoff = now ?? DateTime.now();
  final activeGames = <String, OpenQueueGame>{
    for (final game in games)
      if (game.isUpcomingReservationAt(cutoff)) game.id: game,
  };
  final seenBookingIds = <String>{};
  final hydrated = <OpenQueueBooking>[];
  for (final booking in bookings) {
    if (booking.status.toUpperCase() != 'CONFIRMED' ||
        !seenBookingIds.add(booking.id)) {
      continue;
    }
    final game = activeGames[booking.gameId];
    if (game == null) continue;
    hydrated.add(booking.copyWith(game: game));
  }
  hydrated.sort((left, right) {
    final kickoff = left.game.startsAt.compareTo(right.game.startsAt);
    return kickoff != 0 ? kickoff : left.id.compareTo(right.id);
  });
  return hydrated;
}
