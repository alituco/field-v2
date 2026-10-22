import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import * as goalActions from "../src/lib/clan-goal-actions.ts";
import * as operationalLock from "../src/lib/match-operational-lock.ts";
import { clanGoalInput, mutateClanGoal, ClanGoalActionError, prepareClanGoalRequest, acknowledgeClanGoalRequest, pendingClanGoalRequest, rejectClanGoalRequest } from "../src/lib/clan-goal-actions.ts";

const id = n => `a0220000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const [actor, fixture, request, clan, scorer, assist, goal, event] = Array.from({ length: 8 }, (_, i) => id(i + 1));
const body = { action: "goal", clanId: clan, profileId: scorer, assistProfileId: assist };
const ack = { fixture_id: fixture, request_id: request, action: "ADD", goal_id: goal, event_id: event, home_score: 1, away_score: 0 };
const storage = () => {
  const values = new Map();
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) };
};

test("clan goal input accepts only scorer/team/assist, never client scores or clock", () => {
  assert.deepEqual(clanGoalInput({ ...body, actor_referee_id: "spoof", elapsedSeconds: 999, home_score: 20 }),
    { action: "ADD", clan_id: clan, profile_id: scorer, assist_profile_id: assist });
  for (const bad of [{ ...body, action: "remove_goal" }, { ...body, profileId: "bad" }, { ...body, clanId: "HOME" }]) assert.throws(() => clanGoalInput(bad));
  // Self-assist validation is a separate, deferred audit finding (OPS-004).
  assert.equal(clanGoalInput({ ...body, assistProfileId: scorer }).assist_profile_id, scorer);
});

test("clan route helper sends one transactional RPC under the verified staff identity", async () => {
  const calls = [];
  const db = { rpc: async (name, args) => { calls.push({ name, args }); return { data: ack, error: null }; } };
  assert.deepEqual(await mutateClanGoal(db, actor, fixture, { ...body, requestId: request, actor_referee_id: "spoof" }), { goalOperation: ack });
  assert.deepEqual(calls, [{ name: "referee_record_fixture_goal_atomic", args: { actor_referee_id: actor, fixture_id_to_use: fixture, request_id_to_use: request, goal_input: clanGoalInput(body) } }]);
});

test("a missing or malformed request ID cannot reach the database", async () => {
  const db = { rpc: () => { assert.fail("RPC must not be called"); } };
  for (const requestId of [null, "", "not-a-uuid"]) {
    await assert.rejects(mutateClanGoal(db, actor, fixture, { ...body, requestId }), error => error instanceof ClanGoalActionError && error.definitivelyRejected);
  }
});

test("acknowledgement must match the exact fixture, request and concrete committed score", async () => {
  for (const data of [null, {}, [], { ...ack, fixture_id: id(90) }, { ...ack, request_id: id(91) }, { ...ack, action: "REMOVE" }, { ...ack, goal_id: "bad" }, { ...ack, event_id: null }, { ...ack, home_score: -1 }, { ...ack, away_score: 0.5 }]) {
    await assert.rejects(mutateClanGoal({ rpc: async () => ({ data, error: null }) }, actor, fixture, { ...body, requestId: request }), /not acknowledged/);
  }
});

test("definite database rollback is distinguished from an uncertain network response", async () => {
  for (const [error, definite] of [[{ code: "22023", message: "Match not live" }, true], [{ code: "P0001", message: "Injected failure" }, true], [{ code: "40001", message: "Retry" }, true], [{ code: "57014", message: "canceling statement due to statement timeout" }, true], [{ code: "57014", message: "unknown cancellation" }, false], [{ message: "fetch failed" }, false]]) {
    await assert.rejects(mutateClanGoal({ rpc: async () => ({ data: null, error }) }, actor, fixture, { ...body, requestId: request }), value => value instanceof ClanGoalActionError && value.definitivelyRejected === definite);
  }
});

test("lost response and refresh preserve the payload and request ID until acknowledged", () => {
  const saved = storage(); let allocated = 0;
  const create = () => { allocated++; return request; };
  const first = prepareClanGoalRequest(actor, fixture, body, saved, create);
  assert.deepEqual(prepareClanGoalRequest(actor, fixture, body, saved, create), first);
  assert.equal(allocated, 1);
  assert.deepEqual(pendingClanGoalRequest(actor, fixture, saved), body);
  assert.throws(() => prepareClanGoalRequest(actor, fixture, { ...body, profileId: id(70) }, saved, create), /previous goal action/);
  assert.throws(() => acknowledgeClanGoalRequest(actor, fixture, first, {}, saved), /not acknowledged/);
  assert.deepEqual(prepareClanGoalRequest(actor, fixture, body, saved, create), first);
  acknowledgeClanGoalRequest(actor, fixture, first, { goalOperation: ack }, saved);
  assert.equal(pendingClanGoalRequest(actor, fixture, saved), null);
  assert.equal(prepareClanGoalRequest(actor, fixture, body, saved, () => id(30)).requestId, id(30));
});

test("pending receipts are isolated by staff, fixture and match kind; explicit rejection unlocks corrections", () => {
  const saved = storage();
  prepareClanGoalRequest(actor, fixture, body, saved, () => request);
  assert.equal(pendingClanGoalRequest(id(80), fixture, saved), null);
  assert.equal(pendingClanGoalRequest(actor, id(81), saved), null);
  assert.equal(saved.getItem(`fieldrush:solo-goal:${actor}:${fixture}`), null);
  rejectClanGoalRequest(actor, fixture, saved);
  assert.equal(prepareClanGoalRequest(actor, fixture, { ...body, profileId: id(82) }, saved, () => id(83)).requestId, id(83));
});

function route({ state = "NORMAL", rpcError = null, response = ack } = {}) {
  const calls = [];
  const chain = { select: () => chain, eq: () => chain, single: async () => ({ data: { operational_state: state }, error: null }) };
  const db = {
    from: name => { assert.equal(name, "fixtures", "No separate scorer/event/score writes"); return chain; },
    rpc: async (name, args) => { calls.push({ name, args }); return { data: response, error: rpcError }; },
  };
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200 }) } },
    "@/lib/clan-goal-actions": goalActions,
    "@/lib/match-operational-lock": operationalLock,
    "@/lib/fixture-access": { assertCanManageFixture: async () => {} },
    "@/lib/referee-session": {
      requireReferee: async () => ({ referee: { role: "admin", profileId: actor }, db }),
      isRefereeContext: value => "referee" in value,
    },
    "@/lib/broadcasts": {}, "@/lib/match-action-input": {},
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL("../src/app/api/referee/fixtures/[fixtureId]/action/route.ts", import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, require: name => modules[name], Error });
  return { calls, ...exports };
}

test("actual clan route permits receipt lookup during review but keeps non-goal actions locked", async () => {
  const api = route({ state: "UNDER_REVIEW" });
  const result = await api.POST({ json: async () => ({ ...body, requestId: request }) }, { params: Promise.resolve({ fixtureId: fixture }) });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.goalOperation, ack);
  assert.equal(api.calls.length, 1);
  assert.equal(api.calls[0].name, "referee_record_fixture_goal_atomic");
  const blocked = await api.POST({ json: async () => ({ action: "pause" }) }, { params: Promise.resolve({ fixtureId: fixture }) });
  assert.equal(blocked.status, 409);
  assert.equal(api.calls.length, 1);
});

test("actual clan route reports confirmed rollback separately from an ambiguous acknowledgement", async () => {
  for (const [options, rejected] of [[{ rpcError: { code: "22023", message: "Match finished" } }, true], [{ rpcError: { message: "fetch failed" } }, false], [{ response: {} }, false]]) {
    const api = route(options);
    const result = await api.POST({ json: async () => ({ ...body, requestId: request }) }, { params: Promise.resolve({ fixtureId: fixture }) });
    assert.equal(result.status, 400);
    assert.equal(result.body.goalOperationRejected === true, rejected);
    assert.equal(api.calls.length, 1);
  }
});
