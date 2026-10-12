import { strict as assert } from "node:assert";
import {
  assertStagingE2EActor,
  assertStagingE2EGame,
  deadlineFetch,
  expectedLiveMode,
  normalizedCheckout,
  PaymentDatabase,
  PaymentIntent,
  processRefunds,
  reconcilePayment,
  Stripe,
  stripeAmountMinor,
  stripeClient,
  stripeMetadata,
  verifyStripePayment,
  verifyStripeRefund,
  verifyWebhook,
} from "./stripe_checkout.ts";
import {
  canReuseSoloCheckoutQuote,
  prepareCheckout,
} from "./stripe_payment_handler.ts";

const intent: PaymentIntent = {
  id: "a5287b6a-22f6-4e55-a230-5582f8ebf0b4",
  profile_id: "b5287b6a-22f6-4e55-a230-5582f8ebf0b4",
  provider: "STRIPE",
  purpose: "SOLO_BOOKING",
  status: "PENDING",
  currency: "USD",
  amount_fils: 13_000,
  amount_minor: 1300,
  payload: { game_id: "c5287b6a-22f6-4e55-a230-5582f8ebf0b4", role: "DEF" },
  quote_snapshot: { total_fils: 13_000, currency: "USD" },
  transaction_reference: "fieldrush_test",
  provider_intent_id: "pi_test",
  provider_payment_id: null,
  payment_method: null,
  resource_type: null,
  resource_id: null,
  expires_at: "2030-01-01T00:00:00Z",
  created_at: "2026-10-10T00:00:00Z",
};

function payment(
  overrides: Record<string, unknown> = {},
): Stripe.PaymentIntent {
  return {
    id: "pi_test",
    object: "payment_intent",
    amount: 1300,
    amount_received: 1300,
    currency: "usd",
    livemode: false,
    metadata: stripeMetadata(intent),
    status: "succeeded",
    capture_method: "automatic",
    payment_method_types: ["card"],
    latest_charge: {
      id: "ch_test",
      payment_method_details: {
        card: { brand: "visa", wallet: { type: "apple_pay" } },
      },
    },
    ...overrides,
  } as unknown as Stripe.PaymentIntent;
}

Deno.test("quote precision converts $13 to 1300 cents without rounding", () => {
  assert.equal(stripeAmountMinor(13000, "USD"), 1300);
  assert.throws(() => stripeAmountMinor(3000, "BHD"), /retired currency/);
  for (const value of [0, -10, 1.2, 13001, NaN, Infinity, "13000"]) {
    assert.throws(() => stripeAmountMinor(value, "USD"));
  }
  assert.throws(() => stripeAmountMinor(3001, "BHD"));
  assert.throws(() => stripeAmountMinor(13000, "EUR"));
});

Deno.test("staging cannot accept live keys and production cannot accept test keys", () => {
  assert.equal(expectedLiveMode("sk_test_placeholder", "staging"), false);
  assert.equal(expectedLiveMode("rk_test_placeholder", "local"), false);
  assert.equal(expectedLiveMode("sk_live_placeholder", "production"), true);
  for (
    const [key, environment] of [
      ["sk_live_placeholder", "staging"],
      ["sk_test_placeholder", "production"],
      ["pk_test_placeholder", "staging"],
      ["sk_test_placeholder", ""],
    ]
  ) {
    assert.throws(() => expectedLiveMode(key, environment));
  }
});

Deno.test("synthetic checkout requires protected app metadata for the exact staging run", () => {
  const config = {
    url: "https://nfdkdhdevpstfspazbfn.supabase.co",
    environment: "staging",
    dev: "true",
    livemode: false,
    runId: "run-1",
    appMetadata: {
      fieldrush_e2e: true,
      fieldrush_e2e_role: "player",
      fieldrush_e2e_run_id: "run-1",
    },
  };
  assertStagingE2EActor(config);
  for (
    const invalid of [
      { appMetadata: undefined },
      { appMetadata: { field_e2e: true } },
      {
        appMetadata: {
          ...config.appMetadata,
          fieldrush_e2e_run_id: "another-run",
        },
      },
      {
        appMetadata: { ...config.appMetadata, fieldrush_e2e_role: "bootstrap" },
      },
      { environment: "production" },
      { livemode: true },
      { dev: "false" },
      { url: "https://zjsjuuhborxrlmdcpvlj.supabase.co" },
    ]
  ) assert.throws(() => assertStagingE2EActor({ ...config, ...invalid }));
});

