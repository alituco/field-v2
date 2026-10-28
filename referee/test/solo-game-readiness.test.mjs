import assert from "node:assert/strict";
import test from "node:test";
import { soloGameReadiness, soloStarterLineupReady } from "../src/lib/solo-game-readiness.ts";

const configured = (minimumPlayers) => ({ minimumPlayers, capacity: 14,
  participationRulesVersion: "s0-configurable-v1", ratingPolicyId: "field-sr-season0-v2" });

test("a configured two-player game is ready as 1v1 while booking capacity remains fourteen", () => {
  assert.equal(soloGameReadiness(configured(2), 1).minimumReached, false);
  assert.equal(soloGameReadiness(configured(2), 2).minimumReached, true);
  assert.equal(soloGameReadiness(configured(2), 2).capacity, 14);
  assert.equal(soloStarterLineupReady(configured(2), 1, 1), true);
  assert.equal(soloStarterLineupReady(configured(2), 2, 0), false);
});

test("odd thresholds check actual total and each side, not a rounded up per-side minimum", () => {
  assert.equal(soloStarterLineupReady(configured(11), 5, 6), true);
  assert.equal(soloStarterLineupReady(configured(11), 5, 5), false);
  assert.equal(soloStarterLineupReady(configured(3), 1, 2), true);
  assert.equal(soloStarterLineupReady(configured(10), 2, 8), false);
});

test("old S0 and legacy metadata retain their existing player requirements", () => {
  const old = { ratingPolicyId: "field-sr-season0-v2", capacity: 14, minimumPlayers: 2 };
  assert.equal(soloGameReadiness(old, 2).minimumReached, false);
  assert.equal(soloGameReadiness(old, 10).minimumReached, true);
  assert.equal(soloStarterLineupReady(old, 1, 1), false);
  assert.equal(soloStarterLineupReady(old, 4, 6), false);
  assert.equal(soloStarterLineupReady(old, 5, 5), true);
  assert.equal(soloGameReadiness({ capacity: 12, minimumPlayers: 2 }, 2).minimumReached, false);
  assert.equal(soloStarterLineupReady({ ratingPolicyId: "LEGACY" }, 1, 1), true);
});

test("malformed new metadata cannot silently permit a small match", () => {
  for (const minimum of [undefined, null, 0, 1, 15, 2.5, "2"]) {
    assert.equal(soloGameReadiness(configured(minimum), 2).minimumReached, false);
    assert.equal(soloStarterLineupReady(configured(minimum), 1, 1), false);
  }
  assert.equal(soloGameReadiness(configured(2), 15).minimumReached, false);
});
