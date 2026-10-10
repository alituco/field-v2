import assert from "node:assert/strict";
import test from "node:test";

import { retryAdminRefund } from "../src/lib/admin-payment-refund-retry.ts";

const actor = { profileId: "11111111-1111-4111-8111-111111111111", role: "admin", isActive: true };
const refundId = "22222222-2222-4222-8222-222222222222";
const gameId = "33333333-3333-4333-8333-333333333333";
const caseId = "44444444-4444-4444-8444-444444444444";
const paymentRefundId = "55555555-5555-4555-8555-555555555555";
const reason = "Confirmed original payment refund needs retry.";

function setup(overrides = {}) {
  const calls = [];
  const store = {
    retry: async (...args) => { calls.push(["retry", ...args]); return { data: { status: "PENDING" }, error: null }; },
    resolutionCase: async (...args) => { calls.push(["case", ...args]); return { data: { id: caseId }, error: null }; },
    resolutionRefund: async (...args) => { calls.push(["refund", ...args]); return { data: { id: refundId, case_id: caseId, status: "FAILED" }, error: null }; },
    ...overrides,
  };
  return { calls, store, input: { actor, refundId, body: { reason }, store } };
}

test("refund retries reject unauthenticated, non-admin and inactive users before database access", async () => {
  for (const [user, status] of [[null, 401], [{ ...actor, role: "referee" }, 403], [{ ...actor, isActive: false }, 403]]) {
    const { input, calls } = setup();
    assert.equal((await retryAdminRefund({ ...input, actor: user })).status, status);
    assert.deepEqual(calls, []);
  }
});

test("refund retries reject malformed references and missing/short/oversized reasons", async () => {
  for (const changes of [{ refundId: "not-a-uuid" }, { body: null }, { body: { reason: "short" } }, { body: { reason: "x".repeat(2001) } }]) {
    const { input, calls } = setup();
    assert.equal((await retryAdminRefund({ ...input, ...changes })).status, 400);
    assert.deepEqual(calls, []);
  }
});

test("request cannot choose refund amount, recipient, actor, currency or processor reference", async () => {
  const { input, calls } = setup();
  const response = await retryAdminRefund({ ...input, body: {
    reason: `  ${reason}  `, amount_fils: 999999999, amount_minor: 9999999,
    recipient_profile_id: gameId, actor_admin_id: gameId, currency: "EUR",
    provider_refund_id: "re_attacker", intent_id: gameId, destination: "FIELD_WALLET",
  } });
  assert.equal(response.status, 200);
  assert.deepEqual(calls, [["retry", "admin_retry_payment_refund", {
    actor_admin_id: actor.profileId, refund_id_to_retry: refundId, reason_to_use: reason,
  }]]);
  assert.equal(response.body.result.status, "PENDING");
});

test("match-scoped retry checks game identity and rejects a refund from another match", async () => {
  const { input, calls } = setup({ resolutionRefund: async () => ({ data: { id: refundId, case_id: gameId, status: "FAILED" }, error: null }) });
  const response = await retryAdminRefund({ ...input, match: { kind: "clan", gameId } });
  assert.equal(response.status, 404);
  assert.match(response.body.error, /does not belong/);
  assert.deepEqual(calls, [["case", "CLAN", gameId]]);
});

test("match retries reject unknown match kinds and invalid game IDs before queries", async () => {
  for (const match of [{ kind: "other", gameId }, { kind: "SOLO", gameId: "invalid" }]) {
    const { input, calls } = setup();
    assert.equal((await retryAdminRefund({ ...input, match })).status, 400);
    assert.deepEqual(calls, []);
  }
});

test("match retry cannot retry absent, already completed or pending resolution refunds", async () => {
  for (const status of ["COMPLETED", "PENDING"]) {
    const { input, calls } = setup({ resolutionRefund: async () => ({ data: { id: refundId, case_id: caseId, status }, error: null }) });
    assert.equal((await retryAdminRefund({ ...input, match: { kind: "SOLO", gameId } })).status, 409);
    assert.equal(calls.some(([name]) => name === "retry"), false);
  }
  const { input, calls } = setup({ resolutionCase: async () => ({ data: null, error: null }) });
  assert.equal((await retryAdminRefund({ ...input, match: { kind: "SOLO", gameId } })).status, 404);
  assert.deepEqual(calls, []);
});

test("linked Stripe match refund queues the stored payment refund ID, not client IDs", async () => {
  const { input, calls } = setup({ resolutionRefund: async () => ({ data: {
    id: refundId, case_id: caseId, status: "FAILED", payment_refund_id: paymentRefundId,
  }, error: null }) });
  const response = await retryAdminRefund({ ...input, match: { kind: "SOLO", gameId }, body: { reason, payment_refund_id: gameId } });
  assert.equal(response.status, 200);
  assert.deepEqual(calls.at(-1), ["retry", "admin_retry_payment_refund", {
    actor_admin_id: actor.profileId, refund_id_to_retry: paymentRefundId, reason_to_use: reason,
  }]);
  assert.equal(response.body.result.status, "PENDING");
});

test("historical match refunds retain their original audited retry path", async () => {
  const { input, calls } = setup();
  assert.equal((await retryAdminRefund({ ...input, match: { kind: "CLAN", gameId } })).status, 200);
  assert.deepEqual(calls.at(-1), ["retry", "admin_retry_match_resolution_refund", {
    actor_admin_id: actor.profileId, refund_id_to_retry: refundId, reason_to_use: reason,
  }]);
});

test("external Stripe refund hold rejects match retry without issuing an RPC", async () => {
  const { input, calls } = setup({ resolutionRefund: async () => ({ data: {
    id: refundId, case_id: caseId, status: "FAILED", payment_refund_id: paymentRefundId,
    payment_refund: { provider_status: "external_refund_review" },
  }, error: null }) });
  const result = await retryAdminRefund({ ...input, match: { kind: "SOLO", gameId } });
  assert.equal(result.status, 409);
  assert.match(result.body.error, /Manual reconciliation/);
  assert.equal(calls.some(([name]) => name === "retry"), false);
});

test("server-enforced external refund hold never returns queued or success", async () => {
  const { input } = setup({ retry: async () => ({ data: null, error: {
    message: "Reconcile the external Stripe refund before retrying this payment refund.",
  } }) });
  const result = await retryAdminRefund(input);
  assert.equal(result.status, 409);
  assert.equal(result.body.ok, undefined);
  assert.equal(result.body.result, undefined);
});

test("RPC authorization/conflict errors and processor failures are not reported as successes", async () => {
  for (const [message, status] of [["access denied", 403], ["refund not found", 404], ["resolution superseded", 409]]) {
    const { input } = setup({ retry: async () => ({ data: null, error: { message } }) });
    const result = await retryAdminRefund(input);
    assert.equal(result.status, status);
    assert.equal(result.body.ok, undefined);
  }
  const { input } = setup({ retry: async () => ({ data: { status: "FAILED", failure_reason: "Processor declined refund" }, error: null }) });
  assert.equal((await retryAdminRefund(input)).status, 502);
});

test("processor success and processing states remain distinct in the API response", async () => {
  for (const status of ["PROCESSING", "SUCCEEDED", "COMPLETED"]) {
    const { input } = setup({ retry: async () => ({ data: { status }, error: null }) });
    const result = await retryAdminRefund(input);
    assert.equal(result.status, 200);
    assert.equal(result.body.result.status, status);
  }
});
