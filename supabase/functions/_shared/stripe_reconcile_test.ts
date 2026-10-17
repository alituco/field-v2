import { strict as assert } from "node:assert";
import { PaymentIntent, stripeMetadata } from "./stripe_checkout.ts";
import { handleReconcile } from "./stripe_payment_handler.ts";
import { fieldStagingSupabaseUrl } from "./staging_guard.ts";

type PollIntent = PaymentIntent & {
  updated_at: string;
  provider_status: string;
};

function fixture(index: number, status = "PENDING"): PollIntent {
  const id = (value: number) =>
    `fe164000-0000-4000-8000-${String(value).padStart(12, "0")}`;
  return {
    id: id(index + 1),
    profile_id: id(index + 101),
    provider: "STRIPE",
    purpose: "SOLO_BOOKING",
    status,
    currency: "USD",
    amount_fils: 8000,
    amount_minor: 800,
    payload: { game_id: id(999), role: "DEF" },
    quote_snapshot: { total_fils: 8000, currency: "USD" },
    transaction_reference: `offline-poll-${index}`,
    provider_intent_id: `pi_offlinePoll${index}`,
    provider_payment_id: null,
    provider_status: "processing",
    payment_method: "CARD",
    resource_type: null,
    resource_id: null,
    created_at: "2026-01-01T00:00:00.000Z",
    expires_at: "2099-01-01T00:00:00.000Z",
    updated_at: new Date(Date.UTC(2026, 0, 1, 0, index)).toISOString(),
  };
}

