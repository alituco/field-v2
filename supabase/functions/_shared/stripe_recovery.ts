import {
  object,
  PaymentDatabase,
  PaymentError,
  PaymentIntent,
  Stripe,
  text,
  verifyStripePayment,
} from "./stripe_checkout.ts";

type RecoveryRuntime = {
  admin: PaymentDatabase;
  stripe: Stripe;
  livemode: boolean;
  deadlineMs?: number;
};

/** Safe provider fields only: never persist a client secret, card or customer. */
export function recoveryEvidence(payment: Stripe.PaymentIntent) {
  return {
    id: payment.id,
    object: payment.object,
    amount: payment.amount,
    amount_received: payment.amount_received,
    currency: payment.currency,
    livemode: payment.livemode,
    status: payment.status,
    capture_method: payment.capture_method,
    payment_method_types: payment.payment_method_types,
    metadata: {
      field_payment_intent_id: payment.metadata?.field_payment_intent_id,
      field_profile_id: payment.metadata?.field_profile_id,
      field_purpose: payment.metadata?.field_purpose,
      field_transaction_reference: payment.metadata
        ?.field_transaction_reference,
    },
  };
}

export class CheckoutRecoveryRequired extends PaymentError {
  constructor(readonly reviewReference: string | null) {
    super(
      "Your earlier checkout needs payment review. No new payment was started." +
        (reviewReference ? ` Support reference: ${reviewReference}.` : ""),
      409,
    );
  }
}

/**
 * Positive-only recovery after the original idempotency window. Stripe Search
 * is eventually consistent; use LIST and persist its fixed range/cursor instead.
 * An empty or incomplete result NEVER releases the player's checkout lease.
 * https://docs.stripe.com/search#data-freshness
 */
export async function recoverOrphanStripeIntent(
  ctx: RecoveryRuntime,
  intent: PaymentIntent,
): Promise<Stripe.PaymentIntent> {
  const claimId = crypto.randomUUID();
  const claim = await ctx.admin.rpc("claim_stripe_checkout_recovery", {
    intent_id_to_use: intent.id,
    claim_id_to_use: claimId,
    livemode_to_use: ctx.livemode,
  });
  if (claim.error) throw claim.error;
  const state = object(claim.data);
  const reference = text(state?.case_id);
  const existingId = text(state?.provider_intent_id);
  if (existingId) {
    const payment = await ctx.stripe.paymentIntents.retrieve(existingId, {
      expand: ["latest_charge"],
    });
    verifyStripePayment(payment, intent, ctx.livemode);
    intent.provider_intent_id = existingId;
    return payment;
  }
  if (state?.claimed !== true) throw new CheckoutRecoveryRequired(reference);
  const from = state.scan_from;
  const until = state.scan_until;
  if (
    !Number.isSafeInteger(from) || !Number.isSafeInteger(until) ||
    Number(from) > Number(until) || !Array.isArray(state.provider_evidence) ||
    !Number.isSafeInteger(state.pages_scanned)
  ) throw new CheckoutRecoveryRequired(reference);

  const evidence = new Map<string, ReturnType<typeof recoveryEvidence>>();
  for (const entry of state.provider_evidence) {
    const candidate = object(entry);
    const id = text(candidate?.id);
    if (!candidate || !id) throw new CheckoutRecoveryRequired(reference);
    evidence.set(id, candidate as ReturnType<typeof recoveryEvidence>);
  }
  let cursor = text(state.scan_cursor);
  let pages = Number(state.pages_scanned);
  let complete = false;
  let unavailable = false;
  const deadline = Math.min(ctx.deadlineMs ?? Infinity, Date.now() + 20_000);
  try {
    for (let page = 0; page < 3; page++) {
      const remaining = deadline - Date.now();
      if (remaining < 1_000) break;
      const result = await ctx.stripe.paymentIntents.list({
        created: { gte: Number(from), lte: Number(until) },
        limit: 100,
        ...(cursor ? { starting_after: cursor } : {}),
      }, { timeout: Math.min(8_000, remaining), maxNetworkRetries: 0 });
      if (!Array.isArray(result.data) || typeof result.has_more !== "boolean") {
        throw new Error("Invalid provider listing.");
      }
      for (const payment of result.data) {
        if (payment.metadata?.field_payment_intent_id === intent.id) {
          evidence.set(payment.id, recoveryEvidence(payment));
        }
      }
      pages++;
      if (!result.has_more) {
        complete = true;
        cursor = null;
        break;
      }
      const lastId = result.data.at(-1)?.id;
      if (!lastId || lastId === cursor) {
        throw new Error("Provider pagination did not advance.");
      }
      cursor = lastId;
    }
  } catch {
    unavailable = true;
  }
  const candidates = [...evidence.values()];
  let outcome = unavailable
    ? "PROVIDER_UNAVAILABLE"
    : !complete
    ? "INCOMPLETE"
    : candidates.length === 0
    ? "NO_MATCH"
    : candidates.length > 1
    ? "MULTIPLE_MATCHES"
    : "RECOVERED";
  if (outcome === "RECOVERED") {
    try {
      verifyStripePayment(
        candidates[0] as unknown as Stripe.PaymentIntent,
        intent,
        ctx.livemode,
      );
    } catch {
      outcome = "MISMATCH";
    }
  }
  const saved = await ctx.admin.rpc("complete_stripe_checkout_recovery", {
    intent_id_to_use: intent.id,
    claim_id_to_use: claimId,
    outcome_to_use: outcome,
    evidence_to_use: candidates,
    scan_complete_to_use: complete,
    scan_cursor_to_use: cursor,
    pages_scanned_to_use: pages,
  });
  if (saved.error) throw saved.error; // Lost ACK remains ambiguous and retryable.
  const savedState = object(saved.data);
  const providerId = text(savedState?.provider_intent_id);
  if (!providerId) throw new CheckoutRecoveryRequired(reference);
  // Re-read the authoritative current state. A capture may have raced listing;
  // never interpret a stale requires_payment_method snapshot as safe to cancel.
  const payment = await ctx.stripe.paymentIntents.retrieve(providerId, {
    expand: ["latest_charge"],
  });
  verifyStripePayment(payment, intent, ctx.livemode);
  intent.provider_intent_id = providerId;
  return payment;
}
