import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import 'fixture.dart';

class FixtureHeroBanner extends StatefulWidget {
  const FixtureHeroBanner({super.key, required this.fixtures});

  final List<Fixture> fixtures;

  @override
  State<FixtureHeroBanner> createState() => _FixtureHeroBannerState();
}

class _FixtureHeroBannerState extends State<FixtureHeroBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.fixtures
        .where((fixture) => fixture.status == FixtureStatus.open)
        .length;
    final live = widget.fixtures
        .where((fixture) => fixture.status == FixtureStatus.live)
        .length;
    final scheduled = widget.fixtures
        .where((fixture) => fixture.status == FixtureStatus.scheduled)
        .length;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
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
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: const RadialGradient(
            center: Alignment(-1, 1),
            radius: 1.55,
            colors: [Color(0xFFF97316), Color(0xFFDB2777), Color(0xFF3B0764)],
            stops: [0, 0.46, 1],
          ),
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFDB2777).withValues(alpha: 0.28),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            const Positioned.fill(
              child: CustomPaint(painter: _FixturePitchLinesPainter()),
            ),
            Positioned(
              top: -72,
              right: -72,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final phase = math.sin(_controller.value * math.pi);
                  return Transform.scale(
                    scale: 1.04 + (phase * 0.08),
                    child: Opacity(
                      opacity: 0.20 + (phase * 0.06),
                      child: child,
                    ),
                  );
                },
                child: Container(
                  width: 224,
                  height: 224,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFFFB86B),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0xFFFFB86B),
                        blurRadius: 54,
                        spreadRadius: 18,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
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
                                  width: 32,
                                  height: 3,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.72),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Flexible(
                                  child: Text(
                                    'MATCH DAY',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Color(0xEFFFF7ED),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'KICKOFF AWAITS.',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 36,
                                height: 1.04,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Challenge rivals, defend your turf, and earn the SR.',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.86),
                                fontSize: 15,
                                height: 1.35,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.28),
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Center(
                          child: _CrossedSwordsIcon(
                            color: Color(0xFFFFF7CC),
                            size: 36,
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
                      _HeroPill(label: 'Open', value: open.toString()),
                      _HeroPill(label: 'Live', value: live.toString()),
                      _HeroPill(
                        label: 'Scheduled',
                        value: scheduled.toString(),
                      ),
                    ],
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

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Color(0xFFFFEDD5),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class FixtureStatusFilters extends StatelessWidget {
  const FixtureStatusFilters({
    super.key,
    required this.selectedStatus,
    required this.fixtures,
    required this.onSelected,
  });

  final FixtureStatus? selectedStatus;
  final List<Fixture> fixtures;
  final ValueChanged<FixtureStatus?> onSelected;

  @override
  Widget build(BuildContext context) {
    final filters = <({FixtureStatus? status, String label})>[
      (status: null, label: 'All'),
      (status: FixtureStatus.open, label: 'Open'),
      (status: FixtureStatus.scheduled, label: 'Scheduled'),
      (status: FixtureStatus.live, label: 'Live'),
      (status: FixtureStatus.finalResult, label: 'Final'),
    ];

    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          final filter = filters[index];
          final selected = selectedStatus == filter.status;
          final count = filter.status == null
              ? fixtures.length
              : fixtures
                    .where((fixture) => fixture.status == filter.status)
                    .length;
          return _FilterChipButton(
            label: filter.label,
            count: count,
            selected: selected,
            onTap: () => onSelected(filter.status),
          );
        },
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemCount: filters.length,
      ),
    );
  }
}

class _CrossedSwordsIcon extends StatelessWidget {
  const _CrossedSwordsIcon({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _CrossedSwordsPainter(color),
    );
  }
}

class _CrossedSwordsPainter extends CustomPainter {
  const _CrossedSwordsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final blade = Paint()
      ..color = color
      ..strokeWidth = size.width * 0.12
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final guard = Paint()
      ..color = color
      ..strokeWidth = size.width * 0.09
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    void sword({required bool flip}) {
      canvas.save();
      canvas.translate(size.width / 2, size.height / 2);
      canvas.rotate((flip ? -42 : 42) * math.pi / 180);
      canvas.translate(-size.width / 2, -size.height / 2);

      canvas.drawLine(
        Offset(size.width * 0.50, size.height * 0.14),
        Offset(size.width * 0.50, size.height * 0.76),
        blade,
      );
      canvas.drawLine(
        Offset(size.width * 0.31, size.height * 0.55),
        Offset(size.width * 0.69, size.height * 0.55),
        guard,
      );
      canvas.drawLine(
        Offset(size.width * 0.50, size.height * 0.76),
        Offset(size.width * 0.50, size.height * 0.91),
        guard,
      );

      final tip = Path()
        ..moveTo(size.width * 0.50, size.height * 0.06)
        ..lineTo(size.width * 0.42, size.height * 0.18)
        ..lineTo(size.width * 0.58, size.height * 0.18)
        ..close();
      canvas.drawPath(tip, Paint()..color = color);
      canvas.restore();
    }

