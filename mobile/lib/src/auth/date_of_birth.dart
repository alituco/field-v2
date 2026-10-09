const minimumPlayerAge = 18;

DateTime latestEligibleDateOfBirth({DateTime? today}) {
  final date = _dateOnly(today ?? DateTime.now());
  final year = date.year - minimumPlayerAge;
  // Clamp February 29 instead of allowing Dart to roll it into March.
  final lastDay = DateTime(year, date.month + 1, 0).day;
  return DateTime(year, date.month, date.day.clamp(1, lastDay));
}

bool isEligibleDateOfBirth(DateTime dateOfBirth, {DateTime? today}) {
  final birthDate = _dateOnly(dateOfBirth);
  return birthDate.year >= 1900 &&
      !birthDate.isAfter(latestEligibleDateOfBirth(today: today));
}

String dateOfBirthToIso(DateTime dateOfBirth) {
  final date = _dateOnly(dateOfBirth);
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

DateTime? parseDateOfBirth(Object? value) {
  if (value is! String) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final parsed = DateTime(year, month, day);
  if (year < 1900 ||
      parsed.year != year ||
      parsed.month != month ||
      parsed.day != day) {
    return null;
  }
  return parsed;
}

String formatDateOfBirth(DateTime dateOfBirth) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final date = _dateOnly(dateOfBirth);
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
