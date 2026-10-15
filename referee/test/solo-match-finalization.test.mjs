import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import { canRefereePerformOperationalAction } from "../src/lib/match-operational-lock.ts";
import { finalizeSoloMatch } from "../src/lib/solo-match-finalization.ts";
import { runSeasonZeroAction, SEASON_ZERO_POLICY } from "../src/lib/season-zero-actions.ts";
import { parseRefereeVerifiedInjuryInput } from "../src/lib/match-action-input.ts";

const gameId = "10000000-0000-4000-8000-000000000001";
const success = (status = "FINAL", id = gameId) => ({ data: { id, status }, error: null });
const timeout = { data: null, error: { code: "57014", message: "canceling statement due to statement timeout" } };

function harness(results, states = []) {
  const calls = [];
  const next = (queue) => {
    const result = queue.shift();
    assert.notEqual(result, undefined, "Unexpected extra database call");
    if (result instanceof Error) throw result;
    return result;
  };
  return {
    calls,
    run: () => finalizeSoloMatch(gameId, {
      complete: async () => { calls.push("complete"); return next(results); },
      readGame: async () => { calls.push("read"); return next(states); },
    }, async (ms) => { calls.push(["delay", ms]); }),
  };
}

test("verified normal completion requires no state read or retry", async () => {
  for (const data of [{ id: gameId, status: "FINAL" }, [{ id: gameId, status: "FINAL" }]]) {
    const check = harness([{ data, error: null }]);
    await check.run();
    assert.deepEqual(check.calls, ["complete"]);
  }
});

test("one confirmed statement timeout retries the same still-live game then verifies completion", async () => {
  const check = harness([timeout, success()], [success("LIVE")]);
  await check.run();
  assert.deepEqual(check.calls, ["complete", ["delay", 250], "read", "complete"]);
});

test("a concurrent committed completion after timeout is accepted without a second finalizer", async () => {
  const check = harness([timeout], [success()]);
  await check.run();
  assert.deepEqual(check.calls, ["complete", ["delay", 250], "read"]);
});

test("a second statement timeout is bounded and never makes a third attempt", async () => {
  const check = harness([timeout, timeout], [success("LIVE"), success("LIVE")]);
  await assert.rejects(check.run(), /statement timeout/);
  assert.deepEqual(check.calls, ["complete", ["delay", 250], "read", "complete", "read"]);
});

test("a committed completion observed after the second timeout is still verified without another write", async () => {
  const check = harness([timeout, timeout], [success("LIVE"), success()]);
  await check.run();
  assert.deepEqual(check.calls, ["complete", ["delay", 250], "read", "complete", "read"]);
});

test("cancellation, business, permission and unconfirmed timeout errors never retry", async () => {
  for (const error of [
    { code: "57014", message: "canceling statement due to user request" },
    { code: "P0001", message: "Every booked player must remain checked in." },
    { code: "42501", message: "Permission denied" },
    { code: "55P03", message: "canceling statement due to lock timeout" },
    { code: "PGRST003", message: "canceling statement due to statement timeout" },
    { message: "canceling statement due to statement timeout" },
    { code: "57014", message: "A different cancellation" },
  ]) {
    const check = harness([{ data: null, error }]);
    await assert.rejects(check.run(), /Could not finalize solo game/);
    assert.deepEqual(check.calls, ["complete"]);
  }
});

test("transport failure on either attempt cannot trigger additional writes or infer success", async () => {
  const transport = new Error("Network connection lost");
  const first = harness([transport]);
  await assert.rejects(first.run(), transport);
  assert.deepEqual(first.calls, ["complete"]);
  const second = harness([timeout, transport], [success("LIVE")]);
  await assert.rejects(second.run(), transport);
  assert.deepEqual(second.calls, ["complete", ["delay", 250], "read", "complete"]);
});

test("only LIVE permits a retry; other game states remain untouched", async () => {
  for (const status of ["OPEN", "FULL", "CANCELLED", "UNKNOWN"]) {
    const check = harness([timeout], [success(status)]);
    await assert.rejects(check.run(), /statement timeout/);
    assert.deepEqual(check.calls, ["complete", ["delay", 250], "read"]);
  }
});

