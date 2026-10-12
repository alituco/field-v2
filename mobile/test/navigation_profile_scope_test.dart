import 'dart:async';

import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/home/navigation_profile_scope.dart';
import 'package:field/src/profile/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('own avatar is shared by pushed routes and changes immediately', (
    tester,
  ) async {
    final auth = _Auth('player-a');
    addTearDown(auth.events.close);
    final navigator = GlobalKey<NavigatorState>();
    late BuildContext rootContext;
    late BuildContext routeContext;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) =>
            FieldNavigationProfileScope(authRepository: auth, child: child!),
        home: Builder(
          builder: (context) {
            rootContext = context;
            return const Scaffold(body: _AvatarLabel());
          },
        ),
      ),
    );
    FieldNavigationProfileScope.beginRead(
      rootContext,
    )!.complete(_profile('player-a', 'photo-a'));
    await tester.pump();
    expect(find.text('photo-a'), findsOneWidget);

    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) {
          routeContext = context;
          return const Scaffold(body: _AvatarLabel());
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('photo-a'), findsOneWidget);

    final previousRead = FieldNavigationProfileScope.beginRead(rootContext)!;
    FieldNavigationProfileScope.profileChanged(
      routeContext,
      _profile('player-a', 'photo-b'),
    );
    // A Home/You refresh started before the edit must not restore the old photo.
    previousRead.complete(_profile('player-a', 'photo-a'));
    await tester.pump();
    expect(find.text('photo-b'), findsOneWidget);

    FieldNavigationProfileScope.profileChanged(
      routeContext,
      _profile('player-a', '  '),
    );
    await tester.pump();
    expect(find.text('HOME ICON'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('HOME ICON'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visited profiles and old sessions cannot replace own avatar', (
    tester,
  ) async {
    final auth = _Auth('player-a');
    addTearDown(auth.events.close);
    late BuildContext readContext;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FieldNavigationProfileScope(authRepository: auth, child: child!),
        home: Builder(
          builder: (context) {
            readContext = context;
            return const Scaffold(body: _AvatarLabel());
          },
        ),
      ),
    );
    final oldRead = FieldNavigationProfileScope.beginRead(readContext)!;
    oldRead.complete(_profile('player-a', 'photo-a'));
    FieldNavigationProfileScope.profileChanged(
      readContext,
      _profile('someone-else', 'someone-elses-photo'),
    );
    await tester.pump();
    expect(find.text('photo-a'), findsOneWidget);

    auth.useUser('player-b');
    await tester.pump();
    expect(find.text('HOME ICON'), findsOneWidget);
    oldRead.complete(_profile('player-a', 'photo-a'));
    FieldNavigationProfileScope.beginRead(
      readContext,
    )!.complete(_profile('player-b', 'photo-b'));
    await tester.pump();
    expect(find.text('photo-b'), findsOneWidget);

    final secondRead = FieldNavigationProfileScope.beginRead(readContext)!;
    auth.useUser(null);
    auth.useUser('player-b');
    secondRead.complete(_profile('player-b', 'photo-b'));
    await tester.pump();
    expect(find.text('HOME ICON'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    secondRead.complete(_profile('player-b', 'photo-b'));
    expect(tester.takeException(), isNull);
  });
}

class _AvatarLabel extends StatelessWidget {
  const _AvatarLabel();

  @override
  Widget build(BuildContext context) =>
      Text(FieldNavigationProfileScope.avatarUrlOf(context) ?? 'HOME ICON');
}

class _Auth extends Fake implements AuthRepository {
  _Auth(String userId) : session = _session(userId);

  final events = StreamController<AuthState>.broadcast(sync: true);
  Session? session;

  @override
  User? get currentUser => session?.user;

  @override
  Stream<AuthState> get authStateChanges => events.stream;

  void useUser(String? userId) {
    session = userId == null ? null : _session(userId);
    events.add(
      AuthState(
        userId == null ? AuthChangeEvent.signedOut : AuthChangeEvent.signedIn,
        session,
      ),
    );
  }
}

Session _session(String id) => Session(
  accessToken: 'test-token',
  tokenType: 'bearer',
  user: User(
    id: id,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
  ),
);

PlayerProfile _profile(String id, String? avatarUrl) => PlayerProfile(
  id: id,
  displayName: 'Player A.',
  username: id,
  bio: '',
  avatarUrl: avatarUrl,
  followingCount: 0,
  fansCount: 0,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: const [],
  career: const [],
);
