import 'dart:convert';

import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'recommendations use the authenticated RPC and hydrate clip and owner',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-anon-key-not-a-secret',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/list_fieldrush_profile_identities')) {
            expect(jsonDecode(request.body), {
              'profile_ids_to_use': ['creator'],
            });
            return _identityResponse(request);
          }
          expect(
            request.url.path,
            '/rest/v1/rpc/get_profile_clip_recommendations',
          );
          expect(jsonDecode(request.body), {
            'highlight_id_to_use': 'current-clip',
            'limit_to_use': 4,
          });
          return http.Response(
            jsonEncode([_recommendation]),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final ProfileRepository repository = SupabaseProfileRepository(
        client: client,
      );

      final result = await repository.getClipRecommendations(
        highlightId: ' current-clip ',
        limit: 4,
      );

      expect(result, hasLength(1));
      expect(result.single.profileId, 'creator');
      expect(result.single.username, 'player.one');
      expect(result.single.displayName, 'Player One');
      expect(result.single.avatarUrl, 'https://example.com/avatar.jpg');
      expect(result.single.highlight.profileId, 'creator');
      expect(result.single.highlight.id, 'next-clip');
      expect(result.single.highlight.views, 14);
      expect(result.single.highlight.createdAt, DateTime.utc(2026, 10, 19, 10));
      expect(result.single.highlight.copyWith(views: 15).profileId, 'creator');
      expect(requests, hasLength(2));
    },
  );

  test('invalid clip IDs and limits never make a network request', () async {
    final client = SupabaseClient(
      'https://fieldrush-tests.invalid',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(
        (_) async => throw StateError('Unexpected request'),
      ),
    );
    addTearDown(client.dispose);
    final repository = SupabaseProfileRepository(client: client);
    await expectLater(
      repository.getClipRecommendations(highlightId: ' '),
      throwsArgumentError,
    );
    await expectLater(
      repository.getClipRecommendations(highlightId: 'clip', limit: 0),
      throwsArgumentError,
    );
    await expectLater(
      repository.getClipRecommendations(highlightId: 'clip', limit: 21),
      throwsArgumentError,
    );
  });

  test(
    'missing or malformed RPC responses do not fabricate an unseen list',
    () async {
      Object? payload = {'invalid': true};
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode(payload),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        ),
      );
      addTearDown(client.dispose);
      final repository = SupabaseProfileRepository(client: client);
      await expectLater(
        repository.getClipRecommendations(highlightId: 'clip'),
        throwsStateError,
      );
      payload = ['invalid'];
      await expectLater(
        repository.getClipRecommendations(highlightId: 'clip'),
        throwsStateError,
      );
      payload = [
        {
          'highlight': {'id': 'clip'},
        },
      ];
      await expectLater(
        repository.getClipRecommendations(highlightId: 'clip'),
        throwsFormatException,
      );
      payload = [];
      expect(
        await repository.getClipRecommendations(highlightId: 'clip'),
        isEmpty,
      );
    },
  );

  test(
    'repositories without recommendation capability return an empty list',
    () async {
      final ProfileRepository repository = _LegacyRepository();
      expect(
        await repository.getClipRecommendations(highlightId: 'clip'),
        isEmpty,
      );
    },
  );
  test(
    'an overbroad response cannot show private, current or unplayable clips',
    () async {
      final originalHighlight = _recommendation['highlight']! as Map;
      Map<String, Object?> row(String id, Map<String, Object?> changes) => {
        ..._recommendation,
        'highlight': {...originalHighlight, 'id': id, ...changes},
      };
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient(
          (request) async =>
              request.url.path.endsWith('/list_fieldrush_profile_identities')
              ? _identityResponse(request)
              : http.Response(
                  jsonEncode([
                    row('private', {'is_public': false}),
                    row('current', {}),
                    row('unready', {'processing_status': 'PROCESSING'}),
                    row('missing-media', {'video_url': ''}),
                    row('visible', {}),
                    {...row('blocked-owner', {}), 'profile_id': 'blocked'},
                  ]),
                  200,
                  headers: {'content-type': 'application/json'},
                  request: request,
                ),
        ),
      );
      addTearDown(client.dispose);
      final repository = SupabaseProfileRepository(client: client);
      expect(
        (await repository.getClipRecommendations(
          highlightId: 'current',
        )).map((item) => item.highlight.id),
        ['visible'],
      );
    },
  );
}

class _LegacyRepository implements ProfileRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _recommendation = {
  'profile_id': 'creator',
  'username': 'player.one',
  'display_name': 'Player One',
  'avatar_url': 'https://example.com/avatar.jpg',
  'highlight': {
    'id': 'next-clip',
    'title': 'A clean finish',
    'thumbnail_url': 'https://example.com/thumbnail.jpg',
    'video_url': 'https://example.com/video.m3u8',
    'duration': '0:30',
    'views': 14,
    'created_at': '2026-10-19T10:00:00Z',
  },
};

http.Response _identityResponse(http.Request request) => http.Response(
  jsonEncode([
    {
      'id': 'creator',
      'username': 'player.one',
      'display_name': 'Player One',
      'avatar_url': 'https://example.com/avatar.jpg',
      'content_hidden': false,
    },
  ]),
  200,
  headers: {'content-type': 'application/json'},
  request: request,
);
