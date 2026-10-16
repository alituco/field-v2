import { strict as assert } from "node:assert";
import {
  PaymentDatabase,
  PaymentIntent,
  Stripe,
  stripeMetadata,
} from "./stripe_checkout.ts";
import {
  CheckoutRecoveryRequired,
  recoverOrphanStripeIntent,
  recoveryEvidence,
} from "./stripe_recovery.ts";
import { recoverEarlierCheckout } from "./stripe_payment_handler.ts";

const fixture: PaymentIntent = {
  id: "a5287b6a-22f6-4e55-a230-5582f8ebf0b4",
  profile_id: "b5287b6a-22f6-4e55-a230-5582f8ebf0b4",
  provider: "STRIPE",
  purpose: "SOLO_BOOKING",
  status: "PENDING",
  currency: "USD",
  amount_fils: 13000,
  amount_minor: 1300,
  payload: { game_id: "c5287b6a-22f6-4e55-a230-5582f8ebf0b4", role: "DEF" },
  quote_snapshot: {},
  transaction_reference: "recovery-fixture",
  provider_intent_id: null,
  provider_payment_id: null,
  payment_method: null,
  resource_type: null,
  resource_id: null,
  created_at: new Date(Date.now() - 25 * 3600000).toISOString(),
  expires_at: new Date(Date.now() - 24 * 3600000).toISOString(),
};
function payment(patch: Record<string, unknown> = {}) {
  return {
    id: "pi_recoveryA",
    object: "payment_intent",
    amount: 1300,
    amount_received: 0,
    currency: "usd",
    livemode: false,
    metadata: stripeMetadata(fixture),
    status: "requires_payment_method",
    capture_method: "automatic",
    payment_method_types: ["card"],
    latest_charge: null,
    client_secret: "secret-never-persisted",
    ...patch,
  } as unknown as Stripe.PaymentIntent;
}
const reference = "d5287b6a-22f6-4e55-a230-5582f8ebf0b4";
function harness(
  options: {
    pages?: unknown[];
    state?: Record<string, unknown>;
    retrieved?: Stripe.PaymentIntent;
    lostAck?: boolean;
    denied?: boolean;
  } = {},
) {
  const local = { ...fixture };
  let bound: string | null = null,
    listCalls = 0,
    createCalls = 0,
    retrievals = 0,
    lostAck = options.lostAck;
  const completions: Record<string, unknown>[] = [];
  const listings: unknown[] = [];
  const admin = {
    rpc(name: string, args: Record<string, unknown>) {
      if (name === "claim_stripe_checkout_recovery") {
        return Promise.resolve({
          data: bound ? { claimed: false, provider_intent_id: bound } : {
            claimed: !options.denied,
            case_id: reference,
            scan_from: 1,
            scan_until: 2,
            scan_cursor: null,
            provider_evidence: [],
            pages_scanned: 0,
            ...options.state,
          },
          error: null,
        });
      }
      assert.equal(name, "complete_stripe_checkout_recovery");
      completions.push(args);
      if (args.outcome_to_use === "RECOVERED") {
        bound = (args.evidence_to_use as { id: string }[])[0].id;
      }
      if (lostAck) {
        lostAck = false;
        return Promise.resolve({
          data: null,
          error: new Error("Lost database acknowledgement"),
        });
      }
      return Promise.resolve({
        data: { case_id: reference, provider_intent_id: bound },
        error: null,
      });
    },
  } as unknown as PaymentDatabase;
  const stripe = {
    paymentIntents: {
      list(args: unknown) {
        listings.push(args);
        const result = options.pages?.[listCalls++] ??
          { data: [], has_more: false };
        return result instanceof Error
          ? Promise.reject(result)
          : Promise.resolve(result);
      },
      retrieve() {
        retrievals++;
        return Promise.resolve(options.retrieved ?? payment());
      },
      create() {
        createCalls++;
        throw new Error("Recovery must not create a PaymentIntent");
      },
    },
  } as unknown as Stripe;
  return {
    ctx: { admin, stripe, livemode: false },
    local,
    completions,
    listings,
    get lists() {
      return listCalls;
    },
    get creates() {
      return createCalls;
    },
    get retrievals() {
      return retrievals;
    },
  };
}
Deno.test("orphan recovery verifies a unique complete LIST match and stores no secret", async () => {
  const h = harness({
    pages: [{
      data: [payment({ id: "pi_other", metadata: {} }), payment()],
      has_more: false,
    }],
  });
  assert.equal(
    (await recoverOrphanStripeIntent(h.ctx, h.local)).id,
    "pi_recoveryA",
  );
  assert.equal(h.local.provider_intent_id, "pi_recoveryA");
  assert.equal(h.creates, 0);
  assert.equal(h.completions[0].outcome_to_use, "RECOVERED");
  assert(!JSON.stringify(h.completions).includes("secret-never-persisted"));
});
Deno.test("an empty provider LIST keeps the checkout protected and exposes a stable review reference", async () => {
  const h = harness();
  await assert.rejects(
    recoverOrphanStripeIntent(h.ctx, h.local),
    (e: unknown) =>
      e instanceof CheckoutRecoveryRequired && e.reviewReference === reference,
  );
  assert.equal(h.completions[0].outcome_to_use, "NO_MATCH");
  assert.equal(h.local.provider_intent_id, null);
  assert.equal(h.creates, 0);
});
Deno.test("multiple matching provider intents never pick one or release the lease", async () => {
  const h = harness({
    pages: [{
      data: [payment(), payment({ id: "pi_recoveryB" })],
      has_more: false,
    }],
  });
  await assert.rejects(
    recoverOrphanStripeIntent(h.ctx, h.local),
    CheckoutRecoveryRequired,
  );
  assert.equal(h.completions[0].outcome_to_use, "MULTIPLE_MATCHES");
  assert.equal(h.retrievals, 0);
});
for (
  const patch of [{ amount: 999 }, { currency: "bhd" }, { livemode: true }, {
    metadata: { ...stripeMetadata(fixture), field_profile_id: "foreign" },
  }, { status: "succeeded", amount_received: 100 }]
) {
  Deno.test(`provider mismatch remains under review: ${JSON.stringify(patch)}`, async () => {
    const h = harness({ pages: [{ data: [payment(patch)], has_more: false }] });
    await assert.rejects(
      recoverOrphanStripeIntent(h.ctx, h.local),
      CheckoutRecoveryRequired,
    );
    assert.equal(h.completions[0].outcome_to_use, "MISMATCH");
    assert.equal(h.creates, 0);
  });
}
Deno.test("bounded pagination persists progress without trusting an early positive match", async () => {
  const h = harness({
    pages: [{ data: [payment()], has_more: true }, {
      data: [payment({ id: "pi_pageB", metadata: {} })],
      has_more: true,
    }, { data: [payment({ id: "pi_pageC", metadata: {} })], has_more: true }],
  });
  await assert.rejects(
    recoverOrphanStripeIntent(h.ctx, h.local),
    CheckoutRecoveryRequired,
  );
  assert.equal(h.lists, 3);
  assert.equal(h.completions[0].outcome_to_use, "INCOMPLETE");
  assert.equal(h.completions[0].scan_cursor_to_use, "pi_pageC");
  assert.equal(h.local.provider_intent_id, null);
});
Deno.test("a later invocation resumes persisted cursor and verifies its previous candidate", async () => {
  const h = harness({
    state: {
      scan_cursor: "pi_previous",
      pages_scanned: 3,
      provider_evidence: [recoveryEvidence(payment())],
    },
    pages: [{ data: [], has_more: false }],
  });
  await recoverOrphanStripeIntent(h.ctx, h.local);
  assert.equal(
    (h.listings[0] as { starting_after: string }).starting_after,
    "pi_previous",
  );
  assert.equal(h.completions[0].pages_scanned_to_use, 4);
  assert.equal(h.completions[0].outcome_to_use, "RECOVERED");
});
Deno.test("pagination outage preserves accumulated evidence and cannot bind or release", async () => {
  const h = harness({
    pages: [
      { data: [payment()], has_more: true },
      new Error("Provider offline"),
    ],
  });
  await assert.rejects(
    recoverOrphanStripeIntent(h.ctx, h.local),
    CheckoutRecoveryRequired,
  );
  assert.equal(h.completions[0].outcome_to_use, "PROVIDER_UNAVAILABLE");
  assert.equal(h.completions[0].scan_complete_to_use, false);
  assert.equal(h.completions[0].scan_cursor_to_use, "pi_recoveryA");
  assert.equal(h.local.provider_intent_id, null);
});
Deno.test("non-advancing pagination fails closed", async () => {
  const h = harness({ pages: [{ data: [], has_more: true }] });
  await assert.rejects(
    recoverOrphanStripeIntent(h.ctx, h.local),
    CheckoutRecoveryRequired,
  );
  assert.equal(h.completions[0].outcome_to_use, "PROVIDER_UNAVAILABLE");
});
Deno.test("claim cooldown prevents repeated provider scans", async () => {
  const h = harness({ denied: true });
  await assert.rejects(
    recoverOrphanStripeIntent(h.ctx, h.local),
    CheckoutRecoveryRequired,
  );
  assert.equal(h.lists, 0);
  assert.equal(h.completions.length, 0);
});
Deno.test("a lost link acknowledgement recovers its existing binding without another provider create", async () => {
  const h = harness({
    lostAck: true,
    pages: [{ data: [payment()], has_more: false }],
  });
  await assert.rejects(
    recoverOrphanStripeIntent(h.ctx, h.local),
    /Lost database acknowledgement/,
  );
  await recoverOrphanStripeIntent(h.ctx, h.local);
  assert.equal(h.lists, 1);
  assert.equal(h.creates, 0);
  assert.equal(h.local.provider_intent_id, "pi_recoveryA");
});
Deno.test("capture racing the LIST scan returns the freshly retrieved captured state", async () => {
  const h = harness({
    pages: [{ data: [payment()], has_more: false }],
    retrieved: payment({
      status: "succeeded",
      amount_received: 1300,
      latest_charge: "ch_capture",
    }),
  });
  assert.equal(
    (await recoverOrphanStripeIntent(h.ctx, h.local)).status,
    "succeeded",
  );
  assert.equal(h.creates, 0);
});

