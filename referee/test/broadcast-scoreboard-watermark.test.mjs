import assert from "node:assert/strict";
import test from "node:test";
import { createGoalWatermark } from "../public/broadcast-scoreboard.mjs";

const now = Date.parse("2030-01-13T03:54:12.000Z");
function goal(id, seconds = 0, team = "AWAY") {
  return { latestGoal: { id, createdAt: new Date(now + seconds * 1000).toISOString(), team, minute: 25, scorerName: "Ali A." } };
}
test("goal deletion does not replay an earlier recent announcement", () => {
  const accept = createGoalWatermark();
  assert.equal(accept(goal("newer"), now).latestGoal.id, "newer");
  assert.equal(accept(goal("older", -1), now).latestGoal, null);
  assert.equal(accept(goal("newer"), now).latestGoal.id, "newer");
  assert.equal(accept(goal("next", 2), now).latestGoal.id, "next");
});
test("invalid and far-future rows cannot poison the goal watermark", () => {
  const accept = createGoalWatermark();
  assert.equal(accept(goal("future", 60), now).latestGoal, null);
  assert.equal(accept(goal("bad-team", 3, "INVALID"), now).latestGoal, null);
  assert.equal(accept(goal(""), now).latestGoal, null);
  assert.equal(accept(goal("real"), now).latestGoal.id, "real");
});
