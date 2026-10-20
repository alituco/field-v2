import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";

import * as bots from "../src/lib/staging-game-bots.ts";

const gameId = "a1000000-0000-4000-8000-000000000001";
const requestId = "b1000000-0000-4000-8000-000000000001";
const adminId = "c1000000-0000-4000-8000-000000000001";
const input = { requestId, confirmation: "FILL_WITH_BOTS" };
const receipt = { gameId, requestId, createdBots: 11, confirmedCount: 14, capacity: 14, alreadyFilled: false };
const stagingUrl = "https://nfdkdhdevpstfspazbfn.supabase.co";

test("bots require the exact valid staging environment; production/local/unknown/mismatches fail closed", () => {
  assert.equal(bots.isStagingGameBotsEnabled("staging", stagingUrl), true);
  for (const [environment, url] of [
    ["production", "https://zjsjuuhborxrlmdcpvlj.supabase.co"],
    ["local", "http://127.0.0.1:54321"], ["production", stagingUrl], ["local", stagingUrl],
    ["staging", "https://zjsjuuhborxrlmdcpvlj.supabase.co"], ["staging", "http://127.0.0.1:54321"],
    ["staging", `${stagingUrl}.evil.example`], ["staging", `${stagingUrl}/rest/v1`],
    ["staging", `${stagingUrl}?project=staging`], ["staging", "https://user:pass@nfdkdhdevpstfspazbfn.supabase.co"],
    ["staging", "https://nfdkdhdevpstfspazbfn.supabase.co:444"], ["invalid", "https://unrelated.example"],
  ]) assert.equal(bots.isStagingGameBotsEnabled(environment, url), false, `${environment} ${url}`);
});

test("input accepts only the explicit confirmation and UUID receipt key", () => {
  assert.deepEqual(bots.parseStagingBotFillInput(input), input);
  for (const invalid of [null, [], "fill", {}, { requestId }, { ...input, confirmation: "yes" },
    { ...input, requestId: "bad" }, { ...input, actor_admin_id: adminId }, { ...input, capacity: 14 }]) {
    assert.throws(() => bots.parseStagingBotFillInput(invalid));
  }
});

test("only unassigned, normal pregame solo fixtures expose the control", () => {
  const fixture = { matchKind: "SOLO", status: "OPEN", operationalState: "NORMAL", teamsAssignedAt: null, clock: null };
  assert.equal(bots.canFillGameWithBots(fixture), true);
  assert.equal(bots.canFillGameWithBots({ ...fixture, status: "FULL" }), true);
  assert.equal(bots.canFillGameWithBots({ ...fixture, clock: { status: "NOT_STARTED", startedAt: null, accumulatedSeconds: 0 } }), true);
  for (const change of [
    { matchKind: "CLAN" }, { status: "LIVE" }, { status: "FINAL" }, { status: "CANCELLED" },
    { operationalState: "UNDER_REVIEW" }, { operationalState: null }, { teamsAssignedAt: "2026-10-20T00:00:00Z" },
    { clock: { status: "PAUSED", startedAt: null, accumulatedSeconds: 0 } },
    { clock: { status: "NOT_STARTED", startedAt: "2026-10-20T00:00:00Z", accumulatedSeconds: 0 } },
    { clock: { status: "NOT_STARTED", startedAt: null, accumulatedSeconds: 1 } },
  ]) assert.equal(bots.canFillGameWithBots({ ...fixture, ...change }), false);
});

test("receipt validation enforces identity and bounded integer counts and strips extra fields", () => {
  assert.deepEqual(bots.validateStagingBotFillReply({ ...receipt, privateSecret: "must-not-leak" }, { gameId, requestId }), receipt);
  assert.deepEqual(bots.validateStagingBotFillReply({ ...receipt, createdBots: 0, alreadyFilled: true }, { gameId, requestId }), { ...receipt, createdBots: 0, alreadyFilled: true });
  for (const invalid of [null, [], {}, { ...receipt, gameId: adminId }, { ...receipt, requestId: adminId },
    { ...receipt, createdBots: -1 }, { ...receipt, createdBots: "11" }, { ...receipt, createdBots: 1.5 },
    { ...receipt, createdBots: Infinity }, { ...receipt, confirmedCount: NaN }, { ...receipt, capacity: 0 },
    { ...receipt, confirmedCount: 13 }, { ...receipt, confirmedCount: 15 }, { ...receipt, createdBots: 15 },
    { ...receipt, alreadyFilled: true }, { ...receipt, createdBots: 0, alreadyFilled: false },
    { ...receipt, alreadyFilled: "false" }]) assert.throws(() => bots.validateStagingBotFillReply(invalid, { gameId, requestId }));
});

