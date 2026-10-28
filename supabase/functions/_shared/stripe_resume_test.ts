import { strict as assert } from "node:assert";
import {
  handlePayment,
  resumeExistingCheckout,
} from "./stripe_payment_handler.ts";
import { PaymentIntent, Stripe, stripeMetadata } from "./stripe_checkout.ts";
import { fieldStagingSupabaseUrl } from "./staging_guard.ts";

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
  quote_snapshot: {
    currency: "USD",
    total_fils: 13000,
    standard_match_fee_fils: 10000,
    match_fee_fils: 10000,
    reliability_deposit_fils: 3000,
    replacement_discount_bps: 0,
    policy_version_id: "initial-policy",
  },
  transaction_reference: "resume-fixture",
  provider_intent_id: "pi_resume",
  provider_payment_id: null,
  payment_method: null,
  resource_type: null,
  resource_id: null,
  created_at: new Date().toISOString(),
  expires_at: new Date(Date.now() + 600000).toISOString(),
};
const body = {
  action: "resume",
  intent_id: fixture.id,
  purpose: fixture.purpose,
  payload: fixture.payload,
};
function setup(
  options: {
    intent?: Partial<PaymentIntent>;
    provider?: Record<string, unknown>;
    settlement?: string;
    missing?: boolean;
    cancelRace?: boolean;
    quoteError?: string;
    quote?: Record<string, unknown>;
  } = {},
) {
  const local = { ...fixture, ...options.intent };
  const requests: Record<string, unknown>[] = [];
  let canceled = 0, created = 0, captured = 0;
  const payment = () => ({
    id: "pi_resume",
    object: "payment_intent",
    amount: 1300,
    amount_received: 0,
    currency: "usd",
    livemode: false,
    status: "requires_payment_method",
    capture_method: "automatic",
    payment_method_types: ["card"],
    metadata: stripeMetadata(local),
    client_secret: "pi_resume_secret_fixture",
    latest_charge: null,
    ...options.provider,
  } as unknown as Stripe.PaymentIntent);
  const admin = {
    from(table: string) {
      const filters: Record<string, unknown> = {};
      const q = {
        select: () => q,
        eq: (k: string, v: unknown) => {
          filters[k] = v;
          return q;
        },
        in: (k: string, v: unknown) => {
          filters[k] = v;
          return q;
        },
        order: () => q,
        limit: () => q,
        maybeSingle: () => {
          requests.push({ table, ...filters });
          return Promise.resolve({
            data: options.missing ? null : local,
            error: null,
          });
        },
        update: (value: Record<string, unknown>) => {
          requests.push({ update: value });
          return q;
        },
        then: (resolve: (v: unknown) => unknown) =>
          Promise.resolve({
            data: table === "payment_refunds" ? [{ status: "PENDING" }] : null,
            error: null,
          }).then(resolve),
      };
      return q;
    },
    rpc(name: string, args: Record<string, unknown>) {
      assert.equal(name, "record_stripe_payment_capture");
      captured++;
      requests.push({ rpc: name, ...args });
      local.status = options.settlement ?? "FINALIZED";
      return Promise.resolve({
        data: {
          status: local.status,
          intent_id: local.id,
          resource_type: "OPEN_QUEUE_BOOKING",
          resource_id: "booking",
        },
        error: null,
      });
    },
  };
  const stripe = {
    paymentIntents: {
      retrieve: () => Promise.resolve(payment()),
      create: () => {
        created++;
        assert.fail("Resume cannot create a provider intent");
      },
      cancel: () => {
        canceled++;
        return Promise.resolve({ ...payment(), status: "canceled" });
      },
    },
  };
  // The cancellation-race result is deliberately captured instead of canceled.
  if (options.cancelRace) {
    stripe.paymentIntents.cancel = () => {
      canceled++;
      return Promise.resolve(
        {
          ...payment(),
          status: "succeeded",
          amount_received: 1300,
          latest_charge: "ch_race",
        } as Stripe.PaymentIntent,
      );
    };
  }
  const ctx = {
    admin,
    user: {
      rpc(name: string, args: Record<string, unknown>) {
        assert.equal(name, "preview_open_queue_booking_cost");
        requests.push({ quote: true, ...args });
        return Promise.resolve({
          data: { ...fixture.quote_snapshot, ...options.quote },
          error: options.quoteError ? { message: options.quoteError } : null,
        });
      },
    },
    stripe,
    userId: fixture.profile_id,
    livemode: false,
  } as unknown as Parameters<typeof resumeExistingCheckout>[0];
  return {
    ctx,
    local,
    requests,
    get created() {
      return created;
    },
    get captured() {
      return captured;
    },
    get canceled() {
      return canceled;
    },
  };
}

