import 'dart:async';

import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_connections_screen.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/ui/field_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cream people layout fits a narrow viewport and larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpScreen(tester, _ConnectionsRepository(), textScale: 1.6);

    expect(find.text('@current_player'), findsOneWidget);
    expect(find.text('Following · 1'), findsOneWidget);
    expect(find.text('Fans · 0'), findsOneWidget);
    expect(find.text('Search 1 following'), findsOneWidget);
    expect(find.text('Unfollow'), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xFFFAF7EF),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search matches handles and changing tabs clears the query', (
    tester,
  ) async {
    final repository = _ConnectionsRepository(
      connections: ProfileConnections(
        following: [_ali, _mina.copyWith(isFollowedByMe: true)],
        fans: [_omar],
        discover: [_omar],
      ),
    );
    await _pumpScreen(tester, repository);

    await tester.enterText(find.byType(TextField), '@MINA');
    await tester.pump();
    expect(find.text('Mina Hassan'), findsOneWidget);
    expect(find.text('Ali Altaraif'), findsNothing);
    expect(find.text('1 match'), findsOneWidget);
    expect(find.text('Discover players'), findsNothing);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.text('Ali Altaraif'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'no match');
    await tester.pump();
    expect(find.text('No players match “no match”'), findsOneWidget);
    await tester.tap(find.text('Fans · 1'));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('Omar Ahmed'), findsOneWidget);
    expect(find.text('Search 1 fans'), findsOneWidget);
    expect(find.text('Follow back'), findsOneWidget);
    // Incoming players must not also be duplicated in Discover.
    expect(find.text('Discover players'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'row navigation opens its profile and refreshes follow state on return',
    (tester) async {
      final repository = _ConnectionsRepository();
      final navigatorKey = GlobalKey<NavigatorState>();
      String? openedProfileId;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: ProfileConnectionsScreen(
            profileRepository: repository,
            initialTab: ProfileConnectionTab.following,
            onOpenProfile: (profileId) async {
              openedProfileId = profileId;
              await navigatorKey.currentState!.push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text('Player $profileId')),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ali Altaraif'));
      await tester.pumpAndSettle();
      expect(openedProfileId, 'ali-profile');
      expect(find.text('Player ali-profile'), findsOneWidget);

      repository.connections = ProfileConnections(
        following: [],
        fans: [],
        discover: [_ali.copyWith(isFollowedByMe: false)],
      );
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(repository.loadCalls, 2);
      expect(find.text('Following · 0'), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'follow back guards repeated taps and failure preserves another successful row',
    (tester) async {
      final aliUpdate = Completer<void>();
      final minaUpdate = Completer<void>();
      final repository = _ConnectionsRepository(
        connections: ProfileConnections(
          following: [],
          fans: [_ali.copyWith(isFollowedByMe: false), _mina],
          discover: [],
        ),
      );
      repository.onFollow = (id) =>
          id == _ali.id ? aliUpdate.future : minaUpdate.future;
      await _pumpScreen(tester, repository, tab: ProfileConnectionTab.fans);

      await tester.tap(find.byKey(const ValueKey('follow-ali-profile')));
      await tester.pump();
      final aliButton = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('follow-ali-profile')),
      );
      expect(aliButton.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('follow-ali-profile')));
      await tester.tap(find.byKey(const ValueKey('follow-mina-profile')));
      await tester.pump();
      expect(repository.followCalls, ['ali-profile', 'mina-profile']);
      expect(find.text('Following · 2'), findsOneWidget);
      expect(find.byType(FieldSkeleton), findsNWidgets(2));
      expect(find.byType(CircularProgressIndicator), findsNothing);

      aliUpdate.complete();
      await tester.pump();
      minaUpdate.completeError(StateError('Follow failed'));
      await tester.pumpAndSettle();
      expect(find.text('Following · 1'), findsOneWidget);
      expect(find.text('Fans · 2'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Follow back'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed unfollow restores the outgoing relationship and its count',
    (tester) async {
      final pending = Completer<void>();
      final repository = _ConnectionsRepository()
        ..onUnfollow = (_) => pending.future;
      await _pumpScreen(tester, repository);
      await tester.tap(find.text('Unfollow'));
      await tester.pump();
      expect(find.text('Following · 0'), findsOneWidget);
      expect(repository.unfollowCalls, ['ali-profile']);
      pending.completeError(StateError('Unfollow failed'));
      await tester.pumpAndSettle();
      expect(find.text('Following · 1'), findsOneWidget);
      expect(find.text('Unfollow'), findsOneWidget);
      expect(find.text('Discover players'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'back waits for follow mutation before returning settled counts',
    (tester) async {
      final pending = Completer<void>();
      final repository = _ConnectionsRepository(
        connections: ProfileConnections(
          following: [],
          fans: [_ali.copyWith(isFollowedByMe: false)],
          discover: [],
        ),
      )..onFollow = (_) => pending.future;
      final navigatorKey = GlobalKey<NavigatorState>();
      ProfileConnectionCounts? returnedCounts;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  returnedCounts = await Navigator.of(context)
                      .push<ProfileConnectionCounts>(
                        MaterialPageRoute(
                          builder: (_) => ProfileConnectionsScreen(
                            profileRepository: repository,
                            initialTab: ProfileConnectionTab.fans,
                            onOpenProfile: (_) async {},
                          ),
                        ),
                      );
                },
                child: const Text('Open people'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open people'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Follow back'));
      await tester.pump();
      expect(find.text('Following · 1'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await navigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(ProfileConnectionsScreen), findsOneWidget);
      expect(returnedCounts, isNull);

      pending.completeError(StateError('Follow failed'));
      await tester.pumpAndSettle();
      expect(find.text('Following · 0'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileConnectionsScreen), findsNothing);
      expect(returnedCounts!.followingCount, 0);
      expect(returnedCounts!.fansCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'initial loading uses skeletons and failed reads can be retried',
    (tester) async {
      final pending = Completer<ProfileConnections>();
      final repository = _ConnectionsRepository()
        ..onLoad = () => pending.future;
      await _pumpScreen(tester, repository);
      expect(find.byType(FieldLoadingContent), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      pending.completeError(StateError('Load failed'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      repository.onLoad = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Ali Altaraif'), findsOneWidget);
      expect(repository.loadCalls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a read started before a follow cannot overwrite its newer state',
    (tester) async {
      final oldRead = Completer<ProfileConnections>();
      final initial = ProfileConnections(
        following: [],
        fans: [],
        discover: [_ali.copyWith(isFollowedByMe: false)],
      );
      final repository = _ConnectionsRepository(connections: initial);
      await _pumpScreen(tester, repository);
      repository.onLoad = () => repository.loadCalls == 2
          ? oldRead.future
          : Future.value(repository.connections);
      final refresh = tester
          .widget<FieldRefreshIndicator>(find.byType(FieldRefreshIndicator))
          .onRefresh();
      await tester.tap(find.text('Follow'));
      await tester.pump();
      repository.connections = const ProfileConnections(
        following: [_ali],
        fans: [],
        discover: [],
      );
      oldRead.complete(initial);
      await refresh;
      await tester.pumpAndSettle();
      expect(find.text('Following · 1'), findsOneWidget);
      expect(find.text('Unfollow'), findsOneWidget);
      expect(repository.loadCalls, 3);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _ConnectionsRepository repository, {
  ProfileConnectionTab tab = ProfileConnectionTab.following,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ProfileConnectionsScreen(
        profileRepository: repository,
        initialTab: tab,
        username: 'current_player',
        onOpenProfile: (_) async {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _ali = ProfileConnection(
  id: 'ali-profile',
  displayName: 'Ali Altaraif',
  username: 'aliiii',
  isFollowedByMe: true,
);
const _mina = ProfileConnection(
  id: 'mina-profile',
  displayName: 'Mina Hassan',
  username: 'mina_h',
  isFollowedByMe: false,
);
const _omar = ProfileConnection(
  id: 'omar-profile',
  displayName: 'Omar Ahmed',
  username: 'omar_a',
  isFollowedByMe: false,
);

class _ConnectionsRepository implements ProfileRepository {
  _ConnectionsRepository({
    this.connections = const ProfileConnections(
      following: [_ali],
      fans: [],
      discover: [],
    ),
  });
  ProfileConnections connections;
  Future<ProfileConnections> Function()? onLoad;
  Future<void> Function(String)? onFollow;
  Future<void> Function(String)? onUnfollow;
  int loadCalls = 0;
  final followCalls = <String>[];
  final unfollowCalls = <String>[];

  @override
  String? get currentUserId => 'current-profile';

  @override
  Future<ProfileConnections> getConnections() async {
    loadCalls++;
    return onLoad == null ? connections : await onLoad!();
  }

  @override
  Future<void> followProfile(String profileId) async {
    followCalls.add(profileId);
    await onFollow?.call(profileId);
  }

  @override
  Future<void> unfollowProfile(String profileId) async {
    unfollowCalls.add(profileId);
    await onUnfollow?.call(profileId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
