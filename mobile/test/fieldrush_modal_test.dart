import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('optional shared modal visual previews', (tester) async {
    final directory = Platform.environment['FIELDRUSH_MODAL_PREVIEW_DIR'];
    if (directory == null) return;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      for (final font in ['Outfit', 'PlusJakartaSans']) {
        await (FontLoader(
          font,
        )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    for (final signOut in [true, false]) {
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Builder(
              builder: (context) => Scaffold(
                backgroundColor: FieldrushAuthTheme.cream,
                body: Center(
                  child: FilledButton(
                    onPressed: () => showFieldrushModal<bool>(
                      context: context,
                      builder: (context) => FieldrushModal(
                        eyebrow: signOut ? null : 'Clan action',
                        title: signOut ? 'Sign out?' : 'Leave GOAT CLAN?',
                        description: signOut
                            ? 'You can sign back in with your phone or linked Google account.'
                            : 'A clan needs a captain. Archive it instead, or add another member before leaving.',
                        actions: [
                          FilledButton(
                            style: FieldrushModal.primaryButtonStyle(
                              destructive: true,
                            ),
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(signOut ? 'Sign out' : 'Leave clan'),
                          ),
                          OutlinedButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(signOut ? 'Stay signed in' : 'Cancel'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Open preview'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open preview'));
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 2);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File(
          '$directory/${signOut ? 'sign-out' : 'leave-clan'}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
    }
  });

  Future<void> open(
    WidgetTester tester, {
    required WidgetBuilder builder,
    bool dismissible = true,
    ValueChanged<bool?>? onResult,
    TextScaler? textScaler,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        // Deliberately use a different parent theme: overlays must not inherit it.
        theme: ThemeData(colorSchemeSeed: Colors.purple),
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final result = await showFieldrushModal<bool>(
                  context: context,
                  builder: builder,
                  dismissible: dismissible,
                );
                onResult?.call(result);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shared sheet owns cream surface, fonts and action styles', (
    tester,
  ) async {
    await open(
      tester,
      onResult: (_) {},
      builder: (context) => FieldrushModal(
        title: 'Leave clan?',
        description: 'Your game booking stays put.',
        actions: [
          FilledButton(
            style: FieldrushModal.primaryButtonStyle(destructive: true),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave clan'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    final surface = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(FieldrushModal),
            matching: find.byType(Material),
          ),
        )
        .first;
    expect(surface.color, FieldrushAuthTheme.cream);
    expect(
      tester.widget<Text>(find.text('Leave clan?')).style!.fontFamily,
      'Outfit',
    );
    expect(
      tester
          .widget<Text>(find.text('Your game booking stays put.'))
          .style!
          .fontFamily,
      'PlusJakartaSans',
    );
    final primary = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(
      primary.style!.backgroundColor!.resolve({}),
      FieldrushAuthTheme.danger,
    );
    expect(
      tester.getTopLeft(find.text('Leave clan')).dy,
      lessThan(tester.getTopLeft(find.text('Cancel')).dy),
    );
    expect(
      find.byKey(const ValueKey('fieldrush-modal-handle')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel and confirm preserve typed results', (tester) async {
    bool? result;
    for (final confirm in [false, true]) {
      await open(
        tester,
        onResult: (value) => result = value,
        builder: (context) => FieldrushModal(
          title: 'Continue?',
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      await tester.tap(find.text(confirm ? 'Continue' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(result, confirm);
      expect(find.byType(FieldrushModal), findsNothing);
    }
  });

  testWidgets('protected verification does not dismiss on scrim or drag', (
    tester,
  ) async {
    await open(
      tester,
      onResult: (_) {},
      dismissible: false,
      builder: (context) => FieldrushModal(
        title: 'Confirm it’s you',
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('fieldrush-modal-handle')),
      const Offset(0, 400),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsNothing);
  });

  testWidgets('long content stays scrollable with keyboard and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await open(
      tester,
      textScaler: const TextScaler.linear(2),
      onResult: (_) {},
      builder: (context) => FieldrushModal(
        title: 'Confirm it’s you',
        description: 'Verify your phone number before continuing.',
        content: Column(
          children: [
            for (var i = 0; i < 8; i++)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Important account information.'),
              ),
            const TextField(
              key: ValueKey('code'),
              decoration: InputDecoration(labelText: 'Verification code'),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Verify & continue'),
          ),
        ],
      ),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('code')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('code')), '123456');
    await tester.ensureVisible(find.text('Verify & continue'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getBottomLeft(find.text('Verify & continue')).dy,
      lessThanOrEqualTo(328),
    );
    await tester.tap(find.text('Verify & continue'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsNothing);
  });
}
