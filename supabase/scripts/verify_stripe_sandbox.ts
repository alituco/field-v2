// Explicit, test-mode-only provider smoke test. This is not a booking E2E test.
// deno run --allow-env --allow-net --env-file=.env.staging supabase/scripts/verify_stripe_sandbox.ts
import { strict as assert } from "node:assert";
import { Stripe, stripeClient } from "../functions/_shared/stripe_checkout.ts";

const secret = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const publishable = Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "";
if (!secret.startsWith("sk_test_") || !publishable.startsWith("pk_test_")) {
  console.error(
    "Stripe sandbox secret and publishable keys are required. Live keys are refused.",
  );
  Deno.exit(1);
}
const stripe = stripeClient(secret);
const publicStripe = stripeClient(publishable);
const run = crypto.randomUUID();
const created: string[] = [];
let failed = false;
let assertions = 0;
function check(value: boolean, label: string) {
  assert(value, label);
  assertions++;
}

async function create(name: string, currency = "usd", amount = 1300) {
  const params: Stripe.PaymentIntentCreateParams = {
    amount,
    currency,
    allowed_payment_method_types: ["card"],
    capture_method: "automatic",
    metadata: { fieldrush_sandbox_smoke: run, scenario: name },
  };
  const options = { idempotencyKey: `fieldrush-smoke-${run}-${name}` };
  const payment = await stripe.paymentIntents.create(params, options);
  created.push(payment.id);
  check(!payment.livemode, "Payment must stay in sandbox");
  const repeated = await stripe.paymentIntents.create(params, options);
  check(payment.id === repeated.id, "Repeated create must reuse payment");
  return payment;
}

try {
  const payment = await create("success");
  const clientPayment = await publicStripe.paymentIntents.retrieve(payment.id, {
    client_secret: payment.client_secret!,
  });
  check(
    clientPayment.id === payment.id,
    "Mobile and server keys must belong to the same Stripe sandbox",
  );
  const confirmed = await stripe.paymentIntents.confirm(payment.id, {
    payment_method: "pm_card_visa",
  });
  check(confirmed.status === "succeeded", "Test card payment should succeed");
  check(confirmed.amount_received === 1300, "Captured amount must be $13");
  const partial = { payment_intent: payment.id, amount: 650 };
  const options = { idempotencyKey: `fieldrush-smoke-refund-${run}` };
  const refund = await stripe.refunds.create(partial, options);
  const repeated = await stripe.refunds.create(partial, options);
  check(refund.id === repeated.id, "Refund retry must not duplicate money");
  check(refund.status === "succeeded", "Partial refund should succeed");
  const remainder = await stripe.refunds.create(partial, {
    idempotencyKey: `fieldrush-smoke-remainder-${run}`,
  });
  check(remainder.status === "succeeded", "Remaining refund should succeed");
  const charge = await stripe.charges.retrieve(String(confirmed.latest_charge));
  check(
    charge.amount_refunded === 1300,
    "Full captured amount should be refunded",
  );

  const declined = await create("decline");
  let declineReceived = false;
  try {
    await stripe.paymentIntents.confirm(declined.id, {
      payment_method: "pm_card_visa_chargeDeclined",
    });
  } catch (error) {
    declineReceived = error instanceof Stripe.errors.StripeCardError;
  }
  check(declineReceived, "Declined card must not report success");
  const declinedResult = await stripe.paymentIntents.retrieve(declined.id);
  check(declinedResult.amount_received === 0, "Decline must not capture money");

  const challenged = await create("3ds");
  const authentication = await stripe.paymentIntents.confirm(challenged.id, {
    payment_method: "pm_card_threeDSecure2Required",
    return_url: "fieldrush://stripe-redirect",
  });
  check(
    authentication.status === "requires_action",
    "3DS must await authentication",
  );
  check(
    authentication.amount_received === 0,
    "Unfinished 3DS must not capture money",
  );

  const abandoned = await create("cancel");
  const canceled = await stripe.paymentIntents.cancel(abandoned.id);
  check(canceled.status === "canceled", "Abandoned payment must cancel");
  check(
    canceled.amount_received === 0,
    "Canceled payment must not capture money",
  );
} catch (error) {
  failed = true;
  // Never log Stripe response bodies, credentials or client secrets.
  console.error(
    "Stripe sandbox smoke failed:",
    error instanceof Stripe.errors.StripeError
      ? `${error.type} (${error.code ?? "no-code"})`
      : error instanceof assert.AssertionError
      ? error.message
      : "internal error",
  );
} finally {
  // Any successful sandbox capture is refunded even if an assertion fails.
  for (const id of created) {
    try {
      const payment = await stripe.paymentIntents.retrieve(id, {
        expand: ["latest_charge"],
      });
      if (payment.status === "succeeded") {
        const charge = payment.latest_charge as Stripe.Charge;
        const remaining = charge.amount - charge.amount_refunded;
        if (remaining > 0) {
          await stripe.refunds.create(
            { payment_intent: id, amount: remaining },
            {
              idempotencyKey: `fieldrush-smoke-cleanup-${run}-${id}`,
            },
          );
        }
      } else if (payment.status !== "canceled") {
        await stripe.paymentIntents.cancel(id);
      }
    } catch {
      failed = true;
      console.error(`Sandbox cleanup needs review for ${id}.`);
    }
  }
}
console.log(
  `${assertions} Stripe sandbox checks completed; ${created.length} test attempts cleaned up.`,
);
if (failed) Deno.exit(1);
