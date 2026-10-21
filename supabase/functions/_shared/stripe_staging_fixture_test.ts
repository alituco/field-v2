import { strict as assert } from "node:assert";
import { createClient } from "npm:@supabase/supabase-js@2.86.0";
import {
  assertStagingE2EGameCreator,
  handlePayment,
} from "./stripe_payment_handler.ts";
import { fieldStagingSupabaseUrl } from "./staging_guard.ts";

const runId = "fixture-regression-long-run-12345678901234567890";
const gameId = "10000000-0000-4000-8000-000000000001";
const staffId = "20000000-0000-4000-8000-000000000002";
const authId = "30000000-0000-4000-8000-000000000003";

function fixture() {
  return {
    game: {
      venue: `[FIELD E2E ${runId.slice(0, 28)}] Match`,
      created_by_staff_id: staffId as string | null,
      created_by: null as string | null,
    },
    staff: {
      auth_user_id: authId as string | null,
      email: "fixture@example.invalid",
      role: "admin",
      is_active: true,
    },
    user: {
      id: authId,
      email: "fixture@example.invalid",
      phone: "",
      email_confirmed_at: "2026-01-01T00:00:00Z" as string | null,
      app_metadata: {
        fieldrush_account_type: "staff",
        fieldrush_e2e: true,
        fieldrush_e2e_role: "admin",
        fieldrush_e2e_run_id: runId,
      },
    },
  };
}

type Fixture = ReturnType<typeof fixture>;

function database(
  data: Fixture,
  options: { missing?: string; fail?: string } = {},
) {
  const calls: string[] = [];
  const admin = createClient("http://127.0.0.1:54321", "fixture-only-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        assert.equal(init?.method ?? "GET", "GET");
        const url = new URL(String(input));
        calls.push(url.pathname);
        let result: unknown;
        if (url.pathname === "/rest/v1/open_queue_games") {
          assert.equal(url.searchParams.get("id"), `eq.${gameId}`);
          assert.equal(
            url.searchParams.get("select"),
            "venue,created_by_staff_id",
          );
          result = [data.game];
        } else if (url.pathname === "/rest/v1/referee_profiles") {
          assert.equal(url.searchParams.get("profile_id"), `eq.${staffId}`);
          result = [data.staff];
        } else {
          // Never resolve the retained operational/player key through Auth.
          assert.equal(url.pathname, `/auth/v1/admin/users/${authId}`);
          result = data.user;
        }
        if (url.pathname.includes(options.fail ?? "never-match")) {
          return new Response(
            JSON.stringify({ message: "Fixture lookup failed" }),
            {
              status: 500,
              headers: { "Content-Type": "application/json" },
            },
          );
        }
        if (url.pathname.includes(options.missing ?? "never-match")) {
          result = [];
        }
        return new Response(JSON.stringify(result), {
          headers: { "Content-Type": "application/json" },
        });
      },
    },
  });
  return { admin, calls };
}

Deno.test("staging checkout resolves separate staff Auth binding with no player creator", async () => {
  const { admin, calls } = database(fixture());
  await assertStagingE2EGameCreator(admin, runId, gameId);
  assert.deepEqual(calls, [
    "/rest/v1/open_queue_games",
    "/rest/v1/referee_profiles",
    `/auth/v1/admin/users/${authId}`,
  ]);
});

const invalid: Array<[string, (data: Fixture) => void]> = [
  ["legacy player creator only", (d) => {
    d.game.created_by_staff_id = null;
    d.game.created_by = staffId;
  }],
  ["unbound staff", (d) => d.staff.auth_user_id = null],
  ["inactive staff", (d) => d.staff.is_active = false],
  ["non-admin staff", (d) => d.staff.role = "referee"],
  ["different Auth identity", (d) => d.user.id = staffId],
  ["different email", (d) => d.user.email = "other@example.invalid"],
  ["phone identity", (d) => d.user.phone = "fixture-phone"],
  ["unconfirmed staff", (d) => d.user.email_confirmed_at = null],
  [
    "player Auth identity",
    (d) => d.user.app_metadata.fieldrush_account_type = "player",
  ],
  ["unmarked fixture", (d) => d.user.app_metadata.fieldrush_e2e = false],
  [
    "wrong fixture role",
    (d) => d.user.app_metadata.fieldrush_e2e_role = "player",
  ],
  [
    "different full run with same venue prefix",
    (d) => d.user.app_metadata.fieldrush_e2e_run_id += "x",
  ],
  ["normal staging game", (d) => d.game.venue = "Normal game"],
];
for (const [name, mutate] of invalid) {
  Deno.test(`staging checkout rejects ${name}`, async () => {
    const data = fixture();
    mutate(data);
    const { admin } = database(data);
    await assert.rejects(
      assertStagingE2EGameCreator(admin, runId, gameId),
      {
        message: "Staging checkout is restricted to this run's fixtures.",
        status: 403,
      },
    );
  });
}

