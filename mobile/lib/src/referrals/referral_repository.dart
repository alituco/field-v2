import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/read_timeout.dart';
import 'referrals.dart';

abstract class ReferralRepository {
  String? get currentUserId;
  Future<ReferralSummary> load();
  Future<ReferralPerson> checkCode(String code);
  Future<ReferralSummary> claimCode(
    String code, {
    required String expectedReferrerId,
  });
  Future<ReferralLeaderboard> loadLeaderboard({int offset = 0, int limit = 50});
  Future<ReferralFriendsPage> loadReferredPlayers({
    int offset = 0,
    int limit = 50,
  });
}

class SupabaseReferralRepository implements ReferralRepository {
  SupabaseReferralRepository({SupabaseClient? client})
    : _injectedClient = client;
  final SupabaseClient? _injectedClient;
  SupabaseClient get _client => _injectedClient ?? Supabase.instance.client;
  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  Future<Map<String, dynamic>> _read(
    String name, [
    Map<String, dynamic>? params,
  ]) async {
    final response = await _client
        .rpc(name, params: params)
        .timeout(fieldReadTimeout);
    return Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<ReferralSummary> load() async =>
      ReferralSummary.fromJson(await _read('get_fieldrush_referrals'));

  @override
  Future<ReferralPerson> checkCode(String code) async =>
      ReferralPerson.fromJson(
        await _read('check_fieldrush_referral_code', {
          'code_to_use': code.trim(),
        }),
      );

  @override
  Future<ReferralSummary> claimCode(
    String code, {
    required String expectedReferrerId,
  }) async {
    // Retrying the same confirmed person is idempotent on the server. A
    // different person can never replace an existing link, including races.
    try {
      final response = await _client
          .rpc(
            'claim_fieldrush_referral_code',
            params: {
              'code_to_use': code.trim(),
              'expected_referrer_id': expectedReferrerId,
            },
          )
          .timeout(const Duration(seconds: 20));
      return ReferralSummary.fromJson(
        Map<String, dynamic>.from(response as Map),
      );
    } catch (error) {
      // The server may have committed before the response was lost. Reconcile
      // this specific confirmed person; never call a failed write successful
      // merely because some other referral is now linked.
      try {
        final summary = await load();
        if (summary.referrer?.id == expectedReferrerId) return summary;
      } catch (_) {
        // Preserve the original result when the readback is also unavailable.
      }
      rethrow;
    }
  }

  @override
  Future<ReferralLeaderboard> loadLeaderboard({
    int offset = 0,
    int limit = 50,
  }) async => ReferralLeaderboard.fromJson(
    await _read('get_fieldrush_referral_leaderboard', {
      'offset_to_use': offset,
      'limit_to_use': limit,
    }),
  );

  @override
  Future<ReferralFriendsPage> loadReferredPlayers({
    int offset = 0,
    int limit = 50,
  }) async => ReferralFriendsPage.fromJson(
    await _read('get_fieldrush_referred_players', {
      'offset_to_use': offset,
      'limit_to_use': limit,
    }),
  );
}
