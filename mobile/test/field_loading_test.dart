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
    },
  );

  testWidgets(
    'pull refresh retains data and shows a skeleton until completion',
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
        find.byKey(const ValueKey('field-refresh-skeleton')),
        findsOneWidget,
      );
      expect(find.text('Existing game'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      completion.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('field-refresh-skeleton')),
        findsNothing,
      );
      expect(find.text('Existing game'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('app-owned loaders cannot reintroduce rotating spinners', () {
    final prohibited = RegExp(
      r'\b(?:CircularProgressIndicator|CupertinoActivityIndicator|RefreshIndicator)\s*\(',
    );
    final files = Directory('lib').listSync(recursive: true).whereType<File>();
    for (final file in files.where((file) => file.path.endsWith('.dart'))) {
      expect(
        prohibited.hasMatch(file.readAsStringSync()),
        isFalse,
        reason:
            '${file.path} must use a content skeleton or clear action label.',
      );
    }
  });
}