    sword(flip: false);
    sword(flip: true);
  }

  @override
  bool shouldRepaint(covariant _CrossedSwordsPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _FixturePitchLinesPainter extends CustomPainter {
  const _FixturePitchLinesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final fill = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;

    final center = Offset(size.width * 0.50, size.height * 0.50);
    final circleRadius = size.shortestSide * 0.30;
    canvas.drawLine(
      Offset(size.width * 0.50, -20),
      Offset(size.width * 0.50, size.height + 20),
      line,
    );
    canvas.drawCircle(center, circleRadius, line);
    canvas.drawCircle(center, 3, fill);

    canvas.drawArc(
      Rect.fromCircle(center: Offset(size.width, 0), radius: 46),
      math.pi / 2,
      math.pi / 2,
      false,
      line,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(0, size.height), radius: 46),
      -math.pi / 2,
      math.pi / 2,
      false,
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _FixturePitchLinesPainter oldDelegate) {
    return false;
  }
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? fieldEmerald600 : Colors.white,
          border: Border.all(color: selected ? fieldEmerald600 : fieldGray200),
          borderRadius: BorderRadius.circular(10),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: fieldEmerald600.withValues(alpha: 0.20),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : fieldGray600,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.20)
                    : fieldGray100,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  color: selected ? Colors.white : fieldGray600,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FixtureCard extends StatelessWidget {
  const FixtureCard({super.key, required this.fixture, this.onTap});

  final Fixture fixture;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final status = _statusColors(fixture.status);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: fieldGray200),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                color: status.background,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        fixture.statusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: status.foreground,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.calendar_month_rounded,
                      color: status.foreground,
                      size: 13,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      fixture.monthDay,
                      style: TextStyle(
                        color: status.foreground,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FixtureTeamSummary(
                            clan: fixture.homeClan,
                            alignEnd: false,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: _FixtureCenter(fixture: fixture),
                        ),
                        Expanded(
                          child: fixture.awayClan == null
                              ? const _OpenOpponentSlot()
                              : FixtureTeamSummary(
                                  clan: fixture.awayClan!,
                                  alignEnd: true,
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Divider(color: fieldGray100, height: 1),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _DetailIconText(
                            icon: Icons.location_on_rounded,
                            label: fixture.venue,
                          ),
                        ),
                        const SizedBox(width: 12),
                        _DetailIconText(
                          icon: Icons.access_time_rounded,
                          label: fixture.timeSlot,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FixtureTeamSummary extends StatelessWidget {
  const FixtureTeamSummary({
    super.key,
    required this.clan,
    required this.alignEnd,
  });

  final FixtureClan clan;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final avatar = FixtureClanAvatar(clan: clan, size: 48);
    final text = Expanded(
      child: Column(
        crossAxisAlignment: alignEnd
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Text(
            clan.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: alignEnd ? TextAlign.right : TextAlign.left,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 14,
              height: 1.05,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            clan.tag,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );

    return Row(
      mainAxisAlignment: alignEnd
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: alignEnd
          ? [text, const SizedBox(width: 9), avatar]
          : [avatar, const SizedBox(width: 9), text],
    );
  }
}

class FixtureClanAvatar extends StatelessWidget {
  const FixtureClanAvatar({super.key, required this.clan, this.size = 56});

  final FixtureClan clan;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [clan.theme.from, clan.theme.to],
        ),
        borderRadius: BorderRadius.circular(size * 0.24),
        boxShadow: [
          BoxShadow(
            color: clan.theme.from.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 6),
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
                color: clan.theme.accent,
              ),
            ),
          ),
          Center(
            child: Text(clan.emblem, style: TextStyle(fontSize: size * 0.52)),
          ),
        ],
      ),
    );
  }
}

class _FixtureCenter extends StatelessWidget {
  const _FixtureCenter({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
    if (fixture.isFinal &&
        fixture.homeScore != null &&
        fixture.awayScore != null) {
      return Text(
        '${fixture.homeScore} - ${fixture.awayScore}',
        style: const TextStyle(
          color: fieldGray900,
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
      );
    }

    return const Text(
      'VS',
      style: TextStyle(
        color: fieldGray400,
        fontSize: 17,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _OpenOpponentSlot extends StatelessWidget {
  const _OpenOpponentSlot();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fieldGray100,
          border: Border.all(
            color: fieldGray300,
            width: 2,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          '?',
          style: TextStyle(
            color: fieldGray400,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _DetailIconText extends StatelessWidget {
  const _DetailIconText({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: fieldGray500, size: 15),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: fieldGray600,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

({Color background, Color foreground}) _statusColors(FixtureStatus status) {
  return switch (status) {
    FixtureStatus.open => (
      background: const Color(0xFFDBEAFE),
      foreground: const Color(0xFF1D4ED8),
    ),
    FixtureStatus.scheduled => (
      background: const Color(0xFFD1FAE5),
      foreground: const Color(0xFF047857),
    ),
    FixtureStatus.live => (
      background: const Color(0xFFFFEDD5),
      foreground: const Color(0xFFC2410C),
    ),
    FixtureStatus.finalResult => (
      background: fieldGray100,
      foreground: fieldGray700,
    ),
    FixtureStatus.cancelled => (
      background: const Color(0xFFFFF7ED),
      foreground: const Color(0xFFB45309),
    ),
  };
}
