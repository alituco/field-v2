import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';

/// The floating, frosted navigation from the Fieldrush reference.
class FieldBottomNav extends StatelessWidget {
  const FieldBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int? selectedIndex;
  final ValueChanged<int> onSelected;
  static const _labels = ['Home', 'Fixtures', 'Clans', 'Ranks', 'You'];

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(13, 0, 13, 15),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: FieldrushAuthTheme.ink.withValues(alpha: .3),
              blurRadius: 34,
              spreadRadius: -10,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              key: const ValueKey('field-liquid-glass-nav'),
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
              decoration: BoxDecoration(
                color: FieldrushAuthTheme.cream.withValues(alpha: .58),
                border: Border.all(color: Colors.white.withValues(alpha: .8)),
                borderRadius: BorderRadius.circular(32),
              ),
              child: Row(
                children: [
                  for (var index = 0; index < _labels.length; index++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Semantics(
                          selected: selectedIndex == index,
                          button: true,
                          label: _labels[index],
                          onTap: () => onSelected(index),
                          excludeSemantics: true,
                          child: AnimatedContainer(
                            key: selectedIndex == index
                                ? const ValueKey('field-liquid-glass-selection')
                                : null,
                            duration: const Duration(milliseconds: 180),
                            decoration: BoxDecoration(
                              color: selectedIndex == index
                                  ? FieldrushAuthTheme.forest
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(25),
                              boxShadow: selectedIndex == index
                                  ? [
                                      BoxShadow(
                                        color: FieldrushAuthTheme.ink
                                            .withValues(alpha: .42),
                                        offset: const Offset(0, 4),
                                        blurRadius: 12,
                                        spreadRadius: -2,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: ValueKey('field-bottom-nav-item-$index'),
                                borderRadius: BorderRadius.circular(25),
                                onTap: () => onSelected(index),
                                child: SizedBox(
                                  height: 52,
                                  width: double.infinity,
                                  child: Center(
                                    child: SizedBox(
                                      key: ValueKey(
                                        'field-bottom-nav-icon-$index',
                                      ),
                                      width: 36,
                                      height: 36,
                                      child: CustomPaint(
                                        painter: _NavIcon(
                                          index,
                                          selectedIndex == index
                                              ? Colors.white
                                              : const Color(0xFF414A42),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavIcon extends CustomPainter {
  const _NavIcon(this.index, this.color);
  final int index;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (index) {
      case 0:
        canvas.drawPath(
          Path()
            ..moveTo(4, 10.4)
            ..lineTo(12, 4)
            ..lineTo(20, 10.4)
            ..lineTo(20, 19)
            ..quadraticBezierTo(20, 20.5, 18.5, 20.5)
            ..lineTo(15, 20.5)
            ..lineTo(15, 15)
            ..lineTo(9, 15)
            ..lineTo(9, 20.5)
            ..lineTo(5.5, 20.5)
            ..quadraticBezierTo(4, 20.5, 4, 19)
            ..close(),
          pen,
        );
      case 1:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(3.5, 5, 17, 15.5),
            const Radius.circular(2.5),
          ),
          pen,
        );
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 10)
            ..lineTo(20.5, 10)
            ..moveTo(8, 3)
            ..lineTo(8, 7)
            ..moveTo(16, 3)
            ..lineTo(16, 7),
          pen,
        );
      case 2:
        canvas.drawPath(
          Path()
            ..moveTo(12, 3.5)
            ..lineTo(19, 6)
            ..lineTo(19, 11.4)
            ..cubicTo(19, 15.8, 16.1, 19, 12, 20.5)
            ..cubicTo(7.9, 19, 5, 15.8, 5, 11.4)
            ..lineTo(5, 6)
            ..close(),
          pen,
        );
      case 3:
        for (final rect in [
          const Rect.fromLTWH(3.5, 13, 5.5, 7.5),
          const Rect.fromLTWH(9.25, 7.5, 5.5, 13),
          const Rect.fromLTWH(15, 10.5, 5.5, 10),
        ]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(1)),
            pen,
          );
        }
      case 4:
        canvas.drawCircle(const Offset(12, 8.2), 3.8, pen);
        canvas.drawPath(
          Path()
            ..moveTo(4.8, 20.5)
            ..cubicTo(5.7, 16.6, 8.4, 14.5, 12, 14.5)
            ..cubicTo(15.6, 14.5, 18.3, 16.6, 19.2, 20.5),
          pen,
        );
    }
  }

  @override
  bool shouldRepaint(_NavIcon oldDelegate) =>
      index != oldDelegate.index || color != oldDelegate.color;
}
