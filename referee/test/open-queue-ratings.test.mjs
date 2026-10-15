import assert from "node:assert/strict";
import test from "node:test";

import {
  formatPlayerSr,
  nullableSr,
  persistedOpenQueueTeam,
  ratingTrackForBookedRole,
  ratingTrackLabel,
} from "../src/lib/open-queue-ratings.ts";

test("only persisted White and Black assignments become referee teams", () => {
  assert.equal(persistedOpenQueueTeam("WHITE"), "WHITE");
  assert.equal(persistedOpenQueueTeam("black"), "BLACK");
  assert.equal(persistedOpenQueueTeam(null), null);
  assert.equal(persistedOpenQueueTeam(""), null);
  assert.equal(persistedOpenQueueTeam("HOME"), null);
});

test("referee rating labels follow the booked position rather than profile preference", () => {
  assert.equal(ratingTrackForBookedRole("GK"), "GOALKEEPER");
  assert.equal(ratingTrackLabel("gk"), "Keeper");
  for (const role of ["DEF", "ATT", "MID"]) {
    assert.equal(ratingTrackForBookedRole(role), "OUTFIELD");
    assert.equal(ratingTrackLabel(role), "Outfield");
  }
});

test("solo SR values preserve valid snapshots and render missing data clearly", () => {
  assert.equal(nullableSr(1488), 1488);
  assert.equal(nullableSr("1512"), 1512);
  assert.equal(nullableSr(null), null);
  assert.equal(nullableSr(-1), -1);
  assert.equal(nullableSr("-40"), -40);
  assert.equal(nullableSr(true), null);
  assert.equal(nullableSr(" "), null);
  assert.equal(nullableSr(Infinity), null);
  assert.equal(nullableSr("not-a-rating"), null);
  assert.equal(formatPlayerSr(1499.6), "1,500");
  assert.equal(formatPlayerSr(-40), "-40");
  assert.equal(formatPlayerSr(null), "—");
});
