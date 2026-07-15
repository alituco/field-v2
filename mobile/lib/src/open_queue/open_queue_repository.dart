import 'package:supabase_flutter/supabase_flutter.dart';

import 'open_queue.dart';

abstract class OpenQueueRepository {
  Future<List<OpenQueueGame>> listGames();

  Future<List<OpenQueueGame>> listFixtureGames();

  Future<OpenQueueMatchDetail> getMatchDetail(String gameId);

  Future<OpenQueueBooking?> getMyUpcomingBooking();

  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  });

  Future<OpenQueueCancellationPreview> previewCancellation(String bookingId);

  Future<OpenQueueBooking> cancelBooking(String bookingId);
}

class SupabaseOpenQueueRepository implements OpenQueueRepository {
  SupabaseClient get _client => Supabase.instance.client;

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
      venue,
      starts_at,
      ends_at,
      timezone,
      price_fils,
      age_label,
      capacity,
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
  Future<OpenQueueBooking?> getMyUpcomingBooking() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

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
    ]..removeWhere((booking) => !booking.game.startsAt.isAfter(DateTime.now()));
    bookings.sort((a, b) => a.game.startsAt.compareTo(b.game.startsAt));
    return bookings.isEmpty ? null : _hydrateBookingGame(bookings.first);
  }

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async {
    final bookingId = await _client.rpc(
      'book_open_queue_game',
      params: {
        'game_id_to_book': game.id,
        'role_to_book': role.code,
        'payment_method_to_use': paymentMethod,
        'payment_reference_to_use':
            'mock-${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    final response = await _client
        .from('open_queue_bookings')
        .select(_bookingSelect)
        .eq('id', bookingId as String)
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
    final rows = response as List<dynamic>;
    if (rows.isEmpty) throw StateError('Cancellation preview is unavailable.');
    return OpenQueueCancellationPreview.fromJson(
      Map<String, dynamic>.from(rows.first as Map),
    );
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
    return OpenQueueBooking.fromJson(Map<String, dynamic>.from(response));
  }

  Future<OpenQueueBooking> _hydrateBookingGame(OpenQueueBooking booking) async {
    final games = await listGames();
    for (final game in games) {
      if (game.id == booking.gameId) return booking.copyWith(game: game);
    }
    return booking;
  }
}
