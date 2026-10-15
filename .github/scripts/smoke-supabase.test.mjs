import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";

const smokeUrl = new URL("./smoke-supabase.mjs", import.meta.url).href;

function runSmoke({
  serviceRole = false,
  profileStatus = 403,
  environment = "production",
  gameStatus = serviceRole || environment === "production" ? 200 : 401,
  clanStatus = 200,
  healthStatus = 200,
  url,
} = {}) {
  const projectRef = environment === "staging"
    ? "nfdkdhdevpstfspazbfn"
    : "zjsjuuhborxrlmdcpvlj";
  const script = `
    globalThis.fetch = async (url) => {
      const path = new URL(url).pathname;
      if (path === '/auth/v1/health') {
        return new Response(JSON.stringify({ name: 'GoTrue' }), { status: ${healthStatus} });
      }
      const table = path.split('/').pop();
      if (!${serviceRole} && table === 'profiles') {
        return new Response('{}', { status: ${profileStatus} });
      }
      if (!${serviceRole} && ['season_zero_waitlist', 'reliability_policy_versions'].includes(table)) {
        return new Response('{}', { status: 403 });
      }
      if (table === 'open_queue_games' && ${gameStatus} !== 200) {
        return new Response('{}', { status: ${gameStatus} });
      }
      if (table === 'clans' && ${clanStatus} !== 200) {
        return new Response('{}', { status: ${clanStatus} });
      }
      return new Response('[]', { headers: { 'content-range': '0-0/1' } });
    };
    await import(${JSON.stringify(smokeUrl)});
  `;
  return spawnSync(process.execPath, ["--input-type=module", "-e", script], {
    encoding: "utf8",
    env: {
      ...(process.env.SystemRoot ? { SystemRoot: process.env.SystemRoot } : {}),
      FIELD_ENVIRONMENT: environment,
      SUPABASE_PROJECT_REF: projectRef,
      SUPABASE_URL: url ?? `https://${projectRef}.supabase.co`,
      SUPABASE_PUBLISHABLE_KEY: "test-public-key",
      SUPABASE_SERVICE_ROLE_KEY: serviceRole ? "test-service-role-key" : "",
    },
    timeout: 10_000,
  });
}

test("production anonymous smoke accepts the intended profile privacy boundary", () => {
  const result = runSmoke();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /production smoke check passed/);
  assert.doesNotMatch(result.stdout, /profiles: \d/);
});

test("anonymous profile reads succeeding fail the smoke check", () => {
  const result = runSmoke({ profileStatus: 200 });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /profiles unexpectedly allowed anonymous reads/);
});

test("an HTTP 401 profile rejection also satisfies the privacy boundary", () => {
  const result = runSmoke({ profileStatus: 401 });
  assert.equal(result.status, 0, result.stderr);
});

test("a missing profiles table is not mistaken for denied anonymous access", () => {
  const result = runSmoke({ profileStatus: 404 });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /profiles returned unexpected HTTP 404/);
});

test("server errors are not mistaken for denied anonymous access", () => {
  const result = runSmoke({ profileStatus: 500 });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /profiles returned unexpected HTTP 500/);
});

test("privileged staging-style smoke still verifies profile counts", () => {
  const result = runSmoke({ serviceRole: true, environment: "staging" });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /staging smoke check passed/);
  assert.match(result.stdout, /open_queue_games: 1 row/);
  assert.match(result.stdout, /profiles: 1 row/);
  assert.match(result.stdout, /reliability_policy_versions: 1 row/);
});

for (const gameStatus of [401, 403]) {
  test(`anonymous staging smoke requires game privacy and accepts HTTP ${gameStatus}`, () => {
    const result = runSmoke({ environment: "staging", gameStatus });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /staging smoke check passed/);
    assert.match(result.stdout, /clans: 1 row/);
    assert.doesNotMatch(result.stdout, /open_queue_games: \d/);
  });
}

test("anonymous staging games becoming readable fails the smoke check", () => {
  const result = runSmoke({ environment: "staging", gameStatus: 200 });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /open_queue_games unexpectedly allowed anonymous reads/);
});

for (const gameStatus of [404, 500]) {
  test(`HTTP ${gameStatus} is not mistaken for the staging game privacy boundary`, () => {
    const result = runSmoke({ environment: "staging", gameStatus });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, new RegExp(`open_queue_games returned unexpected HTTP ${gameStatus}`));
  });
}

test("anonymous staging smoke still requires positive public-clan access", () => {
  const result = runSmoke({ environment: "staging", clanStatus: 401 });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /clans\?select=id&limit=1 failed with HTTP 401/);
});

test("staging smoke does not treat failed Auth health as a privacy success", () => {
  const result = runSmoke({ environment: "staging", healthStatus: 401 });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /auth\/v1\/health failed with HTTP 401/);
});

test("privileged staging games must remain readable", () => {
  const result = runSmoke({ environment: "staging", serviceRole: true, gameStatus: 403 });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /open_queue_games\?select=id&limit=1 failed with HTTP 403/);
});

test("production keeps its positive anonymous game-read contract", () => {
  const result = runSmoke();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /open_queue_games: 1 row/);
  const denied = runSmoke({ gameStatus: 401 });
  assert.notEqual(denied.status, 0);
  assert.match(denied.stderr, /open_queue_games\?select=id&limit=1 failed with HTTP 401/);
});

test("production smoke refuses a staging URL", () => {
  const result = runSmoke({ url: "https://nfdkdhdevpstfspazbfn.supabase.co" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /SUPABASE_URL does not match/);
});
