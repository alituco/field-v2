import assert from "node:assert/strict";
import test from "node:test";

import {
  formatPlayerSr,
  nullableSr,
  persistedOpenQueueTeam,
} from "../src/lib/open-queue-ratings.ts";

test("only persisted White and Black assignments become referee teams", () => {
  assert.equal(persistedOpenQueueTeam("WHITE"), "WHITE");
  assert.equal(persistedOpenQueueTeam("black"), "BLACK");
  assert.equal(persistedOpenQueueTeam(null), null);
  assert.equal(persistedOpenQueueTeam(""), null);
  assert.equal(persistedOpenQueueTeam("HOME"), null);
});

test("solo SR values preserve valid snapshots and render missing data clearly", () => {
  assert.equal(nullableSr(1488), 1488);
  assert.equal(nullableSr("1512"), 1512);
  assert.equal(nullableSr(null), null);
  assert.equal(nullableSr(-1), null);
  assert.equal(nullableSr("not-a-rating"), null);
  assert.equal(formatPlayerSr(1499.6), "1,500");
  assert.equal(formatPlayerSr(null), "—");
});
