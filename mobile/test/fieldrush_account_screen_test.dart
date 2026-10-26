import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_account_screen.dart';
import 'package:field/src/auth/fieldrush_recovery_screen.dart';
import 'package:field/src/home/navigation_profile_scope.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

void main() {
  late _AccountRepository accounts;
  late _AuthRepository auth;
  late _ProfileRepository profiles;
  late _ImagePicker picker;

  setUp(() {
    accounts = _AccountRepository();
    auth = _AuthRepository();
    profiles = _ProfileRepository();
    picker = _ImagePicker();
  });

  Future<void> showAccount(
    WidgetTester tester, {
    Size size = const Size(600, 2600),
    bool routed = false,
    bool withNavigationAvatar = false,
    double keyboardInset = 0,
    Widget? bottomNavigationBar,
    Widget Function(Future<bool> Function() confirmLeave)?
    bottomNavigationBuilder,
    GlobalKey? boundaryKey,
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final screen = FieldrushAccountScreen(
      authRepository: auth,
      accountRepository: accounts,
      profileRepository: profiles,
      imagePicker: picker,
      bottomNavigationBar: bottomNavigationBar,
      bottomNavigationBuilder: bottomNavigationBuilder,
    );
    final navigatorKey = GlobalKey<NavigatorState>();
    if (withNavigationAvatar) {
      auth.navigationUser = User(
        id: 'player-1',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00Z',
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => RepaintBoundary(
          key: boundaryKey,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewInsets: EdgeInsets.only(bottom: keyboardInset),
              textScaler: TextScaler.linear(textScale),
            ),
            child: withNavigationAvatar
                ? FieldNavigationProfileScope(
                    authRepository: auth,
                    child: child!,
                  )
                : child!,
          ),
        ),
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

  testWidgets(
    'disabled delivery keeps contact email without a dead-end prompt',
    (tester) async {
      await showAccount(tester);
      expect(
        find.textContaining('Contact email. Sign in with your phone'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('fieldrush-verify-email')), findsNothing);
      expect(find.text('Shown on ladders as Alex R.'), findsOneWidget);
      expect(accounts.emailRequests, 0);
    },
  );

  Future<void> submitEmailCode(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('fieldrush-verify-email')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(FieldrushModal),
        matching: find.byType(TextField),
      ),
      '123456',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Verify email'));
    await tester.pumpAndSettle();
  }

  FieldrushAccount googleSnapshot({bool phoneVerified = true}) =>
      FieldrushAccount(
        draft: accounts.account.draft,
        phone: accounts.account.phone,
        phoneVerified: phoneVerified,
        emailVerified: true,
        googleLinked: true,
        completed: true,
        status: 'active',
      );

  Future<void> editEmail(WidgetTester tester, String email) async {
    await tester.tap(find.byKey(const Key('fieldrush-edit-email')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('fieldrush-email')), email);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
  }

  void returnFromInbox(WidgetTester tester) {
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

  testWidgets('unverified email has explicit Verify and Edit buttons', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    await showAccount(tester);
    expect(find.byKey(const Key('fieldrush-verify-email')), findsOneWidget);
    await tester.tap(find.byKey(const Key('fieldrush-edit-email-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fieldrush-email')), findsOneWidget);
    expect(accounts.emailRequests, 0);
  });

  testWidgets('changing Google email warns before any account update', (
    tester,
  ) async {
    accounts.account = googleSnapshot();
    await showAccount(tester);
    await editEmail(tester, 'new@example.com');
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(find.text('Disconnect Google?'), findsOneWidget);
    expect(find.textContaining('verified phone number'), findsOneWidget);
    expect(accounts.updateCalls, 0);
    await tester.tap(
      find.byKey(const Key('fieldrush-cancel-google-email-change')),
    );
    await tester.pumpAndSettle();
    expect(accounts.updateCalls, 0);
    expect(accounts.saved, isNull);
    expect(accounts.account.googleLinked, isTrue);
  });

  testWidgets('confirmed email change explicitly disconnects Google', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    accounts.account = googleSnapshot();
    await showAccount(tester);
    await editEmail(tester, 'new@example.com');
    await tester.tap(
      find.byKey(const Key('fieldrush-confirm-google-email-change')),
    );
    await tester.pumpAndSettle();
    expect(accounts.updateCalls, 1);
    expect(accounts.disconnectGoogleRequested, isTrue);
    expect(accounts.saved!.email, 'new@example.com');
    expect(accounts.account.googleLinked, isFalse);
    expect(accounts.account.emailVerified, isFalse);
    expect(
      find.text(
        'Email updated and Google disconnected. Verify your new email.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fieldrush-verify-email')), findsOneWidget);
  });

  testWidgets('Google email change requires verified phone fallback', (
    tester,
  ) async {
    accounts.account = googleSnapshot(phoneVerified: false);
    await showAccount(tester);
    await editEmail(tester, 'new@example.com');
    expect(accounts.updateCalls, 0);
    expect(find.byType(FieldrushModal), findsNothing);
    expect(
      find.textContaining('Verify your phone number before changing an email'),
      findsOneWidget,
    );
  });

  testWidgets('same Google email with different case does not disconnect', (
    tester,
  ) async {
    accounts.account = googleSnapshot();
    await showAccount(tester);
    await editEmail(tester, 'ALEX@EXAMPLE.COM');
    expect(find.byType(FieldrushModal), findsNothing);
    expect(accounts.updateCalls, 1);
    expect(accounts.disconnectGoogleRequested, isFalse);
    expect(accounts.account.googleLinked, isTrue);
  });

  testWidgets('editing another field keeps Google linked without a warning', (
    tester,
  ) async {
    accounts.account = googleSnapshot();
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-edit-name')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-first-name')),
      'Alexis',
    );
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsNothing);
    expect(accounts.disconnectGoogleRequested, isFalse);
    expect(accounts.account.googleLinked, isTrue);
  });

  testWidgets('Google callback after resume updates the contact email', (
    tester,
  ) async {
    auth.changes = StreamController<AuthState>();
    addTearDown(() => auth.changes!.close());
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-security-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fieldrush-link-google')));
    await tester.pumpAndSettle();
    // Resuming can precede the OAuth callback. Keep listening until linked.
    returnFromInbox(tester);
    await tester.pumpAndSettle();
    expect(find.text('Refresh linked accounts'), findsOneWidget);
    accounts.account = FieldrushAccount(
      draft: accounts.account.draft.copyWith(email: 'google@example.com'),
      phone: accounts.account.phone,
      phoneVerified: true,
      googleLinked: true,
      googleEmail: 'google@example.com',
      emailVerified: true,
      completed: true,
      status: 'active',
    );
    auth.changes!.add(AuthState(AuthChangeEvent.userUpdated, null));
    await tester.pumpAndSettle();
    expect(find.text('google@example.com'), findsOneWidget);
    expect(find.text('Refresh linked accounts'), findsNothing);
    expect(find.text('VERIFIED'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('fieldrush-edit-email')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('fieldrush-email')))
          .controller!
          .text,
      'google@example.com',
    );
  });

  testWidgets('stale Google link refreshes before consent is requested', (
    tester,
  ) async {
    await showAccount(tester);
    accounts.account = googleSnapshot();
    accounts.saveError = const GoogleEmailChangeConfirmationRequiredException();
    await editEmail(tester, 'new@example.com');
    expect(accounts.disconnectGoogleRequested, isFalse);
    expect(find.textContaining('Google is now linked'), findsOneWidget);
    accounts.saveError = null;
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect Google?'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('fieldrush-cancel-google-email-change')),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('partial Google disconnect failure never claims email saved', (
    tester,
  ) async {
    accounts.account = googleSnapshot();
    await showAccount(tester);
    accounts.saveError = const GoogleDisconnectedEmailUpdateException();
    await editEmail(tester, 'new@example.com');
    await tester.tap(
      find.byKey(const Key('fieldrush-confirm-google-email-change')),
    );
    await tester.pumpAndSettle();
    expect(accounts.saved, isNull);
    expect(find.textContaining('Google was disconnected, but'), findsOneWidget);
    expect(find.text('Account details saved.'), findsNothing);
    expect(
      find.text(
        'Email updated and Google disconnected. Verify your new email.',
      ),
      findsNothing,
    );
  });

  testWidgets('uncertain unlink status never claims success or saved email', (
    tester,
  ) async {
    accounts.account = googleSnapshot();
    accounts.saveError = const GoogleEmailChangeStatusUnavailableException();
    await showAccount(tester);
    await editEmail(tester, 'new@example.com');
    await tester.tap(
      find.byKey(const Key('fieldrush-confirm-google-email-change')),
    );
    await tester.pumpAndSettle();
    expect(accounts.saved, isNull);
    expect(
      find.textContaining('could not confirm whether Google was disconnected'),
      findsOneWidget,
    );
    expect(find.text('Account details saved.'), findsNothing);
  });

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
    'email code acceptance still requires authoritative verification without old-inbox instructions',
    (tester) async {
      accounts.emailEnabled = true;
      await showAccount(tester);
      await submitEmailCode(tester);
      expect(find.text('Email verified.'), findsNothing);
      expect(
        find.textContaining('Use the code sent to your new email'),
        findsOneWidget,
      );
      expect(find.text('UNVERIFIED'), findsOneWidget);
      expect(find.textContaining('previous email'), findsNothing);
      expect(find.textContaining('both inboxes'), findsNothing);
      accounts.account = emailSnapshot(verified: true);
      await tester.tap(
        find.byKey(const Key('fieldrush-refresh-email-verification')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Email verified.'), findsOneWidget);
      expect(find.text('VERIFIED'), findsNWidgets(2));
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
      expect(find.text('VERIFIED'), findsNWidgets(2));
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
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(find.text('Could not confirm email status.'), findsOneWidget);
    expect(find.text('Email verified.'), findsNothing);
    expect(accounts.emailVerifyCalls, 1);
    accounts.loadErrorAfterEmailVerification = null;
    accounts.account = emailSnapshot(verified: true);
    await tester.tap(
      find.widgetWithText(FilledButton, 'Check verification status'),
    );
    await tester.pumpAndSettle();
    expect(accounts.emailVerifyCalls, 1);
    expect(find.text('Email verified.'), findsOneWidget);
  });

  testWidgets('email sheet is themed and accepts exactly six numeric digits', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-verify-email')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(FieldrushModal), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('fieldrush-email-verification-code'));
    await tester.enterText(input, 'abc12345');
    await tester.tap(find.widgetWithText(FilledButton, 'Verify email'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the 6-digit code.'), findsOneWidget);
    expect(accounts.emailVerifyCalls, 0);
    await tester.enterText(input, '12345678');
    expect(tester.widget<TextField>(input).controller!.text, '123456');
    expect(
      tester.widget<TextField>(input).autofillHints,
      contains(AutofillHints.oneTimeCode),
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('email resend waits a minute and restarts its cooldown', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-verify-email')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    final resend = find.byKey(const Key('fieldrush-resend-email-code'));
    expect(tester.widget<TextButton>(resend).onPressed, isNull);
    expect(accounts.emailRequests, 1);
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(find.text('Resend code'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('fieldrush-email-verification-code')),
      '123456',
    );
    await tester.tap(resend);
    await tester.pumpAndSettle();
    expect(accounts.emailRequests, 2);
    expect(tester.widget<TextButton>(resend).onPressed, isNull);
    expect(
      find.text('New code sent. Use the most recent email.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('fieldrush-email-verification-code')),
          )
          .controller!
          .text,
      isEmpty,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed send can retry without claiming a code was sent', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    accounts.emailRequestError = const AuthException('Could not send email.');
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-verify-email')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    expect(find.text('Could not send email.'), findsOneWidget);
    expect(
      find.byKey(const Key('fieldrush-email-verification-code')),
      findsNothing,
    );
    accounts.emailRequestError = null;
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    expect(accounts.emailRequests, 2);
    expect(
      find.byKey(const Key('fieldrush-email-verification-code')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'wrong or expired email code stays unverified with a useful error',
    (tester) async {
      accounts.emailEnabled = true;
      accounts.emailVerificationError = const AuthException(
        'Token has expired or is invalid',
        code: 'otp_expired',
      );
      await showAccount(tester);
      await submitEmailCode(tester);
      expect(
        find.textContaining('That code is invalid or has expired.'),
        findsOneWidget,
      );
      expect(find.byType(FieldrushModal), findsOneWidget);
      expect(find.text('Email verified.'), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('email sending blocks duplicate submits and cancellation', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    accounts.emailSendResponse = Completer<void>();
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-verify-email')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pump();
    expect(accounts.emailRequests, 1);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Sending code…'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Cancel'))
          .onPressed,
      isNull,
    );
    accounts.emailSendResponse!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('verified email matching is case insensitive', (tester) async {
    accounts.emailEnabled = true;
    accounts.accountAfterEmailVerification = emailSnapshot(
      verified: true,
      email: 'ALEX@EXAMPLE.COM',
    );
    await showAccount(tester);
    await submitEmailCode(tester);
    expect(find.text('Email verified.'), findsOneWidget);
  });

  testWidgets(
    'accepted code with failed Auth status reads retries status only',
    (tester) async {
      accounts.emailEnabled = true;
      accounts.emailVerificationError =
          const EmailVerificationStatusUnavailableException();
      await showAccount(tester);
      await submitEmailCode(tester);
      expect(find.textContaining('Your code was accepted,'), findsOneWidget);
      expect(find.text('Email verified.'), findsNothing);
      expect(accounts.emailVerifyCalls, 1);
      accounts.account = emailSnapshot(verified: true);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Check verification status'),
      );
      await tester.pumpAndSettle();
      expect(accounts.emailVerifyCalls, 1);
      expect(find.text('Email verified.'), findsOneWidget);
    },
  );

  testWidgets('email confirmation link can finish without reusing its code', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-verify-email')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    expect(find.text('Already confirmed? Check status'), findsNothing);
    returnFromInbox(tester);
    await tester.pumpAndSettle();
    expect(find.text('Email verified.'), findsNothing);
    accounts.account = emailSnapshot(verified: true);
    returnFromInbox(tester);
    await tester.pumpAndSettle();
    expect(accounts.emailVerifyCalls, 0);
    expect(find.text('Email verified.'), findsOneWidget);
  });

  testWidgets('email verification sheet fits above a small-phone keyboard', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    accounts.accountAfterEmailVerification = emailSnapshot(verified: true);
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await showAccount(tester, size: const Size(320, 740), keyboardInset: 280);
    final verify = find.byKey(const Key('fieldrush-verify-email'));
    await tester.scrollUntilVisible(
      verify,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(verify);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('fieldrush-email-verification-code'));
    await tester.ensureVisible(input);
    await tester.pumpAndSettle();
    await tester.enterText(input, '123456');
    await tester.pumpAndSettle();
    final button = find.widgetWithText(FilledButton, 'Verify email');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(button).bottom, lessThanOrEqualTo(460));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(accounts.emailVerifyCalls, 1);
    expect(find.byType(FieldrushModal), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Email verified.'),
      -220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Email verified.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a sent code retains a status check for the email link', (
    tester,
  ) async {
    accounts.emailEnabled = true;
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-verify-email')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('fieldrush-refresh-email-verification')),
      findsOneWidget,
    );
    accounts.account = emailSnapshot(verified: true);
    returnFromInbox(tester);
    await tester.pumpAndSettle();
    expect(find.text('Email verified.'), findsOneWidget);
    expect(
      find.byKey(const Key('fieldrush-refresh-email-verification')),
      findsNothing,
    );
    expect(accounts.emailVerifyCalls, 0);
  });

  testWidgets('successful signout removes the settings route', (tester) async {
    await showAccount(tester, routed: true);
    await tester.tap(find.byKey(const Key('fieldrush-security-options')));
    await tester.pumpAndSettle();
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
    await tester.tap(find.byKey(const Key('fieldrush-security-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushAccountScreen), findsOneWidget);
    expect(find.text('Could not sign out.'), findsOneWidget);
  });

  testWidgets('saves validated private profile details through repository', (
    tester,
  ) async {
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-edit-name')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-first-name')),
      'Jordan',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fieldrush-edit-username')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-username')),
      'jordan.r',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    expect(accounts.saved?.firstName, 'Jordan');
    expect(accounts.saved?.username, 'jordan.r');
    expect(find.text('Account details saved.'), findsOneWidget);
    expect(find.text('Shown on ladders as Jordan R.'), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('fieldrush-edit-birthday')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-birthday')),
      '2025-01-01',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    expect(find.text('You must be 18 or older.'), findsOneWidget);
    expect(accounts.saved, isNull);
    await tester.enterText(
      find.byKey(const Key('fieldrush-birthday')),
      '2000-02-31',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid birthday.'), findsOneWidget);
    expect(accounts.saved, isNull);
  });

  testWidgets(
    'completed-account birthday cannot be edited to bypass age checks',
    (tester) async {
      await showAccount(tester);
      await tester.tap(find.byKey(const Key('fieldrush-edit-birthday')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fieldrush-birthday')), findsNothing);
      expect(
        find.textContaining(
          'Your birthday is private and cannot be changed here.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Google linking failure does not claim an account is linked', (
    tester,
  ) async {
    accounts.linkError = const AuthException('Google linking was cancelled.');
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-security-options')));
    await tester.pumpAndSettle();
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

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      '$platform account only offers supported Google linking',
      (tester) async {
        await showAccount(tester);
        await tester.tap(find.byKey(const Key('fieldrush-security-options')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('fieldrush-link-google')),
          platform == TargetPlatform.iOS ? findsNothing : findsOneWidget,
        );
        expect(accounts.linkCalls, 0);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      '$platform recovery retains phone and support options',
      (tester) async {
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
        expect(
          find.byKey(const Key('fieldrush-recovery-google')),
          platform == TargetPlatform.iOS ? findsNothing : findsOneWidget,
        );
        expect(
          find.byKey(const Key('fieldrush-recovery-submit')),
          findsOneWidget,
        );
        expect(find.text('Open support website'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'iOS still displays an existing linked Google account',
    (tester) async {
      accounts.account = googleSnapshot();
      await showAccount(tester);
      await tester.tap(find.byKey(const Key('fieldrush-security-options')));
      await tester.pumpAndSettle();
      expect(find.text('Google is linked'), findsOneWidget);
      expect(find.byKey(const Key('fieldrush-link-google')), findsNothing);
      expect(accounts.linkCalls, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

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
            of: find.byType(FieldrushModal),
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
            of: find.byType(FieldrushModal),
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
    expect(find.textContaining('forfeit any remaining'), findsOneWidget);
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

  testWidgets(
    'phone verification sheet stays usable above a small-phone keyboard',
    (tester) async {
      await showAccount(tester, size: const Size(320, 640), keyboardInset: 260);
      final changePhone = find.byKey(const Key('fieldrush-change-phone'));
      await tester.scrollUntilVisible(
        changePhone,
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(changePhone);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(FieldrushModal), findsOneWidget);
      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).enableDrag,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('fieldrush-reauth-submit')));
      await tester.pumpAndSettle();
      final code = find.byKey(const Key('fieldrush-reauth-code'));
      await tester.ensureVisible(code);
      await tester.enterText(code, '123456');
      final verify = find.byKey(const Key('fieldrush-reauth-submit'));
      await tester.ensureVisible(verify);
      await tester.pumpAndSettle();
      await tester.tap(verify);
      await tester.pumpAndSettle();
      expect(accounts.reauthSendCalls, 1);
      expect(accounts.reauthVerifyCalls, 1);
      expect(
        find.byKey(const Key('fieldrush-change-phone-modal')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'discard sheet preserves the draft when cancelled on a small phone',
    (tester) async {
      await showAccount(tester, size: const Size(320, 640), keyboardInset: 220);
      await tester.tap(find.byKey(const Key('fieldrush-edit-name')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('fieldrush-first-name')),
        'Jordan',
      );
      final editUsername = find.byKey(const Key('fieldrush-edit-username'));
      await tester.ensureVisible(editUsername);
      await tester.pumpAndSettle();
      await tester.tap(editUsername);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(FieldrushModal), findsOneWidget);
      expect(find.text('Discard your changes?'), findsOneWidget);
      final keepEditing = find.widgetWithText(OutlinedButton, 'Keep editing');
      await tester.ensureVisible(keepEditing);
      await tester.pumpAndSettle();
      await tester.tap(keepEditing);
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushModal), findsNothing);
      expect(find.text('Jordan'), findsOneWidget);
      expect(accounts.saved, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('legal policies card opens the website without account changes', (
    tester,
  ) async {
    final previousLauncher = UrlLauncherPlatform.instance;
    final launcher = _PolicyLauncher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);
    await showAccount(tester);
    final link = find.byKey(const Key('fieldrush-legal-policies'));
    expect(find.text('Legal & policies'), findsOneWidget);
    expect(
      find.text('Terms, privacy and data requests on fieldrush.gg'),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(link).dy,
      greaterThan(tester.getTopLeft(find.text('HOME CITY')).dy),
    );
    expect(
      tester.getBottomLeft(link).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('fieldrush-delete-account'))).dy,
      ),
    );
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(launcher.urls, ['https://fieldrush.gg/legal']);
    expect(launcher.modes, [PreferredLaunchMode.externalApplication]);
    expect(accounts.updateCalls, 0);
    expect(accounts.deleteCalls, 0);
    expect(accounts.reauthSendCalls, 0);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(FieldrushModal), findsNothing);
    expect(find.text('Account details'), findsOneWidget);
  });

  testWidgets('legal policies card wraps on narrow screens with larger text', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        await (FontLoader(
          font,
        )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
      }
    });
    await showAccount(tester, size: const Size(320, 740), textScale: 1.6);
    await tester.scrollUntilVisible(
      find.byKey(const Key('fieldrush-legal-policies')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Legal & policies'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('optional account visual preview uses the bundled fonts', (
    tester,
  ) async {
    final directory = Platform.environment['FIELDRUSH_ACCOUNT_SCREENSHOT_DIR'];
    if (directory == null) return;
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
    final boundaryKey = GlobalKey();
    await showAccount(
      tester,
      size: const Size(390, 1100),
      boundaryKey: boundaryKey,
    );
    expect(tester.takeException(), isNull);
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/account-extra-settings.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });

  testWidgets('account design shows saved values without an open editor', (
    tester,
  ) async {
    await showAccount(tester, size: const Size(390, 844));
    expect(find.text('Account details'), findsOneWidget);
    expect(find.text('Profile photo'), findsOneWidget);
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('@alex.r'), findsOneWidget);
    expect(find.text('January 2, 2000'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'account keeps the shared navigation and clears it when scrolling',
    (tester) async {
      await showAccount(
        tester,
        size: const Size(390, 844),
        bottomNavigationBar: const SizedBox(
          height: 100,
          child: ColoredBox(color: Colors.white, child: Text('SHARED NAV')),
        ),
      );
      expect(find.text('SHARED NAV'), findsOneWidget);
      final list = tester.widget<ListView>(
        find.byKey(const Key('fieldrush-account-scroll')),
      );
      expect(list.padding, const EdgeInsets.only(bottom: 132));
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.extendBody, isTrue);
      await tester.scrollUntilVisible(
        find.byKey(const Key('fieldrush-delete-account')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel returns to the saved account without a request', (
    tester,
  ) async {
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-edit-name')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-first-name')),
      'Jordan',
    );
    await tester.tap(find.byKey(const Key('fieldrush-cancel-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(accounts.saved, isNull);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets(
    'shared navigation confirms an unsaved account edit before leaving',
    (tester) async {
      var navigated = false;
      await showAccount(
        tester,
        bottomNavigationBuilder: (confirmLeave) => TextButton(
          onPressed: () async => navigated = await confirmLeave(),
          child: const Text('GO HOME'),
        ),
      );
      await tester.tap(find.byKey(const Key('fieldrush-edit-name')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('fieldrush-first-name')),
        'Jordan',
      );
      await tester.pump();
      await tester.tap(find.text('GO HOME'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(navigated, isFalse);
      expect(find.text('Jordan'), findsOneWidget);
      await tester.tap(find.text('GO HOME'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fieldrush-discard-changes')));
      await tester.pumpAndSettle();
      expect(navigated, isTrue);
      expect(find.text('Alex Rivera'), findsOneWidget);
      expect(accounts.saved, isNull);
    },
  );

  testWidgets('changing rows asks before discarding an unsaved edit', (
    tester,
  ) async {
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-edit-name')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-first-name')),
      'Jordan',
    );
    await tester.tap(find.byKey(const Key('fieldrush-edit-username')));
    await tester.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Jordan'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fieldrush-edit-username')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fieldrush-discard-changes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fieldrush-username')), findsOneWidget);
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(accounts.saved, isNull);
  });

  testWidgets('failed save keeps the inline draft and does not claim success', (
    tester,
  ) async {
    accounts.saveError = const AuthException('That username is unavailable.');
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-edit-username')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fieldrush-username')),
      'another.user',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('fieldrush-save-account')));
    await tester.pumpAndSettle();
    expect(find.text('That username is unavailable.'), findsOneWidget);
    expect(find.text('another.user'), findsOneWidget);
    expect(find.text('Account details saved.'), findsNothing);
    expect(accounts.account.draft.username, 'alex.r');
  });

  testWidgets('photo change uploads and preserves the latest profile bio', (
    tester,
  ) async {
    picker.photo = XFile.fromData(
      Uint8List.fromList([1, 2, 3]),
      name: 'photo.png',
      mimeType: 'image/png',
    );
    await showAccount(
      tester,
      withNavigationAvatar: true,
      bottomNavigationBar: const _NavigationAvatarProbe(),
    );
    profiles.bio = 'New bio from another screen';
    await tester.tap(find.byKey(const Key('fieldrush-change-photo')));
    await tester.pumpAndSettle();
    expect(profiles.uploadCalls, 1);
    expect(profiles.uploadedType, 'image/png');
    expect(profiles.saved?.bio, 'New bio from another screen');
    expect(profiles.saved?.avatarUrl, 'https://example.com/uploaded.png');
    expect(find.text('Photo updated.'), findsOneWidget);
    expect(find.byKey(const Key('fieldrush-reset-photo')), findsOneWidget);
    expect(
      find.text('NAV AVATAR: https://example.com/uploaded.png'),
      findsOneWidget,
    );
  });

  testWidgets(
    'photo reset persists removal and retains other profile details',
    (tester) async {
      profiles.avatar = 'https://example.com/avatar.png';
      await showAccount(
        tester,
        withNavigationAvatar: true,
        bottomNavigationBar: const _NavigationAvatarProbe(),
      );
      expect(
        find.text('NAV AVATAR: https://example.com/avatar.png'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('fieldrush-reset-photo')));
      await tester.pumpAndSettle();
      expect(profiles.saved?.avatarUrl, '');
      expect(profiles.saved?.bio, 'A football player');
      expect(profiles.uploadCalls, 0);
      expect(find.text('Photo reset.'), findsOneWidget);
      expect(find.byKey(const Key('fieldrush-reset-photo')), findsNothing);
      expect(find.text('NAV AVATAR: HOME ICON'), findsOneWidget);
    },
  );

  testWidgets('failed photo upload preserves the existing photo', (
    tester,
  ) async {
    profiles.avatar = 'https://example.com/avatar.png';
    profiles.uploadError = const AuthException('Photo upload failed.');
    picker.photo = XFile.fromData(Uint8List.fromList([1]), name: 'photo.jpg');
    await showAccount(tester);
    await tester.tap(find.byKey(const Key('fieldrush-change-photo')));
    await tester.pumpAndSettle();
    expect(profiles.saved, isNull);
    expect(profiles.avatar, 'https://example.com/avatar.png');
    expect(find.text('Photo upload failed.'), findsOneWidget);
    expect(find.text('Photo updated.'), findsNothing);
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

class _PolicyLauncher extends UrlLauncherPlatform {
  final urls = <String>[];
  final modes = <PreferredLaunchMode>[];

  @override
  Null get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    urls.add(url);
    modes.add(options.mode);
    return true;
  }
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
  Object? saveError;
  Object? deleteError;
  Object? reauthError;
  Object? phoneVerificationError;
  Object? loadErrorAfterEmailVerification;
  Object? emailRequestError;
  Object? emailVerificationError;
  Completer<void>? emailSendResponse;
  bool emailEnabled = false;
  bool emailCodeSubmitted = false;
  FieldrushAccount? accountAfterEmailVerification;
  int emailRequests = 0;
  int emailVerifyCalls = 0;
  int linkCalls = 0;
  int reauthSendCalls = 0;
  int reauthVerifyCalls = 0;
  int deleteCalls = 0;
  int updateCalls = 0;
  bool disconnectGoogleRequested = false;

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
  Future<FieldrushAccount> updateAccount(
    AccountDraft draft, {
    bool disconnectGoogle = false,
  }) async {
    updateCalls++;
    disconnectGoogleRequested = disconnectGoogle;
    if (saveError != null) throw saveError!;
    saved = draft;
    account = FieldrushAccount(
      draft: draft,
      phone: account.phone,
      phoneVerified: account.phoneVerified,
      googleLinked: account.googleLinked && !disconnectGoogle,
      emailVerified:
          account.emailVerified &&
          account.draft.email.toLowerCase() == draft.email.toLowerCase(),
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
    if (emailRequestError != null) throw emailRequestError!;
    await emailSendResponse?.future;
  }

  @override
  Future<void> verifyEmailCode(String email, String token) async {
    emailVerifyCalls++;
    if (emailVerificationError != null) throw emailVerificationError!;
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
  User? navigationUser;
  StreamController<AuthState>? changes;

  @override
  User? get currentUser => navigationUser;

  @override
  Stream<AuthState> get authStateChanges =>
      changes?.stream ?? const Stream.empty();

  @override
  Future<void> signOut() async {
    signOutCalls++;
    if (signOutError != null) throw signOutError!;
  }
}

class _NavigationAvatarProbe extends StatelessWidget {
  const _NavigationAvatarProbe();

  @override
  Widget build(BuildContext context) => Text(
    'NAV AVATAR: ${FieldNavigationProfileScope.avatarUrlOf(context) ?? 'HOME ICON'}',
  );
}

class _ProfileRepository extends Fake implements ProfileRepository {
  String bio = 'A football player';
  String? avatar;
  ProfileUpdate? saved;
  int uploadCalls = 0;
  String? uploadedType;
  Object? uploadError;

  @override
  Future<PlayerProfile> getCurrentProfile() async => PlayerProfile(
    id: 'player-1',
    displayName: 'Alex R.',
    username: 'alex.r',
    bio: bio,
    avatarUrl: avatar,
    followingCount: 0,
    fansCount: 0,
    appearances: 0,
    goals: 0,
    assists: 0,
    highlights: const [],
    career: const [],
  );

  @override
  Future<void> updateCurrentProfile(ProfileUpdate update) async {
    saved = update;
    bio = update.bio;
    avatar = update.avatarUrl.isEmpty ? null : update.avatarUrl;
  }

  @override
  Future<String> uploadCurrentUserAvatar({
    required Uint8List bytes,
    required String fileExtension,
    required String contentType,
  }) async {
    uploadCalls++;
    uploadedType = contentType;
    if (uploadError != null) throw uploadError!;
    return 'https://example.com/uploaded.png';
  }
}

class _ImagePicker extends Fake implements ImagePicker {
  XFile? photo;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => photo;
}
