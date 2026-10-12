import 'dart:async';

import 'package:field/src/profile/fieldrush_player_profile.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:field/src/ui/field_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('public profile has skeletons until its own data arrives', (
    tester,
  ) async {
    final repository = _Repository()..load = Completer<PlayerProfile>();
    await _pump(tester, repository);
    expect(find.byType(FieldSkeleton), findsWidgets);
    expect(find.byType(FieldrushPlayerProfileContent), findsNothing);
    repository.load!.complete(_profile('other'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushPlayerProfileContent), findsOneWidget);
    expect(find.text('@other'), findsOneWidget);
    expect(find.text('secret phone'), findsNothing);
    expect(find.text('Follow'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('follow is optimistic, guarded, and rolls back on failure', (
    tester,
  ) async {
    final repository = _Repository()..mutation = Completer<void>();
    await _pump(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();
    var content = tester.widget<FieldrushPlayerProfileContent>(
      find.byType(FieldrushPlayerProfileContent),
    );
    expect(content.isFollowing, isTrue);
    expect(content.followBusy, isTrue);
    content.onFollow?.call();
    expect(repository.followCalls, 1);
    repository.mutation!.completeError(StateError('Network unavailable'));
    await tester.pumpAndSettle();
    content = tester.widget<FieldrushPlayerProfileContent>(
      find.byType(FieldrushPlayerProfileContent),
    );
    expect(content.isFollowing, isFalse);
    expect(content.followBusy, isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing follow state loads and successful unfollow persists', (
    tester,
  ) async {
    final repository = _Repository()..following = true;
    await _pump(tester, repository);
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);
    await tester.tap(find.text('Following'));
    await tester.pumpAndSettle();
    expect(repository.unfollowCalls, 1);
    expect(repository.following, isFalse);
    expect(find.text('Follow'), findsOneWidget);
  });

  testWidgets('a stale refresh cannot overwrite a newer confirmed follow', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    await tester.pumpAndSettle();
    repository.load = Completer<PlayerProfile>();
    final refresh = tester
        .widget<FieldRefreshIndicator>(find.byType(FieldRefreshIndicator))
        .onRefresh();
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();
    expect(repository.following, isTrue);
    repository.load!.complete(_profile('other', following: false));
    await refresh;
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);
    await tester.tap(find.text('Following'));
    await tester.pumpAndSettle();
    expect(repository.unfollowCalls, 1);
  });

  testWidgets('button and system back wait for a follow to settle', (
    tester,
  ) async {
    final repository = _Repository()..mutation = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(
                    profileId: 'other',
                    profileRepository: repository,
                  ),
                ),
              ),
              child: const Text('Open profile'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FieldrushPlayerProfileContent>(
            find.byType(FieldrushPlayerProfileContent),
          )
          .onBack,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('@other'), findsOneWidget);
    repository.mutation!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-back')));
    await tester.pumpAndSettle();
    expect(find.text('Open profile'), findsOneWidget);
    expect(find.text('@other'), findsNothing);
  });

  testWidgets(
    'changing player reloads identity and self cannot follow or report',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.pumpAndSettle();
      expect(find.text('@other'), findsOneWidget);
      await _pump(tester, repository, id: 'me');
      await tester.pumpAndSettle();
      expect(find.text('@me'), findsOneWidget);
      expect(find.text('@other'), findsNothing);
      final content = tester.widget<FieldrushPlayerProfileContent>(
        find.byType(FieldrushPlayerProfileContent),
      );
      expect(content.onFollow, isNull);
      expect(content.onReport, isNull);
      expect(find.text('Report player'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed load can retry without exposing another profile', (
    tester,
  ) async {
    final repository = _Repository()..failLoad = true;
    await _pump(tester, repository);
    await tester.pumpAndSettle();
    expect(find.text('Player unavailable'), findsOneWidget);
    expect(find.byType(FieldrushPlayerProfileContent), findsNothing);
    repository.failLoad = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('@other'), findsOneWidget);
    expect(find.text('Player unavailable'), findsNothing);
  });
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  String id = 'other',
}) => tester.pumpWidget(
  MaterialApp(
    home: ProfileScreen(profileId: id, profileRepository: repository),
  ),
);

PlayerProfile _profile(String id, {bool following = false}) => PlayerProfile(
  id: id,
  displayName: '$id P.',
  username: id,
  bio: '',
  phone: 'secret phone',
  followingCount: 0,
  fansCount: 0,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: const [],
  career: const [],
  isFollowedByMe: following,
  playerRating: const ProfilePlayerRating(
    skillRating: 1200,
    matchesPlayed: 0,
    wins: 0,
    losses: 0,
    draws: 0,
    lastChange: 0,
    region: 'phoenix',
    events: [],
  ),
);

class _Repository extends Fake implements ProfileRepository {
  Completer<PlayerProfile>? load;
  Completer<void>? mutation;
  bool following = false, failLoad = false;
  int followCalls = 0, unfollowCalls = 0;

  @override
  String? get currentUserId => 'me';
  @override
  Future<PlayerProfile> getProfile(String id) async {
    if (failLoad) throw StateError('Offline');
    if (load != null) return load!.future;
    return _profile(id, following: following);
  }

  @override
  Future<void> followProfile(String profileId) async {
    followCalls++;
    if (mutation != null) await mutation!.future;
    following = true;
  }

  @override
  Future<void> unfollowProfile(String profileId) async {
    unfollowCalls++;
    if (mutation != null) await mutation!.future;
    following = false;
  }
}
