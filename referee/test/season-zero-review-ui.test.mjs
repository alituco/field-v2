import assert from "node:assert/strict";
import test from "node:test";
import { buildReviewResolution, toEventDraft } from "../src/lib/season-zero-review-ui.ts";

const state = { observed_roster: [{ id: "player" }] };
const draft = { status: "completed", winner: "B", whiteScore: "3", blackScore: "1", reason: "Verified against match recording.", correctTimeline: false, playedSeconds: "3600", events: [] };
const event = { id: "entry", type: "JOIN", player_id: "player", second: 90, recorded_at: "2026-10-14T19:01:30.123456Z", actor_id: "original-actor", sr_before: 1900, note: "Late arrival" };

test("completed outcome derives winner from recorded scores, not supplied winner", () => {
  assert.deepEqual(buildReviewResolution(state, draft), { status: "completed", winner: "A", white_score: 3, black_score: 1, reason: draft.reason });
  assert.equal(buildReviewResolution(state, { ...draft, blackScore: "3" }).winner, null);
});

test("nonrated and conduct-forfeit outcomes never invent score inputs", () => {
  for (const status of ["pending_review", "no_contest", "cancelled", "unranked"]) {
    const result = buildReviewResolution(state, { ...draft, status });
    assert.equal(result.winner, null);
    assert.equal("white_score" in result, false);
  }
  assert.equal(buildReviewResolution(state, { ...draft, status: "forfeit_confirmed" }).winner, "B");
  assert.throws(() => buildReviewResolution(state, { ...draft, status: "forfeit_confirmed", winner: "" }), /actual winning team/);
});

test("a finalized match cannot enter cancellation through rating review", () => {
  assert.throws(() => buildReviewResolution({ ...state, lifecycle: "FINAL" }, { ...draft, status: "cancelled" }), /manual refund review/);
  assert.equal(buildReviewResolution({ ...state, lifecycle: "REVIEW" }, { ...draft, status: "cancelled" }).status, "cancelled");
  assert.equal(buildReviewResolution({ ...state, lifecycle: "FINAL" }, { ...draft, status: "unranked" }).status, "unranked");
});

test("timeline payload allowlists evidence and preserves untouched wall timestamps", () => {
  const result = buildReviewResolution(state, { ...draft, correctTimeline: true, events: [toEventDraft(event)] });
  assert.deepEqual(result.events, [{ id: "entry", type: "JOIN", player_id: "player", second: 90, recorded_at: event.recorded_at, note: "Late arrival" }]);
  assert.equal(result.played_seconds, 3600);
});

test("timeline edits require roster identities and chronological clock and wall times", () => {
  const initial = toEventDraft(event);
  for (const invalid of [
    { ...initial, type: "SET_SR" }, { ...initial, playerId: "replacement" },
    { ...initial, second: "-1" }, { ...initial, second: "3601" }, { ...initial, wallTime: "invalid" },
  ]) assert.throws(() => buildReviewResolution(state, { ...draft, correctTimeline: true, events: [invalid] }));
  assert.throws(() => buildReviewResolution(state, { ...draft, correctTimeline: true, events: [initial, { ...initial, id: "two", second: "80" }] }), /chronological/);
  assert.throws(() => buildReviewResolution(state, { ...draft, correctTimeline: true, events: [initial, initial] }), /unique/);
});

test("clock actions cannot target a player and body limits are validated", () => {
  const result = buildReviewResolution(state, { ...draft, correctTimeline: true, events: [{ ...toEventDraft(event), type: "PAUSE" }] });
  assert.equal(result.events[0].player_id, null);
  for (const change of [{ reason: "short" }, { whiteScore: "" }, { whiteScore: "1.5" }, { blackScore: "1000" }, { status: "SET_RATING" }, { correctTimeline: true, playedSeconds: "10801" }]) {
    assert.throws(() => buildReviewResolution(state, { ...draft, ...change }));
  }
});
