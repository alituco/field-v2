import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../home/field_bottom_nav.dart';
import '../home/fieldrush_home_widgets.dart';
import '../leaderboard/fieldrush_rating_tracks.dart';
import '../leaderboard/leaderboard.dart';
import 'player_rating_visibility.dart';
import 'rating_division.dart';

const _ink = FieldrushAuthTheme.ink;
const _muted = FieldrushAuthTheme.muted;
const _green = FieldrushAuthTheme.forest;
const _border = FieldrushAuthTheme.border;

TextStyle _jakarta(double size, {Color color = _muted, int weight = 6}) =>
    TextStyle(
      fontFamily: 'PlusJakartaSans',
      fontSize: size,
      fontWeight: FontWeight.values[weight - 1],
      height: 1.4,
      color: color,
    );

/// The HTML's divisions guide, using the exact rating track already on screen.
/// Hidden official ratings never become predictions: only the owner projection
/// may supply a predicted SR before lifetime placement is complete.
class FieldrushDivisionsScreen extends StatelessWidget {
  const FieldrushDivisionsScreen({
    super.key,
    this.rating,
    this.prediction,
    this.track = RatingTrack.outfield,
    this.season,
    this.cityName,
    required this.onOpenRanks,
    this.onNavigateTab,
    this.selectedTab = 0,
  });

  final PublicPlayerRating? rating;
  final FieldrushPlacementPrediction? prediction;
  final RatingTrack track;
  final LeaderboardSeason? season;
  final String? cityName;
  final VoidCallback onOpenRanks;
  final ValueChanged<int>? onNavigateTab;
  final int selectedTab;