Deno.test("checkout ignores client amounts, normalizes role and validates references", () => {
  assert.deepEqual(
    normalizedCheckout({
      purpose: "solo_booking",
      payload: {
        ...intent.payload,
        role: "def",
        amount_fils: 1,
        currency: "BHD",
        profile_id: "attacker",
      },
    }),
    {
      purpose: "SOLO_BOOKING",
      payload: intent.payload,
    },
  );
  assert.throws(() =>
    normalizedCheckout({
      purpose: "SOLO_BOOKING",
      payload: { game_id: "invalid", role: "DEF" },
    })
  );
  assert.throws(() =>
    normalizedCheckout({
      purpose: "SOLO_BOOKING",
      payload: { ...intent.payload, role: "ANY" },
    })
  );
});

Deno.test("E2E venue truncation stays bound to the full protected creator run", () => {
  const runId = "manual-long-run-abcdefghijklmnopqrstuvwxyz-1234567890";
  const creatorMetadata = {
    fieldrush_e2e: true,
    fieldrush_e2e_role: "admin",
    fieldrush_e2e_run_id: runId,
  };
  const venue = `[FIELD E2E ${runId.slice(0, 28)}] Match`;
  assertStagingE2EGame({ runId, venue, creatorMetadata });
  assert.throws(() =>
    assertStagingE2EGame({
      runId,
      venue,
      creatorMetadata: {
        ...creatorMetadata,
        fieldrush_e2e_run_id: `${runId}x`,
      },
    })
  );
  assert.throws(() =>
    assertStagingE2EGame({
      runId,
      venue,
      creatorMetadata: { ...creatorMetadata, fieldrush_e2e_role: "player" },
    })
  );
  assert.throws(() =>
    assertStagingE2EGame({ runId, venue, creatorMetadata: undefined })
  );
  assert.throws(() =>
    assertStagingE2EGame({
      runId,
      venue: "A normal staging game",
      creatorMetadata,
    })
  );
});

Deno.test("clan checkout preserves the venue and human-readable slot needed by booking", () => {
  const input = {
    purpose: "CLAN_CREATE",
    payload: {
      clan_id: intent.profile_id,
      venue: "North Field",
      match_date: "2030-01-01",
      time_slot: "8:30 PM - 9:30 PM",
    },
  };
  assert.deepEqual(normalizedCheckout(input), input);
  assert.throws(() =>
    normalizedCheckout({ ...input, payload: { ...input.payload, venue: "" } })
  );
});

Deno.test("receipt requires exact owner purpose amount currency reference and environment", () => {
  verifyStripePayment(payment(), intent, false);
  const mismatches = [
    { id: "pi_other" },
    { amount: 1 },
    { amount_received: 1299 },
    { currency: "bhd" },
    { livemode: true },
    { capture_method: "manual" },
    { payment_method_types: ["card", "klarna"] },
    ...Object.keys(stripeMetadata(intent)).map((key) => ({
      metadata: { ...stripeMetadata(intent), [key]: "wrong" },
    })),
  ];
  for (const mismatch of mismatches) {
    assert.throws(() => verifyStripePayment(payment(mismatch), intent, false));
  }
  assert.throws(() =>
    verifyStripePayment(
      payment(),
      { ...intent, provider: "STAGING_E2E" },
      false,
    )
  );
});

