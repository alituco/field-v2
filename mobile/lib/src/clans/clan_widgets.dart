import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'clan.dart';

const fieldBackground = Color(0xFFF9FAFB);
const fieldGray900 = Color(0xFF111827);
const fieldGray700 = Color(0xFF374151);
const fieldGray600 = Color(0xFF4B5563);
const fieldGray500 = Color(0xFF6B7280);
const fieldGray400 = Color(0xFF9CA3AF);
const fieldGray300 = Color(0xFFD1D5DB);
const fieldGray200 = Color(0xFFE5E7EB);
const fieldGray100 = Color(0xFFF3F4F6);
const fieldEmerald600 = Color(0xFF059669);
const fieldEmerald500 = Color(0xFF10B981);
const fieldBlue600 = Color(0xFF2563EB);

enum HeaderActionTone { blue, pink }

class FieldSkeletonBox extends StatefulWidget {
  const FieldSkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = 12,
  });

  final double? width;
  final double height;
  final double borderRadius;

  @override
  State<FieldSkeletonBox> createState() => _FieldSkeletonBoxState();
}

class _FieldSkeletonBoxState extends State<FieldSkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(
        width: widget.width ?? double.infinity,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-1.8 + (_controller.value * 3.6), 0),
                  end: Alignment(-0.4 + (_controller.value * 3.6), 0),
                  colors: const [fieldGray100, Color(0xFFF9FAFB), fieldGray100],
                  stops: const [0.1, 0.5, 0.9],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class FieldSkeletonCard extends StatelessWidget {
  const FieldSkeletonCard({
    super.key,
    required this.height,
    this.borderRadius = 16,
    this.padding = const EdgeInsets.all(16),
    this.children = const [],
  });

  final double height;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: fieldGray900.withValues(alpha: 0.025),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: children.isEmpty
          ? const FieldSkeletonBox(height: double.infinity)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
    );
  }
}

class FieldPageHeader extends StatelessWidget {
  const FieldPageHeader({
    super.key,
    required this.title,
    this.showBack = false,
    this.rightAction,
    this.onBack,
  });

  final String title;
  final bool showBack;
  final Widget? rightAction;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return SizedBox(
      height: topInset + 64,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.38),
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.white.withValues(alpha: 0.28),
                      ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: fieldGray900.withValues(alpha: 0.035),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Color(0x9910B981),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SizedBox(height: 2),
            ),
          ),
          Positioned(
            top: topInset,
            left: 0,
            right: 0,
            height: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (showBack)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _HeaderBackButton(
                              onPressed:
                                  onBack ?? () => Navigator.of(context).pop(),
                            ),
                          ),
                        const SizedBox(
                          width: 4,
                          height: 24,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [fieldEmerald500, fieldBlue600],
                              ),
                              borderRadius: BorderRadius.all(
                                Radius.circular(99),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            title.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: fieldGray900,
                              fontSize: 20,
                              height: 1,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (rightAction != null) ...[
                    const SizedBox(width: 12),
                    rightAction!,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FieldHeaderOverlay extends StatelessWidget {
  const FieldHeaderOverlay({
    super.key,
    required this.header,
    required this.child,
  });

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(top: 0, left: 0, right: 0, child: header),
      ],
    );
  }
}

double fieldPageHeaderExtent(BuildContext context) {
  return MediaQuery.paddingOf(context).top + 64;
}

EdgeInsets fieldHeaderAwarePadding(
  BuildContext context, {
  double left = 16,
  double top = 16,
  double right = 16,
  double bottom = 28,
}) {
  return EdgeInsets.fromLTRB(
    left,
    fieldPageHeaderExtent(context) + top,
    right,
    bottom,
  );
}

class _HeaderBackButton extends StatelessWidget {
  const _HeaderBackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            border: Border.all(color: fieldGray200),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: const Icon(Icons.arrow_back_rounded, size: 18),
        ),
      ),
    );
  }
}

class HeaderActionButton extends StatefulWidget {
  const HeaderActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tone = HeaderActionTone.blue,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final HeaderActionTone tone;

  @override
  State<HeaderActionButton> createState() => _HeaderActionButtonState();
}

