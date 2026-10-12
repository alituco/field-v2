import 'dart:ui' as ui;

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
    final labels = ['Home', 'Fixtures', 'Clans', 'Ranks', 'You'];
    for (var index = 0; index < labels.length; index++) {
      expect(find.text(labels[index]), findsNothing);
      final item = find.byKey(ValueKey('field-bottom-nav-item-$index'));
      expect(tester.getSize(item).height, 48);
      expect(tester.getSize(item).width, greaterThan(50));
      expect(
        tester.getSize(find.byKey(ValueKey('field-bottom-nav-icon-$index'))),
        const Size(32, 32),
      );
      final labelsForItem = tester.widgetList<Semantics>(
        find.ancestor(of: item, matching: find.byType(Semantics)),
      );
      expect(
        labelsForItem.any(
          (semantics) =>
              semantics.properties.label == labels[index] &&
              semantics.properties.onTap != null,
        ),
        isTrue,
      );
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

    final selection = tester.widget<Container>(
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
    expect(tester.getSize(dock), const Size(280, 56));
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

  testWidgets('iOS hold and slide previews tabs and commits only on release', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final selected = <int>[];
    await _pumpNav(
      tester,
      selectedIndex: 1,
      platform: TargetPlatform.iOS,
      onSelected: selected.add,
    );
    final initialSelection = tester.getCenter(
      find.byKey(const ValueKey('field-liquid-glass-selection')),
    );
    final gesture = await tester.startGesture(_tabCenter(tester, 1));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(_tabCenter(tester, 2));
    await tester.pump();
    await gesture.moveTo(_tabCenter(tester, 4));
    await tester.pump();
    expect(selected, isEmpty);
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('field-liquid-glass-selection')))
          .dx,
      closeTo(_tabCenter(tester, 4).dx, .1),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, [4]);
    // The parent still owns selection. A rejected leave prompt restores it.
    expect(
      tester.getCenter(
        find.byKey(const ValueKey('field-liquid-glass-selection')),
      ),
      initialSelection,
    );
  });

  testWidgets(
    'iOS direct swipe commits once and cancelled holds do not leave',
    (tester) async {
      await _setPhoneSize(tester);
      final selected = <int>[];
      await _pumpNav(
        tester,
        selectedIndex: 0,
        platform: TargetPlatform.iOS,
        onSelected: selected.add,
      );
      await tester.dragFrom(
        _tabCenter(tester, 0),
        _tabCenter(tester, 3) - _tabCenter(tester, 0),
      );
      await tester.pumpAndSettle();
      expect(selected, [3]);
      selected.clear();
      final gesture = await tester.startGesture(_tabCenter(tester, 0));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(_tabCenter(tester, 4) - const Offset(0, 100));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected, isEmpty);

      final cancelled = await tester.startGesture(_tabCenter(tester, 0));
      await tester.pump(const Duration(milliseconds: 600));
      await cancelled.moveTo(_tabCenter(tester, 2));
      await tester.pump();
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
    },
  );

  testWidgets('You uses the photo while Home keeps its existing icon', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    const avatar = 'https://example.test/avatar.png';
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.green, BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(32, 32);
    picture.dispose();
    PaintingBinding.instance.imageCache.putIfAbsent(
      const NetworkImage(avatar),
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image))),
    );
    addTearDown(PaintingBinding.instance.imageCache.clear);
    int? selected;
    await _pumpNav(
      tester,
      selectedIndex: 0,
      profileAvatarUrl: avatar,
      onSelected: (index) => selected = index,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('field-you-nav-avatar')), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byType(ClipOval), findsOneWidget);
    final home = find.byKey(const ValueKey('field-bottom-nav-icon-0'));
    expect(
      find.descendant(of: home, matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: home, matching: find.byType(Image)),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('field-you-nav-avatar')));
    expect(selected, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing or broken photo keeps the existing You icon', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    await _pumpNav(
      tester,
      selectedIndex: 0,
      profileAvatarUrl: '  ',
      onSelected: (_) {},
    );
    expect(find.byKey(const ValueKey('field-you-nav-avatar')), findsNothing);
    final you = find.byKey(const ValueKey('field-bottom-nav-icon-4'));
    expect(
      find.descendant(of: you, matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
    await _pumpNav(
      tester,
      selectedIndex: 0,
      profileAvatarUrl: 'https://example.test/missing.png',
      onSelected: (_) {},
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: you, matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Offset _tabCenter(WidgetTester tester, int index) =>
    tester.getCenter(find.byKey(ValueKey('field-bottom-nav-item-$index')));

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
  TargetPlatform platform = TargetPlatform.android,
  String? profileAvatarUrl,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
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
          profileAvatarUrl: profileAvatarUrl,
        ),
      ),
    ),
  );
}
