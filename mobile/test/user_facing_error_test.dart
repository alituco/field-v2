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

    test('explains upcoming clan and solo limits', () {
      expect(
        userFacingError(
          const PostgrestException(
            message:
                'Your clan can have a maximum of 2 upcoming matches. Finish or cancel one before scheduling another.',
            code: 'P0001',
          ),
        ),
        'Your clan already has 2 upcoming matches. Finish or cancel one before scheduling another.',
      );
      expect(
        userFacingError(
          const PostgrestException(
            message:
                'You can have a maximum of 2 upcoming solo games. Cancel one before booking another.',
            code: 'P0001',
          ),
        ),
        'You already have an upcoming or active game. Finish or cancel it before booking another.',
      );
    });

    test('explains single-game registration and unfinished checkout conflicts', () {
      expect(
        userFacingError(
          const PostgrestException(
            message:
                'You can only be registered in one upcoming or active game. Finish or cancel your current game before booking another.',
            code: 'P0001',
          ),
        ),
        'You already have an upcoming or active game. Finish or cancel it before booking another.',
      );
      expect(
        userFacingError(
          const FunctionException(
            status: 409,
            details: {
              'error':
                  'Finish or cancel your earlier game checkout before booking another game.',
            },
          ),
        ),
        'Finish or cancel your earlier checkout before booking another game.',
      );
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

    test('missing RPC or table uses the screen fallback, not schema details', () {
      for (final code in ['PGRST202', 'PGRST205']) {
        final error = PostgrestException(
          message:
              'Could not find the function public.list_fieldrush_player_rating_page '
              'in the schema cache.',
          code: code,
        );
        expect(
          userFacingError(error, fallback: 'Could not load ranks. Try again.'),
          'Could not load ranks. Try again.',
        );
      }
    });
  });
}
