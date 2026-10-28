import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import 'player_history_repository.dart';

/// A private receipt for an organizer-cancelled game, not a played match.
class FieldrushCancelledGameScreen extends StatelessWidget {
  const FieldrushCancelledGameScreen({
    super.key,
    required this.game,
    this.onFindAnotherGame,
  });

  final PlayerCancelledGame game;
  final VoidCallback? onFindAnotherGame;

  @override
  Widget build(BuildContext context) {
    final date = game.localDisplayStartsAt;
    final hour = date == null
        ? null
        : date.hour % 12 == 0
        ? 12
        : date.hour % 12;
    final time = date == null
        ? 'Time unavailable'
        : '$hour:${date.minute.toString().padLeft(2, '0')} '
              '${date.hour >= 12 ? 'PM' : 'AM'}';
    final reason = game.reason?.trim();
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: Scaffold(
        backgroundColor: FieldrushAuthTheme.cream,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(top: 18, bottom: 32),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: FieldrushAuthTheme.border),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.of(context).pop(),
                          child: const Tooltip(
                            message: 'Back',
                            child: Center(
                              child: Icon(
                                Icons.chevron_left,
                                color: FieldrushAuthTheme.ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text('Solo game', style: _outfit(18))),
                  ],
                ),
              ),
              Container(
                key: const Key('cancelled-game-receipt'),
                margin: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 19),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: FieldrushAuthTheme.border),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF2EFE3),
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: Text(
                            'CANCELLED',
                            style: _jakarta(9).copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: .9,
                            ),
                          ),
                        ),
                        Text('by Fieldrush', style: _jakarta(11)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      date == null
                          ? 'Date unavailable'
                          : '${_weekdays[date.weekday - 1]}, '
                                '${_months[date.month - 1]} ${date.day}',
                      style: _outfit(26).copyWith(letterSpacing: -.65),
                    ),
                    const SizedBox(height: 8),
                    Text('$time · ${game.venue}', style: _jakarta(12)),
                    const Padding(
                      padding: EdgeInsets.only(top: 16, bottom: 15),
                      child: Divider(height: 1, color: Color(0xFFF0ECE0)),
                    ),
                    Text(
                      'WHY',
                      style: _jakarta(10).copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      reason == null || reason.isEmpty
                          ? 'Fieldrush cancelled this game.'
                          : reason,
                      key: const Key('cancelled-game-reason'),
                      style: _jakarta(
                        13,
                      ).copyWith(color: FieldrushAuthTheme.ink, height: 1.5),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 16, bottom: 15),
                      child: Divider(height: 1, color: Color(0xFFF0ECE0)),
                    ),
                    _OutcomeRow(
                      label: 'Refund',
                      value: game.refundSummary,
                      color: FieldrushAuthTheme.forest,
                    ),
                    const SizedBox(height: 12),
                    _OutcomeRow(
                      label: 'Skill rating',
                      value: game.ratingSummary,
                    ),
                    const SizedBox(height: 12),
                    _OutcomeRow(label: 'Strikes', value: game.strikesSummary),
                    const SizedBox(height: 12),
                    _OutcomeRow(label: 'Streak', value: game.streakSummary),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: FilledButton(
                  key: const Key('cancelled-game-find-another'),
                  onPressed: onFindAnotherGame,
                  style: FilledButton.styleFrom(
                    backgroundColor: FieldrushAuthTheme.forest,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                    textStyle: _jakarta(
                      14,
                    ).copyWith(fontWeight: FontWeight.w800),
                  ),
                  child: const Text('Find another game'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutcomeRow extends StatelessWidget {
  const _OutcomeRow({
    required this.label,
    required this.value,
    this.color = FieldrushAuthTheme.ink,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(flex: 2, child: Text(label, style: _jakarta(12))),
      const SizedBox(width: 12),
      Expanded(
        flex: 3,
        child: Text(
          value,
          textAlign: TextAlign.right,
          style: _jakarta(
            12.5,
          ).copyWith(color: color, fontWeight: FontWeight.w800),
        ),
      ),
    ],
  );
}

TextStyle _outfit(double size) => TextStyle(
  fontFamily: 'Outfit',
  fontSize: size,
  height: 1,
  fontWeight: FontWeight.w800,
  color: FieldrushAuthTheme.ink,
);
TextStyle _jakarta(double size) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  height: 1.3,
  fontWeight: FontWeight.w600,
  color: FieldrushAuthTheme.muted,
);
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
