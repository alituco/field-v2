import 'dart:convert';

import 'package:field/src/referrals/referrals.dart';
import 'package:field/src/referrals/referral_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// Supabase's injectable JSON worker keeps network tests deterministic.
// ignore: depend_on_referenced_packages
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

void main() {
  test(
    'username punctuation is preserved and confirmation pins checked person',
    () async {
      final calls = <String>[];
      final client = _client((request) async {
        calls.add(request.url.path.split('/').last);
        final body = jsonDecode(request.body) as Map;
        if (calls.last == 'check_fieldrush_referral_code') {
          expect(body, {'code_to_use': 'MARCUS.K'});
          return _json(_person);
        }
        expect(calls.last, 'claim_fieldrush_referral_code');
        expect(body, {
          'code_to_use': 'MARCUS.K',
          'expected_referrer_id': 'friend',
        });
        return _json(_summary(referrer: _person));
      });
      addTearDown(client.dispose);
      final repo = SupabaseReferralRepository(client: client);
      final checked = await repo.checkCode('  MARCUS.K ');
      final linked = await repo.claimCode(
        ' MARCUS.K ',
        expectedReferrerId: checked.id,
      );
      expect(linked.referrer?.id, 'friend');
      expect(calls, [
        'check_fieldrush_referral_code',
        'claim_fieldrush_referral_code',
      ]);
    },
  );

  test(
    'lost claim response reconciles success without a second mutation',
    () async {
      final calls = <String>[];
      final client = _client((request) async {
        calls.add(request.url.path.split('/').last);
        if (calls.last == 'claim_fieldrush_referral_code') {
          throw http.ClientException('response disconnected after commit');
        }
        return _json(_summary(referrer: _person));
      });
      addTearDown(client.dispose);
      final linked = await SupabaseReferralRepository(
        client: client,
      ).claimCode('MARCUS.K', expectedReferrerId: 'friend');
      expect(linked.referrer?.id, 'friend');
      expect(calls, [
        'claim_fieldrush_referral_code',
        'get_fieldrush_referrals',
      ]);
    },
  );

  test(
    'an unrelated linked person never falsely confirms the requested code',
    () async {
      final client = _client((request) async {
        if (request.url.path.endsWith('claim_fieldrush_referral_code')) {
          return _json({
            'message': 'Your referral is already linked.',
            'code': '22023',
          }, status: 400);
        }
        return _json(_summary(referrer: {..._person, 'id': 'someone-else'}));
      });
      addTearDown(client.dispose);
      await expectLater(
        SupabaseReferralRepository(
          client: client,
        ).claimCode('MARCUS.K', expectedReferrerId: 'friend'),
        throwsA(isA<PostgrestException>()),
      );
    },
  );

  test(
    'fresh launch grace uses authoritative expiry even for old accounts',
    () {
      final summary = ReferralSummary.fromJson(_summary());
      expect(summary.daysLeft, 7);
      expect(summary.canAddCode, isTrue);
      expect(summary.season.displayLabel, 'Season 0');
      final expired = ReferralSummary.fromJson({
        ..._summary(),
        'server_now': '2026-10-31T12:00:00Z',
        'can_add_code': false,
      });
      expect(expired.daysLeft, 0);
      expect(expired.canAddCode, isFalse);
      expect(expired.ownCode, 'ALI');
    },
  );

  test(
    'unresolved prize tie remains unawarded and paging offsets are retained',
    () async {
      final client = _client((request) async {
        expect(jsonDecode(request.body), {
          'offset_to_use': 50,
          'limit_to_use': 50,
        });
        return _json({
          'season': _season,
          'prize_entries': [
            {
              ..._person,
              'rank': 5,
              'referral_count': 3,
              'needs_review': true,
              'prize_eligible': false,
            },
          ],
          'entries': [],
          'me': {..._person, 'rank': null, 'referral_count': 1},
          'qualified_total': 1101,
          'next_offset': 100,
        });
      });
      addTearDown(client.dispose);
      final page = await SupabaseReferralRepository(
        client: client,
      ).loadLeaderboard(offset: 50);
      expect(page.nextOffset, 100);
      expect(page.qualifiedTotal, 1101);
      expect(page.prizeEntries.single.needsReview, isTrue);
      expect(page.prizeEntries.single.prizeEligible, isFalse);
      expect(page.me.rank, isNull);
    },
  );
}

const _person = {
  'id': 'friend',
  'name': 'Marcus K.',
  'username': 'marcus.k',
  'division': null,
  'rating_visible': false,
};
const _season = {'id': 's1', 'label': 'S0', 'ended': false};
Map<String, dynamic> _summary({Map<String, dynamic>? referrer}) => {
  'server_now': '2026-10-24T12:00:00Z',
  'entry_expires_at': '2026-10-31T12:00:00Z',
  'can_add_code': referrer == null,
  'own_code': 'ALI',
  'referrer': referrer,
  'season': _season,
  'referral_count': 0,
  'waiting_count': 0,
  'referrals': [],
};
http.Response _json(Object data, {int status = 200}) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);
SupabaseClient _client(Future<http.Response> Function(http.Request) handler) =>
    SupabaseClient(
      'https://referrals.test.invalid',
      'test-key',
      isolate: _ImmediateJsonWorker(),
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
    );

class _ImmediateJsonWorker extends YAJsonIsolate {
  @override
  Future<void> initialize() async {}
  @override
  Future<dynamic> decode(String data) async => jsonDecode(data);
  @override
  Future<String> encode(Object? data) async => jsonEncode(data);
  @override
  Future<void> dispose() async {}
}
