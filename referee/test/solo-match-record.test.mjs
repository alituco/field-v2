import assert from "node:assert/strict";
import test from "node:test";
import { parseMatchRecordRequest, saveMatchRecord, assertMatchRecordResult, assertMatchRecordState, arrivalAtOffset } from "../src/lib/solo-match-record.ts";
import { buildMatchRecord, createRecordDraft, clockSeconds, recordEventPlayingSecond } from "../src/lib/solo-match-record-ui.ts";

const id = n => `d1000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const body = () => ({ expectedRevision: 5, requestId: id(99), preview: false, record: { reason: "", arrivals: [{ profile_id: id(1), arrived_at: "now" }] } });
const state = () => ({ game_id: id(20), revision: 5, lifecycle: "LIVE", started_at: "2026-10-27T00:00:00Z", ended_at: null,
  elapsed_seconds: 1800, can_correct_record: true, white_score: 0, black_score: 0, goals: [], events: [],
  observed_roster: [{ id: id(1), team: "A", booked_role: "ATT" }, { id: id(2), team: "B", booked_role: "ATT" }],
  arrivals: [{ profile_id: id(1), arrived_at: null }, { profile_id: id(2), arrived_at: "2026-10-26T23:40:00.123456Z" }] });
const result = (preview = false) => ({ state: state(), preview, record_input: body().record, impact: { players: [], attendance: [] }, ...(preview ? { preview_token: "server-token" } : {}) });

test("arrival requests accept one server-timed arrival and exclude identity, SR and team inputs", () => {
  assert.deepEqual(parseMatchRecordRequest(body()), body());
  for (const profile_id of ["00000000-0000-0000-0000-000000000001", "d1000000-0000-7000-8000-000000000001"]) {
    assert.equal(parseMatchRecordRequest({ ...body(), record: { reason: "", arrivals: [{ profile_id, arrived_at: "now" }] } }).record.arrivals[0].profile_id, profile_id);
  }
  for (const extra of [{ actorId: id(3) }, { skill_rating: 9000 }, { team: "BLACK" }]) {
    assert.throws(() => parseMatchRecordRequest({ ...body(), record: { ...body().record, ...extra } }), /match facts/);
  }
  assert.throws(() => parseMatchRecordRequest({ ...body(), actor_referee_id: id(3) }), /Refresh/);
  for (const arrivals of [[...body().record.arrivals, ...body().record.arrivals].flat(), [{ profile_id: id(1), arrived_at: "tomorrow" }]]) {
    assert.throws(() => parseMatchRecordRequest({ ...body(), record: { reason: "", arrivals } }), /valid arrival/);
  }
});

test("explicit earlier arrivals and absent corrections require reason; published preview preserves canonical time", () => {
  const record = { reason: "", arrivals: [{ profile_id: id(1), arrived_at: "2026-10-27T00:30:00Z" }] };
  assert.throws(() => parseMatchRecordRequest({ ...body(), record }), /10 characters/);
  assert.equal(parseMatchRecordRequest({ ...body(), record, previewToken: "server-token" }).record.arrivals[0].arrived_at, record.arrivals[0].arrived_at);
  assert.throws(() => parseMatchRecordRequest({ ...body(), record: { ...record, arrivals: [{ profile_id: id(1), arrived_at: null }] } }), /10 characters/);
});

test("RPC uses authenticated actor, original request, revision and preview binding without extra writes", async () => {
  const calls = [];
  const db = { rpc: async (name, args) => { calls.push({ name, args }); return { data: result(), error: null }; } };
  await saveMatchRecord(db, id(7), id(20), { ...body(), previewToken: "checked-token" });
  assert.deepEqual(calls, [{ name: "referee_save_solo_match_record", args: {
    actor_referee_id: id(7), game_id_to_use: id(20), request_id_to_use: id(99), expected_revision: 5,
    record_input: body().record, preview_only: false, preview_token_to_use: "checked-token",
  } }]);
  const error = { message: "Changed record", code: "40001" };
  await assert.rejects(saveMatchRecord({ rpc: async () => ({ data: null, error }) }, id(7), id(20), body()), failure => failure.code === "40001");
});

test("missing and wrong-game acknowledgements stay failures; preview requires server token and resolved input", () => {
  for (const invalid of [null, {}, { ...result(), state: { ...state(), game_id: id(40) } }, { ...result(), preview: true },
    { ...result(true), preview_token: undefined }, { ...result(true), record_input: null }]) {
    assert.throws(() => assertMatchRecordResult(invalid, id(20), invalid?.preview === true), /not acknowledged/);
  }
  assertMatchRecordResult(result(true), id(20), true);
});

test("single arrival is wall time after actual kickoff, never a guessed playing-clock JOIN", () => {
  const draft = createRecordDraft(state(), id(1));
  draft.arrivals[0] = { ...draft.arrivals[0], mode: "AT", minutes: "30" };
  draft.reason = "Arrival verified with the referee.";
  assert.deepEqual(buildMatchRecord(state(), draft), { reason: draft.reason, arrivals: [{ profile_id: id(1), arrived_at: "2026-10-27T00:30:00.000Z" }] });
  assert.equal(arrivalAtOffset(state().started_at, "-15"), "2026-10-26T23:45:00.000Z");
  assert.equal("events" in buildMatchRecord(state(), draft), false);
});

test("opening a correction preserves exact existing arrival precision and finished games disallow arrived now", () => {
  const draft = createRecordDraft(state(), id(2)); draft.reason = "Reviewed the recorded arrival time.";
  assert.equal(buildMatchRecord(state(), draft).arrivals[0].arrived_at, state().arrivals[1].arrived_at);
  draft.arrivals[1].mode = "NOW";
  assert.throws(() => buildMatchRecord({ ...state(), lifecycle: "FINAL" }, draft), /finished game/);
});

test("goals derive scorer team and assist from original roster, never a bare score override", () => {
  const draft = createRecordDraft(state()); draft.correctGoals = true; draft.reason = "Corrected the goal from the recording.";
  draft.goals = [{ key: "new", team: "WHITE", playerId: id(1), assistId: "", clock: "23:45" }];
  assert.deepEqual(buildMatchRecord(state(), draft).goals, [{ team: "WHITE", profile_id: id(1), assist_profile_id: null, second: 1425 }]);
  assert.throws(() => buildMatchRecord(state(), { ...draft, goals: [{ ...draft.goals[0], assistId: id(2) }] }), /teammate/);
  assert.throws(() => parseMatchRecordRequest({ ...body(), record: { reason: draft.reason, white_score: 1, black_score: 0 } }), /recorded goals/);
  const valid = parseMatchRecordRequest({ ...body(), record: buildMatchRecord(state(), draft) });
  assert.equal(valid.record.goals[0].second, 1425);
});

test("clock and timeline corrections bound actual playing seconds and retain original event timestamps", () => {
  assert.equal(clockSeconds("30:05", "Playing time"), 1805);
  for (const time of ["30", "-1:00", "1:90", "181:00"]) assert.throws(() => clockSeconds(time, "Playing time"));
  const withEvent = { ...state(), lifecycle: "FINAL", events: [{ id: id(50), type: "EXCUSED_LEAVE", player_id: id(2), second: 600, recorded_at: "2026-10-27T00:10:00.123456Z", note: "Injury" }] };
  const draft = createRecordDraft(withEvent); draft.correctTimeline = true; draft.reason = "Verified the clock against the recording.";
  assert.equal(buildMatchRecord(withEvent, draft).events[0].recorded_at, withEvent.events[0].recorded_at);
  draft.events[0].wallMinutes = "31";
  assert.throws(() => buildMatchRecord(withEvent, draft), /later than/);
});


test("correcting a timeline after a late arrival omits the real derived JOIN key and passes API validation", () => {
  const joined = { ...state(), events: [
    { id: `${id(99)}:${id(1)}`, type: "JOIN", player_id: id(1), second: 600, recorded_at: "2026-10-27T00:10:00Z", note: "Arrival recorded as entry into play." },
    { id: id(50), type: "EXCUSED_LEAVE", player_id: id(1), second: 900, recorded_at: "2026-10-27T00:15:00Z", note: "Injury" },
  ] };
  const draft = createRecordDraft(joined); draft.correctTimeline = true; draft.reason = "Corrected the actual injury time.";
  draft.events[1].wallMinutes = "16";
  const record = buildMatchRecord(joined, draft);
  assert.equal(draft.events[0].type, "JOIN", "arrival still appears read-only in the editor");
  assert.deepEqual(record.events.map(event => event.type), ["EXCUSED_LEAVE"]);
  assert.equal(record.events[0].second, 960);
  assert.equal(record.events[0].recorded_at, "2026-10-27T00:16:00.000Z");
  assert.deepEqual(parseMatchRecordRequest({ ...body(), record }).record, record);
  assert.throws(() => parseMatchRecordRequest({ ...body(), record: { reason: draft.reason, events: [joined.events[0]] } }), /valid participation/);
});

test("one actual event time derives the playing clock through pauses, including a late arrival", () => {
  const paused = { ...state(), elapsed_seconds: 2400, events: [
    { id: id(51), type: "PAUSE", player_id: null, second: 1200, recorded_at: "2026-10-27T00:20:00Z" },
    { id: `${id(99)}:${id(1)}`, type: "JOIN", player_id: id(1), second: 1200, recorded_at: "2026-10-27T00:23:00Z" },
    { id: id(52), type: "RESUME", player_id: null, second: 1200, recorded_at: "2026-10-27T00:25:00Z" },
    { id: id(53), type: "EXCUSED_LEAVE", player_id: id(1), second: 1500, recorded_at: "2026-10-27T00:30:00Z", note: "Injury" },
  ] };
  const draft = createRecordDraft(paused); draft.correctTimeline = true; draft.reason = "Verified the actual pause and injury times.";
  draft.events[3].wallMinutes = "32";
  draft.events[3].clock = "1:00"; // No editable second clock can override the actual time.
  const record = buildMatchRecord(paused, draft);
  assert.deepEqual(record.events.map(event => [event.type, event.second]), [["PAUSE", 1200], ["RESUME", 1200], ["EXCUSED_LEAVE", 1620]]);
  assert.equal(recordEventPlayingSecond(paused, draft.events, draft.events[1]), 1200);
  draft.events[0].wallMinutes = "18";
  const correctedPause = buildMatchRecord(paused, draft);
  assert.deepEqual(correctedPause.events.map(event => [event.type, event.second]), [["PAUSE", 1080], ["RESUME", 1080], ["EXCUSED_LEAVE", 1500]]);
});

test("equal-time pause and resume events preserve sequence instead of sorting random IDs", () => {
  const tied = { ...state(), events: [
    { id: id(90), type: "PAUSE", player_id: null, second: 600, recorded_at: "2026-10-27T00:10:00Z" },
    { id: id(10), type: "RESUME", player_id: null, second: 600, recorded_at: "2026-10-27T00:10:00Z" },
  ] };
  const draft = createRecordDraft(tied); draft.correctTimeline = true; draft.reason = "Verified the pause and immediate resume.";
  assert.deepEqual(buildMatchRecord(tied, draft).events.map(event => [event.id, event.second]), [[id(90), 600], [id(10), 600]]);
  draft.events.reverse();
  assert.throws(() => buildMatchRecord(tied, draft), /actual order/);
});


test("incomplete match state and malformed consequence rows cannot be accepted as a successful save", () => {
  for (const patch of [{ observed_roster: undefined }, { events: undefined }, { goals: undefined }, { started_at: "invalid" },
    { arrivals: [{ profile_id: id(1), arrived_at: "invalid" }] }, { events: [{ id: "derived", type: "JOIN", second: 10, recorded_at: "bad", player_id: id(1) }] },
    { record_revisions: [{ revision: 6, reason: "Corrected arrival", recorded_at: "bad", actor_id: id(7) }] }]) {
    assert.throws(() => assertMatchRecordState({ ...state(), ...patch }, id(20)), /incomplete/);
    assert.throws(() => assertMatchRecordResult({ ...result(), state: { ...state(), ...patch } }, id(20), false), /not acknowledged/);
  }
  for (const player of [{ profile_id: id(1), before: null, after: {} }, { profile_id: id(1), before: {}, after: { sr: "1000" } },
    { profile_id: id(1), before: {}, after: { arrived_at: "yesterday" } }]) {
    assert.throws(() => assertMatchRecordResult({ ...result(), impact: { players: [player], attendance: [] } }, id(20), false), /not acknowledged/);
  }
  assertMatchRecordState({ ...state(), white_score: null, black_score: null }, id(20));
});


test("live timeline corrections omit stale clock totals while finished duration remains explicit", () => {
  const liveDraft = createRecordDraft(state()); liveDraft.correctTimeline = true; liveDraft.reason = "Corrected the actual pause history.";
  assert.equal("played_seconds" in buildMatchRecord(state(), liveDraft), false);
  const finalState = { ...state(), lifecycle: "FINAL" };
  const finalDraft = createRecordDraft(finalState); finalDraft.correctTimeline = true; finalDraft.reason = liveDraft.reason; finalDraft.clock = "25:00";
  assert.equal(buildMatchRecord(finalState, finalDraft).played_seconds, 1500);
});

test("booking eligibility preview requires actual booleans and complete total strike values", () => {
  const attendance = { profile_id: id(1), changed: true, before: { active_strikes: 3, can_book: false }, after: { active_strikes: 2, can_book: true } };
  assertMatchRecordResult({ ...result(true), impact: { players: [], attendance: [attendance] } }, id(20), true);
  for (const invalid of [{ ...attendance, after: undefined }, { ...attendance, after: { active_strikes: 2, can_book: "yes" } },
    { ...attendance, before: { can_book: false } }]) {
    assert.throws(() => assertMatchRecordResult({ ...result(true), impact: { players: [], attendance: [invalid] } }, id(20), true), /not acknowledged/);
  }
  assertMatchRecordResult({ ...result(), impact: { players: [], attendance: [{ profile_id: id(1), changed: false }] } }, id(20), false);
});


test("final duration moves its generated whistle instead of submitting an old terminal pause", () => {
  const finished = { ...state(), lifecycle: "FINAL", elapsed_seconds: 3600, ended_at: "2026-10-27T01:00:00Z", events: [
    { id: `${id(99)}:finish`, type: "PAUSE", player_id: null, second: 3600, recorded_at: "2026-10-27T01:00:00Z", note: "Referee ended the match." },
  ] };
  const draft = createRecordDraft(finished); draft.correctTimeline = true; draft.reason = "Actual play stopped at minute 25."; draft.clock = "25:00";
  const corrected = buildMatchRecord(finished, draft);
  assert.equal(corrected.played_seconds, 1500);
  assert.deepEqual(corrected.events, []);
  assert.deepEqual(parseMatchRecordRequest({ ...body(), record: corrected }).record, corrected);
  const live = { ...finished, lifecycle: "LIVE" };
  const reopenedDraft = createRecordDraft(live); reopenedDraft.correctTimeline = true; reopenedDraft.reason = "Confirmed the previous full-time pause.";
  const preserved = buildMatchRecord(live, reopenedDraft);
  assert.equal(preserved.events[0].id, `${id(99)}:finish`);
  assert.equal(parseMatchRecordRequest({ ...body(), record: preserved }).record.events[0].type, "PAUSE");
  const endedWhilePaused = { ...finished, elapsed_seconds: 1200, ended_at: "2026-10-27T00:30:00Z", events: [
    { ...finished.events[0], second: 600, recorded_at: "2026-10-27T00:10:00Z" },
    { id: id(30), type: "RESUME", player_id: null, second: 600, recorded_at: "2026-10-27T00:15:00Z" },
    { id: id(31), type: "PAUSE", player_id: null, second: 1200, recorded_at: "2026-10-27T00:25:00Z", note: "Stopped for injury" },
  ] };
  const pausedDraft = createRecordDraft(endedWhilePaused); pausedDraft.correctTimeline = true; pausedDraft.reason = "Verified the actual pause history.";
  assert.deepEqual(buildMatchRecord(endedWhilePaused, pausedDraft).events.map(event => event.type), ["PAUSE", "RESUME", "PAUSE"]);
});


test("transport failures and incomplete RPC acknowledgements stay uncertain rather than becoming rejected writes", async () => {
  for (const rpc of [
    async () => ({ data: null, error: null }),
    async () => ({ data: { ...result(), impact: null }, error: null }),
    async () => ({ data: null, error: { message: "fetch failed", code: "" } }),
    async () => { throw new Error("Connection reset after sending the write"); },
  ]) {
    await assert.rejects(saveMatchRecord({ rpc }, id(7), id(20), body()), failure => failure.code === "MATCH_RECORD_ACK_UNKNOWN");
  }
});
