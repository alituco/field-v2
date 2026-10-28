import 'dart:async';
import 'dart:ui' as ui;

import 'package:field/src/ui/fieldrush_avatar_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} photo fills a loosely aligned square and crops its center',
      (tester) async {
        final width = portrait ? 20 : 40;
        final height = portrait ? 40 : 20;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(Colors.blue, BlendMode.src);
        canvas.drawRect(
          Rect.fromLTWH(portrait ? 0 : 10, portrait ? 10 : 0, 20, 20),
          Paint()..color = Colors.red,
        );
        final picture = recorder.endRecording();
        final image = picture.toImageSync(width, height);
        picture.dispose();
        final provider = NetworkImage('https://example.test/$portrait.png');
        PaintingBinding.instance.imageCache.putIfAbsent(
          provider,
          () => OneFrameImageStreamCompleter(
            Future.value(ImageInfo(image: image)),
          ),
        );
        addTearDown(PaintingBinding.instance.imageCache.clear);
        final frameKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: frameKey,
                child: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  color: Colors.green,
                  child: FieldrushAvatarImage(
                    size: 38,
                    image: provider,
                    fallback: const Text('AA'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rendered = tester.renderObject<RenderImage>(
          find.byType(RawImage),
        );
        expect(rendered.size, const Size(38, 38));
        expect(rendered.image!.width, width);
        expect(rendered.image!.height, height);
        expect(rendered.fit, BoxFit.cover);
        expect(rendered.alignment, Alignment.center);
        final boundary =
            frameKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final bytes = await tester.runAsync(() async {
          final renderedImage = await boundary.toImage(pixelRatio: 1);
          final data = await renderedImage.toByteData();
          renderedImage.dispose();
          return data!;
        });
        // The blue ends must be cropped off, and the green frame must never
        // show through either side of a narrow portrait or above a wide photo.
        for (final point in [
          const Offset(1, 19),
          const Offset(36, 19),
          const Offset(19, 1),
          const Offset(19, 36),
          const Offset(19, 19),
        ]) {
          final offset = (point.dy.toInt() * 38 + point.dx.toInt()) * 4;
          expect(bytes!.buffer.asUint8List(offset, 4), [244, 67, 54, 255]);
        }
        expect(find.text('AA'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('blank photo shows the caller fallback in the same square', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: FieldrushAvatarImage(
            size: 38,
            url: '   ',
            fallback: Center(child: Text('AA')),
          ),
        ),
      ),
    );
    expect(find.text('AA'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(
      tester.getSize(find.byType(FieldrushAvatarImage)),
      const Size(38, 38),
    );
  });

  testWidgets('loading and failed photos retain the caller fallback', (
    tester,
  ) async {
    const provider = NetworkImage('https://example.test/unavailable.png');
    final response = Completer<ImageInfo>();
    PaintingBinding.instance.imageCache.putIfAbsent(
      provider,
      () => OneFrameImageStreamCompleter(response.future),
    );
    addTearDown(PaintingBinding.instance.imageCache.clear);
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: FieldrushAvatarImage(
            size: 38,
            image: provider,
            fallback: Center(child: Text('AA')),
          ),
        ),
      ),
    );
    expect(find.text('AA'), findsOneWidget);
    response.completeError(StateError('Unavailable photo'));
    await tester.pumpAndSettle();
    expect(find.text('AA'), findsOneWidget);
    expect(
      tester.getSize(find.byType(FieldrushAvatarImage)),
      const Size(38, 38),
    );
    expect(tester.takeException(), isNull);
  });
}
