import Stripe from "npm:stripe@23.0.0";
import { createClient } from "npm:@supabase/supabase-js@2.86.0";
import { isExactFieldStagingSupabaseUrl } from "./staging_guard.ts";

export { Stripe };
export const stripeApiVersion = "2026-09-30.endive" as const;
export type PaymentDatabase = ReturnType<
  // deno-lint-ignore no-explicit-any
  typeof createClient<any, "public", any>
>;
export type PaymentPurpose = "SOLO_BOOKING" | "CLAN_CREATE" | "CLAN_JOIN";
export type PaymentIntent = {
  id: string;
  profile_id: string;
  provider: "STRIPE" | "LEGACY" | "STAGING_E2E";
  purpose: PaymentPurpose;
  status: string;
  currency: string;
  amount_fils: number;
  amount_minor: number;
  payload: Record<string, unknown>;
  quote_snapshot: Record<string, unknown>;
  transaction_reference: string;
  provider_intent_id: string | null;
  provider_payment_id: string | null;
  payment_method: string | null;
  resource_type: string | null;
  resource_id: string | null;
  expires_at: string;
  created_at: string;
  external_refund_review_required?: boolean;
};

export class PaymentError extends Error {
  constructor(message: string, readonly status = 409) {
    super(message);
  }
}

export function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

export function uuid(value: unknown, message = "Payment attempt is invalid.") {
  const normalized = text(value);
  if (
    !normalized ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(normalized)
  ) {
    throw new PaymentError(message, 400);
  }
  return normalized.toLowerCase();
}

// Existing quote columns named *_fils are thousandths. New checkouts are USD
// only; Stripe expects cents. Never relabel or round a historical quote.
export function stripeAmountMinor(amount: unknown, currency: unknown): number {
  if (
    typeof amount !== "number" || !Number.isSafeInteger(amount) || amount <= 0
  ) {
    throw new PaymentError("The checkout total is invalid.");
  }
  const normalized = text(currency)?.toUpperCase();
  if (normalized !== "USD") {
    throw new PaymentError(
      "This game uses a retired currency. Choose a USD game or contact support.",
    );
  }
  if (amount % 10 !== 0) {
    throw new PaymentError(
      "The checkout total has invalid currency precision.",
    );
  }
  const minor = amount / 10;
  if (minor > 99_999_999) {
    throw new PaymentError("The checkout total is too large.");
  }
  return minor;
}

export function normalizedCheckout(body: Record<string, unknown>): {
  purpose: PaymentPurpose;
  payload: Record<string, unknown>;
} {
  const purpose = text(body.purpose)?.toUpperCase();
  const payload = object(body.payload);
  if (!payload) throw new PaymentError("Payment details are missing.", 400);
  if (purpose === "SOLO_BOOKING") {
    const role = text(payload.role)?.toUpperCase();
    if (!role || !["GK", "DEF", "MID", "ATT"].includes(role)) {
      throw new PaymentError("Choose a valid position.", 400);
    }
    return { purpose, payload: { game_id: uuid(payload.game_id), role } };
  }
  if (purpose === "CLAN_CREATE") {
    const date = text(payload.match_date);
    const time = text(payload.time_slot);
    const venue = text(payload.venue);
    if (
      !date || !/^\d{4}-\d{2}-\d{2}$/.test(date) || !time || time.length > 80
    ) {
      throw new PaymentError("Choose a valid match date and time.", 400);
    }
    if (!venue || venue.length < 2 || venue.length > 60) {
      throw new PaymentError("Choose a valid venue.", 400);
    }
    return {
      purpose,
      payload: {
        clan_id: uuid(payload.clan_id),
        match_date: date,
        time_slot: time,
        venue,
      },
    };
  }
  if (purpose === "CLAN_JOIN") {
    return {
      purpose,
      payload: {
        fixture_id: uuid(payload.fixture_id),
        clan_id: uuid(payload.clan_id),
      },
    };
  }
  throw new PaymentError("Choose a valid payment purpose.", 400);
}

export function checkoutIdentityKeys(purpose: PaymentPurpose) {
  if (purpose === "SOLO_BOOKING") return ["game_id"];
  if (purpose === "CLAN_CREATE") return ["clan_id", "match_date", "time_slot"];
  return ["fixture_id", "clan_id"];
}