for (const status of ["requires_payment_method", "requires_confirmation"]) {
  Deno.test(`fresh verified ${status} resumes the exact same quoted intent`, async () => {
    const h = setup({ provider: { status } });
    const result = await resumeExistingCheckout(h.ctx, body);
    assert.equal(result.status, "COLLECTABLE");
    assert.equal(result.verified_unpaid, true);
    assert.equal(result.intent_id, fixture.id);
    assert.equal(result.stripe_payment_intent_id, fixture.provider_intent_id);
    assert.equal(result.client_secret, "pi_resume_secret_fixture");
    assert.equal(result.amount_fils, 13000);
    assert(
      h.requests.some((r) =>
        r.profile_id === fixture.profile_id && r.id === fixture.id
      ),
    );
    assert.equal(h.created, 0);
  });
}
for (const status of ["processing", "requires_capture", "requires_action"]) {
  Deno.test(`${status} is verification-only, never collectable`, async () => {
    const h = setup({ provider: { status } });
    const result = await resumeExistingCheckout(h.ctx, body);
    assert.notEqual(result.status, "COLLECTABLE");
    assert.equal(result.client_secret, undefined);
    assert.equal(h.created, 0);
    assert.equal(h.canceled, 0);
  });
}
for (const status of ["FINALIZED", "REQUIRES_REFUND"]) {
  Deno.test(`a succeeded provider payment follows existing ${status} settlement without collection`, async () => {
    const h = setup({
      provider: {
        status: "succeeded",
        amount_received: 1300,
        latest_charge: "ch_captured",
      },
      settlement: status,
    });
    const result = await resumeExistingCheckout(h.ctx, body);
    assert.equal(result.status, status);
    assert.equal(result.client_secret, undefined);
    assert.equal(h.captured, 1);
    assert.equal(h.created, 0);
    assert.equal(h.canceled, 0);
  });
}
Deno.test("unknown provider identity remains pending without recreating or probing a new intent", async () => {
  const h = setup({ intent: { provider_intent_id: null } });
  const result = await resumeExistingCheckout(h.ctx, body);
  assert.equal(result.status, "PENDING");
  assert.equal(result.provider_status, "UNKNOWN");
  assert.equal(result.client_secret, undefined);
  assert.equal(h.created, 0);
});
Deno.test("expiry cancels only the existing provider attempt and never renews it", async () => {
  const h = setup({
    intent: { expires_at: new Date(Date.now() - 1000).toISOString() },
  });
  const result = await resumeExistingCheckout(h.ctx, body);
  assert.equal(result.status, "CANCELLED");
  assert.equal(h.canceled, 1);
  assert.equal(h.created, 0);
  assert.equal(result.client_secret, undefined);
});
Deno.test("capture racing expiry cancellation settles the charge instead of opening another checkout", async () => {
  const h = setup({
    intent: { expires_at: new Date(Date.now() - 1000).toISOString() },
    cancelRace: true,
  });
  const result = await resumeExistingCheckout(h.ctx, body);
  assert.equal(result.status, "FINALIZED");
  assert.equal(h.captured, 1);
  assert.equal(h.created, 0);
});
for (
  const mismatch of [
    {
      purpose: "CLAN_JOIN",
      payload: {
        fixture_id: fixture.payload.game_id,
        clan_id: fixture.profile_id,
      },
    },
    { payload: { ...fixture.payload, role: "ATT" } },
    { payload: { ...fixture.payload, game_id: fixture.profile_id } },
  ]
) {
  Deno.test("resume rejects mismatched purpose/game/role before any payment collection", async () => {
    const h = setup();
    await assert.rejects(
      resumeExistingCheckout(h.ctx, { ...body, ...mismatch }),
      /does not match/,
    );
    assert.equal(h.created, 0);
    assert.equal(h.canceled, 0);
  });
}
Deno.test("missing/foreign owner lookup is rejected", async () => {
  const h = setup({ missing: true });
  await assert.rejects(resumeExistingCheckout(h.ctx, body), /not found/);
  assert.equal(h.created, 0);
});
for (
  const provider of [
    { amount: 1400 },
    { currency: "bhd" },
    { livemode: true },
    { amount_received: 100, status: "succeeded" },
  ]
) {
  Deno.test("provider identity/money mismatch fails before exposing a client secret", async () => {
    const h = setup({ provider });
    await assert.rejects(resumeExistingCheckout(h.ctx, body), /does not match/);
    assert.equal(h.created, 0);
    assert.equal(h.captured, 0);
  });
}
Deno.test("an existing refund-required state never becomes a collectible checkout", async () => {
  const h = setup({ intent: { status: "REQUIRES_REFUND" } });
  const result = await resumeExistingCheckout(h.ctx, body);
  assert.equal(result.status, "REQUIRES_REFUND");
  assert.equal(result.client_secret, undefined);
  assert.equal(h.created, 0);
  assert.equal(h.canceled, 0);
});

