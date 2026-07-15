import 'package:field/src/core/field_confirmation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Field confirmation returns the selected action', (tester) async {
    bool? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showFieldConfirmDialog(
                  context: context,
                  icon: Icons.delete_outline_rounded,
                  eyebrow: 'Your clip',
                  title: 'Delete this clip?',
                  message: 'This cannot be undone.',
                  detail: 'Only the clip on your profile will be removed.',
                  confirmLabel: 'Delete clip',
                  cancelLabel: 'Keep clip',
                  destructive: true,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('field-confirmation-dialog')),
      findsOneWidget,
    );
    expect(find.text('YOUR CLIP'), findsOneWidget);
    expect(find.text('Delete this clip?'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('field-confirmation-detail')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('field-confirmation-confirm')));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(
      find.byKey(const ValueKey('field-confirmation-dialog')),
      findsNothing,
    );
  });

  testWidgets('disabled confirmation stays visible', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () {
                showFieldConfirmDialog(
                  context: context,
                  icon: Icons.lock_outline_rounded,
                  eyebrow: 'Unavailable',
                  title: 'Action unavailable',
                  message: 'This action cannot be completed yet.',
                  confirmLabel: 'Continue',
                  confirmEnabled: false,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final confirm = tester.widget<FilledButton>(
      find.byKey(const ValueKey('field-confirmation-confirm')),
    );
    expect(confirm.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('field-confirmation-cancel')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('field-confirmation-dialog')),
      findsNothing,
    );
  });
}
