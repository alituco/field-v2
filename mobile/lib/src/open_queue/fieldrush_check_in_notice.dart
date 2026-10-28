import 'package:flutter/material.dart';

import 'open_queue.dart';

/// The referee still records Early/Late. This is the player's arrival reminder,
/// with the saved late threshold displayed in the venue's timezone.
class FieldrushCheckInNotice extends StatelessWidget {
  const FieldrushCheckInNotice({super.key, required this.game});

  final OpenQueueGame game;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('fieldrush-check-in-notice'),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFFAF7EF),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFFE6DFCB)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 3,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFFC0392B),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Check in before ${game.checkInDeadlineTimeLabel}. ',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const TextSpan(
                  text: 'Arriving at or after this time is 1 strike.',
                ),
              ],
            ),
            style: const TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontWeight: FontWeight.w600,
              fontSize: 11,
              height: 1.45,
              color: Color(0xFF22301F),
            ),
          ),
        ),
      ],
    ),
  );
}
