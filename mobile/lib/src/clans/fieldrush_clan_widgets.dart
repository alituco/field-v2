import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';

TextStyle clanText(
  double size, {
  FontWeight weight = FontWeight.w700,
  Color color = FieldrushAuthTheme.ink,
  double height = 1.25,
}) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: 0,
);

TextStyle clanTitle(double size, {Color color = FieldrushAuthTheme.ink}) =>
    TextStyle(
      fontFamily: 'Outfit',
      fontSize: size,
      fontWeight: FontWeight.w800,
      color: color,
      height: 1.1,
      letterSpacing: -size * .01,
    );

const fieldrushClanColors = <String, (String, Color)>{
  'pitch': ('Green', Color(0xFF386641)),
  'electric': ('Royal blue', Color(0xFF22406F)),
  'sunset': ('Bronze', Color(0xFF8E5A33)),
  'shadow': ('Black', Color(0xFF1A1915)),
  'crimson': ('Red', Color(0xFFA63A3C)),
};

Color clanColor(String themeId) =>
    fieldrushClanColors[themeId]?.$2 ?? FieldrushAuthTheme.forest;

class FieldrushClanCard extends StatelessWidget {
  const FieldrushClanCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 20,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: FieldrushAuthTheme.border),
      borderRadius: BorderRadius.circular(radius),
    ),
    child: Padding(padding: padding, child: child),
  );
}

class FieldrushClanHeader extends StatelessWidget {
  const FieldrushClanHeader({
    super.key,
    required this.title,
    this.back = false,
    this.action,
  });
  final String title;
  final bool back;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
    child: Row(
      children: [
        if (back) ...[
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF3C4A38),
                side: const BorderSide(color: FieldrushAuthTheme.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.chevron_left_rounded, size: 22),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            title,
            style: clanTitle(back ? 18 : 25),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (action != null) action!,
      ],
    ),
  );
}

class FieldrushClanCrest extends StatelessWidget {
  const FieldrushClanCrest({
    super.key,
    required this.tag,
    this.themeId = 'pitch',
    this.size = 56,
    this.soft = false,
  });
  final String tag, themeId;
  final double size;
  final bool soft;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: soft ? Colors.white.withValues(alpha: .16) : clanColor(themeId),
      borderRadius: BorderRadius.circular(size / 3),
      border: soft
          ? Border.all(color: const Color(0x88C7DD9B), width: 1.5)
          : null,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          tag,
          style: clanTitle(size * .36, color: Colors.white),
          maxLines: 1,
        ),
      ),
    ),
  );
}

ButtonStyle clanButtonStyle({
  bool outlined = false,
  bool danger = false,
  double height = 46,
}) => OutlinedButton.styleFrom(
  backgroundColor: outlined ? Colors.white : FieldrushAuthTheme.forest,
  disabledBackgroundColor: const Color(0xFFEEE9DC),
  disabledForegroundColor: const Color(0xFF8E897A),
  foregroundColor: danger
      ? FieldrushAuthTheme.danger
      : outlined
      ? FieldrushAuthTheme.ink
      : Colors.white,
  minimumSize: Size(0, height),
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  side: outlined
      ? const BorderSide(color: FieldrushAuthTheme.border)
      : BorderSide.none,
  textStyle: clanText(12.5, weight: FontWeight.w800, height: 1),
);

class ClanGamesComingSoon extends StatelessWidget {
  const ClanGamesComingSoon({super.key});
  @override
  Widget build(BuildContext context) => FieldrushDashedBox(
    radius: 20,
    color: const Color(0xFFDED8C6),
    child: Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Clan games', style: clanTitle(14)),
                const SizedBox(height: 7),
                Text(
                  'Matches, rankings and match history are on the way.',
                  style: clanText(
                    11.5,
                    weight: FontWeight.w600,
                    color: FieldrushAuthTheme.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFF7EED6),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              'COMING SOON',
              style: clanText(
                9.5,
                weight: FontWeight.w800,
                color: const Color(0xFF8A6516),
                height: 1,
              ).copyWith(letterSpacing: 1.14),
            ),
          ),
        ],
      ),
    ),
  );
}

class FieldrushDashedBox extends StatelessWidget {
  const FieldrushDashedBox({
    super.key,
    required this.child,
    this.radius = 18,
    this.color = const Color(0xFFC9C2AE),
  });
  final Widget child;
  final double radius;
  final Color color;
  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: _ClanDashedBorder(radius, color),
    child: child,
  );
}

class _ClanDashedBorder extends CustomPainter {
  const _ClanDashedBorder(this.radius, this.color);
  final double radius;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.75),
          Radius.circular(radius),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (var start = 0.0; start < metric.length; start += 9) {
        canvas.drawPath(
          metric.extractPath(start, (start + 5).clamp(0, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ClanDashedBorder old) =>
      old.radius != radius || old.color != color;
}
