import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'fieldrush_welcome_ball.dart';

/// Native rendering of the original welcome illustration's geometry and layers.
class FieldrushWelcomePainter extends CustomPainter {
  const FieldrushWelcomePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipRect(bounds);
    final scale = size.width / 372;
    canvas.scale(scale);
    final height = size.height / scale;
    final artworkBounds = Rect.fromLTWH(0, 0, 372, height);
    const stripeEdge = 73.2 * math.sqrt2;
    canvas.drawRect(
      artworkBounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF3B7448),
            Color(0xFF3B7448),
            Color(0xFF407C4D),
            Color(0xFF407C4D),
          ],
          stops: [0, 0.5, 0.5, 1],
          tileMode: TileMode.repeated,
        ).createShader(const Rect.fromLTWH(0, 0, stripeEdge, stripeEdge)),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 372, 231.8),
      Paint()..color = Colors.black.withValues(alpha: 0.07),
    );

    final lineColor = Colors.white.withValues(alpha: 0.92);
    canvas.drawRect(
      const Rect.fromLTWH(-80, 231.8, 408.1, 14.6),
      Paint()..color = lineColor,
    );
    const verticalLine = Rect.fromLTWH(313.4, 231.8, 14.6, 322.1);
    canvas.drawRect(
      verticalLine,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [lineColor, lineColor, Colors.white.withValues(alpha: 0)],
          stops: const [0, 0.72, 1],
        ).createShader(verticalLine),
    );
    // CSS's 183px outer corner radius includes its 14.6px inside border.
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(328.1, 231.8), radius: 175.7),
      math.pi / 2,
      math.pi / 2,
      false,
      Paint()
        ..color = lineColor
        ..strokeWidth = 14.6
        ..style = PaintingStyle.stroke,
    );

    _paintPole(canvas);
    _paintFlag(canvas);
    _paintMotionLines(canvas);
    paintFieldrushWelcomeBall(canvas);
    canvas.restore();

    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0x000A180E),
            const Color(0x000A180E),
            const Color(0xFF0A180E).withValues(alpha: 0.55),
          ],
          stops: const [0, 0.52, 1],
        ).createShader(bounds),
    );
  }

  void _paintPole(Canvas canvas) {
    canvas.save();
    canvas.translate(318.3 + 6.1 / 2, 234.3);
    canvas.rotate(40 * math.pi / 180);
    const shadow = Rect.fromLTWH(-6.1 / 2, 0, 6.1, 117.1);
    canvas.drawRRect(
      RRect.fromRectAndRadius(shadow, const Radius.circular(3)),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF0A190E).withValues(alpha: 0.3),
            const Color(0x000A190E),
          ],
        ).createShader(shadow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.restore();

    const grip = Rect.fromLTWH(314.7, 218.4, 12.2, 18.3);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(grip, const Radius.circular(2)));
    for (var row = 0; row < 10; row++) {
      canvas.drawRect(
        Rect.fromLTWH(grip.left, grip.top + row * 2, grip.width, 2),
        Paint()
          ..color = row.isEven
              ? const Color(0xFF2E2E2A)
              : const Color(0xFF9A988F),
      );
    }
    canvas.restore();

    const poleBounds = Rect.fromLTWH(315.9, 90.3, 9.8, 129.1);
    final pole = RRect.fromRectAndCorners(
      poleBounds,
      topLeft: const Radius.circular(4.9),
      topRight: const Radius.circular(4.9),
      bottomLeft: const Radius.circular(1),
      bottomRight: const Radius.circular(1),
    );
    canvas.drawRRect(pole, Paint()..color = const Color(0xFFF4F2EC));
    canvas.drawRRect(
      pole,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.black.withValues(alpha: 0.22),
            Colors.white.withValues(alpha: 0.34),
            Colors.black.withValues(alpha: 0.26),
          ],
          stops: const [0, 0.36, 1],
        ).createShader(poleBounds),
    );
  }

  void _paintFlag(Canvas canvas) {
    canvas.save();
    canvas.translate(250.1, 95.2);
    final flag = Path()
      ..moveTo(75.6, 2.4)
      ..lineTo(75.6, 53.7)
      ..cubicTo(63, 57.4, 50.4, 50.1, 35.3, 54.9)
      ..cubicTo(22.7, 58.6, 10.1, 52.5, 0, 56.2)
      ..lineTo(1.3, 6.1)
      ..cubicTo(11.3, 2.4, 22.7, 8.5, 36.5, 3.7)
      ..cubicTo(50.4, 0, 63, 4.9, 75.6, 2.4)
      ..close();
    canvas.drawPath(
      flag.shift(const Offset(0, 8)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.clipPath(flag);
    for (var row = 0; row < 4; row++) {
      for (var column = 0; column < 6; column++) {
        canvas.drawRect(
          Rect.fromLTWH(column * 14.65, row * 14.65, 14.65, 14.65),
          Paint()
            ..color = (row + column).isEven
                ? const Color(0xFFF2D012)
                : const Color(0xFFE23B2E),
        );
      }
    }
    const flagBounds = Rect.fromLTWH(0, 0, 75.6, 58.6);
    canvas.drawRect(
      flagBounds,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.black.withValues(alpha: 0.18),
            Colors.white.withValues(alpha: 0.16),
            Colors.black.withValues(alpha: 0.14),
            Colors.white.withValues(alpha: 0.12),
            Colors.black.withValues(alpha: 0.1),
          ],
          stops: const [0, 0.22, 0.46, 0.70, 1],
        ).createShader(flagBounds),
    );
    const foldedEdge = Rect.fromLTWH(75.6 - 9.8, 0, 9.8, 58.6);
    canvas.drawRect(
      foldedEdge,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.black.withValues(alpha: 0.24),
            Colors.white.withValues(alpha: 0.2),
            Colors.black.withValues(alpha: 0.28),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(foldedEdge),
    );
    canvas.restore();
  }

  void _paintMotionLines(Canvas canvas) {
    for (final (left, top, width) in const [
      (264.6, 267.9, 29.3),
      (274.5, 278.7, 43.9),
      (284.3, 289.5, 26.8),
    ]) {
      canvas.save();
      canvas.translate(left, top + 2.45);
      canvas.rotate(-42.3 * math.pi / 180);
      final bounds = Rect.fromLTWH(0, -2.45, width, 4.9);
      canvas.drawRRect(
        RRect.fromRectAndRadius(bounds, const Radius.circular(2.45)),
        Paint()
          ..shader = LinearGradient(
            colors: [
              Colors.white.withValues(alpha: 0.75),
              const Color(0x00FFFFFF),
            ],
          ).createShader(bounds),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant FieldrushWelcomePainter oldDelegate) => false;
}
