import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:field/src/profile/avatar_crop_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final portrait in [false, true]) {
    testWidgets(
      'crop preserves chosen pixels for ${portrait ? 'portrait' : 'landscape'} photo',
      (tester) async {
        Uint8List? result;
        final bytes = await tester.runAsync(() => _photo(portrait));
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<Uint8List>(
                      MaterialPageRoute(
                        builder: (_) => AvatarCropScreen(bytes: bytes!),
                      ),
                    );
                  },
                  child: const Text('Choose photo'),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('Choose photo'));
          await tester.pump();
          for (
            var i = 0;
            i < 500 &&
                find
                    .byKey(const ValueKey('avatar-crop-preview'))
                    .evaluate()
                    .isEmpty;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        final preview = find.byKey(const ValueKey('avatar-crop-preview'));
        expect(preview, findsOneWidget);
        // Move to the blue half, then zoom in. The saved center must be blue.
        await tester.timedDrag(
          preview,
          portrait ? const Offset(0, -300) : const Offset(-300, 0),
          const Duration(milliseconds: 500),
        );
        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChanged!(2);
        await tester.pump();
        await tester.runAsync(() async {
          await tester.tap(find.text('Use photo'));
          await tester.pump();
          for (var i = 0; i < 500 && result == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        expect(result, isNotNull);
        await tester.runAsync(() async {
          final codec = await ui.instantiateImageCodec(result!);
          final image = (await codec.getNextFrame()).image;
          expect((image.width, image.height), (100, 100));
          final pixels = (await image.toByteData())!.buffer.asUint8List();
          final center = (50 * image.width + 50) * 4;
          expect(pixels.sublist(center, center + 4), [0, 0, 255, 255]);
          image.dispose();
          codec.dispose();
        });
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancel leaves photo selection unchanged', (tester) async {
    Uint8List? result;
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<Uint8List>(
                MaterialPageRoute(
                  builder: (_) => AvatarCropScreen(bytes: Uint8List(0)),
                ),
              );
              returned = true;
            },
            child: const Text('Choose photo'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not read this photo. Try another.'),
      findsOneWidget,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isNull);
  });
}

Future<Uint8List> _photo(bool portrait) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final width = portrait ? 200 : 400;
  final height = portrait ? 400 : 200;
  canvas.drawColor(const Color(0xFFFF0000), BlendMode.src);
  canvas.drawRect(
    portrait
        ? const Rect.fromLTWH(0, 200, 200, 200)
        : const Rect.fromLTWH(200, 0, 200, 200),
    Paint()..color = const Color(0xFF0000FF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}
