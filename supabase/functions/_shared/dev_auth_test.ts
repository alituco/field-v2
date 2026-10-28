import { handleDevAuth } from "./dev_auth_handler.ts";
import {
  type DevAuthUser,
  E2E_STAFF_EMAIL,
  isCurrentRunFixture,
  stagingDevAuthWindow,
} from "./dev_auth.ts";

const now = Date.parse("2026-10-16T12:00:00.000Z");
const secret = crypto.randomUUID() + crypto.randomUUID();
const bootstrap = {
  id: "fe160000-0000-4000-8000-000000000001",
  phone: "+97339009098",
  app_metadata: {
    fieldrush_e2e: true,
    fieldrush_e2e_role: "bootstrap",
    fieldrush_e2e_run_id: "run-1",
  },
};
const player = {
  id: "fe160000-0000-4000-8000-000000000002",
  phone: "+97339009001",
  app_metadata: {
    fieldrush_e2e: true,
    fieldrush_e2e_role: "player",
    fieldrush_e2e_run_id: "run-1",
  },
};
const configuration = {
  SUPABASE_URL: "https://nfdkdhdevpstfspazbfn.supabase.co",
  SUPABASE_ANON_KEY: "public-fixture-key",
  SUPABASE_SERVICE_ROLE_KEY: "private-fixture-key",
  DEV: "true",
  DEV_OTP_ENABLED: "true",
  DEV_OTP_CODE: "000000",
  DEV_AUTH_RUN_ID: "run-1",
  DEV_AUTH_SECRET: secret,
  DEV_OTP_PASSWORD: secret,
  DEV_AUTH_VALID_UNTIL: "2026-10-16T13:00:00.000Z",
};
const assert = (ok: unknown) => {
  if (!ok) throw new Error("Dev authentication safety contract failed");
};

function harness(
  overrides: Record<string, string | undefined> = {},
  caller: DevAuthUser = bootstrap,
  target: DevAuthUser = player,
) {
  const env = { ...configuration, ...overrides };
  let reads = 0, signIns = 0;
  const credentials: Array<{ phone?: string; email?: string }> = [];
  const client = {
    auth: {
      admin: {
        async listUsers() {
          reads++;
          return { data: { users: [bootstrap] }, error: null };
        },
        async getUserById() {
          reads++;
          return { data: { user: target }, error: null };
        },
        createUser() {
          throw new Error("No Auth creation is allowed");
        },
        updateUserById() {
          throw new Error("No Auth update is allowed");
        },
        generateLink() {
          throw new Error("No magic-link creation is allowed");
        },
      },
      async getUser() {
        reads++;
        return { data: { user: caller }, error: null };
      },
      async signInWithPassword(
        input: { phone?: string; email?: string; password: string },
      ) {
        signIns++;
        credentials.push(input);
        assert(
          input.password === secret ||
            env.SUPABASE_URL === "http://127.0.0.1:54321",
        );
        const user = input.phone === bootstrap.phone ? bootstrap : target;
        return {
          data: {
            user,
            session: {
              access_token: "fixture-session",
              refresh_token: "fixture-refresh",
              expires_at: 42,
            },
          },
          error: null,
        };
      },
    },
  };
  const run = (
    kind: "phone" | "switch",
    body: unknown,
    capability: string | null = secret,
    bearer = true,
  ) => {
    const headers: Record<string, string> = {
      "content-type": "application/json",
    };
    if (capability !== null) headers["x-fieldrush-e2e-secret"] = capability;
    if (bearer) headers.Authorization = "Bearer fixture-caller";
    return handleDevAuth(
      new Request("https://fixture.invalid", {
        method: "POST",
        headers,
        body: JSON.stringify(body),
      }),
      kind,
      {
        env: (name) => env[name as keyof typeof env],
        now: () => now,
        client: () => client as never,
      },
    );
  };
  return { run, reads: () => reads, signIns: () => signIns, credentials };
}

Deno.test("only the marked current-run email-only staff fixture may use the staff E2E session path", async () => {
  const staff: DevAuthUser = {
    id: "fe160000-0000-4000-8000-000000000003",
    email: E2E_STAFF_EMAIL,
    email_confirmed_at: "2026-10-16T10:00:00.000Z",
    app_metadata: {
      fieldrush_e2e: true,
      fieldrush_e2e_role: "admin",
      fieldrush_e2e_run_id: "run-1",
      fieldrush_account_type: "staff",
    },
  };
  assert(isCurrentRunFixture(staff, "run-1", now));
  const h = harness({}, bootstrap, staff);
  assert((await h.run("switch", { profile_id: staff.id })).status === 200);
  assert(h.credentials[0].email === E2E_STAFF_EMAIL && !h.credentials[0].phone);
  for (
    const invalid of [
      { ...staff, phone: "+97339009099" },
      { ...staff, email: "real-admin@example.test" },
      { ...staff, email_confirmed_at: null },
      {
        ...staff,
        app_metadata: {
          ...staff.app_metadata,
          fieldrush_account_type: "player",
        },
      },
      {
        ...staff,
        app_metadata: {
          ...staff.app_metadata,
          fieldrush_e2e_run_id: "another-run",
        },
      },
    ]
  ) {
    assert(!isCurrentRunFixture(invalid, "run-1", now));
    const denied = harness({}, bootstrap, invalid);
    assert(
      (await denied.run("switch", { profile_id: staff.id })).status === 403 &&
        denied.signIns() === 0,
    );
  }
});

