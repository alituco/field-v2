import 'package:field/src/ui/fieldrush_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('message uses the HTML dark text-sized pill above navigation', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(FieldrushToast), findsOneWidget);
    final surface = find.byKey(const ValueKey('fieldrush-toast-surface'));
    final decoration =
        tester.widget<DecoratedBox>(surface).decoration as BoxDecoration;
    expect(decoration.color, const Color(0xFF22301F));
    expect(decoration.borderRadius, BorderRadius.circular(999));
    final textStyle = DefaultTextStyle.of(
      tester.element(find.text('Profile copied')),
    ).style;
    expect(textStyle.fontFamily, 'PlusJakartaSans');
    expect(textStyle.fontSize, 12);
    expect(textStyle.fontWeight, FontWeight.w700);
    expect(textStyle.height, 1.3);
    expect(textStyle.color, Colors.white);
    final rect = tester.getRect(surface);
    expect(rect.width, lessThan(300));
    expect(rect.center.dx, closeTo(195, .1));
    expect(rect.bottom, closeTo(844 - 94, .1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('message expires at the HTML 2200ms duration', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('First'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2199));
    expect(find.text('Profile copied'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(FieldrushToast), findsNothing);
  });

  testWidgets('new messages replace old ones and get their own lifetime', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('First'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.tap(find.text('Second'));
    await tester.pump();
    expect(find.text('Profile copied'), findsNothing);
    expect(find.text('Invite sent'), findsOneWidget);
    expect(find.byType(FieldrushToast), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('Invite sent'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(FieldrushToast), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('success remains visible after its source route closes', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Open route'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save and close'));
    await tester.pumpAndSettle();
    expect(find.text('Save and close'), findsNothing);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.byType(FieldrushToast), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacement before mounting and app disposal cancel safely', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Rapid messages'));
    await tester.pump();
    expect(find.text('First rapid'), findsNothing);
    expect(find.text('Second rapid'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long enlarged text wraps above the keyboard and announces', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, scale: 2, inset: 340, safeBottom: 20);
    await tester.tap(find.text('Long message'));
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('fieldrush-toast-surface'));
    final rect = tester.getRect(surface);
    expect(rect.width, lessThanOrEqualTo(300));
    expect(rect.bottom, lessThanOrEqualTo(844 - 340 - 16));
    expect(rect.top, greaterThanOrEqualTo(0));
    final toastSemantics = tester.getSemantics(find.byType(FieldrushToast));
    expect(
      toastSemantics.getSemanticsData().flagsCollection.isLiveRegion,
      isTrue,
    );
    expect(find.textContaining('Do not pay again.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('reduced motion keeps the toast static and non-blocking', (
    tester,
  ) async {
    await _pump(tester, reducedMotion: true);
    await tester.tap(find.text('First'));
    await tester.pump();
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byType(FieldrushToast),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, 1);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    final ignore = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byType(FieldrushToast),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(ignore.ignoring, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('structured notice preserves its content, duration and action', (
    tester,
  ) async {
    var actions = 0;
    await _pump(tester, onAcknowledge: () => actions++);
    await tester.tap(find.text('Notice'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Account notice'), findsOneWidget);
    expect(find.text('Important account details'), findsOneWidget);
    await tester.tap(find.text('GOT IT'));
    await tester.pump();
    expect(actions, 1);
    expect(find.byType(FieldrushToast), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short phones cap large messages and allow scrolling', (
    tester,
  ) async {
    await _pump(tester, scale: 3, inset: 300, height: 568, width: 320);
    await tester.ensureVisible(find.text('Long message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long message'));
    await tester.pumpAndSettle();
    final toast = find.byType(FieldrushToast);
    final rect = tester.getRect(
      find.byKey(const ValueKey('fieldrush-toast-surface')),
    );
    expect(rect.top, greaterThanOrEqualTo(16));
    expect(rect.bottom, lessThanOrEqualTo(568 - 300 - 16));
    final scroller = find.descendant(
      of: toast,
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scroller).position.maxScrollExtent,
      greaterThan(0),
    );
    final ignore = tester.widget<IgnorePointer>(
      find.ancestor(of: toast, matching: find.byType(IgnorePointer)).first,
    );
    expect(ignore.ignoring, isFalse);
    await tester.drag(scroller, const Offset(0, -80));
    await tester.pump();
    expect(
      tester.state<ScrollableState>(scroller).position.pixels,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short-phone structured notice keeps acknowledgement reachable', (
    tester,
  ) async {
    var acknowledgements = 0;
    await _pump(
      tester,
      scale: 3,
      inset: 300,
      height: 568,
      width: 320,
      onAcknowledge: () => acknowledgements++,
    );
    await tester.ensureVisible(find.text('Notice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notice'));
    await tester.pumpAndSettle();
    final surface = tester.getRect(
      find.byKey(const ValueKey('fieldrush-toast-surface')),
    );
    final action = tester.getRect(
      find.byKey(const ValueKey('fieldrush-toast-action')),
    );
    expect(surface.top, greaterThanOrEqualTo(16));
    expect(surface.bottom, lessThanOrEqualTo(568 - 300 - 16));
    expect(action.width, greaterThanOrEqualTo(44));
    expect(action.height, greaterThanOrEqualTo(44));
    expect(action.bottom, lessThanOrEqualTo(surface.bottom));
    await tester.tap(find.text('GOT IT'));
    await tester.pump();
    expect(acknowledgements, 1);
    expect(find.byType(FieldrushToast), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen-reader action notice stays until acknowledged', (
    tester,
  ) async {
    await _pump(tester, accessibleNavigation: true);
    await tester.tap(find.text('Notice'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('GOT IT'), findsOneWidget);
    await tester.tap(find.text('GOT IT'));
    await tester.pump();
    expect(find.byType(FieldrushToast), findsNothing);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  double scale = 1,
  double inset = 0,
  double safeBottom = 0,
  double width = 390,
  double height = 844,
  bool reducedMotion = false,
  bool accessibleNavigation = false,
  VoidCallback? onAcknowledge,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: Size(width, height),
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: inset),
          padding: EdgeInsets.only(bottom: safeBottom),
          disableAnimations: reducedMotion,
          accessibleNavigation: accessibleNavigation,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                TextButton(
                  onPressed: () =>
                      showFieldrushToast(context, 'Profile copied'),
                  child: const Text('First'),
                ),
                TextButton(
                  onPressed: () => showFieldrushToast(context, 'Invite sent'),
                  child: const Text('Second'),
                ),
                TextButton(
                  onPressed: () {
                    showFieldrushToast(context, 'First rapid');
                    showFieldrushToast(context, 'Second rapid');
                  },
                  child: const Text('Rapid messages'),
                ),
                TextButton(
                  onPressed: () => showFieldrushToast(
                    context,
                    'Your payment was received. Support is resolving the refund. Do not pay again.',
                  ),
                  child: const Text('Long message'),
                ),
                TextButton(
                  onPressed: () => showFieldrushToastContent(
                    context,
                    const Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.white),
                        SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Account notice'),
                              Text('Important account details'),
                            ],
                          ),
                        ),
                      ],
                    ),
                    duration: const Duration(seconds: 8),
                    actionLabel: 'GOT IT',
                    onAction: onAcknowledge ?? () {},
                  ),
                  child: const Text('Notice'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (routeContext) => Scaffold(
                        body: TextButton(
                          onPressed: () {
                            showFieldrushToast(routeContext, 'Saved');
                            Navigator.of(routeContext).pop();
                          },
                          child: const Text('Save and close'),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('Open route'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
