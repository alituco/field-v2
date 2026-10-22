import 'dart:convert';

import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'Home summary loads only the signed-in identity row, not profile history',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-anon-key-not-a-secret',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          expect(request.url.path, '/rest/v1/profiles');
          expect(request.url.queryParameters['id'], 'eq.viewer');
          expect(
            request.url.queryParameters['select'],
            'id,display_name,username,bio,avatar_url',
          );
          return http.Response(
            jsonEncode({
              'id': 'viewer',
              'display_name': 'Viewer Name',
              'username': 'viewer',
              'bio': 'A profile',
              'avatar_url': 'https://example.com/avatar.jpg',
            }),
            200,
            headers: {'content-type': 'application/json'},
          request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(_session()));
      final repository = SupabaseProfileRepository(client: client);
      final summary = await repository.getCurrentProfileSummary();
      expect(summary.id, 'viewer');
      expect(summary.displayName, 'Viewer Name');
      expect(summary.username, 'viewer');
      expect(summary.avatarUrl, 'https://example.com/avatar.jpg');
      expect(summary.playerRating, isNull);
      expect(summary.highlights, isEmpty);
      expect(summary.career, isEmpty);
      expect(requests, hasLength(1));
    },
  );

  test(
    'signed-out Home summary fails without making a profile request',
    () async {
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-anon-key-not-a-secret',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient(
          (_) async => throw StateError('Unexpected request'),
        ),
      );
      addTearDown(client.dispose);
      await expectLater(
        SupabaseProfileRepository(client: client).getCurrentProfileSummary(),
        throwsA(isA<AuthException>()),
      );
    },
  );
}

Map<String, dynamic> _session() {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  String encoded(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': 'viewer', 'exp': expires})}.local-test-signature',
    'refresh_token': 'local-test-refresh-token',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': 'viewer',
      'aud': 'authenticated',
      'role': 'authenticated',
      'created_at': '2026-10-01T00:00:00Z',
      'app_metadata': {},
      'user_metadata': {},
    },
  };
}
