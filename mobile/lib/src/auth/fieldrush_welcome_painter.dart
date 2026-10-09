import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Native, resolution-independent interpretation of the HTML's corner artwork.
/// Scales with the canvas; it never paints UI controls or fake device chrome.
class FieldrushWelcomePainter extends CustomPainter {
  const FieldrushWelcomePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = const Color(0xFF3B7448));
    canvas.save();
    canvas.clipRect(bounds);
    final scale = size.width / 372;
    canvas.scale(scale);
    final height = size.height / scale;
    final stripe = Paint()
      ..color = const Color(0xFF407C4D)
      ..strokeWidth = 73.2;
    for (double x = -height; x < 372 + height; x += 207) {
      canvas.drawLine(Offset(x, 0), Offset(x - height, height), stripe);
    }
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 372, 231.8),
      Paint()..color = const Color(0x12000000),
    );

    final line = Paint()
      ..color = const Color(0xEBFFFFFF)
      ..strokeWidth = 14.6
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(-20, 239), const Offset(321, 239), line);
    canvas.drawLine(const Offset(321, 239), const Offset(321, 495), line);
    canvas.drawArc(
      const Rect.fromLTWH(145, 63, 352, 352),
      math.pi / 2,
      math.pi / 2,
      false,
      line,
    );
    final pole = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFFB9B9AD), Color(0xFFF4F2EC), Color(0xFFB0B2A8)],
      ).createShader(const Rect.fromLTWH(316, 90, 10, 148));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(316, 90, 10, 148),
        const Radius.circular(4),
      ),
      pole,
    );
    final flag = Path()
      ..moveTo(326, 97)
      ..lineTo(326, 149)
      ..cubicTo(313, 153, 301, 146, 285, 151)
      ..cubicTo(273, 155, 260, 148, 250, 151)
      ..lineTo(251, 101)
      ..cubicTo(262, 97, 273, 103, 287, 99)
      ..cubicTo(300, 94, 313, 101, 326, 97)
      ..close();
    canvas.drawShadow(flag, Colors.black.withValues(alpha: 0.5), 5, true);
    canvas.save();
    canvas.clipPath(flag);
    for (var row = 0; row < 4; row++) {
      for (var column = 0; column < 6; column++) {
        canvas.drawRect(
          Rect.fromLTWH(247 + column * 15, 93 + row * 15, 15, 15),
          Paint()
            ..color = (row + column).isEven
                ? const Color(0xFFE23B2E)
                : const Color(0xFFF2D012),
        );
      }
    }
    canvas.restore();

    const ball = Offset(240, 312);
    canvas.drawOval(
      const Rect.fromLTWH(189, 341, 80, 25),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.24)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawCircle(ball, 39, Paint()..color = const Color(0xFFF8F7F2));
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: ball, radius: 39)));
    final patches = [
      (const Offset(240, 312), 15.0, const Color(0xFF1A1915)),
      (const Offset(212, 285), 12.0, const Color(0xFF22406F)),
      (const Offset(276, 295), 13.0, const Color(0xFFAEB7BF)),
      (const Offset(214, 341), 13.0, const Color(0xFFD9B04F)),
      (const Offset(266, 344), 12.0, const Color(0xFF1A1915)),
    ];
    for (final (center, radius, color) in patches) {
      final patch = Path();
      for (var index = 0; index < 5; index++) {
        final angle = index * 2 * math.pi / 5 - math.pi / 2;
        final point =
            center + Offset(math.cos(angle), math.sin(angle)) * radius;
        if (index == 0) {
          patch.moveTo(point.dx, point.dy);
        } else {
          patch.lineTo(point.dx, point.dy);
        }
      }
      patch.close();
      canvas.drawPath(patch, Paint()..color = color);
      canvas.drawPath(
        patch,
        Paint()
          ..color = const Color(0xFFD9B25C)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
    }
    canvas.drawCircle(
      ball,
      39,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.4, -0.5),
          radius: 1,
          colors: [Color(0x55FFFFFF), Color(0x00000000), Color(0x60000000)],
          stops: [0, 0.5, 1],
        ).createShader(Rect.fromCircle(center: ball, radius: 39)),
    );
    canvas.restore();
    canvas.restore();
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x000A180E), Color(0x000A180E), Color(0xD00A180E)],
          stops: [0, 0.43, 1],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(covariant FieldrushWelcomePainter oldDelegate) => false;
}
