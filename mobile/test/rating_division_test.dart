import 'package:field/src/ranking/rating_division.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Field rating divisions', () {
    test('Division 5 is the entry division and Division 1 is the top', () {
      expect(divisionFromRating(-50), RatingDivision.division5);
      expect(divisionFromRating(999), RatingDivision.division5);
      expect(divisionFromRating(1000), RatingDivision.division4);
      expect(divisionFromRating(1299), RatingDivision.division4);
      expect(divisionFromRating(1300), RatingDivision.division3);
      expect(divisionFromRating(1599), RatingDivision.division3);
      expect(divisionFromRating(1600), RatingDivision.division2);
      expect(divisionFromRating(1799), RatingDivision.division2);
      expect(divisionFromRating(1800), RatingDivision.division1);
    });

    test('each division exposes the correct next promotion target', () {
      expect(RatingDivision.division5.nextDivisionRating, 1000);
      expect(RatingDivision.division4.nextDivisionRating, 1300);
      expect(RatingDivision.division3.nextDivisionRating, 1600);
      expect(RatingDivision.division2.nextDivisionRating, 1800);
      expect(RatingDivision.division1.nextDivisionRating, isNull);
    });
  });
}
