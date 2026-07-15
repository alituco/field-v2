import 'package:field/src/auth/auth_flow_screen.dart';
import 'package:field/src/auth/auth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('existing named user goes directly from OTP to date of birth', (
    tester,
  ) async {
    final repository = _OtpAuthRepository(
      userMetadata: const {'display_name': 'Ali Altaraif'},
    );
    var completed = false;

    await _pumpAuthFlow(
      tester,
      repository: repository,
      onCompleted: () => completed = true,
    );
    await _submitPhoneAndOtp(tester);

    expect(repository.verifiedPhone, '+14807469696');
    expect(repository.verifiedToken, '000000');
    expect(find.text('When were you born?'), findsOneWidget);
    expect(find.text('What should we call you?'), findsNothing);
    expect(completed, isFalse);

    await _disposeAuthFlow(tester);
  });

  testWidgets('complete existing user finishes after OTP without onboarding', (
    tester,
  ) async {
    final repository = _OtpAuthRepository(
      userMetadata: const {
        'display_name': 'Ali Altaraif',
        'date_of_birth': '2000-01-01',
      },
    );
    var completionCount = 0;

    await _pumpAuthFlow(
      tester,
      repository: repository,
      onCompleted: () => completionCount++,
    );
    await _submitPhoneAndOtp(tester);

    expect(completionCount, 1);
    expect(find.text('What should we call you?'), findsNothing);
    expect(find.text('When were you born?'), findsNothing);

    await _disposeAuthFlow(tester);
  });
}

Future<void> _pumpAuthFlow(
  WidgetTester tester, {
  required AuthRepository repository,
  required VoidCallback onCompleted,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: AuthFlowScreen(
        authRepository: repository,
        initialStep: AuthStep.phone,
        onOnboardingCompleted: onCompleted,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _submitPhoneAndOtp(WidgetTester tester) async {
  expect(find.text("What's your number?"), findsOneWidget);
  await tester.enterText(find.byType(TextField), '4807469696');
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 500));

  expect(find.text('Enter the code'), findsOneWidget);
  await tester.enterText(find.byType(TextField), '000000');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _disposeAuthFlow(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  expect(tester.takeException(), isNull);
}

class _OtpAuthRepository implements AuthRepository {
  _OtpAuthRepository({required this.userMetadata});

  final Map<String, dynamic> userMetadata;
  Session? _session;
  String? verifiedPhone;
  String? verifiedToken;
  String? sentPhone;

  @override
  Session? get currentSession => _session;

  @override
  User? get currentUser => _session?.user;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  Future<void> sendPhoneOtp(String phone) async {
    sentPhone = phone;
  }

  @override
  Future<void> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {
    verifiedPhone = phone;
    verifiedToken = token;
    const userId = '3f84969a-7c5b-4e98-9a71-dcad98c5d719';
    final user = User(
      id: userId,
      appMetadata: const {},
      userMetadata: userMetadata,
      aud: 'authenticated',
      phone: phone,
      createdAt: '2026-06-07T00:00:00Z',
    );
    _session = Session(
      accessToken: 'test-token',
      refreshToken: 'test-refresh-token',
      tokenType: 'bearer',
      user: user,
    );
  }

  @override
  Future<void> updateDisplayName(String displayName) async {}

  @override
  Future<void> updateDateOfBirth(DateTime dateOfBirth) async {}

  @override
  Future<void> switchToUserForDevelopment(String profileId) async {}

  @override
  Future<void> signOut() async {}
}
