import 'package:field/src/core/user_facing_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('userFacingError', () {
    test('keeps database business rules and removes Postgres metadata', () {
      const error = PostgrestException(
        message:
            'Your clan needs at least 7 players before paying for a match.',
        code: 'P0001',
        details: 'Bad Request',
      );

      final message = userFacingError(error);

      expect(
        message,
        'Your clan needs at least 7 players before you can book this match.',
      );
      expect(message, isNot(contains('PostgrestException')));
      expect(message, isNot(contains('P0001')));
      expect(message, isNot(contains('Bad Request')));
    });

    test('maps unique constraints to a useful action', () {
      const error = PostgrestException(
        message:
            'duplicate key value violates unique constraint "profiles_username_unique_lower_idx"',
        code: '23505',
      );

      expect(userFacingError(error), 'That username is already taken.');
    });

    test('maps network internals to an offline message', () {
      final error = Exception(
        "ClientException with SocketException: Failed host lookup: 'example.supabase.co' (errno = 8)",
      );

      expect(
        userFacingError(error),
        'You appear to be offline. Check your connection and try again.',
      );
    });

    test('maps expired OTP errors', () {
      const error = AuthException(
        'Token has expired or is invalid',
        code: 'otp_expired',
      );

      expect(
        userFacingError(error),
        'That code has expired. Request a new one.',
      );
    });

    test('extracts user messages from function responses', () {
      const error = FunctionException(
        status: 400,
        details: {'error': 'This match is no longer open.'},
      );

      expect(userFacingError(error), 'This match is no longer open.');
    });

    test('hides unknown database internals behind the supplied fallback', () {
      const error = PostgrestException(
        message:
            'new row for relation "fixtures" violates check constraint "fixture_check"',
        code: 'XX000',
      );

      expect(
        userFacingError(error, fallback: 'We could not book this match.'),
        'We could not book this match.',
      );
    });
  });
}