export function canonicalJson(value: unknown): string {
  function canonical(item: unknown): unknown {
    if (Array.isArray(item)) return item.map(canonical);
    const source = object(item);
    return source
      ? Object.fromEntries(
        Object.keys(source).filter((key) => key !== "server_now").sort().map((
          key,
        ) => [key, canonical(source[key])]),
      )
      : item;
  }
  return JSON.stringify(canonical(value));
}

export function deadlineFetch(deadlineMs: number): typeof fetch {
  return (input, init) => {
    const remaining = deadlineMs - Date.now();
    if (remaining <= 0) {
      return Promise.reject(
        new DOMException("Worker time budget expired.", "AbortError"),
      );
    }
    const timeout = AbortSignal.timeout(Math.min(15_000, remaining));
    const inherited = init?.signal ??
      (input instanceof Request ? input.signal : null);
    return fetch(input, {
      ...init,
      signal: inherited ? AbortSignal.any([inherited, timeout]) : timeout,
    });
  };
}

export function stripeClient(secret: string, deadlineMs?: number) {
  return new Stripe(secret, {
    apiVersion: stripeApiVersion,
    httpClient: Stripe.createFetchHttpClient(
      deadlineMs ? deadlineFetch(deadlineMs) : undefined,
    ),
    timeout: 15_000,
    // The scheduled worker retries durably, not beyond its invocation budget.
    maxNetworkRetries: deadlineMs ? 0 : 1,
  });
}

export function expectedLiveMode(
  secret: string,
  environment: string | undefined,
): boolean {
  const test = /^(sk|rk)_test_/.test(secret);
  const live = /^(sk|rk)_live_/.test(secret);
  if (environment === "production" && live) return true;
  if (["staging", "local"].includes(environment ?? "") && test) return false;
  throw new PaymentError(
    "Payment configuration does not match this environment.",
    503,
  );
}

export function assertStagingE2EActor(input: {
  url: string;
  environment: string | undefined;
  dev: string | undefined;
  livemode: boolean;
  runId: string;
  appMetadata: Record<string, unknown> | undefined;
}) {
  if (
    !isExactFieldStagingSupabaseUrl(input.url) ||
    input.environment !== "staging" || input.dev !== "true" || input.livemode
  ) {
    throw new PaymentError("Staging test checkout is unavailable.", 404);
  }
  if (
    input.appMetadata?.fieldrush_e2e !== true ||
    input.appMetadata?.fieldrush_e2e_run_id !== input.runId ||
    !["player", "onboarding", "admin"].includes(
      String(input.appMetadata?.fieldrush_e2e_role),
    )
  ) {
    throw new PaymentError(
      "Staging test checkout is unavailable for this account and run.",
      403,
    );
  }
}

export function stripeMetadata(intent: PaymentIntent) {
  return {
    field_payment_intent_id: intent.id,
    field_profile_id: intent.profile_id,
    field_purpose: intent.purpose,
    field_transaction_reference: intent.transaction_reference,
  };
}

export function assertStagingE2EGame(input: {
  runId: string;
  venue: unknown;
  creatorMetadata: Record<string, unknown> | undefined;
}) {
  if (
    !String(input.venue ?? "").startsWith(
      `[FIELD E2E ${input.runId.slice(0, 28)}] `,
    ) ||
    input.creatorMetadata?.fieldrush_e2e !== true ||
    input.creatorMetadata?.fieldrush_e2e_role !== "admin" ||
    input.creatorMetadata?.fieldrush_e2e_run_id !== input.runId
  ) {
    throw new PaymentError(
      "Staging checkout is restricted to this run's fixtures.",
      403,
    );
  }
}

export function verifyStripePayment(
  payment: Stripe.PaymentIntent,
  intent: PaymentIntent,
  livemode: boolean,
) {
  if (intent.provider !== "STRIPE" || payment.object !== "payment_intent") {
    throw new PaymentError("The payment provider does not match.");
  }
  if (intent.provider_intent_id && intent.provider_intent_id !== payment.id) {
    throw new PaymentError("The payment reference does not match.");
  }
  if (payment.livemode !== livemode) {
    throw new PaymentError("The payment environment does not match.");
  }
  if (payment.currency.toUpperCase() !== intent.currency.toUpperCase()) {
    throw new PaymentError("The payment currency does not match.");
  }
  const amount = stripeAmountMinor(intent.amount_fils, intent.currency);
  if (
    payment.amount !== amount ||
    (payment.status === "succeeded" && payment.amount_received !== amount)
  ) {
    throw new PaymentError("The payment amount does not match.");
  }
  for (const [key, value] of Object.entries(stripeMetadata(intent))) {
    if (payment.metadata[key] !== value) {
      throw new PaymentError("The payment details do not match.");
    }
  }
  if (
    payment.capture_method !== "automatic" ||
    payment.payment_method_types.some((method) => method !== "card")
  ) {
    throw new PaymentError("The payment configuration does not match.");
  }
}

