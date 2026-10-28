import assert from "node:assert/strict";
import test from "node:test";
import { completedPlayingDuration, waitForPlayingDuration } from "../e2e/support/season-zero-journey.ts";

const payload = (elapsed = 0) => ({ state: { game_id: "match", lifecycle: "LIVE", scheduled_seconds: 1800, elapsed_seconds: elapsed } });

test("the rated S0 journey waits for the full saved duration, not just the appearance minimum", () => {
  for (const seconds of [0, 600, 1799]) assert.equal(completedPlayingDuration(payload(seconds), "match"), false);
  for (const seconds of [1800, 1810]) assert.equal(completedPlayingDuration(payload(seconds), "match"), true);
});

test("wrong-game, stopped, missing and malformed server clocks fail immediately", () => {
  for (const value of [null, {}, { state: null }, payload("1800"), payload(NaN), payload(-1),
    { state: { ...payload().state, game_id: "other" } },
    { state: { ...payload().state, lifecycle: "FINAL" } },
    { state: { ...payload().state, scheduled_seconds: 3600 } }]) {
    assert.throws(() => completedPlayingDuration(value, "match"));
  }
});

test("duration waiter only reads exact server state and does not fast-forward or finalize", async () => {
  const calls = [];
  const states = [payload(1799), payload(1800)];
  const page = {
    request: { get: async (path, options) => {
      calls.push(path);
      assert.equal(options.headers.authorization, "Bearer fixture-token");
      return { ok: () => true, status: () => 200, json: async () => states.shift() };
    } },
    waitForTimeout: async (ms) => { assert.equal(ms, 15000); },
  };
  await waitForPlayingDuration(page, "match", "fixture-token");
  assert.deepEqual(calls, Array(2).fill("/api/referee/open-queue-games/match/participation"));
});
