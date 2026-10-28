import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';

/// A trim selection whose outline and vertical grips share the same geometry.
/// The owner applies clip-duration and minimum-duration rules in [onChanged].
class FieldrushClipTrimTimeline extends StatelessWidget {
  const FieldrushClipTrimTimeline({
    super.key,
    required this.values,
    required this.min,
    required this.max,
    required this.background,
    required this.onChanged,
    required this.onChangeEnd,
    required this.formatTime,
    this.sliderKey,
  }) : assert(max >= min);

  static const double height = 64;
  static const double handleWidth = 12;

  final RangeValues values;
  final double min;
  final double max;
  final Widget background;
  final ValueChanged<RangeValues> onChanged;
  final ValueChanged<RangeValues> onChangeEnd;
  final String Function(double) formatTime;
  final Key? sliderKey;

  @override
  Widget build(BuildContext context) {
    assert(values.start >= min);
    assert(values.end <= max);
    assert(values.start <= values.end);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final span = max - min;
    double fraction(double value) {
      final fraction = span == 0 ? 0.0 : ((value - min) / span).clamp(0.0, 1.0);
      return rtl ? 1 - fraction : fraction;
    }

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final trackWidth = math.max(0.0, width - handleWidth);
          final startCenter =
              handleWidth / 2 + fraction(values.start) * trackWidth;
          final endCenter = handleWidth / 2 + fraction(values.end) * trackWidth;
          final selectedLeft =
              math.min(startCenter, endCenter) - handleWidth / 2;
          final selectedRight =
              math.max(startCenter, endCenter) + handleWidth / 2;
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                background,
                Positioned(
                  key: const ValueKey('clip-trim-left-mask'),
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: selectedLeft,
                  child: const IgnorePointer(
                    child: ColoredBox(color: Color(0xCCFAF7EF)),
                  ),
                ),
                Positioned(
                  key: const ValueKey('clip-trim-right-mask'),
                  left: selectedRight,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: const IgnorePointer(
                    child: ColoredBox(color: Color(0xCCFAF7EF)),
                  ),
                ),
                Positioned(
                  key: const ValueKey('clip-trim-selected-outline'),
                  left: selectedLeft,
                  width: selectedRight - selectedLeft,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: FieldrushAuthTheme.forest,
                          width: 3,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 0,
                    rangeTrackShape: const _TrimTrackShape(),
                    rangeThumbShape: const _TrimGripShape(),
                    overlayShape: SliderComponentShape.noOverlay,
                    overlayColor: Colors.transparent,
                    thumbColor: FieldrushAuthTheme.forest,
                    minThumbSeparation: 0,
                    showValueIndicator: ShowValueIndicator.never,
                  ),
                  child: RangeSlider(
                    key: sliderKey,
                    padding: EdgeInsets.zero,
                    min: min,
                    max: max,
                    values: values,
                    labels: RangeLabels(
                      formatTime(values.start),
                      formatTime(values.end),
                    ),
                    semanticFormatterCallback: formatTime,
                    onChanged: onChanged,
                    onChangeEnd: onChangeEnd,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TrimTrackShape extends RangeSliderTrackShape {
  const _TrimTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) => Rect.fromLTWH(
    offset.dx + FieldrushClipTrimTimeline.handleWidth / 2,
    offset.dy + parentBox.size.height / 2,
    math.max(0, parentBox.size.width - FieldrushClipTrimTimeline.handleWidth),
    0,
  );

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset startThumbCenter,
    required Offset endThumbCenter,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {}
}

class _TrimGripShape extends RangeSliderThumbShape {
  const _TrimGripShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(
    FieldrushClipTrimTimeline.handleWidth,
    FieldrushClipTrimTimeline.height,
  );

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool isOnTop = false,
    TextDirection textDirection = TextDirection.ltr,
    required SliderThemeData sliderTheme,
    Thumb thumb = Thumb.start,
    bool isPressed = false,
  }) {
    final canvas = context.canvas;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center,
          width: FieldrushClipTrimTimeline.handleWidth,
          height: FieldrushClipTrimTimeline.height,
        ),
        const Radius.circular(4),
      ),
      Paint()..color = FieldrushAuthTheme.forest,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 2, height: 22),
        const Radius.circular(1),
      ),
      Paint()..color = Colors.white,
    );
  }
}
