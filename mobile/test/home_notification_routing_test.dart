import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_detail_screen.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/home/activity_revision.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/home/home_discovery_repository.dart';
import 'package:field/src/home/home_discovery_screen.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/open_queue/fieldrush_booking_flow.dart';
import 'package:field/src/open_queue/fieldrush_checkout_sheet.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/open_queue/open_queue_review_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:field/src/ui/fieldrush_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUp(clearFieldrushActivityOpenRequest);
  tearDown(clearFieldrushActivityOpenRequest);

  testWidgets(
    'cold phone tap resolves its canonical receipt and opens its game',
    (tester) async {
      final game = _game('phone-game');
      final queue = _Queue(detail: _detail(game));
      await _openActivity(
        tester,
        queue,
        _notice('OPEN_QUEUE_GAME', game.id),
        phoneTap: true,
      );
      expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
      expect(find.byType(HomeDiscoveryScreen), findsNothing);
      expect(queue.detailRequests, everyElement(game.id));
      _expectNoCheckout(queue);
    },
  );

  testWidgets('expired or missing phone receipt falls back to Activity', (
    tester,
  ) async {
    final queue = _Queue();
    await _openActivity(
      tester,
      queue,
      _notice('OPEN_QUEUE_GAME', 'old-game'),
      phoneTap: true,
      missingPhoneReceipt: true,
    );
    expect(find.byType(HomeDiscoveryScreen), findsOneWidget);
    expect(queue.detailRequests, isEmpty);
    _expectNoCheckout(queue);
  });

  testWidgets(
    'phone tap queued for previous account cannot open private route',
    (tester) async {
      final queue = _Queue();
      await _openActivity(
        tester,
        queue,
        _notice('OPEN_QUEUE_GAME', 'private-game'),
        phoneTap: true,
        phoneOwner: 'previous-account',
      );
      expect(find.byType(HomeDiscoveryScreen), findsNothing);
      expect(find.byType(FieldrushGameDetailScreen), findsNothing);
      expect(queue.detailRequests, isEmpty);
    },
  );

  testWidgets('optional themed activity and search visual previews', (
    tester,
  ) async {
    final directory =
        Platform.environment['FIELDRUSH_DISCOVERY_SCREENSHOT_DIR'];
    if (directory == null) return;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        await (FontLoader(
          font,
        )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    for (final search in [false, true]) {
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: HomeDiscoveryScreen(
              repository: _PreviewDiscovery(),
              search: search,
              onPlayer: (_) async {},
              onNotification: (_) async {},
            ),
          ),
        ),
      );
      if (search) {
        await tester.enterText(
          find.byKey(const Key('home-player-search')),
          'Alex',
        );
        await tester.pump(const Duration(milliseconds: 310));
      }
      await tester.pumpAndSettle();
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 1);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File(
          '$directory/${search ? 'search' : 'activity'}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
      expect(tester.takeException(), isNull);
    }
  });

  test('notification payload maps only explicitly supported entity types', () {
    final party = HomeNotification.fromJson(
      _notificationJson(
        type: 'OPEN_QUEUE_PARTY_MEMBERSHIP',
        id: 'membership-id',
        data: {'game_id': 'actual-game'},
      ),
    );
    expect(party.entityId, 'membership-id');
    expect(party.openQueueGameId, 'actual-game');
    expect(party.fixtureId, isNull);

    final incident = HomeNotification.fromJson(
      _notificationJson(
        type: 'CLAN_RELIABILITY_INCIDENT',
        id: 'incident-id',
        data: {'fixture_id': 'actual-fixture'},
      ),
    );
    expect(incident.fixtureId, 'actual-fixture');
    expect(incident.openQueueGameId, isNull);

    for (final payload in [
      null,
      [],
      {'game_id': 42},
      {'game_id': '  '},
    ]) {
      final item = HomeNotification.fromJson(
        _notificationJson(
          type: 'OPEN_QUEUE_PARTY_MEMBERSHIP',
          id: 'membership-id',
          data: payload,
        ),
      );
      expect(item.openQueueGameId, isNull);
    }
    final unsupported = HomeNotification.fromJson(
      _notificationJson(
        type: 'SUPPORT_TICKET',
        id: 'actual-game',
        data: {'game_id': 'actual-game', 'fixture_id': 'actual-fixture'},
      ),
    );
    expect(unsupported.openQueueGameId, isNull);
    expect(unsupported.fixtureId, isNull);
  });

  test(
    'repository loads owned unresolved activity including JSON data',
    () async {
      final requests = <http.Request>[];
      final client = _client(
        requests,
        (request) => [
          _notificationJson(
            type: 'OPEN_QUEUE_PARTY_MEMBERSHIP',
            id: 'membership-id',
            data: {'game_id': 'actual-game'},
          ),
        ],
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(_session));
      final items = await SupabaseHomeDiscoveryRepository(
        client: client,
      ).notifications();
      expect(items.single.openQueueGameId, 'actual-game');
      final query = requests.single.url.queryParameters;
      expect(query['select'], contains('data'));
      expect(query['recipient_profile_id'], 'eq.profile');
      expect(query['resolved_at'], 'is.null');
      expect(query['dismissed_at'], 'is.null');
      expect(query['order'], startsWith('created_at.desc'));
    },
  );

  test('dismissal uses the recipient-owned activity receipt RPC', () async {
    final requests = <http.Request>[];
    final client = _client(requests, (_) => null);
    addTearDown(client.dispose);
    await SupabaseHomeDiscoveryRepository(client: client).dismiss('notice');
    expect(
      requests.single.url.path,
      '/rest/v1/rpc/dismiss_my_home_notification',
    );
    expect(jsonDecode(requests.single.body), {
      'notification_id_to_use': 'notice',
    });
  });

  test(
    'public search normalizes blank avatar URLs without private fields',
    () async {
      final requests = <http.Request>[];
      final client = _client(
        requests,
        (_) => [
          {
            'id': 'a',
            'content_hidden': false,
            'display_name': 'Dana',
            'username': 'dana',
            'avatar_url': '  ',
          },
          {
            'id': 'b',
            'content_hidden': false,
            'display_name': 'Sam',
            'username': 'sam',
            'avatar_url': null,
          },
        ],
      );
      addTearDown(client.dispose);
      final players = await SupabaseHomeDiscoveryRepository(
        client: client,
      ).searchPlayers('da');
      expect(players.map((player) => player.avatarUrl), [null, null]);
      expect(requests.first.url.path, '/rest/v1/rpc/search_fieldrush_players');
      expect(jsonDecode(requests.first.body), {'query_to_use': 'da'});
      expect(requests, hasLength(2));
      expect(
        requests.last.url.path,
        '/rest/v1/rpc/list_fieldrush_profile_identities',
      );
      expect(jsonDecode(requests.last.body), {
        'profile_ids_to_use': ['a', 'b'],
      });
    },
  );

  testWidgets(
    'nonempty player search renders a tappable card without assertions',
    (tester) async {
      String? openedId;
      final repository = _Discovery(
        _notice('SUPPORT_TICKET', 'support'),
        readFails: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: HomeDiscoveryScreen(
            repository: repository,
            search: true,
            onPlayer: (id) async {
              openedId = id;
            },
            onNotification: (_) async {},
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('home-player-search')),
        'Dana',
      );
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      final tile = find.byKey(
        const ValueKey('home-search-player-found-player'),
      );
      expect(tile, findsOneWidget);
      final search = tester.widget<TextField>(
        find.byKey(const Key('home-player-search')),
      );
      expect(search.style?.fontFamily, 'PlusJakartaSans');
      expect(search.style?.fontWeight, FontWeight.w700);
      expect(search.decoration?.enabledBorder, InputBorder.none);
      expect(search.decoration?.focusedBorder, InputBorder.none);
      expect(find.text('@dana', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(openedId, 'found-player');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'activity is compact and resolution persists without opening it',
    (tester) async {
      final repository = _Discovery(
        _notice('SUPPORT_TICKET', 'support'),
        readFails: false,
      );
      var opens = 0;
      Widget screen() => MaterialApp(
        home: HomeDiscoveryScreen(
          repository: repository,
          onPlayer: (_) async {},
          onNotification: (_) async => opens++,
        ),
      );
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('home-notification-notification'));
      expect(tester.getSize(tile).height, lessThan(100));
      expect(find.byKey(const ValueKey('activity-unread-dot')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('home-notification-resolve-notification')),
      );
      await tester.pumpAndSettle();
      expect(repository.dismissedIds, ['notification']);
      expect(opens, 0);
      expect(repository.readIds, isEmpty);
      expect(tile, findsNothing);
      expect(find.text("You're all caught up."), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(tile, findsNothing);
      expect(find.text("You're all caught up."), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clan search cannot retain authored artwork after a failed return refresh',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final clans = _SearchClans();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: HomeDiscoveryScreen(
            repository: _ActivityDiscovery(),
            search: true,
            initialClans: true,
            clanRepository: clans,
            onPlayer: (_) async {},
            onNotification: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('home-search-clan-search-clan'));
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(row.hitTestable(), findsOneWidget);
      await tester.tap(row.hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(ClanDetailScreen), findsOneWidget);
      clans.failReads = true;
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(clans.reads, greaterThanOrEqualTo(3));
      expect(row, findsNothing);
      expect(
        find.textContaining('Original club artwork', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('Original clan motto', findRichText: true),
        findsNothing,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed activity resolution leaves the item and supports retry', (
    tester,
  ) async {
    final repository = _Discovery(
      _notice('SUPPORT_TICKET', 'support'),
      readFails: false,
      dismissFails: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeDiscoveryScreen(
          repository: repository,
          onPlayer: (_) async {},
          onNotification: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final resolve = find.byKey(
      const ValueKey('home-notification-resolve-notification'),
    );
    await tester.tap(resolve);
    await tester.pumpAndSettle();
    expect(repository.dismissedIds, isEmpty);
    expect(
      find.byKey(
        const ValueKey('home-notification-resolve-error-notification'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-notification-notification')),
      findsOneWidget,
    );
    repository.dismissFails = false;
    await tester.tap(resolve);
    await tester.pumpAndSettle();
    expect(repository.dismissedIds, ['notification']);
    expect(find.text("You're all caught up."), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('activity dismisses immediately while its receipt is saving', (
    tester,
  ) async {
    final receipt = Completer<void>();
    final repository = _ActivityDiscovery(dismissReceipt: receipt);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeDiscoveryScreen(
          repository: repository,
          onPlayer: (_) async {},
          onNotification: (_) async => fail('Dismiss must not open the item'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('home-notification-resolve-first')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('home-notification-first')), findsNothing);
    expect(
      find.byKey(const ValueKey('home-notification-second')),
      findsOneWidget,
    );
    receipt.complete();
    await tester.pumpAndSettle();
    expect(repository.dismissed, ['first']);
  });

  testWidgets('mark all read preserves rows and retries only failed receipts', (
    tester,
  ) async {
    final repository = _ActivityDiscovery()..failedReads.add('second');
    await tester.pumpWidget(
      MaterialApp(
        home: HomeDiscoveryScreen(
          repository: repository,
          onPlayer: (_) async {},
          onNotification: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-unread-dot')), findsNWidgets(2));
    await tester.tap(find.text('Mark all read'));
    await tester.pumpAndSettle();
    expect(repository.read, ['first', 'second']);
    expect(find.byKey(const ValueKey('activity-unread-dot')), findsOneWidget);
    expect(
      find.text('Could not mark all activity as read. Try again.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-notification-first')),
      findsOneWidget,
    );
    repository.failedReads.clear();
    await tester.tap(find.text('Mark all read'));
    await tester.pumpAndSettle();
    expect(repository.read, ['first', 'second', 'second']);
    expect(find.text('Mark all read'), findsNothing);
    expect(find.byKey(const ValueKey('activity-unread-dot')), findsNothing);
    expect(repository.dismissed, isEmpty);
  });

  testWidgets('opening activity does not wait for the read receipt', (
    tester,
  ) async {
    final receipt = Completer<void>();
    final repository = _ActivityDiscovery(readReceipt: receipt);
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeDiscoveryScreen(
          repository: repository,
          onPlayer: (_) async {},
          onNotification: (_) async {
            opened = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-notification-first')));
    await tester.pump();
    expect(opened, isTrue);
    expect(find.byKey(const ValueKey('activity-unread-dot')), findsOneWidget);
    receipt.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('returning from a resolved party invite refreshes Activity', (
    tester,
  ) async {
    final repository = _ActivityDiscovery()
      ..feed = [
        _notice(
          'OPEN_QUEUE_PARTY_MEMBERSHIP',
          'membership',
          data: {'game_id': 'game'},
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: HomeDiscoveryScreen(
          repository: repository,
          onPlayer: (_) async {},
          onNotification: (_) async => repository.feed = [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('home-notification-notification')),
    );
    await tester.pumpAndSettle();
    expect(repository.loads, greaterThanOrEqualTo(2));
    expect(
      find.byKey(const ValueKey('home-notification-notification')),
      findsNothing,
    );
    expect(find.text("You're all caught up."), findsOneWidget);
  });

  testWidgets(
    'failed Activity return preserves operational notices and cannot restore pending invite bodies',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final dismissReceipt = Completer<void>();
      final repository = _ActivityDiscovery(dismissReceipt: dismissReceipt)
        ..feed = [
          _pendingPartyActivity('party-open'),
          _pendingPartyActivity('party-dismissed'),
          _operationalActivity(),
        ];
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: HomeDiscoveryScreen(
            repository: repository,
            onPlayer: (_) async {},
            onNotification: (_) async {
              await navigator.currentState!.push<void>(
                MaterialPageRoute(
                  builder: (_) =>
                      const Scaffold(body: Text('Game destination')),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('home-notification-resolve-party-dismissed')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('home-notification-party-open')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Game destination'), findsOneWidget);
      // Any read-receipt/realtime invalidation while the detail route is open
      // must not fetch an older pending invitation back into its backdrop.
      expect(repository.loads, 1);
      repository.failNotifications = true;
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      // An earlier optimistic dismissal can also fail after the safety change.
      // Its saved _latestActivity entry must not resurrect the private body.
      dismissReceipt.completeError(StateError('Offline after safety change'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-notification-party-open')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-notification-resolve-party-open')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-notification-party-dismissed')),
        findsNothing,
      );
      expect(
        find.textContaining('Private party invitation', findRichText: true),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-notification-official')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Your refund is processing.', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a pre-navigation Activity reply cannot restore invitations after a failed return refresh',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final originalFeed = [
        _pendingPartyActivity('party'),
        _operationalActivity(),
      ];
      final repository = _ActivityDiscovery()..feed = originalFeed;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: HomeDiscoveryScreen(
            repository: repository,
            onPlayer: (_) async {},
            onNotification: (_) async {
              await navigator.currentState!.push<void>(
                MaterialPageRoute(
                  builder: (_) =>
                      const Scaffold(body: Text('Activity destination')),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final staleReply = Completer<List<HomeNotification>>();
      repository.pendingNotifications = staleReply;
      repository.changes.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(repository.loads, 2);
      expect(
        find.byKey(const ValueKey('home-notification-party')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('home-notification-official')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Activity destination'), findsOneWidget);
      repository.pendingNotifications = null;
      repository.failNotifications = true;
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(repository.loads, 3);
      staleReply.complete(originalFeed);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-notification-party')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-notification-resolve-party')),
        findsNothing,
      );
      expect(
        find.textContaining('Private party invitation', findRichText: true),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-notification-official')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Your refund is processing.', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('server read and dismiss changes refresh an open Activity page', (
    tester,
  ) async {
    final repository = _ActivityDiscovery();
    await tester.pumpWidget(
      MaterialApp(
        home: HomeDiscoveryScreen(
          repository: repository,
          onPlayer: (_) async {},
          onNotification: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    repository.persistedReads.add('first');
    repository.changes.add(null);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-unread-dot')), findsOneWidget);
    repository.dismissed.add('second');
    repository.changes.add(null);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('home-notification-second')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('activity-unread-dot')), findsNothing);
  });

  testWidgets(
    'push invalidation refreshes Activity without trusting push data',
    (tester) async {
      final repository = _ActivityDiscovery();
      await tester.pumpWidget(
        MaterialApp(
          home: HomeDiscoveryScreen(
            repository: repository,
            onPlayer: (_) async {},
            onNotification: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      repository.feed = [];
      notifyFieldrushActivityChanged();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text("You're all caught up."), findsOneWidget);
    },
  );

  testWidgets('a failed dismissal never resurrects a resolved invitation', (
    tester,
  ) async {
    final receipt = Completer<void>();
    final repository = _ActivityDiscovery(dismissReceipt: receipt);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeDiscoveryScreen(
          repository: repository,
          onPlayer: (_) async {},
          onNotification: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('home-notification-resolve-first')),
    );
    await tester.pump();
    repository.feed = [];
    repository.changes.add(null);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    receipt.completeError(StateError('lost receipt response'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-notification-first')), findsNothing);
    expect(find.text("You're all caught up."), findsOneWidget);
  });

  testWidgets('opening Activity twice cannot push duplicate destinations', (
    tester,
  ) async {
    final destination = Completer<void>();
    final repository = _ActivityDiscovery();
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeDiscoveryScreen(
          repository: repository,
          onPlayer: (_) async {},
          onNotification: (_) async {
            opens++;
            await destination.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final item = find.byKey(const ValueKey('home-notification-first'));
    await tester.tap(item);
    await tester.pump();
    await tester.tap(item);
    await tester.pump();
    expect(opens, 1);
    expect(repository.read, ['first']);
    destination.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('game activity opens a known booking instead of checkout', (
    tester,
  ) async {
    final game = _game('booked');
    final queue = _Queue(bookings: [_booking(game)]);
    await _openActivity(tester, queue, _notice('OPEN_QUEUE_GAME', game.id));
    expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
    expect(
      tester
          .widget<FieldrushGameDetailScreen>(
            find.byType(FieldrushGameDetailScreen),
          )
          .gameId,
      game.id,
    );
    expect(find.text('Leave game'), findsOneWidget);
    expect(queue.detailRequests, [game.id]);
    _expectNoCheckout(queue);
  });

  testWidgets('party activity uses game_id, not the membership entity ID', (
    tester,
  ) async {
    final game = _game('party-game');
    final queue = _Queue(bookings: [_booking(game)]);
    await _openActivity(
      tester,
      queue,
      _notice(
        'OPEN_QUEUE_PARTY_MEMBERSHIP',
        'membership-id',
        data: {'game_id': game.id},
      ),
    );
    expect(
      tester
          .widget<FieldrushGameDetailScreen>(
            find.byType(FieldrushGameDetailScreen),
          )
          .gameId,
      game.id,
    );
    expect(queue.detailRequests, [game.id]);
    expect(queue.detailRequests, isNot(contains('membership-id')));
    _expectNoCheckout(queue);
  });

  testWidgets('historical cancelled game opens by ID outside the Home feed', (
    tester,
  ) async {
    final game = _game('old-game', status: 'CANCELLED', past: true);
    final queue = _Queue(detail: _detail(game));
    await _openActivity(tester, queue, _notice('OPEN_QUEUE_GAME', game.id));
    final screen = tester.widget<FieldrushGameDetailScreen>(
      find.byType(FieldrushGameDetailScreen),
    );
    expect(screen.gameId, game.id);
    expect(find.text('Game cancelled'), findsOneWidget);
    expect(find.byKey(const ValueKey('game-main-action')), findsNothing);
    expect(queue.games, isEmpty);
    expect(queue.detailRequests, [game.id]);
    _expectNoCheckout(queue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('game activity opens details even when that game is bookable', (
    tester,
  ) async {
    final game = _game('available');
    final queue = _Queue(games: [game], detail: _detail(game));
    await _openActivity(tester, queue, _notice('OPEN_QUEUE_GAME', game.id));
    expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
    expect(
      tester
          .widget<FieldrushGameDetailScreen>(
            find.byType(FieldrushGameDetailScreen),
          )
          .gameId,
      game.id,
    );
    expect(queue.detailRequests, [game.id]);
    expect(find.text('Join · \$13.00'), findsOneWidget);
    _expectNoCheckout(queue);
  });

  testWidgets('clan activity fetches a fixture absent from the Home feed', (
    tester,
  ) async {
    final fixture = _fixture('old-fixture');
    final fixtures = _Fixtures(detail: fixture);
    await _openActivity(
      tester,
      _Queue(),
      _notice('FIXTURE', fixture.id),
      fixtures: fixtures,
    );
    expect(
      tester
          .widget<FixtureDetailScreen>(find.byType(FixtureDetailScreen))
          .fixture
          .id,
      fixture.id,
    );
    expect(fixtures.requests, isNotEmpty);
    expect(fixtures.requests, everyElement(fixture.id));
  });

  testWidgets(
    'fixture entity type wins over a same-ID booking and uses the loaded fixture',
    (tester) async {
      final fixture = _fixture('shared-id');
      final fixtures = _Fixtures(detail: fixture, feed: [fixture]);
      final queue = _Queue(bookings: [_booking(_game(fixture.id))]);
      await _openActivity(
        tester,
        queue,
        _notice('FIXTURE', fixture.id),
        fixtures: fixtures,
      );
      expect(find.byType(FieldrushGameDetailScreen), findsNothing);
      final screen = tester.widget<FixtureDetailScreen>(
        find.byType(FixtureDetailScreen),
      );
      expect(screen.fixture, same(fixture));
      expect(screen.sourceLabel, isNull);
      // Only the detail screen's quiet refresh fetches; routing uses the cache.
      expect(fixtures.requests, [fixture.id]);
      expect(queue.detailRequests, isEmpty);
      _expectNoCheckout(queue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reliability incident activity uses its fixture payload ID', (
    tester,
  ) async {
    final fixture = _fixture('incident-fixture');
    final fixtures = _Fixtures(detail: fixture);
    await _openActivity(
      tester,
      _Queue(),
      _notice(
        'CLAN_RELIABILITY_INCIDENT',
        'incident-id',
        data: {'fixture_id': fixture.id},
      ),
      fixtures: fixtures,
    );
    expect(
      tester
          .widget<FixtureDetailScreen>(find.byType(FixtureDetailScreen))
          .fixture
          .id,
      fixture.id,
    );
    expect(fixtures.requests, everyElement(fixture.id));
  });

  testWidgets(
    'unsupported activity shows the full message despite ID collision',
    (tester) async {
      final game = _game('same-id');
      final queue = _Queue(bookings: [_booking(game)], games: [game]);
      final notice = _notice(
        'SUPPORT_TICKET',
        game.id,
        data: {'game_id': game.id},
      );
      await _openActivity(tester, queue, notice);
      expect(
        find.byKey(const Key('home-notification-details')),
        findsOneWidget,
      );
      final sheet = tester.widget<FieldrushModal>(find.byType(FieldrushModal));
      expect(sheet.title, notice.title);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        notice.body,
      );
      expect(find.byType(FieldrushGameDetailScreen), findsNothing);
      expect(find.byType(FixtureDetailScreen), findsNothing);
      expect(queue.detailRequests, isEmpty);
      _expectNoCheckout(queue);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-notification-details')), findsNothing);
    },
  );

  testWidgets('malformed party activity still displays its full message', (
    tester,
  ) async {
    await _openActivity(
      tester,
      _Queue(),
      _notice('OPEN_QUEUE_PARTY_MEMBERSHIP', 'membership'),
    );
    expect(find.byKey(const Key('home-notification-details')), findsOneWidget);
    expect(find.byType(FieldrushGameDetailScreen), findsNothing);
  });

  testWidgets(
    'game fetch errors stay visible in detail and retry the same ID',
    (tester) async {
      final queue = _Queue();
      await _openActivity(tester, queue, _notice('OPEN_QUEUE_GAME', 'missing'));
      expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
      expect(
        find.textContaining('We could not load this game'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(queue.detailRequests, ['missing']);
      _expectNoCheckout(queue);

      queue.detail = _detail(_game('missing'));
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(queue.detailRequests, ['missing', 'missing']);
      expect(find.textContaining('We could not load this game'), findsNothing);
      expect(find.byKey(const ValueKey('fieldrush-game-hero')), findsOneWidget);
      _expectNoCheckout(queue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fixture fetch errors show feedback instead of silently doing nothing',
    (tester) async {
      final queue = _Queue();
      await _openActivity(
        tester,
        queue,
        _notice('FIXTURE', 'missing'),
        fixtures: _Fixtures(),
      );
      expect(find.byType(FieldrushToast), findsOneWidget);
      expect(find.textContaining('Could not open'), findsOneWidget);
      expect(find.byType(FixtureDetailScreen), findsNothing);
      expect(find.byType(FieldrushGameDetailScreen), findsNothing);
      _expectNoCheckout(queue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read receipt failure never blocks the notification destination',
    (tester) async {
      final game = _game('booked');
      final queue = _Queue(bookings: [_booking(game)]);
      await _openActivity(
        tester,
        queue,
        _notice('OPEN_QUEUE_GAME', game.id),
        readFails: true,
      );
      expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
      expect(
        tester
            .widget<FieldrushGameDetailScreen>(
              find.byType(FieldrushGameDetailScreen),
            )
            .gameId,
        game.id,
      );
      expect(find.text('Leave game'), findsOneWidget);
      _expectNoCheckout(queue);
      expect(tester.takeException(), isNull);
    },
  );
}

void _expectNoCheckout(_Queue queue) {
  expect(find.byType(FieldrushBookingFlow), findsNothing);
  expect(find.byType(FieldrushCheckoutSheet), findsNothing);
  expect(find.byType(OpenQueueReviewScreen), findsNothing);
  expect(queue.bookRequests, isEmpty);
}

Future<void> _openActivity(
  WidgetTester tester,
  _Queue queue,
  HomeNotification item, {
  _Fixtures? fixtures,
  bool readFails = false,
  bool phoneTap = false,
  bool missingPhoneReceipt = false,
  String phoneOwner = 'profile',
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final discovery = _Discovery(item, readFails: readFails)
    ..missingPhoneReceipt = missingPhoneReceipt;
  if (phoneTap) requestFieldrushNotificationOpen(item.id, phoneOwner);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DashboardHome(
          profileRepository: _Profiles(),
          clanRepository: _Clans(),
          fixtureRepository: fixtures ?? _Fixtures(),
          leaderboardRepository: _Ranks(),
          openQueueRepository: queue,
          discoveryRepository: discovery,
          onOpenClans: () {},
          onOpenFixtures: () {},
          onOpenRanks: () {},
          onOpenProfile: () {},
          onNavigateTab: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (phoneTap) {
    expect(
      discovery.readIds,
      missingPhoneReceipt || phoneOwner != 'profile' ? isEmpty : [item.id],
    );
    return;
  }
  tester
      .widget<FieldrushHomeHeader>(find.byType(FieldrushHomeHeader))
      .onActivity();
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('home-notification-${item.id}')));
  await tester.pumpAndSettle();
  expect(discovery.readIds, [item.id]);
}

HomeNotification _notice(
  String type,
  String id, {
  Map<String, dynamic> data = const {},
}) => HomeNotification(
  id: 'notification',
  title: 'A complete activity title',
  body:
      'The full notification body is available here, including all of its details.',
  createdAt: DateTime.utc(2026, 10, 10),
  entityType: type,
  entityId: id,
  data: data,
);

Map<String, dynamic> _notificationJson({
  required String type,
  required String id,
  Object? data,
}) => {
  'id': 'notification',
  'title': 'Activity',
  'body': 'Complete message',
  'created_at': '2026-10-10T12:00:00Z',
  'read_at': null,
  'related_entity_type': type,
  'related_entity_id': id,
  'data': data,
};

SupabaseClient _client(
  List<http.Request> requests,
  Object? Function(http.Request) response,
) => SupabaseClient(
  'https://fieldrush-tests.invalid',
  'test-anon-key-not-a-secret',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
  httpClient: MockClient((request) async {
    requests.add(request);
    return http.Response(
      jsonEncode(response(request)),
      200,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }),
);

final _session = {
  'access_token': 'test-access-token',
  'token_type': 'bearer',
  'expires_in': 3600,
  'refresh_token': 'test-refresh-token',
  'user': {
    'id': 'profile',
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': '',
    'phone': '',
    'created_at': '2026-10-10T12:00:00Z',
    'app_metadata': {},
    'user_metadata': {},
  },
};

OpenQueueGame _game(String id, {String status = 'OPEN', bool past = false}) =>
    OpenQueueGame(
      id: id,
      status: status,
      venue: 'Phoenix Sports Park',
      startsAt: DateTime.now().add(Duration(days: past ? -2 : 2)),
      endsAt: DateTime.now().add(Duration(days: past ? -2 : 2, hours: 1)),
      timezone: 'America/Phoenix',
      currency: 'USD',
      priceFils: 13000,
      ageLabel: '18+',
      capacity: 14,
      confirmedCount: 8,
      spots: const {
        OpenQueueRole.goalkeeper: 1,
        OpenQueueRole.defender: 3,
        OpenQueueRole.attacker: 2,
      },
    );

OpenQueueBooking _booking(OpenQueueGame game) => OpenQueueBooking(
  id: 'booking-${game.id}',
  gameId: game.id,
  profileId: 'profile',
  role: OpenQueueRole.defender,
  status: 'CONFIRMED',
  amountPaidFils: game.priceFils,
  bookedAt: DateTime.now(),
  game: game,
);

OpenQueueMatchDetail _detail(OpenQueueGame game) =>
    OpenQueueMatchDetail(game: game, scorers: const [], timeline: const []);

Fixture _fixture(String id) => Fixture(
  id: id,
  status: FixtureStatus.finalResult,
  homeClanId: 'clan',
  venue: 'Legacy Stadium',
  day: 'Tuesday',
  timeSlot: '7:00 PM - 8:00 PM',
  matchDate: DateTime(2026, 1, 6),
  createdBy: 'profile',
  homeClan: const FixtureClan(
    id: 'clan',
    name: 'Falcons',
    tag: 'FLC',
    emblem: '⚽',
    themeId: 'pitch',
    patternId: 'solid',
    skillRating: 1200,
  ),
);

const _profile = PlayerProfile(
  id: 'profile',
  displayName: 'Dana A.',
  username: 'dana',
  bio: '',
  followingCount: 0,
  fansCount: 0,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: [],
  career: [],
);

class _Profiles extends Fake implements ProfileRepository {
  @override
  Future<PlayerProfile> getCurrentProfile() async => _profile;
}

class _Clans extends Fake implements ClanRepository {
  @override
  Future<List<Clan>> listClans() async => [];
  @override
  Future<ClanMembership?> getMyClanMembership() async => null;
}

class _Ranks extends Fake implements LeaderboardRepository {
  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async => const PlayerRatingLeaderboardEntry(
    rank: 0,
    profileId: 'profile',
    displayName: 'Dana A.',
    username: 'dana',
    skillRating: 1200,
    matchesPlayed: 0,
    wins: 0,
    losses: 0,
    draws: 0,
    lastChange: 0,
    region: 'phoenix',
  );
}

class _Queue extends Fake implements OpenQueueRepository {
  _Queue({this.bookings = const [], this.games = const [], this.detail});
  final List<OpenQueueBooking> bookings;
  final List<OpenQueueGame> games;
  OpenQueueMatchDetail? detail;
  final detailRequests = <String>[];
  final bookRequests = <String>[];
  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => bookings;
  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async =>
      bookings.firstOrNull;
  @override
  Future<List<OpenQueueGame>> listGames() async => games;
  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => [];
  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String id) async {
    detailRequests.add(id);
    if (detail?.game.id == id) return detail!;
    final booking = bookings
        .where((booking) => booking.gameId == id)
        .firstOrNull;
    if (booking != null) return _detail(booking.game);
    throw Exception('internal server error');
  }

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) async {
    bookRequests.add(game.id);
    throw StateError('Opening activity must never create a booking.');
  }
}

class _Fixtures extends Fake implements FixtureRepository {
  _Fixtures({this.detail, this.feed = const []});
  final Fixture? detail;
  final List<Fixture> feed;
  final requests = <String>[];
  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;
  @override
  Future<List<Fixture>> listFixtures() async => feed;
  @override
  Future<Fixture> getFixture(String id) async {
    requests.add(id);
    if (detail == null) throw Exception('internal server error');
    return detail!;
  }
}

class _ActivityDiscovery extends Fake
    implements HomeDiscoveryRepository, HomeActivityChanges {
  _ActivityDiscovery({this.dismissReceipt, this.readReceipt}) {
    addTearDown(changes.close);
  }
  final Completer<void>? dismissReceipt;
  final Completer<void>? readReceipt;
  final failedReads = <String>{};
  final read = <String>[];
  final dismissed = <String>[];
  final persistedReads = <String>{};
  final changes = StreamController<void>.broadcast();
  List<HomeNotification>? feed;
  bool failNotifications = false;
  Completer<List<HomeNotification>>? pendingNotifications;
  int loads = 0;
  @override
  Stream<void> watchActivityChanges() => changes.stream;
  @override
  Future<List<HomeNotification>> notifications() async {
    loads++;
    final pending = pendingNotifications;
    if (pending != null) {
      return pending.future;
    }
    if (failNotifications) {
      throw StateError('Activity is offline');
    }
    return feed ??
        [
          for (final id in ['first', 'second'])
            if (!dismissed.contains(id))
              HomeNotification(
                id: id,
                title: 'Marcus K.',
                body: 'started following you.',
                createdAt: DateTime.now().subtract(const Duration(hours: 2)),
                readAt: persistedReads.contains(id) ? DateTime.now() : null,
              ),
        ];
  }

  @override
  Future<void> markRead(String id) async {
    read.add(id);
    if (readReceipt != null) await readReceipt!.future;
    if (failedReads.contains(id)) throw Exception('Read failed');
    persistedReads.add(id);
  }

  @override
  Future<void> dismiss(String id) async {
    if (dismissReceipt != null) await dismissReceipt!.future;
    dismissed.add(id);
  }
}

class _Discovery
    implements HomeDiscoveryRepository, HomeNotificationLookupRepository {
  _Discovery(this.item, {required this.readFails, this.dismissFails = false});
  final HomeNotification item;
  bool missingPhoneReceipt = false;
  @override
  String? get signedInProfileId => 'profile';
  @override
  Future<HomeNotification?> notificationById(String notificationId) async =>
      missingPhoneReceipt || notificationId != item.id ? null : item;
  final bool readFails;
  bool dismissFails;
  final readIds = <String>[];
  final dismissedIds = <String>[];
  @override
  Future<List<HomePlayerResult>> searchPlayers(String query) async => [
    const HomePlayerResult(id: 'found-player', name: 'Dana', username: 'dana'),
  ];
  @override
  Future<List<HomeNotification>> notifications() async =>
      dismissedIds.contains(item.id) ? [] : [item];
  @override
  Future<void> markRead(String id) async {
    readIds.add(id);
    if (readFails) throw Exception('test read receipt failed');
  }

  @override
  Future<void> dismiss(String id) async {
    if (dismissFails) throw Exception('test dismiss failed');
    dismissedIds.add(id);
  }
}

class _PreviewDiscovery extends Fake implements HomeDiscoveryRepository {
  @override
  Future<List<HomeNotification>> notifications() async => [
    for (final (id, title, body, read) in [
      (
        'game',
        'Your spot is confirmed',
        'Phoenix Sports Park · Friday, 7:30 PM. Get ready for game night.',
        false,
      ),
      (
        'invite',
        'Party invite from Sam',
        'Sam wants to team up for your next game.',
        false,
      ),
      (
        'support',
        'Your support ticket has an update',
        'We replied to your question. Tap to view the details.',
        true,
      ),
      (
        'rating',
        'Match result posted',
        'Your latest game has been added to match history.',
        true,
      ),
    ])
      HomeNotification(
        id: id,
        title: title,
        body: body,
        createdAt: DateTime(2026, 10, 12),
        readAt: read ? DateTime(2026, 10, 12) : null,
      ),
  ];

  @override
  Future<List<HomePlayerResult>> searchPlayers(String query) async => const [
    HomePlayerResult(
      id: 'alex',
      name: 'Alex Morgan',
      username: 'alexm',
      skillRating: 1438,
      matchesPlayed: 6,
      cityName: 'Phoenix',
    ),
    HomePlayerResult(
      id: 'alexandra',
      name: 'Alexandra Reyes',
      username: 'alexreyes',
    ),
  ];
}

HomeNotification _pendingPartyActivity(String id) => HomeNotification(
  id: id,
  title: 'Inviter $id',
  body: 'Private party invitation from $id',
  createdAt: DateTime.utc(2026, 10, 10),
  type: 'OPEN_QUEUE_PARTY_INVITE',
  entityType: 'OPEN_QUEUE_PARTY_MEMBERSHIP',
  entityId: 'membership-$id',
  data: const {'game_id': 'game'},
);
HomeNotification _operationalActivity() => HomeNotification(
  id: 'official',
  title: 'Booking refund',
  body: 'Your refund is processing.',
  createdAt: DateTime.utc(2026, 10, 10),
  type: 'PLAYER_CHECKOUT_REFUND_PENDING',
  entityType: 'OPEN_QUEUE_GAME',
  entityId: 'game',
);

class _SearchClans extends Fake implements ClanRepository {
  bool failReads = false;
  int reads = 0;
  @override
  Future<List<Clan>> listClans() async {
    reads++;
    if (failReads) {
      throw StateError('Offline after player safety changed');
    }
    return const [
      Clan(
        id: 'search-clan',
        name: 'Original club artwork',
        tag: 'ORI',
        motto: 'Original clan motto',
        emblem: '🦁',
        themeId: 'pitch',
        patternId: 'solid',
        skillRating: 1200,
        wins: 0,
        losses: 0,
        memberCount: 1,
        createdBy: 'creator',
      ),
    ];
  }

  @override
  Future<ClanMembership?> getMyClanMembership() async => null;
  @override
  Future<List<ClanMember>> listClanMembers(String id) async => [];
  @override
  Future<List<ClanJoinRequest>> listPendingJoinRequests(String id) async => [];
}
