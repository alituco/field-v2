import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_account_screen.dart';
import 'package:field/src/auth/fieldrush_recovery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late _AccountRepository accounts;
  late _AuthRepository auth;

  setUp(() {
    accounts = _AccountRepository();
    auth = _AuthRepository();
  });

  Future<void> showAccount(
    WidgetTester tester, {
    Size size = const Size(600, 2600),
    bool routed = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final screen = FieldrushAccountScreen(
      authRepository: auth,
      accountRepository: accounts,
    );
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: routed ? const Scaffold(body: Text('SIGNED OUT ROOT')) : screen,
      ),
    );
    if (routed) {
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => screen),
      );
    }
    await tester.pumpAndSettle();
  }

  testWidgets('email verification is explicitly unavailable without delivery', (
    tester,
  ) async {
    await showAccount(tester);
    expect(
      find.textContaining('Email verification is not available yet.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fieldrush-verify-email')), findsNothing);
    expect(find.textContaining('Other players see Alex R.'), findsOneWidget);
    expect(accounts.emailRequests, 0);
  });

  Future<void> submitEmailCode(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('fieldrush-verify-email')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '123456',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Verify email'));
    await tester.pumpAndSettle();
  }

  FieldrushAccount emailSnapshot({
    required bool verified,
    String email = 'alex@example.com',
  }) => FieldrushAccount(
    draft: accounts.account.draft.copyWith(email: email),
    phone: accounts.account.phone,
    phoneVerified: true,
    emailVerified: verified,
    completed: true,
    status: 'active',
  );

  testWidgets(
    'email code acceptance does not claim verification while previous email is pending',
    (tester) async {
      accounts.emailEnabled = true;
      await showAccount(tester);
      await submitEmailCode(tester);
      expect(find.text('Email verified.'), findsNothing);
      expect(
        find.textContaining(
          'also confirm the message sent to your previous email',
        ),
        findsOneWidget,
      );
      expect(find.text('Not verified yet'), findsOneWidget);
      accounts.account = emailSnapshot(verified: true);
      await tester.tap(
        find.byKey(const Key('fieldrush-refresh-email-verification')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Email verified.'), findsOneWidget);
      expect(find.text('Verified email'), findsOneWidget);
    },
  );

  testWidgets(
    'email verification requires the authoritative verified address to match',
    (tester) async {
      accounts.emailEnabled = true;
      accounts.accountAfterEmailVerification = emailSnapshot(
        verified: true,
        email: 'previous@example.com',
      );
      await showAccount(tester);
      await submitEmailCode(tester);
      expect(find.text('Email verified.'), findsNothing);
      expect(
        find.textContaining('Email verification is not complete yet.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'email verification announces success after matching server confirmation',
    (tester) async {
      accounts.emailEnabled = true;
      accounts.accountAfterEmailVerification = emailSnapshot(verified: true);
      await showAccount(tester);
      await submitEmailCode(tester);
      expect(find.text('Email verified.'), findsOneWidget);
      expect(find.text('Verified email'), findsOneWidget);
    },
  );

  testWidgets('failed email status reload shows no fake verification success', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    accounts.loadErrorAfterEmailVerification = const AuthException(
      'Could not confirm email status.',
    );
    await showAccount(tester);
    await submitEmailCode(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Could not confirm email status.'), findsOneWidget);
    expect(find.text('Email verified.'), findsNothing);
  });

  testWidgets('successful signout removes the settings route', (tester) async {
    await showAccount(tester, routed: true);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('SIGNED OUT ROOT'), findsOneWidget);
    expect(find.byType(FieldrushAccountScreen), findsNothing);
  });

  testWidgets('failed signout stays on settings and surfaces the failure', (
    tester,
  ) async {
    auth.signOutError = const AuthException('Could not sign out.');
    await showAccount(tester, routed: true);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushAccountScreen), findsOneWidget);
    expect(find.text('Could not sign out.'), findsOneWidget);
  });

  testWidgets('saves validated private profile details through repository', (
    tester,
  ) async {
    await showAccount(tester);
    await tester.enterText(
      find.byKey(const Key('fieldrush-first-name')),
      'Jordan',
    );
    await tester.enterText(
      find.byKey(const Key('fieldrush-username')),
      'jordan.r',
    );
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    expect(accounts.saved?.firstName, 'Jordan');
    expect(accounts.saved?.username, 'jordan.r');
    expect(find.text('Account details saved.'), findsOneWidget);
    expect(find.textContaining('Other players see Jordan R.'), findsOneWidget);
  });

  testWidgets('rejects under-18 and impossible birthdays without saving', (
    tester,
  ) async {
    accounts.account = FieldrushAccount(
      draft: accounts.account.draft,
      phone: accounts.account.phone,
      phoneVerified: true,
    );
    await showAccount(tester);
    await tester.enterText(
      find.byKey(const Key('fieldrush-birthday')),
      '2025-01-01',
    );
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    expect(find.text('You must be 18 or older.'), findsOneWidget);
    expect(accounts.saved, isNull);
    await tester.enterText(
      find.byKey(const Key('fieldrush-birthday')),
      '2000-02-31',
    );
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid birthday.'), findsOneWidget);
    expect(accounts.saved, isNull);
  });

  testWidgets(
    'completed-account birthday cannot be edited to bypass age checks',
    (tester) async {
      await showAccount(tester);
      final birthday = find.descendant(
        of: find.byKey(const Key('fieldrush-birthday')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(birthday).readOnly, isTrue);
      expect(
        find.textContaining('Contact support for a correction.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Google linking failure does not claim an account is linked', (
    tester,
  ) async {
    accounts.linkError = const AuthException('Google linking was cancelled.');
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-link-google')));
    await tester.pumpAndSettle();
    expect(accounts.linkCalls, 1);
    expect(find.text('Google linking was cancelled.'), findsOneWidget);
    expect(find.text('Google is linked'), findsNothing);
    expect(
      find.text('Finish linking in Google, then return here.'),
      findsNothing,
    );
  });

  testWidgets('phone change keeps current phone when new verification fails', (
    tester,
  ) async {
    accounts.phoneVerificationError = const AuthException(
      'Invalid verification code.',
    );
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-change-phone')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fieldrush-reauth-submit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-reauth-code')),
      '123456',
    );
    await tester.tap(find.byKey(const Key('fieldrush-reauth-submit')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Your current number stays active until the new number is verified.',
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first,
      '6025550101',
    );
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    expect(accounts.signupPhone, '+16025550101');
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .last,
      '123456',
    );
    await tester.tap(find.text('Verify new number'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid verification code.'), findsOneWidget);
    expect(accounts.account.phone, '+14807469696');
    expect(find.text('Phone number verified and updated.'), findsNothing);
  });

  Future<void> confirmDeletion(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('fieldrush-delete-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fieldrush-delete-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fieldrush-reauth-submit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-reauth-code')),
      '123456',
    );
    await tester.tap(find.byKey(const Key('fieldrush-reauth-submit')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'unsettled-account deletion refusal preserves session and shows no success',
    (tester) async {
      accounts.deleteError = const AuthException(
        'Resolve your unsettled bookings before deleting your account.',
      );
      await showAccount(tester);
      await confirmDeletion(tester);
      expect(accounts.reauthSendCalls, 1);
      expect(accounts.reauthVerifyCalls, 1);
      expect(accounts.deleteCalls, 1);
      expect(auth.signOutCalls, 0);
      expect(
        find.textContaining('Resolve your unsettled bookings'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Your account has been deleted.'),
        findsNothing,
      );
    },
  );

  testWidgets('deletion is not attempted when reauthentication fails', (
    tester,
  ) async {
    accounts.reauthError = const AuthException('Invalid verification code.');
    await showAccount(tester);
    await confirmDeletion(tester);
    expect(find.text('Invalid verification code.'), findsOneWidget);
    expect(accounts.deleteCalls, 0);
    expect(auth.signOutCalls, 0);
  });

  testWidgets('deletion signs out only after the server accepts it', (
    tester,
  ) async {
    await showAccount(tester);
    await confirmDeletion(tester);
    expect(accounts.deleteCalls, 1);
    expect(auth.signOutCalls, 1);
    expect(
      find.textContaining('Your account has been deleted.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('fieldrush-delete-account')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('confirmed deletion removes the settings route', (tester) async {
    await showAccount(tester, routed: true);
    await confirmDeletion(tester);
    expect(accounts.deleteCalls, 1);
    expect(find.text('SIGNED OUT ROOT'), findsOneWidget);
    expect(find.byType(FieldrushAccountScreen), findsNothing);
  });

  testWidgets('rejected deletion never navigates away from settings', (
    tester,
  ) async {
    accounts.deleteError = const AuthException(
      'Resolve your unsettled bookings first.',
    );
    await showAccount(tester, routed: true);
    await confirmDeletion(tester);
    expect(find.byType(FieldrushAccountScreen), findsOneWidget);
    expect(
      find.textContaining('Resolve your unsettled bookings'),
      findsOneWidget,
    );
  });

  testWidgets('account screen fits a small phone', (tester) async {
    await showAccount(tester, size: const Size(320, 720));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const Key('fieldrush-delete-account')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovery sends an existing-account code and not a signup code', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: FieldrushRecoveryScreen(
          authRepository: auth,
          accountRepository: accounts,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '4807469696');
    await tester.tap(find.byKey(const Key('fieldrush-recovery-submit')));
    await tester.pumpAndSettle();
    expect(accounts.recoveryPhone, '+14807469696');
    expect(accounts.signupPhone, isNull);
    expect(
      find.textContaining('If this number belongs to an account'),
      findsOneWidget,
    );
  });
}

class _AccountRepository extends Fake implements FieldrushAccountRepository {
  FieldrushAccount account = FieldrushAccount(
    draft: AccountDraft(
      firstName: 'Alex',
      lastName: 'Rivera',
      username: 'alex.r',
      dateOfBirth: DateTime(2000, 1, 2),
      email: 'alex@example.com',
    ),
    phone: '+14807469696',
    phoneVerified: true,
    completed: true,
    status: 'active',
  );
  AccountDraft? saved;
  String? recoveryPhone;
  String? signupPhone;
  Object? linkError;
  Object? deleteError;
  Object? reauthError;
  Object? phoneVerificationError;
  Object? loadErrorAfterEmailVerification;
  bool emailEnabled = false;
  bool emailCodeSubmitted = false;
  FieldrushAccount? accountAfterEmailVerification;
  int emailRequests = 0;
  int linkCalls = 0;
  int reauthSendCalls = 0;
  int reauthVerifyCalls = 0;
  int deleteCalls = 0;

  @override
  bool get emailDeliveryEnabled => emailEnabled;

  @override
  Future<FieldrushAccount> loadAccount() async {
    if (emailCodeSubmitted && loadErrorAfterEmailVerification != null) {
      throw loadErrorAfterEmailVerification!;
    }
    return account;
  }

  @override
  Future<FieldrushAccount> updateAccount(AccountDraft draft) async {
    saved = draft;
    account = FieldrushAccount(
      draft: draft,
      phone: account.phone,
      phoneVerified: account.phoneVerified,
      completed: true,
      status: 'active',
    );
    return account;
  }

  @override
  Future<void> linkGoogle() async {
    linkCalls++;
    if (linkError != null) throw linkError!;
  }

  @override
  Future<void> requestEmailVerification(String email) async {
    emailRequests++;
  }

  @override
  Future<void> verifyEmailCode(String email, String token) async {
    emailCodeSubmitted = true;
    account = accountAfterEmailVerification ?? account;
  }

  @override
  Future<void> sendReauthenticationCode() async {
    reauthSendCalls++;
  }

  @override
  Future<void> verifyReauthenticationCode(String token) async {
    reauthVerifyCalls++;
    if (reauthError != null) throw reauthError!;
  }

  @override
  Future<void> deleteAccount() async {
    deleteCalls++;
    if (deleteError != null) throw deleteError!;
  }

  @override
  Future<void> sendRecoveryCode(String phone) async {
    recoveryPhone = phone;
  }

  @override
  Future<void> sendPhoneCode(String phone) async {
    signupPhone = phone;
  }

  @override
  Future<void> verifyPhoneCode(String phone, String token) async {
    if (phoneVerificationError != null) throw phoneVerificationError!;
  }
}

class _AuthRepository extends Fake implements AuthRepository {
  int signOutCalls = 0;
  Object? signOutError;

  @override
  User? get currentUser => null;

  @override
  Future<void> signOut() async {
    signOutCalls++;
    if (signOutError != null) throw signOutError!;
  }
}
