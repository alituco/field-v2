import 'dart:async';

import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_account_gate.dart';
import 'package:field/src/auth/fieldrush_auth_screen.dart';
import 'package:field/src/auth/player_identity.dart';
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

  Future<void> showGate(
    WidgetTester tester, {
    bool settle = true,
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    await tester.binding.setSurfaceSize(const Size(430, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
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

  void backgroundAndResume(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  testWidgets(
    'stored staff identity is signed out before player loading or signup',
    (tester) async {
      auth.session = _session(appMetadata: {'fieldrush_account_type': 'staff'});
      await showGate(tester);
      expect(auth.currentUser, isNull);
      expect(find.text(staffAccountOnlyMessage), findsOneWidget);
      expect(find.byType(FieldrushAuthScreen), findsNothing);
      expect(find.text('AUTHENTICATED APP'), findsNothing);
      expect(accounts.loadCalls, 0);
      expect(accounts.completionCalls, 0);
      expect(accounts.draftSaves, 0);
      expect(moderation.calls, 0);
      await tester.tap(find.text('Use a player account'));
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushAuthScreen), findsOneWidget);
    },
  );

  testWidgets('staff auth event cannot enter an unfinished player signup', (
    tester,
  ) async {
    auth.session = null;
    await showGate(tester);
    auth.signIn(appMetadata: {'fieldrush_account_type': 'staff'});
    await tester.pumpAndSettle();
    expect(auth.currentUser, isNull);
    expect(find.text(staffAccountOnlyMessage), findsOneWidget);
    expect(find.byType(FieldrushAuthScreen), findsNothing);
    expect(accounts.loadCalls, 0);
    expect(accounts.completionCalls, 0);
    expect(moderation.calls, 0);
  });

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
    'phone login keeps its skeleton through delayed account and moderation reads',
    (tester) async {
      auth.session = null;
      accounts.onVerified = () => auth.signIn();
      final pendingAccount = Completer<FieldrushAccount>();
      final pendingModeration = Completer<ModerationStatus>();
      accounts.nextLoad = () => pendingAccount.future;
      moderation.nextLoad = () => pendingModeration.future;
      await showGate(tester);
      await logInWithPhone(tester);
      await verifyLoginCode(tester);

      for (var second = 0; second < 3; second++) {
        await tester.pump(const Duration(seconds: 1));
        expect(find.byKey(const Key('fieldrush-signing-in')), findsOneWidget);
        expect(find.textContaining('Your number was verified'), findsNothing);
        expect(find.byKey(const Key('fieldrush-code')), findsNothing);
        expect(find.text('AUTHENTICATED APP'), findsNothing);
      }
      expect(accounts.loadCalls, 2);
      expect(moderation.calls, 0);

      pendingAccount.complete(accounts.account);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const Key('fieldrush-signing-in')), findsOneWidget);
      expect(find.textContaining('Your number was verified'), findsNothing);
      expect(find.text('AUTHENTICATED APP'), findsNothing);

      pendingModeration.complete(const ModerationStatus.active());
      await tester.pumpAndSettle();
      expect(find.text('AUTHENTICATED APP'), findsOneWidget);
      expect(find.byType(FieldrushAuthScreen), findsNothing);
      expect(accounts.verifiedCodes, ['123456']);
      expect(accounts.completionCalls, 0);
      expect(accounts.draftSaves, 0);
      expect(tester.takeException(), isNull);
    },
  );

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

  for (final trigger in [
    'signout',
    'another player',
    'account restriction',
    'pending deletion',
    'unverified phone',
    'revoked session',
    'auth stream revoked session',
  ]) {
    testWidgets('$trigger clears private pages and dialogs above the gate', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await showGate(tester, navigatorKey: navigator);
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('PRIVATE PLAYER A')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(
        showDialog<void>(
          context: tester.element(find.text('PRIVATE PLAYER A')),
          builder: (_) => const PopScope(
            canPop: false,
            child: AlertDialog(content: Text('PRIVATE CONFIRMATION')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PRIVATE CONFIRMATION'), findsOneWidget);

      switch (trigger) {
        case 'signout':
          await auth.signOut();
        case 'another player':
          auth.signIn(userId: 'player-b');
        case 'auth stream revoked session':
          auth.events.addError(
            const AuthException('Session unavailable.', statusCode: '401'),
          );
        default:
          if (trigger == 'account restriction') {
            moderation.status = const ModerationStatus(
              state: ModerationState.banned,
              scope: ModerationScope.account,
              message: 'Restricted for safety.',
              endsAt: null,
              warningCount: 0,
            );
          } else if (trigger == 'pending deletion') {
            accounts.account = _account(status: 'deletion_pending');
          } else if (trigger == 'unverified phone') {
            accounts.account = _account(phoneVerified: false);
          } else {
            accounts.error = const AuthException(
              'Session revoked.',
              statusCode: '401',
            );
          }
          auth.events.add(
            AuthState(AuthChangeEvent.userUpdated, auth.currentSession),
          );
      }
      await tester.pumpAndSettle();

      expect(find.text('PRIVATE PLAYER A', skipOffstage: false), findsNothing);
      expect(
        find.text('PRIVATE CONFIRMATION', skipOffstage: false),
        findsNothing,
      );
      expect(navigator.currentState!.canPop(), isFalse);
      switch (trigger) {
        case 'signout':
        case 'unverified phone':
          expect(find.byType(FieldrushAuthScreen), findsOneWidget);
        case 'another player':
          expect(
            find.byKey(const ValueKey<String>('player-b')),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey<String>('player-a')), findsNothing);
        case 'account restriction':
          expect(find.byType(RestrictedAccountScreen), findsOneWidget);
        case 'pending deletion':
          expect(find.text('Account deletion in progress'), findsOneWidget);
        default:
          expect(find.text('Could not load your account'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('same-player refresh preserves the private route stack', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await showGate(tester, navigatorKey: navigator);
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('PRIVATE PLAYER A')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final privateElement = tester.element(find.text('PRIVATE PLAYER A'));

    for (final event in [
      AuthChangeEvent.tokenRefreshed,
      AuthChangeEvent.userUpdated,
      AuthChangeEvent.signedIn,
    ]) {
      auth.events.add(AuthState(event, auth.currentSession));
      await tester.pumpAndSettle();
      expect(
        tester.element(find.text('PRIVATE PLAYER A')),
        same(privateElement),
      );
      expect(navigator.currentState!.canPop(), isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  for (final failure in ['account read', 'moderation read', 'auth stream']) {
    testWidgets('$failure failure retains a pushed draft and retry recovers', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await showGate(tester, navigatorKey: navigator);
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) =>
                const Scaffold(body: TextField(key: Key('private-draft'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final draft = find.byKey(const Key('private-draft'));
      await tester.enterText(draft, 'Keep my booking position');
      final element = tester.element(draft);
      if (failure == 'auth stream') {
        auth.events.addError(
          AuthRetryableFetchException(message: 'Network interrupted.'),
        );
      } else {
        if (failure == 'account read') {
          accounts.error = StateError('Account offline');
        } else {
          moderation.error = StateError('Moderation offline');
        }
        backgroundAndResume(tester);
      }
      await tester.pumpAndSettle();
      expect(tester.element(draft), same(element));
      expect(find.text('Keep my booking position'), findsOneWidget);
      expect(navigator.currentState!.canPop(), isTrue);
      expect(find.text('Could not load your account'), findsNothing);
      expect(
        find.byKey(const Key('fieldrush-account-refresh-banner')),
        findsOneWidget,
      );
      accounts.error = null;
      moderation.error = null;
      await tester.tap(find.text('Retry').last);
      await tester.pumpAndSettle();
      expect(tester.element(draft), same(element));
      expect(
        find.byKey(const Key('fieldrush-account-refresh-banner')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a stalled foreground refresh times out without closing a dialog',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await showGate(tester, navigatorKey: navigator);
      unawaited(
        showDialog<void>(
          context: tester.element(find.text('AUTHENTICATED APP')),
          builder: (_) =>
              const AlertDialog(content: Text('BOOKING CONFIRMATION')),
        ),
      );
      await tester.pumpAndSettle();
      final pending = Completer<FieldrushAccount>();
      accounts.nextLoad = () => pending.future;
      backgroundAndResume(tester);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('BOOKING CONFIRMATION'), findsOneWidget);
      expect(navigator.currentState!.canPop(), isTrue);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('fieldrush-account-refresh-banner')),
        findsOneWidget,
      );
      accounts.nextLoad = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      pending.complete(_account(status: 'deletion_pending'));
      await tester.pumpAndSettle();
      expect(find.text('Account deletion in progress'), findsNothing);
      expect(find.text('AUTHENTICATED APP'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'signout clears a retry banner after a transient refresh failure',
    (tester) async {
      await showGate(tester);
      accounts.error = StateError('Offline');
      auth.events.add(
        AuthState(AuthChangeEvent.userUpdated, auth.currentSession),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('fieldrush-account-refresh-banner')),
        findsOneWidget,
      );
      await auth.signOut();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('fieldrush-account-refresh-banner')),
        findsNothing,
      );
      expect(find.byType(FieldrushAuthScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a late account response cannot reopen a revoked session', (
    tester,
  ) async {
    await showGate(tester);
    final pending = Completer<FieldrushAccount>();
    accounts.nextLoad = () => pending.future;
    auth.events.add(
      AuthState(AuthChangeEvent.userUpdated, auth.currentSession),
    );
    await tester.pump();
    auth.events.addError(
      const AuthException('Session revoked.', statusCode: '401'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load your account'), findsOneWidget);
    pending.complete(_account());
    await tester.pumpAndSettle();
    expect(find.text('Could not load your account'), findsOneWidget);
    expect(find.text('AUTHENTICATED APP'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'retry applies an authoritative restriction after an offline error',
    (tester) async {
      await showGate(tester);
      accounts.error = StateError('Offline');
      auth.events.add(
        AuthState(AuthChangeEvent.userUpdated, auth.currentSession),
      );
      await tester.pumpAndSettle();
      accounts.error = null;
      moderation.status = const ModerationStatus(
        state: ModerationState.banned,
        scope: ModerationScope.account,
        message: 'Restricted for safety.',
        endsAt: null,
        warningCount: 0,
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(RestrictedAccountScreen), findsOneWidget);
      expect(find.text('AUTHENTICATED APP'), findsNothing);
      expect(
        find.byKey(const Key('fieldrush-account-refresh-banner')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('signout clears a restricted account support sheet', (
    tester,
  ) async {
    moderation.status = const ModerationStatus(
      state: ModerationState.banned,
      scope: ModerationScope.account,
      message: 'Restricted for safety.',
      endsAt: null,
      warningCount: 0,
    );
    final navigator = GlobalKey<NavigatorState>();
    await showGate(tester, navigatorKey: navigator);
    await tester.tap(
      find.byKey(const Key('restricted-account-contact-support')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('restricted-account-support-sheet')),
      findsOneWidget,
    );

    await auth.signOut();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('restricted-account-support-sheet')),
      findsNothing,
    );
    expect(find.byType(FieldrushAuthScreen), findsOneWidget);
    expect(navigator.currentState!.canPop(), isFalse);
    expect(tester.takeException(), isNull);
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

  testWidgets('refresh failure preserves previously authenticated content', (
    tester,
  ) async {
    await showGate(tester);
    expect(find.text('AUTHENTICATED APP'), findsOneWidget);
    accounts.error = const AuthException('Refresh failed.');
    auth.events.add(
      AuthState(AuthChangeEvent.userUpdated, auth.currentSession),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load your account'), findsNothing);
    expect(find.text('AUTHENTICATED APP'), findsOneWidget);
    expect(
      find.byKey(const Key('fieldrush-account-refresh-banner')),
      findsOneWidget,
    );
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

Session _session({
  String userId = 'player-a',
  Map<String, dynamic> appMetadata = const {},
}) => Session(
  accessToken: 'local-test-token',
  tokenType: 'bearer',
  user: User(
    id: userId,
    appMetadata: appMetadata,
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
  void signIn({
    String userId = 'player-a',
    Map<String, dynamic> appMetadata = const {},
  }) {
    session = _session(userId: userId, appMetadata: appMetadata);
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
  int loadCalls = 0;
  @override
  bool get emailDeliveryEnabled => false;
  @override
  Future<FieldrushAccount> loadAccount() async {
    loadCalls++;
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
