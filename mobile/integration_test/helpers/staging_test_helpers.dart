import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class StagingE2EConfig {
  const StagingE2EConfig({
    required this.mainPhone,
    required this.partyTargetPhone,
    required this.partyTargetProfileId,
    required this.adminPhone,
    required this.onboardingPhone,
    required this.password,
    required this.runId,
    required this.matchGameId,
    required this.cancellationGameId,
    required this.supportDetails,
    required this.reportDetails,
    required this.bootstrapPhone,
    required this.devOtpCode,
  });

  factory StagingE2EConfig.fromEnvironment() {
    const mainPhone = String.fromEnvironment('E2E_MAIN_PHONE');
    const partyTargetPhone = String.fromEnvironment('E2E_PARTY_TARGET_PHONE');
    const partyTargetProfileId = String.fromEnvironment(
      'E2E_PARTY_TARGET_PROFILE_ID',
    );
    const adminPhone = String.fromEnvironment('E2E_ADMIN_PHONE');
    const onboardingPhone = String.fromEnvironment('E2E_ONBOARDING_PHONE');
    const password = String.fromEnvironment('E2E_TEST_PASSWORD');
    const runId = String.fromEnvironment('E2E_RUN_ID');
    const matchGameId = String.fromEnvironment('E2E_MATCH_GAME_ID');
    const cancellationGameId = String.fromEnvironment(
      'E2E_CANCELLATION_GAME_ID',
    );
    const bootstrapPhone = String.fromEnvironment(
      'E2E_BOOTSTRAP_PHONE',
      defaultValue: '+97338883672',
    );
    const devOtpCode = String.fromEnvironment(
      'E2E_DEV_OTP_CODE',
      defaultValue: '000000',
    );
    const supportDetails = String.fromEnvironment('E2E_SUPPORT_DETAILS');
    const reportDetails = String.fromEnvironment('E2E_REPORT_DETAILS');

    return StagingE2EConfig(
      mainPhone: mainPhone,
      partyTargetPhone: partyTargetPhone,
      partyTargetProfileId: partyTargetProfileId,
      adminPhone: adminPhone,
      onboardingPhone: onboardingPhone,
      password: password,
      runId: runId,
      matchGameId: matchGameId,
      cancellationGameId: cancellationGameId,
      supportDetails: supportDetails,
      reportDetails: reportDetails,
      bootstrapPhone: bootstrapPhone,
      devOtpCode: devOtpCode,
    );
  }

  final String mainPhone;
  final String partyTargetPhone;
  final String partyTargetProfileId;
  final String adminPhone;
  final String onboardingPhone;
  final String password;
  final String runId;
  final String matchGameId;
  final String cancellationGameId;
  final String supportDetails;
  final String reportDetails;
  final String bootstrapPhone;
  final String devOtpCode;

  void validate() {
    final missing = <String>[
      if (mainPhone.trim().isEmpty) 'E2E_MAIN_PHONE',
      if (partyTargetPhone.trim().isEmpty) 'E2E_PARTY_TARGET_PHONE',
      if (partyTargetProfileId.trim().isEmpty) 'E2E_PARTY_TARGET_PROFILE_ID',
      if (adminPhone.trim().isEmpty) 'E2E_ADMIN_PHONE',
      if (onboardingPhone.trim().isEmpty) 'E2E_ONBOARDING_PHONE',
      if (password.isEmpty) 'E2E_TEST_PASSWORD',
      if (runId.trim().isEmpty) 'E2E_RUN_ID',
      if (matchGameId.trim().isEmpty) 'E2E_MATCH_GAME_ID',
      if (cancellationGameId.trim().isEmpty) 'E2E_CANCELLATION_GAME_ID',
      if (supportDetails.trim().isEmpty) 'E2E_SUPPORT_DETAILS',
      if (reportDetails.trim().isEmpty) 'E2E_REPORT_DETAILS',
    ];
    if (missing.isNotEmpty) {
      throw TestFailure(
        'Missing required staging E2E dart-defines: ${missing.join(', ')}.',
      );
    }
    if (devOtpCode.length != 6) {
      throw TestFailure(
        'E2E_DEV_OTP_CODE must contain the six-digit staging test OTP.',
      );
    }
    if (supportDetails.trim().length < 10 || reportDetails.trim().length < 10) {
      throw TestFailure(
        'E2E support and moderation markers must be at least 10 characters.',
      );
    }
    for (final entry in <String, String>{
      'E2E_MAIN_PHONE': mainPhone,
      'E2E_PARTY_TARGET_PHONE': partyTargetPhone,
      'E2E_ADMIN_PHONE': adminPhone,
      'E2E_ONBOARDING_PHONE': onboardingPhone,
      'E2E_BOOTSTRAP_PHONE': bootstrapPhone,
    }.entries) {
      _validateBahrainPhone(entry.key, entry.value);
    }
  }

  String get bahrainBootstrapLocalNumber {
    final digits = bootstrapPhone.replaceAll(RegExp(r'\D'), '');
    return digits.substring(3);
  }

  static void _validateBahrainPhone(String name, String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (!digits.startsWith('973') || digits.length != 11) {
      throw TestFailure(
        '$name must be a Bahrain number in +973XXXXXXXX format.',
      );
    }
  }
}

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 25),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (finder.evaluate().isEmpty) {
    throw TestFailure(reason ?? 'Timed out waiting for the expected widget.');
  }
}

Future<void> pumpUntilAbsent(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 25),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isNotEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (finder.evaluate().isNotEmpty) {
    throw TestFailure(
      reason ?? 'Timed out waiting for the widget to disappear.',
    );
  }
}

Future<Finder> pumpUntilAny(
  WidgetTester tester,
  List<Finder> finders, {
  Duration timeout = const Duration(seconds: 25),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    for (final finder in finders) {
      if (finder.evaluate().isNotEmpty) return finder;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  throw TestFailure(reason ?? 'Timed out waiting for an expected screen.');
}

Future<void> tapWhenVisible(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 25),
  String? reason,
}) async {
  await pumpUntilFound(tester, finder, timeout: timeout, reason: reason);
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(finder);
  await tester.pump();
}

Future<void> scrollUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxScrolls = 18,
  double delta = 420,
  String? reason,
}) async {
  for (var attempt = 0; attempt <= maxScrolls; attempt++) {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder);
      await tester.pump(const Duration(milliseconds: 200));
      return;
    }
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isEmpty) break;

    Finder? scrollTarget;
    final candidateCount = scrollables.evaluate().length;
    for (var index = candidateCount - 1; index >= 0; index--) {
      final candidate = scrollables.at(index);
      final state = tester.state<ScrollableState>(candidate);
      final position = state.position;
      if (position.axis == Axis.vertical &&
          position.pixels < position.maxScrollExtent - 0.5) {
        scrollTarget = candidate;
        break;
      }
    }
    if (scrollTarget == null) {
      // Lists can still be loading their first page. Pump without dragging a
      // zero-range PageView/Scrollable, then inspect the layout again.
      await tester.pump(const Duration(milliseconds: 220));
      continue;
    }
    await tester.drag(
      scrollTarget,
      Offset(0, -delta),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 220));
  }
  throw TestFailure(reason ?? 'Could not scroll to the expected widget.');
}

Future<void> tapAfterScroll(
  WidgetTester tester,
  Finder finder, {
  int maxScrolls = 18,
  String? reason,
}) async {
  await scrollUntilFound(
    tester,
    finder,
    maxScrolls: maxScrolls,
    reason: reason,
  );
  await tester.tap(finder);
  await tester.pump();
}
