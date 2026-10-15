import assert from "node:assert/strict";
import test from "node:test";
import { seasonZeroActionInput, runSeasonZeroAction, parseSeasonZeroRebalance, parseSeasonZeroResolution } from "../src/lib/season-zero-actions.ts";

test("participation accepts actions, not client clocks or rating inputs", () => {
  assert.deepEqual(seasonZeroActionInput({ action: "participation", participationAction: "JOIN", profileId: "player", elapsedSeconds: 700,
    sr_before: 9999, note: " late arrival " }), { action: "JOIN", profile_id: "player", note: "late arrival" });
  assert.throws(() => seasonZeroActionInput({ action: "participation", participationAction: "REPLACE", profileId: "player" }));
  assert.throws(() => seasonZeroActionInput({ action: "participation", participationAction: "JOIN" }));
});

test("new policy rejects old team-level estimates and unaudited final-clock changes", () => {
  for (const action of ["set_time", "start_shorthanded", "end_shorthanded", "expire_blue_card"]) {
    assert.throws(() => seasonZeroActionInput({ action }));
  }
  assert.equal(seasonZeroActionInput({ action: "goal" }), null);
  assert.equal(seasonZeroActionInput({ action: "record_verified_injury" }), null);
  assert.deepEqual(seasonZeroActionInput({ action: "pause" }), { action: "PAUSE" });
  assert.deepEqual(seasonZeroActionInput({ action: "resume" }), { action: "RESUME" });
});

test("server authenticates actor and passes the exact revision/idempotency request", async () => {
  const calls = [];
  const db = { rpc: async (name, args) => {
    calls.push({ name, args });
    return { data: name === "get_season_zero_match_state" ? { game_id: "game", revision: 5 } : { game_id: "game", revision: 6, lifecycle: "LIVE" }, error: null };
  } };
  await runSeasonZeroAction(db, "verified-actor", "game", { action: "participation", participationAction: "BLUE_RETURN", profileId: "player",
    actor_referee_id: "spoof", expectedRevision: 4, requestId: "same-request" });
  assert.deepEqual(calls[1], { name: "referee_season_zero_action", args: {
    actor_referee_id: "verified-actor", game_id_to_use: "game", request_id_to_use: "same-request", expected_revision: 4,
    action_input: { action: "BLUE_RETURN", profile_id: "player", note: "" },
  } });
});

test("finish requires a nonempty acknowledgement and never retries a failed settlement blindly", async () => {
  let writes = 0;
  const db = { rpc: async name => name === "get_season_zero_match_state"
    ? { data: { game_id: "game", revision: 2 }, error: null }
    : (++writes, { data: null, error: null }) };
  await assert.rejects(runSeasonZeroAction(db, "actor", "game", { action: "finish" }), /not acknowledged/);
  assert.equal(writes, 1);
});

test("finish must acknowledge the exact game, final state and settled status", async () => {
  for (const data of [{}, { game_id: "other", revision: 3, lifecycle: "FINAL", settlement_status: "RATED" },
    { game_id: "game", revision: 3, lifecycle: "LIVE", settlement_status: "RATED" },
    { game_id: "game", revision: 3, lifecycle: "FINAL", settlement_status: "UNSETTLED" }]) {
    const db = { rpc: async name => ({ data: name === "get_season_zero_match_state" ? { game_id: "game", revision: 2 } : data, error: null }) };
    await assert.rejects(runSeasonZeroAction(db, "actor", "game", { action: "finish" }), /not acknowledged/);
  }
  const state = { game_id: "game", revision: 3, lifecycle: "FINAL", settlement_status: "HELD" };
  const db = { rpc: async name => ({ data: name === "get_season_zero_match_state" ? { game_id: "game", revision: 2 } : state, error: null }) };
  assert.deepEqual(await runSeasonZeroAction(db, "actor", "game", { action: "finish" }), { seasonZeroState: state });
});

test("rebalance sends booked identities and explicit consent, never client ratings or roles", async () => {
  const body = { action: "rebalance", requestId: "request", reason: "Both players consented", moves: [
    { profile_id: "player", to_team: "BLACK", consented: true, skill_rating: 9000, role: "GK" },
  ] };
  assert.deepEqual(parseSeasonZeroRebalance(body), [{ profile_id: "player", to_team: "BLACK", consented: true }]);
  assert.throws(() => parseSeasonZeroRebalance({ ...body, moves: [...body.moves, ...body.moves] }), /only once/);
  let called;
  const db = { rpc: async (name, args) => { called = { name, args }; return { data: { game_id: "game", action: "REBALANCE" }, error: null }; } };
  await runSeasonZeroAction(db, "actor", "game", body);
  assert.equal(called.name, "referee_rebalance_season_zero_match");
  assert.equal(called.args.actor_referee_id, "actor");
  assert.deepEqual(called.args.moves_input, [{ profile_id: "player", to_team: "BLACK", consented: true }]);
});

test("organizer correction accepts match evidence but never manual rating inputs", () => {
  const resolution = { status: "forfeit_confirmed", winner: "A", reason: "Confirmed intentional team walkout", played_seconds: 600 };
  assert.deepEqual(parseSeasonZeroResolution({ resolution }), resolution);
  for (const extra of [{ sr_before: 2000 }, { games_before: 10 }, { rating_change: 50 }, { initial_active: true }]) {
    assert.throws(() => parseSeasonZeroResolution({ resolution: { ...resolution, ...extra } }), /Rating inputs cannot be edited/);
  }
  assert.throws(() => parseSeasonZeroResolution({ resolution: { ...resolution, events: [{ type: "JOIN", second: 100, skill_rating: 2000 }] } }), /participation events only/);
  assert.throws(() => parseSeasonZeroResolution({ resolution: { ...resolution, played_seconds: -1 } }), /whole-number/);
});
