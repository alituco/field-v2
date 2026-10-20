import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import vm from "node:vm";

import * as data from "../src/lib/broadcast-overlay-data.ts";
import { soloScheduledDurationSeconds } from "../src/lib/match-duration.ts";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const { NextResponse } = require("next/server");
const now = "2026-10-19T21:00:00.000Z";
const goal = (id, team, createdAt = now, player = { display_name: "Ali" }) => ({
  id, team, clan_id: team, minute: 18, created_at: createdAt, player,
});

test("clock/schedule metadata normalizes missing values and invalid timezones safely", () => {
  assert.deepEqual(data.overlayClock(null, 5400), {
    status: "NOT_STARTED", started_at: null, accumulated_seconds: 0,
    duration_seconds: 5400, updated_at: null,
  });
  const clock = data.overlayClock({ status: "PAUSED", accumulated_seconds: "45", duration_seconds: 5400, updated_at: now });
  assert.equal(clock.accumulated_seconds, 45);
  assert.equal(clock.updated_at, now);
  assert.equal(data.overlayTimestamp("2026-10-19T14:00:00-07:00"), now);
  for (const value of [null, "", "bad", "2026-10-19", {}, 1234]) {
    assert.equal(data.overlayTimestamp(value), null);
  }
  assert.equal(data.overlayTimeZone("America/Phoenix"), "America/Phoenix");
  for (const value of [null, {}, "invalid/timezone"]) assert.equal(data.overlayTimeZone(value), "Asia/Bahrain");
});

test("halftime needs a paused clock and a midpoint or explicit halftime pause", () => {
  const clock = data.overlayClock({ status: "PAUSED", accumulated_seconds: 1800, duration_seconds: 3600 });
  assert.equal(data.overlayHalftimePaused(clock, null), true);
  assert.equal(data.overlayHalftimePaused({ ...clock, status: "RUNNING" }, null), false);
  assert.equal(data.overlayHalftimePaused({ ...clock, status: "ENDED" }, null), false);
  const earlier = { ...clock, accumulated_seconds: 1560 };
  assert.equal(data.overlayHalftimePaused(earlier, { event_type: "MATCH_PAUSED", minute: 26, second: 0, note: "Injury" }), false);
  assert.equal(data.overlayHalftimePaused(earlier, { event_type: "MATCH_PAUSED", minute: 26, second: 0, note: "Half-time break" }), true);
  assert.equal(data.overlayHalftimePaused(earlier, { event_type: "GOAL", note: "half time" }), false);
});

test("live scores use current goal rows; published final corrections remain authoritative", () => {
  const input = { status: "LIVE", goals: [goal("one", "WHITE")], sideField: "team", homeSide: "WHITE", awaySide: "BLACK", homeScore: 4, awayScore: 2 };
  assert.deepEqual(data.overlayScores(input), { homeScore: 1, awayScore: 0 });
  assert.deepEqual(data.overlayScores({ ...input, status: "FINAL" }), { homeScore: 4, awayScore: 2 });
  assert.deepEqual(data.overlayScores({ ...input, goals: [], status: "FINAL" }), { homeScore: 4, awayScore: 2 });
  assert.deepEqual(data.overlayScores({ ...input, homeScore: null, awayScore: null, status: "FINAL" }), { homeScore: 1, awayScore: 0 });
  assert.deepEqual(data.overlayScores({ ...input, goals: [], homeScore: null, awayScore: NaN }), { homeScore: 0, awayScore: 0 });
});

test("goal metadata only comes from still-existing goal rows, not score changes", () => {
  const first = goal("one", "WHITE", "2026-10-19T20:59:00.000Z");
  const latest = goal("two", "BLACK", now, [{ display_name: "", username: "mahmoney" }]);
  assert.deepEqual(data.latestOverlayGoal([latest, first], "team", "WHITE", "BLACK"), {
    id: "two", createdAt: now, minute: 18, scorerName: "mahmoney", team: "AWAY",
  });
  assert.equal(data.latestOverlayGoal([first], "team", "WHITE", "BLACK").id, "one");
  assert.equal(data.latestOverlayGoal([], "team", "WHITE", "BLACK"), null);
  assert.equal(data.latestOverlayGoal([{ ...latest, created_at: "invalid" }, { ...latest, team: "OTHER" }], "team", "WHITE", "BLACK"), null);
  assert.equal(data.latestOverlayGoal([goal("anon", "WHITE", now, null)], "team", "WHITE", "BLACK").scorerName, "Player");
  assert.equal(data.latestOverlayGoal([goal("clean", "home", now, { display_name: "  Ali\n\u0000 A.  " })], "clan_id", "home", "away").scorerName, "Ali A.");
});

