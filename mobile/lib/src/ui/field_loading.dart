import 'package:flutter/material.dart';

/// Quiet placeholders: no perpetual animation, flashing, or motion preference
/// exceptions. The owning region supplies the single accessible loading label.
class FieldSkeleton extends StatelessWidget {
  const FieldSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = 8,
    this.color,
  });

  final double? width;
  final double height;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: width ?? double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: color ?? const Color(0x1A386641),
        borderRadius: BorderRadius.circular(radius),
      ),
    ),
  );
}

/// Compact placeholder for an icon-sized async control or media preview.
/// Full sections should use content-shaped placeholders instead.
class FieldLoadingIndicator extends StatelessWidget {
  const FieldLoadingIndicator({super.key, this.label = 'Loading', this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: SizedBox(
      width: 32,
      height: 18,
      child: FittedBox(
        child: SizedBox(
          width: 32,
          height: 18,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FieldSkeleton(width: 32, height: 4, radius: 2, color: color),
              const SizedBox(height: 3),
              FieldSkeleton(width: 22, height: 4, radius: 2, color: color),
              const SizedBox(height: 3),
              FieldSkeleton(width: 27, height: 4, radius: 2, color: color),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Generic card/list skeleton for secondary screens. Primary surfaces can
/// compose [FieldSkeleton] directly to preserve their exact eventual layout.
class FieldLoadingContent extends StatelessWidget {
  const FieldLoadingContent({
    super.key,
    this.label = 'Loading',
    this.rows = 3,
    this.compact = false,
  }) : assert(rows > 0);

  final String label;
  final int rows;
  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final content = Padding(
            padding: EdgeInsets.all(compact ? 12 : 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < rows; index++) ...[
                  if (index > 0) SizedBox(height: compact ? 16 : 20),
                  Row(
                    children: [
                      FieldSkeleton(
                        width: compact ? 36 : 48,
                        height: compact ? 36 : 48,
                        radius: compact ? 12 : 16,
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FractionallySizedBox(
                              widthFactor: .72,
                              child: FieldSkeleton(height: 16),
                            ),
                            SizedBox(height: 9),
                            FractionallySizedBox(
                              widthFactor: .48,
                              child: FieldSkeleton(height: 10),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (!compact) ...[
                    const SizedBox(height: 16),
                    const FieldSkeleton(height: 58, radius: 14),
                  ],
                ],
              ],
            ),
          );
          return constraints.hasBoundedHeight
              ? SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: content,
                )
              : content;
        },
      ),
    ),
  );
}

/// Retains pull-to-refresh and existing content without the Material spinner.
class FieldRefreshIndicator extends StatefulWidget {
  const FieldRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
    this.color,
    this.edgeOffset = 0,
  });

  final RefreshCallback onRefresh;
  final Widget child;
  final Color? color;
  final double edgeOffset;

  @override
  State<FieldRefreshIndicator> createState() => _FieldRefreshIndicatorState();
}

class _FieldRefreshIndicatorState extends State<FieldRefreshIndicator> {
  RefreshIndicatorStatus? _status;

  @override
  Widget build(BuildContext context) {
    final active = switch (_status) {
      RefreshIndicatorStatus.drag ||
      RefreshIndicatorStatus.armed ||
      RefreshIndicatorStatus.snap ||
      RefreshIndicatorStatus.refresh => true,
      _ => false,
    };
    final label = switch (_status) {
      RefreshIndicatorStatus.drag => 'Pull to refresh',
      RefreshIndicatorStatus.armed => 'Release to refresh',
      _ => 'Refreshing',
    };
    return Stack(
      children: [
        RefreshIndicator.noSpinner(
          onRefresh: widget.onRefresh,
          onStatusChange: (status) {
            if (mounted) setState(() => _status = status);
          },
          child: widget.child,
        ),
        if (active)
          Positioned(
            top: widget.edgeOffset + 8,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Semantics(
                  label: label,
                  liveRegion: true,
                  child: Container(
                    key: const ValueKey('field-refresh-skeleton'),
                    width: 124,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE6DFCB)),
                    ),
                    child: FieldSkeleton(
                      height: 6,
                      radius: 3,
                      color: widget.color?.withValues(alpha: .24),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
