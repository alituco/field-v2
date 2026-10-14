import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import { DEFAULT_SOLO_FORMATION, parseSoloFormation, parseAdminSoloGameCreateInput } from "../src/lib/admin-solo-games.ts";
import { parseAdminGameScheduleInput, serializeGameSchedule } from "../src/lib/admin-game-schedules.ts";
import * as formation from "../src/lib/admin-game-formation.ts";

const { parseGameFormationUpdate, buildAdminGameFormation, loadAdminGameFormation } = formation;
const id = "10000000-0000-4000-8000-000000000001";
const reason = "Use a more attacking formation for this game.";
const base = { ...DEFAULT_SOLO_FORMATION, reason };
const now = new Date("2026-10-14T10:00:00Z");
const game = { goalkeeper_capacity: 2, defender_capacity: 6, attacker_capacity: 6, format_version: "FIELDRUSH_7V7", status: "OPEN", operational_state: "NORMAL", starts_at: "2099-07-25T01:00:00Z" };

test("new solo games and schedules default to one keeper, two defenders and four attackers", () => {
  assert.deepEqual(parseSoloFormation({}, true), { goalkeepersPerSide: 1, defendersPerSide: 2, attackersPerSide: 4 });
  const solo = parseAdminSoloGameCreateInput({ fieldId: id, matchDate: "2099-07-25", ageLabel: "18+" });
  assert.deepEqual([solo.goalkeepersPerSide, solo.defendersPerSide, solo.attackersPerSide], [1, 2, 4]);
  const schedule = parseAdminGameScheduleInput({ name: "Saturday football", fieldId: id, weekdays: [6], kickoffTime: "18:30", startsOn: "2099-07-25" });
  assert.deepEqual([schedule.goalkeepers_per_side, schedule.defenders_per_side, schedule.attackers_per_side], [1, 2, 4]);
});

test("every seven-a-side outfield split is allowed and invalid totals or forged values are rejected", () => {
  for (let defenders = 0; defenders <= 6; defenders++) {
    assert.deepEqual(parseGameFormationUpdate({ ...base, defendersPerSide: defenders, attackersPerSide: 6 - defenders }), { ...base, defendersPerSide: defenders, attackersPerSide: 6 - defenders });
  }
  for (const change of [{ goalkeepersPerSide: 0 }, { goalkeepersPerSide: 2 }, { defendersPerSide: 3 }, { attackersPerSide: -1 }, { defendersPerSide: "2" }, { attackersPerSide: 4.5 }, { defendersPerSide: null }, { reason: "short" }, { actor_admin_id: id }, { capacity: 16 }]) {
    assert.throws(() => parseGameFormationUpdate({ ...base, ...change }));
  }
});

test("partial schedule formation edits require a complete snapshot and retain existing snapshots on ordinary edits", () => {
  assert.deepEqual(parseAdminGameScheduleInput({ ...DEFAULT_SOLO_FORMATION }, true), { goalkeepers_per_side: 1, defenders_per_side: 2, attackers_per_side: 4 });
  assert.throws(() => parseAdminGameScheduleInput({ defendersPerSide: 2 }, true));
  assert.deepEqual(parseAdminGameScheduleInput({ isActive: false }, true), { is_active: false });
  const schedule = serializeGameSchedule({ goalkeepers_per_side: 1, defenders_per_side: 3, attackers_per_side: 3 }, "Saved pitch");
  assert.deepEqual([schedule.goalkeepersPerSide, schedule.defendersPerSide, schedule.attackersPerSide], [1, 3, 3]);
});

