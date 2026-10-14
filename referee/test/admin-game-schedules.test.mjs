import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import * as schedules from "../src/lib/admin-game-schedules.ts";
import * as fields from "../src/lib/admin-fields.ts";
import * as soloGames from "../src/lib/admin-solo-games.ts";

const { parseAdminGameScheduleInput: parse, parseScheduleSkipInput, serializeGameSchedule } = schedules;
const id = "10000000-0000-4000-8000-000000000001";
const base = { name: "Saturday football", fieldId: id, weekdays: [6], kickoffTime: "18:15", startsOn: "2099-07-25" };

test("weekly Saturday schedules use Phoenix defaults, 60 minutes, $13, and four weeks", () => {
  assert.deepEqual(parse(base), { name: base.name, field_id: id, weekdays: [6], kickoff_time: "18:15", duration_minutes: 60,
    starts_on: "2099-07-25", ends_on: null, booking_window_days: 28, price_fils: 13000, age_label: "18+", highest_division: 1, lowest_division: 5,
    goalkeepers_per_side: 1, defenders_per_side: 2, attackers_per_side: 4, is_active: true });
  const custom = parse({ ...base, weekdays: [7, 2, 6], durationMinutes: 90, priceUsd: "15.50", bookingWindowDays: 42, highestDivision: 2, lowestDivision: 4 });
  assert.deepEqual(custom.weekdays, [2, 6, 7]);
  assert.equal(custom.price_fils, 15500);
  assert.equal(custom.duration_minutes, 90);
  assert.equal(custom.highest_division, 2);
  assert.equal(custom.lowest_division, 4);
});

test("schedule input rejects invalid and duplicate weekdays, dates, money, duration and windows", () => {
  for (const invalid of [
    { weekdays: [] }, { weekdays: [6, 6] }, { weekdays: [0] }, { weekdays: [8] }, { weekdays: ["6"] },
    { startsOn: "2099-02-29" }, { startsOn: "2099-04-31" }, { endsOn: "2099-07-24" },
    { kickoffTime: "24:00" }, { kickoffTime: "18:15:30" }, { fieldId: "park" },
    { durationMinutes: 29 }, { durationMinutes: 181 }, { durationMinutes: "90" }, { durationMinutes: 30.5 },
    { bookingWindowDays: 6 }, { bookingWindowDays: 85 }, { bookingWindowDays: "28" },
    { priceUsd: "13.001" }, { priceUsd: "101" }, { priceUsd: false }, { priceUsd: "1e1" },
    { highestDivision: null }, { highestDivision: "1" }, { highestDivision: 0 }, { highestDivision: 6 }, { highestDivision: 1.5 },
    { lowestDivision: null }, { lowestDivision: "5" }, { lowestDivision: 0 }, { lowestDivision: 6 }, { lowestDivision: 4.5 },
    { highestDivision: 4, lowestDivision: 2 },
    { isActive: "false" }, { actor_admin_id: id }, { timezone: "Asia/Bahrain" }, { currency: "BHD" },
  ]) assert.throws(() => parse({ ...base, ...invalid }), JSON.stringify(invalid));
});

test("partial division edits validate each bound and reject reversed ranges when both are supplied", () => {
  assert.deepEqual(parse({ highestDivision: 2 }, true), { highest_division: 2 });
  assert.deepEqual(parse({ lowestDivision: 4 }, true), { lowest_division: 4 });
  assert.deepEqual(parse({ highestDivision: 2, lowestDivision: 4 }, true), { highest_division: 2, lowest_division: 4 });
  for (const body of [
    { highestDivision: null }, { highestDivision: "2" }, { highestDivision: 0 }, { highestDivision: 6 }, { highestDivision: 2.5 },
    { lowestDivision: null }, { lowestDivision: "4" }, { lowestDivision: 0 }, { lowestDivision: 6 }, { lowestDivision: 4.5 },
    { highestDivision: 5, lowestDivision: 1 },
  ]) assert.throws(() => parse(body, true), JSON.stringify(body));
});

test("schedule creation and partial price edits accept free games or whole cents from $0.50 to $100", () => {
  for (const priceUsd of ["0", "0.00", 0, "0.50", 0.5, "100.00", 100]) {
    const expected = Math.round(Number(priceUsd) * 1000);
    assert.equal(parse({ ...base, priceUsd }).price_fils, expected);
    assert.deepEqual(parse({ priceUsd }, true), { price_fils: expected });
  }
  for (const priceUsd of ["0.01", "0.49", 0.01, 0.49, "0.001", "100.01"]) {
    assert.throws(() => parse({ ...base, priceUsd }), /Price/);
    assert.throws(() => parse({ priceUsd }, true), /Price/);
  }
});