class _HeaderActionButtonState extends State<HeaderActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = switch (widget.tone) {
      HeaderActionTone.blue => const [
        Color(0xFF3B82F6),
        Color(0xFF6366F1),
        Color(0xFF7C3AED),
      ],
      HeaderActionTone.pink => const [
        Color(0xFFFF2D7D),
        Color(0xFFFF3366),
        Color(0xFFFF6B1A),
      ],
    };
    final shadowColor = switch (widget.tone) {
      HeaderActionTone.blue => const Color(0xFF3B82F6),
      HeaderActionTone.pink => const Color(0xFFFF2D7D),
    };

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onPressed,
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1,
        duration: const Duration(milliseconds: 120),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  final phase = math.sin(_pulseController.value * math.pi);
                  return Transform.scale(
                    scale: 1 + (phase * 0.18),
                    child: Opacity(opacity: 0.6 * (1 - phase), child: child),
                  );
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              height: 46,
              padding: const EdgeInsets.only(left: 14, right: 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                ),
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: shadowColor.withValues(alpha: 0.38),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    widget.label.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FieldHeroBanner extends StatefulWidget {
  const FieldHeroBanner({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.chips,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<HeroChip> chips;

  @override
  State<FieldHeroBanner> createState() => _FieldHeroBannerState();
}

class _FieldHeroBannerState extends State<FieldHeroBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: const RadialGradient(
            center: Alignment(1, -1),
            radius: 1.35,
            colors: [Color(0xFF22D3EE), Color(0xFF3B82F6), Color(0xFF1E1B4B)],
            stops: [0, 0.45, 1],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3B82F6).withValues(alpha: 0.34),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            const Positioned.fill(
              child: CustomPaint(painter: _PitchLinesPainter()),
            ),
            Positioned(
              top: -72,
              right: -72,
              child: AnimatedBuilder(
                animation: _glowController,
                builder: (context, child) {
                  final phase = math.sin(_glowController.value * math.pi * 2);
                  return Transform.scale(
                    scale: 1.08 + (phase * 0.08),
                    child: Opacity(
                      opacity: 0.24 + (phase * 0.06),
                      child: child,
                    ),
                  );
                },
                child: Container(
                  width: 224,
                  height: 224,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF67E8F9),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0xFF67E8F9),
                        blurRadius: 54,
                        spreadRadius: 18,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 24,
                                height: 2,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.70),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  widget.eyebrow.toUpperCase(),
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xE6CFFAFE),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.title.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              height: 1.05,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.subtitle,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 14,
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 520),
                      curve: Curves.easeOutBack,
                      builder: (context, value, child) {
                        return Transform.rotate(
                          angle: (-8 + (8 * value)) * math.pi / 180,
                          child: Transform.scale(
                            scale: 0.88 + (0.12 * value),
                            child: child,
                          ),
                        );
                      },
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          widget.icon,
                          color: const Color(0xFFDBEAFE),
                          size: 28,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < widget.chips.length; i++)
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: Duration(milliseconds: 300 + (i * 80)),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, child) {
                          return Opacity(
                            opacity: value,
                            child: Transform.translate(
                              offset: Offset(0, 6 * (1 - value)),
                              child: child,
                            ),
                          );
                        },
                        child: _HeroChipView(chip: widget.chips[i]),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class HeroChip {
  const HeroChip({required this.label, required this.value});

  final String label;
  final String value;
}

class _HeroChipView extends StatelessWidget {
  const _HeroChipView({required this.chip});

