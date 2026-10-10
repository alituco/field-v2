import 'package:field/src/home/field_bottom_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('liquid glass dock preserves all five navigation actions', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    int? tappedIndex;

    await _pumpNav(
      tester,
      selectedIndex: 1,
      onSelected: (index) => tappedIndex = index,
    );

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      find.byKey(const ValueKey('field-liquid-glass-nav')),
      findsOneWidget,
    );
    for (final label in ['Home', 'Fixtures', 'Clans', 'Ranks', 'You']) {
      expect(find.text(label), findsOneWidget);
    }

    final fixturesSemantics = tester.widgetList<Semantics>(
      find.ancestor(
        of: find.byKey(const ValueKey('field-bottom-nav-item-1')),
        matching: find.byType(Semantics),
      ),
    );
    expect(
      fixturesSemantics.any((widget) => widget.properties.selected == true),
      isTrue,
    );

    final selection = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('field-liquid-glass-selection')),
    );
    expect(
      (selection.decoration as BoxDecoration).color,
      const Color(0xFF386641),
    );

    await tester.tap(find.byKey(const ValueKey('field-bottom-nav-item-4')));
    await tester.pump();
    expect(tappedIndex, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass dock respects small phones and the home indicator', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    await _pumpNav(tester, selectedIndex: 0, onSelected: (_) {});

    final dock = find.byKey(const ValueKey('field-liquid-glass-nav'));
    expect(tester.getSize(dock).width, 294);
    expect(tester.getSize(dock).height, greaterThanOrEqualTo(64));
    expect(tester.getBottomRight(dock).dy, 568 - 34);
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass dock gets out of the way of the keyboard', (tester) async {
    await _setPhoneSize(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);

    await _pumpNav(tester, selectedIndex: 2, onSelected: (_) {});

    expect(find.byKey(const ValueKey('field-liquid-glass-nav')), findsNothing);
  });
}

Future<void> _setPhoneSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpNav(
  WidgetTester tester, {
  required int? selectedIndex,
  required ValueChanged<int> onSelected,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        extendBody: true,
        body: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFE0F2FE), Color(0xFFDCFCE7)],
            ),
          ),
          child: SizedBox.expand(),
        ),
        bottomNavigationBar: FieldBottomNav(
          selectedIndex: selectedIndex,
          onSelected: onSelected,
        ),
      ),
    ),
  );
}
