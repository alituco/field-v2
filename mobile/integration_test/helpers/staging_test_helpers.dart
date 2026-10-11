import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hosted journeys must never present a real-charge checkout. The application
/// and server still validate the run-scoped, staging-only bypass independently.
void validateHostedPaymentBypass() {
  const environment = String.fromEnvironment('APP_ENV');
  const bypass = bool.fromEnvironment('FIELD_E2E_PAYMENT_BYPASS');
  const runId = String.fromEnvironment('E2E_RUN_ID');
  if (environment != 'staging' || !bypass || runId.trim().isEmpty) {
    throw TestFailure(
      'Hosted player journeys require APP_ENV=staging, '
      'FIELD_E2E_PAYMENT_BYPASS=true, and an isolated E2E_RUN_ID. '
      'Refusing to execute a real-payment journey.',
    );
  }
}

class StagingE2EConfig {
  const StagingE2EConfig({
    required this.mainPhone,
    required this.mainProfileId,
    required this.partyTargetPhone,
    required this.partyTargetProfileId,
    required this.adminPhone,
    required this.onboardingPhone,
    required this.onboardingProfileId,
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
    const mainProfileId = String.fromEnvironment('E2E_MAIN_PROFILE_ID');
    const partyTargetPhone = String.fromEnvironment('E2E_PARTY_TARGET_PHONE');
    const partyTargetProfileId = String.fromEnvironment(
      'E2E_PARTY_TARGET_PROFILE_ID',
    );
    const adminPhone = String.fromEnvironment('E2E_ADMIN_PHONE');
    const onboardingPhone = String.fromEnvironment('E2E_ONBOARDING_PHONE');
    const onboardingProfileId = String.fromEnvironment(
      'E2E_ONBOARDING_PROFILE_ID',
    );
    const password = String.fromEnvironment('E2E_TEST_PASSWORD');
    const runId = String.fromEnvironment('E2E_RUN_ID');
    const matchGameId = String.fromEnvironment('E2E_MATCH_GAME_ID');
    const cancellationGameId = String.fromEnvironment(
      'E2E_CANCELLATION_GAME_ID',
    );
    const bootstrapPhone = String.fromEnvironment(
      'E2E_BOOTSTRAP_PHONE',
      defaultValue: '+97339009098',
    );
    const devOtpCode = String.fromEnvironment(
      'E2E_DEV_OTP_CODE',
      defaultValue: '000000',
    );
    const supportDetails = String.fromEnvironment('E2E_SUPPORT_DETAILS');
    const reportDetails = String.fromEnvironment('E2E_REPORT_DETAILS');

    return StagingE2EConfig(
      mainPhone: mainPhone,
      mainProfileId: mainProfileId,
      partyTargetPhone: partyTargetPhone,
      partyTargetProfileId: partyTargetProfileId,
      adminPhone: adminPhone,
      onboardingPhone: onboardingPhone,
      onboardingProfileId: onboardingProfileId,
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
  final String mainProfileId;
  final String partyTargetPhone;
  final String partyTargetProfileId;
  final String adminPhone;
  final String onboardingPhone;
  final String onboardingProfileId;
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
      if (mainProfileId.trim().isEmpty) 'E2E_MAIN_PROFILE_ID',
      if (partyTargetPhone.trim().isEmpty) 'E2E_PARTY_TARGET_PHONE',
      if (partyTargetProfileId.trim().isEmpty) 'E2E_PARTY_TARGET_PROFILE_ID',
      if (adminPhone.trim().isEmpty) 'E2E_ADMIN_PHONE',
      if (onboardingPhone.trim().isEmpty) 'E2E_ONBOARDING_PHONE',
      if (onboardingProfileId.trim().isEmpty) 'E2E_ONBOARDING_PROFILE_ID',
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
  await _tapWhenHittable(tester, finder, timeout: timeout, reason: reason);
}

Future<void> scrollUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxScrolls = 18,
  double delta = 420,
  Duration timeout = const Duration(seconds: 25),
  String? reason,
}) async {
  const interval = Duration(milliseconds: 220);
  final deadline = DateTime.now().add(timeout);
  var pumpedTime = Duration.zero;
  var scrollCount = 0;
  var resetToStart = false;
  var rescannedAfterLayoutChange = false;
  ScrollPosition? trackedPosition;
  double? previousMaxExtent;
  var scanFinished = false;
  while (DateTime.now().isBefore(deadline) && pumpedTime < timeout) {
    if (finder.evaluate().isNotEmpty) {
      await _centerInScrollable(tester, finder);
      // Centering pumps a frame. Async booking/party refreshes can rebuild a
      // lazy list during that frame and briefly remove the element that was
      // just found. Only return once the target still exists after centering;
      // otherwise continue the bounded scan and resolve the rebuilt widget.
      if (finder.evaluate().isNotEmpty) return;
    } else {
      final scrollables = find.byType(Scrollable);
      Finder? scrollTarget;
      final candidateCount = scrollables.evaluate().length;
      for (var index = candidateCount - 1; index >= 0; index--) {
        final candidate = scrollables.at(index);
        final position = tester.state<ScrollableState>(candidate).position;
        if (position.axis == Axis.vertical &&
            (position.pixels > position.minScrollExtent + 0.5 ||
                position.pixels < position.maxScrollExtent - 0.5)) {
          scrollTarget = candidate;
          break;
        }
      }
      if (scrollTarget != null) {
        final position = tester.state<ScrollableState>(scrollTarget).position;
        final extentChanged =
            identical(position, trackedPosition) &&
            previousMaxExtent != null &&
            (position.maxScrollExtent - previousMaxExtent).abs() > 0.5;
        trackedPosition = position;
        previousMaxExtent = position.maxScrollExtent;
        if (scanFinished &&
            extentChanged &&
            !rescannedAfterLayoutChange &&
            position.pixels > position.minScrollExtent + 0.5) {
          // Async content may appear above the viewport after a lazy-list scan
          // has finished. Rescan once when its extent actually changes, keeping
          // the same overall time and physical-drag budgets.
          position.jumpTo(position.minScrollExtent);
          rescannedAfterLayoutChange = true;
          scanFinished = false;
        } else if (!resetToStart &&
            position.pixels > position.minScrollExtent + 0.5) {
          // A prior action may have left a lazy ListView below a target that is
          // no longer built. Start one deterministic top-to-bottom scan so this
          // helper can find content in either direction.
          position.jumpTo(position.minScrollExtent);
          resetToStart = true;
        } else {
          resetToStart = true;
          if (scrollCount < maxScrolls &&
              position.pixels < position.maxScrollExtent - 0.5) {
            await tester.drag(
              scrollTarget,
              Offset(0, -delta),
              warnIfMissed: false,
            );
            scrollCount++;
          }
        }
        scanFinished =
            scrollCount >= maxScrolls ||
            position.pixels >= position.maxScrollExtent - 0.5;
      }
    }

    // Readiness polling is not a scroll attempt. A pending server action may
    // replace a card long after this scan reaches its boundary, or before any
    // scroll range exists. Keep waiting within the time budget without spending
    // the physical-drag budget on loading frames.
    final remaining = timeout - pumpedTime;
    final pause = remaining < interval ? remaining : interval;
    await tester.pump(pause);
    pumpedTime += pause;
  }
  _reportUiWaitFailure();
  throw TestFailure(reason ?? 'Could not scroll to the expected widget.');
}

Future<void> _centerInScrollable(WidgetTester tester, Finder finder) async {
  final elements = finder.evaluate();
  if (elements.isEmpty) return;
  final element = elements.first;
  // Integration tests drive Flutter frames manually. Awaiting an animated
  // ensureVisible before pumping a frame deadlocks whenever scrolling is
  // actually required, so center the target synchronously instead.
  await Scrollable.ensureVisible(
    element,
    alignment: 0.5,
    duration: Duration.zero,
  );
  await tester.pump();
}

Future<void> tapAfterScroll(
  WidgetTester tester,
  Finder finder, {
  int maxScrolls = 18,
  Duration timeout = const Duration(seconds: 25),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  await scrollUntilFound(
    tester,
    finder,
    maxScrolls: maxScrolls,
    timeout: timeout,
    reason: reason,
  );
  await _tapWhenHittable(
    tester,
    finder,
    timeout: deadline.difference(DateTime.now()),
    reason: reason,
  );
}

Future<void> _tapWhenHittable(
  WidgetTester tester,
  Finder finder, {
  required Duration timeout,
  String? reason,
}) async {
  const interval = Duration(milliseconds: 100);
  final deadline = DateTime.now().add(timeout);
  var pumpedTime = Duration.zero;

  // A route can have built its controls while a slide transition still places
  // them outside the screen. Async list refreshes can also replace a target
  // after ensureVisible. Re-resolve and hit-test the live layout on each frame;
  // never tap geometry captured before the frame or wait for every animation.
  while (DateTime.now().isBefore(deadline) && pumpedTime < timeout) {
    if (finder.evaluate().isNotEmpty) {
      await _centerInScrollable(tester, finder);
      final hittable = finder.hitTestable();
      if (hittable.evaluate().isNotEmpty) {
        final center = tester.getCenter(hittable.first);
        await tester.tapAt(center);
        await tester.pump();
        return;
      }
    }
    await tester.pump(interval);
    pumpedTime += interval;
  }
  throw TestFailure(
    reason ?? 'Timed out waiting for the expected widget to become tappable.',
  );
}

void _reportUiWaitFailure() {
  // Fixture-only UI labels help diagnose a failed action without dumping
  // editable fields, auth sessions, or the entire widget tree.
  final labels = find
      .byType(Text)
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .whereType<String>()
      .take(40)
      .map(
        (label) => label.length > 160 ? '${label.substring(0, 160)}…' : label,
      );
  debugPrint('[FIELD_E2E] UI wait failed; labels: ${labels.join(' | ')}');
}
