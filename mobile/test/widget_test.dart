import 'package:field/src/app.dart';
import 'package:field/src/auth/phone_number.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a helpful message when Supabase config is missing', (
    tester,
  ) async {
    await tester.pumpWidget(const FieldApp(hasSupabaseConfig: false));

    expect(find.text('Supabase config missing'), findsOneWidget);
    expect(
      find.textContaining('--dart-define-from-file=.env.mobile'),
      findsOneWidget,
    );
  });

  group('normalizePhoneNumber', () {
    test('keeps E.164 phone numbers', () {
      expect(normalizePhoneNumber('+15551234567'), '+15551234567');
    });

    test('keeps Bahrain E.164 phone numbers with spaces', () {
      expect(normalizePhoneNumber('+973 3333 3333'), '+97333333333');
      expect(isValidE164PhoneNumber('+97333333333'), isTrue);
    });

    test('converts a 10 digit US number to E.164', () {
      expect(normalizePhoneNumber('(555) 123-4567'), '+15551234567');
    });

    test('converts an 11 digit US number to E.164', () {
      expect(normalizePhoneNumber('1 555 123 4567'), '+15551234567');
    });
  });
}
