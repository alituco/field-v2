import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import 'open_queue.dart';

class OpenQueueKitIndicator extends StatelessWidget {
  const OpenQueueKitIndicator({
    super.key,
    required this.booking,
    this.compact = false,
  });

  final OpenQueueBooking booking;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (!booking.game.isUpcomingMatchConfirmed) {
      return const SizedBox.shrink();
    }

    final team = booking.assignedTeam;
    final instruction = booking.kitInstruction;
    if (team == null || instruction == null) {
      return Semantics(
        container: true,
        label: 'Match kit assignment is updating',
        child: Container(
          key: const ValueKey('kit-assignment-updating'),
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 11 : 14,
            vertical: compact ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            border: Border.all(color: const Color(0xFFF59E0B), width: 1.5),
            borderRadius: BorderRadius.circular(compact ? 13 : 16),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.sync_rounded,
                color: Color(0xFFB45309),
                size: 23,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'KIT ASSIGNMENT UPDATING',
                      style: TextStyle(
                        color: Color(0xFF92400E),
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 2),
                      const Text(
                        'Pull to refresh in a moment.',
                        style: TextStyle(
                          color: Color(0xFFB45309),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final isBlack = team == openQueueBlackTeamId;
    final foreground = isBlack ? Colors.white : fieldGray900;
    final background = isBlack ? const Color(0xFF090B10) : Colors.white;
    final border = isBlack ? Colors.white : fieldGray900;

    return Semantics(
      container: true,
      label: 'Match kit: ${instruction.toLowerCase()}',
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('kit-instruction'),
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 11 : 14,
            vertical: compact ? 9 : 12,
          ),
          decoration: BoxDecoration(
            color: background,
            border: Border.all(color: border, width: 1.7),
            borderRadius: BorderRadius.circular(compact ? 13 : 16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isBlack ? 0.22 : 0.10),
                blurRadius: compact ? 8 : 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: compact ? 32 : 39,
                height: compact ? 32 : 39,
                decoration: BoxDecoration(
                  color: isBlack ? Colors.white : fieldGray900,
                  borderRadius: BorderRadius.circular(compact ? 10 : 12),
                ),
                child: Icon(
                  Icons.checkroom_rounded,
                  color: isBlack ? fieldGray900 : Colors.white,
                  size: compact ? 20 : 24,
                ),
              ),
              SizedBox(width: compact ? 9 : 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'YOUR MATCH KIT',
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.68),
                        fontSize: compact ? 8 : 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      instruction,
                      maxLines: 1,
                      style: TextStyle(
                        color: foreground,
                        fontSize: compact ? 15 : 19,
                        height: 1,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.check_circle_rounded,
                color: foreground.withValues(alpha: 0.76),
                size: compact ? 18 : 21,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
