import assert from "node:assert/strict";
import test from "node:test";

import {
  canRefereePerformOperationalAction,
  isMatchOperationallyLocked,
} from "../src/lib/match-operational-lock.ts";

test("no-data and under-review matches are operationally locked", () => {
  assert.equal(isMatchOperationallyLocked("NO_DATA"), true);
  assert.equal(isMatchOperationallyLocked("under_review"), true);
  assert.equal(isMatchOperationallyLocked("RESOLVED"), false);
  assert.equal(isMatchOperationallyLocked("NORMAL"), false);
});

test("locked matches accept evidence reports but reject match mutations", () => {
  assert.equal(
    canRefereePerformOperationalAction("NO_DATA", "report"),
    true,
  );
  for (const action of [
    "start",
    "check_in_player",
    "goal",
    "finish",
    "cancel",
    "override_score",
  ]) {
    assert.equal(
      canRefereePerformOperationalAction("UNDER_REVIEW", action),
      false,
      action,
    );
  }
  assert.equal(canRefereePerformOperationalAction("NORMAL", "start"), true);
});
