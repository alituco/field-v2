import 'package:flutter/material.dart';

/// Tokens taken from the supplied Fieldrush HTML, shared by account surfaces.
abstract final class FieldrushAuthTheme {
  static const cream = Color(0xFFFAF7EF);
  static const ink = Color(0xFF22301F);
  static const forest = Color(0xFF386641);
  static const muted = Color(0xFF55654A);
  static const border = Color(0xFFE6DFCB);
  static const danger = Color(0xFFA63A3C);
  static const watermark = Color(0xFFEEE8D8);

  static ThemeData theme(BuildContext context) {
    final base = Theme.of(context);
    return base.copyWith(
      scaffoldBackgroundColor: cream,
      colorScheme: ColorScheme.fromSeed(
        seedColor: forest,
        brightness: Brightness.light,
        primary: forest,
        onPrimary: Colors.white,
        surface: cream,
        onSurface: ink,
        error: danger,
      ),
      textTheme: ThemeData.light().textTheme.apply(
        fontFamily: 'PlusJakartaSans',
        bodyColor: ink,
        displayColor: ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: cream,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: forest,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          textStyle: const TextStyle(
            fontFamily: 'PlusJakartaSans',
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: forest,
          minimumSize: const Size(44, 44),
          textStyle: const TextStyle(
            fontFamily: 'PlusJakartaSans',
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: false,
        contentPadding: EdgeInsets.symmetric(vertical: 12),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: border, width: 2),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: forest, width: 2.5),
        ),
        errorBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: danger, width: 2),
        ),
        focusedErrorBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: danger, width: 2.5),
        ),
        labelStyle: TextStyle(
          color: muted,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
        ),
        errorMaxLines: 3,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? forest : null,
        ),
      ),
    );
  }
}

/// Google mark, using the four vector fills embedded in the supplied HTML.
class FieldrushGoogleMark extends StatelessWidget {
  const FieldrushGoogleMark({super.key});

  @override
  Widget build(BuildContext context) => const ExcludeSemantics(
    child: SizedBox(
      width: 20,
      height: 20,
      child: CustomPaint(painter: _GooglePainter()),
    ),
  );
}

class _GooglePainter extends CustomPainter {
  const _GooglePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 48, size.height / 48);
    final gold = Path()
      ..moveTo(43.611, 20.083)
      ..lineTo(42, 20.083)
      ..lineTo(42, 20)
      ..lineTo(24, 20)
      ..lineTo(24, 28)
      ..lineTo(35.303, 28)
      ..cubicTo(33.654, 32.657, 29.223, 36, 24, 36)
      ..cubicTo(17.373, 36, 12, 30.627, 12, 24)
      ..cubicTo(12, 17.373, 17.373, 12, 24, 12)
      ..cubicTo(27.059, 12, 29.842, 13.154, 31.961, 15.039)
      ..lineTo(37.618, 9.382)
      ..cubicTo(34.046, 6.053, 29.268, 4, 24, 4)
      ..cubicTo(12.955, 4, 4, 12.955, 4, 24)
      ..cubicTo(4, 35.045, 12.955, 44, 24, 44)
      ..cubicTo(35.045, 44, 44, 35.045, 44, 24)
      ..cubicTo(44, 22.659, 43.862, 21.35, 43.611, 20.083)
      ..close();
    final red = Path()
      ..moveTo(6.306, 14.691)
      ..lineTo(12.877, 19.51)
      ..cubicTo(14.655, 15.108, 18.961, 12, 24, 12)
      ..cubicTo(27.059, 12, 29.842, 13.154, 31.961, 15.039)
      ..lineTo(37.618, 9.382)
      ..cubicTo(34.046, 6.053, 29.268, 4, 24, 4)
      ..cubicTo(16.318, 4, 9.656, 8.337, 6.306, 14.691)
      ..close();
    final green = Path()
      ..moveTo(24, 44)
      ..cubicTo(29.166, 44, 33.86, 42.023, 37.409, 38.808)
      ..lineTo(31.219, 33.57)
      ..cubicTo(29.211, 35.091, 26.715, 36, 24, 36)
      ..cubicTo(18.798, 36, 14.381, 32.683, 12.717, 28.054)
      ..lineTo(6.195, 33.079)
      ..cubicTo(9.505, 39.556, 16.227, 44, 24, 44)
      ..close();
    final blue = Path()
      ..moveTo(43.611, 20.083)
      ..lineTo(42, 20.083)
      ..lineTo(42, 20)
      ..lineTo(24, 20)
      ..lineTo(24, 28)
      ..lineTo(35.303, 28)
      ..cubicTo(34.511, 30.237, 33.072, 32.166, 31.216, 33.571)
      ..lineTo(37.409, 38.807)
      ..cubicTo(36.971, 39.205, 44, 34, 44, 24)
      ..cubicTo(44, 22.659, 43.862, 21.35, 43.611, 20.083)
      ..close();
    for (final (path, color) in [
      (gold, const Color(0xFFFFC107)),
      (red, const Color(0xFFFF3D00)),
      (green, const Color(0xFF4CAF50)),
      (blue, const Color(0xFF1976D2)),
    ]) {
      canvas.drawPath(path, Paint()..color = color);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GooglePainter oldDelegate) => false;
}
