import { strict as assert } from "node:assert";
import {
  PaymentIntent,
  reconcilePayment,
  Stripe,
  stripeMetadata,
  verifyStripePayment,
} from "./stripe_checkout.ts";
import {
  prepareCheckout,
  supportedWebhookEvents,
} from "./stripe_payment_handler.ts";

function fixture(mode: "manual" | "automatic" = "manual"): PaymentIntent {
  return {
    id: "fa260003-0000-4000-8000-000000000001",
    profile_id: "fa260003-0000-4000-8000-000000000002",
    provider: "STRIPE",
    purpose: "SOLO_BOOKING",
    status: "PENDING",
    currency: "USD",
    amount_fils: 13000,
    amount_minor: 1300,
    payload: { game_id: "fa260003-0000-4000-8000-000000000003", role: "GK" },
    quote_snapshot: { total_fils: 13000, currency: "USD" },
    transaction_reference: "authorized-fixture",
    provider_intent_id: "pi_authorized",
    provider_payment_id: null,
    payment_method: null,
    resource_type: null,
    resource_id: null,
    expires_at: "2099-01-01T00:00:00Z",
    created_at: new Date().toISOString(),
    capture_method: mode,
  };
}

function harness(
  options: {
    full?: boolean;
    capture?: "declined" | "lost-ack" | "outage" | "processing";
    cancelFails?: boolean;
  } = {},
) {
  const intent = fixture();
  const calls: string[] = [];
  const state = {
    reserved: false,
    cancelRequested: false,
    bookings: 0,
    captureCalls: 0,
    cancelFails: options.cancelFails ?? false,
    provider: {
      id: intent.provider_intent_id,
      object: "payment_intent",
      amount: 1300,
      amount_received: 0,
      amount_capturable: 1300,
      currency: "usd",
      livemode: false,
      status: "requires_capture",
      capture_method: "manual",
      payment_method_types: ["card"],
      latest_charge: {
        id: "ch_authorized",
        payment_method_details: {
          card: { brand: "visa", wallet: { type: "apple_pay" } },
        },
      },
      metadata: stripeMetadata(intent),
    } as unknown as Stripe.PaymentIntent,
  };
  const admin = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push(name);
      if (name === "reserve_stripe_booking_authorization") {
        assert.equal(args.amount_minor_to_use, 1300);
        if (options.full || state.cancelRequested) {
          state.cancelRequested = true;
          return Promise.resolve({
            data: { status: "CANCEL_AUTHORIZATION", intent_id: intent.id },
            error: null,
          });
        }
        state.reserved = true;
        return Promise.resolve({
          data: { status: "RESERVED", intent_id: intent.id },
          error: null,
        });
      }
      if (name === "request_stripe_booking_void") {
        state.cancelRequested = true;
        return Promise.resolve({ data: null, error: null });
      }
      if (name === "record_stripe_payment_capture") {
        assert.ok(
          state.reserved,
          "Booking must be reserved before captured money is finalized",
        );
        assert.equal(args.amount_minor_to_use, 1300);
        state.bookings = 1;
        intent.status = "FINALIZED";
        intent.resource_type = "OPEN_QUEUE_BOOKING";
        intent.resource_id = "booking-authorized";
        return Promise.resolve({
          data: {
            status: "FINALIZED",
            intent_id: intent.id,
            resource_id: intent.resource_id,
          },
          error: null,
        });
      }
      throw Error(`Unexpected RPC ${name}`);
    },
    from(table: string) {
      assert.equal(table, "payment_intents");
      let update: Record<string, unknown> | undefined;
      const q = {
        select() {
          return q;
        },
        eq() {
          return q;
        },
        update(value: Record<string, unknown>) {
          update = value;
          return q;
        },
        maybeSingle() {
          return Promise.resolve({ data: intent, error: null });
        },
        then(
          resolve: (value: unknown) => unknown,
          reject: (error: unknown) => unknown,
        ) {
          if (update) {
            Object.assign(intent, update);
            if (update.status === "CANCELLED") state.reserved = false;
          }
          return Promise.resolve({ data: null, error: null }).then(
            resolve,
            reject,
          );
        },
      };
      return q;
    },
  };
  const stripe = {
    paymentIntents: {
      capture(
        id: string,
        args: Record<string, unknown>,
        request: { idempotencyKey: string },
      ) {
        calls.push("stripe.capture");
        state.captureCalls++;
        assert.equal(id, intent.provider_intent_id);
        assert.equal(args.amount_to_capture, 1300);
        assert.equal(request.idempotencyKey, `fieldrush-capture-${intent.id}`);
        assert.ok(state.reserved);
        if (
          options.capture === "declined" || options.capture === "outage"
        ) throw Error("Provider unavailable");
        state.provider = {
          ...state.provider,
          status: options.capture === "processing" ? "processing" : "succeeded",
          amount_capturable: 0,
          amount_received: options.capture === "processing" ? 0 : 1300,
        };
        if (options.capture === "lost-ack") {
          throw Error(
            "Response lost after successful capture",
          );
        }
        return Promise.resolve(state.provider);
      },
      retrieve() {
        calls.push("stripe.retrieve");
        if (options.capture === "outage") {
          throw Error(
            "Provider response remains unknown",
          );
        }
        return Promise.resolve(state.provider);
      },
      cancel(
        id: string,
        _args: unknown,
        request: { idempotencyKey: string },
      ) {
        calls.push("stripe.cancel");
        assert.equal(id, intent.provider_intent_id);
        assert.equal(request.idempotencyKey, `fieldrush-cancel-${intent.id}`);
        if (state.cancelFails) throw Error("Cancel response unavailable");
        state.provider = {
          ...state.provider,
          status: "canceled",
          amount_capturable: 0,
        };
        return Promise.resolve(state.provider);
      },
    },
  };
  return {
    state,
    intent,
    calls,
    run: () =>
      reconcilePayment(
        admin as never,
        stripe as never,
        intent,
        false,
        state.provider,
      ),
  };
}

