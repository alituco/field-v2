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
    await tester.pumpAndSettle();
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
      tester
          .getCenter(find.byKey(const ValueKey('field-liquid-glass-selection')))
          .dx,
      closeTo(initialSelection.dx, .1),
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

  testWidgets('accepted iOS release settles on the requested tab once', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final selected = <int>[];
    await _pumpNav(
      tester,
      selectedIndex: 0,
      platform: TargetPlatform.iOS,
      acceptSelection: true,
      onSelected: selected.add,
    );
    final gesture = await tester.startGesture(_tabCenter(tester, 0));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(_tabCenter(tester, 2));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveTo(_tabCenter(tester, 4));
    await tester.pump(const Duration(milliseconds: 40));
    expect(selected, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, [4]);
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('field-liquid-glass-selection')))
          .dx,
      closeTo(_tabCenter(tester, 4).dx, .1),
    );
    final youSemantics = tester.widgetList<Semantics>(
      find.ancestor(
        of: find.byKey(const ValueKey('field-bottom-nav-item-4')),
        matching: find.byType(Semantics),
      ),
    );
    expect(
      youSemantics.any((widget) => widget.properties.selected == true),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(selected, [4]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS direct swipe tracks its first movement in the same frame', (
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
    final gesture = await tester.startGesture(_tabCenter(tester, 1));
    // Cross touch slop without a long press. Long-press cancellation must not
    // reset the horizontal drag that just won the gesture arena.
    await gesture.moveTo(_tabCenter(tester, 2));
    await tester.pump();
    expect(_selectionCenter(tester).dx, closeTo(_tabCenter(tester, 2).dx, .1));
    expect(selected, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(_selectionCenter(tester).dx, closeTo(_tabCenter(tester, 1).dx, .1));
  });

  for (final frameMillis in [8, 16]) {
    testWidgets(
      'iOS held slider tracks reversals at ${frameMillis}ms cadence',
      (tester) async {
        await _setPhoneSize(tester);
        final selected = <int>[];
        await _pumpNav(
          tester,
          selectedIndex: 0,
          platform: TargetPlatform.iOS,
          onSelected: selected.add,
        );
        final gesture = await tester.startGesture(_tabCenter(tester, 0));
        await tester.pump(const Duration(milliseconds: 600));
        final origin = _tabCenter(tester, 0);
        final slotWidth = _tabCenter(tester, 1).dx - origin.dx;
        const positions = [
          .3,
          .75,
          1.2,
          1.49,
          1.51,
          2.1,
          2.7,
          2.5,
          2.15,
          1.8,
          1.51,
          1.49,
          1.25,
          1.6,
          2.4,
          3.2,
        ];
        for (final position in positions) {
          final pointer = origin + Offset(slotWidth * position, 0);
          await gesture.moveTo(pointer);
          await tester.pump(Duration(milliseconds: frameMillis));
          expect(
            _selectionCenter(tester).dx,
            closeTo(pointer.dx, .1),
            reason:
                'The capsule must stay under the finger at $position slots.',
          );
          expect(selected, isEmpty);
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(selected, [3]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('iOS slider crosses half slots without a magnetic jump', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final selected = <int>[];
    await _pumpNav(
      tester,
      selectedIndex: 0,
      platform: TargetPlatform.iOS,
      onSelected: selected.add,
    );
    final gesture = await tester.startGesture(_tabCenter(tester, 0));
    await tester.pump(const Duration(milliseconds: 600));
    final origin = _tabCenter(tester, 0);
    final slotWidth = _tabCenter(tester, 1).dx - origin.dx;
    await gesture.moveTo(origin + Offset(slotWidth * 1.49, 0));
    await tester.pumpAndSettle();
    final before = _selectionCenter(tester);
    await gesture.moveTo(origin + Offset(slotWidth * 1.51, 0));
    await tester.pumpAndSettle();
    final after = _selectionCenter(tester);
    expect(after.dx - before.dx, closeTo(slotWidth * .02, .1));
    expect(selected, isEmpty);
    final homeSemantics = tester.widgetList<Semantics>(
      find.ancestor(
        of: find.byKey(const ValueKey('field-bottom-nav-item-0')),
        matching: find.byType(Semantics),
      ),
    );
    expect(
      homeSemantics.any((widget) => widget.properties.selected == true),
      isTrue,
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
  });

  testWidgets('iOS press lift completes while frequent pointer events arrive', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final selected = <int>[];
    await _pumpNav(
      tester,
      selectedIndex: 2,
      platform: TargetPlatform.iOS,
      onSelected: selected.add,
    );
    final origin = _tabCenter(tester, 2);
    final gesture = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 600));
    for (var event = 0; event < 32; event++) {
      await gesture.moveTo(origin + Offset(event.isEven ? .5 : 1, 0));
      await tester.pump(const Duration(milliseconds: 8));
    }
    final icon = find.byKey(const ValueKey('field-bottom-nav-icon-2'));
    final movingCenter = tester.getCenter(icon);
    final movingExtent = tester.getBottomRight(icon) - tester.getTopLeft(icon);
    expect(selected, isEmpty);

    // Stopping pointer updates must not be what finally lets the press
    // animation finish: it should already be fully engaged while sliding.
    await tester.pumpAndSettle();
    final settledExtent = tester.getBottomRight(icon) - tester.getTopLeft(icon);
    expect(settledExtent.dx, greaterThan(32));
    expect(movingExtent.dx, closeTo(settledExtent.dx, .1));
    expect(movingCenter.dy, closeTo(tester.getCenter(icon).dy, .1));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps slide navigation without spring or lift', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final selected = <int>[];
    await _pumpNav(
      tester,
      selectedIndex: 0,
      platform: TargetPlatform.iOS,
      reduceMotion: true,
      acceptSelection: true,
      onSelected: selected.add,
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(_tabCenter(tester, 0));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(_tabCenter(tester, 3));
    await tester.pump();
    expect(selected, isEmpty);
    final selection = find.byKey(
      const ValueKey('field-liquid-glass-selection'),
    );
    final icon = find.byKey(const ValueKey('field-bottom-nav-icon-3'));
    final selectionCenter = tester.getCenter(selection);
    expect(selectionCenter.dx, closeTo(_tabCenter(tester, 3).dx, .1));
    expect(tester.getCenter(icon), _tabCenter(tester, 3));
    final iconExtent = tester.getBottomRight(icon) - tester.getTopLeft(icon);
    expect(iconExtent, const Offset(32, 32));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getCenter(selection), selectionCenter);
    await gesture.up();
    await tester.pump();
    expect(selected, [3]);
    expect(tester.getCenter(selection), selectionCenter);
    expect(tester.takeException(), isNull);
  });

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

Offset _selectionCenter(WidgetTester tester) => tester.getCenter(
  find.byKey(const ValueKey('field-liquid-glass-selection')),
);

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
  bool reduceMotion = false,
  bool acceptSelection = false,
}) {
  var currentIndex = selectedIndex;
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
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
            selectedIndex: currentIndex,
            onSelected: (index) {
              onSelected(index);
              if (acceptSelection) setState(() => currentIndex = index);
            },
            profileAvatarUrl: profileAvatarUrl,
          ),
        ),
      ),
    ),
  );
}
