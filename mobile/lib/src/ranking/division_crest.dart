import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'rating_division.dart';

/// Native Flutter version of the DivisionArt crest system used by the Field
/// product concept. Higher divisions progressively gain wings, laurels, a
/// crown, rays, and additional stars.
class DivisionCrest extends StatelessWidget {
  const DivisionCrest({
    super.key,
    required this.division,
    this.size = 52,
    this.showLabel = false,
  });

  final RatingDivision division;
  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final crest = SizedBox(
      width: size,
      height: size * 1.18,
      child: CustomPaint(painter: _DivisionCrestPainter(division)),
    );

    return Semantics(
      label: division.label,
      image: true,
      child: showLabel
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                crest,
                const SizedBox(height: 4),
                Text(
                  division.label.toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFF4B5563),
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            )
          : crest,
    );
  }
}

class DivisionLabelBadge extends StatelessWidget {
  const DivisionLabelBadge({
    super.key,
    required this.division,
    this.small = false,
  });

  final RatingDivision division;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final foreground = division.colors.last;
    final background = Color.alphaBlend(
      division.colors[1].withValues(alpha: 0.12),
      Colors.white,
    );

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 8 : 10,
        vertical: small ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: foreground.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        division.label.toUpperCase(),
        style: TextStyle(
          color: foreground,
          fontSize: small ? 10 : 12,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

class _DivisionCrestPainter extends CustomPainter {
  const _DivisionCrestPainter(this.division);

  final RatingDivision division;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 120, size.height / 142);

    if (division.hasRays) _paintRays(canvas);
    if (division.hasWings) _paintWings(canvas);
    if (division.hasLaurel) _paintLaurel(canvas);
    if (division.hasCrown) _paintCrown(canvas);
    _paintShield(canvas);
    _paintNumber(canvas);
    _paintStars(canvas);

    canvas.restore();
  }

