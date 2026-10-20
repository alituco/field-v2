import { handleStagingAdminSession } from "./staging_admin_session.ts";

const actor = "fe160000-0000-4000-8000-000000000001";
const target = "fe160000-0000-4000-8000-000000000002";
const assert = (value: unknown) => {
  if (!value) throw new Error("Staging admin session contract failed");
};
function harness(
  options: {
    production?: boolean;
    enabled?: boolean;
    admin?: boolean;
    active?: boolean;
    invalidToken?: boolean;
    nested?: boolean;
    deleted?: boolean;
    banned?: boolean;
    auditFailure?: boolean;
  } = {},
) {
  let minted = 0, authWrites = 0;
  const token = `header.${
    btoa(
      JSON.stringify({
        session_id: "real-session",
        ...(options.nested ? { fieldrush_staging_actor: actor } : {}),
      }),
    )
  }.signature`;
  const client = {
    auth: {
      getUser: () =>
        Promise.resolve({
          data: { user: { id: actor } },
          error: options.invalidToken ? {} : null,
        }),
      admin: {
        getUserById: () =>
          Promise.resolve({
            data: {
              user: {
                id: target,
                phone: "15555555555",
                app_metadata: {},
                user_metadata: {},
                ...(options.banned
                  ? { banned_until: "2099-01-01T00:00:00Z" }
                  : {}),
              },
            },
            error: null,
          }),
        updateUserById: () => {
          authWrites++;
          throw new Error("No identity changes");
        },
        generateLink: () => {
          authWrites++;
          throw new Error("No identity changes");
        },
      },
    },
    from: (table: string) => ({
      select: () => ({
        eq: () => ({
          maybeSingle: () =>
            Promise.resolve({
              error: null,
              data: table === "referee_profiles"
                ? {
                  role: options.admin === false ? "referee" : "admin",
                  is_active: options.active !== false,
                }
                : { account_deleted_at: options.deleted ? "2026-01-01" : null },
            }),
        }),
      }),
      insert: () => {
        minted++;
        return Promise.resolve({ error: options.auditFailure ? {} : null });
      },
    }),
  };
  const env: Record<string, string> = {
    SUPABASE_URL: `https://${
      options.production ? "zjsjuuhborxrlmdcpvlj" : "nfdkdhdevpstfspazbfn"
    }.supabase.co`,
    STAGING_ADMIN_SWITCH_ENABLED: options.enabled === false ? "false" : "true",
    STAGING_IMPERSONATION_JWT_SECRET: "test-signing-key-not-a-real-secret",
    SUPABASE_SERVICE_ROLE_KEY: "test-service-key",
  };
  return {
    run: (body: unknown = { profile_id: target }, authenticated = true) =>
      handleStagingAdminSession(
        new Request("https://test.invalid", {
          method: "POST",
          headers: authenticated ? { Authorization: `Bearer ${token}` } : {},
          body: JSON.stringify(body),
        }),
        {
          env: (name) => env[name],
          client: (() => client) as never,
          now: () => 1700000000000,
        },
      ),
    minted: () => minted,
    authWrites: () => authWrites,
  };
}

Deno.test("staging admin may open any active account without changing its identity", async () => {
  const h = harness();
  const response = await h.run();
  const data = await response.json();
  assert(
    response.status === 200 && data.user.id === target &&
      data.refresh_token === null,
  );
  const claims = JSON.parse(
    atob(
      data.access_token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/"),
    ),
  );
  assert(
    claims.sub === target && claims.fieldrush_staging_actor === actor &&
      claims.exp - claims.iat === 900,
  );
  assert(
    claims.role === "authenticated" && !claims.session_id && h.minted() === 1 &&
      h.authWrites() === 0,
  );
});
Deno.test("production, disabled configuration, non-admin, inactive, forged and nested sessions fail closed", async () => {
  for (
    const options of [
      { production: true },
      { enabled: false },
      { admin: false },
      { active: false },
      { invalidToken: true },
      { nested: true },
      { deleted: true },
      { banned: true },
    ]
  ) {
    const h = harness(options);
    assert((await h.run()).status >= 400);
    assert(h.minted() === 0 && h.authWrites() === 0);
  }
  const h = harness();
  assert((await h.run(undefined, false)).status === 401);
});
Deno.test("invalid target and missing audit never return a token", async () => {
  for (
    const body of [
      { profile_id: "bad" },
      { profile_id: target, role: "admin" },
      null,
    ]
  ) {
    const h = harness();
    assert((await h.run(body)).status >= 400);
    assert(h.minted() === 0);
  }
  const response = await harness({ auditFailure: true }).run();
  assert(response.status === 503 && !(await response.json()).access_token);
});