  final HeroChip chip;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            chip.value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            chip.label.toUpperCase(),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.80),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class ClanCard extends StatelessWidget {
  const ClanCard({super.key, required this.clan, required this.onTap});

  final Clan clan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rank = clan.rank;
    final theme = clan.theme;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: fieldGray200),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [theme.from, theme.to],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: theme.from.withValues(alpha: 0.28),
                      blurRadius: 14,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: PatternPainter(
                          pattern: clan.patternId,
                          color: theme.accent,
                        ),
                      ),
                    ),
                    Center(
                      child: Text(
                        clan.emblem,
                        style: const TextStyle(fontSize: 30),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            clan.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: fieldGray900,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          clan.tag,
                          style: const TextStyle(
                            color: fieldGray500,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _MiniMetric(
                          icon: Icons.group_rounded,
                          label: clan.memberCount.toString(),
                        ),
                        const SizedBox(width: 12),
                        _MiniMetric(
                          icon: Icons.trending_up_rounded,
                          iconColor: fieldEmerald600,
                          label: '${clan.winRate}%',
                          strong: true,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${clan.wins}W - ${clan.losses}L',
                          style: const TextStyle(
                            color: fieldGray600,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: SizedBox(
                              height: 8,
                              child: Stack(
                                children: [
                                  const DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: fieldGray100,
                                    ),
                                    child: SizedBox.expand(),
                                  ),
                                  FractionallySizedBox(
                                    widthFactor: clan.ratingProgress,
                                    child: const DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            fieldEmerald500,
                                            fieldBlue600,
                                          ],
                                        ),
                                      ),
                                      child: SizedBox.expand(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          clan.skillRating.toString(),
                          style: const TextStyle(
                            color: fieldGray700,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TierBadge(rank: rank, small: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({
    required this.icon,
    required this.label,
    this.iconColor = fieldGray600,
    this.strong = false,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: iconColor),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: fieldGray600,
            fontSize: 13,
            fontWeight: strong ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class TierBadge extends StatelessWidget {
  const TierBadge({super.key, required this.rank, this.small = false});

  final ClanRank rank;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final size = small ? 36.0 : 52.0;
    final icon = rank.tier == ClanTier.champion
        ? Icons.workspace_premium_rounded
        : Icons.shield_rounded;
    return Tooltip(
      message: rank.label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              tierStartColor(rank.tier),
              tierMiddleColor(rank.tier),
              tierEndColor(rank.tier),
            ],
          ),
          borderRadius: BorderRadius.circular(small ? 10 : 14),
          boxShadow: [
            BoxShadow(
              color: tierMiddleColor(rank.tier).withValues(alpha: 0.30),
              blurRadius: small ? 8 : 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(icon, color: Colors.white, size: small ? 19 : 28),
            if (rank.division != null)
              Positioned(
                bottom: small ? 3 : 5,
                child: Text(
                  switch (rank.division) {
                    3 => 'III',
                    2 => 'II',
                    1 => 'I',
                    _ => '',
                  },
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: small ? 7 : 9,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TierLabelBadge extends StatelessWidget {
  const TierLabelBadge({super.key, required this.rank, this.small = false});

  final ClanRank rank;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final foreground = _tierLabelForeground(rank.tier);
    final background = _tierLabelBackground(rank.tier);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 8 : 10,
        vertical: small ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: foreground.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: foreground.withValues(alpha: 0.10),
            blurRadius: small ? 8 : 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            rank.tier == ClanTier.champion
                ? Icons.workspace_premium_rounded
                : Icons.shield_rounded,
            color: foreground,
            size: small ? 13 : 15,
          ),
          SizedBox(width: small ? 4 : 6),
          Text(
            rank.label.toUpperCase(),
            style: TextStyle(
              color: foreground,
              fontSize: small ? 10 : 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

Color _tierLabelForeground(ClanTier tier) {
  return switch (tier) {
    ClanTier.silver => const Color(0xFF475569),
    ClanTier.gold => const Color(0xFFD97706),
    ClanTier.diamond => const Color(0xFF0284C7),
    ClanTier.champion => const Color(0xFFE11D48),
  };
}

Color _tierLabelBackground(ClanTier tier) {
  return switch (tier) {
    ClanTier.silver => const Color(0xFFF1F5F9),
    ClanTier.gold => const Color(0xFFFFFBEB),
    ClanTier.diamond => const Color(0xFFECFEFF),
    ClanTier.champion => const Color(0xFFFFF1F2),
  };
}

class KitCard extends StatelessWidget {
  const KitCard({
    super.key,
    required this.clanName,
    required this.clanTag,
    required this.motto,
    required this.emblem,
    required this.theme,
    required this.pattern,
    this.large = false,
    this.preview = false,
  });

  final String clanName;
  final String clanTag;
  final String motto;
  final String emblem;
  final ClanTheme theme;
  final String pattern;
  final bool large;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: large ? 4 / 5 : 5 / 3,
      child: Opacity(
        opacity: preview ? 0.9 : 1,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [theme.from, theme.to],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: theme.from.withValues(alpha: 0.35),
                blurRadius: 28,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: PatternPainter(
                    pattern: pattern,
                    color: theme.accent,
                  ),
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '[${clanTag.isEmpty ? '—' : clanTag}]'.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.8,
                    ),
                  ),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 260),
                        transitionBuilder: (child, animation) {
                          return ScaleTransition(
                            scale: CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOutBack,
                            ),
                            child: FadeTransition(
                              opacity: animation,
                              child: child,
                            ),
                          );
                        },
                        child: Container(
                          key: ValueKey(emblem),
                          width: large ? 112 : 80,
                          height: large ? 112 : 80,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.30),
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Center(
                            child: Text(
                              emblem,
                              style: TextStyle(fontSize: large ? 56 : 40),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        clanName.isEmpty ? '—' : clanName.toUpperCase(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: large ? 30 : 20,
                          height: 1.05,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                          shadows: [
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.20),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                      if (motto.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          '"${motto.trim()}"',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: large ? 14 : 12,
                            height: 1.25,
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [theme.accent, theme.accent.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PatternPreview extends StatelessWidget {
  const PatternPreview({
    super.key,
    required this.pattern,
    required this.theme,
    this.borderRadius = 6,
  });

  final String pattern;
  final ClanTheme theme;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [theme.from, theme.to]),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: CustomPaint(
          painter: PatternPainter(pattern: pattern, color: theme.accent),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class PatternPainter extends CustomPainter {
  const PatternPainter({required this.pattern, required this.color});

  final String pattern;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (pattern == 'solid') return;

    if (pattern == 'stripes') {
      final paint = Paint()..color = color.withValues(alpha: 0.38);
      for (double x = 0; x < size.width + 24; x += 32) {
        canvas.drawRect(Rect.fromLTWH(x, 0, 12, size.height), paint);
      }
      return;
    }

    final paint = Paint()..color = color.withValues(alpha: 0.28);

    if (pattern == 'sash') {
      final path = Path()
        ..moveTo(size.width * 0.18, 0)
        ..lineTo(size.width * 0.44, 0)
        ..lineTo(size.width * 0.86, size.height)
        ..lineTo(size.width * 0.60, size.height)
        ..close();
      canvas.drawPath(path, paint);
      return;
    }

    if (pattern == 'chevron') {
      final path = Path()
        ..moveTo(-size.width * 0.12, size.height)
        ..lineTo(size.width * 0.50, size.height * 0.40)
        ..lineTo(size.width * 1.12, size.height)
        ..close();
      canvas.drawPath(path, paint);
      return;
    }

    if (pattern == 'pitch') {
      final linePaint = Paint()
        ..color = color.withValues(alpha: 0.25)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final center = Offset(size.width / 2, size.height / 2);
      canvas.drawLine(
        Offset(size.width / 2, -20),
        Offset(size.width / 2, size.height + 20),
        linePaint,
      );
      canvas.drawCircle(
        center,
        math.min(size.width, size.height) * 0.24,
        linePaint,
      );
      canvas.drawCircle(
        center,
        3,
        Paint()..color = color.withValues(alpha: 0.25),
      );
      canvas.drawArc(
        Rect.fromCircle(center: Offset(size.width, 0), radius: 28),
        math.pi / 2,
        math.pi / 2,
        false,
        linePaint,
      );
      canvas.drawArc(
        Rect.fromCircle(center: Offset(0, size.height), radius: 28),
        -math.pi / 2,
        math.pi / 2,
        false,
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant PatternPainter oldDelegate) {
    return oldDelegate.pattern != pattern || oldDelegate.color != color;
  }
}

class _PitchLinesPainter extends CustomPainter {
  const _PitchLinesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawLine(
      Offset(size.width / 2, -20),
      Offset(size.width / 2, size.height + 20),
      paint,
    );
    canvas.drawCircle(center, math.min(size.width, size.height) * 0.24, paint);
    canvas.drawCircle(
      center,
      3,
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(size.width, 0), radius: 28),
      math.pi / 2,
      math.pi / 2,
      false,
      paint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(0, size.height), radius: 28),
      -math.pi / 2,
      math.pi / 2,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PitchLinesPainter oldDelegate) => false;
}