for (const recent of [true, false]) {
  Deno.test(`self-service never creates or cancels a ${recent ? "recent unknown" : "unexpired"} checkout`, async () => {
    const current = {
      ...fixture,
      ...(recent
        ? { created_at: new Date().toISOString() }
        : { expires_at: new Date(Date.now() + 600000).toISOString() }),
    };
    const filters: Record<string, unknown> = {};
    const q = {
      select: () => q,
      eq: (k: string, v: unknown) => {
        filters[k] = v;
        return q;
      },
      in: () => q,
      order: () => q,
      limit: () => q,
      maybeSingle: () => Promise.resolve({ data: current, error: null }),
    };
    const ctx = {
      admin: { from: () => q },
      userId: fixture.profile_id,
      stripe: {
        paymentIntents: {
          create: () => assert.fail("No create"),
          retrieve: () => assert.fail("No retrieve"),
          cancel: () => assert.fail("No cancel"),
        },
      },
    };
    assert.deepEqual(
      await recoverEarlierCheckout(
        ctx as unknown as Parameters<typeof recoverEarlierCheckout>[0],
      ),
      { recovered: false },
    );
    assert.equal(filters.profile_id, fixture.profile_id);
    assert.equal(filters.provider, "STRIPE");
  });
}

for (const outcome of ["FINALIZED", "REQUIRES_REFUND"]) {
  Deno.test(`recovered capture uses normal ${outcome} settlement and cannot request another charge`, async () => {
    const h = harness({
      pages: [{ data: [payment()], has_more: false }],
      retrieved: payment({
        status: "succeeded",
        amount_received: 1300,
        latest_charge: "ch_capture",
      }),
    });
    const originalRpc = h.ctx.admin.rpc.bind(h.ctx.admin);
    const captureCalls: Record<string, unknown>[] = [];
    const admin = h.ctx.admin as unknown as {
      rpc: (name: string, args: Record<string, unknown>) => Promise<unknown>;
      from: (table: string) => unknown;
    };
    admin.rpc = (name, args) => {
      if (name !== "record_stripe_payment_capture") {
        return originalRpc(name, args) as unknown as Promise<unknown>;
      }
      captureCalls.push(args);
      h.local.status = outcome;
      return Promise.resolve({
        data: {
          status: outcome,
          intent_id: h.local.id,
          resource_type: outcome === "FINALIZED" ? "OPEN_QUEUE_BOOKING" : null,
          resource_id: outcome === "FINALIZED" ? "booking" : null,
        },
        error: null,
      });
    };
    admin.from = (table) => {
      const q = {
        select: () => q,
        eq: () => q,
        in: () => q,
        order: () => q,
        limit: () => q,
        maybeSingle: () => Promise.resolve({ data: h.local, error: null }),
        then: (resolve: (v: unknown) => unknown) =>
          Promise.resolve({
            data: table === "payment_refunds" ? [{ status: "PENDING" }] : [],
            error: null,
          }).then(resolve),
      };
      return q;
    };
    const ctx = { ...h.ctx, userId: fixture.profile_id };
    const result = await recoverEarlierCheckout(
      ctx as unknown as Parameters<typeof recoverEarlierCheckout>[0],
    );
    assert.deepEqual(result, { recovered: outcome === "FINALIZED" });
    assert.equal(captureCalls.length, 1);
    assert.equal(captureCalls[0].provider_payment_id_to_use, "ch_capture");
    assert.equal(h.creates, 0);
  });
}