function harness(kind, { authorized = true, status = "LIVE", publishedHome = 4, rows, pause = null } = {}) {
  const solo = kind === "SOLO";
  const calls = [];
  const db = { from(table) {
    calls.push({ table, select: null, filters: [] });
    const call = calls.at(-1);
    let result;
    if (table === "open_queue_games") result = { id: "game", status, white_score: publishedHome, black_score: 2, starts_at: now, ends_at: "2026-10-19T22:30:00.000Z", timezone: "America/Phoenix" };
    else if (table === "fixtures") result = { id: "game", status, home_score: publishedHome, away_score: 2, home_clan_id: "home", away_clan_id: "away", home_clan: [{ name: "Home", tag: "HOM", emblem: "⚽" }], away_clan: { name: "Away", tag: "AWY", emblem: "⚽" } };
    else if (table.endsWith("clock_states")) result = { status: "PAUSED", started_at: null, accumulated_seconds: 1800, duration_seconds: 3600, updated_at: now };
    else if (table.endsWith("events")) result = pause;
    else result = rows ?? [goal("current-goal", solo ? "WHITE" : "home")];
    const response = () => Promise.resolve({ data: result, error: null });
    const query = {
      select(value) { call.select = value; return query; },
      eq(key, value) { call.filters.push([key, value]); return query; },
      order() { return query; }, limit() { return query; },
      single: response, maybeSingle: response,
      then(resolve, reject) { return response().then(resolve, reject); },
    };
    return query;
  } };
  const modules = {
    "next/server": { NextResponse },
    "@/lib/broadcast-agent-auth": { authorizeBroadcastOverlay: async (...args) => { calls.push({ auth: args }); return authorized; } },
    "@/lib/supabase-admin": { createSupabaseAdmin: () => db },
    "@/lib/match-duration": { soloScheduledDurationSeconds },
    "@/lib/broadcast-overlay-data": data,
  };
  const path = solo ? "../src/app/api/broadcast-overlay/open-queue/[gameId]/route.ts" : "../src/app/api/broadcast-overlay/[fixtureId]/route.ts";
  const compiled = ts.transpileModule(readFileSync(new URL(path, import.meta.url), "utf8"), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, Date, Intl, require: name => { assert.ok(name in modules, name); return modules[name]; } });
  const get = () => exports.GET(new Request("https://ops.example/overlay", { headers: { authorization: "Bearer private-test-token" } }), { params: Promise.resolve(solo ? { gameId: "game" } : { fixtureId: "game" }) });
  return { get, calls };
}

for (const kind of ["SOLO", "CLAN"]) {
  test(`${kind} route preserves authorization and serves enriched non-cacheable actual-goal data`, async () => {
    const h = harness(kind);
    const response = await h.get();
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    const payload = await response.json();
    assert.ok(Number.isFinite(Date.parse(payload.serverTime)));
    assert.equal(payload.scheduledStart, kind === "SOLO" ? now : null);
    assert.equal(payload.timeZone, kind === "SOLO" ? "America/Phoenix" : "Asia/Bahrain");
    assert.equal(payload.clock.updated_at, now);
    assert.equal(payload.halftimeSeconds, 1800);
    assert.equal(payload.halftimePaused, true);
    assert.deepEqual(payload.latestGoal, { id: "current-goal", createdAt: now, minute: 18, scorerName: "Ali", team: "HOME" });
    assert.equal(payload.homeScore, 1);
    assert.equal(payload.awayScore, 0);
    assert.equal(h.calls[0].auth[1], kind);
    assert.equal(h.calls[0].auth[2], "game");
    assert.ok(h.calls.some(call => call.select?.includes("profile_id_fkey(display_name,username)")));
  });

  test(`${kind} final corrections can change score without fabricating a goal announcement`, async () => {
    const h = harness(kind, { status: "FINAL", rows: [] });
    const payload = await (await h.get()).json();
    assert.equal(payload.homeScore, 4);
    assert.equal(payload.awayScore, 2);
    assert.equal(payload.latestGoal, null);
  });

  test(`${kind} denied overlay never reads match data`, async () => {
    const h = harness(kind, { authorized: false });
    const response = await h.get();
    assert.equal(response.status, 401);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal(h.calls.some(call => call.table), false);
  });
}
