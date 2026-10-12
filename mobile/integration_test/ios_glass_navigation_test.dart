import 'dart:io';

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/home/field_bottom_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Device-only smoke test for native material composition and touch routing.
/// It uses no account, database, or payment services.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native iOS glass keeps Flutter tap and slide navigation', (
    tester,
  ) async {
    if (!Platform.isIOS) return;
    final native = await const MethodChannel(
      'fieldrush/liquid_glass_support',
    ).invokeMethod<bool>('isAvailable');
    expect(native, isTrue);
    var selected = 0;
    final selections = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            backgroundColor: FieldrushAuthTheme.cream,
            extendBody: true,
            body: ListView.builder(
              itemCount: 20,
              itemBuilder: (context, index) => Container(
                height: 130,
                margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: index.isEven
                      ? FieldrushAuthTheme.forest
                      : const Color(0xFFD5E3A1),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Text(
                  index == 0 ? 'Every game counts.' : 'Fieldrush',
                  style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 28,
                    color: index.isEven ? Colors.white : FieldrushAuthTheme.ink,
                  ),
                ),
              ),
            ),
            bottomNavigationBar: FieldBottomNav(
              selectedIndex: selected,
              onSelected: (index) {
                selections.add(index);
                setState(() => selected = index);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(UiKitView),
      native == true ? findsOneWidget : findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('field-bottom-nav-item-1')));
    await tester.pumpAndSettle();
    expect(selected, 1);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('field-bottom-nav-item-1'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('field-bottom-nav-item-4'))),
    );
    await tester.pump();
    expect(selections, [1]);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selections, [1, 4]);
    expect(tester.takeException(), isNull);

    await binding.takeScreenshot('fieldrush-ios-glass');
  });
}