function route({ enabled = true, role = "admin", error = null, data = receipt, throws = false } = {}) {
  const calls = [];
  let authCalls = 0;
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200, headers: init.headers }) } },
    "@/lib/staging-game-bots": { ...bots, isStagingGameBotsEnabled: () => enabled },
    "@/lib/referee-session": {
      requireReferee: async () => {
        authCalls++;
        return role ? { referee: { profileId: adminId, role, isActive: true }, db: { rpc: async (...args) => {
          calls.push(args);
          if (throws) throw new Error("private transport diagnostic");
          return { data, error };
        } } } : { status: 401, headers: new Headers() };
      },
      isRefereeContext: value => "referee" in value,
      adminOnly: value => value.role === "admin" ? null : { status: 403, headers: new Headers() },
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL("../src/app/api/referee/admin/games/[matchKind]/[gameId]/fill-bots/route.ts", import.meta.url), "utf8");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText,
    { exports, Error, require: name => modules[name] });
  return { calls, get authCalls() { return authCalls; }, post: (body = input, changes = {}) => exports.POST({ json: async () => body },
    { params: Promise.resolve({ matchKind: "solo", gameId, ...changes }) }) };
}

test("disabled environments return not found before auth, parsing or database access", async () => {
  const api = route({ enabled: false });
  const response = await api.post(null, { gameId: "bad" });
  assert.equal(response.status, 404);
  assert.equal(api.authCalls, 0);
  assert.equal(api.calls.length, 0);
  assert.equal(response.headers["Cache-Control"], "private, no-store");
});

test("bot fill requires an authenticated administrator", async () => {
  for (const [role, status] of [[null, 401], ["referee", 403]]) {
    const api = route({ role });
    const result = await api.post();
    assert.equal(result.status, status);
    assert.equal(result.headers.get("Cache-Control"), "private, no-store");
    assert.equal(api.calls.length, 0);
  }
});

test("invalid kind, game, body and forged actor never reach the fill RPC", async () => {
  for (const [body, changes] of [[input, { matchKind: "clan" }], [input, { gameId: "bad" }],
    [null, {}], [{ ...input, actor_admin_id: adminId }, {}], [{ ...input, confirmation: "yes" }, {}]]) {
    const api = route();
    assert.equal((await api.post(body, changes)).status, 400);
    assert.equal(api.calls.length, 0);
  }
});

test("bot fill forwards the verified actor, exact game and reused request ID once", async () => {
  const api = route();
  const result = await api.post();
  assert.equal(result.status, 200);
  assert.deepEqual(JSON.parse(JSON.stringify(api.calls)), [["admin_fill_open_queue_game_with_bots", {
    actor_admin_id: adminId, game_id_to_use: gameId, request_id_to_use: requestId,
  }]]);
  assert.deepEqual(result.body, receipt);
  assert.equal(result.headers["Cache-Control"], "private, no-store");
});

test("missing migration, disabled tool and booking conflicts remain clear failures", async () => {
  for (const [error, status, expected] of [
    [{ code: "PGRST202", message: "private missing signature" }, 503, /database update and staging activation/],
    [{ code: "42501", message: "Staging bot tools are disabled." }, 403, /disabled/],
    [{ code: "P0001", message: "An active checkout reserves positions in this game." }, 409, /active checkout/],
  ]) {
    const api = route({ error });
    const result = await api.post();
    assert.equal(result.status, status);
    assert.match(result.body.error, expected);
    assert.equal(api.calls.length, 1);
  }
});

test("malformed or wrong-game acknowledgements fail without claiming success or retrying", async () => {
  for (const data of [null, {}, { ...receipt, gameId: adminId }, { ...receipt, confirmedCount: 99 }]) {
    const api = route({ data });
    const result = await api.post();
    assert.equal(result.status, 502);
    assert.match(result.body.error, /could not be confirmed/);
    assert.equal(api.calls.length, 1);
  }
  const api = route({ throws: true });
  const result = await api.post();
  assert.equal(result.status, 502);
  assert.doesNotMatch(result.body.error, /private transport diagnostic/);
  assert.equal(api.calls.length, 1);
});