test("existing game formation comes from its stored capacities and locks for any booking or payment history", () => {
  const existing = buildAdminGameFormation(game, false, false, null, now);
  assert.deepEqual([existing.goalkeepersPerSide, existing.defendersPerSide, existing.attackersPerSide], [1, 3, 3]);
  assert.equal(existing.canEdit, true);
  for (const [booked, paid] of [[true, false], [false, true], [true, true]]) {
    const result = buildAdminGameFormation(game, booked, paid, null, now);
    assert.equal(result.canEdit, false);
    assert.match(result.lockedReason, /first booking or payment attempt/);
  }
  for (const change of [{ status: "LIVE" }, { status: "CANCELLED" }, { operational_state: "UNDER_REVIEW" }, { starts_at: now.toISOString() }, { teams_assigned_at: now.toISOString() }, { white_score: 0 }, { black_score: 1 }]) {
    assert.equal(buildAdminGameFormation({ ...game, ...change }, false, false, null, now).canEdit, false);
  }
  assert.equal(buildAdminGameFormation(game, false, false, { status: "RUNNING", started_at: now.toISOString(), accumulated_seconds: 1 }, now).canEdit, false);
  assert.equal(buildAdminGameFormation(game, false, false, { status: "NOT_STARTED", started_at: null, accumulated_seconds: 0 }, now).canEdit, true);
  assert.throws(() => buildAdminGameFormation({ ...game, defender_capacity: 5 }, false, false, null, now), /missing or invalid/);
});

function route(actor, error = null) {
  const calls = [];
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200, headers: init.headers }) } },
    "@/lib/admin-game-formation": formation,
    "@/lib/referee-session": {
      requireReferee: async () => actor ? { referee: actor, db: { rpc: async (...args) => { calls.push(args); return { data: {}, error }; } } } : { status: 401 },
      isRefereeContext: (value) => "referee" in value,
      adminOnly: (value) => value.role === "admin" ? null : { status: 403 },
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL("../src/app/api/referee/admin/games/[matchKind]/[gameId]/formation/route.ts", import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, require: (name) => modules[name] });
  return { calls, PATCH: exports.PATCH };
}
const request = (body = base) => ({ json: async () => body });
const params = (changes = {}) => ({ params: Promise.resolve({ gameId: id, matchKind: "solo", ...changes }) });
test("formation edits require authenticated admins before reading input or mutating", async () => {
  for (const [actor, status] of [[null, 401], [{ role: "referee", profileId: id }, 403]]) {
    const api = route(actor);
    assert.equal((await api.PATCH({ json: () => { throw new Error("must not read"); } }, params())).status, status);
    assert.equal(api.calls.length, 0);
  }
});
test("formation route supplies the authenticated actor and complete counts to the atomic server guard", async () => {
  const api = route({ role: "admin", profileId: id });
  const result = await api.PATCH(request(), params());
  assert.equal(result.status, 200);
  assert.equal(result.headers["Cache-Control"], "private, no-store");
  assert.deepEqual(JSON.parse(JSON.stringify(api.calls[0])), ["admin_update_open_queue_game_formation", { actor_admin_id: id, game_id_to_use: id, goalkeepers_per_side_to_use: 1, defenders_per_side_to_use: 2, attackers_per_side_to_use: 4, reason_to_use: reason }]);
  for (const invalid of [{ gameId: "bad" }, { matchKind: "clan" }]) assert.equal((await api.PATCH(request(), params(invalid))).status, 400);
  assert.equal((await api.PATCH(request({ ...base, defendersPerSide: 3 }), params())).status, 400);
  assert.equal(api.calls.length, 1);
});
test("a booking/payment race is a conflict and a missing migration is service-unavailable", async () => {
  for (const [error, status] of [[{ message: "Formation is locked after the first booking or payment attempt." }, 409], [{ code: "PGRST202", message: "Missing function" }, 503]]) {
    const result = await route({ role: "admin", profileId: id }, error).PATCH(request(), params());
    assert.equal(result.status, status);
  }
});
test("formation loader checks all booking/payment history and returns only safe formation details", async () => {
  const calls = [];
  const db = { from(table) {
    const call = { table, select: "", filters: [] }; calls.push(call);
    const query = { select(value) { call.select = value; return query; }, eq(...args) { call.filters.push(args); return query; }, limit() { return query; }, single() { return query; }, maybeSingle() { return query; }, then(resolve) { return Promise.resolve({ error: null, data: table === "open_queue_games" ? game : table === "payment_intents" ? [{ id: "private-intent" }] : table === "open_queue_bookings" ? [] : null }).then(resolve); } };
    return query;
  } };
  const result = await loadAdminGameFormation(db, id);
  assert.equal(result.canEdit, false);
  assert.deepEqual(calls.find((call) => call.table === "payment_intents").filters, [["payload->>game_id", id]]);
  assert.equal(calls.find((call) => call.table === "payment_intents").select, "id");
  assert.doesNotMatch(JSON.stringify(result), /private-intent|payload/);
});
