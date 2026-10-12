import { createClient } from "npm:@supabase/supabase-js@2.86.0";
import { isExactFieldStagingSupabaseUrl } from "./staging_guard.ts";
import {
  assertStagingE2EActor,
  assertStagingE2EGame,
  canonicalJson,
  checkoutIdentityKeys,
  deadlineFetch,
  errorCategory,
  expectedLiveMode,
  inspectProviderRefunds,
  intentResponse,
  loadIntent,
  normalizedCheckout,
  object,
  PaymentDatabase,
  PaymentError,
  PaymentIntent,
  PaymentPurpose,
  processRefunds,
  reconcilePayment,
  Stripe,
  stripeAmountMinor,
  stripeClient,
  stripeMetadata,
  text,
  uuid,
  verifyStripePayment,
  verifyWebhook,
} from "./stripe_checkout.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Runtime = {
  admin: PaymentDatabase;
  stripe: Stripe;
  livemode: boolean;
  url: string;
  anonKey: string;
  deadlineMs?: number;
};
type Context = Runtime & {
  user: PaymentDatabase;
  userId: string;
  authUser: { app_metadata?: Record<string, unknown> };
};

function runtime(deadlineMs?: number): Runtime {
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const adminKey = Deno.env.get("FIELD_SUPABASE_SECRET_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const secret = Deno.env.get("STRIPE_SECRET_KEY");
  if (!url || !anonKey || !adminKey || !secret) {
    throw new PaymentError(
      "Payments are not configured for this environment.",
      503,
    );
  }
  const livemode = expectedLiveMode(secret, Deno.env.get("FIELD_ENVIRONMENT"));
  if (
    Deno.env.get("FIELD_ENVIRONMENT") === "staging" &&
    !isExactFieldStagingSupabaseUrl(url)
  ) throw new PaymentError("Staging payment project does not match.", 503);
  return {
    admin: createClient(url, adminKey, {
      auth: { autoRefreshToken: false, persistSession: false },
      ...(deadlineMs ? { global: { fetch: deadlineFetch(deadlineMs) } } : {}),
    }),
    stripe: stripeClient(secret, deadlineMs),
    livemode,
    url,
    anonKey,
    deadlineMs,
  };
}

async function context(request: Request): Promise<Context> {
  const token = /^Bearer\s+(.+)$/i.exec(
    request.headers.get("Authorization") ?? "",
  )?.[1]?.trim();
  if (!token) throw new PaymentError("Sign in to continue.", 401);
  const services = runtime();
  const { data, error } = await services.admin.auth.getUser(token);
  if (error || !data.user) {
    throw new PaymentError("Your session has expired. Sign in again.", 401);
  }
  return {
    ...services,
    userId: data.user.id,
    authUser: data.user,
    user: createClient(services.url, services.anonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    }),
  };
}

export async function handlePayment(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }
  try {
    const ctx = await context(request);
    const body = object(await request.json().catch(() => null));
    if (!body) throw new PaymentError("Invalid request body.", 400);
    switch (text(body.action)?.toLowerCase()) {
      case "prepare":
        return json(await prepareCheckout(ctx, body));
      case "confirm":
        return json(await confirmCheckout(ctx, uuid(body.intent_id)));
      case "cancel":
        return json(await cancelCheckout(ctx, uuid(body.intent_id)));
      case "complete_staging_e2e":
        return json(await stagingE2ECheckout(ctx, body));
      default:
        throw new PaymentError("Choose a valid payment action.", 400);
    }
  } catch (error) {
    if (error instanceof PaymentError) {
      return json({ error: error.message }, error.status);
    }
    console.error("Stripe checkout failed", { category: errorCategory(error) });
    return json({
      error:
        "Payment could not be confirmed. Check your booking before trying again.",
    }, 503);
  }
}

