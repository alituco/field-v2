/** Use processor status, not a successful HTTP request, to describe a refund. */
export function refundRetryNotice(input: {
  status?: string;
  alreadySettled?: boolean;
  destination?: string;
}) {
  const status = input.status?.toUpperCase() ?? "PENDING";
  const original = input.destination === "ORIGINAL_PAYMENT_METHOD";
  if (input.alreadySettled) {
    return `This refund was already ${status.toLowerCase()}. No duplicate refund was issued.`;
  }
  if (["COMPLETED", "SUCCEEDED", "PROCESSED"].includes(status)) {
    return original
      ? "Refund sent to the original payment method. The customer's bank may take a few days to show it."
      : "Refund completed to the recorded destination.";
  }
  if (status === "FAILED") return "The refund still needs attention. Review the recorded failure before retrying.";
  return "Refund retry queued. It will remain pending until the payment processor confirms it.";
}

export function refundNeedsAttention(row: {
  status: unknown;
  updated_at: unknown;
  created_at?: unknown;
}, now = new Date()) {
  if (row.status === "FAILED") return true;
  if (!["PENDING", "PROCESSING"].includes(String(row.status))) return false;
  const updated = new Date(String(row.updated_at ?? row.created_at)).getTime();
  return Number.isFinite(updated) && now.getTime() - updated > 2 * 60 * 60 * 1000;
}

function record(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return record(value[0]);
  return value && typeof value === "object" ? value as Record<string, unknown> : {};
}

export function refundRequiresManualReview(row: Record<string, unknown>) {
  return row.external_refund_review_required === true ||
    row.provider_status === "external_refund_review" ||
    record(row.payment_intent).external_refund_review_required === true;
}

export function paymentIntentAttention(payment: Record<string, unknown>) {
  const manual = refundRequiresManualReview(payment);
  const reference = String(payment.provider_intent_id ?? payment.provider_payment_id ?? payment.id);
  const external = Array.isArray(payment.external_payment_refunds)
    ? payment.external_payment_refunds.map((value) => {
      const refund = record(value);
      return `${String(refund.provider_refund_id)} ($${(Number(refund.amount_minor) / 100).toFixed(2)} USD, ${String(refund.provider_status)})`;
    }).join("; ") : "";
  return {
    id: `payment-${payment.id}`,
    kind: manual ? "PAYMENT_EXTERNAL_REFUND_REVIEW" : "PAYMENT_RECONCILIATION",
    severity: "CRITICAL",
    title: manual ? "Stripe Dashboard refund needs manual reconciliation" : "Captured payment needs reconciliation",
    detail: manual
      ? `${reference}${external ? ` · ${external}` : ""}. A Dashboard refund does not cancel a booking. Reconcile Stripe refunds against the booking and policy ledger before releasing this hold. Do not issue another refund or use Retry.`
      : `${(Number(payment.amount_fils) / 1000).toFixed(payment.currency === "USD" ? 2 : 3)} ${String(payment.currency)} · ${String(payment.purpose).replaceAll("_", " ")} · ${String(payment.provider)} ${reference}${payment.failure_reason ? ` · ${String(payment.failure_reason)}` : ""}`,
    createdAt: payment.created_at,
    paymentRefundId: null,
    resolution: manual ? "PAYMENT_MANUAL_RECONCILIATION" : "PAYMENT_REVIEW",
    dismissible: false,
  };
}

export function paymentRefundAttention(refund: Record<string, unknown>) {
  const manual = refundRequiresManualReview(refund);
  return {
    id: `payment-refund-${refund.id}`,
    kind: "PAYMENT_REFUND",
    severity: manual || refund.status === "FAILED" ? "CRITICAL" : "HIGH",
    title: manual ? "Refund held for external-payment reconciliation"
      : refund.status === "FAILED" ? "Card refund failed" : "Card refund processing is delayed",
    detail: `${(Number(refund.amount_fils) / 1000).toFixed(refund.currency === "USD" ? 2 : 3)} ${String(refund.currency)} · Original payment method${manual
      ? ". Reconcile the Stripe Dashboard refund against this payment before issuing anything further. This hold cannot be cleared with Retry."
      : refund.last_error ? ` · ${String(refund.last_error)}` : " · Waiting for processor confirmation"}`,
    createdAt: refund.created_at,
    paymentRefundId: manual ? null : String(refund.id),
    resolution: manual ? "PAYMENT_MANUAL_RECONCILIATION" : "RETRY_PAYMENT_REFUND",
    dismissible: false,
  };
}