export function paymentMethod(payment: Stripe.PaymentIntent) {
  const charge = typeof payment.latest_charge === "object"
    ? payment.latest_charge
    : null;
  const card = charge?.payment_method_details?.card;
  if (card?.wallet?.type === "apple_pay") return "APPLE_PAY";
  if (card?.brand === "visa") return "VISA";
  if (card?.brand === "mastercard") return "MASTERCARD";
  return "CARD";
}

export async function loadIntent(
  admin: PaymentDatabase,
  id: string,
  userId?: string,
): Promise<PaymentIntent> {
  let query = admin.from("payment_intents").select("*").eq("id", id);
  if (userId) query = query.eq("profile_id", userId);
  const { data, error } = await query.maybeSingle();
  if (error) throw error;
  if (!data) throw new PaymentError("Payment attempt not found.", 404);
  return data as PaymentIntent;
}

export function intentResponse(intent: PaymentIntent): Record<string, unknown> {
  return {
    status: intent.status,
    intent_id: intent.id,
    stripe_payment_intent_id: intent.provider_intent_id,
    charge_id: intent.provider_payment_id,
    payment_method: intent.payment_method,
    resource_type: intent.resource_type,
    resource_id: intent.resource_id,
  };
}

export async function reconcilePayment(
  admin: PaymentDatabase,
  stripe: Stripe,
  intent: PaymentIntent,
  livemode: boolean,
  payment?: Stripe.PaymentIntent,
): Promise<Record<string, unknown>> {
  if (intent.provider !== "STRIPE" || !intent.provider_intent_id) {
    throw new PaymentError("Payment is still being prepared. Try again.");
  }
  const latest = payment ??
    await stripe.paymentIntents.retrieve(intent.provider_intent_id, {
      expand: ["latest_charge"],
    });
  verifyStripePayment(latest, intent, livemode);
  if (latest.status === "succeeded") {
    const charge = typeof latest.latest_charge === "string"
      ? latest.latest_charge
      : latest.latest_charge?.id;
    if (!charge) {
      throw new PaymentError(
        "Payment is still being confirmed. Try again.",
        503,
      );
    }
    const { data, error } = await admin.rpc("record_stripe_payment_capture", {
      intent_id_to_capture: intent.id,
      provider_intent_id_to_use: latest.id,
      provider_payment_id_to_use: charge,
      amount_minor_to_use: latest.amount_received,
      currency_to_use: latest.currency.toUpperCase(),
      payment_method_to_use: paymentMethod(latest),
    });
    if (error) throw error;
    const result = object(data);
    if (!result) throw new Error("Invalid payment finalization response.");
    return { ...result, stripe_payment_intent_id: latest.id };
  }
  const updates: Record<string, unknown> = { provider_status: latest.status };
  if (latest.status === "canceled") updates.status = "CANCELLED";
  const { error } = await admin.from("payment_intents").update(updates).eq(
    "id",
    intent.id,
  ).eq("status", "PENDING");
  if (error) throw error;
  if (latest.status === "canceled") {
    return { ...intentResponse(intent), status: "CANCELLED" };
  }
  if (["processing", "requires_capture"].includes(latest.status)) {
    return { ...intentResponse(intent), status: "PROCESSING" };
  }
  return {
    ...intentResponse(intent),
    status: "PENDING",
    provider_status: latest.status,
  };
}

type Refund = {
  id: string;
  intent_id: string;
  provider_intent_id: string;
  amount_minor: number;
  currency: string;
  provider_refund_id: string | null;
  retry_generation: number;
};

