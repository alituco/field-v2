import 'dart:async';
import 'dart:convert';

import 'package:field/src/profile/fieldrush_match_history_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Phoenix evening history keeps the actual game month and day', () {
    final game = _game('phoenix', timezone: 'America/Phoenix');
    expect(game.playedAt.toUtc(), DateTime.utc(2026, 11, 1, 2));
    expect(game.localPlayedAt, DateTime.utc(2026, 10, 31, 19));
  });

  test('legacy clan and Bahrain solo history preserve Bahrain dates', () {
    final clan = _game('clan', type: 'CLAN');
    final solo = _game('legacy-solo', timezone: 'Asia/Bahrain');
    expect(clan.localPlayedAt, DateTime.utc(2026, 11, 1, 5));
    expect(solo.localPlayedAt, clan.localPlayedAt);

    final calendarOnly = ProfilePreviousGame.fromJson({
      'match_id': 'calendar-clan',
      'match_type': 'CLAN',
      'match_date': '2026-10-31',
    });
    expect(calendarOnly.localPlayedAt, DateTime.utc(2026, 10, 31));
  });

  test('unknown solo timezone never guesses the device or account market', () {
    expect(_game('unknown').localPlayedAt, isNull);
    expect(
      _game('unsupported', timezone: 'Unknown/Zone').localPlayedAt,
      isNull,
    );
  });

  testWidgets('history groups and labels mixed games in their own timezones', (
    tester,
  ) async {
    final phoenix = _game('phoenix', timezone: 'America/Phoenix');
    final bahrain = _game('bahrain', timezone: 'Asia/Bahrain');
    final unknown = _game('unknown');
    await tester.pumpWidget(
      MaterialApp(
        home: FieldrushMatchHistoryScreen(
          profile: _profile([phoenix, bahrain, unknown]),
          onOpenGame: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('OCTOBER 2026'), findsOneWidget);
    expect(find.text('NOVEMBER 2026'), findsOneWidget);
    expect(find.text('Oct 31 · 2–1'), findsOneWidget);
    expect(find.text('Nov 1 · 2–1'), findsOneWidget);
    expect(find.text('DATE UNAVAILABLE'), findsOneWidget);
    expect(find.text('Date unavailable · 2–1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['batch', 'outage', 'timeout']) {
    final fails = mode == 'outage';
    test('optional timezone metadata $mode preserves core profile', () async {
      final metadataRequests = <http.Request>[];
      final heldMetadata = Completer<http.Response>();
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-anon-key-not-a-secret',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final path = request.url.path;
          Object? payload;
          var status = 200;
          if (path.endsWith('/profiles')) {
            payload = {
              'id': 'player',
              'display_name': 'Dana',
              'username': 'dana',
              'bio': '',
            };
          } else if (path.endsWith('/list_profile_previous_games')) {
            payload = [
              _jsonGame('phoenix'),
              _jsonGame('phoenix'),
              _jsonGame('clan', type: 'CLAN'),
            ];
          } else if (path.endsWith('/open_queue_games')) {
            metadataRequests.add(request);
            if (mode == 'timeout') return heldMetadata.future;
            status = fails ? 403 : 200;
            payload = fails
                ? {'message': 'Optional metadata unavailable'}
                : [
                    {'id': 'phoenix', 'timezone': 'America/Phoenix'},
                  ];
          } else if (path.endsWith('/clan_members') ||
              path.endsWith('/get_player_rating_history')) {
            payload = null;
          } else {
            payload = [];
          }
          return http.Response(
            jsonEncode(payload),
            status,
            headers: {
              'content-type': 'application/json',
              if (request.headers['prefer']?.contains('count=exact') == true)
                'content-range': '*/0',
            },
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final profile = await SupabaseProfileRepository(
        client: client,
      ).getProfile('player');
      if (mode == 'timeout') {
        heldMetadata.complete(
          http.Response('[]', 200, request: metadataRequests.single),
        );
      }
      expect(profile.displayName, 'Dana');
      expect(profile.previousGames, hasLength(3));
      expect(metadataRequests, hasLength(1));
      expect(
        metadataRequests.single.url.queryParameters['select'],
        'id,timezone,open_queue_events(occurred_at)',
      );
      expect(
        metadataRequests.single.url.queryParameters['id'],
        'in.("phoenix")',
      );
      expect(
        profile.previousGames.first.localPlayedAt,
        mode != 'batch' ? isNull : DateTime.utc(2026, 10, 31, 19),
      );
      expect(
        profile.previousGames.last.localPlayedAt,
        DateTime.utc(2026, 11, 1, 5),
      );
    });
  }
}

Map<String, dynamic> _jsonGame(
  String id, {
  String type = 'SOLO',
  String? timezone,
}) => {
  'match_id': id,
  'match_type': type,
  'played_at': '2026-11-01T02:00:00Z',
  'timezone': timezone,
  'home_score': 2,
  'away_score': 1,
  'player_side': type == 'CLAN' ? 'HOME' : 'WHITE',
};

ProfilePreviousGame _game(
  String id, {
  String type = 'SOLO',
  String? timezone,
}) =>
    ProfilePreviousGame.fromJson(_jsonGame(id, type: type, timezone: timezone));

PlayerProfile _profile(List<ProfilePreviousGame> games) => PlayerProfile(
  id: 'player',
  displayName: 'Dana',
  username: 'dana',
  bio: '',
  followingCount: 0,
  fansCount: 0,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: const [],
  career: const [],
  previousGames: games,
);
