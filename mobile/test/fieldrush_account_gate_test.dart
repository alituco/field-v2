import 'dart:async';

import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_account_gate.dart';
import 'package:field/src/auth/fieldrush_auth_screen.dart';
import 'package:field/src/moderation/account_restriction_screen.dart';
import 'package:field/src/moderation/moderation.dart';
import 'package:field/src/moderation/moderation_repository.dart';
import 'package:field/src/ui/field_loading.dart';
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

  Future<void> logInWithPhone(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('fieldrush-log-in')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-phone')),
      '4807469696',
    );
    await tester.ensureVisible(find.byKey(const Key('fieldrush-continue')));
    await tester.tap(find.byKey(const Key('fieldrush-continue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fieldrush-code')), findsOneWidget);
  }

  Future<void> verifyLoginCode(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
    await tester.ensureVisible(find.byKey(const Key('fieldrush-continue')));
    await tester.tap(find.byKey(const Key('fieldrush-continue')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
  }

  testWidgets('unknown phone entered through Log in starts signup after OTP', (
    tester,
  ) async {
    auth.session = null;
    accounts.account = const FieldrushAccount(
      draft: AccountDraft(),
      phone: '+14807469696',
      phoneVerified: true,
    );
    accounts.onVerified = () => auth.signIn();
    await showGate(tester);
    await logInWithPhone(tester);
    expect(accounts.sentPhones, ['+14807469696']);
    expect(accounts.recoveryPhones, isEmpty);
    expect(auth.currentUser, isNull);
    expect(find.text('AUTHENTICATED APP'), findsNothing);

    await verifyLoginCode(tester);
    await tester.pumpAndSettle();
    expect(accounts.verifiedCodes, ['123456']);
    expect(auth.currentUser, isNotNull);
    expect(find.text('What’s your\nname?'), findsOneWidget);
    expect(find.text('Look\nright?'), findsNothing);
    expect(find.byKey(const Key('fieldrush-accept-policies')), findsNothing);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
    expect(accounts.completionCalls, 0);
    expect(accounts.draftSaves, 0);
    expect(moderation.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'returning phone login waits for moderation without signup review',
    (tester) async {
      auth.session = null;
      accounts.onVerified = () => auth.signIn();
      final pending = Completer<ModerationStatus>();
      moderation.nextLoad = () => pending.future;
      await showGate(tester);
      await logInWithPhone(tester);
      await verifyLoginCode(tester);
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Look\nright?'), findsNothing);
        expect(
          find.byKey(const Key('fieldrush-accept-policies')),
          findsNothing,
        );
        expect(find.text('AUTHENTICATED APP'), findsNothing);
        expect(
          tester
              .widget<FieldLoadingContent>(find.byType(FieldLoadingContent))
              .label,
          'Signing you in',
        );
      }
      expect(moderation.calls, greaterThanOrEqualTo(1));
      expect(accounts.completionCalls, 0);
      expect(accounts.draftSaves, 0);

      pending.complete(const ModerationStatus.active());
      await tester.pumpAndSettle();
      expect(find.text('AUTHENTICATED APP'), findsOneWidget);
      expect(find.byType(FieldrushAuthScreen), findsNothing);
      expect(find.text('Look\nright?'), findsNothing);
      expect(accounts.verifiedCodes, ['123456']);
      expect(accounts.completionCalls, 0);
      expect(accounts.tourCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning phone login still honors a delayed account restriction',
    (tester) async {
      auth.session = null;
      accounts.onVerified = () => auth.signIn();
      final pending = Completer<ModerationStatus>();
      moderation.nextLoad = () => pending.future;
      await showGate(tester);
      await logInWithPhone(tester);
      await verifyLoginCode(tester);
      expect(find.text('Look\nright?'), findsNothing);
      expect(find.text('AUTHENTICATED APP'), findsNothing);

      pending.complete(
        const ModerationStatus(
          state: ModerationState.banned,
          scope: ModerationScope.account,
          message: 'Restricted for safety.',
          endsAt: null,
          warningCount: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RestrictedAccountScreen), findsOneWidget);
      expect(find.text('AUTHENTICATED APP'), findsNothing);
      expect(find.text('Look\nright?'), findsNothing);
      expect(accounts.completionCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning phone login fails closed when moderation cannot load',
    (tester) async {
      auth.session = null;
      accounts.onVerified = () => auth.signIn();
      final pending = Completer<ModerationStatus>();
      moderation.nextLoad = () => pending.future;
      await showGate(tester);
      await logInWithPhone(tester);
      await verifyLoginCode(tester);
      expect(find.text('Look\nright?'), findsNothing);

      pending.completeError(StateError('moderation offline'));
      await tester.pumpAndSettle();
      expect(find.text('Could not load your account'), findsOneWidget);
      expect(find.text('AUTHENTICATED APP'), findsNothing);
      expect(find.text('Look\nright?'), findsNothing);
      expect(accounts.completionCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('account loading uses a skeleton and then enters the real app', (
    tester,
  ) async {
    final pending = Completer<FieldrushAccount>();
    accounts.nextLoad = () => pending.future;
    await showGate(tester, settle: false);
    expect(find.byType(FieldLoadingContent), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
    pending.complete(accounts.account);
    await tester.pumpAndSettle();
    expect(find.byType(FieldLoadingContent), findsNothing);
    expect(find.text('AUTHENTICATED APP'), findsOneWidget);
  });

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

  testWidgets('switching accounts remounts the authenticated user subtree', (
    tester,
  ) async {
    await showGate(tester);
    final firstUser = find.byKey(const ValueKey<String>('player-a'));
    expect(firstUser, findsOneWidget);
    final firstElement = tester.element(firstUser);

    auth.session = _session(userId: 'player-b');
    auth.events.add(AuthState(AuthChangeEvent.signedIn, auth.currentSession));
    await tester.pumpAndSettle();

    final nextUser = find.byKey(const ValueKey<String>('player-b'));
    expect(firstUser, findsNothing);
    expect(nextUser, findsOneWidget);
    expect(tester.element(nextUser), isNot(same(firstElement)));
    expect(find.text('AUTHENTICATED APP'), findsOneWidget);
    expect(moderation.calls, 2);
  });

  testWidgets(
    'intentional incomplete signup switch preserves the new-number OTP screen',
    (tester) async {
      accounts.account = const FieldrushAccount(
        draft: AccountDraft(firstName: 'Original draft'),
        phone: '+14807469696',
        phoneVerified: true,
      );
      final smsRequested = Completer<void>();
      accounts.onSwitch = () async {
        await auth.signOut();
        await smsRequested.future;
      };
      await showGate(tester);
      final oldScreen = tester.element(find.byType(FieldrushAuthScreen));
      await tester.tap(find.byKey(const Key('fieldrush-back')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('fieldrush-phone')),
        '6025550101',
      );
      await tester.ensureVisible(find.byKey(const Key('fieldrush-continue')));
      await tester.tap(find.byKey(const Key('fieldrush-continue')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('fieldrush-confirm-phone-account-switch')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(auth.currentUser, isNull);
      expect(tester.element(find.byType(FieldrushAuthScreen)), same(oldScreen));
      expect(find.byKey(const Key('fieldrush-create-account')), findsNothing);
      smsRequested.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fieldrush-code')), findsOneWidget);
      expect(accounts.sentPhones, ['+16025550101']);
      expect(tester.element(find.byType(FieldrushAuthScreen)), same(oldScreen));

      accounts.account = const FieldrushAccount(
        draft: AccountDraft(),
        phone: '+16025550101',
        phoneVerified: true,
      );
      accounts.onVerified = () => auth.signIn(userId: 'player-b');
      await verifyLoginCode(tester);
      await tester.pumpAndSettle();
      expect(auth.currentUser?.id, 'player-b');
      expect(find.text('What’s your\nname?'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('fieldrush-first-name')))
            .controller!
            .text,
        isEmpty,
      );
      expect(accounts.draftSaves, 0);
      expect(accounts.completionCalls, 0);
      expect(find.text('AUTHENTICATED APP'), findsNothing);
    },
  );

  testWidgets(
    'external sign-in during signup switch remounts before old draft can survive',
    (tester) async {
      accounts.account = const FieldrushAccount(
        draft: AccountDraft(firstName: 'Original private draft'),
        phone: '+14807469696',
        phoneVerified: true,
      );
      final pendingSms = Completer<void>();
      accounts.onSwitch = () async {
        await auth.signOut();
        await pendingSms.future;
        throw const AuthException('The account changed. Start again.');
      };
      await showGate(tester);
      final oldScreen = tester.element(find.byType(FieldrushAuthScreen));
      await tester.tap(find.byKey(const Key('fieldrush-back')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('fieldrush-phone')),
        '6025550101',
      );
      await tester.ensureVisible(find.byKey(const Key('fieldrush-continue')));
      await tester.tap(find.byKey(const Key('fieldrush-continue')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('fieldrush-confirm-phone-account-switch')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(auth.currentUser, isNull);
      expect(tester.element(find.byType(FieldrushAuthScreen)), same(oldScreen));

      accounts.account = const FieldrushAccount(
        draft: AccountDraft(firstName: 'New owner'),
        phone: '+16025550199',
        phoneVerified: true,
      );
      auth.signIn(userId: 'external-user');
      await tester.pumpAndSettle();
      expect(
        tester.element(find.byType(FieldrushAuthScreen)),
        isNot(same(oldScreen)),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('fieldrush-first-name')))
            .controller!
            .text,
        'New owner',
      );
      pendingSms.complete();
      await tester.pumpAndSettle();
      expect(auth.currentUser?.id, 'external-user');
      expect(find.byKey(const Key('fieldrush-code')), findsNothing);
      expect(find.text('The account changed. Start again.'), findsNothing);
      expect(accounts.sentPhones, isEmpty);
      expect(accounts.draftSaves, 0);
      expect(accounts.completionCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

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

Session _session({String userId = 'player-a'}) => Session(
  accessToken: 'local-test-token',
  tokenType: 'bearer',
  user: User(
    id: userId,
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
  void signIn({String userId = 'player-a'}) {
    session = _session(userId: userId);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
  }

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
  VoidCallback? onVerified;
  Future<void> Function()? onSwitch;
  final sentPhones = <String>[];
  final recoveryPhones = <String>[];
  final verifiedCodes = <String>[];
  int completionCalls = 0;
  int draftSaves = 0;
  int tourCalls = 0;
  @override
  bool get emailDeliveryEnabled => false;
  @override
  Future<FieldrushAccount> loadAccount() async {
    if (error != null) throw error!;
    return nextLoad == null ? account : nextLoad!();
  }

  @override
  Future<void> sendPhoneCode(String phone) async {
    sentPhones.add(phone);
  }

  @override
  Future<void> switchIncompletePhoneAccount(String phone) async {
    await onSwitch?.call();
    sentPhones.add(phone);
  }

  @override
  Future<void> sendRecoveryCode(String phone) async {
    recoveryPhones.add(phone);
  }

  @override
  Future<void> verifyPhoneCode(String phone, String token) async {
    verifiedCodes.add(token);
    onVerified?.call();
  }

  @override
  Future<void> saveDraft(AccountDraft draft) async {
    draftSaves++;
  }

  @override
  Future<FieldrushAccount> completeOnboarding(AccountDraft draft) async {
    completionCalls++;
    return account;
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
  Future<ModerationStatus> Function()? nextLoad;
  @override
  Future<ModerationStatus> getMyModerationStatus() async {
    calls++;
    if (error != null) throw error!;
    return nextLoad == null ? status : nextLoad!();
  }
}
