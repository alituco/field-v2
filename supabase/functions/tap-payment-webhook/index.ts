import { createClient } from "npm:@supabase/supabase-js@2.86.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, hashstring",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("FIELD_SUPABASE_SECRET_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const secretKey = Deno.env.get("TAP_SECRET_KEY");
  const merchantId = Deno.env.get("TAP_MERCHANT_ID");
  if (!supabaseUrl || !serviceRoleKey || !secretKey || !merchantId) {
    return json({ error: "Webhook is not configured." }, 503);
  }

  let charge: Record<string, unknown>;
  try {
    const body = await request.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      throw new Error("Invalid body.");
    }
    charge = body as Record<string, unknown>;
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }

  const postedHash = request.headers.get("hashstring")?.trim().toLowerCase();
  if (!postedHash) return json({ error: "Missing Tap signature." }, 401);
  const calculatedHash = await webhookHash(secretKey, charge);
  if (!constantTimeEqual(postedHash, calculatedHash)) {
    console.error("Rejected Tap webhook with invalid hashstring.");
    return json({ error: "Invalid Tap signature." }, 401);
  }

  const reference = object(charge.reference);
  const transactionReference = text(reference?.transaction);
  const chargeId = text(charge.id);
  const status = text(charge.status)?.toUpperCase();
  if (!transactionReference || !chargeId || !status) {
    return json({ error: "Incomplete Tap event." }, 400);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: intent, error } = await admin
    .from("tap_payment_intents")
    .select(
      "id, status, currency, amount_fils, transaction_reference, tap_charge_id",
    )
    .eq("transaction_reference", transactionReference)
    .maybeSingle();
  if (error) {
    console.error("Tap webhook intent lookup failed", error);
    return json({ error: "Webhook could not be stored." }, 500);
  }
  if (!intent) {
    // Tap retries non-2xx responses. Unknown references are acknowledged while
    // remaining visible in function logs for investigation.
    console.error("Tap webhook has no Field payment intent", {
      chargeId,
      transactionReference,
    });
    return json({ received: true, matched: false }, 200);
  }
  if (
    intent.tap_charge_id && intent.tap_charge_id !== chargeId
  ) {
    console.error("Tap webhook charge does not match the stored charge", {
      intentId: intent.id,
      storedChargeId: intent.tap_charge_id,
      chargeId,
    });
    return json({ received: true, matched: false }, 200);
  }
  const mismatch = chargeMismatch(charge, intent, merchantId);
  if (mismatch) {
    console.error("Tap webhook did not match its Field payment intent", {
      intentId: intent.id,
      chargeId,
      mismatch,
    });
    return json({ received: true, matched: false }, 200);
  }
  if (intent.status === "FINALIZED") {
    return json({ received: true, matched: true, finalized: true }, 200);
  }

  const captured = status === "CAPTURED";
  const updates: Record<string, unknown> = {
    tap_charge_id: chargeId,
    tap_status: status,
  };
  if (captured && ["PENDING", "CAPTURED"].includes(intent.status)) {
    updates.status = "CAPTURED";
    updates.tap_payment_method = normalizedPaymentMethod(charge);
    updates.captured_at = new Date().toISOString();
  } else if (intent.status === "PENDING") {
    updates.status = fieldIntentStatus(status);
    updates.failure_reason = `Tap reported ${status}.`;
  }

  const { error: updateError } = await admin
    .from("tap_payment_intents")
    .update(updates)
    .eq("id", intent.id);
  if (updateError) {
    console.error("Tap webhook intent update failed", updateError);
    return json({ error: "Webhook could not be stored." }, 500);
  }
  if (!captured) {
    return json({
      received: true,
      matched: true,
      payment_status: fieldIntentStatus(status),
    }, 200);
  }

  const { error: finalizeError } = await admin.rpc(
    "finalize_tap_payment_intent",
    { intent_id_to_finalize: intent.id },
  );
  if (finalizeError) {
    const message = finalizeError.message ||
      "Paid resource finalization failed.";
    await admin
      .from("tap_payment_intents")
      .update({
        status: "REQUIRES_REFUND",
        failure_reason: message,
      })
      .eq("id", intent.id)
      .eq("status", "CAPTURED");
    console.error("Captured Tap webhook requires reconciliation", {
      intentId: intent.id,
      chargeId,
      error: message,
    });
    // Acknowledge the authenticated webhook. Retrying the same domain-rule
    // failure cannot reserve the place and could create noisy duplicate work.
    return json({
      received: true,
      matched: true,
      requires_reconciliation: true,
    }, 200);
  }

  return json({ received: true, matched: true, finalized: true }, 200);
});

function chargeMismatch(
  charge: Record<string, unknown>,
  intent: {
    currency: string;
    amount_fils: number;
    transaction_reference: string;
  },
  merchantId: string,
) {
  if (text(charge.currency)?.toUpperCase() !== intent.currency) {
    return "currency";
  }
  const amount = Number(charge.amount);
  if (
    !Number.isFinite(amount) || Math.round(amount * 1000) !== intent.amount_fils
  ) {
    return "amount";
  }
  const reference = object(charge.reference);
  if (text(reference?.transaction) !== intent.transaction_reference) {
    return "transaction_reference";
  }
  const merchant = object(charge.merchant);
  const actualMerchant = text(merchant?.id) ?? text(charge.merchant_id);
  if (actualMerchant && actualMerchant !== merchantId) return "merchant";
  return null;
}

function normalizedPaymentMethod(charge: Record<string, unknown>) {
  const source = object(charge.source);
  const card = object(charge.card);
  const raw = (
    text(source?.payment_method) ??
      text(card?.brand) ??
      "CARD"
  ).toUpperCase().replaceAll(" ", "_");
  if (raw.includes("APPLE")) return "APPLE_PAY";
  if (raw.includes("BENEFIT")) return "BENEFITPAY";
  if (raw.includes("MASTER")) return "MASTERCARD";
  if (raw.includes("VISA")) return "VISA";
  return "CARD";
}

function fieldIntentStatus(tapStatus: string) {
  if (["INITIATED", "PENDING", "IN_PROGRESS"].includes(tapStatus)) {
    return "PENDING";
  }
  if (["CANCELLED", "ABANDONED"].includes(tapStatus)) return "CANCELLED";
  if (tapStatus === "REFUNDED") return "REFUNDED";
  return "FAILED";
}

async function webhookHash(
  secretKey: string,
  charge: Record<string, unknown>,
) {
  const reference = object(charge.reference);
  const transaction = object(charge.transaction);
  const currency = text(charge.currency)?.toUpperCase() ?? "";
  const input = `x_id${text(charge.id) ?? ""}` +
    `x_amount${formatAmount(charge.amount, currency)}` +
    `x_currency${currency}` +
    `x_gateway_reference${text(reference?.gateway) ?? ""}` +
    `x_payment_reference${text(reference?.payment) ?? ""}` +
    `x_status${text(charge.status) ?? ""}` +
    `x_created${text(transaction?.created) ?? text(charge.created) ?? ""}`;
  return hmacSha256(secretKey, input);
}

async function hmacSha256(secret: string, input: string) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(input),
  );
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function formatAmount(value: unknown, currency: string) {
  const amount = Number(value);
  if (!Number.isFinite(amount)) return "";
  const threeDecimals = ["BHD", "KWD", "OMR", "JOD"].includes(currency);
  return amount.toFixed(threeDecimals ? 3 : 2);
}

function constantTimeEqual(left: string, right: string) {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let index = 0; index < left.length; index++) {
    mismatch |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return mismatch === 0;
}

function object(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

function text(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
