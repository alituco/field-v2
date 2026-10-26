import 'package:field/src/legal/fieldrush_policy_links.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

void main() {
  late _Launcher launcher;
  late UrlLauncherPlatform previous;

  setUp(() {
    previous = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher = _Launcher();
  });
  tearDown(() => UrlLauncherPlatform.instance = previous);

  Future<void> show(WidgetTester tester, Widget notice) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: notice)));

  Future<void> openLink(WidgetTester tester, String label) async {
    final text = tester.widget<Text>(find.byType(Text).first);
    final span = (text.textSpan! as TextSpan).children!
        .whereType<TextSpan>()
        .singleWhere((span) => span.text == label);
    (span.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();
  }

  testWidgets('signup links open the specified public documents', (
    tester,
  ) async {
    await show(
      tester,
      const FieldrushSignupPolicyNotice(creatingAccount: true),
    );
    expect(find.byType(Checkbox), findsNothing);
    await openLink(tester, 'Terms');
    await openLink(tester, 'Privacy Policy');
    expect(launcher.urls, [
      'https://fieldrush.gg/terms',
      'https://fieldrush.gg/privacy',
    ]);
    expect(
      launcher.modes,
      everyElement(PreferredLaunchMode.externalApplication),
    );
  });

  testWidgets(
    'booking links work without accepting or creating a reservation',
    (tester) async {
      await show(tester, const FieldrushBookingPolicyNotice());
      final text = tester.widget<Text>(
        find.byKey(const Key('fieldrush-booking-agreement')),
      );
      expect(
        text.textSpan!.toPlainText(),
        'By paying, you accept the Participation terms and Recording policy. '
        'Games are filmed and streamed.',
      );
      expect(find.byType(Checkbox), findsNothing);
      await openLink(tester, 'Participation terms');
      await openLink(tester, 'Recording policy');
      expect(launcher.urls, [
        'https://fieldrush.gg/participation',
        'https://fieldrush.gg/recording',
      ]);
    },
  );

  testWidgets('free booking uses accurate action wording', (tester) async {
    await show(tester, const FieldrushBookingPolicyNotice(freeBooking: true));
    expect(
      tester
          .widget<Text>(find.byKey(const Key('fieldrush-booking-agreement')))
          .textSpan!
          .toPlainText(),
      startsWith('By booking, you accept'),
    );
  });

  testWidgets('refund notice states every cutoff and opens the refund policy', (
    tester,
  ) async {
    await show(tester, const FieldrushRefundPolicyNotice());
    final text = tester.widget<Text>(
      find.byKey(const Key('fieldrush-refund-policy-notice')),
    );
    expect(
      text.textSpan!.toPlainText(),
      'Full refund 24+ hours before kickoff; 50% from 10 to under '
      '24 hours; none under 10 hours. Refund policy',
    );
    expect(find.byType(Checkbox), findsNothing);
    await openLink(tester, 'Refund policy');
    expect(launcher.urls, ['https://fieldrush.gg/refunds']);
  });

  testWidgets(
    'failed link launch leaves the current screen and shows the URL',
    (tester) async {
      launcher.succeeds = false;
      await show(tester, const FieldrushBookingPolicyNotice());
      await openLink(tester, 'Recording policy');
      expect(find.byType(FieldrushBookingPolicyNotice), findsOneWidget);
      expect(
        find.text(
          'Could not open https://fieldrush.gg/recording. Please try again.',
        ),
        findsOneWidget,
      );
    },
  );
}

class _Launcher extends UrlLauncherPlatform {
  final urls = <String>[];
  final modes = <PreferredLaunchMode>[];
  bool succeeds = true;

  @override
  Null get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    urls.add(url);
    modes.add(options.mode);
    return succeeds;
  }
}
