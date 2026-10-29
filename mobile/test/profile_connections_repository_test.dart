import 'dart:convert';

import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'connection pages hydrate exact IDs and counts exclude RLS-hidden profiles',
    () async {
      final requests = <http.Request>[];
      final following = [
        for (var index = 0; index < 1001; index++) 'follow-$index',
        'hidden-following',
      ];
      final fans = ['follow-1000', 'fan-visible', 'hidden-fan'];
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-anon-key-not-a-secret',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          final query = request.url.queryParameters;
          final select = query['select'] ?? '';
          Object? payload;
          final headers = {'content-type': 'application/json'};
          if (path.endsWith('/profile_follows')) {
            final isFollowing = query['follower_id'] == 'eq.viewer';
            final idColumn = isFollowing ? 'following_id' : 'follower_id';
            if (request.headers['prefer']?.contains('count=exact') == true) {
              expect(
                select,
                '$idColumn,profile:profiles!profile_follows_${idColumn}_fkey!inner(id)',
              );
              expect(query['limit'], '1');
              // The inner join excludes hidden profiles. A one-row payload
              // must not replace the exact, server-computed readable count.
              payload = [
                {
                  idColumn: 'follow-1000',
                  'profile': {'id': 'follow-1000'},
                },
              ];
              headers['content-range'] = isFollowing ? '0-0/1001' : '0-0/2';
            } else {
              expect(select, idColumn);
              expect(
                query['order'],
                'created_at.desc.nullslast,$idColumn.asc.nullslast',
              );
              expect(query['limit'], '500');
              final ids = isFollowing ? following : fans;
              final offset = int.parse(query['offset']!);
              final end = (offset + 500).clamp(0, ids.length);
              payload = [
                for (final id in ids.sublist(offset, end)) {idColumn: id},
              ];
            }
          } else if (path.endsWith('/profiles')) {
            expect(query['id'], 'eq.viewer');
            payload = {'id': 'viewer', 'display_name': 'Viewer'};
          } else if (path.endsWith('/list_fieldrush_profile_identities')) {
            final ids = (jsonDecode(request.body)['profile_ids_to_use'] as List)
                .cast<String>();
            expect(ids.length, lessThanOrEqualTo(100));
            payload = [
              for (final id in ids)
                if (!id.startsWith('hidden-'))
                  {..._profile(id), 'content_hidden': false},
            ];
          } else if (path.endsWith('/list_fieldrush_discover_profiles')) {
            expect(jsonDecode(request.body), isEmpty);
            payload = [_profile('discover-player'), _profile('follow-0')];
          } else if (path.endsWith('/list_fieldrush_connection_clans')) {
            final ids = (jsonDecode(request.body)['profile_ids_to_use'] as List)
                .cast<String>();
            expect(ids.length, lessThanOrEqualTo(100));
            expect(ids.any((id) => id.startsWith('hidden-')), isFalse);
            payload = [];
          } else if (path.endsWith('/get_fieldrush_profile_clan')) {
            payload = null;
          } else if (path.endsWith('/get_player_rating_history')) {
            payload = null;
          } else if (path.endsWith('/list_profile_previous_games') ||
              path.endsWith('/list_profile_career_entries') ||
              path.endsWith('/profile_highlights')) {
            payload = [];
          } else {
            throw StateError('Unexpected connection request: $path');
          }
          return http.Response(
            jsonEncode(payload),
            200,
            headers: headers,
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(_session('viewer')));
      final repository = SupabaseProfileRepository(client: client);

      final connections = await repository.getConnections();
      expect(connections.following, hasLength(1001));
      expect(connections.following.last.id, 'follow-1000');
      expect(
        connections.following.every((person) => person.isFollowedByMe),
        isTrue,
      );
      expect(connections.fans.map((person) => person.id), [
        'follow-1000',
        'fan-visible',
      ]);
      expect(connections.fans.first.isFollowedByMe, isTrue);
      expect(connections.fans.last.isFollowedByMe, isFalse);
      expect(connections.discover.map((person) => person.id), [
        'discover-player',
      ]);
      expect(
        [
          ...connections.following,
          ...connections.fans,
          ...connections.discover,
        ].any((person) => person.id.startsWith('hidden-')),
        isFalse,
      );
      final relationshipReads = requests.where(
        (request) => request.url.path.endsWith('/profile_follows'),
      );
      expect(
        relationshipReads
            .where(
              (request) =>
                  request.url.queryParameters['follower_id'] == 'eq.viewer',
            )
            .map((request) => request.url.queryParameters['offset']),
        ['0', '500', '1000'],
      );

      final ownProfile = await repository.getProfile('viewer');
      expect(ownProfile.followingCount, connections.following.length);
      expect(ownProfile.fansCount, connections.fans.length);
      expect(ownProfile.isFollowedByMe, isFalse);
      expect(
        requests.where(
          (request) =>
              request.headers['prefer']?.contains('count=exact') == true,
        ),
        hasLength(2),
      );
    },
  );
}

Map<String, dynamic> _profile(String id) => {
  'id': id,
  'display_name': id,
  'username': id.replaceAll('-', '.'),
};

Map<String, dynamic> _session(String id) {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  String encoded(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': id, 'exp': expires})}.local-test-signature',
    'refresh_token': 'local-test-refresh-token',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': id,
      'aud': 'authenticated',
      'role': 'authenticated',
      'created_at': '2026-10-01T00:00:00Z',
      'app_metadata': {},
      'user_metadata': {},
    },
  };
}
