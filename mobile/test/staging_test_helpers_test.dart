import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/helpers/staging_test_helpers.dart';

void main() {
  testWidgets('tapWhenVisible waits for an incoming route to be hit-testable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final navigator = GlobalKey<NavigatorState>();
    var taps = 0;
    const target = ValueKey('incoming-route-target');

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    navigator.currentState!.push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 750),
        pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FilledButton(
              key: target,
              onPressed: () => taps++,
              child: const Text('Choose solo'),
            ),
          ),
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(target), findsOneWidget);
    expect(find.byKey(target).hitTestable(), findsNothing);
    await tapWhenVisible(tester, find.byKey(target));

    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapAfterScroll resolves a rebuilt target after scrolling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final layout = ValueNotifier<bool>(false);
    addTearDown(layout.dispose);
    var originalTaps = 0;
    var replacementTaps = 0;
    const target = ValueKey('scroll-target');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: layout,
            builder: (context, changed, child) => ListView(
              children: [
                SizedBox(height: changed ? 1400 : 1100),
                FilledButton(
                  key: target,
                  onPressed: () {
                    if (changed) {
                      replacementTaps++;
                    } else {
                      originalTaps++;
                    }
                  },
                  child: Text(
                    changed ? 'Replacement action' : 'Original action',
                  ),
                ),
                const SizedBox(height: 300),
              ],
            ),
          ),
        ),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => layout.value = true);

    await tapAfterScroll(tester, find.byKey(target));

    expect(originalTaps, 0);
    expect(replacementTaps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapWhenVisible fails within its budget for an obscured target', (
    tester,
  ) async {
    var taps = 0;
    const target = ValueKey('obscured-target');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Center(
                child: FilledButton(
                  key: target,
                  onPressed: () => taps++,
                  child: const Text('Do not tap'),
                ),
              ),
              const Positioned.fill(child: ColoredBox(color: Colors.black)),
            ],
          ),
        ),
      ),
    );

    await expectLater(
      tapWhenVisible(
        tester,
        find.byKey(target),
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TestFailure>()),
    );
    expect(taps, 0);
    expect(tester.takeException(), isNull);
  });
}