async function quote(
  user: PaymentDatabase,
  purpose: PaymentPurpose,
  payload: Record<string, unknown>,
) {
  const response = purpose === "SOLO_BOOKING"
    ? await user.rpc("preview_open_queue_booking_cost", {
      game_id_to_book: payload.game_id,
      role_to_book: payload.role,
    })
    : purpose === "CLAN_CREATE"
    ? await user.rpc("preview_create_clan_fixture_charge", {
      clan_id_to_use: payload.clan_id,
      match_date_to_use: payload.match_date,
      time_slot_to_use: payload.time_slot,
    })
    : await user.rpc("preview_join_clan_fixture_charge", {
      fixture_id_to_use: payload.fixture_id,
      clan_id_to_use: payload.clan_id,
    });
  if (response.error) throw new PaymentError(response.error.message);
  const data = object(response.data);
  if (!data) throw new PaymentError("The checkout total is unavailable.");
  if (text(data.currency)?.toUpperCase() !== "USD") {
    throw new PaymentError(
      "This game uses a retired currency. Choose a USD game or contact support.",
    );
  }
  if (data.total_fils !== 0) stripeAmountMinor(data.total_fils, data.currency);
  return data;
}

async function matchingIntent(
  ctx: Context,
  purpose: PaymentPurpose,
  payload: Record<string, unknown>,
  statuses: string[],
) {
  let query = ctx.admin.from("payment_intents").select("*").eq(
    "profile_id",
    ctx.userId,
  ).eq("provider", "STRIPE").eq("purpose", purpose).in("status", statuses);
  for (const key of checkoutIdentityKeys(purpose)) {
    query = query.eq(`payload->>${key}`, String(payload[key]));
  }
  const { data, error } = await query.order("created_at", { ascending: false })
    .limit(1).maybeSingle();
  if (error) throw error;
  return data as PaymentIntent | null;
}

async function ensureStripeIntent(
  ctx: Runtime,
  intent: PaymentIntent,
): Promise<Stripe.PaymentIntent> {
  if (intent.provider_intent_id) {
    const payment = await ctx.stripe.paymentIntents.retrieve(
      intent.provider_intent_id,
      { expand: ["latest_charge"] },
    );
    verifyStripePayment(payment, intent, ctx.livemode);
    return payment;
  }
  // Stripe may prune idempotency keys after 24 hours. An unresolved create
  // older than this must be investigated, never blindly recreated.
  if (Date.now() - Date.parse(intent.created_at) > 23 * 60 * 60 * 1000) {
    throw new PaymentError(
      "An earlier payment attempt needs review. Please contact support.",
    );
  }
  const payment = await ctx.stripe.paymentIntents.create({
    amount: stripeAmountMinor(intent.amount_fils, intent.currency),
    currency: intent.currency.toLowerCase(),
    allowed_payment_method_types: ["card"],
    capture_method: "automatic",
    confirmation_method: "automatic",
    description: intent.purpose === "SOLO_BOOKING"
      ? "Fieldrush solo match reservation"
      : "Fieldrush clan match reservation",
    metadata: stripeMetadata(intent),
  }, { idempotencyKey: `fieldrush-payment-${intent.id}` });
  verifyStripePayment(payment, intent, ctx.livemode);
  const { error } = await ctx.admin.from("payment_intents").update({
    provider_intent_id: payment.id,
    provider_status: payment.status,
  }).eq("id", intent.id).is("provider_intent_id", null);
  if (error) throw error;
  intent.provider_intent_id = payment.id;
  return payment;
}