test("pausing only changes active state; partial edits cannot silently clear missing settings", () => {
  assert.deepEqual(parse({ isActive: false }, true), { is_active: false });
  assert.deepEqual(parse({ priceUsd: "0" }, true), { price_fils: 0 });
  assert.deepEqual(parse({ endsOn: null }, true), { ends_on: null });
  for (const invalid of [{}, { durationMinutes: null }, { priceUsd: null }, { startsOn: null }, { isActive: null }]) assert.throws(() => parse(invalid, true));
});

test("skip-date requests require a date, a real boolean and an audit reason", () => {
  assert.deepEqual(parseScheduleSkipInput({ matchDate: "2099-12-25", reason: " Holiday closure ", skip: true }), { matchDate: "2099-12-25", reason: "Holiday closure", skip: true });
  for (const body of [{}, { matchDate: "2099-12-25", reason: "ok", skip: true }, { matchDate: "2099-02-30", reason: "Holiday", skip: true }, { matchDate: "2099-12-25", reason: "Holiday", skip: "true" }]) assert.throws(() => parseScheduleSkipInput(body));
});

test("schedule serialization includes conflict and skip information, never admin identity", () => {
  const input = { ...parse(base), id, timezone: "America/Phoenix", created_by: "private", created_at: "now", updated_at: "now" };
  const result = serializeGameSchedule(input, "Encanto", [{ match_date: "2099-07-25", status: "CONFLICT", error_message: "Pitch occupied", game_id: null }], [{ match_date: "2099-08-01", reason: "Holiday" }]);
  assert.equal(result.priceUsd, "13.00");
  assert.equal(result.highestDivision, 1);
  assert.equal(result.lowestDivision, 5);
  assert.equal(result.occurrences[0].errorMessage, "Pitch occupied");
  assert.equal(result.skips[0].reason, "Holiday");
  assert.equal(result.created_by, undefined);
});

const require = createRequire(import.meta.url);
const ts = require("typescript");
const routeFiles = [
  ["route.ts", "GET"], ["route.ts", "POST"], ["[id]/route.ts", "PATCH"],
  ["[id]/skip/route.ts", "POST"], ["[id]/generate/route.ts", "POST"],
];

function route(file, actor = { profileId: id, role: "admin" }) {
  const calls = [];
  const db = { rpc: async (...args) => { calls.push(args); return { data: {}, error: null }; }, from: () => { throw new Error("Unexpected DB read"); } };
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200 }) } },
    "@/lib/admin-game-schedules": schedules,
    "@/lib/admin-fields": fields,
    "@/lib/admin-solo-games": soloGames,
    "@/lib/referee-session": {
      requireReferee: async () => actor ? { referee: actor, db } : { body: { error: "Sign in required" }, status: 401 },
      isRefereeContext: (context) => "referee" in context,
      adminOnly: (referee) => referee.role === "admin" ? null : { body: { error: "Admin required" }, status: 403 },
    },
  };
  const source = readFileSync(new URL(`../src/app/api/referee/admin/game-schedules/${file}`, import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, require: (name) => { if (!(name in modules)) throw new Error(`Unknown dependency ${name}`); return modules[name]; }, Intl, Date });
  return { exports, calls };
}

test("all schedule endpoints deny unauthenticated or referee-only callers before database access", async () => {
  for (const [file, method] of routeFiles) for (const [actor, status] of [[null, 401], [{ profileId: id, role: "referee" }, 403]]) {
    const { exports, calls } = route(file, actor);
    const result = await exports[method]({ json: async () => base }, { params: Promise.resolve({ id }) });
    assert.equal(result.status, status, `${file} ${method}`);
    assert.equal(calls.length, 0);
  }
});

test("schedule writes pass only validated values and the authenticated actor to guarded RPCs", async () => {
  const post = route("route.ts");
  assert.equal((await post.exports.POST({ json: async () => base })).status, 201);
  assert.equal(post.calls[0][0], "admin_save_game_schedule");
  assert.equal(post.calls[0][1].actor_admin_id, id);
  assert.deepEqual(post.calls[0][1].values_to_use, parse(base));
  const patch = route("[id]/route.ts");
  assert.equal((await patch.exports.PATCH({ json: async () => ({ isActive: false }) }, { params: Promise.resolve({ id }) })).status, 200);
  assert.deepEqual(patch.calls[0][1].values_to_use, { is_active: false });
  for (const [file, method] of routeFiles.filter((item) => item[1] !== "GET")) {
    const endpoint = route(file);
    const result = await endpoint.exports[method]({ json: async () => ({ ...base, actor_admin_id: "forged" }) }, { params: Promise.resolve({ id: "invalid" }) });
    assert.equal(result.status, 400);
    assert.equal(endpoint.calls.length, 0);
  }
});