// Exercise the actual HTTP handler, Supabase query construction, and Stripe
// client with an allowlisted in-memory transport. No environment/net permission
// or provider/database credentials are available to these tests.
async function offline(
  rows: PollIntent[],
  run: (harness: {
    invoke: () => Promise<{ status: number; body: Record<string, unknown> }>;
    batches: string[][];
    retrieved: string[];
    scheduling: string[];
    captureCalls: string[];
    calls: string[];
  }) => Promise<void>,
  options: {
    paymentStatus?: string;
    providerFails?: boolean;
    schedulingFails?: boolean;
    beforeScheduling?: (row: PollIntent) => void;
  } = {},
) {
  const originalFetch = globalThis.fetch;
  const originalEnvGet = Deno.env.get;
  const originalConsoleError = console.error;
  const secret = crypto.randomUUID() + crypto.randomUUID();
  const values: Record<string, string> = {
    STRIPE_RECONCILE_SECRET: secret,
    SUPABASE_URL: fieldStagingSupabaseUrl,
    SUPABASE_ANON_KEY: crypto.randomUUID(),
    SUPABASE_SERVICE_ROLE_KEY: crypto.randomUUID(),
    STRIPE_SECRET_KEY: `sk_test_${crypto.randomUUID().replaceAll("-", "")}`,
    FIELD_ENVIRONMENT: "staging",
  };
  const batches: string[][] = [];
  const retrieved: string[] = [];
  const scheduling: string[] = [];
  const captureCalls: string[] = [];
  const calls: string[] = [];
  const unexpected: string[] = [];
  let databaseClock = Date.now();
  const dbNow = () => new Date(++databaseClock).toISOString();
  const response = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  function matching(url: URL, row: PollIntent) {
    for (const [field, filter] of url.searchParams) {
      if (!["id", "provider", "status"].includes(field)) continue;
      const actual = row[field as keyof PollIntent];
      if (filter.startsWith("eq.") && actual !== filter.slice(3)) return false;
      if (
        filter.startsWith("in.(") &&
        !filter.slice(4, -1).split(",").includes(String(actual))
      ) return false;
    }
    return true;
  }
  Deno.env.get = (key: string) => values[key];
  console.error = () => {};
  globalThis.fetch = async (input, init) => {
    const request = input instanceof Request ? input : new Request(input, init);
    const url = new URL(request.url);
    const path = url.pathname;
    calls.push(`${request.method} ${path}`);
    if (
      url.hostname === "api.stripe.com" && request.method === "GET" &&
      /^\/v1\/payment_intents\/pi_offlinePoll\d+$/.test(path)
    ) {
      const row = rows.find((item) =>
        path.endsWith(`/${item.provider_intent_id}`)
      );
      assert.ok(row);
      retrieved.push(row.id);
      // Every provider attempt must already have yielded its scheduling slot.
      assert.ok(scheduling.includes(row.id));
      if (options.providerFails) {
        return response({ error: { type: "invalid_request_error" } }, 400);
      }
      const status = options.paymentStatus ?? "succeeded";
      return response({
        id: row.provider_intent_id,
        object: "payment_intent",
        amount: 800,
        amount_received: status === "succeeded" ? 800 : 0,
        currency: "usd",
        livemode: false,
        status,
        capture_method: "automatic",
        payment_method_types: ["card"],
        latest_charge: status === "succeeded"
          ? {
            id: `ch_offlinePoll${rows.indexOf(row)}`,
            payment_method_details: { card: { brand: "visa" } },
          }
          : null,
        metadata: stripeMetadata(row),
      });
    }
    if (url.origin === fieldStagingSupabaseUrl) {
      if (path === "/rest/v1/rpc/claim_payment_refunds") {
        assert.equal(request.method, "POST");
        assert.deepEqual(await request.json(), {
          batch_size: 10,
          intent_id_to_claim: null,
        });
        // Existing failed/manual-review refunds are not claimable.
        return response([]);
      }
      if (path === "/rest/v1/payment_webhook_events") return response([]);
      if (path === "/rest/v1/rpc/record_stripe_payment_capture") {
        const body = await request.json();
        const row = rows.find((item) => item.id === body.intent_id_to_capture);
        assert.ok(row);
        captureCalls.push(row.id);
        row.status = "FINALIZED";
        row.updated_at = dbNow();
        return response({ status: "FINALIZED", intent_id: row.id });
      }
      if (path === "/rest/v1/payment_intents") {
        if (request.method === "PATCH") {
          const body = await request.json();
          const isScheduling = Object.hasOwn(body, "updated_at");
          if (isScheduling) {
            assert.deepEqual(Object.keys(body), ["updated_at"]);
            assert.equal(url.searchParams.get("provider"), "eq.STRIPE");
            assert.equal(
              url.searchParams.get("status"),
              "in.(PENDING,CAPTURED)",
            );
            assert.equal(url.searchParams.get("select"), "id");
            const target = rows.find((row) =>
              url.searchParams.get("id") === `eq.${row.id}`
            );
            assert.ok(target);
            options.beforeScheduling?.(target);
            if (options.schedulingFails) {
              return response({ code: "OFFLINE_DATABASE_ERROR" }, 503);
            }
          } else {
            assert.deepEqual(body, { provider_status: "processing" });
            assert.equal(url.searchParams.get("status"), "eq.PENDING");
          }
          const matched = rows.filter((row) => matching(url, row));
          for (const row of matched) {
            if (isScheduling) scheduling.push(row.id);
            Object.assign(row, body, { updated_at: dbNow() });
          }
          return response(matched.map((row) => ({ id: row.id })));
        }
        assert.equal(request.method, "GET");
        assert.equal(url.searchParams.get("provider"), "eq.STRIPE");
        assert.equal(url.searchParams.get("limit"), "10");
        assert.equal(url.searchParams.get("order"), "updated_at.asc,id.asc");
        const batch = rows.filter((row) => matching(url, row)).sort((a, b) =>
          a.updated_at.localeCompare(b.updated_at) || a.id.localeCompare(b.id)
        ).slice(0, 10);
        batches.push(batch.map((row) => row.id));
        return response(batch);
      }
    }
    unexpected.push(`${request.method} ${url.origin}${path}`);
    throw new Error("Unexpected offline test request.");
  };
  try {
    await run({
      invoke: async () => {
        const result = await handleReconcile(
          new Request("http://offline.invalid/stripe-reconcile", {
            method: "POST",
            headers: { Authorization: `Bearer ${secret}` },
          }),
        );
        return { status: result.status, body: await result.json() };
      },
      batches,
      retrieved,
      scheduling,
      captureCalls,
      calls,
    });
    assert.deepEqual(unexpected, []);
  } finally {
    globalThis.fetch = originalFetch;
    Deno.env.get = originalEnvGet;
    console.error = originalConsoleError;
  }
}