export async function prepareCheckout(
  ctx: Context,
  body: Record<string, unknown>,
  attempt = 0,
): Promise<Record<string, unknown>> {
  if (attempt > 2) {
    throw new PaymentError(
      "The checkout changed while it was being prepared. Try again.",
    );
  }
  const { purpose, payload } = normalizedCheckout(body);
  // Reconcile any money already captured before asking for another payment.
  const paid = await matchingIntent(ctx, purpose, payload, [
    "CAPTURED",
    "REQUIRES_REFUND",
  ]);
  if (paid) return await confirmCheckout(ctx, paid.id);
  const finalized = await matchingIntent(ctx, purpose, payload, ["FINALIZED"]);
  if (finalized?.resource_id) {
    if (finalized.resource_type === "OPEN_QUEUE_BOOKING") {
      const { data, error } = await ctx.admin.from("open_queue_bookings")
        .select("status").eq("id", finalized.resource_id).eq(
          "profile_id",
          ctx.userId,
        ).maybeSingle();
      if (error) throw error;
      if (data?.status === "CONFIRMED") return intentResponse(finalized);
    } else if (finalized.resource_type === "FIXTURE") {
      const { data, error } = await ctx.admin.from("fixtures")
        .select("status,home_clan_id,away_clan_id").eq(
          "id",
          finalized.resource_id,
        ).maybeSingle();
      if (error) throw error;
      const side = purpose === "CLAN_CREATE"
        ? data?.home_clan_id
        : data?.away_clan_id;
      if (data && data.status !== "CANCELLED" && side === payload.clan_id) {
        return intentResponse(finalized);
      }
    }
  }

  // Free bookings have no payment-intent row. Recover a committed booking
  // before requesting a quote, which otherwise correctly rejects duplicates.
  if (purpose === "SOLO_BOOKING") {
    const { data: freeBooking, error } = await ctx.admin.from(
      "open_queue_bookings",
    )
      .select("id")
      .eq("profile_id", ctx.userId)
      .eq("game_id", payload.game_id)
      .eq("role", payload.role)
      .eq("status", "CONFIRMED")
      .eq("payment_method", "FREE")
      .maybeSingle();
    if (error) throw error;
    if (freeBooking) {
      return {
        status: "FINALIZED",
        intent_id: null,
        payment_method: "FREE",
        resource_type: "OPEN_QUEUE_BOOKING",
        resource_id: freeBooking.id,
      };
    }
  }

  let intent = await matchingIntent(ctx, purpose, payload, ["PENDING"]);
  let existingPayment: Stripe.PaymentIntent | undefined;
  if (intent?.provider_intent_id) {
    existingPayment = await ensureStripeIntent(ctx, intent);
    // The provider can succeed before the webhook updates our local row. Do
    // this before a fresh quote: a now-full/closed game must not hide a charge
    // behind an ordinary availability error when the player reconnects.
    if (
      ["succeeded", "processing", "requires_capture"].includes(
        existingPayment.status,
      )
    ) {
      return await reconcileAndRefund(ctx, intent, existingPayment);
    }
  }
  const authoritativeQuote = await quote(ctx.user, purpose, payload);
  // Still recheck current availability above, but an unexpired server-owned
  // solo checkout keeps its agreed price/deposit. Admin repricing must not
  // silently change an already-open PaymentSheet or cancel its Stripe intent.
  const checkoutQuote = intent && canReuseSoloCheckoutQuote(
      intent,
      purpose,
      payload,
      authoritativeQuote,
    )
    ? intent.quote_snapshot
    : authoritativeQuote;
  const amount = checkoutQuote.total_fils as number;
  const currency = String(checkoutQuote.currency).toUpperCase();
  if (amount === 0) {
    if (intent) {
      const canceled = await cancelAtProvider(ctx, intent);
      const reconciled = await reconcileAndRefund(ctx, intent, canceled);
      if (reconciled.status !== "CANCELLED") return reconciled;
    }
    // The database recomputes the zero quote under its own transaction before
    // reserving the place. No synthetic provider capture is created.
    const { data, error } = await ctx.admin.rpc("finalize_free_checkout", {
      profile_id_to_use: ctx.userId,
      purpose_to_use: purpose,
      payload_to_use: payload,
    });
    if (error) throw new PaymentError(error.message);
    return object(data) ?? {};
  }
  if (currency === "USD" && amount < 500) {
    throw new PaymentError(
      "The card checkout minimum is $0.50. Please contact support for this game.",
    );
  }
  if (!intent) {
    const id = crypto.randomUUID();
    const { data, error } = await ctx.admin.from("payment_intents").insert({
      id,
      profile_id: ctx.userId,
      provider: "STRIPE",
      purpose,
      currency,
      amount_fils: amount,
      payload,
      quote_snapshot: authoritativeQuote,
      transaction_reference: `fieldrush_${id.replaceAll("-", "")}`,
    }).select("*").single();
    if (error) {
      if (error.code === "23505") {
        return prepareCheckout(ctx, body, attempt + 1);
      }
      throw error;
    }
    intent = data as PaymentIntent;
  }
  const payment = existingPayment ?? await ensureStripeIntent(ctx, intent);
  if (
    ["succeeded", "processing", "requires_capture"].includes(payment.status)
  ) {
    return await reconcileAndRefund(ctx, intent, payment);
  }
  const changed = intent.amount_fils !== amount ||
    intent.currency !== currency ||
    canonicalJson(intent.payload) !== canonicalJson(payload) ||
    canonicalJson(intent.quote_snapshot) !==
      canonicalJson(checkoutQuote) ||
    Date.parse(intent.expires_at) <= Date.now();
  if (changed || payment.status === "canceled") {
    const canceled = payment.status === "canceled"
      ? payment
      : await cancelAtProvider(ctx, intent);
    if (canceled.status !== "canceled") {
      return reconcileAndRefund(ctx, intent, canceled);
    }
    const { error } = await ctx.admin.from("payment_intents").update({
      status: "EXPIRED",
      provider_status: "canceled",
    }).eq("id", intent.id).eq("status", "PENDING");
    if (error) throw error;
    return prepareCheckout(ctx, body, attempt + 1);
  }
  if (!payment.client_secret) {
    throw new PaymentError("Checkout could not be prepared. Try again.", 503);
  }
  return {
    status: "PENDING",
    intent_id: intent.id,
    stripe_payment_intent_id: payment.id,
    client_secret: payment.client_secret,
    amount_fils: amount,
    currency,
    expires_at: intent.expires_at,
  };
}

