import 'package:flutter/material.dart';
import '../home/fieldrush_home_widgets.dart';
import 'fieldrush_rating_tracks.dart';

/// The HTML's compact, crest-led role switcher.
class FieldrushRatingRoleTabs extends StatelessWidget {
  const FieldrushRatingRoleTabs({
    super.key,
    required this.selected,
    required this.onChanged,
    this.ratings,
    this.dark = false,
  });
  final RatingTrack selected;
  final ValueChanged<RatingTrack> onChanged;
  final FieldrushPlayerRatings? ratings;
  final bool dark;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: dark ? const Color(0x14FFFFFF) : const Color(0xFFF2EFE3),
      border: dark ? null : Border.all(color: const Color(0xFFE6DFCB)),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final track in RatingTrack.values) ...[
          if (track != RatingTrack.values.first) const SizedBox(width: 2),
          Semantics(
            selected: track == selected,
            button: true,
            child: InkWell(
              key: ValueKey('rating-track-${track.value}'),
              onTap: () => onChanged(track),
              borderRadius: BorderRadius.circular(99),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.fromLTRB(6, 6, 11, 6),
                decoration: BoxDecoration(
                  color: track == selected
                      ? dark
                            ? const Color(0xFFF3EBD6)
                            : Colors.white
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FieldrushDivisionShield(
                      size: 14,
                      mini: true,
                      placement:
                          (ratings?.forTrack(track).matchesPlayed ?? 0) < 2,
                      division: ratings?.forTrack(track).division.number ?? 5,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      track.label,
                      style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 10.5,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        color: track == selected
                            ? const Color(0xFF22301F)
                            : dark
                            ? const Color(0xFFA9B3A6)
                            : const Color(0xFF55654A),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
