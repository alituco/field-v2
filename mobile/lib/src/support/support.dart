import 'dart:math';

enum SupportRequestCategory {
  appOrTechnical(
    'APP_OR_TECHNICAL',
    'App or technical',
    'Something is not loading, working, or displaying correctly',
  ),
  bookingOrPayment(
    'BOOKING_OR_PAYMENT',
    'Booking or payment',
    'A reservation, refund, charge, or payment issue',
  ),
  matchOrVenue(
    'MATCH_OR_VENUE',
    'Match or venue',
    'A problem with match information, scheduling, or the venue',
  ),
  accountOrProfile(
    'ACCOUNT_OR_PROFILE',
    'Account or profile',
    'Help with your account, access, or profile information',
  ),
  safety(
    'SAFETY',
    'Safety concern',
    'A safety issue that the Field team should review',
  ),
  feedback(
    'FEEDBACK',
    'Feedback',
    'An idea or suggestion that could make Field better',
  ),
  other('OTHER', 'Something else', 'Anything that does not fit above');

  const SupportRequestCategory(this.wireValue, this.label, this.description);

  final String wireValue;
  final String label;
  final String description;
}

class SupportRequestDraft {
  const SupportRequestDraft({
    required this.category,
    required this.details,
    required this.clientRequestId,
    this.context = const {},
  });

  final SupportRequestCategory category;
  final String details;
  final String clientRequestId;
  final Map<String, Object?> context;

  Map<String, dynamic> toRpcParams() {
    return {
      'category_to_use': category.wireValue,
      'details_to_use': details.trim(),
      'context_to_use': Map<String, Object?>.from(context),
      'client_request_id_to_use': clientRequestId,
    };
  }
}

String createSupportClientRequestId({Random? random}) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

class SupportRequestReceipt {
  const SupportRequestReceipt({required this.id, this.reference});

  final String id;
  final String? reference;

  String get shortReference {
    final provided = reference?.trim();
    if (provided != null && provided.isNotEmpty) return provided.toUpperCase();
    final normalized = id.replaceAll('-', '').toUpperCase();
    if (normalized.length <= 8) return normalized;
    return normalized.substring(0, 8);
  }

  factory SupportRequestReceipt.fromRpcResponse(Object? response) {
    final responseMap = switch (response) {
      final Map map => map,
      final List list when list.isNotEmpty && list.first is Map =>
        list.first as Map,
      _ => null,
    };
    final value = response is String
        ? response
        : responseMap?['ticket_id'] ?? responseMap?['id'];
    final id = value?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw StateError('Your support request could not be confirmed.');
    }
    final reference = responseMap?['reference']?.toString().trim();
    return SupportRequestReceipt(
      id: id,
      reference: reference == null || reference.isEmpty ? null : reference,
    );
  }
}