Deno.test("reconcile fallback reaches newer checkout past ten refund-review no-ops", async () => {
  const refunds = Array.from(
    { length: 10 },
    (_, index) => fixture(index, "REQUIRES_REFUND"),
  );
  const before = structuredClone(refunds);
  const rows = [...refunds, fixture(10)];
  await offline(rows, async (harness) => {
    for (let pass = 0; pass < 3; pass++) {
      const result = await harness.invoke();
      assert.equal(result.status, 200);
      assert.deepEqual(result.body.refunds, {
        checked: 0,
        completed: 0,
        pending: 0,
      });
    }
    assert.deepEqual(harness.batches, [[rows[10].id], [], []]);
    assert.deepEqual(harness.retrieved, [rows[10].id]);
    assert.deepEqual(harness.captureCalls, [rows[10].id]);
    assert.deepEqual(rows.slice(0, 10), before);
    assert.equal(rows[10].status, "FINALIZED");
    assert.equal(harness.calls[0], "POST /rest/v1/rpc/claim_payment_refunds");
  });
});

for (const status of ["PENDING", "CAPTURED"]) {
  Deno.test(`reconcile rotates successful unresolved ${status} polls across bounded passes`, async () => {
    const rows = Array.from(
      { length: 21 },
      (_, index) => fixture(index, status),
    );
    const initial = structuredClone(rows);
    await offline(rows, async (harness) => {
      for (let pass = 0; pass < 3; pass++) {
        const result = await harness.invoke();
        assert.equal(result.status, 200);
        assert.equal(result.body.reconciled, 10);
      }
      assert.equal(new Set(harness.retrieved).size, rows.length);
      assert.deepEqual(
        harness.batches[0],
        initial.slice(0, 10).map((row) => row.id),
      );
      assert.deepEqual(
        harness.batches[1],
        initial.slice(10, 20).map((row) => row.id),
      );
      assert.equal(harness.batches[2][0], initial[20].id);
      assert.equal(harness.captureCalls.length, 0);
      for (let index = 0; index < rows.length; index++) {
        assert.deepEqual(
          { ...rows[index], updated_at: initial[index].updated_at },
          initial[index],
        );
      }
    }, { paymentStatus: "processing" });
  });
}

Deno.test("reconcile rotates provider failures without changing payment state", async () => {
  const rows = Array.from({ length: 11 }, (_, index) => fixture(index));
  const initial = structuredClone(rows);
  await offline(rows, async (harness) => {
    for (let pass = 0; pass < 2; pass++) {
      const result = await harness.invoke();
      assert.equal(result.status, 200);
      assert.equal(result.body.reconciled, 0);
    }
    assert.equal(new Set(harness.retrieved).size, rows.length);
    assert.equal(harness.batches[1][0], rows[10].id);
    for (let index = 0; index < rows.length; index++) {
      assert.deepEqual(
        { ...rows[index], updated_at: initial[index].updated_at },
        initial[index],
      );
    }
  }, { providerFails: true });
});

Deno.test("reconcile skips a checkout concurrently transferred to refund ownership", async () => {
  const row = fixture(0);
  const initialTimestamp = row.updated_at;
  await offline([row], async (harness) => {
    const result = await harness.invoke();
    assert.equal(result.status, 200);
    assert.equal(result.body.reconciled, 0);
    assert.deepEqual(harness.scheduling, []);
    assert.deepEqual(harness.retrieved, []);
    assert.equal(row.status, "REQUIRES_REFUND");
    assert.equal(row.updated_at, initialTimestamp);
  }, { beforeScheduling: (current) => current.status = "REQUIRES_REFUND" });
});

Deno.test("reconcile fails closed before provider polling if scheduling write fails", async () => {
  const rows = [fixture(0)];
  const initial = structuredClone(rows);
  await offline(rows, async (harness) => {
    const result = await harness.invoke();
    assert.equal(result.status, 503);
    assert.deepEqual(result.body, {
      error: "Payment reconciliation could not finish.",
    });
    assert.deepEqual(harness.retrieved, []);
    assert.deepEqual(rows, initial);
  }, { schedulingFails: true });
});