  Paint _gradientPaint(Rect bounds, {bool reverse = false}) {
    final colors = reverse
        ? [division.colors[1], division.colors[2]]
        : division.colors;
    return Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: colors,
      ).createShader(bounds);
  }

  void _paintRays(Canvas canvas) {
    final accent = division.colors[1];
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [accent.withValues(alpha: 0.42), accent.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: const Offset(60, 70), radius: 58));
    canvas.drawCircle(const Offset(60, 70), 58, glow);

    final rayPaint = Paint()
      ..color = accent.withValues(alpha: 0.36)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var index = 0; index < 12; index++) {
      final angle = math.pi / 6 * index;
      canvas.drawLine(
        Offset(60 + math.cos(angle) * 44, 70 + math.sin(angle) * 44),
        Offset(60 + math.cos(angle) * 58, 70 + math.sin(angle) * 58),
        rayPaint,
      );
    }
  }

  void _paintWings(Canvas canvas) {
    final fill = _gradientPaint(
      const Rect.fromLTWH(0, 46, 120, 44),
      reverse: true,
    );
    final stroke = Paint()
      ..color = division.stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;

    final left = Path()
      ..moveTo(30, 52)
      ..cubicTo(10, 46, -2, 58, 4, 74)
      ..cubicTo(10, 68, 18, 66, 26, 68)
      ..cubicTo(16, 72, 10, 78, 10, 88)
      ..cubicTo(20, 82, 32, 78, 36, 72)
      ..close();
    canvas.drawPath(left, fill);
    canvas.drawPath(left, stroke);

    final right = Path()
      ..moveTo(90, 52)
      ..cubicTo(110, 46, 122, 58, 116, 74)
      ..cubicTo(110, 68, 102, 66, 94, 68)
      ..cubicTo(104, 72, 110, 78, 110, 88)
      ..cubicTo(100, 82, 88, 78, 84, 72)
      ..close();
    canvas.drawPath(right, fill);
    canvas.drawPath(right, stroke);
  }

  void _paintLaurel(Canvas canvas) {
    final leafPaint = _gradientPaint(
      const Rect.fromLTWH(20, 48, 80, 52),
      reverse: true,
    );
    for (final side in [-1.0, 1.0]) {
      for (var index = 0; index < 5; index++) {
        final t = index / 4;
        final x = 60 + side * (26 + t * 6);
        final y = 98 - t * 40;
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(side * (-0.7 - index * 0.14));
        canvas.drawOval(
          Rect.fromCenter(center: Offset.zero, width: 9.2, height: 4.8),
          leafPaint,
        );
        canvas.restore();
      }
    }
  }

  void _paintCrown(Canvas canvas) {
    final crown = Path()
      ..moveTo(42, 26)
      ..lineTo(49, 12)
      ..lineTo(56, 23)
      ..lineTo(60, 9)
      ..lineTo(64, 23)
      ..lineTo(71, 12)
      ..lineTo(78, 26)
      ..lineTo(75, 31)
      ..lineTo(45, 31)
      ..close();
    canvas.drawPath(crown, _gradientPaint(const Rect.fromLTWH(42, 9, 36, 22)));
    canvas.drawPath(
      crown,
      Paint()
        ..color = division.stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7,
    );
    final jewelPaint = Paint()..color = division.highlight;
    canvas.drawCircle(const Offset(49, 12), 1.7, jewelPaint);
    canvas.drawCircle(const Offset(60, 9), 2, jewelPaint);
    canvas.drawCircle(const Offset(71, 12), 1.7, jewelPaint);
  }

  void _paintShield(Canvas canvas) {
    final outer = Path()
      ..moveTo(60, 28)
      ..lineTo(98, 40)
      ..lineTo(98, 76)
      ..cubicTo(98, 100, 82, 116, 60, 126)
      ..cubicTo(38, 116, 22, 100, 22, 76)
      ..lineTo(22, 40)
      ..close();
    canvas.drawPath(outer, Paint()..color = division.stroke);

    final inner = Path()
      ..moveTo(60, 31)
      ..lineTo(95, 42)
      ..lineTo(95, 76)
      ..cubicTo(95, 98, 80, 113, 60, 122)
      ..cubicTo(40, 113, 25, 98, 25, 76)
      ..lineTo(25, 42)
      ..close();
    canvas.drawPath(inner, _gradientPaint(const Rect.fromLTWH(25, 31, 70, 91)));

    final inset = Path()
      ..moveTo(60, 38)
      ..lineTo(89, 48)
      ..lineTo(89, 76)
      ..cubicTo(89, 94, 76, 107, 60, 115)
      ..cubicTo(44, 107, 31, 94, 31, 76)
      ..lineTo(31, 48)
      ..close();
    canvas.drawPath(
      inset,
      Paint()
        ..color = division.highlight.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _paintNumber(Canvas canvas) {
    final text = division.number.toString();
    final shadow = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: division.stroke.withValues(alpha: 0.28),
          fontSize: 42,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    shadow.paint(canvas, Offset(60 - shadow.width / 2, 50));

    final number = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: division.highlight,
          fontSize: 42,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    number.paint(canvas, Offset(60 - number.width / 2, 48));
  }

  void _paintStars(Canvas canvas) {
    final totalWidth = division.stars * 9.0;
    for (var index = 0; index < division.stars; index++) {
      final center = Offset(-totalWidth / 2 + 64.5 + index * 9, 110);
      final star = Path();
      for (var point = 0; point < 10; point++) {
        final angle = math.pi / 5 * point - math.pi / 2;
        final radius = point.isEven ? 3.6 : 1.62;
        final offset = Offset(
          center.dx + math.cos(angle) * radius,
          center.dy + math.sin(angle) * radius,
        );
        if (point == 0) {
          star.moveTo(offset.dx, offset.dy);
        } else {
          star.lineTo(offset.dx, offset.dy);
        }
      }
      star.close();
      canvas.drawPath(star, Paint()..color = division.highlight);
      canvas.drawPath(
        star,
        Paint()
          ..color = division.stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.4,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DivisionCrestPainter oldDelegate) {
    return oldDelegate.division != division;
  }
}
