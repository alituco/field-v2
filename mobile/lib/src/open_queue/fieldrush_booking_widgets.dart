import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import 'open_queue.dart';

TextStyle bookingHeading(double size, {Color? color}) => TextStyle(
  fontFamily: 'Outfit',
  fontSize: size,
  fontWeight: FontWeight.w800,
  height: 1.15,
  letterSpacing: -.3,
  color: color ?? FieldrushAuthTheme.ink,
);

TextStyle bookingText(double size, {Color? color, bool bold = false}) =>
    TextStyle(
      fontFamily: 'PlusJakartaSans',
      fontSize: size,
      fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
      height: 1.5,
      color: color ?? FieldrushAuthTheme.muted,
    );

String bookingRoleName(OpenQueueRole role) =>
    role == OpenQueueRole.goalkeeper ? 'Keeper' : role.label;

String bookingMoney(int mills, String currency) => currency == 'USD'
    ? '\$${(mills / 1000).toStringAsFixed(2)}'
    : '${(mills / 1000).toStringAsFixed(3)} $currency';

class BookingPanel extends StatelessWidget {
  const BookingPanel({super.key, required this.child, this.padding = 18});
  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: FieldrushAuthTheme.border),
      borderRadius: BorderRadius.circular(22),
    ),
    child: child,
  );
}

class BookingValueRow extends StatelessWidget {
  const BookingValueRow(
    this.label,
    this.value, {
    super.key,
    this.emphasized = false,
  });
  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: bookingText(12))),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: emphasized
                ? bookingHeading(20)
                : bookingText(12.5, color: FieldrushAuthTheme.ink, bold: true),
          ),
        ),
      ],
    ),
  );
}

class BookingDateBadge extends StatelessWidget {
  const BookingDateBadge({super.key, required this.game});
  final OpenQueueGame game;

  @override
  Widget build(BuildContext context) => Container(
    width: 46,
    constraints: const BoxConstraints(minHeight: 46),
    padding: const EdgeInsets.symmetric(vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFF2EFE3),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      children: [
        Text(
          const [
            'MON',
            'TUE',
            'WED',
            'THU',
            'FRI',
            'SAT',
            'SUN',
          ][game.localStartsAt.weekday - 1],
          style: bookingText(9, bold: true),
        ),
        Text('${game.localStartsAt.day}', style: bookingHeading(19)),
      ],
    ),
  );
}
