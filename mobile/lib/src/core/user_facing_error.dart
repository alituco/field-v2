import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String userFacingError(
  Object? error, {
  String fallback = 'Something went wrong. Please try again.',
}) {
  assert(() {
    debugPrint('Handled app error: $error');
    return true;
  }());

  if (error == null) return fallback;
  if (error is TimeoutException) {
    return 'That took too long. Check your connection and try again.';
  }

  final details = _errorDetails(error);
  final message = _cleanMessage(details.message);
  final lower = message.toLowerCase();
  final code = details.code?.toLowerCase();

  final codeMessage = _messageForCode(code, lower);
  if (codeMessage != null) return codeMessage;

  final knownMessage = _messageForKnownError(lower);
  if (knownMessage != null) return knownMessage;

  if (_isSafeMessage(message)) return _withPeriod(message);
  return fallback;
}

({String message, String? code}) _errorDetails(Object error) {
  if (error is PostgrestException) {
    return (message: error.message, code: error.code);
  }
  if (error is AuthException) {
    return (message: error.message, code: error.code ?? error.statusCode);
  }
  if (error is StorageException) {
    return (message: error.message, code: error.error ?? error.statusCode);
  }
  if (error is FunctionException) {
    return (
      message:
          _messageFromFunctionDetails(error.details) ??
          error.reasonPhrase ??
          'Function request failed.',
      code: error.status.toString(),
    );
  }
  if (error is PlatformException) {
    return (message: error.message ?? error.code, code: error.code);
  }
  if (error is StateError) {
    return (message: error.message, code: null);
  }
  if (error is ArgumentError) {
    return (message: error.message?.toString() ?? '', code: null);
  }
  return (message: error.toString(), code: null);
}

String? _messageFromFunctionDetails(Object? details) {
  if (details is String) return details;
  if (details is! Map) return null;

  for (final key in ['message', 'error', 'detail']) {
    final value = details[key];
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is Map) {
      final nested = _messageFromFunctionDetails(value);
      if (nested != null) return nested;
    }
  }
  return null;
}

String _cleanMessage(String rawMessage) {
  var message = rawMessage.trim();
  final wrapped = RegExp(
    r'^[A-Za-z]+Exception\(message:\s*(.*?)(?:,\s*(?:code|statusCode|details|hint|error):|\)$)',
    dotAll: true,
  ).firstMatch(message);
  if (wrapped != null) message = wrapped.group(1)?.trim() ?? message;

  message = message
      .replaceFirst(RegExp(r'^Exception:\s*'), '')
      .replaceFirst(RegExp(r'^Bad state:\s*'), '')
      .replaceFirst(RegExp(r'^Invalid argument\(s\):\s*'), '')
      .trim();

  if ((message.startsWith('"') && message.endsWith('"')) ||
      (message.startsWith("'") && message.endsWith("'"))) {
    message = message.substring(1, message.length - 1).trim();
  }
  return message;
}

String? _messageForCode(String? code, String message) {
  if (code == null) return null;

  if (code == '23505') {
    if (message.contains('username')) return 'That username is already taken.';
    if (message.contains('clans_tag') || message.contains('clan tag')) {
      return 'That clan tag is already taken.';
    }
    if (message.contains('fixture') || message.contains('time_slot')) {
      return 'That match time was just booked. Choose another time.';
    }
    return 'That already exists. Try a different value.';
  }
  if (code == '23503') {
    return 'This cannot be removed because it is still being used.';
  }
  if (code == '23514' || code == '23502' || code == '22p02') {
    return 'Some information is missing or invalid. Check it and try again.';
  }
  if (code == '42501' || code == '403') {
    return 'You do not have permission to do that.';
  }
  if (code == 'pgrst116') return 'We could not find that.';
  if (code == '57014' || code == '408' || code == '504') {
    return 'That took too long. Try again.';
  }
  if (code == 'otp_expired') {
    return 'That code has expired. Request a new one.';
  }
  if (code == 'over_request_rate_limit' || code == '429') {
    return 'Too many attempts. Wait a moment and try again.';
  }
  if (code == 'session_not_found' || code == 'refresh_token_not_found') {
    return 'Your session has expired. Sign in again.';
  }
  if (code == 'sms_send_failed' || code == 'sms_provider_disabled') {
    return 'We could not send a code to that number. Check it and try again.';
  }
  if (code.contains('photo') && code.contains('denied')) {
    return 'Allow photo access in Settings to choose a profile picture.';
  }
  return null;
}

String? _messageForKnownError(String message) {
  if (_containsAny(message, [
    'failed host lookup',
    'socketexception',
    'clientexception',
    'network request failed',
    'connection refused',
    'connection reset',
    'network is unreachable',
    'no address associated with hostname',
    'nodename nor servname provided',
  ])) {
    return 'You appear to be offline. Check your connection and try again.';
  }
  if (_containsAny(message, [
    'invalid verification code',
    'token has expired or is invalid',
    'otp expired',
    'invalid otp',
  ])) {
    return 'That code has expired or is invalid. Request a new one.';
  }
  if (message.contains('rate limit') || message.contains('too many requests')) {
    return 'Too many attempts. Wait a moment and try again.';
  }
  if (_containsAny(message, [
    'auth session missing',
    'jwt expired',
    'invalid jwt',
    'refresh token',
  ])) {
    return 'Your session has expired. Sign in again.';
  }
  if (message.contains('invalid login credentials')) {
    return 'Those sign-in details are incorrect.';
  }
  if (_containsAny(message, [
    'error sending confirmation otp',
    'sms provider',
    'invalid from number',
    '21212',
  ])) {
    return 'We could not send a code to that number. Check it and try again.';
  }
  if (message.contains('needs at least 7 players')) {
    return 'Your clan needs at least 7 players before you can book this match.';
  }
  if (message.contains('maximum of 20 players')) {
    return 'This clan is full. Clans can have up to 20 players.';
  }
  if (message.contains('profiles_username_unique_lower_idx')) {
    return 'That username is already taken.';
  }
  if (message.contains('clans_tag_unique_lower_idx')) {
    return 'That clan tag is already taken.';
  }
  if (message.contains('duplicate key') ||
      message.contains('unique constraint')) {
    return 'That is already in use. Try something different.';
  }
  if (message.contains('row-level security')) {
    return 'You do not have permission to do that.';
  }
  if (message.contains('payload too large') ||
      message.contains('file too large')) {
    return 'That file is too large. Choose a smaller one.';
  }
  if (message.contains('unsupported') && message.contains('image')) {
    return 'Choose a JPG, PNG, or WebP image.';
  }
  return null;
}

bool _isSafeMessage(String message) {
  if (message.isEmpty || message.length > 220) return false;
  final lower = message.toLowerCase();
  if (_containsAny(lower, [
    'postgrestexception',
    'authexception(',
    'storageexception',
    'functionexception',
    'socketexception',
    'clientexception',
    'constraint',
    'violates',
    'relation "',
    'column "',
    'sqlstate',
    'pgrst',
    'bad request',
    'statuscode',
    'stack trace',
    'null value in',
    'internal server error',
    'failed to fetch',
    'errno =',
  ])) {
    return false;
  }
  return RegExp(r'^[A-Za-z0-9]').hasMatch(message);
}

bool _containsAny(String value, List<String> needles) {
  return needles.any(value.contains);
}

String _withPeriod(String message) {
  if (RegExp(r'[.!?]$').hasMatch(message)) return message;
  return '$message.';
}