export function canReuseSoloCheckoutQuote(
  intent: PaymentIntent,
  purpose: PaymentPurpose,
  payload: Record<string, unknown>,
  currentQuote: Record<string, unknown>,
  now = Date.now(),
): boolean {
  if (
    purpose !== "SOLO_BOOKING" || intent.purpose !== purpose ||
    intent.provider !== "STRIPE" || intent.status !== "PENDING" ||
    intent.currency !== "USD" ||
    !Number.isFinite(Date.parse(intent.expires_at)) ||
    Date.parse(intent.expires_at) <= now ||
    canonicalJson(intent.payload) !== canonicalJson(payload)
  ) return false;
  const saved = intent.quote_snapshot;
  if (
    saved.currency !== intent.currency ||
    saved.currency !== currentQuote.currency ||
    !text(saved.policy_version_id) ||
    saved.policy_version_id !== currentQuote.policy_version_id
  ) return false;
  const amounts = [
    saved.standard_match_fee_fils,
    saved.match_fee_fils,
    saved.reliability_deposit_fils,
    saved.total_fils,
  ];
  if (
    amounts.some((amount) =>
      typeof amount !== "number" || !Number.isSafeInteger(amount) ||
      amount < 0 || amount % 10 !== 0
    ) || typeof saved.replacement_discount_bps !== "number" ||
    !Number.isInteger(saved.replacement_discount_bps) ||
    saved.replacement_discount_bps < 0 ||
    saved.replacement_discount_bps > 10000
  ) return false;
  return intent.amount_fils >= 500 &&
    saved.total_fils === intent.amount_fils &&
    Number(saved.match_fee_fils) <= Number(saved.standard_match_fee_fils) &&
    Number(saved.match_fee_fils) + Number(saved.reliability_deposit_fils) ===
      saved.total_fils;
}

async function cancelAtProvider(ctx: Runtime, intent: PaymentIntent) {
  const payment = await ensureStripeIntent(ctx, intent);
  if (["succeeded", "canceled"].includes(payment.status)) return payment;
  try {
    return await ctx.stripe.paymentIntents.cancel(payment.id, {}, {
      idempotencyKey: `fieldrush-cancel-${intent.id}`,
    });
  } catch {
    // Cancellation can race with successful payment. Retrieve the authoritative
    // outcome instead of opening a second attempt or claiming no charge.
    return await ctx.stripe.paymentIntents.retrieve(payment.id, {
      expand: ["latest_charge"],
    });
  }
}

async function confirmCheckout(ctx: Context, id: string) {
  const intent = await loadIntent(ctx.admin, id, ctx.userId);
  if (intent.provider !== "STRIPE") {
    throw new PaymentError("This payment cannot be changed by Stripe.");
  }
  if (intent.status === "FINALIZED" || intent.status === "REFUNDED") {
    return intentResponse(intent);
  }
  await ensureStripeIntent(ctx, intent);
  return await reconcileAndRefund(ctx, intent);
}

async function cancelCheckout(ctx: Context, id: string) {
  const intent = await loadIntent(ctx.admin, id, ctx.userId);
  if (intent.provider !== "STRIPE") {
    throw new PaymentError("This payment cannot be changed by Stripe.");
  }
  if (["FINALIZED", "REFUNDED"].includes(intent.status)) {
    return intentResponse(intent);
  }
  const payment = await cancelAtProvider(ctx, intent);
  return await reconcileAndRefund(ctx, intent, payment);
}