Deno.test("manual payment reserves before capture and finalizes once", async () => {
  const h = harness();
  assert.equal((await h.run()).status, "FINALIZED");
  assert.deepEqual(h.calls, [
    "reserve_stripe_booking_authorization",
    "stripe.capture",
    "record_stripe_payment_capture",
  ]);
  assert.equal(h.state.bookings, 1);
  assert.equal((await h.run()).status, "FINALIZED");
  assert.equal(
    h.state.captureCalls,
    1,
    "Replay reads a succeeded payment; it never captures again",
  );
  assert.equal(h.state.bookings, 1);
});
Deno.test("last-position loser voids the authorization without capturing", async () => {
  const h = harness({ full: true });
  assert.equal((await h.run()).status, "CANCELLED");
  assert.equal(h.state.captureCalls, 0);
  assert.equal(h.state.bookings, 0);
  assert.equal(h.intent.status, "CANCELLED");
  assert.ok(h.calls.includes("stripe.cancel"));
});
Deno.test("capture timeout after money moved recovers the same booking", async () => {
  const h = harness({ capture: "lost-ack" });
  assert.equal((await h.run()).status, "FINALIZED");
  assert.equal(h.state.captureCalls, 1);
  assert.equal(h.state.bookings, 1);
  assert.ok(!h.calls.includes("stripe.cancel"));
});
Deno.test("capture declined while still authorized is provider-voided", async () => {
  const h = harness({ capture: "declined" });
  assert.equal((await h.run()).status, "CANCELLED");
  assert.equal(h.state.bookings, 0);
  assert.equal(h.state.reserved, false);
  assert.ok(
    h.calls.indexOf("request_stripe_booking_void") <
      h.calls.indexOf("stripe.cancel"),
  );
});
Deno.test("unknown capture and failed retrieval retain the exact reservation", async () => {
  const h = harness({ capture: "outage" });
  await assert.rejects(h.run(), /response remains unknown/);
  assert.equal(h.state.reserved, true);
  assert.equal(h.intent.status, "PENDING");
  assert.equal(h.state.bookings, 0);
  assert.ok(!h.calls.includes("stripe.cancel"));
});
Deno.test("an unknown void is retried and cannot become a new capture", async () => {
  const h = harness({ full: true, cancelFails: true });
  assert.equal((await h.run()).status, "PROCESSING");
  assert.equal((await h.run()).status, "PROCESSING");
  assert.equal(h.state.captureCalls, 0);
  assert.equal(h.intent.status, "PENDING");
  h.state.cancelFails = false;
  assert.equal((await h.run()).status, "CANCELLED");
});
Deno.test("processing capture is reconciled without releasing capacity", async () => {
  const h = harness({ capture: "processing" });
  assert.equal((await h.run()).status, "PROCESSING");
  assert.equal(h.state.reserved, true);
  assert.equal(h.state.bookings, 0);
  h.state.provider = {
    ...h.state.provider,
    status: "succeeded",
    amount_received: 1300,
  };
  assert.equal((await h.run()).status, "FINALIZED");
  assert.equal(h.state.captureCalls, 1);
});
Deno.test("3DS authentication does not capture or allocate a spot prematurely", async () => {
  const h = harness();
  h.state.provider = {
    ...h.state.provider,
    status: "requires_action",
    amount_capturable: 0,
  };
  assert.equal((await h.run()).status, "PENDING");
  assert.equal(h.state.captureCalls, 0);
  assert.equal(h.state.reserved, false);
});
for (const amount of [0, 1299, 1301]) {
  Deno.test(`incorrect authorized amount ${amount} is rejected before any reservation`, async () => {
    const h = harness();
    h.state.provider = { ...h.state.provider, amount_capturable: amount };
    await assert.rejects(h.run(), /authorization amount/);
    assert.equal(h.calls.length, 0);
  });
}
Deno.test("capture mode is pinned to the saved attempt", () => {
  const h = harness();
  assert.throws(
    () =>
      verifyStripePayment(
        { ...h.state.provider, capture_method: "automatic" } as never,
        h.intent,
        false,
      ),
    /configuration/,
  );
  assert.ok(
    supportedWebhookEvents.has("payment_intent.amount_capturable_updated"),
  );
});

