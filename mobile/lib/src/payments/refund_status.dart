/// A cancellation frees the booking immediately; its card refund can settle
/// later. Only describe a refund as complete when the server says it is.
String cancellationRefundMessage({
  required int refundAmountFils,
  String? destination,
  String? status,
  bool isClan = false,
}) {
  final cancelled = isClan ? 'Clan booking cancelled.' : 'Booking cancelled.';
  if (refundAmountFils <= 0) return cancelled;
  final originalMethod = const {
    'ORIGINAL_PAYMENT_METHOD',
    'STRIPE',
  }.contains(destination?.trim().toUpperCase());
  final refundStatus = status?.trim().toUpperCase();
  if (refundStatus == 'FAILED') {
    return '$cancelled Your refund needs attention. Support has been alerted.';
  }
  if (refundStatus == 'SUCCEEDED' ||
      refundStatus == 'COMPLETED' ||
      refundStatus == 'PROCESSED') {
    return originalMethod
        ? '$cancelled Your refund was sent to your original payment method. Your bank may take a few days to show it.'
        : '$cancelled Your refund is complete.';
  }
  return originalMethod
      ? '$cancelled Your refund to the original payment method is pending.'
      : '$cancelled Your refund outcome has been recorded.';
}