test("unavailable or failed recovery reads do not permit another finalizer", async () => {
  for (const state of [
    { data: null, error: { code: "57014", message: "canceling statement due to statement timeout" } },
    { data: success().data, error: { code: "42501", message: "Permission denied" } },
    new Error("Recovery transport failure"),
    new Error("This match is locked for admin review."),
  ]) {
    const check = harness([timeout], [state]);
    await assert.rejects(check.run());
    assert.deepEqual(check.calls, ["complete", ["delay", 250], "read"]);
  }
});

test("malformed or wrong-game responses never count as a successful completion", async () => {
  for (const data of [null, {}, [], [success().data, success().data], "FINAL", { id: "other", status: "FINAL" }, { id: gameId }, { id: gameId, status: 1 }]) {
    const direct = harness([{ data, error: null }]);
    await assert.rejects(direct.run(), /Could not verify/);
    assert.deepEqual(direct.calls, ["complete"]);
    const recovery = harness([timeout], [{ data, error: null }]);
    await assert.rejects(recovery.run(), /Could not verify/);
    assert.deepEqual(recovery.calls, ["complete", ["delay", 250], "read"]);
  }
  const nonFinal = harness([success("LIVE")]);
  await assert.rejects(nonFinal.run(), /Could not verify/);
  assert.deepEqual(nonFinal.calls, ["complete"]);
});

function finishRoute({ actor = { profileId: "referee-1", role: "referee" }, denied = false,
  operationalState = "NORMAL", ratingPolicy = "LEGACY", body = { action: "finish" }, results = [success()], states = [], onDelay = () => {} } = {}) {
  const calls = [];
  const db = {
    rpc: async (name, params) => {
      if (name === "referee_record_verified_injury") {
        assert.equal(params.match_id_to_use, gameId);
        assert.equal(params.actor_referee_id, actor.profileId);
        assert.equal(params.replacement_available_to_use, false);
        calls.push("financial-injury-evidence");
        return { data: { injury_id: "injury" }, error: null };
      }
      if (ratingPolicy === SEASON_ZERO_POLICY) {
        assert.equal(params.game_id_to_use, gameId);
        assert.equal(params.actor_referee_id, actor.profileId);
        if (name === "get_season_zero_match_state") return { data: { game_id: gameId, revision: 2 }, error: null };
        assert.equal(name, "referee_finish_season_zero_match");
        calls.push("v2-complete");
        return results.shift();
      }
      assert.equal(name, "referee_complete_open_queue_game");
      assert.equal(params.game_id_to_complete, gameId);
      calls.push("complete");
      const result = results.shift();
      assert.notEqual(result, undefined, "Unexpected extra finalizer");
      return result;
    },
    from: (table) => {
      assert.equal(table, "open_queue_games");
      return { select: (columns) => ({ eq: (key, value) => {
        assert.equal(key, "id"); assert.equal(value, gameId);
        return { single: async () => {
          if (columns === "operational_state,rating_policy_id") {
            calls.push("initial-review-guard");
            return { data: { operational_state: operationalState, rating_policy_id: ratingPolicy }, error: null };
          }
          assert.equal(columns, "id,status,operational_state");
          calls.push("recovery-read");
          const state = states.shift();
          assert.notEqual(state, undefined, "Unexpected extra state read");
          return state;
        } };
      } }) };
    },
  };
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200 }) } },
    "@/lib/broadcasts": { queueOpenQueueBroadcastStop: async () => calls.push("broadcast-stop") },
    "@/lib/fixture-access": { assertCanManageOpenQueueGame: async () => {
      calls.push("access-guard");
      if (denied) throw new Error("Game access denied");
    } },
    "@/lib/match-action-input": { parseRefereeVerifiedInjuryInput },
    "@/lib/match-duration": {},
    "@/lib/season-zero-actions": { runSeasonZeroAction, SEASON_ZERO_POLICY },
    "@/lib/match-operational-lock": { canRefereePerformOperationalAction },
    "@/lib/referee-session": {
      requireReferee: async () => actor ? { referee: actor, db } : { status: 401 },
      isRefereeContext: (value) => "referee" in value,
    },
    "@/lib/solo-match-finalization": {
      finalizeSoloMatch: (id, store) => finalizeSoloMatch(id, store, async () => {
        calls.push("delay");
        await onDelay();
      }),
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL("../src/app/api/referee/open-queue-games/[gameId]/action/route.ts", import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, Error, console, require: (name) => modules[name] });
  return { calls, run: () => exports.POST({ json: async () => body }, { params: Promise.resolve({ gameId }) }) };
}

