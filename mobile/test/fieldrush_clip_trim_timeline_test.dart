import 'package:field/src/ui/fieldrush_clip_trim_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sliderKey = ValueKey('test-trim-range');

  Future<void> pumpTimeline(
    WidgetTester tester, {
    required RangeValues values,
    double min = 0,
    double max = 100,
    TextDirection direction = TextDirection.ltr,
    ValueChanged<RangeValues>? onChanged,
    ValueChanged<RangeValues>? onChangeEnd,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: FieldrushClipTrimTimeline(
                  values: values,
                  min: min,
                  max: max,
                  background: const ColoredBox(color: Colors.amber),
                  onChanged: onChanged ?? (_) {},
                  onChangeEnd: onChangeEnd ?? (_) {},
                  formatTime: (seconds) => '${seconds.round()} seconds',
                  sliderKey: sliderKey,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final direction in TextDirection.values) {
    testWidgets('outline and grips share precise geometry in $direction', (
      tester,
    ) async {
      const cases = [
        RangeValues(120, 190),
        RangeValues(100, 190),
        RangeValues(120, 220),
        RangeValues(100, 220),
      ];
      for (final values in cases) {
        await pumpTimeline(
          tester,
          values: values,
          min: 100,
          max: 220,
          direction: direction,
        );
        final slider = find.byKey(sliderKey);
        final bounds = tester.getRect(slider);
        final theme = tester
            .widget<SliderTheme>(
              find
                  .ancestor(of: slider, matching: find.byType(SliderTheme))
                  .first,
            )
            .data;
        final track = theme.rangeTrackShape!.getPreferredRect(
          parentBox: tester.renderObject<RenderBox>(slider),
          sliderTheme: theme,
        );
        expect(track.left, 6);
        expect(track.right, 314);
        expect(track.center.dy, 32);
        expect(
          theme.rangeThumbShape!.getPreferredSize(true, false),
          const Size(12, 64),
        );

        double center(double value) {
          final fraction = (value - 100) / 120;
          return 6 +
              (direction == TextDirection.rtl ? 1 - fraction : fraction) * 308;
        }

        final first = center(values.start);
        final last = center(values.end);
        final expectedLeft = (first < last ? first : last) - 6;
        final expectedRight = (first > last ? first : last) + 6;
        final outline = tester.getRect(
          find.byKey(const ValueKey('clip-trim-selected-outline')),
        );
        expect(outline.left - bounds.left, closeTo(expectedLeft, .001));
        expect(outline.right - bounds.left, closeTo(expectedRight, .001));
        expect(outline.top, bounds.top);
        expect(outline.height, 64);
        final leftMask = tester.getRect(
          find.byKey(const ValueKey('clip-trim-left-mask')),
        );
        final rightMask = tester.getRect(
          find.byKey(const ValueKey('clip-trim-right-mask')),
        );
        expect(leftMask.right, closeTo(outline.left, .001));
        expect(rightMask.left, closeTo(outline.right, .001));
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final direction in TextDirection.values) {
    testWidgets('dragging grips reaches both exact ends in $direction', (
      tester,
    ) async {
      var values = const RangeValues(20, 80);
      final ended = <RangeValues>[];
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      update = setState;
                      return FieldrushClipTrimTimeline(
                        values: values,
                        min: 0,
                        max: 100,
                        background: const ColoredBox(color: Colors.amber),
                        onChanged: (next) => update(() => values = next),
                        onChangeEnd: ended.add,
                        formatTime: (seconds) => '${seconds.round()} seconds',
                        sliderKey: sliderKey,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final bounds = tester.getRect(find.byKey(sliderKey));
      double x(double value) =>
          bounds.left +
          6 +
          (direction == TextDirection.rtl ? 1 - value / 100 : value / 100) *
              308;
      final startGesture = await tester.startGesture(
        Offset(x(values.start), bounds.center.dy),
      );
      await startGesture.moveTo(Offset(x(0), bounds.center.dy));
      await tester.pump();
      await startGesture.up();
      await tester.pumpAndSettle();
      expect(values.start, 0);
      expect(values.end, 80);
      expect(ended.last.start, 0);

      final endGesture = await tester.startGesture(
        Offset(x(values.end), bounds.center.dy),
      );
      await endGesture.moveTo(Offset(x(100), bounds.center.dy));
      await tester.pump();
      await endGesture.up();
      await tester.pumpAndSettle();
      expect(values, const RangeValues(0, 100));
      expect(ended.last, const RangeValues(0, 100));
      expect(ended, hasLength(2));
      final outline = tester.getRect(
        find.byKey(const ValueKey('clip-trim-selected-outline')),
      );
      expect(outline, bounds);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'range keeps time labels and leaves minimum duration to its owner',
    (tester) async {
      RangeValues? changed;
      RangeValues? ended;
      await pumpTimeline(
        tester,
        values: const RangeValues(20, 80),
        onChanged: (next) => changed = next,
        onChangeEnd: (next) => ended = next,
      );
      final slider = tester.widget<RangeSlider>(find.byKey(sliderKey));
      expect(slider.labels!.start, '20 seconds');
      expect(slider.labels!.end, '80 seconds');
      expect(slider.semanticFormatterCallback!(25), '25 seconds');
      const next = RangeValues(79.5, 80);
      slider.onChanged!(next);
      slider.onChangeEnd!(next);
      expect(changed, next);
      expect(ended, next);
    },
  );
}