// Money returned in the provider dashboard is real money, even when no app
// cancellation happened. Import it for admin review instead of cancelling a
// valid booking or accidentally issuing the same refund a second time.
export async function inspectProviderRefunds(
  admin: PaymentDatabase,
  stripe: Stripe,
  intent: PaymentIntent,
  deadlineMs = Number.POSITIVE_INFINITY,
) {
  if (!intent.provider_intent_id) {
    throw new PaymentError("Payment reference is missing.");
  }
  const { data, error } = await admin.from("payment_refunds")
    .select("id,provider_refund_id,retry_generation,amount_minor,currency")
    .eq("intent_id", intent.id);
  if (error) throw error;
  const known = (data ?? []) as Pick<
    Refund,
    | "id"
    | "provider_refund_id"
    | "retry_generation"
    | "amount_minor"
    | "currency"
  >[];
  const refunds: Stripe.Refund[] = [];
  let reviewRequired = intent.external_refund_review_required === true;
  for await (
    const refund of stripe.refunds.list({
      payment_intent: intent.provider_intent_id,
      limit: 100,
    })
  ) {
    if (Date.now() >= deadlineMs) {
      throw new DOMException("Worker time budget expired.", "AbortError");
    }
    const paymentId = typeof refund.payment_intent === "string"
      ? refund.payment_intent
      : refund.payment_intent?.id;
    if (
      paymentId !== intent.provider_intent_id ||
      refund.currency.toUpperCase() !== intent.currency.toUpperCase() ||
      !Number.isSafeInteger(refund.amount) || refund.amount <= 0 ||
      refund.amount > intent.amount_minor
    ) {
      throw new PaymentError("Provider refund does not match its payment.");
    }
    refunds.push(refund);
    const owned = known.some((row) =>
      row.amount_minor === refund.amount &&
      row.currency.toUpperCase() === refund.currency.toUpperCase() &&
      (row.provider_refund_id === refund.id || (
        !row.provider_refund_id &&
        refund.metadata?.field_refund_id === row.id &&
        refund.metadata?.field_payment_intent_id === intent.id &&
        (refund.metadata?.field_refund_attempt ===
            String(row.retry_generation) ||
          (["failed", "canceled"].includes(refund.status ?? "") &&
            /^\d+$/.test(refund.metadata?.field_refund_attempt ?? "") &&
            Number(refund.metadata?.field_refund_attempt) <
              row.retry_generation))
      ))
    );
    if (owned) continue;
    const { data: recorded, error: recordError } = await admin.rpc(
      "record_external_stripe_refund",
      {
        intent_id_to_use: intent.id,
        provider_refund_id_to_use: refund.id,
        amount_minor_to_use: refund.amount,
        currency_to_use: refund.currency.toUpperCase(),
        provider_status_to_use: refund.status ?? "pending",
      },
    );
    if (recordError) throw recordError;
    if (
      object(recorded)?.external_refund_review_required === true ||
      !["failed", "canceled"].includes(refund.status ?? "pending")
    ) reviewRequired = true;
  }
  return { refunds, reviewRequired };
}

export function verifyStripeRefund(
  refund: Stripe.Refund,
  expected: Refund,
  livemode: boolean,
) {
  const paymentId = typeof refund.payment_intent === "string"
    ? refund.payment_intent
    : refund.payment_intent?.id;
  // Refund objects do not expose livemode. The referenced PaymentIntent is
  // retrieved and checked by the worker before a refund is created or read.
  void livemode;
  if (
    paymentId !== expected.provider_intent_id ||
    refund.amount !== expected.amount_minor ||
    refund.currency.toUpperCase() !== expected.currency.toUpperCase()
  ) {
    throw new PaymentError("Refund details do not match.");
  }
  if (
    expected.provider_refund_id && expected.provider_refund_id !== refund.id
  ) throw new PaymentError("Refund reference does not match.");
  if (
    refund.metadata?.field_refund_id !== expected.id ||
    refund.metadata?.field_payment_intent_id !== expected.intent_id ||
    refund.metadata?.field_refund_attempt !== String(expected.retry_generation)
  ) {
    throw new PaymentError("Refund metadata does not match.");
  }
}

