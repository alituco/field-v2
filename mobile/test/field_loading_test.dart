import 'dart:async';
import 'dart:io';

import 'package:field/src/ui/field_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('content placeholders have one loading label and no animation', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FieldLoadingContent(label: 'Loading games', rows: 2),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Loading games'), findsOneWidget);
    expect(find.byType(FieldSkeleton), findsNWidgets(8));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'skeletons fit a compact region with enlarged text and no motion',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: const TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: const Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 220,
                  height: 90,
                  child: FieldLoadingContent(rows: 4, compact: true),
                ),
                SizedBox(width: 15, height: 15, child: FieldLoadingIndicator()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        .75,
      );
    },
  );

  testWidgets(
    'compact activity indicators stay circular and announce loading once',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox.square(
                  dimension: 12,
                  child: FieldLoadingIndicator(label: 'Loading preview'),
                ),
                SizedBox.square(
                  dimension: 18,
                  child: FieldLoadingIndicator(label: 'Sending report'),
                ),
                FieldLoadingIndicator(label: 'Refreshing games'),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FieldSkeleton), findsNothing);
      final indicators = find.byType(CircularProgressIndicator);
      expect(indicators, findsNWidgets(3));
      expect(tester.getSize(indicators.at(0)), const Size.square(12));
      expect(tester.getSize(indicators.at(1)), const Size.square(18));
      expect(tester.getSize(indicators.at(2)), const Size.square(20));
      for (final label in [
        'Loading preview',
        'Sending report',
        'Refreshing games',
      ]) {
        final indicator = find.bySemanticsLabel(label);
        expect(indicator, findsOneWidget);
        expect(
          tester.getSemantics(indicator).getSemanticsData().value,
          isEmpty,
        );
      }
      expect(tester.binding.hasScheduledFrame, isTrue);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'pull refresh retains data and shows a spinner until completion',
    (tester) async {
      final completion = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FieldRefreshIndicator(
              onRefresh: () {
                calls++;
                return completion.future;
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [Text('Existing game')],
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, 450));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(calls, 1);
      expect(
        find.byKey(const ValueKey('field-refresh-indicator')),
        findsOneWidget,
      );
      expect(find.text('Existing game'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      completion.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('field-refresh-indicator')),
        findsNothing,
      );
      expect(find.text('Existing game'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('app-owned loaders use the shared loading components', () {
    final prohibited = RegExp(
      r'\b(?:CircularProgressIndicator|CupertinoActivityIndicator|RefreshIndicator)\s*\(',
    );
    final files = Directory('lib').listSync(recursive: true).whereType<File>();
    for (final file in files.where((file) => file.path.endsWith('.dart'))) {
      if (file.path == 'lib/src/ui/field_loading.dart') continue;
      expect(
        prohibited.hasMatch(file.readAsStringSync()),
        isFalse,
        reason: '${file.path} must use a shared loading component.',
      );
    }
  });
}