async function reconcileAndRefund(
  ctx: Runtime,
  intent: PaymentIntent,
  payment?: Stripe.PaymentIntent,
) {
  const result = await reconcilePayment(
    ctx.admin,
    ctx.stripe,
    intent,
    ctx.livemode,
    payment,
  );
  if (result.status !== "REQUIRES_REFUND") return result;
  // Return the durable refund state promptly. The scheduled worker owns money
  // movement, so an unavailable booking cannot stall native checkout for minutes.
  const updated = await loadIntent(ctx.admin, intent.id);
  const { data: refunds, error } = await ctx.admin.from("payment_refunds")
    .select("status").eq("intent_id", intent.id);
  if (error) throw error;
  const statuses = (refunds ?? []).map((refund) => refund.status);
  const refundStatus = updated.status === "REFUNDED"
    ? "SUCCEEDED"
    : statuses.includes("FAILED")
    ? "FAILED"
    : statuses.includes("PROCESSING")
    ? "PROCESSING"
    : "PENDING";
  return {
    ...intentResponse(updated),
    refund_status: refundStatus,
    message: updated.status === "REFUNDED"
      ? "Your place could not be reserved. Your payment has been refunded to your original payment method."
      : refundStatus === "FAILED"
      ? "Your place could not be reserved. Your refund needs support review; you will not be charged again."
      : "Your place could not be reserved. Your refund to the original payment method is being processed.",
  };
}

async function stagingE2ECheckout(ctx: Context, body: Record<string, unknown>) {
  const runId = text(body.run_id);
  if (!runId || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(runId)) {
    throw new PaymentError("Invalid staging run.", 400);
  }
  assertStagingE2EActor({
    url: ctx.url,
    environment: Deno.env.get("FIELD_ENVIRONMENT"),
    dev: Deno.env.get("DEV"),
    livemode: ctx.livemode,
    runId,
    appMetadata: ctx.authUser.app_metadata,
  });
  const { purpose, payload } = normalizedCheckout(body);
  if (purpose !== "SOLO_BOOKING") {
    throw new PaymentError(
      "Staging checkout supports isolated solo games only.",
      400,
    );
  }
  const [profileResult, gameResult] = await Promise.all([
    ctx.admin.from("profiles").select("display_name,username").eq(
      "id",
      ctx.userId,
    ).maybeSingle(),
    ctx.admin.from("open_queue_games").select("venue,created_by").eq(
      "id",
      payload.game_id,
    )
      .maybeSingle(),
  ]);
  if (profileResult.error) throw profileResult.error;
  if (gameResult.error) throw gameResult.error;
  if (
    !String(profileResult.data?.display_name ?? "").startsWith("[E2E]") ||
    !String(profileResult.data?.username ?? "").startsWith("field_e2e_") ||
    !gameResult.data?.created_by
  ) {
    throw new PaymentError(
      "Staging checkout is restricted to this run's fixtures.",
      403,
    );
  }
  const { data: creator, error: creatorError } = await ctx.admin.auth.admin
    .getUserById(gameResult.data.created_by);
  if (creatorError) throw creatorError;
  assertStagingE2EGame({
    runId,
    venue: gameResult.data.venue,
    creatorMetadata: creator.user?.app_metadata,
  });
  const { data: existing, error: existingError } = await ctx.admin.from(
    "payment_intents",
  ).select("*").eq("profile_id", ctx.userId).eq("provider", "STAGING_E2E").eq(
    "purpose",
    purpose,
  ).eq("payload->>game_id", payload.game_id).in("status", [
    "CAPTURED",
    "FINALIZED",
  ]).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (existingError) throw existingError;
  if (existing?.status === "FINALIZED") return intentResponse(existing);
  const checkout = await quote(ctx.user, purpose, payload);
  if (checkout.total_fils === 0) {
    const { data, error } = await ctx.admin.rpc("finalize_free_checkout", {
      profile_id_to_use: ctx.userId,
      purpose_to_use: purpose,
      payload_to_use: payload,
    });
    if (error) throw error;
    return object(data) ?? {};
  }
  const id = existing?.id ?? crypto.randomUUID();
  if (!existing) {
    const { error } = await ctx.admin.from("payment_intents").insert({
      id,
      profile_id: ctx.userId,
      provider: "STAGING_E2E",
      purpose,
      status: "CAPTURED",
      currency: checkout.currency,
      amount_fils: checkout.total_fils,
      payload,
      quote_snapshot: checkout,
      transaction_reference: `field_e2e_${runId}_${id.replaceAll("-", "")}`,
      provider_intent_id: `field_e2e_intent_${id.replaceAll("-", "")}`,
      provider_payment_id: `field_e2e_${id.replaceAll("-", "")}`,
      payment_method: "CARD",
      provider_status: "SUCCEEDED",
      captured_at: new Date().toISOString(),
    });
    if (error) throw error;
  }
  const { data, error } = await ctx.admin.rpc("finalize_payment_intent", {
    intent_id_to_finalize: id,
  });
  if (error) throw error;
  return object(data) ?? {};
}

