const minimumPlayerAge = 16;

DateTime latestEligibleDateOfBirth({DateTime? today}) {
  final date = _dateOnly(today ?? DateTime.now());
  return DateTime(date.year - minimumPlayerAge, date.month, date.day);
}

bool isEligibleDateOfBirth(DateTime dateOfBirth, {DateTime? today}) {
  final birthDate = _dateOnly(dateOfBirth);
  return !birthDate.isAfter(latestEligibleDateOfBirth(today: today));
}

String dateOfBirthToIso(DateTime dateOfBirth) {
  final date = _dateOnly(dateOfBirth);
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

DateTime? parseDateOfBirth(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(value.trim());
  return parsed == null ? null : _dateOnly(parsed);
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
