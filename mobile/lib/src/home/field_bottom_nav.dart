import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/fieldrush_auth_theme.dart';
import 'native_glass_surface.dart';
import 'navigation_profile_scope.dart';

/// Compact glass dock. iOS can scrub across tabs before committing on release.
class FieldBottomNav extends StatefulWidget {
  const FieldBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.profileAvatarUrl,
  });

  final int? selectedIndex;
  final ValueChanged<int> onSelected;
  final String? profileAvatarUrl;

  @override
  State<FieldBottomNav> createState() => _FieldBottomNavState();
}

class _FieldBottomNavState extends State<FieldBottomNav> {
  static const _labels = ['Home', 'Fixtures', 'Clans', 'Ranks', 'You'];
  final _dockKey = GlobalKey();
  double? _scrubPosition;
  bool _scrubInside = true;

  void _moveScrub(Offset globalPosition) {
    final box = _dockKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    final width = (box.size.width - 8) / _labels.length;
    final position = ((local.dx - 4) / width - .5).clamp(0.0, 4.0);
    final inside = (Offset.zero & box.size).inflate(24).contains(local);
    if (_scrubPosition?.round() != position.round() && inside) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      _scrubPosition = position;
      _scrubInside = inside;
    });
  }

  void _endScrub() {
    final target = _scrubInside ? _scrubPosition?.round() : null;
    _cancelScrub();
    // One callback per gesture: account/checkout routes may ask before leaving.
    if (target != null && target != widget.selectedIndex) {
      widget.onSelected(target);
    }
  }

  void _cancelScrub() {
    if (_scrubPosition == null) return;
    setState(() {
      _scrubPosition = null;
      _scrubInside = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    final ios = Theme.of(context).platform == TargetPlatform.iOS;
    final avatarUrl =
        widget.profileAvatarUrl ??
        FieldNavigationProfileScope.avatarUrlOf(context);
    final preview = _scrubInside ? _scrubPosition : null;
    final selected = preview?.round() ?? widget.selectedIndex;
    final position = preview ?? widget.selectedIndex?.toDouble();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion || preview != null
        ? Duration.zero
        : const Duration(milliseconds: 240);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: FieldrushAuthTheme.ink.withValues(alpha: .10),
                  blurRadius: 24,
                  spreadRadius: -7,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: GestureDetector(
              key: _dockKey,
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: ios
                  ? (details) => _moveScrub(details.globalPosition)
                  : null,
              onHorizontalDragUpdate: ios
                  ? (details) => _moveScrub(details.globalPosition)
                  : null,
              onHorizontalDragEnd: ios ? (_) => _endScrub() : null,
              onHorizontalDragCancel: ios ? _cancelScrub : null,
              onLongPressStart: ios
                  ? (details) => _moveScrub(details.globalPosition)
                  : null,
              onLongPressMoveUpdate: ios
                  ? (details) => _moveScrub(details.globalPosition)
                  : null,
              onLongPressEnd: ios ? (_) => _endScrub() : null,
              onLongPressCancel: ios ? _cancelScrub : null,
              child: SizedBox(
                key: const ValueKey('field-liquid-glass-nav'),
                height: 56,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const NativeGlassSurface(),
                    if (position != null)
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: LayoutBuilder(
                          builder: (context, constraints) => AnimatedAlign(
                            alignment: Alignment(-1 + position / 2, 0),
                            duration: duration,
                            curve: Curves.easeOutCubic,
                            child: AnimatedScale(
                              scale: preview == null || reduceMotion ? 1 : 1.04,
                              duration: reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 140),
                              child: Container(
                                key: const ValueKey(
                                  'field-liquid-glass-selection',
                                ),
                                width: constraints.maxWidth / _labels.length,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: ios
                                      ? FieldrushAuthTheme.forest.withValues(
                                          alpha: .06,
                                        )
                                      : FieldrushAuthTheme.forest,
                                  borderRadius: BorderRadius.circular(24),
                                  border: ios
                                      ? Border.all(
                                          color: Colors.white.withValues(
                                            alpha: .45,
                                          ),
                                        )
                                      : null,
                                  gradient: ios
                                      ? LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            Colors.white.withValues(alpha: .20),
                                            FieldrushAuthTheme.forest
                                                .withValues(alpha: .04),
                                          ],
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        children: [
                          for (var index = 0; index < _labels.length; index++)
                            Expanded(
                              child: Semantics(
                                selected: widget.selectedIndex == index,
                                button: true,
                                label: _labels[index],
                                onTap: () => widget.onSelected(index),
                                excludeSemantics: true,
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    key: ValueKey(
                                      'field-bottom-nav-item-$index',
                                    ),
                                    borderRadius: BorderRadius.circular(24),
                                    onTap: () => widget.onSelected(index),
                                    child: SizedBox(
                                      height: 48,
                                      width: double.infinity,
                                      child: Center(
                                        child: SizedBox(
                                          key: ValueKey(
                                            'field-bottom-nav-icon-$index',
                                          ),
                                          width: 32,
                                          height: 32,
                                          child: _icon(
                                            index,
                                            selected == index && !ios
                                                ? Colors.white
                                                : selected == index
                                                ? FieldrushAuthTheme.forest
                                                : const Color(0xFF414A42),
                                            avatarUrl,
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _icon(int index, Color color, String? avatarUrl) {
    final fallback = CustomPaint(painter: _NavIcon(index, color));
    if (index != 4 || avatarUrl == null || avatarUrl.trim().isEmpty) {
      return fallback;
    }
    return ClipOval(
      child: Image.network(
        avatarUrl.trim(),
        key: const ValueKey('field-you-nav-avatar'),
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, synchronous) =>
            frame == null && !synchronous ? fallback : child,
        errorBuilder: (context, error, stackTrace) => fallback,
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
