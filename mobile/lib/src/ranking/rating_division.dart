import 'dart:ui';

/// Field's single rating ladder. Division 5 is the entry division and
/// Division 1 is the highest division.
enum RatingDivision {
  division5(
    number: 5,
    minimumRating: 0,
    maximumRating: 999,
    colors: [Color(0xFFF6E2C5), Color(0xFFC08A4E), Color(0xFF6B3D16)],
    highlight: Color(0xFFFFF3DF),
    stroke: Color(0xFF3F2410),
  ),
  division4(
    number: 4,
    minimumRating: 1000,
    maximumRating: 1299,
    colors: [Color(0xFFE4ECF3), Color(0xFF8695A5), Color(0xFF3C4652)],
    highlight: Color(0xFFF8FBFF),
    stroke: Color(0xFF232B34),
  ),
  division3(
    number: 3,
    minimumRating: 1300,
    maximumRating: 1599,
    colors: [Color(0xFFF8FAFC), Color(0xFF9FB0C3), Color(0xFF465569)],
    highlight: Color(0xFFFFFFFF),
    stroke: Color(0xFF1E293B),
  ),
  division2(
    number: 2,
    minimumRating: 1600,
    maximumRating: 1799,
    colors: [Color(0xFFFEF0B8), Color(0xFFF2A416), Color(0xFF8A4B0C)],
    highlight: Color(0xFFFFF8D8),
    stroke: Color(0xFF3A1D02),
  ),
  division1(
    number: 1,
    minimumRating: 1800,
    maximumRating: null,
    colors: [Color(0xFFE9FFF6), Color(0xFF34D399), Color(0xFF065F46)],
    highlight: Color(0xFFF0FFF8),
    stroke: Color(0xFF043027),
  );

  const RatingDivision({
    required this.number,
    required this.minimumRating,
    required this.maximumRating,
    required this.colors,
    required this.highlight,
    required this.stroke,
  });

  final int number;
  final int minimumRating;
  final int? maximumRating;
  final List<Color> colors;
  final Color highlight;
  final Color stroke;

  String get label => 'Division $number';

  bool get isTop => number == 1;

  int get stars => 6 - number;

  bool get hasWings => number <= 4;

  bool get hasLaurel => number <= 3;

  bool get hasCrown => number <= 2;

  bool get hasRays => number == 1;

  int? get nextDivisionRating => isTop ? null : maximumRating! + 1;

  double progressFor(int rating) {
    if (isTop) return 1;
    final span = nextDivisionRating! - minimumRating;
    return ((rating - minimumRating) / span).clamp(0, 1).toDouble();
  }
}

RatingDivision divisionFromRating(int rating) {
  if (rating >= 1800) return RatingDivision.division1;
  if (rating >= 1600) return RatingDivision.division2;
  if (rating >= 1300) return RatingDivision.division3;
  if (rating >= 1000) return RatingDivision.division4;
  return RatingDivision.division5;
}

String ratingDivisionLabel(int rating) => divisionFromRating(rating).label;
