import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../home/fieldrush_home_widgets.dart';
import '../ui/fieldrush_toast.dart';
import 'featured_field.dart';
import 'fieldrush_booking_widgets.dart';
import 'open_queue.dart';

class FieldrushBookingFieldCard extends StatelessWidget {
  const FieldrushBookingFieldCard({
    super.key,
    required this.field,
    required this.games,
    required this.allGamesHere,
  });

  final FeaturedField field;
  final List<OpenQueueGame> games;
  final bool allGamesHere;

  Future<void> _directions(BuildContext context) async {
    final uri = field.directionsUri;
    if (uri == null) return;
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Keep the booking list available if the maps app cannot open.
    }
    if (context.mounted) {
      showFieldrushToast(context, 'Could not open directions. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final here = games.where(field.matchesGame).toList();
    final times = here.map((game) => game.displayTimeLabel).toSet();
    final formats = here.map((game) => game.capacity).toSet();
    final prices = here.map((game) => game.priceLabel).toSet();
    final details = [
      if (times.length == 1 && allGamesHere) 'Check-in ${times.single}',
      if (formats.length == 1 && prices.length == 1 && allGamesHere)
        'Up to ${formats.single ~/ 2}v${formats.single ~/ 2} · ${prices.single}',
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: CustomPaint(
        painter: const _FieldStripes(),
        child: Container(
          key: const ValueKey('booking-field-showcase'),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                allGamesHere ? 'WHERE YOU’LL PLAY' : 'FEATURED FIELD',
                style: bookingText(
                  10,
                  color: const Color(0xFFC7DD9B),
                  bold: true,
                ).copyWith(height: 1, letterSpacing: 1.4),
              ),
              const SizedBox(height: 10),
              Text(
                field.name,
                style: bookingHeading(
                  22,
                  color: Colors.white,
                ).copyWith(height: 1.05, letterSpacing: -.44),
              ),
              if (field.address case final String address) ...[
                const SizedBox(height: 7),
                Text(
                  address,
                  style: bookingText(
                    12,
                    color: const Color(0xFFE4F0D5),
                  ).copyWith(height: 1.4),
                ),
              ],
              if (field.directionsUri != null || details.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (field.directionsUri != null)
                      FilledButton.icon(
                        key: const ValueKey('booking-field-directions'),
                        onPressed: () => _directions(context),
                        icon: const Icon(Icons.near_me_outlined, size: 14),
                        label: const Text('Directions'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFF3EBD6),
                          foregroundColor: FieldrushAuthTheme.ink,
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          textStyle: bookingText(12, bold: true),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    if (details.isNotEmpty)
                      Text(
                        details.join('\n'),
                        style: bookingText(
                          11.5,
                          color: const Color(0xFFE4F0D5),
                        ).copyWith(height: 1.35, fontWeight: FontWeight.w700),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class FieldrushBookingGameRow extends StatelessWidget {
  const FieldrushBookingGameRow({
    super.key,
    required this.game,
    required this.roles,
    required this.suggestedRole,
    required this.now,
    required this.onTap,
    required this.showLocationAndTime,
    required this.showDivision,
    this.sooner = false,
  });

  final OpenQueueGame game;
  final Set<OpenQueueRole> roles;
  final OpenQueueRole suggestedRole;
  final DateTime now;
  final VoidCallback onTap;
  final bool showLocationAndTime;
  final bool showDivision;
  final bool sooner;

  @override
  Widget build(BuildContext context) {
    final positions = fieldrushOpenQueueRoles.where(
      (role) => roles.isEmpty || roles.contains(role),
    );
    final count = positions.fold<int>(
      0,
      (total, role) =>
          total + (game.canBookAt(role, now) ? game.spotsFor(role) : 0),
    );
    final capacity = positions.fold<int>(
      0,
      (total, role) => total + game.capacityFor(role),
    );
    final who = roles.length == 1
        ? '${bookingRoleName(roles.single).toLowerCase()} '
        : '';
    final subtitle = sooner
        ? 'Out of position · ${bookingRoleName(suggestedRole)}'
        : '$count $who${count == 1 ? 'spot' : 'spots'} left'
              '${roles.length > 1 ? ' · you’d play ${bookingRoleName(suggestedRole).toLowerCase()}' : ''}';
    final date = game.localDisplayStartsAt;
    final dateLabel =
        '${_weekdays[date.weekday - 1]}, ${_months[date.month - 1]} ${date.day}';
    return InkWell(
      key: ValueKey('booking-game-${game.id}${sooner ? '-sooner' : ''}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        child: Row(
          children: [
            Container(
              width: 44,
              constraints: const BoxConstraints(minHeight: 46),
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF2EFE3),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Column(
                children: [
                  Text(
                    _weekdays[date.weekday - 1].toUpperCase(),
                    style: bookingText(
                      9,
                      bold: true,
                    ).copyWith(height: 1, letterSpacing: .9),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${date.day}',
                    style: bookingHeading(18).copyWith(height: 1),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dateLabel, style: bookingHeading(15)),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    style: bookingText(11.5).copyWith(height: 1.3),
                  ),
                  if (showLocationAndTime || sooner) ...[
                    const SizedBox(height: 5),
                    Text(
                      'Check-in ${game.displayTimeLabel} · ${game.venue} · ${game.priceLabel}',
                      style: bookingText(11).copyWith(height: 1.35),
                    ),
                  ],
                  if (showDivision) ...[
                    const SizedBox(height: 7),
                    FieldrushGameDivisionRange(game: game, compact: true),
                  ],
                  if (!sooner) ...[
                    const SizedBox(height: 7),
                    _AvailabilityBar(open: count, capacity: capacity),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '›',
              style: bookingText(
                14,
              ).copyWith(height: 1, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvailabilityBar extends StatelessWidget {
  const _AvailabilityBar({required this.open, required this.capacity});
  final int open;
  final int capacity;

  @override
  Widget build(BuildContext context) {
    final total = math.max(1, capacity);
    final available = open.clamp(0, total);
    final segments = total <= 8
        ? [for (var i = 0; i < total; i++) (flex: 1, available: i < available)]
        : [
            if (available > 0) (flex: available, available: true),
            if (available < total) (flex: total - available, available: false),
          ];
    return Semantics(
      label: '$open of $capacity position spots open',
      child: SizedBox(
        width: 84,
        height: 4,
        child: Row(
          children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(
                flex: segments[i].flex,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: segments[i].available
                        ? FieldrushAuthTheme.forest
                        : const Color(0xFFD9CFB5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class FieldrushBookingSoonerPanel extends StatelessWidget {
  const FieldrushBookingSoonerPanel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: CustomPaint(
      foregroundPainter: const _SoonerOutline(),
      child: Material(color: const Color(0xFFFDFBF3), child: child),
    ),
  );
}

class _SoonerOutline extends CustomPainter {
  const _SoonerOutline();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.5),
          const Radius.circular(16),
        ),
      );
    final stroke = Paint()
      ..color = const Color(0xFFCBBF9E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      for (var offset = 0.0; offset < metric.length; offset += 8) {
        canvas.drawPath(
          metric.extractPath(offset, math.min(offset + 4, metric.length)),
          stroke,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SoonerOutline oldDelegate) => false;
}

class _FieldStripes extends CustomPainter {
  const _FieldStripes();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = FieldrushAuthTheme.forest,
    );
    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: .045)
      ..strokeWidth = 1;
    final offset = size.height * .25;
    for (var x = -offset; x < size.width + offset; x += 26) {
      canvas.drawLine(Offset(x, 0), Offset(x + offset, size.height), stroke);
    }
  }

  @override
  bool shouldRepaint(_FieldStripes oldDelegate) => false;
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
