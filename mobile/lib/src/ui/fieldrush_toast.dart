import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The HTML's small, dark message pill. These notifications are app-wide, so a
/// success message remains visible when its originating sheet or route closes.
void showFieldrushToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 2200),
}) {
  if (message.trim().isEmpty) return;
  _showToast(
    context,
    content: Text(message, textAlign: TextAlign.center),
    duration: duration,
    compact: true,
  );
}

/// Keeps important structured notices and their acknowledgement action, while
/// using the same dark surface rather than the old Material notification bar.
void showFieldrushToastContent(
  BuildContext context,
  Widget content, {
  Duration duration = const Duration(milliseconds: 2200),
  String? actionLabel,
  VoidCallback? onAction,
}) {
  assert((actionLabel == null) == (onAction == null));
  _showToast(
    context,
    content: content,
    duration: duration,
    compact: false,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

final _activeToasts = Expando<_ToastHandle>('Fieldrush app toast');

void _showToast(
  BuildContext context, {
  required Widget content,
  required Duration duration,
  required bool compact,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  if (!context.mounted) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null || !overlay.mounted) return;
  final sourceMedia = MediaQuery.of(context);
  final direction = Directionality.of(context);
  _activeToasts[overlay]?.dismiss();
  final handle = _ToastHandle(
    overlay: overlay,
    duration: duration,
    accessibleAction: sourceMedia.accessibleNavigation && onAction != null,
  );
  handle.entry = OverlayEntry(
    builder: (overlayContext) => MediaQuery(
      data: MediaQuery.of(overlayContext).copyWith(
        textScaler: sourceMedia.textScaler,
        disableAnimations: sourceMedia.disableAnimations,
      ),
      child: Directionality(
        textDirection: direction,
        child: _ToastOverlay(
          handle: handle,
          compact: compact,
          content: content,
          actionLabel: actionLabel,
          onAction: onAction,
        ),
      ),
    ),
  );
  _activeToasts[overlay] = handle;
  overlay.insert(handle.entry);
}

class _ToastHandle {
  _ToastHandle({
    required this.overlay,
    required this.duration,
    required this.accessibleAction,
  });
  final OverlayState overlay;
  final Duration duration;
  final bool accessibleAction;
  late final OverlayEntry entry;
  Timer? _timer;
  bool _dismissed = false;

  void start() {
    if (!_dismissed && !accessibleAction) _timer = Timer(duration, dismiss);
  }

  void dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    _timer?.cancel();
    if (identical(_activeToasts[overlay], this)) _activeToasts[overlay] = null;
    entry
      ..remove()
      ..dispose();
  }

  void onWidgetDisposed() {
    _timer?.cancel();
    // If the entire navigator is going away, clean up after Flutter unlocks
    // its widget tree. A normal dismissal has already removed the entry.
    if (!_dismissed) scheduleMicrotask(dismiss);
  }
}

class _ToastOverlay extends StatefulWidget {
  const _ToastOverlay({
    required this.handle,
    required this.content,
    required this.compact,
    this.actionLabel,
    this.onAction,
  });
  final _ToastHandle handle;
  final Widget content;
  final bool compact;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<_ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<_ToastOverlay>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    widget.handle.start();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 1;
    } else {
      _animation.forward();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    widget.handle.onWidgetDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final desiredBottom = math.max(
      94 + media.padding.bottom,
      media.viewInsets.bottom + 16,
    );
    final bottom = math.min(
      desiredBottom,
      math.max(0.0, media.size.height - media.padding.top - 104),
    );
    final availableHeight = math.max(
      88.0,
      media.size.height - bottom - media.padding.top - 16,
    );
    final width = math.min(
      300.0,
      media.size.width - media.padding.left - media.padding.right - 32,
    );
    var needsScrolling = !widget.compact;
    if (widget.content case Text(:final data?)) {
      final painter = TextPainter(
        text: TextSpan(text: data, style: FieldrushToast.textStyle),
        textDirection: Directionality.of(context),
        textScaler: media.textScaler,
      )..layout(maxWidth: math.max(1, width - 32));
      needsScrolling = painter.height + 22 > availableHeight;
      painter.dispose();
    }
    return Positioned(
      left: math.max(16, media.padding.left + 16),
      right: math.max(16, media.padding.right + 16),
      bottom: bottom,
      child: Center(
        heightFactor: 1,
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _animation, curve: Curves.easeOut),
          child: IgnorePointer(
            ignoring: widget.onAction == null && !needsScrolling,
            child: FieldrushToast(
              content: widget.content,
              compact: widget.compact,
              maxHeight: availableHeight,
              actionLabel: widget.actionLabel,
              onAction: widget.onAction == null
                  ? null
                  : () {
                      if (widget.handle._dismissed) return;
                      try {
                        widget.onAction!();
                      } finally {
                        widget.handle.dismiss();
                      }
                    },
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared visual surface; message notifications hug their text up to 300 px.
class FieldrushToast extends StatelessWidget {
  const FieldrushToast({
    super.key,
    required this.content,
    this.compact = true,
    this.maxHeight,
    this.actionLabel,
    this.onAction,
  });
  static const background = Color(0xFF22301F);
  static const textStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: 12,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: Colors.white,
  );
  final Widget content;
  final bool compact;
  final double? maxHeight;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 300,
        maxHeight: maxHeight ?? double.infinity,
      ),
      child: IntrinsicWidth(
        child: DecoratedBox(
          key: const ValueKey('fieldrush-toast-surface'),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(compact ? 999 : 20),
            boxShadow: const [
              BoxShadow(
                color: Color(0xB3172415),
                offset: Offset(0, 12),
                blurRadius: 28,
                spreadRadius: -12,
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: DefaultTextStyle(
                style: textStyle,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      fit: FlexFit.loose,
                      child: SingleChildScrollView(child: content),
                    ),
                    if (actionLabel != null && onAction != null)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const ValueKey('fieldrush-toast-action'),
                          onPressed: onAction,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            minimumSize: const Size(44, 44),
                            textStyle: const TextStyle(
                              fontFamily: 'PlusJakartaSans',
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          child: Text(actionLabel!),
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
