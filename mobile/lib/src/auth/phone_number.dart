String normalizePhoneNumber(String input) {
  final compact = input.trim().replaceAll(RegExp(r'[\s().-]'), '');

  if (compact.startsWith('+')) {
    return compact;
  }

  if (compact.length == 10) {
    return '+1$compact';
  }

  if (compact.length == 11 && compact.startsWith('1')) {
    return '+$compact';
  }

  return compact;
}

bool isValidE164PhoneNumber(String input) {
  return RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(input);
}
