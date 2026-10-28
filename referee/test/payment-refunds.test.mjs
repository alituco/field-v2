import assert from "node:assert/strict";
import test from "node:test";

import { paymentIntentAttention, paymentRefundAttention, refundNeedsAttention, refundRetryNotice, refundRequiresManualReview } from "../src/lib/payment-refunds.ts";

test("queued retries never claim refund completion", () => {
  assert.match(refundRetryNotice({ status: "PENDING" }), /queued/);
  assert.match(refundRetryNotice({ status: "PROCESSING" }), /pending/);
  assert.match(refundRetryNotice({}), /pending/);
  assert.doesNotMatch(refundRetryNotice({ status: "PENDING" }), /completed/);
});

test("completed original-method refund distinguishes processor and bank settlement", () => {
  assert.match(refundRetryNotice({ status: "SUCCEEDED", destination: "ORIGINAL_PAYMENT_METHOD" }), /bank may take a few days/);
  assert.match(refundRetryNotice({ status: "COMPLETED", destination: "FIELD_WALLET" }), /recorded destination/);
  assert.match(refundRetryNotice({ status: "SUCCEEDED", alreadySettled: true }), /No duplicate/);
});

test("failed and stale processing refunds need attention, completed ones do not", () => {
  const now = new Date("2026-10-10T14:00:00Z");
  assert.equal(refundNeedsAttention({ status: "FAILED", updated_at: now }, now), true);
  assert.equal(refundNeedsAttention({ status: "PROCESSING", updated_at: "2026-10-10T11:59:00Z" }, now), true);
  assert.equal(refundNeedsAttention({ status: "PENDING", updated_at: "2026-10-10T11:59:00Z" }, now), true);
  assert.equal(refundNeedsAttention({ status: "PROCESSING", updated_at: "2026-10-10T13:59:00Z" }, now), false);
  assert.equal(refundNeedsAttention({ status: "SUCCEEDED", updated_at: "2026-10-10T10:00:00Z" }, now), false);
});

test("Stripe Dashboard refund remains a manual review item even without a policy refund", () => {
  const item = paymentIntentAttention({
    id: "intent", status: "FINALIZED", provider: "STRIPE", provider_intent_id: "pi_test",
    external_refund_review_required: true,
    external_payment_refunds: [{ provider_refund_id: "re_dashboard", amount_minor: 500, currency: "USD", provider_status: "succeeded" }],
  });
  assert.equal(item.kind, "PAYMENT_EXTERNAL_REFUND_REVIEW");
  assert.equal(item.resolution, "PAYMENT_MANUAL_RECONCILIATION");
  assert.equal(item.dismissible, false);
  assert.equal(item.paymentRefundId, null);
  assert.match(item.detail, /re_dashboard \(\$5\.00 USD, succeeded\)/);
  assert.match(item.detail, /does not cancel a booking/);
  assert.match(item.detail, /Do not issue another refund or use Retry/);
});

test("external reconciliation holds never expose an automatic retry action", () => {
  for (const hold of [
    { provider_status: "external_refund_review" },
    { payment_intent: { external_refund_review_required: true } },
    { payment_intent: [{ external_refund_review_required: true }] },
  ]) {
    assert.equal(refundRequiresManualReview(hold), true);
    const item = paymentRefundAttention({ id: "refund", amount_fils: 13000, currency: "USD", status: "FAILED", ...hold });
    assert.equal(item.paymentRefundId, null);
    assert.equal(item.dismissible, false);
    assert.equal(item.resolution, "PAYMENT_MANUAL_RECONCILIATION");
    assert.match(item.detail, /cannot be cleared with Retry/);
  }
});

test("ordinary failed refunds retain their audited retry option", () => {
  const item = paymentRefundAttention({ id: "refund", amount_fils: 13000, currency: "USD", status: "FAILED", provider_status: "failed" });
  assert.equal(item.paymentRefundId, "refund");
  assert.equal(item.resolution, "RETRY_PAYMENT_REFUND");
  assert.equal(item.dismissible, false);
});