Deno.test("staging windows fail closed on missing, invalid, expired or unbounded configuration", () => {
  assert(
    stagingDevAuthWindow(
      (name) => configuration[name as keyof typeof configuration],
      now,
    ),
  );
  for (
    const [name, value] of [
      ["DEV", "false"],
      ["DEV_OTP_ENABLED", "false"],
      ["DEV_AUTH_SECRET", undefined],
      ["DEV_AUTH_SECRET", "short"],
      ["DEV_AUTH_RUN_ID", undefined],
      ["DEV_AUTH_VALID_UNTIL", undefined],
      ["DEV_AUTH_VALID_UNTIL", "invalid"],
      ["DEV_AUTH_VALID_UNTIL", "2026-02-31T13:00:00.000Z"],
      ["DEV_AUTH_VALID_UNTIL", "2026-10-16T12:00:00.000Z"],
      ["DEV_AUTH_VALID_UNTIL", "2026-10-16T14:00:00.001Z"],
      ["SUPABASE_URL", "https://zjsjuuhborxrlmdcpvlj.supabase.co"],
      [
        "SUPABASE_URL",
        "https://nfdkdhdevpstfspazbfn.supabase.co.attacker.invalid",
      ],
    ]
  ) {
    const env = { ...configuration, [name!]: value };
    assert(!stagingDevAuthWindow((key) => env[key as keyof typeof env], now));
  }
});

Deno.test("public fixed OTP and ordinary bearer cannot reach Auth without the run capability", async () => {
  for (const kind of ["phone", "switch"] as const) {
    for (const supplied of [null, "incorrect"]) {
      const h = harness();
      assert(
        (await h.run(
          kind,
          kind === "phone"
            ? { phone: bootstrap.phone, token: "000000" }
            : { profile_id: player.id },
          supplied,
        )).status === 401,
      );
      assert(h.reads() === 0 && h.signIns() === 0);
    }
  }
});

Deno.test("current run service markers and reserved role/phone must agree", () => {
  assert(isCurrentRunFixture(player, "run-1", now));
  for (
    const user of [
      { ...player, app_metadata: {} },
      { ...player, phone: "+16025550123" },
      {
        ...player,
        app_metadata: {
          ...player.app_metadata,
          fieldrush_e2e_run_id: "old-run",
        },
      },
      {
        ...player,
        app_metadata: { ...player.app_metadata, fieldrush_e2e: "true" },
      },
      {
        ...player,
        app_metadata: { ...player.app_metadata, fieldrush_e2e_role: "admin" },
      },
      { ...player, deleted_at: "2026-10-15T12:00:00.000Z" },
      { ...player, banned_until: "2026-10-17T12:00:00.000Z" },
    ]
  ) assert(!isCurrentRunFixture(user, "run-1", now));
});

Deno.test("ordinary or previous-run callers cannot select even a valid current fixture", async () => {
  for (
    const caller of [
      { ...bootstrap, app_metadata: {} },
      {
        ...bootstrap,
        app_metadata: {
          ...bootstrap.app_metadata,
          fieldrush_e2e_run_id: "old-run",
        },
      },
    ]
  ) {
    const h = harness({}, caller as typeof bootstrap);
    assert((await h.run("switch", { profile_id: player.id })).status === 403);
    assert(h.reads() === 1 && h.signIns() === 0);
  }
});

Deno.test("real player, real admin, previous run and user-editable markers cannot be selected", async () => {
  for (
    const target of [
      { ...player, app_metadata: {} },
      { ...player, phone: "+16025550123" },
      {
        ...player,
        app_metadata: {
          ...player.app_metadata,
          fieldrush_e2e_run_id: "old-run",
        },
      },
      { ...player, app_metadata: {}, user_metadata: player.app_metadata },
    ]
  ) {
    const h = harness({}, bootstrap, target as typeof player);
    assert((await h.run("switch", { profile_id: player.id })).status === 403);
    assert(h.signIns() === 0);
  }
});

Deno.test("switch requires caller JWT and rejects metadata reset commands", async () => {
  const h = harness();
  assert(
    (await h.run("switch", { profile_id: player.id }, secret, false)).status ===
      401,
  );
  assert(
    (await h.run("switch", {
      profile_id: player.id,
      reset_onboarding_metadata: true,
    })).status === 400,
  );
  assert(h.signIns() === 0);
});

Deno.test("only protected bootstrap can use hosted fixed-code entry", async () => {
  const h = harness();
  assert(
    (await h.run("phone", { phone: "+97338883670", token: "000000" }))
      .status === 401,
  );
  assert(
    (await h.run("phone", { phone: bootstrap.phone, token: "000000" }))
      .status === 200,
  );
  assert(h.signIns() === 1);
});

Deno.test("current fixture switch signs in without resetting password, metadata or minting links", async () => {
  const h = harness();
  assert((await h.run("switch", { profile_id: player.id })).status === 200);
  assert(h.signIns() === 1);
});

Deno.test("loopback-only seed login remains available without a hosted run capability", async () => {
  const h = harness({
    SUPABASE_URL: "http://127.0.0.1:54321",
    DEV: "false",
    DEV_OTP_ENABLED: "false",
  });
  assert(
    (await h.run("phone", { phone: bootstrap.phone, token: "000000" }, null))
      .status === 200,
  );
  assert(
    (await h.run("switch", { profile_id: player.id }, null)).status === 404,
  );
});