// New/old app negotiation runs the actual prepare path with a narrow in-memory
// database transport. Neither case has network or external credentials.
for (const mode of [undefined, "manual"] as const) {
  Deno.test(`new checkout capture mode: ${mode ?? "untagged old app"}`, async () => {
    let stored: PaymentIntent | undefined;
    let createdMode: unknown;
    const quote = {
      currency: "USD",
      total_fils: 13000,
      match_fee_fils: 13000,
      standard_match_fee_fils: 13000,
      reliability_deposit_fils: 0,
      replacement_discount_bps: 0,
      policy_version_id: "policy-fixture",
    };
    const admin = {
      from(table: string) {
        let operation: "select" | "insert" | "update" = "select";
        let inserted: Record<string, unknown> | undefined;
        const q = {
          select() {
            return q;
          },
          eq() {
            return q;
          },
          in() {
            return q;
          },
          order() {
            return q;
          },
          limit() {
            return q;
          },
          is() {
            return q;
          },
          maybeSingle() {
            return Promise.resolve({ data: null, error: null });
          },
          insert(value: Record<string, unknown>) {
            operation = "insert";
            inserted = value;
            return q;
          },
          update() {
            operation = "update";
            return q;
          },
          single() {
            assert.equal(table, "payment_intents");
            assert.equal(operation, "insert");
            stored = {
              ...fixture(mode === "manual" ? "manual" : "automatic"),
              ...inserted,
              provider_intent_id: null,
            } as PaymentIntent;
            return Promise.resolve({ data: stored, error: null });
          },
          then(
            resolve: (value: unknown) => unknown,
            reject: (error: unknown) => unknown,
          ) {
            assert.equal(operation, "update");
            return Promise.resolve({ data: null, error: null }).then(
              resolve,
              reject,
            );
          },
        };
        return q;
      },
    };
    const result = await prepareCheckout({
      admin,
      userId: fixture().profile_id,
      user: { rpc: () => Promise.resolve({ data: quote, error: null }) },
      livemode: false,
      stripe: {
        paymentIntents: {
          create: (params: Record<string, unknown>) => {
            createdMode = params.capture_method;
            return Promise.resolve({
              id: "pi_prepared",
              object: "payment_intent",
              status: "requires_payment_method",
              amount: 1300,
              amount_received: 0,
              currency: "usd",
              livemode: false,
              metadata: params.metadata,
              capture_method: params.capture_method,
              payment_method_types: ["card"],
              client_secret: "pi_prepared_secret_fixture",
            });
          },
        },
      },
    } as never, {
      purpose: "SOLO_BOOKING",
      payload: fixture().payload,
      ...(mode ? { capture_method: mode } : {}),
    });
    assert.equal(createdMode, mode ?? "automatic");
    assert.equal(stored?.capture_method, mode ?? "automatic");
    assert.equal(result.capture_method, mode ?? "automatic");
    assert.equal(result.status, "PENDING");
  });
}
