import 'package:field/src/auth/auth_flow_screen.dart';
import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/auth/date_of_birth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('player eligibility uses the exact eighteenth birthday', () {
    final today = DateTime(2026, 7, 14);

    expect(isEligibleDateOfBirth(DateTime(2008, 7, 14), today: today), isTrue);
    expect(isEligibleDateOfBirth(DateTime(2008, 7, 15), today: today), isFalse);
    expect(dateOfBirthToIso(DateTime(2002, 3, 9)), '2002-03-09');
  });

  test('DOB parsing rejects calendar overflow and unsupported dates', () {
    expect(parseDateOfBirth('2000-02-30'), isNull);
    expect(parseDateOfBirth('2001-02-29'), isNull);
    expect(parseDateOfBirth('2000-13-01'), isNull);
    expect(parseDateOfBirth('1899-01-01'), isNull);
    expect(parseDateOfBirth('2000-02-29'), DateTime(2000, 2, 29));
    expect(isEligibleDateOfBirth(DateTime(1800, 1, 1)), isFalse);
    expect(
      latestEligibleDateOfBirth(today: DateTime(2028, 2, 29)),
      DateTime(2010, 2, 28),
    );
  });

  testWidgets('DOB is required as the final onboarding step', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _FakeAuthRepository();
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: AuthFlowScreen(
          authRepository: repository,
          initialStep: AuthStep.dateOfBirth,
          onOnboardingCompleted: () => completed = true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('When were you born?'), findsOneWidget);
    expect(find.text('Choose your birthday'), findsOneWidget);
    expect(find.textContaining('18 or older'), findsOneWidget);

    await tester.tap(find.text('FINISH SETUP'));
    await tester.pump();
    expect(repository.savedDateOfBirth, isNull);
    expect(completed, isFalse);

    await tester.tap(find.byKey(const ValueKey('date-of-birth-selector')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DatePickerDialog), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Choose your birthday'), findsNothing);
    await tester.tap(find.text('FINISH SETUP'));
    await tester.pump();

    expect(repository.savedDateOfBirth, isNotNull);
    expect(isEligibleDateOfBirth(repository.savedDateOfBirth!), isTrue);
    expect(completed, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

class _FakeAuthRepository implements AuthRepository {
  DateTime? savedDateOfBirth;

  @override
  Session? get currentSession => null;

  @override
  User? get currentUser => null;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  Future<void> sendPhoneOtp(String phone) async {}

  @override
  Future<void> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {}

  @override
  Future<void> updateDisplayName(String displayName) async {}

  @override
  Future<void> updateDateOfBirth(DateTime dateOfBirth) async {
    savedDateOfBirth = dateOfBirth;
  }

  @override
  Future<void> switchToUserForDevelopment(String profileId) async {}

  @override
  Future<void> signOut() async {}
}
