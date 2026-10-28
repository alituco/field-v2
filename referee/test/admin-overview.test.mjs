import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import { loadAllRows } from "../src/lib/paginated-rows.ts";
import { adminGameStartTimestamp, formatVenueDateTime } from "../src/lib/admin-game-time.ts";

const ts = createRequire(import.meta.url)("typescript");
const now = "2026-10-22T20:00:00.000Z";
const solo = { id: "phoenix", status: "OPEN", starts_at: "2026-10-23T01:30:00Z", timezone: "America/Phoenix", venue: "Phoenix field" };

function database(tables, failure) {
  const calls = [];
  return { calls, from(table) {
    const filters = [];
    const orders = [];
    let range = [0, 999];
    let head = false;
    const chain = {
      select(_columns, options) { head = options?.head === true; return chain; },
      in(key, values) { filters.push((row) => values.includes(row[key])); return chain; },
      eq(key, value) { filters.push((row) => row[key] === value); return chain; },
      is(key, value) { filters.push((row) => (row[key] ?? null) === value); return chain; },
      gte(key, value) { filters.push((row) => row[key] >= value); return chain; },
      lte(key, value) { filters.push((row) => row[key] <= value); return chain; },
      or() { return chain; },
      order(key, options) { orders.push([key, options?.ascending !== false]); return chain; },
      range(from, to) { range = [from, to]; return chain; },
      limit(count) { range = [0, count - 1]; return chain; },
      then(resolve, reject) {
        calls.push({ table, from: range[0], head });
        const error = failure?.(table, range[0]);
        const data = (tables[table] ?? []).filter((row) => filters.every((filter) => filter(row))).sort((left, right) => {
          for (const [key, asc] of orders) {
            const order = String(left[key] ?? "").localeCompare(String(right[key] ?? ""));
            if (order) return asc ? order : -order;
          }
          return 0;
        });
        return Promise.resolve({ data: head ? null : data.slice(range[0], range[1] + 1), count: data.length, error }).then(resolve, reject);
      },
    };
    return chain;
  } };
}

