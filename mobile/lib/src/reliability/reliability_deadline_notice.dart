import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import 'reliability.dart';

class ReliabilityDeadlineNotice extends StatefulWidget {
  const ReliabilityDeadlineNotice({
    super.key,
    required this.load,
    this.includeNoShowCutoff = false,
  });

  final Future<MatchReliabilityContext?> Function() load;
  final bool includeNoShowCutoff;

  @override
  State<ReliabilityDeadlineNotice> createState() =>
      _ReliabilityDeadlineNoticeState();
}

class _ReliabilityDeadlineNoticeState extends State<ReliabilityDeadlineNotice> {
  late final Future<MatchReliabilityContext?> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MatchReliabilityContext?>(
      future: _future,
      builder: (context, snapshot) {
        final reliability = snapshot.data;
        final deadline = reliability?.checkInDeadlineAt;
        final kickoff = reliability?.kickoffAt;
        if (deadline == null || kickoff == null) {
          return const SizedBox.shrink();
        }
        final cutoff = reliability?.noShowCutoffAt;
        return Container(
          key: const ValueKey('reliability-check-in-deadline'),
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.how_to_reg_rounded,
                  color: Color(0xFFB45309),
                  size: 21,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ARRIVAL DEADLINE',
                      style: TextStyle(
                        color: Color(0xFFB45309),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Arrive by ${_clock(deadline)}. The referee records attendance—no app check-in is needed. Kickoff is ${_clock(kickoff)}.',
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 13,
                        height: 1.35,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (widget.includeNoShowCutoff && cutoff != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Missing players are finalized at ${_clock(cutoff)}. Kickoff is not delayed.',
                        style: const TextStyle(
                          color: fieldGray500,
                          fontSize: 10,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _clock(DateTime value) {
  final bahrain = value.toUtc().add(const Duration(hours: 3));
  final hour = bahrain.hour % 12 == 0 ? 12 : bahrain.hour % 12;
  final minute = bahrain.minute.toString().padLeft(2, '0');
  final period = bahrain.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $period';
}
