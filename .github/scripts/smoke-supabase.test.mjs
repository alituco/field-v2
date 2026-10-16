import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";

const smokeUrl = new URL("./smoke-supabase.mjs", import.meta.url).href;

function runSmoke({ serviceRole = false, profileStatus = 403, url } = {}) {
  const script = `
    globalThis.fetch = async (url) => {
      const path = new URL(url).pathname;
      if (path === '/auth/v1/health') {
        return new Response(JSON.stringify({ name: 'GoTrue' }));
      }
      const table = path.split('/').pop();
      if (!${serviceRole} && table === 'profiles') {
        return new Response('{}', { status: ${profileStatus} });
      }
      if (!${serviceRole} && ['season_zero_waitlist', 'reliability_policy_versions'].includes(table)) {
        return new Response('{}', { status: 403 });
      }
      return new Response('[]', { headers: { 'content-range': '0-0/1' } });
    };
    await import(${JSON.stringify(smokeUrl)});
  `;
  return spawnSync(process.execPath, ["--input-type=module", "-e", script], {
    encoding: "utf8",
    env: {
      ...(process.env.SystemRoot ? { SystemRoot: process.env.SystemRoot } : {}),
      FIELD_ENVIRONMENT: "production",
      SUPABASE_PROJECT_REF: "zjsjuuhborxrlmdcpvlj",
      SUPABASE_URL: url ?? "https://zjsjuuhborxrlmdcpvlj.supabase.co",
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
  const result = runSmoke({ serviceRole: true });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /profiles: 1 row/);
  assert.match(result.stdout, /reliability_policy_versions: 1 row/);
});

test("production smoke refuses a staging URL", () => {
  const result = runSmoke({ url: "https://nfdkdhdevpstfspazbfn.supabase.co" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /SUPABASE_URL does not match/);
});
