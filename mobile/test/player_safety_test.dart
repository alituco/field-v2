import 'dart:async';
import 'dart:convert';

import 'package:field/src/profile/blocked_players_screen.dart';
import 'package:field/src/profile/fieldrush_you_widgets.dart';
import 'package:field/src/profile/player_safety_repository.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:field/src/profile/profile_clip_screen.dart';
import 'package:field/src/profile/profile_clips_screen.dart';
import 'package:field/src/profile/profile_connections_screen.dart';
import 'package:field/src/home/home_discovery_repository.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
import 'package:field/src/profile/viewer_safe_identities.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'safety RPCs infer their owner and confirm idempotent block/unblock',
    () async {
      var blocked = false;
      final requests = <http.Request>[];
      final client = _client((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/list_fieldrush_blocked_players')) {
          expect(jsonDecode(request.body), isNull);
          return _response(
            request,
            blocked
                ? [
                    {
                      'profile_id': 'other',
                      'username': 'other',
                      'display_name': 'Other',
                      'blocked_at': '2026-10-29T12:00:00Z',
                    },
                  ]
                : [],
          );
        }
        final body = jsonDecode(request.body) as Map;
        if (request.url.path.endsWith('/set_fieldrush_player_block')) {
          expect(body.keys.toSet(), {'profile_id_to_use', 'blocked_to_use'});
          blocked = body['blocked_to_use'] as bool;
        } else {
          expect(request.url.path, '/rest/v1/rpc/get_fieldrush_player_safety');
          expect(body, {'profile_id_to_use': 'other'});
        }
        expect(body['profile_id_to_use'], 'other');
        return _response(request, _stateJson(blocked));
      });
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(_session()));
      final repository = SupabasePlayerSafetyRepository(client: client);
      expect(
        (await repository.getState(' other ')).interactionBlocked,
        isFalse,
      );
      expect(
        (await repository.setBlocked('other', blocked: true)).blockedByMe,
        isTrue,
      );
      expect(
        (await repository.setBlocked('other', blocked: true)).blockedByMe,
        isTrue,
      );
      expect((await repository.listBlockedPlayers()).single.profileId, 'other');
      expect(
        (await repository.setBlocked(
          'other',
          blocked: false,
        )).interactionBlocked,
        isFalse,
      );
      expect(await repository.listBlockedPlayers(), isEmpty);
      expect(requests, hasLength(6));
      await expectLater(
        repository.setBlocked('viewer', blocked: true),
        throwsArgumentError,
      );
      await expectLater(
        repository.setBlocked(' ', blocked: true),
        throwsArgumentError,
      );
      expect(requests, hasLength(6));
    },
  );

  test(
    'anonymous mutation/list and unconfirmed responses fail closed',
    () async {
      var requests = 0;
      var wrongTarget = false;
      final client = _client((request) async {
        requests++;
        return _response(
          request,
          wrongTarget
              ? {..._stateJson(true), 'profile_id': 'someone-else'}
              : _stateJson(false),
        );
      });
      addTearDown(client.dispose);
      final repository = SupabasePlayerSafetyRepository(client: client);
      await expectLater(
        repository.setBlocked('other', blocked: true),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        repository.listBlockedPlayers(),
        throwsA(isA<AuthException>()),
      );
      expect(requests, 0);
      await client.auth.recoverSession(jsonEncode(_session()));
      await expectLater(
        repository.setBlocked('other', blocked: true),
        throwsFormatException,
      );
      wrongTarget = true;
      await expectLater(repository.getState('other'), throwsFormatException);
      expect(requests, 2);
    },
  );

  test(
    'safe identity hydration hides authored content but preserves every official row',
    () async {
      final client = _client((request) async {
        final body = jsonDecode(request.body) as Map;
        if (request.url.path.endsWith('/list_fieldrush_profile_identities')) {
          expect(
            body['profile_ids_to_use'],
            unorderedEquals(['hidden', 'visible']),
          );
          return _response(request, [
            {
              'id': 'visible',
              'display_name': 'Safe name',
              'username': 'safe',
              'avatar_url': 'https://example.com/safe.jpg',
              'content_hidden': false,
            },
          ]);
        }
        expect(request.url.path, '/rest/v1/rpc/list_fieldrush_clan_identities');
        expect(body['clan_ids_to_use'], ['clan']);
        return _response(request, [
          {
            'id': 'clan',
            'name': 'Hidden clan',
            'tag': 'HIDE',
            'emblem': '⚽',
            'theme_id': 'pitch',
            'pattern_id': 'solid',
            'content_hidden': true,
          },
        ]);
      });
      addTearDown(client.dispose);
      final original = <String, dynamic>{
        'confirmed_count': 2,
        'home_score': 4,
        'away_score': 2,
        'players': [
          {
            'id': 'hidden',
            'display_name': 'Old authored name',
            'avatar_url': 'https://example.com/hidden.jpg',
            'bio': 'Hidden bio',
            'rating_change': 19,
            'played': true,
          },
          {
            'id': 'visible',
            'display_name': 'Stale name',
            'avatar_url': 'https://example.com/stale.jpg',
            'rating_change': -7,
            'played': true,
          },
        ],
        'fixture_player_appearances': [
          {
            'profile_id': 'hidden',
            'played': true,
            'player': {
              'id': 'hidden',
              'display_name': 'Old authored name',
              'avatar_url': 'https://example.com/hidden.jpg',
            },
          },
        ],
        'home_clan': {
          'id': 'clan',
          'name': 'Authored clan',
          'tag': 'OLD',
          'emblem': '🦁',
          'skill_rating': 1300,
        },
      };
      final safe = await viewerSafeIdentityPayload(client, original);
      final players = safe['players'] as List;
      expect(players, hasLength(2));
      expect(players[0]['id'], 'hidden');
      expect(players[0]['avatar_url'], isNull);
      expect(players[0]['bio'], '');
      expect(players[0]['display_name'], 'Blocked player');
      expect(players[0]['rating_change'], 19);
      expect(players[0]['played'], isTrue);
      expect(players[1]['avatar_url'], 'https://example.com/safe.jpg');
      expect(
        safe['fixture_player_appearances'][0]['player']['avatar_url'],
        isNull,
      );
      expect(safe['home_clan']['name'], 'Hidden clan');
      expect(safe['home_clan']['emblem'], '⚽');
      expect(safe['home_clan']['skill_rating'], 1300);
      expect(safe['confirmed_count'], 2);
      expect(safe['home_score'], 4);
      expect(safe['away_score'], 2);
      expect(
        original['players'][0]['avatar_url'],
        'https://example.com/hidden.jpg',
      );
    },
  );

  test(
    'failed safe identity reads never return a raw photo fallback',
    () async {
      final client = _client(
        (request) async =>
            _response(request, {'message': 'unavailable'}, status: 503),
      );
      addTearDown(client.dispose);
      await expectLater(
        viewerSafeIdentityPayload(client, {
          'players': [
            {'id': 'other', 'avatar_url': 'https://example.com/private.jpg'},
          ],
        }),
        throwsA(isA<PostgrestException>()),
      );
    },
  );

  test(
    'large roster identity batches remain bounded without dropping rows',
    () async {
      final sizes = <int>[];
      final client = _client((request) async {
        final ids = jsonDecode(request.body)['profile_ids_to_use'] as List;
        sizes.add(ids.length);
        return _response(request, []);
      });
      addTearDown(client.dispose);
      final safe = await viewerSafeIdentityRows(client, [
        for (var index = 0; index < 201; index++)
          {
            'id': 'player-$index',
            'avatar_url': 'https://example.com/old.jpg',
            'played': true,
          },
      ]);
      expect(sizes, [100, 100, 1]);
      expect(safe, hasLength(201));
      expect(
        safe.every((row) => row['avatar_url'] == null && row['played'] == true),
        isTrue,
      );
    },
  );

  testWidgets('You settings exposes the blocked-player management action', (
    tester,
  ) async {
    var opened = 0;
    final profile = await _Profiles().getProfile('viewer');
    void noop() {}
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              FieldrushYouContent(
                profile: profile,
                onEdit: noop,
                onFollowing: noop,
                onFans: noop,
                onRanks: noop,
                onMatchHistory: noop,
                onClip: (_) {},
                onReliability: noop,
                onNotifications: noop,
                onWallet: noop,
                onPaymentMethods: noop,
                onSignOut: noop,
                onBlockedPlayers: () => opened++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.text('Blocked players');

    await _tapVisible(tester, row);
    expect(opened, 1);
  });

  test(
    'Home search excludes blocked identities without changing valid rating fields',
    () async {
      final client = _client((request) async {
        if (request.url.path.endsWith('/search_fieldrush_players')) {
          expect(jsonDecode(request.body), {'query_to_use': 'player'});
          return _response(request, [
            {
              'id': 'hidden',
              'display_name': 'Hidden original',
              'username': 'hidden',
              'avatar_url': 'https://example.com/hidden.jpg',
            },
            {
              'id': 'visible',
              'display_name': 'Old visible',
              'username': 'visible',
              'skill_rating': 1250,
              'matches_played': 4,
              'is_self': false,
            },
          ]);
        }
        expect(
          request.url.path,
          '/rest/v1/rpc/list_fieldrush_profile_identities',
        );
        return _response(request, [
          {
            'id': 'visible',
            'display_name': 'Safe visible',
            'username': 'visible',
            'avatar_url': null,
            'content_hidden': false,
          },
        ]);
      });
      addTearDown(client.dispose);
      final result = await SupabaseHomeDiscoveryRepository(
        client: client,
      ).searchPlayers('@player');
      expect(result.map((player) => player.id), ['visible']);
      expect(result.single.name, 'Safe visible');
      expect(result.single.matchesPlayed, 4);
    },
  );

  test(
    'party reads hide blocked pending invitations and preserve accepted members',
    () async {
      final client = _client((request) async {
        if (request.url.path.endsWith('/get_open_queue_party_context')) {
          return _response(request, {
            'game_id': 'game',
            'can_use_parties': true,
            'my_party': {
              'id': 'party',
              'owner_profile_id': 'hidden',
              'is_owner': false,
              'accepted_count': 2,
              'members': [
                {
                  'id': 'member-a',
                  'profile_id': 'hidden',
                  'display_name': 'Old name',
                  'avatar_url': 'https://example.com/hidden.jpg',
                  'status': 'ACCEPTED',
                },
                {
                  'id': 'member-b',
                  'profile_id': 'other',
                  'display_name': 'Other',
                  'avatar_url': 'https://example.com/other.jpg',
                  'status': 'ACCEPTED',
                },
              ],
            },
            'received_invites': [
              {
                'membership_id': 'pending-hidden',
                'party_id': 'party-hidden',
                'owner': {
                  'profile_id': 'hidden',
                  'display_name': 'Hidden owner',
                },
              },
              {
                'membership_id': 'pending-allowed',
                'party_id': 'party-allowed',
                'owner': {
                  'profile_id': 'allowed',
                  'display_name': 'Allowed owner',
                },
              },
            ],
            'eligible_players': [
              {
                'profile_id': 'hidden',
                'display_name': 'Old name',
                'avatar_url': 'https://example.com/hidden.jpg',
              },
            ],
          });
        }
        if (request.url.path.endsWith(
          '/list_my_open_queue_party_invite_notifications',
        )) {
          return _response(request, [
            for (final inviter in ['hidden', 'allowed'])
              {
                'notification_id': 'receipt-$inviter',
                'game_id': 'game',
                'party_id': 'party',
                'membership_id': 'membership-$inviter',
                'created_at': '2026-10-29T12:00:00Z',
                'inviter': {
                  'profile_id': inviter,
                  'display_name': 'Old inviter name',
                  'avatar_url': 'https://example.com/old.jpg',
                },
                'game': {'venue': 'Real venue', 'status': 'OPEN'},
              },
          ]);
        }
        expect(
          request.url.path,
          '/rest/v1/rpc/list_fieldrush_profile_identities',
        );
        return _response(request, [
          {
            'id': 'allowed',
            'display_name': 'Allowed inviter',
            'username': 'allowed',
            'avatar_url': null,
            'content_hidden': false,
          },
        ]);
      });
      addTearDown(client.dispose);
      final repository = _PartyRepository(client);
      final context = await repository.getPartyContext('game');
      expect(context.myParty!.acceptedCount, 2);
      expect(context.myParty!.members, hasLength(2));
      expect(context.myParty!.members.map((member) => member.profileId), [
        'hidden',
        'other',
      ]);
      expect(
        context.myParty!.members.every((member) => member.avatarUrl == null),
        isTrue,
      );
      expect(context.eligiblePlayers, isEmpty);
      expect(context.receivedInvites.map((invite) => invite.membershipId), [
        'pending-allowed',
      ]);
      final receipt = (await repository.listPartyInviteNotifications()).single;
      expect(receipt.id, 'receipt-allowed');
      expect(receipt.gameId, 'game');
      expect(receipt.inviter.avatarUrl, isNull);
      expect(receipt.venue, 'Real venue');
    },
  );

  for (final missingOwner in [false, true]) {
    testWidgets(
      'direct clip entry gates thumbnails and playback on owner safety: missingOwner=$missingOwner',
      (tester) async {
        final profiles = _ClipProfiles();
        final safety = _Safety()..incomingBlock = true;
        final highlight = ProfileHighlight(
          id: 'clip',
          title: 'Confidential clip',
          thumbnailUrl: 'https://example.com/hidden.jpg',
          videoUrl: 'https://example.com/hidden.m3u8',
          duration: '0:30',
          views: 4,
          profileId: missingOwner ? null : 'other',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ProfileClipScreen(
              highlight: highlight,
              profileRepository: profiles,
              playerSafetyRepository: safety,
              canManage: false,
              ownerLabel: 'Hidden author',
              ownerAvatarUrl: 'https://example.com/hidden.jpg',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('profile-clip-safety')),
          findsOneWidget,
        );
        expect(find.text('Confidential clip'), findsNothing);
        expect(find.text('Hidden author'), findsNothing);
        expect(find.byType(Image), findsNothing);
        expect(profiles.refreshes, missingOwner ? 1 : 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'returning from another clip rechecks safety and discards old thumbnails',
    (tester) async {
      final key = GlobalKey<NavigatorState>();
      final profiles = _RecommendationProfiles();
      final safety = _Safety();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          home: ProfileClipScreen(
            highlight: _safeTestClip('first'),
            profileRepository: profiles,
            playerSafetyRepository: safety,
            canManage: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final next = find.byKey(const ValueKey('up-next-clip-next'));

      await _tapVisible(tester, next);
      await tester.pumpAndSettle();
      expect(find.text('Clip next'), findsWidgets);
      safety.incomingBlock = true;
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile-clip-safety')), findsOneWidget);
      expect(find.text('Clip first'), findsNothing);
      expect(find.byKey(const ValueKey('up-next-clip-next')), findsNothing);
    },
  );

  testWidgets(
    'gallery hides cached thumbnails if identity refresh fails after a clip',
    (tester) async {
      final key = GlobalKey<NavigatorState>();
      final profiles = _Profiles();
      final profile = (await profiles.getProfile(
        'other',
      )).copyWith(highlights: [_safeTestClip('first')]);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          home: ProfileClipsScreen(
            profile: profile,
            repository: profiles,
            canManage: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('profile-grid-clip-first')),
      );
      await tester.pumpAndSettle();
      profiles.failProfile = true;
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-grid-clip-first')),
        findsNothing,
      );
      expect(find.text('Other Player'), findsNothing);
      expect(find.text('Could not refresh clips. Try again.'), findsOneWidget);
    },
  );

  testWidgets(
    'connections cannot restore cached avatars after failed return refresh',
    (tester) async {
      final profiles = _ConnectionProfiles();
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileConnectionsScreen(
            profileRepository: profiles,
            initialTab: ProfileConnectionTab.following,
            onOpenProfile: (_) async {
              profiles.failConnections = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Other Player'));
      await tester.pumpAndSettle();
      expect(find.text('Other Player'), findsNothing);
      expect(find.byKey(const ValueKey('follow-other')), findsNothing);
      expect(find.text('Retry'), findsWidgets);
    },
  );

  testWidgets('safety loads before authored profile content', (tester) async {
    final safety = _Safety()..pendingRead = Completer<PlayerSafetyState>();
    final profiles = _Profiles();
    await _pumpProfile(tester, profiles, safety);
    expect(profiles.reads, 0);
    expect(find.text('Other Player'), findsNothing);
    safety.pendingRead!.complete(
      const PlayerSafetyState(
        profileId: 'other',
        blockedByMe: false,
        interactionBlocked: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(profiles.reads, 1);
    expect(find.text('Other Player'), findsWidgets);
  });

  testWidgets(
    'confirmed block hides authored profile and permits later unblock',
    (tester) async {
      final safety = _Safety();
      final profiles = _Profiles();
      await _pumpProfile(tester, profiles, safety);
      await tester.pumpAndSettle();
      final action = find.byKey(const ValueKey('player-block-action'));

      await _tapVisible(tester, action);
      await tester.pumpAndSettle();
      expect(find.text(playerBlockScope), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('player-block-confirm')),
      );
      await tester.pumpAndSettle();
      expect(safety.writes, [true]);
      expect(
        find.byKey(const ValueKey('blocked-profile-content')),
        findsOneWidget,
      );
      expect(find.text('Other Player'), findsNothing);
      expect(find.text('Share profile'), findsNothing);
      expect(find.text('Follow'), findsNothing);
      expect(find.text('Report player'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('player-block-action')),
      );
      await tester.pumpAndSettle();
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('player-block-confirm')),
      );
      await tester.pumpAndSettle();
      expect(safety.writes, [true, false]);
      expect(
        find.byKey(const ValueKey('blocked-profile-content')),
        findsNothing,
      );
      expect(find.text('Other Player'), findsWidgets);
    },
  );

  testWidgets('cancel and failed block do not claim success', (tester) async {
    final safety = _Safety()..failWrite = true;
    await _pumpProfile(tester, _Profiles(), safety);
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('player-block-action'));

    await _tapVisible(tester, action);
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(safety.writes, isEmpty);
    await _tapVisible(tester, action);
    await tester.pumpAndSettle();
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('player-block-confirm')),
    );
    await tester.pumpAndSettle();
    expect(safety.writes, [true]);
    expect(find.byKey(const ValueKey('blocked-profile-content')), findsNothing);
    expect(find.text('Other Player'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final uncertainWrite in [false, true]) {
    testWidgets(
      '${uncertainWrite ? 'uncertain committed' : 'confirmed'} block plus failed safety refresh never keeps authored content',
      (tester) async {
        final safety = _Safety()
          ..failAfterCommit = uncertainWrite
          ..failReadAfterWrite = true;
        await _pumpProfile(tester, _Profiles(), safety);
        await tester.pumpAndSettle();
        final action = find.byKey(const ValueKey('player-block-action'));

        await _tapVisible(tester, action);
        await tester.pumpAndSettle();
        await _tapVisible(
          tester,
          find.byKey(const ValueKey('player-block-confirm')),
        );
        await tester.pumpAndSettle();
        expect(safety.blocked, isTrue);
        expect(find.text('Other Player'), findsNothing);
        expect(find.byKey(const ValueKey('profile-error')), findsOneWidget);
        expect(tester.takeException(), isNull);
        safety.failRead = false;
        await _tapVisible(tester, find.text('Try again'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('blocked-profile-content')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an incoming block hides content without exposing an unblock action',
    (tester) async {
      final safety = _Safety()..incomingBlock = true;
      final profiles = _Profiles();
      await _pumpProfile(tester, profiles, safety);
      await tester.pumpAndSettle();
      expect(profiles.reads, 0);
      expect(
        find.byKey(const ValueKey('blocked-profile-content')),
        findsOneWidget,
      );
      expect(find.text('Unblock player'), findsNothing);
      expect(find.text('Report player'), findsOneWidget);
    },
  );

  testWidgets('self profile has no block action', (tester) async {
    final profiles = _Profiles()..userId = 'other';
    final safety = _Safety()..userId = 'other';
    await _pumpProfile(tester, profiles, safety);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-block-action')), findsNothing);
    expect(safety.reads, 0);
  });

  for (final fail in [false, true]) {
    testWidgets(
      'blocked list removes a row only after successful unblock: fail=$fail',
      (tester) async {
        final safety = _Safety()
          ..blocked = true
          ..failWrite = fail;
        await tester.pumpWidget(
          MaterialApp(home: BlockedPlayersScreen(repository: safety)),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('blocked-player-other')),
          findsOneWidget,
        );
        await _tapVisible(tester, find.byKey(const ValueKey('unblock-other')));
        await tester.pumpAndSettle();
        await _tapVisible(
          tester,
          find.byKey(const ValueKey('player-block-confirm')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('blocked-player-other')),
          fail ? findsOneWidget : findsNothing,
        );
        if (!fail) {
          expect(
            find.text('You have not blocked any players.'),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'safety read errors show retry instead of a cached public profile',
    (tester) async {
      final safety = _Safety()..failRead = true;
      final profiles = _Profiles();
      await _pumpProfile(tester, profiles, safety);
      await tester.pumpAndSettle();
      expect(profiles.reads, 0);
      expect(find.byKey(const ValueKey('profile-error')), findsOneWidget);
      expect(find.text('Other Player'), findsNothing);
      safety.failRead = false;
      await _tapVisible(tester, find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Other Player'), findsWidgets);
    },
  );
}

Future<void> _pumpProfile(
  WidgetTester tester,
  _Profiles profiles,
  _Safety safety,
) => tester.pumpWidget(
  MaterialApp(
    home: ProfileScreen(
      profileRepository: profiles,
      profileId: 'other',
      playerSafetyRepository: safety,
    ),
  ),
);

class _Profiles extends Fake implements ProfileRepository {
  String userId = 'viewer';
  int reads = 0;
  bool failProfile = false;
  @override
  String get currentUserId => userId;
  @override
  Future<PlayerProfile> getProfile(String id) async {
    reads++;
    if (failProfile) {
      throw StateError('Unavailable');
    }
    return PlayerProfile(
      id: id,
      displayName: 'Other Player',
      username: 'other',
      bio: 'Authored bio',
      followingCount: 1,
      fansCount: 2,
      appearances: 3,
      goals: 4,
      assists: 5,
      highlights: const [],
      career: const [],
    );
  }
}

class _Safety implements PlayerSafetyRepository {
  String userId = 'viewer';
  bool blocked = false;
  bool incomingBlock = false;
  bool failRead = false;
  bool failWrite = false;
  bool failAfterCommit = false;
  bool failReadAfterWrite = false;
  int reads = 0;
  final writes = <bool>[];
  Completer<PlayerSafetyState>? pendingRead;
  @override
  String get currentUserId => userId;
  PlayerSafetyState get state => PlayerSafetyState(
    profileId: 'other',
    blockedByMe: blocked,
    interactionBlocked: blocked || incomingBlock,
  );
  @override
  Future<PlayerSafetyState> getState(String profileId) async {
    reads++;
    if (failRead) {
      throw StateError('Unavailable');
    }
    if (pendingRead != null) {
      return pendingRead!.future;
    }
    return state;
  }

  @override
  Future<PlayerSafetyState> setBlocked(
    String profileId, {
    required bool blocked,
  }) async {
    writes.add(blocked);
    if (failAfterCommit) {
      this.blocked = blocked;
      failRead = failReadAfterWrite;
      throw TimeoutException('Response lost after commit');
    }
    if (failWrite) {
      throw StateError('Unavailable');
    }
    this.blocked = blocked;
    failRead = failReadAfterWrite;
    return state;
  }

  @override
  Future<List<BlockedPlayer>> listBlockedPlayers() async => blocked
      ? [
          const BlockedPlayer(
            profileId: 'other',
            username: 'other',
            displayName: 'Other Player',
          ),
        ]
      : [];
}

SupabaseClient _client(Future<http.Response> Function(http.Request) handler) =>
    SupabaseClient(
      'https://fieldrush-tests.invalid',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(handler),
    );
http.Response _response(
  http.Request request,
  Object? value, {
  int status = 200,
}) => http.Response(
  jsonEncode(value),
  status,
  request: request,
  headers: {'content-type': 'application/json'},
);
Map<String, dynamic> _stateJson(bool blocked) => {
  'profile_id': 'other',
  'blocked_by_me': blocked,
  'interaction_blocked': blocked,
};
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

class _PartyRepository with SupabaseOpenQueuePartyRepository {
  _PartyRepository(this.partyClient);
  @override
  final SupabaseClient partyClient;
}

class _ClipProfiles extends _Profiles {
  int refreshes = 0;
  @override
  Future<ProfileHighlight> refreshHighlight(String id) async {
    refreshes++;
    return ProfileHighlight(
      id: id,
      title: 'Confidential clip',
      thumbnailUrl: 'https://example.com/hidden.jpg',
      videoUrl: 'https://example.com/hidden.m3u8',
      duration: '0:30',
      views: 4,
      profileId: 'other',
    );
  }
}

ProfileHighlight _safeTestClip(String id) => ProfileHighlight(
  id: id,
  title: 'Clip $id',
  thumbnailUrl: '',
  duration: '0:30',
  views: 4,
  profileId: 'other',
);

class _RecommendationProfiles extends _Profiles
    implements ProfileClipRecommendationsRepository {
  @override
  Future<List<ProfileClipRecommendation>> getClipRecommendations({
    required String highlightId,
    int limit = 8,
  }) async => highlightId == 'first'
      ? [
          ProfileClipRecommendation(
            highlight: _safeTestClip('next'),
            profileId: 'other',
            username: 'other',
            displayName: 'Other Player',
          ),
        ]
      : [];
}

class _ConnectionProfiles extends _Profiles {
  bool failConnections = false;
  @override
  Future<ProfileConnections> getConnections() async {
    if (failConnections) {
      throw StateError('Unavailable');
    }
    return const ProfileConnections(
      following: [
        ProfileConnection(
          id: 'other',
          displayName: 'Other Player',
          username: 'other',
          isFollowedByMe: true,
        ),
      ],
      fans: [],
      discover: [],
    );
  }
}

Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  final visibleTarget = target.hitTestable();
  expect(visibleTarget, findsOneWidget);
  await tester.tap(visibleTarget);
}