export const supportedWebhookEvents = new Set([
  "payment_intent.succeeded",
  "payment_intent.processing",
  "payment_intent.payment_failed",
  "payment_intent.canceled",
  "refund.created",
  "refund.updated",
  "refund.failed",
]);

export async function handleWebhook(request: Request): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }
  let eventId: string | null = null;
  let admin: PaymentDatabase | null = null;
  try {
    const ctx = runtime();
    admin = ctx.admin;
    const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    if (!secret) throw new PaymentError("Webhook is not configured.", 503);
    const raw = await request.text();
    if (raw.length > 1_000_000) {
      throw new PaymentError("Webhook is too large.", 413);
    }
    let event: Stripe.Event;
    try {
      event = await verifyWebhook(
        ctx.stripe,
        raw,
        request.headers.get("Stripe-Signature") ?? "",
        secret,
      );
    } catch {
      throw new PaymentError("Invalid webhook signature.", 400);
    }
    if (event.livemode !== ctx.livemode || event.account) {
      throw new PaymentError("Webhook environment does not match.", 400);
    }
    if (!supportedWebhookEvents.has(event.type)) {
      return json({ received: true, ignored: true });
    }
    const payload = event.data.object;
    const providerId = payload.object === "payment_intent"
      ? payload.id
      : payload.object === "refund"
      ? (typeof payload.payment_intent === "string"
        ? payload.payment_intent
        : payload.payment_intent?.id)
      : null;
    if (!providerId) return json({ received: true, ignored: true });
    const { data: claim, error } = await ctx.admin.rpc(
      "claim_payment_webhook",
      {
        event_id_to_claim: event.id,
        event_type_to_use: event.type,
        provider_intent_id_to_use: providerId,
      },
    );
    if (error) throw error;
    const result = object(claim);
    if (result?.claimed !== true) {
      return result?.status === "PROCESSED"
        ? json({ received: true, duplicate: true })
        : json({ error: "Webhook is being processed. Retry shortly." }, 503);
    }
    eventId = event.id;
    await processProviderEvent(ctx, providerId);
    await finishWebhook(ctx.admin, event.id, null);
    return json({ received: true });
  } catch (error) {
    if (eventId && admin) {
      await finishWebhook(
        admin,
        eventId,
        "Payment event could not be reconciled. Retry scheduled.",
      ).catch(() => {});
    }
    if (error instanceof PaymentError) {
      return json({ error: error.message }, error.status);
    }
    console.error("Stripe webhook failed", {
      eventId,
      category: errorCategory(error),
    });
    return json({ error: "Payment event could not be processed." }, 503);
  }
}

async function processProviderEvent(ctx: Runtime, providerId: string) {
  const payment = await ctx.stripe.paymentIntents.retrieve(providerId, {
    expand: ["latest_charge"],
  });
  const fieldId = text(payment.metadata.field_payment_intent_id);
  if (!fieldId) return; // Unrelated payments on the same Stripe account.
  const intent = await loadIntent(ctx.admin, uuid(fieldId));
  verifyStripePayment(payment, intent, ctx.livemode);
  if (!intent.provider_intent_id) {
    const { error } = await ctx.admin.from("payment_intents").update({
      provider_intent_id: providerId,
    }).eq("id", intent.id).is("provider_intent_id", null);
    if (error) throw error;
    intent.provider_intent_id = providerId;
  }
  await reconcileAndRefund(ctx, intent, payment);
  if (payment.status === "succeeded") {
    await inspectProviderRefunds(ctx.admin, ctx.stripe, intent, ctx.deadlineMs);
  }
}

async function finishWebhook(
  admin: PaymentDatabase,
  eventId: string,
  errorMessage: string | null,
) {
  const { error } = await admin.from("payment_webhook_events").update({
    status: errorMessage ? "FAILED" : "PROCESSED",
    last_error: errorMessage,
    processed_at: errorMessage ? null : new Date().toISOString(),
    locked_until: null,
    next_attempt_at: new Date(Date.now() + 60_000).toISOString(),
  }).eq("provider", "STRIPE").eq("event_id", eventId);
  if (error) throw error;
}