function route(tables = {}, options = {}) {
  const db = database(tables, options.failure);
  const exports = {};
  const modules = {
    "next/server": { NextResponse: { json: (body, init) => ({ body, status: init?.status ?? 200 }) } },
    "@/lib/admin-game-time": { formatVenueDateTime },
    "@/lib/paginated-rows": { loadAllRows },
    "@/lib/admin-moderation": { OPEN_REPORT_STATUSES: ["OPEN", "TRIAGED", "INVESTIGATING"] },
    "@/lib/payment-refunds": { paymentIntentAttention: () => {}, paymentRefundAttention: () => {}, refundNeedsAttention: () => false },
    "@/lib/referee-session": {
      requireReferee: async () => options.signedOut ? { status: 401 } : { db, referee: { role: options.role ?? "admin" } },
      isRefereeContext: (context) => "referee" in context,
      adminOnly: (identity) => identity.role === "admin" ? null : { status: 403 },
    },
  };
  const source = readFileSync(new URL("../src/app/api/referee/admin/overview/route.ts", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, {
    exports, require: (name) => { assert.ok(modules[name], name); return modules[name]; },
    Date: class extends Date { constructor(value) { super(value ?? now); } }, Intl,
  });
  return { ...exports, db };
}

test("upcoming Phoenix games use their absolute start even after Bahrain's apparent start", () => {
  const fixture = { matchDate: "2026-10-22", timeSlot: "6:30 PM - 7:30 PM", timezone: "America/Phoenix", startsAt: solo.starts_at };
  assert.equal(adminGameStartTimestamp(fixture), Date.parse(solo.starts_at));
  assert.ok(adminGameStartTimestamp(fixture) > Date.parse(now));
  assert.ok(Date.parse("2026-10-22T18:30:00+03:00") < Date.parse(now));
});

test("venue labels preserve Phoenix local date and New York daylight-saving time", () => {
  const phoenix = formatVenueDateTime(solo.starts_at, "America/Phoenix");
  assert.match(phoenix, /Oct 22, 2026/);
  assert.match(phoenix, /6:30 PM/);
  assert.match(phoenix, /America\/Phoenix/);
  assert.match(formatVenueDateTime("2026-07-23T01:30:00Z", "America/New_York"), /9:30 PM EDT/);
});

test("overview has no missing-reserve alerts or reserve contribution to attention count", async () => {
  const api = route({
    open_queue_games: [solo],
    fixtures: [{ id: "clan", status: "SCHEDULED", match_date: "2026-10-23", time_slot: "20:30", venue: "Field" }],
  });
  const response = await api.GET({});
  assert.equal(response.status, 200);
  assert.equal(response.body.metrics.gamesNeedingAttention, 2);
  assert.equal(response.body.attention.length, 2);
  assert.ok(response.body.attention.every((item) => item.kind === "GAME_MISSING_REFEREE"));
  assert.equal(api.db.calls.some((call) => call.table === "match_reserve_assignments"), false);
  const notice = response.body.attention.find((item) => item.matchKind === "SOLO");
  assert.match(notice.detail, /Oct 22, 2026.*6:30 PM.*America\/Phoenix.*Phoenix field/);
});

test("overview resolution notices use the historical game's saved timezone", async () => {
  const api = route({
    open_queue_games: [{ ...solo, status: "FINAL" }],
    match_resolution_cases: [{ id: "review", match_kind: "SOLO", open_queue_game_id: solo.id, state: "UNDER_REVIEW", reason_code: "NO_ACTIVITY", scheduled_end_at: "2026-10-23T02:30:00Z", high_priority_at: "2026-10-23T05:00:00Z" }],
  });
  const response = await api.GET({});
  assert.equal(response.status, 200);
  assert.match(response.body.attention[0].detail, /Oct 22, 2026.*7:30 PM.*America\/Phoenix/);
});

test("old assignment history beyond 1,000 rows cannot create a false missing-referee alert", async () => {
  const assignments = Array.from({ length: 1005 }, (_, index) => ({ game_id: `old-${String(index).padStart(4, "0")}` }));
  assignments.push({ game_id: "zz-upcoming" });
  const api = route({ open_queue_games: [{ ...solo, id: "zz-upcoming" }], open_queue_referee_assignments: assignments });
  const response = await api.GET({});
  assert.equal(response.status, 200);
  assert.equal(response.body.attention.length, 0);
  assert.equal(response.body.metrics.gamesNeedingAttention, 0);
  assert.ok(api.db.calls.some((call) => call.table === "open_queue_referee_assignments" && call.from === 1000));
});

test("overview does not silently drop upcoming games beyond a REST response page", async () => {
  const games = Array.from({ length: 1005 }, (_, index) => ({ ...solo, id: `game-${String(index).padStart(4, "0")}` }));
  const api = route({ open_queue_games: games });
  const response = await api.GET({});
  assert.equal(response.status, 200);
  assert.equal(response.body.attention.length, 1005);
  assert.equal(response.body.metrics.gamesNeedingAttention, 1005);
});

test("later overview page failures return an error rather than incorrect alerts", async () => {
  const assignments = Array.from({ length: 501 }, (_, index) => ({ game_id: String(index) }));
  const api = route({ open_queue_referee_assignments: assignments }, { failure: (table, from) => table === "open_queue_referee_assignments" && from === 500 ? { message: "assignment page unavailable" } : null });
  const response = await api.GET({});
  assert.equal(response.status, 500);
  assert.match(response.body.error, /assignment page unavailable/);
});

test("overview remains admin-only", async () => {
  for (const [options, status] of [[{ signedOut: true }, 401], [{ role: "referee" }, 403]]) {
    const api = route({}, options);
    assert.equal((await api.GET({})).status, status);
    assert.equal(api.db.calls.length, 0);
  }
});
