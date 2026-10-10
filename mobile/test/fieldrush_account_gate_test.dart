import 'dart:async';

import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_account_gate.dart';
import 'package:field/src/auth/fieldrush_auth_screen.dart';
import 'package:field/src/moderation/account_restriction_screen.dart';
import 'package:field/src/moderation/moderation.dart';
import 'package:field/src/moderation/moderation_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late _Auth auth;
  late _Accounts accounts;
  late _Moderation moderation;

  setUp(() {
    auth = _Auth(_session());
    accounts = _Accounts();
    moderation = _Moderation();
  });

  tearDown(() async {
    await auth.events.close();
  });

  Future<void> showGate(WidgetTester tester, {bool settle = true}) async {
    await tester.binding.setSurfaceSize(const Size(430, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: FieldrushAccountGate(
          authRepository: auth,
          accountRepository: accounts,
          moderationRepository: moderation,
          authenticatedAppBuilder: (context, status) =>
              const Scaffold(body: Text('AUTHENTICATED APP')),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('editable auth metadata cannot bypass incomplete onboarding', (
    tester,
  ) async {
    accounts.account = const FieldrushAccount(
      draft: AccountDraft(),
      phone: '+14807469696',
      phoneVerified: true,
    );
    await showGate(tester);
    expect(find.byType(FieldrushAuthScreen), findsOneWidget);
    expect(find.text('What’s your\nname?'), findsOneWidget);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
    expect(moderation.calls, 0);
  });

  testWidgets('completed account still needs verified phone', (tester) async {
    accounts.account = _account(phoneVerified: false);
    await showGate(tester);
    expect(find.text('What’s your\nnumber?'), findsOneWidget);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
    expect(moderation.calls, 0);
  });

  testWidgets('completed verified account with completed tour enters app', (
    tester,
  ) async {
    await showGate(tester);
    expect(find.text('AUTHENTICATED APP'), findsOneWidget);
    expect(moderation.calls, 1);
  });

  testWidgets('completed account opens Home without a welcome tour', (
    tester,
  ) async {
    accounts.account = _account(tourCompleted: false);
    await showGate(tester);
    expect(find.text('You’re in,\nAlex.'), findsNothing);
    expect(accounts.tourCalls, 0);
    expect(find.text('AUTHENTICATED APP'), findsOneWidget);
  });

  testWidgets(
    'initial account load failure stays closed and retry can recover',
    (tester) async {
      accounts.error = const AuthException('Account service unavailable.');
      await showGate(tester);
      expect(find.text('Could not load your account'), findsOneWidget);
      expect(find.text('AUTHENTICATED APP'), findsNothing);
      accounts.error = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('AUTHENTICATED APP'), findsOneWidget);
    },
  );

  testWidgets('moderation failure fails closed rather than assuming active', (
    tester,
  ) async {
    moderation.error = StateError('moderation offline');
    await showGate(tester);
    expect(find.text('Could not load your account'), findsOneWidget);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
  });

  testWidgets('refresh failure removes previously authenticated content', (
    tester,
  ) async {
    await showGate(tester);
    expect(find.text('AUTHENTICATED APP'), findsOneWidget);
    accounts.error = const AuthException('Refresh failed.');
    auth.events.add(
      AuthState(AuthChangeEvent.userUpdated, auth.currentSession),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load your account'), findsOneWidget);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
  });

  testWidgets('pending deletion blocks app and does not run moderation', (
    tester,
  ) async {
    accounts.account = _account(status: 'deletion_pending');
    await showGate(tester);
    expect(find.text('Account deletion in progress'), findsOneWidget);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
    expect(find.byType(FieldrushAuthScreen), findsNothing);
    expect(moderation.calls, 0);
  });

  testWidgets('account restrictions are honored after onboarding', (
    tester,
  ) async {
    moderation.status = const ModerationStatus(
      state: ModerationState.banned,
      scope: ModerationScope.account,
      message: 'Restricted for safety.',
      endsAt: null,
      warningCount: 0,
    );
    await showGate(tester);
    expect(find.byType(RestrictedAccountScreen), findsOneWidget);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
  });

  testWidgets('stale account result cannot reopen app after signout', (
    tester,
  ) async {
    final pending = Completer<FieldrushAccount>();
    accounts.nextLoad = () => pending.future;
    await showGate(tester, settle: false);
    await auth.signOut();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fieldrush-create-account')), findsOneWidget);
    pending.complete(_account());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fieldrush-create-account')), findsOneWidget);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
  });

  testWidgets('stale account error is ignored after signout', (tester) async {
    final pending = Completer<FieldrushAccount>();
    accounts.nextLoad = () => pending.future;
    await showGate(tester, settle: false);
    await auth.signOut();
    await tester.pumpAndSettle();
    pending.completeError(const AuthException('Old session failed.'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fieldrush-create-account')), findsOneWidget);
    expect(find.text('Could not load your account'), findsNothing);
  });
}

Session _session() => Session(
  accessToken: 'local-test-token',
  tokenType: 'bearer',
  user: const User(
    id: 'player-a',
    appMetadata: {},
    userMetadata: {
      'onboarding_completed': true,
      'tour_completed': true,
      'phone_verified': true,
      'date_of_birth': '2000-01-01',
      'display_name': 'Forged Metadata Name',
    },
    aud: 'authenticated',
    createdAt: '2026-10-09T00:00:00Z',
  ),
);

FieldrushAccount _account({
  bool phoneVerified = true,
  bool tourCompleted = true,
  String status = 'active',
}) => FieldrushAccount(
  draft: AccountDraft(
    firstName: 'Alex',
    lastName: 'Rivera',
    username: 'alex.r',
    dateOfBirth: DateTime(2000, 1, 1),
    email: 'alex@example.com',
  ),
  phone: '+14807469696',
  phoneVerified: phoneVerified,
  completed: true,
  tourCompleted: tourCompleted,
  status: status,
);

class _Auth extends Fake implements AuthRepository {
  _Auth(this.session);
  Session? session;
  final events = StreamController<AuthState>.broadcast(sync: true);
  @override
  Session? get currentSession => session;
  @override
  User? get currentUser => session?.user;
  @override
  Stream<AuthState> get authStateChanges => events.stream;
  @override
  Future<void> signOut() async {
    session = null;
    events.add(const AuthState(AuthChangeEvent.signedOut, null));
  }
}

class _Accounts extends Fake implements FieldrushAccountRepository {
  FieldrushAccount account = _account();
  Object? error;
  Future<FieldrushAccount> Function()? nextLoad;
  int tourCalls = 0;
  @override
  bool get emailDeliveryEnabled => false;
  @override
  Future<FieldrushAccount> loadAccount() async {
    if (error != null) throw error!;
    return nextLoad == null ? account : nextLoad!();
  }

  @override
  Future<void> markTourCompleted() async {
    tourCalls++;
    account = _account();
  }

  @override
  Future<UsernameAvailability> checkUsername(String username) async =>
      const UsernameAvailability(available: true);
}

class _Moderation extends Fake implements ModerationRepository {
  int calls = 0;
  Object? error;
  ModerationStatus status = const ModerationStatus.active();
  @override
  Future<ModerationStatus> getMyModerationStatus() async {
    calls++;
    if (error != null) throw error!;
    return status;
  }
}