test("finish route retains authentication, game access and admin-review guards before finalization", async () => {
  const anonymous = finishRoute({ actor: null });
  assert.equal((await anonymous.run()).status, 401);
  assert.deepEqual(anonymous.calls, []);
  const denied = finishRoute({ denied: true });
  assert.equal((await denied.run()).status, 400);
  assert.deepEqual(denied.calls, ["access-guard"]);
  const locked = finishRoute({ operationalState: "UNDER_REVIEW" });
  assert.equal((await locked.run()).status, 409);
  assert.deepEqual(locked.calls, ["access-guard", "initial-review-guard"]);
});

test("finish route recovers a confirmed timeout and stops the broadcast only after verified completion", async () => {
  const api = finishRoute({ results: [timeout, success()], states: [success("LIVE")] });
  const response = await api.run();
  assert.equal(response.status, 200);
  assert.equal(response.body.ok, true);
  assert.deepEqual(api.calls, ["access-guard", "initial-review-guard", "complete", "delay", "recovery-read", "complete", "broadcast-stop"]);
});

test("finish route stops recovery if an admin locks the still-live game after the timeout", async () => {
  const state = { data: { id: gameId, status: "LIVE", operational_state: "NORMAL" }, error: null };
  const api = finishRoute({ results: [timeout], states: [state], onDelay: () => {
    state.data.operational_state = "UNDER_REVIEW";
  } });
  const response = await api.run();
  assert.equal(response.status, 400);
  assert.match(response.body.error, /locked for admin review/);
  assert.deepEqual(api.calls, ["access-guard", "initial-review-guard", "complete", "delay", "recovery-read"]);
});

test("finish route does not stop the broadcast or claim success for a wrong-game response", async () => {
  const api = finishRoute({ results: [success("FINAL", "other-game")] });
  const response = await api.run();
  assert.equal(response.status, 400);
  assert.match(response.body.error, /Could not verify/);
  assert.deepEqual(api.calls, ["access-guard", "initial-review-guard", "complete"]);
});

test("new-policy finish route uses atomic evidence settlement, then stops its broadcast", async () => {
  const state = { game_id: gameId, revision: 3, lifecycle: "FINAL", settlement_status: "RATED" };
  const api = finishRoute({ ratingPolicy: SEASON_ZERO_POLICY, results: [{ data: state, error: null }] });
  const response = await api.run();
  assert.equal(response.status, 200);
  assert.equal(response.body.seasonZeroState.game_id, gameId);
  assert.deepEqual(api.calls, ["access-guard", "initial-review-guard", "v2-complete", "broadcast-stop"]);
});

test("new-policy finish never falls back to legacy or stops broadcast for bad acknowledgement", async () => {
  for (const result of [timeout, success(), { data: { game_id: "other", revision: 3, lifecycle: "FINAL", settlement_status: "RATED" }, error: null }]) {
    const api = finishRoute({ ratingPolicy: SEASON_ZERO_POLICY, results: [result] });
    assert.equal((await api.run()).status, 400);
    assert.deepEqual(api.calls, ["access-guard", "initial-review-guard", "v2-complete"]);
  }
});

test("new-policy injury refund evidence stays available without writing SR participation or allowing reserves", async () => {
  const body = { action: "record_verified_injury", profileId: gameId, unableToContinue: true,
    replacementAvailable: false, matchContinued: true, note: "Verified injury evidence for refund policy." };
  const api = finishRoute({ ratingPolicy: SEASON_ZERO_POLICY, body });
  assert.equal((await api.run()).status, 200);
  assert.deepEqual(api.calls, ["access-guard", "initial-review-guard", "financial-injury-evidence"]);
  const reserve = finishRoute({ ratingPolicy: SEASON_ZERO_POLICY, body: { ...body, replacementAvailable: true } });
  const rejected = await reserve.run();
  assert.equal(rejected.status, 400);
  assert.match(rejected.body.error, /does not allow reserve replacements/);
  assert.deepEqual(reserve.calls, ["access-guard", "initial-review-guard"]);
});
