import 'package:field/src/ranking/division_crest.dart';
import 'package:field/src/ranking/rating_division.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('division crest exposes its division accessibly', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DivisionCrest(
            division: RatingDivision.division1,
            showLabel: true,
          ),
        ),
      ),
    );

    expect(find.text('DIVISION 1'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DivisionCrest),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });
}