export async function processRefunds(
  admin: PaymentDatabase,
  stripe: Stripe,
  livemode: boolean,
  batchSize = 10,
  intentId: string | null = null,
  deadlineMs = Number.POSITIVE_INFINITY,
) {
  if (Date.now() >= deadlineMs) {
    return { checked: 0, completed: 0, pending: 0 };
  }
  const { data, error } = await admin.rpc("claim_payment_refunds", {
    batch_size: batchSize,
    intent_id_to_claim: intentId,
  });
  if (error) throw error;
  const refunds = (Array.isArray(data) ? data : []) as Refund[];
  let completed = 0;
  let pending = 0;
  let checked = 0;
  async function processOne(row: Refund) {
    try {
      const intent = await loadIntent(admin, row.intent_id);
      const payment = await stripe.paymentIntents.retrieve(
        row.provider_intent_id,
      );
      verifyStripePayment(payment, intent, livemode);
      if (payment.status !== "succeeded") {
        throw new PaymentError(
          "A captured payment is required for this refund.",
        );
      }
      const inspected = await inspectProviderRefunds(
        admin,
        stripe,
        intent,
        deadlineMs,
      );
      // Recover a response lost after Stripe accepted the refund, including
      // retries beyond Stripe's idempotency retention window.
      let recovered: Stripe.Refund | null = null;
      if (!row.provider_refund_id) {
        for (const candidate of inspected.refunds) {
          if (
            candidate.metadata?.field_refund_id === row.id &&
            candidate.metadata?.field_refund_attempt ===
              String(row.retry_generation)
          ) {
            recovered = candidate;
            break;
          }
        }
      }
      if (!row.provider_refund_id && !recovered && inspected.reviewRequired) {
        // The import RPC durably flags this intent and its unissued refunds.
        // Already-issued refunds still reconcile; no new money is returned.
        pending++;
        return;
      }
      const refund = row.provider_refund_id
        ? await stripe.refunds.retrieve(row.provider_refund_id)
        : recovered ?? await stripe.refunds.create({
          payment_intent: row.provider_intent_id,
          amount: row.amount_minor,
          reason: "requested_by_customer",
          metadata: {
            field_refund_id: row.id,
            field_payment_intent_id: row.intent_id,
            field_refund_attempt: String(row.retry_generation),
          },
        }, {
          idempotencyKey: `fieldrush-refund-${row.id}-${row.retry_generation}`,
        });
      verifyStripeRefund(refund, row, livemode);
      const { data: finished, error: finishError } = await admin.rpc(
        "finish_payment_refund",
        {
          refund_id_to_finish: row.id,
          provider_refund_id_to_use: refund.id,
          provider_status_to_use: refund.status ?? "pending",
          amount_minor_to_use: refund.amount,
          currency_to_use: refund.currency.toUpperCase(),
          failure_reason_to_use: refund.failure_reason ?? null,
          retry_generation_to_use: row.retry_generation,
        },
      );
      if (finishError) throw finishError;
      if (object(finished)?.stale === true) {
        pending++;
        return;
      }
      if (refund.status === "succeeded") completed++;
      else pending++;
    } catch (error) {
      // Never log provider error bodies, card data, credentials or client secrets.
      console.error("Stripe refund processing failed", {
        refundId: row.id,
        category: errorCategory(error),
      });
      const { error: finishError } = await admin.rpc("finish_payment_refund", {
        refund_id_to_finish: row.id,
        provider_refund_id_to_use: row.provider_refund_id,
        provider_status_to_use: "transport_error",
        amount_minor_to_use: row.amount_minor,
        currency_to_use: row.currency,
        failure_reason_to_use:
          "The payment provider could not confirm this refund. Retry is scheduled.",
        retry_generation_to_use: row.retry_generation,
      });
      if (finishError) throw finishError;
      pending++;
    }
  }
  // No more than three Stripe operations in flight. Stop taking new rows at
  // the deadline; untouched leases expire and remain eligible for retry.
  let next = 0;
  const workers = Array.from(
    { length: Math.min(3, refunds.length) },
    async () => {
      while (next < refunds.length && Date.now() < deadlineMs) {
        const row = refunds[next++];
        checked++;
        await processOne(row);
      }
    },
  );
  const results = await Promise.allSettled(workers);
  const failure = results.find((result) => result.status === "rejected");
  if (failure?.status === "rejected") throw failure.reason;
  return { checked, completed, pending };
}

export function errorCategory(error: unknown) {
  if (error instanceof PaymentError) return "payment_validation";
  if (error instanceof Stripe.errors.StripeError) return error.type;
  return "internal_error";
}

export async function verifyWebhook(
  stripe: Stripe,
  rawBody: string,
  signature: string,
  secret: string,
  nowSeconds = Math.floor(Date.now() / 1000),
) {
  const timestamps = signature.split(",").filter((part) =>
    part.startsWith("t=")
  );
  const timestamp = Number(timestamps[0]?.slice(2));
  if (
    timestamps.length !== 1 || !Number.isInteger(timestamp) ||
    Math.abs(nowSeconds - timestamp) > 300
  ) {
    throw new PaymentError("Invalid webhook timestamp.", 400);
  }
  return await stripe.webhooks.constructEventAsync(
    rawBody,
    signature,
    secret,
    300,
    Stripe.createSubtleCryptoProvider(),
    nowSeconds * 1000,
  );
}