export async function handleReconcile(request: Request): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }
  try {
    const secret = Deno.env.get("STRIPE_RECONCILE_SECRET");
    if (!secret || secret.length < 32) {
      throw new PaymentError("Reconciliation is not configured.", 503);
    }
    if (
      !constantTimeEqual(
        request.headers.get("Authorization") ?? "",
        `Bearer ${secret}`,
      )
    ) throw new PaymentError("Unauthorized.", 401);
    const ctx = runtime(Date.now() + 75_000);
    // Due money owed takes priority over polling abandoned checkout attempts.
    // Small batches keep the scheduled HTTP invocation bounded on outages.
    const refunds = await processRefunds(
      ctx.admin,
      ctx.stripe,
      ctx.livemode,
      10,
      null,
      ctx.deadlineMs,
    );
    const { data: events, error: eventsError } = await ctx.admin.from(
      "payment_webhook_events",
    ).select("event_id,event_type,provider_intent_id").eq("provider", "STRIPE")
      .neq("status", "PROCESSED").lte(
        "next_attempt_at",
        new Date().toISOString(),
      ).or(`locked_until.is.null,locked_until.lte.${new Date().toISOString()}`)
      .order("updated_at").limit(3);
    if (eventsError) throw eventsError;
    let reconciled = 0;
    for (const event of events ?? []) {
      if (Date.now() >= ctx.deadlineMs!) break;
      const { data, error } = await ctx.admin.rpc("claim_payment_webhook", {
        event_id_to_claim: event.event_id,
        event_type_to_use: event.event_type,
        provider_intent_id_to_use: event.provider_intent_id,
      });
      if (error) throw error;
      if (object(data)?.claimed !== true) continue;
      try {
        await processProviderEvent(ctx, event.provider_intent_id);
        await finishWebhook(ctx.admin, event.event_id, null);
        reconciled++;
      } catch {
        await finishWebhook(
          ctx.admin,
          event.event_id,
          "Payment event could not be reconciled. Retry scheduled.",
        );
      }
    }
    // Poll local unsettled attempts as a fallback if webhook delivery is lost.
    const { data: intents, error: intentsError } = await ctx.admin.from(
      "payment_intents",
    ).select("*").eq("provider", "STRIPE").in("status", [
      "PENDING",
      "CAPTURED",
      "REQUIRES_REFUND",
    ]).order("updated_at").limit(3);
    if (intentsError) throw intentsError;
    for (const row of intents ?? []) {
      if (Date.now() >= ctx.deadlineMs!) break;
      try {
        const intent = row as PaymentIntent;
        const payment = await ensureStripeIntent(ctx, intent);
        if (
          Date.parse(intent.expires_at) <= Date.now() &&
          intent.status === "PENDING" &&
          !["succeeded", "processing"].includes(payment.status)
        ) {
          await reconcileAndRefund(
            ctx,
            intent,
            await cancelAtProvider(ctx, intent),
          );
        } else await reconcileAndRefund(ctx, intent, payment);
        reconciled++;
      } catch (error) {
        console.error("Stripe reconciliation deferred", {
          intentId: row.id,
          category: errorCategory(error),
        });
        // A permanently blocked old attempt must not starve newer attempts
        // from the next bounded reconciliation batch.
        const { error: touchError } = await ctx.admin.from("payment_intents")
          .update({ updated_at: new Date().toISOString() }).eq("id", row.id);
        if (touchError) throw touchError;
      }
    }
    return json({ reconciled, refunds });
  } catch (error) {
    if (error instanceof PaymentError) {
      return json({ error: error.message }, error.status);
    }
    console.error("Stripe reconciliation failed", {
      category: errorCategory(error),
    });
    return json({ error: "Payment reconciliation could not finish." }, 503);
  }
}

function constantTimeEqual(a: string, b: string) {
  const first = new TextEncoder().encode(a);
  const second = new TextEncoder().encode(b);
  let difference = first.length ^ second.length;
  for (let index = 0; index < Math.max(first.length, second.length); index++) {
    difference |= (first[index] ?? 0) ^ (second[index] ?? 0);
  }
  return difference === 0;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
