import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_auth_screen.dart';
import 'package:field/src/auth/fieldrush_phone_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final captureDirectory = Platform.environment['FIELDRUSH_AUTH_CAPTURE_DIR'];
  if (captureDirectory != null) {
    testWidgets('capture synthetic welcome and account review', (tester) async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        await (FontLoader(
          font,
        )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('fieldrush-auth-screenshot')),
        );
        await tester.runAsync(() async {
          await Directory(captureDirectory).create(recursive: true);
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$captureDirectory/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      final repo = _AccountRepository();
      await _pump(tester, repo, size: const Size(390, 1100));
      await capture('signup-welcome');
      await _dispose(tester);
      await _pump(
        tester,
        repo,
        size: const Size(390, 1100),
        account: FieldrushAccount(
          phone: '+16025550148',
          phoneVerified: true,
          draft: _completeDraft,
          ratingInitialized: true,
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('fieldrush-continue')));
      await capture('signup-review');
      await _dispose(tester);
    });
  }

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

  testWidgets('rejected OTP keeps its error on the code screen', (
    tester,
  ) async {
    final repo = _AccountRepository()
      ..verifyError = const AuthException('Expired code', code: 'otp_expired');
    await _pump(tester, repo);
    await _phone(tester);
    await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
    await _tap(tester, 'fieldrush-continue');
    expect(
      find.text('That code has expired. Request a new one.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fieldrush-code')), findsOneWidget);
    expect(find.byKey(const Key('fieldrush-signing-in')), findsNothing);
    expect(find.textContaining('Your number was verified'), findsNothing);
    await _dispose(tester);
  });

  for (final returningPlayer in [true, false]) {
    testWidgets(
      'verified ${returningPlayer ? 'returning' : 'new'} player sees a skeleton while the account loads',
      (tester) async {
        final pending = Completer<FieldrushAccount>();
        final repo = _AccountRepository()..nextLoad = () => pending.future;
        if (returningPlayer) {
          repo.account = FieldrushAccount(
            draft: _completeDraft,
            phone: '+16025550148',
            phoneVerified: true,
            completed: true,
          );
        }
        var completed = 0;
        await _pump(tester, repo, onCompleted: () => completed++);
        await _phone(tester);
        await tester.enterText(
          find.byKey(const Key('fieldrush-code')),
          '123456',
        );
        await _tap(tester, 'fieldrush-continue');

        for (var second = 0; second < 3; second++) {
          await tester.pump(const Duration(seconds: 1));
          expect(find.byKey(const Key('fieldrush-signing-in')), findsOneWidget);
          expect(find.textContaining('Your number was verified'), findsNothing);
          expect(find.byKey(const Key('fieldrush-code')), findsNothing);
          expect(find.text('What’s your\nname?'), findsNothing);
          expect(completed, 0);
        }

        pending.complete(repo.account);
        await tester.pumpAndSettle();
        expect(repo.verifiedCodes, ['123456']);
        expect(completed, returningPlayer ? 1 : 0);
        expect(
          find.byKey(const Key('fieldrush-signing-in')),
          returningPlayer ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('What’s your\nname?'),
          returningPlayer ? findsNothing : findsOneWidget,
        );
        await _dispose(tester);
      },
    );
  }

  testWidgets(
    'failed verified-account load shows recovery and retries in a skeleton',
    (tester) async {
      final firstRead = Completer<FieldrushAccount>();
      final retry = Completer<FieldrushAccount>();
      final repo = _AccountRepository()..nextLoad = () => firstRead.future;
      await _pump(tester, repo);
      await _phone(tester);
      await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
      await _tap(tester, 'fieldrush-continue');
      expect(find.byKey(const Key('fieldrush-signing-in')), findsOneWidget);
      expect(find.textContaining('Your number was verified'), findsNothing);

      firstRead.completeError(TimeoutException('Could not load account'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fieldrush-signing-in')), findsNothing);
      expect(find.text('Finish signing in'), findsOneWidget);
      expect(find.textContaining('Your number was verified'), findsOneWidget);

      repo.nextLoad = () => retry.future;
      await _tap(tester, 'fieldrush-continue');
      expect(find.byKey(const Key('fieldrush-signing-in')), findsOneWidget);
      expect(find.textContaining('Your number was verified'), findsNothing);
      expect(repo.verifiedCodes, ['123456']);
      retry.complete(repo.account);
      await tester.pumpAndSettle();
      expect(find.text('What’s your\nname?'), findsOneWidget);
      expect(repo.verifiedCodes, ['123456']);
      await _dispose(tester);
    },
  );

  testWidgets(
    'different number in unfinished phone signup needs explicit switch consent',
    (tester) async {
      final auth = _AuthRepository()..session = _phoneSession();
      final repo = _AccountRepository()
        ..account = const FieldrushAccount(
          draft: AccountDraft(firstName: 'Old draft'),
          phone: '+16025550148',
          phoneVerified: true,
        )
        ..onSwitch = auth.signOut;
      await _pump(tester, repo, account: repo.account, auth: auth);
      await _tap(tester, 'fieldrush-back');
      await tester.enterText(
        find.byKey(const Key('fieldrush-phone')),
        '6025550101',
      );
      await _tap(tester, 'fieldrush-continue');
      expect(find.text('Use a different account?'), findsOneWidget);
      expect(repo.sentPhones, isEmpty);
      expect(repo.switchedPhones, isEmpty);
      await _tap(tester, 'fieldrush-cancel-phone-account-switch');
      expect(auth.currentUser?.id, 'old-user');
      expect(repo.switchedPhones, isEmpty);

      await _tap(tester, 'fieldrush-continue');
      await _tap(tester, 'fieldrush-confirm-phone-account-switch');
      expect(auth.currentUser, isNull);
      expect(repo.switchedPhones, ['+16025550101']);
      expect(repo.sentPhones, ['+16025550101']);
      expect(find.byKey(const Key('fieldrush-code')), findsOneWidget);
      repo.account = const FieldrushAccount(
        draft: AccountDraft(),
        phone: '+16025550101',
        phoneVerified: true,
      );
      await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
      await _tap(tester, 'fieldrush-continue');
      expect(find.text('What’s your\nname?'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('fieldrush-first-name')))
            .controller!
            .text,
        isEmpty,
      );
      expect(repo.savedDrafts, isEmpty);
      await _dispose(tester);
    },
  );

  testWidgets('failed signup switch never reports a sent code', (tester) async {
    final auth = _AuthRepository()..session = _phoneSession();
    final repo = _AccountRepository()
      ..switchError = const AuthException('Could not sign out.')
      ..onSwitch = auth.signOut;
    await _pump(tester, repo, account: repo.account, auth: auth);
    await _tap(tester, 'fieldrush-back');
    await tester.enterText(
      find.byKey(const Key('fieldrush-phone')),
      '6025550101',
    );
    await _tap(tester, 'fieldrush-continue');
    await _tap(tester, 'fieldrush-confirm-phone-account-switch');
    expect(find.text('Could not sign out.'), findsOneWidget);
    expect(find.byKey(const Key('fieldrush-code')), findsNothing);
    expect(repo.sentPhones, isEmpty);
    expect(auth.currentUser, isNull);
    await _tap(tester, 'fieldrush-continue');
    expect(repo.switchedPhones.length, 1);
    expect(repo.sentPhones, ['+16025550101']);
    expect(find.byKey(const Key('fieldrush-code')), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets(
    'account-read failure before switching cannot fall through to phone change',
    (tester) async {
      final auth = _AuthRepository();
      final repo = _AccountRepository()..loadFailures = 2;
      await _pump(tester, repo, auth: auth);
      await _phone(tester);
      auth.session = _phoneSession();
      await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
      await _tap(tester, 'fieldrush-continue');
      await tester.tap(find.text('Change number'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('fieldrush-phone')),
        '6025550101',
      );
      await _tap(tester, 'fieldrush-continue');
      expect(repo.sentPhones, ['+16025550148']);
      expect(repo.switchedPhones, isEmpty);
      expect(find.byKey(const Key('fieldrush-code')), findsNothing);
      expect(
        find.text('That took too long. Check your connection and try again.'),
        findsOneWidget,
      );
      await _tap(tester, 'fieldrush-continue');
      expect(find.text('Use a different account?'), findsOneWidget);
      expect(repo.sentPhones, ['+16025550148']);
      await _tap(tester, 'fieldrush-cancel-phone-account-switch');
      await _dispose(tester);
    },
  );

  testWidgets('Google-first phone attachment does not switch accounts', (
    tester,
  ) async {
    final auth = _AuthRepository()..session = _phoneSession();
    final repo = _AccountRepository()
      ..account = const FieldrushAccount(
        draft: AccountDraft(email: 'google@example.com'),
        googleLinked: true,
      );
    await _pump(tester, repo, account: repo.account, auth: auth);
    await tester.enterText(
      find.byKey(const Key('fieldrush-phone')),
      '6025550101',
    );
    await _tap(tester, 'fieldrush-continue');
    expect(repo.sentPhones, ['+16025550101']);
    expect(repo.switchedPhones, isEmpty);
    expect(find.text('Use a different account?'), findsNothing);
    expect(auth.currentUser?.id, 'old-user');
    await _dispose(tester);
  });

  testWidgets('phone login with a new number continues into signup after OTP', (
    tester,
  ) async {
    final repo = _AccountRepository()
      ..recoveryError = const AuthException('This phone has no account.');
    var completed = 0;
    await _pump(tester, repo, onCompleted: () => completed++);
    await _tap(tester, 'fieldrush-log-in');
    await tester.enterText(
      find.byKey(const Key('fieldrush-phone')),
      '6025550148',
    );
    await _tap(tester, 'fieldrush-continue');
    expect(repo.sentPhones, ['+16025550148']);
    expect(repo.recoveryPhones, isEmpty);
    expect(find.byKey(const Key('fieldrush-code')), findsOneWidget);
    expect(find.text('What’s your\nname?'), findsNothing);

    await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
    await _tap(tester, 'fieldrush-continue');
    expect(find.text('What’s your\nname?'), findsOneWidget);
    expect(find.text('Look\nright?'), findsNothing);
    expect(repo.savedDrafts, isEmpty);
    expect(repo.completedCount, 0);
    expect(completed, 0);
    await _dispose(tester);
  });

  testWidgets('returning phone login hands off without signup review', (
    tester,
  ) async {
    final repo = _AccountRepository()
      ..account = FieldrushAccount(
        draft: _completeDraft,
        phone: '+16025550148',
        phoneVerified: true,
        completed: true,
      );
    var completed = 0;
    await _pump(tester, repo, onCompleted: () => completed++);
    await _tap(tester, 'fieldrush-log-in');
    await tester.enterText(
      find.byKey(const Key('fieldrush-phone')),
      '6025550148',
    );
    await _tap(tester, 'fieldrush-continue');
    await tester.enterText(find.byKey(const Key('fieldrush-code')), '123456');
    await _tap(tester, 'fieldrush-continue');

    expect(find.byKey(const Key('fieldrush-signing-in')), findsOneWidget);
    expect(find.text('What’s your\nlevel?'), findsNothing);
    expect(find.text('Look\nright?'), findsNothing);
    expect(find.byKey(const Key('fieldrush-accept-policies')), findsNothing);
    expect(repo.completedCount, 0);
    expect(repo.savedDrafts, isEmpty);
    expect(repo.recoveryPhones, isEmpty);
    expect(completed, 1);
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

  testWidgets('full signup completes from account review without a checkbox', (
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
    expect(find.text('What’s your\nlevel?'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('fieldrush-continue')))
          .onPressed,
      isNull,
    );
    expect(repo.completedCount, 0);
    await _tap(tester, 'fieldrush-skill-intermediate');
    await _tap(tester, 'fieldrush-continue');
    expect(repo.savedDrafts.last.skillAssessment, SkillAssessment.intermediate);
    expect(find.text('Look\nright?'), findsOneWidget);
    expect(repo.completedCount, 0);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.byKey(const Key('fieldrush-accept-policies')), findsNothing);
    final agreement = tester.widget<Text>(
      find.byKey(const Key('fieldrush-review-agreement')),
    );
    expect(
      agreement.textSpan!.toPlainText(),
      'By creating an account, you agree to our Terms and Privacy Policy.',
    );
    await _tap(tester, 'fieldrush-continue');
    expect(repo.completedCount, 1);
    expect(repo.account.draft.skillAssessment, SkillAssessment.intermediate);
    expect(find.text('Look\nright?'), findsNothing);
    expect(find.byKey(const Key('fieldrush-signing-in')), findsOneWidget);
    expect(find.text('Let’s go'), findsNothing);
    expect(repo.tourCompletions, 0);
    expect(completed, 1);
    await _dispose(tester);
  });

  testWidgets(
    'new account resumes at assessment while legacy account skips it',
    (tester) async {
      final repo = _AccountRepository();
      await _pump(
        tester,
        repo,
        account: FieldrushAccount(
          phone: '+16025550148',
          phoneVerified: true,
          draft: _completeDraft,
          skillAssessmentRequired: true,
        ),
      );
      expect(find.text('What’s your\nlevel?'), findsOneWidget);
      expect(find.text('Highly competitive'), findsOneWidget);
      expect(find.text('So your first games are fair.'), findsOneWidget);
      expect(find.byKey(const Key('fieldrush-skill-not_sure')), findsNothing);
      await _tap(tester, 'fieldrush-skill-skip');
      expect(repo.savedDrafts.single.skillAssessment, SkillAssessment.notSure);
      expect(find.text('Look\nright?'), findsOneWidget);
      await _dispose(tester);

      await _pump(
        tester,
        repo,
        account: FieldrushAccount(
          phone: '+16025550148',
          phoneVerified: true,
          draft: _completeDraft,
          ratingInitialized: true,
        ),
      );
      expect(find.text('Look\nright?'), findsOneWidget);
      expect(find.text('STARTING LEVEL'), findsNothing);
      expect(find.text('What’s your\nlevel?'), findsNothing);
      await _dispose(tester);
    },
  );

  testWidgets('assessment edit can be cancelled or saved before completion', (
    tester,
  ) async {
    final repo = _AccountRepository();
    await _pump(
      tester,
      repo,
      account: FieldrushAccount(
        phone: '+16025550148',
        phoneVerified: true,
        draft: _completeDraft.copyWith(skillAssessment: SkillAssessment.casual),
        skillAssessmentRequired: true,
      ),
    );
    expect(find.text('Look\nright?'), findsOneWidget);
    expect(find.text('Casual'), findsOneWidget);
    await _tap(tester, 'fieldrush-edit-skillAssessment');
    await _tap(tester, 'fieldrush-skill-advanced');
    await _tap(tester, 'fieldrush-back');
    expect(find.text('Casual'), findsOneWidget);
    expect(repo.savedDrafts, isEmpty);
    await _tap(tester, 'fieldrush-edit-skillAssessment');
    await _tap(tester, 'fieldrush-skill-highly_competitive');
    await _tap(tester, 'fieldrush-continue');
    expect(find.text('Look\nright?'), findsOneWidget);
    expect(find.text('Highly competitive'), findsOneWidget);
    expect(
      repo.savedDrafts.single.skillAssessment,
      SkillAssessment.highlyCompetitive,
    );
    await _dispose(tester);
  });

  testWidgets(
    'assessment survives failed save and fits a narrow large-text screen',
    (tester) async {
      final repo = _AccountRepository()
        ..saveError = StateError('Network request failed');
      await _pump(
        tester,
        repo,
        account: FieldrushAccount(
          phone: '+16025550148',
          phoneVerified: true,
          draft: _completeDraft,
          skillAssessmentRequired: true,
        ),
        size: const Size(320, 568),
        scale: 1.5,
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, 'fieldrush-skill-beginner');
      await _tap(tester, 'fieldrush-continue');
      expect(find.text('What’s your\nlevel?'), findsOneWidget);
      expect(find.textContaining('offline'), findsOneWidget);
      expect(repo.savedDrafts, isEmpty);
      repo.saveError = null;
      await _tap(tester, 'fieldrush-continue');
      expect(find.text('Look\nright?'), findsOneWidget);
      expect(repo.savedDrafts.single.skillAssessment, SkillAssessment.beginner);
      await _dispose(tester);
    },
  );

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

Session _phoneSession() => Session(
  accessToken: 'local-widget-test-token',
  tokenType: 'bearer',
  user: User(
    id: 'old-user',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-10-15T00:00:00Z',
    phone: '16025550148',
  ),
);

Future<void> _pump(
  WidgetTester tester,
  _AccountRepository repo, {
  FieldrushAccount? account,
  VoidCallback? onCompleted,
  _AuthRepository? auth,
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
      home: RepaintBoundary(
        key: const Key('fieldrush-auth-screenshot'),
        child: FieldrushAuthScreen(
          authRepository: auth ?? _AuthRepository(),
          accountRepository: repo,
          account: account,
          onOnboardingCompleted: onCompleted ?? () {},
        ),
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
  Session? session;
  @override
  Session? get currentSession => session;
  @override
  User? get currentUser => session?.user;
  @override
  Future<void> signOut() async => session = null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AccountRepository implements FieldrushAccountRepository {
  FieldrushAccount account = const FieldrushAccount(
    phone: '+16025550148',
    phoneVerified: true,
    draft: AccountDraft(),
    skillAssessmentRequired: true,
  );
  final List<String> sentPhones = [];
  final List<String> recoveryPhones = [];
  final List<String> verifiedCodes = [];
  final List<AccountDraft> savedDrafts = [];
  int googleLaunches = 0;
  int completedCount = 0;
  int tourCompletions = 0;
  int loadFailures = 0;
  Object? sendError;
  Object? recoveryError;
  Object? verifyError;
  Object? saveError;
  Object? switchError;
  Future<void> Function()? onSwitch;
  Future<FieldrushAccount> Function()? nextLoad;
  final List<String> switchedPhones = [];
  String? blockedUsername;

  @override
  bool get emailDeliveryEnabled => false;
  @override
  Future<FieldrushAccount> loadAccount() async {
    if (loadFailures > 0) {
      loadFailures--;
      throw TimeoutException('Could not load account');
    }
    return nextLoad == null ? account : nextLoad!();
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
  Future<void> switchIncompletePhoneAccount(String phone) async {
    switchedPhones.add(phone);
    await onSwitch?.call();
    if (switchError != null) throw switchError!;
    sentPhones.add(phone);
  }

  @override
  Future<void> sendRecoveryCode(String phone) async {
    recoveryPhones.add(phone);
    if (recoveryError != null) throw recoveryError!;
    await sendPhoneCode(phone);
  }

  @override
  Future<void> verifyPhoneCode(String phone, String token) async {
    verifiedCodes.add(token);
    if (verifyError != null) throw verifyError!;
  }

  @override
  Future<void> markTourCompleted() async {
    tourCompletions++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