for (
  const quoteError of [
    "The game is full.",
    "This game was cancelled.",
    "Division requirements changed.",
  ]
) {
  Deno.test(`unpaid resume rechecks availability and cannot charge: ${quoteError}`, async () => {
    const h = setup({ quoteError });
    const result = await resumeExistingCheckout(h.ctx, body);
    assert.equal(result.status, "CANCELLED");
    assert.equal(result.client_secret, undefined);
    assert.equal(h.canceled, 1);
    assert.equal(h.created, 0);
    assert(h.requests.some((request) => request.quote === true));
  });
}
Deno.test("availability failure still settles capture racing cancellation", async () => {
  const h = setup({ quoteError: "The game is full.", cancelRace: true });
  const result = await resumeExistingCheckout(h.ctx, body);
  assert.equal(result.status, "FINALIZED");
  assert.equal(h.captured, 1);
  assert.equal(result.client_secret, undefined);
});
Deno.test("unpaid resume preserves the valid frozen solo price after repricing", async () => {
  const h = setup({
    quote: {
      total_fils: 19000,
      match_fee_fils: 16000,
      standard_match_fee_fils: 16000,
    },
  });
  const result = await resumeExistingCheckout(h.ctx, body);
  assert.equal(result.status, "COLLECTABLE");
  assert.equal(result.amount_fils, fixture.amount_fils);
  assert.equal(h.canceled, 0);
});
Deno.test("a changed cancellation policy retires only the unpaid existing intent", async () => {
  const h = setup({ quote: { policy_version_id: "new-policy" } });
  const result = await resumeExistingCheckout(h.ctx, body);
  assert.equal(result.status, "CANCELLED");
  assert.equal(result.client_secret, undefined);
  assert.equal(h.created, 0);
});
Deno.test("a malformed expiry cannot authorize collection", async () => {
  const h = setup({ intent: { expires_at: "invalid-expiry" } });
  const result = await resumeExistingCheckout(h.ctx, body);
  assert.equal(result.status, "CANCELLED");
  assert.equal(result.client_secret, undefined);
  assert.equal(h.created, 0);
});
for (const missing of [false, true]) {
  Deno.test(`resume without an acknowledged local ID is read-only: missing=${missing}`, async () => {
    const h = setup({ missing });
    const request = { ...body, intent_id: undefined };
    const result = await resumeExistingCheckout(h.ctx, request);
    assert.equal(result.status, missing ? "PENDING" : "COLLECTABLE");
    assert.equal(h.created, 0);
    assert.equal(h.canceled, 0);
    assert(
      h.requests.some((row) =>
        row.profile_id === fixture.profile_id &&
        row.purpose === fixture.purpose &&
        row["payload->>game_id"] === fixture.payload.game_id
      ),
    );
  });
}