for (const table of ["open_queue_games", "referee_profiles"]) {
  Deno.test(`staging checkout rejects missing ${table}`, async () => {
    const { admin } = database(fixture(), { missing: table });
    await assert.rejects(assertStagingE2EGameCreator(admin, runId, gameId));
  });
}
for (const path of ["open_queue_games", "referee_profiles", "admin/users"]) {
  Deno.test(`staging checkout fails closed on ${path} lookup error`, async () => {
    const { admin } = database(fixture(), { fail: path });
    await assert.rejects(assertStagingE2EGameCreator(admin, runId, gameId));
  });
}

for (const wrongRun of [false, true]) {
  Deno.test(`staging HTTP checkout preserves fixture isolation: wrongRun=${wrongRun}`, async () => {
    const originalFetch = globalThis.fetch;
    const originalEnvGet = Deno.env.get;
    const data = fixture();
    if (wrongRun) data.user.app_metadata.fieldrush_e2e_run_id += "x";
    const playerId = "40000000-0000-4000-8000-000000000004";
    const values: Record<string, string> = {
      SUPABASE_URL: fieldStagingSupabaseUrl,
      SUPABASE_ANON_KEY: crypto.randomUUID(),
      SUPABASE_SERVICE_ROLE_KEY: crypto.randomUUID(),
      STRIPE_SECRET_KEY: `sk_test_${crypto.randomUUID().replaceAll("-", "")}`,
      FIELD_ENVIRONMENT: "staging",
      DEV: "true",
    };
    let insertedId: string | undefined;
    let finalized = false;
    const unexpected: string[] = [];
    const response = (value: unknown) =>
      new Response(JSON.stringify(value), {
        headers: { "Content-Type": "application/json" },
      });
    Deno.env.get = (key) => values[key];
    globalThis.fetch = async (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      assert.equal(url.origin, fieldStagingSupabaseUrl);
      if (request.method === "GET") {
        switch (url.pathname) {
          case "/auth/v1/user":
            return response({
              id: playerId,
              app_metadata: {
                fieldrush_e2e: true,
                fieldrush_e2e_role: "player",
                fieldrush_e2e_run_id: runId,
              },
            });
          case "/rest/v1/profiles":
            return response([{
              display_name: "[E2E] Player",
              username: "field_e2e_player",
            }]);
          case "/rest/v1/open_queue_games":
            assert.equal(
              url.searchParams.get("select"),
              "venue,created_by_staff_id",
            );
            return response([data.game]);
          case "/rest/v1/referee_profiles":
            assert.equal(url.searchParams.get("profile_id"), `eq.${staffId}`);
            return response([data.staff]);
          case `/auth/v1/admin/users/${authId}`:
            return response(data.user);
          case "/rest/v1/payment_intents":
            assert.equal(url.searchParams.get("profile_id"), `eq.${playerId}`);
            return response([]);
        }
      } else if (request.method === "POST") {
        assert.equal(
          wrongRun,
          false,
          "Invalid fixtures must never reach a write or quote",
        );
        const body = await request.json();
        switch (url.pathname) {
          case "/rest/v1/rpc/preview_open_queue_booking_cost":
            assert.deepEqual(body, {
              game_id_to_book: gameId,
              role_to_book: "DEF",
            });
            return response({ currency: "USD", total_fils: 13000 });
          case "/rest/v1/payment_intents":
            assert.equal(body.provider, "STAGING_E2E");
            assert.equal(body.profile_id, playerId);
            assert.equal(body.payload.game_id, gameId);
            assert.equal(body.amount_fils, 13000);
            insertedId = body.id;
            return new Response(null, { status: 201 });
          case "/rest/v1/rpc/finalize_payment_intent":
            assert.ok(insertedId);
            assert.equal(body.intent_id_to_finalize, insertedId);
            finalized = true;
            return response({ status: "FINALIZED", intent_id: insertedId });
        }
      }
      unexpected.push(`${request.method} ${url.pathname}`);
      throw new Error("Unexpected offline checkout request");
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
            action: "complete_staging_e2e",
            run_id: runId,
            purpose: "SOLO_BOOKING",
            payload: { game_id: gameId, role: "DEF" },
          }),
        }),
      );
      const body = await result.json();
      assert.equal(result.status, wrongRun ? 403 : 200);
      assert.equal(finalized, !wrongRun);
      if (!wrongRun) assert.equal(body.status, "FINALIZED");
      assert.deepEqual(unexpected, []);
    } finally {
      globalThis.fetch = originalFetch;
      Deno.env.get = originalEnvGet;
    }
  });
}
