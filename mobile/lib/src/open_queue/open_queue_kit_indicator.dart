import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import 'open_queue.dart';

class OpenQueueKitIndicator extends StatelessWidget {
  const OpenQueueKitIndicator({
    super.key,
    required this.booking,
    this.compact = false,
    this.inline = false,
  });

  final OpenQueueBooking booking;
  final bool compact;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    if (!booking.game.isUpcomingMatchConfirmed) {
      return const SizedBox.shrink();
    }
    if (!booking.game.isTeamAssignmentDue) {
      return _ScheduledOpenQueueKitIndicator(
        compact: compact,
        inline: inline,
        assignmentLeadLabel: booking.game.teamAssignmentLeadLabel,
      );
    }

    final team = booking.assignedTeam;
    final instruction = booking.kitInstruction;
    if (inline) {
      return _InlineOpenQueueKitIndicator(team: team, instruction: instruction);
    }
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
                child: OpenQueueJerseyIcon(
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
                      'YOUR KIT',
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
            ],
          ),
        ),
      ),
    );
  }
}

class _ScheduledOpenQueueKitIndicator extends StatelessWidget {
  const _ScheduledOpenQueueKitIndicator({
    required this.compact,
    required this.inline,
    required this.assignmentLeadLabel,
  });

  final bool compact;
  final bool inline;
  final String assignmentLeadLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Match kit assigned $assignmentLeadLabel',
      child: Container(
        key: const ValueKey('kit-assignment-scheduled'),
        width: double.infinity,
        constraints: inline ? const BoxConstraints(minHeight: 40) : null,
        padding: inline
            ? EdgeInsets.zero
            : EdgeInsets.symmetric(
                horizontal: compact ? 11 : 14,
                vertical: compact ? 9 : 12,
              ),
        decoration: inline
            ? null
            : BoxDecoration(
                color: const Color(0xFFF9FAFB),
                border: Border.all(color: fieldGray200, width: 1.4),
                borderRadius: BorderRadius.circular(compact ? 13 : 16),
              ),
        child: Row(
          children: [
            Container(
              width: compact || inline ? 32 : 39,
              height: compact || inline ? 32 : 39,
              decoration: BoxDecoration(
                color: fieldGray100,
                borderRadius: BorderRadius.circular(compact ? 10 : 12),
              ),
              child: OpenQueueJerseyIcon(
                color: fieldGray500,
                size: compact || inline ? 20 : 24,
              ),
            ),
            SizedBox(width: compact || inline ? 9 : 11),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'YOUR KIT',
                    style: TextStyle(
                      color: fieldGray500,
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'ASSIGNED ${assignmentLeadLabel.toUpperCase()}',
                    maxLines: 2,
                    style: const TextStyle(
                      color: fieldGray700,
                      fontSize: 11,
                      height: 1.1,
                      fontWeight: FontWeight.w900,
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

class _InlineOpenQueueKitIndicator extends StatelessWidget {
  const _InlineOpenQueueKitIndicator({
    required this.team,
    required this.instruction,
  });

  final String? team;
  final String? instruction;

  @override
  Widget build(BuildContext context) {
    if (team == null || instruction == null) {
      return Semantics(
        container: true,
        label: 'Match kit assignment is updating',
        child: Container(
          key: const ValueKey('kit-assignment-updating'),
          constraints: const BoxConstraints(minHeight: 40),
          child: const Row(
            children: [
              Icon(Icons.sync_rounded, color: Color(0xFFB45309), size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MATCH KIT',
                      style: TextStyle(
                        color: fieldGray500,
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .8,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'UPDATING',
                      style: TextStyle(
                        color: Color(0xFF92400E),
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
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

    final isBlack = team == openQueueBlackTeamId;
    return Semantics(
      container: true,
      label: 'Match kit: ${instruction!.toLowerCase()}',
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('kit-instruction'),
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: isBlack ? fieldGray900 : Colors.white,
                  border: Border.all(
                    color: isBlack ? fieldGray900 : fieldGray300,
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: OpenQueueJerseyIcon(
                  color: isBlack ? Colors.white : fieldGray900,
                  size: 21,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'MATCH KIT',
                      style: TextStyle(
                        color: fieldGray500,
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .8,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      instruction!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 12,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
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

class OpenQueueJerseyIcon extends StatelessWidget {
  const OpenQueueJerseyIcon({super.key, required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _OpenQueueJerseyPainter(color)),
      ),
    );
  }
}

class _OpenQueueJerseyPainter extends CustomPainter {
  const _OpenQueueJerseyPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * .085
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * .34, size.height * .14)
      ..quadraticBezierTo(
        size.width * .50,
        size.height * .28,
        size.width * .66,
        size.height * .14,
      )
      ..lineTo(size.width * .82, size.height * .22)
      ..lineTo(size.width * .94, size.height * .43)
      ..lineTo(size.width * .78, size.height * .53)
      ..lineTo(size.width * .69, size.height * .42)
      ..lineTo(size.width * .69, size.height * .88)
      ..lineTo(size.width * .31, size.height * .88)
      ..lineTo(size.width * .31, size.height * .42)
      ..lineTo(size.width * .22, size.height * .53)
      ..lineTo(size.width * .06, size.height * .43)
      ..lineTo(size.width * .18, size.height * .22)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _OpenQueueJerseyPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