for (
  const state of [
    "UNPAID",
    "UNKNOWN",
    "FOREIGN",
    "PROVIDER_ERROR",
    "NO_ID_UNPAID",
    "NO_ID_UNKNOWN",
  ]
) {
  Deno.test(`actual resume HTTP handler stays exact-intent and fails closed: ${state}`, async () => {
    const originalFetch = globalThis.fetch;
    const originalEnvGet = Deno.env.get;
    const originalConsoleError = console.error;
    const local = {
      ...fixture,
      provider_intent_id: state.includes("UNKNOWN")
        ? null
        : fixture.provider_intent_id,
    };
    const values: Record<string, string> = {
      SUPABASE_URL: fieldStagingSupabaseUrl,
      SUPABASE_ANON_KEY: crypto.randomUUID(),
      SUPABASE_SERVICE_ROLE_KEY: crypto.randomUUID(),
      STRIPE_SECRET_KEY: `sk_test_${crypto.randomUUID().replaceAll("-", "")}`,
      FIELD_ENVIRONMENT: "staging",
    };
    const calls: string[] = [];
    const unexpected: string[] = [];
    const response = (value: unknown, status = 200) =>
      new Response(JSON.stringify(value), {
        status,
        headers: { "Content-Type": "application/json" },
      });
    Deno.env.get = (key: string) => values[key];
    console.error = () => {};
    globalThis.fetch = async (input, init) => {
      const request = input instanceof Request
        ? input
        : new Request(input, init);
      const url = new URL(request.url);
      calls.push(`${request.method} ${url.pathname}`);
      if (url.origin === fieldStagingSupabaseUrl) {
        if (url.pathname === "/auth/v1/user" && request.method === "GET") {
          return response({
            id: fixture.profile_id,
            aud: "authenticated",
            role: "authenticated",
            app_metadata: {},
            user_metadata: {},
            created_at: fixture.created_at,
          });
        }
        if (
          url.pathname === "/rest/v1/payment_intents" &&
          request.method === "GET"
        ) {
          assert.equal(
            url.searchParams.get("profile_id"),
            `eq.${fixture.profile_id}`,
          );
          if (state.startsWith("NO_ID")) {
            assert.equal(url.searchParams.get("purpose"), "eq.SOLO_BOOKING");
            assert.equal(
              url.searchParams.get("payload->>game_id"),
              `eq.${fixture.payload.game_id}`,
            );
            // Solo lease identity is game-scoped; the complete normalized
            // payload (including role) is checked before provider access.
            assert.equal(url.searchParams.get("payload->>role"), null);
            assert.equal(url.searchParams.get("limit"), "1");
            assert.equal(url.searchParams.get("order"), "created_at.desc");
          } else assert.equal(url.searchParams.get("id"), `eq.${fixture.id}`);
          return response(state === "FOREIGN" ? null : local);
        }
        if (
          url.pathname === "/rest/v1/rpc/preview_open_queue_booking_cost" &&
          request.method === "POST"
        ) {
          assert.deepEqual(await request.json(), {
            game_id_to_book: fixture.payload.game_id,
            role_to_book: fixture.payload.role,
          });
          return response(fixture.quote_snapshot);
        }
      }
      if (
        url.hostname === "api.stripe.com" && request.method === "GET" &&
        url.pathname === "/v1/payment_intents/pi_resume"
      ) {
        if (state === "PROVIDER_ERROR") {
          return response({ error: { type: "invalid_request_error" } }, 400);
        }
        return response({
          id: local.provider_intent_id,
          object: "payment_intent",
          amount: 1300,
          amount_received: 0,
          currency: "usd",
          livemode: false,
          status: "requires_payment_method",
          capture_method: "automatic",
          payment_method_types: ["card"],
          metadata: stripeMetadata(local),
          client_secret: "pi_resume_secret_fixture",
        });
      }
      unexpected.push(`${request.method} ${url.origin}${url.pathname}`);
      throw new Error("Unexpected offline resume request.");
    };
    try {
      const result = await handlePayment(
        new Request("http://offline.invalid/stripe-payment", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${crypto.randomUUID()}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            ...body,
            ...(state.startsWith("NO_ID") ? { intent_id: undefined } : {}),
          }),
        }),
      );
      const actual = await result.json();
      assert.equal(
        result.status,
        state === "FOREIGN" ? 404 : state === "PROVIDER_ERROR" ? 503 : 200,
      );
      if (state === "UNPAID" || state === "NO_ID_UNPAID") {
        assert.equal(actual.status, "COLLECTABLE");
        assert.equal(actual.intent_id, fixture.id);
        assert.equal(actual.client_secret, "pi_resume_secret_fixture");
      } else {
        assert.equal(actual.client_secret, undefined);
      }
      if (state.includes("UNKNOWN") || state === "FOREIGN") {
        assert.equal(
          calls.filter((call) => call.includes("/v1/payment_intents/pi_resume"))
            .length,
          0,
        );
      }
      assert.equal(
        calls.filter((call) =>
          call.startsWith("POST") &&
          !call.endsWith("/preview_open_queue_booking_cost")
        ).length,
        0,
      );
      assert.deepEqual(unexpected, []);
    } finally {
      globalThis.fetch = originalFetch;
      Deno.env.get = originalEnvGet;
      console.error = originalConsoleError;
    }
  });
}
