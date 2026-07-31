import 'package:supabase_flutter/supabase_flutter.dart';

import 'open_queue.dart';
import 'open_queue_party_repository.dart';
import '../payments/tap_payment_service.dart';
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
        OpenQueueBookingLookupRepository,
        OpenQueueReliabilityLookupRepository,
        OpenQueueBookingCostPreviewRepository {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  SupabaseClient get partyClient => _client;

  static const _bookingSelect = '''
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
      age_label,
      capacity,
      white_score,
      black_score,
      white_average_sr,
      black_average_sr,
      match_average_sr,
      team_sr_spread,
      teams_assigned_at
    )
  ''';

  @override
  Future<List<OpenQueueGame>> listGames() async {
    final response = await _client.rpc('list_open_queue_games');
    return [
      for (final row in response as List<dynamic>)
        OpenQueueGame.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async {
    final response = await _client.rpc('list_open_queue_fixture_games');
    return [
      for (final row in response as List<dynamic>)
        OpenQueueGame.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
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
    final response = await _client.rpc(
      'preview_open_queue_booking_cost',
      params: {'game_id_to_book': gameId, 'role_to_book': role.code},
    );
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
  }) async {
    final payment = await TapPaymentService(client: _client).pay(
      purpose: TapPaymentPurpose.soloBooking,
      payload: {'game_id': game.id, 'role': role.code},
    );
    final response = await _client
        .from('open_queue_bookings')
        .select(_bookingSelect)
        .eq('id', payment.resourceId)
        .single();
    return _hydrateBookingGame(
      OpenQueueBooking.fromJson(Map<String, dynamic>.from(response)),
    );
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
    return OpenQueueCancellationPreview.fromJson(row);
  }

  @override
  Future<OpenQueueBooking> cancelBooking(String bookingId) async {
    await _client.rpc(
      'cancel_open_queue_booking',
      params: {'booking_id_to_cancel': bookingId},
    );
    final response = await _client
        .from('open_queue_bookings')
        .select(_bookingSelect)
        .eq('id', bookingId)
        .single();
    return _hydrateBookingGame(
      OpenQueueBooking.fromJson(Map<String, dynamic>.from(response)),
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
