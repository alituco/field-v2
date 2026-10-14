import 'package:field/src/auth/fieldrush_phone_field.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

void main() {
  testWidgets(
    'country picker shares the modal and filters/selects calling codes',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      IsoCode? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FieldrushPhoneField(
              controller: controller,
              onCountryChanged: (country) => selected = country,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('fieldrush-country-picker')));
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushModal), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fieldrush-phone-country-US')),
        findsOneWidget,
      );
      final selection = tester.widget<Semantics>(
        find.byKey(const ValueKey('fieldrush-phone-country-semantics-US')),
      );
      expect(selection.properties.selected, isTrue);
      expect(selection.properties.button, isTrue);
      expect(selection.properties.label, contains('plus 1'));
      expect(selection.properties.onTap, isNotNull);
      await tester.enterText(
        find.byKey(const ValueKey('fieldrush-phone-country-search')),
        '+44',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('fieldrush-phone-country-US')),
        findsNothing,
      );
      final uk = find.byKey(const ValueKey('fieldrush-phone-country-GB'));
      expect(uk, findsOneWidget);
      await tester.ensureVisible(uk);
      await tester.tap(uk);
      await tester.pumpAndSettle();
      expect(selected, IsoCode.GB);
      expect(find.byType(FieldrushModal), findsNothing);
      expect(find.text('+44'), findsOneWidget);
      expect(controller.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('country sheet cancellation does not change country or phone', (
    tester,
  ) async {
    final controller = TextEditingController(text: '2025550123');
    addTearDown(controller.dispose);
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FieldrushPhoneField(
            controller: controller,
            onCountryChanged: (_) => changes++,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('fieldrush-country-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('fieldrush-phone-country-search')),
      'no-such-country',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matching countries.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(changes, 0);
    expect(controller.text, '2025550123');
    expect(find.text('+1'), findsOneWidget);
  });
}
