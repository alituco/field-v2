import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { soloGoalInput, mutateSoloGoal, SoloGoalActionError, prepareSoloGoalRequest, acknowledgeSoloGoalRequest, pendingSoloGoalRequest, rejectSoloGoalRequest } from "../src/lib/solo-goal-actions.ts";

const id = n => `a0160000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const [actor, game, request, scorer, assist, goal, event] = Array.from({ length: 7 }, (_, i) => id(i + 1));
const body = { action: "goal", clanId: "WHITE", profileId: scorer, assistProfileId: assist };
const ack = { game_id: game, request_id: request, action: "ADD", goal_id: goal, event_id: event, white_score: 1, black_score: 0 };
const storage = () => {
  const values = new Map();
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key), values };
};

test("goal input never trusts actor, clock, score, SR or extra payload fields", () => {
  assert.deepEqual(soloGoalInput({ ...body, actor_referee_id: "spoof", elapsedSeconds: 999, white_score: 20, sr: 9999 }), { action: "ADD", team: "WHITE", profile_id: scorer, assist_profile_id: assist });
  for (const bad of [{ ...body, profileId: "bad" }, { ...body, clanId: "HOME" }, { ...body, assistProfileId: scorer }]) assert.throws(() => soloGoalInput(bad));
  assert.deepEqual(soloGoalInput({ action: "remove_goal", goalId: goal, note: "  Duplicate goal  " }), { action: "REMOVE", goal_id: goal, note: "Duplicate goal" });
  assert.throws(() => soloGoalInput({ action: "remove_goal", goalId: goal, note: "" }));
});

test("one RPC atomically records or removes a goal under the authenticated actor", async () => {
  const calls = [];
  const db = { rpc: async (name, args) => { calls.push({ name, args }); return { data: ack, error: null }; } };
  assert.deepEqual(await mutateSoloGoal(db, actor, game, { ...body, requestId: request, actor_referee_id: "spoof" }), { goalOperation: ack });
  assert.deepEqual(calls, [{ name: "referee_mutate_solo_goal", args: { actor_referee_id: actor, game_id_to_use: game, request_id_to_use: request, goal_input: soloGoalInput(body) } }]);
});

test("goal acknowledgement must match exact game/request/action and concrete nonnegative score", async () => {
  for (const data of [null, {}, [], { ...ack, game_id: id(99) }, { ...ack, request_id: id(98) }, { ...ack, action: "REMOVE" }, { ...ack, goal_id: "bad" }, { ...ack, event_id: null }, { ...ack, white_score: -1 }, { ...ack, black_score: 0.5 }]) {
    await assert.rejects(mutateSoloGoal({ rpc: async () => ({ data, error: null }) }, actor, game, { ...body, requestId: request }), /not acknowledged/);
  }
});

test("confirmed rollback is distinguished from transport or ambiguous acknowledgement", async () => {
  for (const [error, definite] of [[{ code: "22023", message: "Paused" }, true], [{ code: "P0001", message: "Scorer is not active" }, true], [{ code: "40001", message: "Retry" }, true], [{ code: "57014", message: "canceling statement due to statement timeout" }, true], [{ code: "57014", message: "unknown cancellation" }, false], [{ message: "fetch failed" }, false]]) {
    await assert.rejects(mutateSoloGoal({ rpc: async () => ({ data: null, error }) }, actor, game, { ...body, requestId: request }), value => value instanceof SoloGoalActionError && value.definitivelyRejected === definite);
  }
});

test("lost response and refresh retain exact request ID; pending operation cannot silently change", () => {
  const saved = storage(); let allocated = 0;
  const create = () => { allocated++; return request; };
  const first = prepareSoloGoalRequest(actor, game, body, saved, create);
  assert.deepEqual(prepareSoloGoalRequest(actor, game, body, saved, create), first);
  assert.equal(allocated, 1);
  assert.deepEqual(pendingSoloGoalRequest(actor, game, saved), body);
  assert.throws(() => prepareSoloGoalRequest(actor, game, { ...body, clanId: "BLACK" }, saved, create), /previous goal action/);
  assert.throws(() => acknowledgeSoloGoalRequest(actor, game, first, {}, saved), /not acknowledged/);
  assert.deepEqual(prepareSoloGoalRequest(actor, game, body, saved, create), first);
  acknowledgeSoloGoalRequest(actor, game, first, { goalOperation: ack }, saved);
  assert.equal(pendingSoloGoalRequest(actor, game, saved), null);
  assert.equal(prepareSoloGoalRequest(actor, game, body, saved, () => id(30)).requestId, id(30));
});

test("pending receipts are isolated by account and game; explicit rejection permits correction", () => {
  const saved = storage();
  prepareSoloGoalRequest(actor, game, body, saved, () => request);
  assert.equal(pendingSoloGoalRequest(id(80), game, saved), null);
  assert.equal(pendingSoloGoalRequest(actor, id(81), saved), null);
  rejectSoloGoalRequest(actor, game, saved);
  assert.equal(prepareSoloGoalRequest(actor, game, { ...body, clanId: "BLACK" }, saved, () => id(82)).requestId, id(82));
});

test("route contains no separate goal table writes; live undo and retry use the themed UI", () => {
  const route = readFileSync(new URL("../src/app/api/referee/open-queue-games/[gameId]/action/route.ts", import.meta.url), "utf8");
  const page = readFileSync(new URL("../src/app/page.tsx", import.meta.url), "utf8");
  assert.doesNotMatch(route, /db\.from\("open_queue_goals"\)/);
  assert.match(route, /case "goal":\s*case "remove_goal":\s*result = await mutateSoloGoal/);
  assert.match(page, /Undo goal/);
  assert.match(page, /Retry saved goal action/);
  assert.match(page, /if \(await onSafetyAction\(body\)\) setEventDialog\(null\)/);
});