async function signature(body: string, timestamp: number, secret: string) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${timestamp}.${body}`),
  );
  return `t=${timestamp},v1=${
    Array.from(new Uint8Array(bytes), (byte) =>
      byte.toString(16).padStart(2, "0")).join("")
  }`;
}

Deno.test("webhook validates original raw bytes and rejects replay or future timestamps", async () => {
  const stripe = stripeClient("sk_test_placeholder");
  const raw = JSON.stringify({
    id: "evt_test",
    object: "event",
    type: "payment_intent.succeeded",
    livemode: false,
    data: { object: payment() },
  });
  const now = 1800000000;
  const valid = await signature(raw, now, "whsec_placeholder");
  assert.equal(
    (await verifyWebhook(stripe, raw, valid, "whsec_placeholder", now)).id,
    "evt_test",
  );
  await assert.rejects(() =>
    verifyWebhook(stripe, raw + " ", valid, "whsec_placeholder", now)
  );
  await assert.rejects(() =>
    verifyWebhook(stripe, raw, valid, "whsec_wrong", now)
  );
  await assert.rejects(() =>
    verifyWebhook(stripe, raw, valid, "whsec_placeholder", now + 301)
  );
  await assert.rejects(() =>
    verifyWebhook(stripe, raw, valid, "whsec_placeholder", now - 301)
  );
});

Deno.test("client confirm and webhook capture converge on the same locked database operation", async () => {
  let calls = 0;
  const admin = {
    rpc(name: string, args: Record<string, unknown>) {
      assert.equal(name, "record_stripe_payment_capture");
      assert.equal(args.intent_id_to_capture, intent.id);
      assert.equal(args.amount_minor_to_use, 1300);
      assert.equal(args.payment_method_to_use, "APPLE_PAY");
      calls++;
      return Promise.resolve({
        data: { status: "FINALIZED", resource_id: "same-booking" },
        error: null,
      });
    },
  } as unknown as PaymentDatabase;
  const stripe = {
    paymentIntents: { retrieve: () => Promise.resolve(payment()) },
  } as unknown as Stripe;
  const results = await Promise.all([
    reconcilePayment(admin, stripe, intent, false),
    reconcilePayment(admin, stripe, intent, false, payment()),
  ]);
  assert.equal(calls, 2);
  assert.equal(results[0].resource_id, results[1].resource_id);
});

Deno.test("mismatched capture never reaches finalization", async () => {
  const admin = {
    rpc: () => {
      throw new Error("must not call database");
    },
  } as unknown as PaymentDatabase;
  const stripe = {} as Stripe;
  await assert.rejects(
    () =>
      reconcilePayment(
        admin,
        stripe,
        intent,
        false,
        payment({ amount_received: 1 }),
      ),
    /amount/,
  );
});

Deno.test("infrastructure finalization failure stays retryable and does not fabricate refund", async () => {
  const admin = {
    rpc: () =>
      Promise.resolve({
        data: null,
        error: { code: "08006", message: "connection interrupted" },
      }),
  } as unknown as PaymentDatabase;
  await assert.rejects(() =>
    reconcilePayment(admin, {} as Stripe, intent, false, payment())
  );
});

const refundRow = {
  id: "refund-row",
  intent_id: intent.id,
  provider_intent_id: "pi_test",
  amount_minor: 650,
  currency: "USD",
  provider_refund_id: null as string | null,
  retry_generation: 0,
};
function refund(overrides: Record<string, unknown> = {}): Stripe.Refund {
  return {
    id: "re_test",
    object: "refund",
    payment_intent: "pi_test",
    amount: 650,
    currency: "usd",
    status: "succeeded",
    metadata: {
      field_refund_id: "refund-row",
      field_payment_intent_id: intent.id,
      field_refund_attempt: "0",
    },
    ...overrides,
  } as unknown as Stripe.Refund;
}

Deno.test("partial refunds verify exact amount and recipient payment", () => {
  verifyStripeRefund(refund(), refundRow, false);
  for (
    const mismatch of [{ amount: 1300 }, { payment_intent: "pi_other" }, {
      currency: "bhd",
    }, { metadata: {} }]
  ) {
    assert.throws(() => verifyStripeRefund(refund(mismatch), refundRow, false));
  }
});

function refundDatabase(
  finish: (args: Record<string, unknown>) => void,
  row = refundRow,
  external?: (args: Record<string, unknown>) => void,
  finishResult: Record<string, unknown> = {},
) {
  return {
    rpc(name: string, args: Record<string, unknown>) {
      if (name === "claim_payment_refunds") {
        return Promise.resolve({ data: [row], error: null });
      }
      if (name === "record_external_stripe_refund") {
        assert.ok(external, "Unexpected external refund import");
        external(args);
        return Promise.resolve({ data: {}, error: null });
      }
      assert.equal(name, "finish_payment_refund");
      finish(args);
      return Promise.resolve({ data: finishResult, error: null });
    },
    from() {
      const chain = {
        select: () => chain,
        eq: () => chain,
        maybeSingle: () => Promise.resolve({ data: intent, error: null }),
        then: (resolve: (value: unknown) => unknown) =>
          Promise.resolve({ data: [row], error: null }).then(resolve),
      };
      return chain;
    },
  } as unknown as PaymentDatabase;
}

Deno.test("refund retry recovers accepted refund after lost response without creating another", async () => {
  let creates = 0;
  const stripe = {
    paymentIntents: { retrieve: () => Promise.resolve(payment()) },
    refunds: {
      list: () => ({
        async *[Symbol.asyncIterator]() {
          yield refund();
        },
      }),
      create: () => {
        creates++;
        return Promise.resolve(refund());
      },
    },
  } as unknown as Stripe;
  const result = await processRefunds(
    refundDatabase((args) => {
      assert.equal(args.provider_refund_id_to_use, "re_test");
      assert.equal(args.provider_status_to_use, "succeeded");
    }),
    stripe,
    false,
  );
  assert.equal(creates, 0);
  assert.equal(result.completed, 1);
});

Deno.test("dashboard refund is recorded and prevents a second automatic money movement", async () => {
  let imports = 0;
  let creates = 0;
  const stripe = {
    paymentIntents: { retrieve: () => Promise.resolve(payment()) },
    refunds: {
      list: () => ({
        async *[Symbol.asyncIterator]() {
          yield refund({ id: "re_dashboard", metadata: {} });
        },
      }),
      create: () => {
        creates++;
        return Promise.resolve(refund());
      },
    },
  } as unknown as Stripe;
  const result = await processRefunds(
    refundDatabase(
      () => {
        assert.fail("An unissued refund under review must not be finalized.");
      },
      refundRow,
      (args) => {
        imports++;
        assert.equal(args.intent_id_to_use, intent.id);
        assert.equal(args.provider_refund_id_to_use, "re_dashboard");
        assert.equal(args.amount_minor_to_use, 650);
        assert.equal(args.currency_to_use, "USD");
        assert.equal(args.provider_status_to_use, "succeeded");
      },
    ),
    stripe,
    false,
  );
  assert.equal(imports, 1);
  assert.equal(creates, 0);
  assert.equal(result.pending, 1);
});

Deno.test("failed dashboard refund is audited without falsely treating money as returned", async () => {
  let imports = 0;
  let creates = 0;
  const stripe = {
    paymentIntents: { retrieve: () => Promise.resolve(payment()) },
    refunds: {
      list: () => ({
        async *[Symbol.asyncIterator]() {
          yield refund({ id: "re_dashboard", metadata: {}, status: "failed" });
        },
      }),
      create: () => {
        creates++;
        return Promise.resolve(refund());
      },
    },
  } as unknown as Stripe;
  const result = await processRefunds(
    refundDatabase(() => {}, refundRow, (args) => {
      imports++;
      assert.equal(args.provider_status_to_use, "failed");
    }),
    stripe,
    false,
  );
  assert.equal(imports, 1);
  assert.equal(creates, 1);
  assert.equal(result.completed, 1);
});

Deno.test("an already-issued refund still settles when a dashboard refund needs review", async () => {
  let imports = 0;
  const stripe = {
    paymentIntents: { retrieve: () => Promise.resolve(payment()) },
    refunds: {
      list: () => ({
        async *[Symbol.asyncIterator]() {
          yield refund({ id: "re_dashboard", metadata: {}, amount: 100 });
          yield refund();
        },
      }),
      retrieve: () => Promise.resolve(refund()),
      create: () =>
        assert.fail(
          "Existing refunds must never create another charge return.",
        ),
    },
  } as unknown as Stripe;
  const result = await processRefunds(
    refundDatabase(
      (args) => {
        assert.equal(args.provider_refund_id_to_use, "re_test");
      },
      { ...refundRow, provider_refund_id: "re_test" as string | null },
      () => {
        imports++;
      },
    ),
    stripe,
    false,
  );
  assert.equal(imports, 1);
  assert.equal(result.completed, 1);
});

Deno.test("an expired worker deadline never leases work or starts another fetch", async () => {
  const expired = Date.now() - 1;
  const result = await processRefunds(
    {
      rpc: () => assert.fail("Expired worker claimed work"),
    } as unknown as PaymentDatabase,
    {} as Stripe,
    false,
    3,
    null,
    expired,
  );
  assert.deepEqual(result, { checked: 0, completed: 0, pending: 0 });
  await assert.rejects(deadlineFetch(expired)("https://example.invalid"), {
    name: "AbortError",
  });
});

Deno.test("a fenced stale refund attempt does not report a completed transfer", async () => {
  const stripe = {
    paymentIntents: { retrieve: () => Promise.resolve(payment()) },
    refunds: {
      list: () => ({
        async *[Symbol.asyncIterator]() {
          yield refund();
        },
      }),
    },
  } as unknown as Stripe;
  const result = await processRefunds(
    refundDatabase(() => {}, refundRow, undefined, { stale: true }),
    stripe,
    false,
  );
  assert.equal(result.completed, 0);
  assert.equal(result.pending, 1);
});

Deno.test("new partial refund uses persistent outbox idempotency and exact original payment", async () => {
  const stripe = {
    paymentIntents: { retrieve: () => Promise.resolve(payment()) },
    refunds: {
      list: () => ({ async *[Symbol.asyncIterator]() {} }),
      create: (
        params: Record<string, unknown>,
        options: Record<string, unknown>,
      ) => {
        assert.equal(params.payment_intent, "pi_test");
        assert.equal(params.amount, 650);
        assert.equal(options.idempotencyKey, "fieldrush-refund-refund-row-0");
        return Promise.resolve(refund({ status: "pending" }));
      },
    },
  } as unknown as Stripe;
  const result = await processRefunds(
    refundDatabase((args) =>
      assert.equal(args.provider_status_to_use, "pending")
    ),
    stripe,
    false,
  );
  assert.equal(result.completed, 0);
  assert.equal(result.pending, 1);
});

Deno.test("approved retry cannot reuse the previous failed Stripe refund", async () => {
  let creates = 0;
  const retryRow = { ...refundRow, retry_generation: 1 };
  const stripe = {
    paymentIntents: { retrieve: () => Promise.resolve(payment()) },
    refunds: {
      list: () => ({
        async *[Symbol.asyncIterator]() {
          yield refund({ status: "failed" });
        },
      }),
      create: (
        params: Record<string, unknown>,
        options: Record<string, unknown>,
      ) => {
        creates++;
        assert.equal(options.idempotencyKey, "fieldrush-refund-refund-row-1");
        return Promise.resolve(refund({ metadata: params.metadata }));
      },
    },
  } as unknown as Stripe;
  const result = await processRefunds(
    refundDatabase((args) => {
      assert.equal(args.retry_generation_to_use, 1);
    }, retryRow),
    stripe,
    false,
  );
  assert.equal(creates, 1);
  assert.equal(result.completed, 1);
});

Deno.test("refund batches bound concurrency and leave unstarted leases retryable at the deadline", async () => {
  const rows = Array.from(
    { length: 8 },
    (_, index) => ({ ...refundRow, id: `refund-${index}` }),
  );
  let active = 0;
  let maximum = 0;
  let now = 100;
  let finishCount = 0;
  const originalNow = Date.now;
  const database = refundDatabase(() => {
    finishCount++;
    now = 300;
  });
  const originalRpc = database.rpc.bind(database);
  const admin = {
    from: database.from.bind(database),
    rpc: (name: string, args: Record<string, unknown>) =>
      name === "claim_payment_refunds"
        ? Promise.resolve({ data: rows, error: null })
        : originalRpc(name, args),
  } as unknown as PaymentDatabase;
  const stripe = {
    paymentIntents: {
      retrieve: async () => {
        active++;
        maximum = Math.max(maximum, active);
        await Promise.resolve();
        active--;
        return payment();
      },
    },
    refunds: {
      list: () => ({ async *[Symbol.asyncIterator]() {} }),
      create: (params: { metadata: Record<string, string> }) =>
        Promise.resolve(refund({
          id: `re_${params.metadata.field_refund_id}`,
          metadata: params.metadata,
        })),
    },
  } as unknown as Stripe;
  try {
    Date.now = () => now;
    const result = await processRefunds(admin, stripe, false, 8, null, 200);
    assert.equal(maximum, 3);
    assert.equal(finishCount, 3);
    assert.deepEqual(result, { checked: 3, completed: 3, pending: 0 });
  } finally {
    Date.now = originalNow;
  }
});

function checkoutContext(options: {
  pending?: boolean;
  pendingIntent?: PaymentIntent;
  providerPayment?: Stripe.PaymentIntent;
  allowPendingQuote?: boolean;
  quote?: Record<string, unknown>;
  quoteError?: string;
  freeBooking?: Record<string, unknown>;
}) {
  let captured = false;
  const admin = {
    from(table: string) {
      let statuses: string[] | undefined;
      const filters: Record<string, unknown> = {};
      const chain = {
        select: () => chain,
        eq: (column: string, value: unknown) => {
          filters[column] = value;
          return chain;
        },
        in: (_column: string, values: string[]) => {
          statuses = values;
          return chain;
        },
        order: () => chain,
        limit: () => chain,
        maybeSingle: () =>
          Promise.resolve({
            data: table === "open_queue_bookings"
              ? options.freeBooking && Object.entries(filters).every(
                  ([key, value]) => options.freeBooking?.[key] === value,
                )
                ? options.freeBooking
                : null
              : statuses
              ? (statuses.includes("PENDING") && options.pending
                ? options.pendingIntent ?? intent
                : null)
              : { ...intent, status: captured ? "REQUIRES_REFUND" : "PENDING" },
            error: null,
          }),
        then: (resolve: (value: unknown) => unknown) => {
          assert.equal(table, "payment_refunds");
          return Promise.resolve({ data: [{ status: "PENDING" }], error: null })
            .then(resolve);
        },
        insert: () => assert.fail("No new checkout should be created."),
      };
      return chain;
    },
    rpc(name: string) {
      assert.equal(name, "record_stripe_payment_capture");
      captured = true;
      return Promise.resolve({
        data: { status: "REQUIRES_REFUND", intent_id: intent.id },
        error: null,
      });
    },
  };
  return {
    admin,
    userId: intent.profile_id,
    authUser: {},
    url: "https://example.invalid",
    anonKey: "unused",
    livemode: false,
    user: {
      rpc: () => {
        if (options.pending && !options.allowPendingQuote) {
          assert.fail(
            "A successful pending provider payment must reconcile before re-quoting an unavailable game.",
          );
        }
        return Promise.resolve({
          data: options.quote ?? null,
          error: options.quoteError ? { message: options.quoteError } : null,
        });
      },
    },
    stripe: {
      paymentIntents: {
        retrieve: () => Promise.resolve(options.providerPayment ?? payment()),
      },
      refunds: {
        create: () =>
          assert.fail(
            "Confirm must enqueue refunds, not wait for money movement.",
          ),
      },
    },
  } as unknown as Parameters<typeof prepareCheckout>[0];
}

Deno.test("reconnecting after provider success reconciles before an unavailable-game quote", async () => {
  const result = await prepareCheckout(checkoutContext({ pending: true }), {
    purpose: "SOLO_BOOKING",
    payload: intent.payload,
  });
  assert.equal(result.status, "REQUIRES_REFUND");
  assert.equal(result.refund_status, "PENDING");
});

Deno.test("free checkout reconnect returns only the caller's matching confirmed free booking", async () => {
  const freeBooking = {
    id: "free-booking",
    profile_id: intent.profile_id,
    game_id: intent.payload.game_id,
    role: intent.payload.role,
    status: "CONFIRMED",
    payment_method: "FREE",
  };
  const body = { purpose: "SOLO_BOOKING", payload: intent.payload };
  const result = await prepareCheckout(
    checkoutContext({
      freeBooking,
      quoteError: "Existing booking must return before quoting.",
    }),
    body,
  );
  assert.deepEqual(result, {
    status: "FINALIZED",
    intent_id: null,
    payment_method: "FREE",
    resource_type: "OPEN_QUEUE_BOOKING",
    resource_id: "free-booking",
  });
  for (
    const change of [
      { profile_id: "another-owner" },
      { game_id: "another-game" },
      { role: "GK" },
      { status: "CANCELLED" },
      { payment_method: "CARD" },
    ]
  ) {
    await assert.rejects(
      prepareCheckout(
        checkoutContext({
          freeBooking: { ...freeBooking, ...change },
          quoteError: "No matching free booking.",
        }),
        body,
      ),
      /No matching free booking/,
    );
  }
});

Deno.test("retired-currency quotes fail before creating an intent, including a free quote", async () => {
  for (const total_fils of [0, 13000]) {
    await assert.rejects(
      prepareCheckout(
        checkoutContext({ quote: { currency: "BHD", total_fils } }),
        {
          purpose: "SOLO_BOOKING",
          payload: intent.payload,
        },
      ),
      /retired currency/,
    );
  }
});

Deno.test("paused clan checkout fails at the authoritative quote before creating payment", async () => {
  await assert.rejects(
    prepareCheckout(
      checkoutContext({
        quoteError:
          "Clan games are currently paused. Please book a solo game instead.",
      }),
      {
        purpose: "CLAN_CREATE",
        payload: {
          clan_id: intent.profile_id,
          match_date: "2026-12-01",
          time_slot: "8:30 PM - 9:30 PM",
          venue: "Phoenix",
        },
      },
    ),
    /currently paused/,
  );
});

const fixedSoloQuote = {
  currency: "USD",
  policy_version_id: "f5287b6a-22f6-4e55-a230-5582f8ebf0b4",
  standard_match_fee_fils: 13000,
  replacement_discount_bps: 0,
  match_fee_fils: 13000,
  reliability_deposit_fils: 0,
  total_fils: 13000,
};

Deno.test("an unexpired solo PaymentSheet keeps its exact quote after a price increase, reduction or free conversion", async () => {
  for (const currentPrice of [16000, 9000, 0]) {
    const pendingIntent = {
      ...intent,
      quote_snapshot: fixedSoloQuote,
      expires_at: new Date(Date.now() + 600000).toISOString(),
    };
    const result = await prepareCheckout(
      checkoutContext({
        pending: true,
        pendingIntent,
        allowPendingQuote: true,
        quote: {
          ...fixedSoloQuote,
          standard_match_fee_fils: currentPrice,
          match_fee_fils: currentPrice,
          total_fils: currentPrice,
        },
        providerPayment: payment({
          status: "requires_payment_method",
          amount_received: 0,
          client_secret: "test_client_secret",
        }),
      }),
      { purpose: "SOLO_BOOKING", payload: intent.payload },
    );
    assert.equal(result.status, "PENDING");
    assert.equal(result.intent_id, intent.id);
    assert.equal(result.amount_fils, 13000);
    assert.equal(result.currency, "USD");
    // The mock has no cancellation/insertion APIs: invoking either also fails.
  }
});

Deno.test("price-locked checkout still rechecks current game availability before returning the payment sheet", async () => {
  await assert.rejects(
    prepareCheckout(
      checkoutContext({
        pending: true,
        pendingIntent: {
          ...intent,
          quote_snapshot: fixedSoloQuote,
          expires_at: new Date(Date.now() + 600000).toISOString(),
        },
        allowPendingQuote: true,
        quoteError: "This Open Queue game is no longer available.",
        providerPayment: payment({
          status: "requires_payment_method",
          amount_received: 0,
          client_secret: "test_client_secret",
        }),
      }),
      { purpose: "SOLO_BOOKING", payload: intent.payload },
    ),
    /no longer available/,
  );
});

Deno.test("expired, wrong-identity, retired-currency and malformed quotes cannot lock an old price", () => {
  const now = Date.now();
  const valid = {
    ...intent,
    quote_snapshot: fixedSoloQuote,
    expires_at: new Date(now + 600000).toISOString(),
  };
  assert.equal(
    canReuseSoloCheckoutQuote(
      valid,
      "SOLO_BOOKING",
      intent.payload,
      fixedSoloQuote,
      now,
    ),
    true,
  );
  for (
    const change of [
      { expires_at: new Date(now).toISOString() },
      { expires_at: "invalid" },
      { status: "EXPIRED" },
      { currency: "BHD" },
      { provider: "LEGACY" as const },
      { payload: { ...intent.payload, role: "GK" } },
      { amount_fils: 15000 },
      { quote_snapshot: { ...fixedSoloQuote, reliability_deposit_fils: 2000 } },
      { quote_snapshot: { ...fixedSoloQuote, match_fee_fils: -1000 } },
      { quote_snapshot: { ...fixedSoloQuote, total_fils: "13000" } },
      { quote_snapshot: { ...fixedSoloQuote, standard_match_fee_fils: 13001 } },
      {
        quote_snapshot: { ...fixedSoloQuote, replacement_discount_bps: 10001 },
      },
      { quote_snapshot: { ...fixedSoloQuote, policy_version_id: "different" } },
    ]
  ) {
    assert.equal(
      canReuseSoloCheckoutQuote(
        { ...valid, ...change },
        "SOLO_BOOKING",
        intent.payload,
        fixedSoloQuote,
        now,
      ),
      false,
    );
  }
  assert.equal(
    canReuseSoloCheckoutQuote(
      valid,
      "CLAN_JOIN",
      intent.payload,
      fixedSoloQuote,
      now,
    ),
    false,
  );
});
