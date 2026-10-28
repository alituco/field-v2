type RetryActor = {
  profileId: string;
  role: string;
  isActive: boolean;
} | null;

type StoreResult = {
  data: unknown;
  error: { message: string } | null;
};

type RetryArguments = {
  actor_admin_id: string;
  refund_id_to_retry: string;
  reason_to_use: string;
};

type RetryStore = {
  retry: (name: string, args: RetryArguments) => Promise<StoreResult>;
  resolutionCase?: (kind: "SOLO" | "CLAN", gameId: string) => Promise<StoreResult>;
  resolutionRefund?: (refundId: string) => Promise<StoreResult>;
};

type RetryReply = { status: number; body: Record<string, unknown> };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function record(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return record(value[0]);
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function failure(status: number, error: string): RetryReply {
  return { status, body: { error } };
}

/** Retries an existing, server-priced refund; never accepts payment amounts or recipients. */
export async function retryAdminRefund(input: {
  actor: RetryActor;
  refundId: string;
  body: unknown;
  match?: { kind: string; gameId: string };
  store: RetryStore;
}): Promise<RetryReply> {
  const { actor, refundId, store } = input;
  if (!actor) return failure(401, "Sign in to manage refunds.");
  if (actor.role !== "admin" || !actor.isActive) {
    return failure(403, "Active administrator access is required.");
  }
  const body = record(input.body);
  const reason = typeof body.reason === "string" ? body.reason.trim() : "";
  if (!UUID.test(refundId) || reason.length < 10 || reason.length > 2000) {
    return failure(400, "Choose a valid refund and give a reason of 10 to 2000 characters.");
  }

  let rpc = "admin_retry_payment_refund";
  let retryId = refundId;
  if (input.match) {
    const kind = input.match.kind.trim().toUpperCase();
    if ((kind !== "SOLO" && kind !== "CLAN") || !UUID.test(input.match.gameId)) {
      return failure(400, "Choose a valid clan or solo game and refund.");
    }
    if (!store.resolutionCase || !store.resolutionRefund) {
      return failure(500, "Could not verify this match resolution.");
    }
    const caseResult = await store.resolutionCase(kind, input.match.gameId);
    if (caseResult.error) return failure(500, "Could not verify this match resolution.");
    const caseData = record(caseResult.data);
    if (!caseData.id) return failure(404, "No match resolution case exists for this game.");

    const refundResult = await store.resolutionRefund(refundId);
    if (refundResult.error) return failure(500, "Could not verify this refund.");
    const refund = record(refundResult.data);
    if (!refund.id || String(refund.case_id) !== String(caseData.id)) {
      return failure(404, "This refund does not belong to this match resolution.");
    }
    const providerRefund = record(refund.payment_refund);
    if (providerRefund.provider_status === "external_refund_review" ||
        record(providerRefund.payment_intent).external_refund_review_required === true) {
      return failure(409, "Manual reconciliation of the external Stripe refund is required. Retry cannot release this hold.");
    }
    if (String(refund.status).toUpperCase() !== "FAILED") {
      return failure(409, "Only failed match-resolution refunds can be retried here.");
    }
    if (typeof refund.payment_refund_id === "string" && UUID.test(refund.payment_refund_id)) {
      // New processor refunds are queued, not credited synchronously to a wallet.
      retryId = refund.payment_refund_id;
    } else {
      rpc = "admin_retry_match_resolution_refund";
    }
  }

  // Actor comes from the authenticated session; amount, currency, destination,
  // processor ID and recipient are resolved/locked by the database RPC.
  const result = await store.retry(rpc, {
    actor_admin_id: actor.profileId,
    refund_id_to_retry: retryId,
    reason_to_use: reason,
  });
  if (result.error) {
    const message = result.error.message;
    const normalized = message.toLowerCase();
    return failure(
      normalized.includes("access") ? 403 : normalized.includes("not found") ? 404 : 409,
      message,
    );
  }
  const data = record(result.data);
  if (String(data.status).toUpperCase() === "FAILED") {
    const reason = typeof data.failure_reason === "string" && data.failure_reason.trim()
      ? data.failure_reason.trim() : "The refund failed again.";
    return { status: 502, body: { error: `Refund retry failed: ${reason}`, result: data } };
  }
  // A successful queue write is not a completed card refund. Preserve PENDING.
  return { status: 200, body: { ok: true, result: data } };
}
