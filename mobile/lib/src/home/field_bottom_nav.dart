import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
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

class _FieldBottomNavState extends State<FieldBottomNav>
    with TickerProviderStateMixin {
  static const _labels = ['Home', 'Fixtures', 'Clans', 'Ranks', 'You'];
  final _dockKey = GlobalKey();
  double? _scrubPosition;
  bool _scrubInside = true;
  late final AnimationController _position;
  late final AnimationController _press;
  double _motionTarget = 0;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _motionTarget = widget.selectedIndex?.toDouble() ?? 0;
    _position = AnimationController.unbounded(vsync: this, value: _motionTarget)
      ..addListener(_repaintMotion);
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 170),
      reverseDuration: const Duration(milliseconds: 280),
    )..addListener(_repaintMotion);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _position.value = _motionTarget;
      _press.value = 0;
    }
  }

  @override
  void didUpdateWidget(covariant FieldBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex &&
        (_scrubPosition == null || !_scrubInside)) {
      _animatePosition(widget.selectedIndex?.toDouble() ?? 0);
    }
  }

  void _repaintMotion() => setState(() {});

  void _animatePosition(double target) {
    _motionTarget = target;
    if (_reduceMotion) {
      _position.value = target;
      return;
    }
    _position.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 380, damping: 26),
        _position.value,
        target,
        // Preserve momentum when an in-flight settle is redirected.
        _position.velocity.clamp(-18.0, 18.0),
        tolerance: const Tolerance(distance: .001, velocity: .01),
        snapToEnd: true,
      ),
    );
  }

  @override
  void dispose() {
    _position.dispose();
    _press.dispose();
    super.dispose();
  }

  void _moveScrub(Offset globalPosition) {
    final box = _dockKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    final width = (box.size.width - 8) / _labels.length;
    final position = ((local.dx - 4) / width - .5).clamp(0.0, 4.0);
    final inside = (Offset.zero & box.size).inflate(24).contains(local);
    final wasInside = _scrubPosition != null && _scrubInside;
    if (_scrubPosition?.round() != position.round() && inside) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      _scrubPosition = position;
      _scrubInside = inside;
    });
    if (inside) {
      // Follow each pointer sample directly. Restarting a spring on every
      // update can starve it of animation time, leaving the glass behind the
      // finger. Only snap to a tab with a spring after the gesture finishes.
      _motionTarget = position;
      _position.value = position;
    } else if (wasInside) {
      _animatePosition(widget.selectedIndex?.toDouble() ?? 0);
    }
    // Let the press animation progress even while pointer events keep coming.
    if (!_reduceMotion && inside != wasInside) {
      if (inside) {
        _press.forward();
      } else {
        _press.reverse();
      }
    }
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
    _press.reverse();
    _animatePosition(widget.selectedIndex?.toDouble() ?? 0);
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
    final hasSelection = preview != null || widget.selectedIndex != null;
    final position = _position.value.clamp(0.0, 4.0);
    final engagement = _reduceMotion
        ? 0.0
        : Curves.easeOut.transform(_press.value);
    final lag = (_motionTarget - _position.value).clamp(-1.0, 1.0);
    final stretch = _reduceMotion
        ? 0.0
        : (lag.abs() * .15 + _position.velocity.abs() * .006).clamp(0.0, .20);
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
            // An accepted horizontal drag reports PointerCancel as onEnd.
            // Clear its preview first so an OS interruption never changes tabs.
            child: Listener(
              onPointerCancel: ios ? (_) => _cancelScrub() : null,
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
                      if (hasSelection)
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: LayoutBuilder(
                            builder: (context, constraints) => Align(
                              alignment: Alignment(-1 + position / 2, 0),
                              child: Transform.scale(
                                scaleX: 1 + engagement * .04 + stretch,
                                scaleY: 1 + engagement * .045 - stretch * .22,
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
                                            begin: Alignment(
                                              -.7 + lag * .3,
                                              -1,
                                            ),
                                            end: Alignment(.7 + lag * .3, 1),
                                            colors: [
                                              Colors.white.withValues(
                                                alpha: .20,
                                              ),
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
                                          child: _animatedIcon(
                                            index: index,
                                            position: position,
                                            engagement: ios ? engagement : 0,
                                            lag: lag,
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
                                                selected: selected == index,
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
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _animatedIcon({
    required int index,
    required double position,
    required double engagement,
    required double lag,
    required Widget child,
  }) {
    final proximity = (1 - (position - index).abs()).clamp(0.0, 1.0);
    final lift = engagement * Curves.easeOut.transform(proximity);
    return Transform.translate(
      offset: Offset(lag * lift * 1.5, -3.5 * lift),
      child: Transform.rotate(
        angle: lag * lift * .075,
        child: Transform.scale(scale: 1 + lift * .16, child: child),
      ),
    );
  }

  Widget _icon(
    int index,
    Color color,
    String? avatarUrl, {
    required bool selected,
  }) {
    final fallback = TweenAnimationBuilder<double>(
      tween: Tween(end: selected ? 1 : 0),
      duration: _reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      builder: (context, fill, child) =>
          CustomPaint(painter: _NavIcon(index, color, fill)),
    );
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
  const _NavIcon(this.index, this.color, this.fill);
  final int index;
  final Color color;
  final double fill;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillPen = Paint()..color = color.withValues(alpha: color.a * fill);
    void shape(Path path, {Path? cutouts}) {
      if (fill > 0) {
        canvas.drawPath(
          cutouts == null
              ? path
              : Path.combine(PathOperation.difference, path, cutouts),
          fillPen,
        );
      }
      canvas.drawPath(path, pen);
    }

    switch (index) {
      case 0:
        shape(
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
        );
      case 1:
        final cutouts = Path()
          ..addRect(const Rect.fromLTWH(4.5, 9.25, 15, 1.5));
        for (final offset in const [
          Offset(7, 12.5),
          Offset(13.5, 12.5),
          Offset(7, 16.5),
          Offset(13.5, 16.5),
        ]) {
          cutouts.addRRect(
            RRect.fromRectAndRadius(
              offset & const Size(2.5, 2),
              const Radius.circular(.5),
            ),
          );
        }
        shape(
          Path()..addRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(3.5, 5, 17, 15.5),
              const Radius.circular(2.5),
            ),
          ),
          cutouts: cutouts,
        );
        canvas.drawLine(
          const Offset(3.5, 10),
          const Offset(20.5, 10),
          Paint()
            ..color = color.withValues(alpha: color.a * (1 - fill))
            ..strokeWidth = 1.9,
        );
        canvas.drawPath(
          Path()
            ..moveTo(8, 3)
            ..lineTo(8, 7)
            ..moveTo(16, 3)
            ..lineTo(16, 7),
          pen,
        );
      case 2:
        shape(
          Path()
            ..moveTo(12, 3.5)
            ..lineTo(19, 6)
            ..lineTo(19, 11.4)
            ..cubicTo(19, 15.8, 16.1, 19, 12, 20.5)
            ..cubicTo(7.9, 19, 5, 15.8, 5, 11.4)
            ..lineTo(5, 6)
            ..close(),
        );
      case 3:
        for (final rect in [
          const Rect.fromLTWH(3.5, 13, 5.5, 7.5),
          const Rect.fromLTWH(9.25, 7.5, 5.5, 13),
          const Rect.fromLTWH(15, 10.5, 5.5, 10),
        ]) {
          shape(
            Path()..addRRect(
              RRect.fromRectAndRadius(rect, const Radius.circular(1)),
            ),
          );
        }
      case 4:
        if (fill > 0) {
          canvas.drawCircle(const Offset(12, 8.2), 3.8, fillPen);
        }
        canvas.drawCircle(const Offset(12, 8.2), 3.8, pen);
        final shoulders = Path()
          ..moveTo(4.8, 20.5)
          ..cubicTo(5.7, 16.6, 8.4, 14.5, 12, 14.5)
          ..cubicTo(15.6, 14.5, 18.3, 16.6, 19.2, 20.5);
        if (fill > 0) canvas.drawPath(Path.from(shoulders)..close(), fillPen);
        canvas.drawPath(shoulders, pen);
    }
  }

  @override
  bool shouldRepaint(_NavIcon oldDelegate) =>
      index != oldDelegate.index ||
      color != oldDelegate.color ||
      fill != oldDelegate.fill;
}
