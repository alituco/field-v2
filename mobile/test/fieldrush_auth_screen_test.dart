import 'dart:async';

import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_auth_screen.dart';
import 'package:field/src/auth/fieldrush_phone_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('phone parsing supports international numbers and defaults to US', () {
    expect(normalizeFieldrushPhone('(602) 555-0148'), '+16025550148');
    expect(normalizeFieldrushPhone('+44 7400 123456'), '+447400123456');
    expect(
      normalizeFieldrushPhone('07400123456', country: IsoCode.GB),
      '+447400123456',
    );
    expect(normalizeFieldrushPhone('123'), isNull);
    expect(normalizeFieldrushPhone('not a phone'), isNull);
  });

  testWidgets(
    'welcome is native Fieldrush, with phone and real Google launch',
    (tester) async {
      final repo = _AccountRepository();
      await _pump(tester, repo);
      expect(find.text('Fieldrush'), findsOneWidget);
      expect(find.text('Every game counts.'), findsOneWidget);
      final agreement = tester.widget<Text>(
        find.byKey(const Key('fieldrush-welcome-agreement')),
      );
      expect(
        agreement.textSpan!.toPlainText(),
        'By tapping Create account or Log in, you agree to our Terms and '
        'Privacy Policy.',
      );
      expect(find.text('Your next game starts here.'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Every game counts.')).dy -
            tester.getBottomLeft(find.text('Fieldrush')).dy,
        4,
      );
      expect(find.text('9:41'), findsNothing);
      await _tap(tester, 'fieldrush-create-account');
      expect(find.text('What’s your\nnumber?'), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      await _tap(tester, 'fieldrush-google');
      expect(repo.googleLaunches, 1);
      expect(find.textContaining('Continue in Google'), findsOneWidget);
      expect(find.text('Choose an account'), findsNothing);
      await _dispose(tester);
    },
  );

  testWidgets(
    'invalid phone does not send OTP and provider errors are visible',
    (tester) async {
      final repo = _AccountRepository();
      await _pump(tester, repo);
      await _tap(tester, 'fieldrush-log-in');
      await tester.enterText(find.byKey(const Key('fieldrush-phone')), '123');
      await _tap(tester, 'fieldrush-continue');
      expect(repo.sentPhones, isEmpty);
      expect(
        find.text('Enter a valid phone number and country code.'),
        findsOneWidget,
      );
      repo.sendError = const AuthException(
        'Too many attempts. Please wait.',
        code: 'over_request_rate_limit',
      );
      await tester.enterText(
        find.byKey(const Key('fieldrush-phone')),
        '6025550148',
      );
      await _tap(tester, 'fieldrush-continue');
      expect(find.textContaining('Too many attempts'), findsOneWidget);
      expect(find.byKey(const Key('fieldrush-code')), findsNothing);
      await _dispose(tester);
    },
  );

  testWidgets(
    'OTP is real, resending has a cooldown and incomplete accounts resume',
    (tester) async {
      final repo = _AccountRepository();
      await _pump(tester, repo);
      await _phone(tester);
      expect(repo.sentPhones, ['+16025550148']);
      final resend = tester.widget<TextButton>(
        find.byKey(const Key('fieldrush-resend-code')),
      );
      expect(resend.onPressed, isNull);
      await tester.enterText(find.byKey(const Key('fieldrush-code')), '123');
      await _tap(tester, 'fieldrush-continue');
      expect(repo.verifiedCodes, isEmpty);
      await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
      await _tap(tester, 'fieldrush-continue');
      expect(repo.verifiedCodes, ['123456']);
      expect(find.text('What’s your\nname?'), findsOneWidget);
      await _dispose(tester);
    },
  );

  testWidgets('account load retry does not consume a second OTP', (
    tester,
  ) async {
    final repo = _AccountRepository()..loadFailures = 1;
    await _pump(tester, repo);
    await _phone(tester);
    await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
    await _tap(tester, 'fieldrush-continue');
    expect(find.text('Finish signing in'), findsOneWidget);
    await _tap(tester, 'fieldrush-continue');
    expect(repo.verifiedCodes, ['123456']);
    expect(find.text('What’s your\nname?'), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('completed account still requires a verified phone', (
    tester,
  ) async {
    final repo = _AccountRepository()
      ..account = FieldrushAccount(
        draft: _completeDraft,
        phone: '+447400123456',
        completed: true,
        tourCompleted: true,
      );
    var completed = 0;
    await _pump(
      tester,
      repo,
      account: repo.account,
      onCompleted: () => completed++,
    );
    expect(find.text('What’s your\nnumber?'), findsOneWidget);
    expect(find.text('+44'), findsOneWidget);
    expect(find.text('Let’s go'), findsNothing);
    expect(completed, 0);
    await _tap(tester, 'fieldrush-continue');
    expect(repo.sentPhones, ['+447400123456']);
    expect(repo.tourCompletions, 0);
    repo.account = FieldrushAccount(
      draft: _completeDraft,
      phone: '+447400123456',
      phoneVerified: true,
      completed: true,
      tourCompleted: true,
    );
    await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
    await _tap(tester, 'fieldrush-continue');
    expect(completed, 1);
    await _dispose(tester);
  });

  testWidgets('full signup saves draft and cannot complete without consent', (
    tester,
  ) async {
    final repo = _AccountRepository();
    var completed = 0;
    await _pump(
      tester,
      repo,
      account: repo.account,
      onCompleted: () => completed++,
    );
    await tester.enterText(
      find.byKey(const Key('fieldrush-first-name')),
      'Jordan',
    );
    await tester.enterText(
      find.byKey(const Key('fieldrush-last-name')),
      'Alvarez',
    );
    await _tap(tester, 'fieldrush-continue');
    expect(repo.savedDrafts.last.firstName, 'Jordan');
    await tester.enterText(
      find.byKey(const Key('fieldrush-username')),
      'jordan.plays',
    );
    await _tap(tester, 'fieldrush-continue');
    expect(find.text('When’s your\nbirthday?'), findsOneWidget);
    await _birthday(tester, '08', '20', '2000');
    await _tap(tester, 'fieldrush-continue');
    await tester.enterText(
      find.byKey(const Key('fieldrush-email')),
      'jordan@example.com',
    );
    await _tap(tester, 'fieldrush-continue');
    expect(find.text('Look\nright?'), findsOneWidget);
    await _tap(tester, 'fieldrush-continue');
    expect(repo.completedCount, 0);
    expect(find.textContaining('Read and accept'), findsOneWidget);
    await _tap(tester, 'fieldrush-accept-policies');
    await _tap(tester, 'fieldrush-continue');
    expect(repo.completedCount, 1);
    expect(find.text('Jordan A.'), findsOneWidget);
    expect(completed, 0);
    await _tap(tester, 'fieldrush-continue');
    expect(repo.tourCompletions, 1);
    expect(completed, 1);
    await _dispose(tester);
  });

  testWidgets(
    'calendar dates and 18 plus rule are validated before draft writes',
    (tester) async {
      final repo = _AccountRepository();
      await _pump(
        tester,
        repo,
        account: const FieldrushAccount(
          phone: '+16025550148',
          phoneVerified: true,
          draft: AccountDraft(
            firstName: 'Jordan',
            lastName: 'Alvarez',
            username: 'jordan.plays',
          ),
        ),
      );
      await _birthday(tester, '02', '31', '2000');
      await _tap(tester, 'fieldrush-continue');
      expect(find.textContaining('Enter a real birthday'), findsOneWidget);
      expect(repo.savedDrafts, isEmpty);
      await _birthday(tester, '01', '01', '${DateTime.now().year - 17}');
      await _tap(tester, 'fieldrush-continue');
      expect(
        find.text('You must be 18 or older to join Fieldrush.'),
        findsOneWidget,
      );
      expect(repo.savedDrafts, isEmpty);
      await _dispose(tester);
    },
  );

  testWidgets('unavailable username never advances or writes a draft', (
    tester,
  ) async {
    final repo = _AccountRepository()..blockedUsername = 'admin';
    await _pump(
      tester,
      repo,
      account: const FieldrushAccount(
        phone: '+16025550148',
        phoneVerified: true,
        draft: AccountDraft(firstName: 'Jordan', lastName: 'Alvarez'),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('fieldrush-username')),
      'admin',
    );
    await _tap(tester, 'fieldrush-continue');
    expect(find.text('Pick a\nusername'), findsOneWidget);
    expect(find.textContaining('reserved'), findsWidgets);
    expect(repo.savedDrafts, isEmpty);
    await _dispose(tester);
  });

  testWidgets(
    'review editing verified unchanged phone does not send another OTP',
    (tester) async {
      final repo = _AccountRepository();
      await _pump(
        tester,
        repo,
        account: FieldrushAccount(
          phone: '+16025550148',
          phoneVerified: true,
          draft: _completeDraft,
        ),
      );
      await _tap(tester, 'fieldrush-edit-phone');
      await _tap(tester, 'fieldrush-continue');
      expect(find.text('Look\nright?'), findsOneWidget);
      expect(repo.sentPhones, isEmpty);
      await _dispose(tester);
    },
  );

  testWidgets('Google callback cannot bypass required verified phone', (
    tester,
  ) async {
    final repo = _AccountRepository();
    await _pump(
      tester,
      repo,
      account: const FieldrushAccount(
        googleLinked: true,
        draft: AccountDraft(
          firstName: 'Jordan',
          lastName: 'Alvarez',
          email: 'jordan@gmail.com',
        ),
      ),
    );
    expect(find.byKey(const Key('fieldrush-phone')), findsOneWidget);
    expect(find.textContaining('Google is connected'), findsOneWidget);
    expect(repo.completedCount, 0);
    await _dispose(tester);
  });

  testWidgets(
    '320px phone and keyboard with large text have no layout overflow',
    (tester) async {
      final repo = _AccountRepository();
      await _pump(tester, repo, size: const Size(320, 568), scale: 1.5);
      expect(tester.takeException(), isNull);
      await _tap(tester, 'fieldrush-create-account');
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('fieldrush-phone')),
        '6025550148',
      );
      await _tap(tester, 'fieldrush-continue');
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    },
  );

  testWidgets('failed draft save keeps the entered values and the same step', (
    tester,
  ) async {
    final repo = _AccountRepository()
      ..saveError = StateError('Network request failed');
    await _pump(tester, repo, account: repo.account);
    await tester.enterText(
      find.byKey(const Key('fieldrush-first-name')),
      'Jordan',
    );
    await tester.enterText(
      find.byKey(const Key('fieldrush-last-name')),
      'Alvarez',
    );
    await _tap(tester, 'fieldrush-continue');
    expect(find.text('What’s your\nname?'), findsOneWidget);
    expect(find.textContaining('offline'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('fieldrush-first-name')))
          .controller!
          .text,
      'Jordan',
    );
    await _dispose(tester);
  });
}

final _completeDraft = AccountDraft(
  firstName: 'Jordan',
  lastName: 'Alvarez',
  username: 'jordan.plays',
  dateOfBirth: DateTime(2000, 8, 20),
  email: 'jordan@example.com',
);

Future<void> _pump(
  WidgetTester tester,
  _AccountRepository repo, {
  FieldrushAccount? account,
  VoidCallback? onCompleted,
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: FieldrushAuthScreen(
        authRepository: _AuthRepository(),
        accountRepository: repo,
        account: account,
        onOnboardingCompleted: onCompleted ?? () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _phone(WidgetTester tester) async {
  await _tap(tester, 'fieldrush-create-account');
  await tester.enterText(
    find.byKey(const Key('fieldrush-phone')),
    '6025550148',
  );
  await _tap(tester, 'fieldrush-continue');
}

Future<void> _birthday(
  WidgetTester tester,
  String month,
  String day,
  String year,
) async {
  await tester.enterText(find.byKey(const Key('fieldrush-month')), month);
  await tester.enterText(find.byKey(const Key('fieldrush-day')), day);
  await tester.enterText(find.byKey(const Key('fieldrush-year')), year);
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  expect(tester.takeException(), isNull);
}

class _AuthRepository implements AuthRepository {
  @override
  Future<void> signOut() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AccountRepository implements FieldrushAccountRepository {
  FieldrushAccount account = const FieldrushAccount(
    phone: '+16025550148',
    phoneVerified: true,
    draft: AccountDraft(),
  );
  final List<String> sentPhones = [];
  final List<String> verifiedCodes = [];
  final List<AccountDraft> savedDrafts = [];
  int googleLaunches = 0;
  int completedCount = 0;
  int tourCompletions = 0;
  int loadFailures = 0;
  Object? sendError;
  Object? saveError;
  String? blockedUsername;

  @override
  bool get emailDeliveryEnabled => false;
  @override
  Future<FieldrushAccount> loadAccount() async {
    if (loadFailures > 0) {
      loadFailures--;
      throw TimeoutException('Could not load account');
    }
    return account;
  }

  @override
  Future<void> saveDraft(AccountDraft draft) async {
    if (saveError != null) throw saveError!;
    savedDrafts.add(draft);
  }

  @override
  Future<FieldrushAccount> completeOnboarding(AccountDraft draft) async {
    completedCount++;
    return account = FieldrushAccount(
      draft: draft,
      phone: account.phone,
      phoneVerified: true,
      completed: true,
    );
  }

  @override
  Future<UsernameAvailability> checkUsername(String username) async =>
      UsernameAvailability(
        available: username != blockedUsername,
        message: username == blockedUsername
            ? 'That username is reserved.'
            : '',
      );
  @override
  Future<void> signInWithGoogle() async {
    googleLaunches++;
  }

  @override
  Future<void> sendPhoneCode(String phone) async {
    if (sendError != null) throw sendError!;
    sentPhones.add(phone);
  }

  @override
  Future<void> sendRecoveryCode(String phone) => sendPhoneCode(phone);

  @override
  Future<void> verifyPhoneCode(String phone, String token) async {
    verifiedCodes.add(token);
  }

  @override
  Future<void> markTourCompleted() async {
    tourCompletions++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