  @override
  Widget build(BuildContext context) {
    final revealed = rating?.ratingVisible == true;
    final sr = revealed ? rating!.skillRating : prediction?.skillRating;
    final division = sr == null ? null : divisionFromRating(sr);
    final city = cityName?.trim() ?? '';
    final cityLabel = city.isEmpty
        ? ''
        : '${city[0].toUpperCase()}${city.substring(1)}';
    final remaining =
        (2 -
                (prediction?.countedMatches ??
                    rating?.lifetimeCountedMatches ??
                    0))
            .clamp(1, 2);
    final inGoal = track == RatingTrack.goalkeeper ? ' in goal' : '';
    final note = prediction != null
        ? 'Predicted until your real rating comes in, after '
              '${remaining == 1 ? '1 more game' : '2 games'}$inGoal.'
        : 'Play ${remaining == 1 ? '1 more game' : '2 games'}$inGoal '
              'to reveal your division.';

    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: Scaffold(
        key: const ValueKey('fieldrush-divisions-screen'),
        backgroundColor: FieldrushAuthTheme.cream,
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.only(bottom: 132),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: 36,
                          child: IconButton(
                            key: const ValueKey('divisions-back'),
                            tooltip: 'Back',
                            onPressed: () => Navigator.of(context).pop(),
                            padding: EdgeInsets.zero,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF3C4A38),
                              side: const BorderSide(color: _border),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(
                              Icons.chevron_left_rounded,
                              size: 22,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Divisions',
                                style: TextStyle(
                                  fontFamily: 'Outfit',
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  height: 1,
                                  letterSpacing: -.18,
                                  color: _ink,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                '${season?.label ?? 'Current season'} · ${track.label}',
                                style: _jakarta(11.5).copyWith(height: 1),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!revealed && rating != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                      child: Row(
                        children: [
                          const FieldrushDivisionShield(
                            size: 16,
                            placement: true,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              note,
                              style: _jakarta(11.5, color: _ink, weight: 7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: _border),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        for (final d in RatingDivision.values.reversed)
                          _DivisionRow(
                            division: d,
                            sr: d == division ? sr : null,
                            predicted: !revealed,
                            first: d.isTop,
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Text(
                      'Wins raise your skill rating and losses lower it. '
                      'Reach a division’s number to move up.',
                      style: _jakarta(12).copyWith(height: 1.5),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                    child: OutlinedButton(
                      key: const ValueKey('divisions-open-ranks'),
                      onPressed: onOpenRanks,
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: _ink,
                        minimumSize: const Size(0, 48),
                        side: const BorderSide(color: _border),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: _jakarta(13, color: _ink, weight: 8),
                      ),
                      child: Text(
                        cityLabel.isEmpty
                            ? 'See ranks'
                            : 'See $cityLabel ranks',
                      ),
                    ),
                  ),
                ],
              ),
              if (onNavigateTab != null)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FieldBottomNav(
                    selectedIndex: selectedTab,
                    onSelected: onNavigateTab!,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DivisionRow extends StatelessWidget {
  const _DivisionRow({
    required this.division,
    required this.sr,
    required this.predicted,
    required this.first,
  });
  final RatingDivision division;
  final int? sr;
  final bool predicted;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final current = sr != null;
    final range = division.isTop
        ? '${division.minimumRating}+ skill rating'
        : division.number == 5
        ? 'Under ${division.nextDivisionRating} skill rating'
        : '${division.minimumRating} to ${division.maximumRating} skill rating';
    // The entry division's visual meter begins at the HTML's 900 SR marker;
    // the canonical division still includes every rating below 1100.
    final low = division.number == 5 ? 900 : division.minimumRating;
    final high = division.nextDivisionRating ?? 1800;
    final progress = current
        ? ((sr! - low) / (high - low)).clamp(.04, 1.0).toDouble()
        : 0.0;
    final color = switch (division.number) {
      1 => const Color(0xFF26251F),
      2 => const Color(0xFF22406F),
      3 => const Color(0xFFB8872E),
      4 => const Color(0xFF7D8892),
      _ => const Color(0xFF9A6236),
    };

    return Container(
      key: ValueKey('division-row-${division.number}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: current ? const Color(0xFFF5F9EC) : Colors.white,
        border: first
            ? null
            : const Border(top: BorderSide(color: Color(0xFFF0ECE0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              FieldrushDivisionShield(division: division.number, size: 32),
              const SizedBox(width: 13),
              Expanded(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          division.label,
                          style: const TextStyle(
                            fontFamily: 'Outfit',
                            fontSize: 17,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.17,
                            color: _ink,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(range, style: _jakarta(11.5).copyWith(height: 1)),
                      ],
                    ),
                    if (current)
                      CustomPaint(
                        foregroundPainter: predicted
                            ? const _PredictedPillOutline()
                            : null,
                        child: Container(
                          key: const ValueKey('division-current-rating'),
                          padding: EdgeInsets.symmetric(
                            horizontal: predicted ? 11.5 : 11,
                            vertical: predicted ? 7.5 : 7,
                          ),
                          decoration: BoxDecoration(
                            color: predicted ? Colors.transparent : _green,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            predicted ? 'Predicted $sr' : 'You · $sr',
                            style: _jakarta(
                              10.5,
                              color: predicted
                                  ? const Color(0xFF24472C)
                                  : Colors.white,
                              weight: 8,
                            ).copyWith(height: 1),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (current)
            Padding(
              padding: const EdgeInsets.only(left: 45, top: 12),
              child: Column(
                children: [
                  Semantics(
                    label: predicted
                        ? 'Predicted division progress'
                        : 'Division progress',
                    value: '${(progress * 100).round()}%',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: SizedBox(
                        key: const ValueKey('division-progress-track'),
                        width: double.infinity,
                        height: 6,
                        child: LayoutBuilder(
                          builder: (context, constraints) => Stack(
                            children: [
                              const Positioned.fill(
                                child: ColoredBox(color: Color(0xFFEFEBDF)),
                              ),
                              SizedBox(
                                key: const ValueKey('division-progress'),
                                width: constraints.maxWidth * progress,
                                height: 6,
                                child: CustomPaint(
                                  painter: _ProgressPainter(color, predicted),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$low',
                        style: _jakarta(10.5, weight: 7).copyWith(height: 1),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          division.isTop
                              ? 'Top division'
                              : '${high - sr!} to Division ${division.number - 1}',
                          textAlign: TextAlign.right,
                          style: _jakarta(10.5, weight: 7).copyWith(height: 1),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PredictedPillOutline extends CustomPainter {
  const _PredictedPillOutline();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.75),
          const Radius.circular(999),
        ),
      );
    final paint = Paint()
      ..color = _green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (double offset = 0; offset < metric.length; offset += 7.5) {
        canvas.drawPath(
          metric.extractPath(offset, (offset + 4.5).clamp(0, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PredictedPillOutline oldDelegate) => false;
}

class _ProgressPainter extends CustomPainter {
  const _ProgressPainter(this.color, this.dashed);
  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (!dashed) {
      canvas.drawRect(Offset.zero & size, paint);
      return;
    }
    for (double x = 0; x < size.width; x += 9) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, (size.width - x).clamp(0, 6), size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.dashed != dashed;
}
