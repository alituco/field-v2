import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";

const ts = createRequire(import.meta.url)("typescript");
const modules = new Map();

// Exercise the real loaders and their hydration dependencies. Transpiling the
// existing extensionless imports mirrors the route-test setup without a server.
function loadModule(url) {
  if (modules.has(url.href)) return modules.get(url.href);
  const exports = {};
  modules.set(url.href, exports);
  const source = readFileSync(url, "utf8");
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  vm.runInNewContext(compiled, {
    exports,
    console,
    require: (name) => {
      assert.ok(name.startsWith("."), `Unexpected runtime dependency: ${name}`);
      return loadModule(new URL(`${name.replace(/\.ts$/, "")}.ts`, url));
    },
  });
  return exports;
}

const { loadRefereeOpenQueueGames, loadAdminOpenQueueGame, loadAdminOpenQueueGames } = loadModule(new URL("../src/lib/open-queue-referee-data.ts", import.meta.url));
const { loadRefereeFixtures, loadAdminFixture } = loadModule(new URL("../src/lib/referee-data.ts", import.meta.url));
const REFEREE = "referee-one";

function database(tables, failures = {}) {
  const calls = [];
  const db = {
    calls,
    rpc: async (name, args) => {
      calls.push({ table: `rpc:${name}`, args });
      return { data: null, error: null };
    },
    from(table) {
      const filters = [];
      const orders = [];
      let range = [0, 999]; // Match Supabase's default response cap.
      const chain = {
        select() { return chain; },
        eq(column, value) { filters.push((row) => row[column] === value); return chain; },
        in(column, values) { filters.push((row) => values.includes(row[column])); return chain; },
        is(column, value) { filters.push((row) => (row[column] ?? null) === value); return chain; },
        not(column, operator, value) {
          assert.equal(operator, "is");
          filters.push((row) => (row[column] ?? null) !== value);
          return chain;
        },
        gte(column, value) { filters.push((row) => row[column] >= value); return chain; },
        order(column, options = {}) { orders.push([column, options.ascending !== false]); return chain; },
        limit(count) { range = [0, count - 1]; return chain; },
        range(from, to) { range = [from, to]; return chain; },
        async maybeSingle() {
          const result = await chain;
          return { ...result, data: result.data?.[0] ?? null };
        },
        then(resolve, reject) {
          calls.push({ table, range: [...range] });
          const error = typeof failures[table] === "function"
            ? failures[table](range)
            : failures[table];
          let rows = (tables[table] ?? []).filter((row) => filters.every((filter) => filter(row)));
          rows = [...rows].sort((left, right) => {
            for (const [column, ascending] of orders) {
              const order = String(left[column] ?? "").localeCompare(String(right[column] ?? ""));
              if (order) return ascending ? order : -order;
            }
            return 0;
          });
          return Promise.resolve({ data: error ? null : rows.slice(range[0], range[1] + 1), error: error ?? null }).then(resolve, reject);
        },
      };
      return chain;
    },
  };
  return db;
}

function solo(id, status, startsAt = "2099-10-17T23:30:00Z") {
  return {
    id, status, venue: "Diablo", starts_at: startsAt,
    ends_at: new Date(Date.parse(startsAt) + 60 * 60 * 1000).toISOString(),
    timezone: "America/Phoenix",
  };
}

function clan(id, status, overrides = {}) {
  return {
    id, status, venue: "Diablo", day: "SATURDAY", time_slot: "4:30 PM - 5:30 PM",
    match_date: "2099-10-17", home_clan: { id: "clan-home", name: "Home" },
    away_clan_id: "clan-away", away_clan: { id: "clan-away", name: "Away" },
    ...overrides,
  };
}

function assignments(rows, column) {
  return rows.map((row) => ({ [column]: row.id, referee_id: REFEREE }));
}

test("solo assignments include OPEN, FULL, old LIVE, FINAL and CANCELLED games only for this referee", async () => {
  const assigned = [
    solo("open", "OPEN"), solo("full", "FULL"),
    solo("live-old", "LIVE", "2000-01-01T23:30:00Z"),
    solo("final-old", "FINAL", "2000-01-02T23:30:00Z"),
    solo("cancelled-old", "CANCELLED", "2000-01-03T23:30:00Z"),
  ];
  const db = database({
    open_queue_referee_assignments: [
      ...assignments(assigned, "game_id"),
      { game_id: "another-referee", referee_id: "referee-two" },
    ],
    open_queue_games: [...assigned, solo("unassigned", "OPEN"), solo("another-referee", "FULL")],
    open_queue_bookings: [{ game_id: "open", profile_id: "player-one", role: "GK", team: null, status: "CONFIRMED", profiles: { display_name: "Ali" } }],
  });
  const results = await loadRefereeOpenQueueGames(db, REFEREE);
  assert.deepEqual([...results.map((row) => row.id)].sort(), assigned.map((row) => row.id).sort());
  const open = results.find((row) => row.id === "open");
  assert.equal(open.players[0].displayName, "Ali");
  assert.equal(open.players[0].clanId, "UNASSIGNED");
  assert.equal(open.status, "OPEN");
  assert.equal(db.calls.filter((call) => call.table === "rpc:get_match_reliability_context").length, assigned.length);
});

test("clan assignments include an OPEN match awaiting opposition, old LIVE, FINAL and CANCELLED matches", async () => {
  const assigned = [
    clan("open-pending", "OPEN", { away_clan_id: null, away_clan: null }),
    clan("scheduled", "SCHEDULED"),
    clan("live-old", "LIVE", { match_date: "2000-01-01" }),
    clan("final-old", "FINAL", { match_date: "2000-01-02" }),
    clan("cancelled-old", "CANCELLED", { match_date: "2000-01-03" }),
  ];
  const db = database({
    fixture_referee_assignments: [
      ...assignments(assigned, "fixture_id"),
      { fixture_id: "another-referee", referee_id: "referee-two" },
    ],
    fixtures: [...assigned, clan("unassigned", "OPEN"), clan("another-referee", "SCHEDULED")],
    clan_members: [{ clan_id: "clan-home", profile_id: "player-one", role: "captain", left_at: null, profiles: { display_name: "Ali" } }],
  });
  const results = await loadRefereeFixtures(db, REFEREE);
  assert.deepEqual([...results.map((row) => row.id)].sort(), assigned.map((row) => row.id).sort());
  const pending = results.find((row) => row.id === "open-pending");
  assert.equal(pending.awayClan.name, "Opponent pending");
  assert.equal(pending.awayClan.id, "");
  assert.equal(pending.players[0].displayName, "Ali");
  assert.equal(db.calls.filter((call) => call.table === "rpc:get_match_reliability_context").length, assigned.length);
});

for (const [label, loader, assignmentTable, idColumn, matchTable, rosterTable, makeRow] of [
  ["solo", loadRefereeOpenQueueGames, "open_queue_referee_assignments", "game_id", "open_queue_games", "open_queue_bookings", solo],
  ["clan", loadRefereeFixtures, "fixture_referee_assignments", "fixture_id", "fixtures", "clan_members", clan],
]) {
  test(`${label} assignment history is not truncated at the default 1,000-row limit`, async () => {
    const rows = Array.from({ length: 1005 }, (_, index) => makeRow(`game-${String(index).padStart(4, "0")}`, "OPEN"));
    const db = database({ [assignmentTable]: assignments(rows, idColumn), [matchTable]: rows });
    const results = await loader(db, REFEREE);
    assert.equal(results.length, rows.length);
    assert.equal(new Set(results.map((row) => row.id)).size, rows.length);
    assert.ok(db.calls.some((call) => call.table === assignmentTable && call.range[0] === 1000));
    assert.ok(db.calls.filter((call) => call.table === matchTable).length > 1);
  });

  test(`${label} no assignments returns empty without querying matches`, async () => {
    const db = database({ [matchTable]: [makeRow("not-assigned", "OPEN")] });
    assert.equal((await loader(db, REFEREE)).length, 0);
    assert.equal(db.calls.some((call) => call.table === matchTable), false);
  });

  test(`${label} assignment, match and hydration failures remain errors, not an empty dashboard`, async () => {
    const row = makeRow("assigned", "OPEN");
    const tables = { [assignmentTable]: assignments([row], idColumn), [matchTable]: [row] };
    for (const table of [assignmentTable, matchTable, rosterTable]) {
      const error = { message: `${table} unavailable` };
      await assert.rejects(loader(database(tables, { [table]: error }), REFEREE), (actual) => actual === error);
    }
  });

  test(`${label} a later assignment page failure cannot return a partial history`, async () => {
    const rows = Array.from({ length: 201 }, (_, index) => makeRow(`game-${index}`, "OPEN"));
    const error = { message: "Assignment history page unavailable" };
    const db = database({ [assignmentTable]: assignments(rows, idColumn), [matchTable]: rows }, {
      [assignmentTable]: ([from]) => from > 0 ? error : null,
    });
    await assert.rejects(loader(db, REFEREE), (actual) => actual === error);
    assert.equal(db.calls.some((call) => call.table === matchTable), false);
  });
}


test("admin detail loads a Solo game directly by ID outside age and list limits", async () => {
  const latest = Array.from({ length: 301 }, (_, index) => solo(`recent-${index}`, "OPEN"));
  const old = solo("old-final", "FINAL", "2000-01-01T23:30:00Z");
  const db = database({ open_queue_games: [...latest, old] });
  for (const id of ["recent-300", "old-final"]) {
    const game = await loadAdminOpenQueueGame(db, id);
    assert.equal(game.id, id);
    assert.equal(game.startsAt, id === "old-final" ? old.starts_at : latest[300].starts_at);
  }
  assert.equal(await loadAdminOpenQueueGame(db, "missing"), null);
});

test("admin clan detail can load an older fixture awaiting opposition", async () => {
  const pending = clan("old-pending", "OPEN", { match_date: "2000-01-01", away_clan_id: null, away_clan: null });
  const db = database({ fixtures: [pending] });
  const fixture = await loadAdminFixture(db, pending.id);
  assert.equal(fixture.id, pending.id);
  assert.equal(fixture.awayClan.name, "Opponent pending");
  assert.equal(await loadAdminFixture(db, "missing"), null);
});

test("admin Solo hydration retains all 4,200 players across a capped 300-game list", async () => {
  const games = Array.from({ length: 300 }, (_, index) => solo(`g-${String(index).padStart(3, "0")}`, "FULL"));
  const bookings = games.flatMap((game) => Array.from({ length: 14 }, (_, index) => ({
    id: `${game.id}-b-${index}`, game_id: game.id, profile_id: `${game.id}-p-${index}`,
    status: "CONFIRMED", booked_at: "2099-01-01T00:00:00Z", team: index < 7 ? "WHITE" : "BLACK", profiles: { display_name: `Player ${index}` },
  })));
  const db = database({ open_queue_games: games, open_queue_bookings: bookings });
  const results = await loadAdminOpenQueueGames(db);
  assert.equal(results.length, 300);
  assert.equal(results.reduce((sum, game) => sum + game.players.length, 0), 4200);
  assert.ok(results.every((game) => game.players.length === 14));
  assert.ok(db.calls.some((call) => call.table === "open_queue_bookings" && call.range[0] === 500));
});

test("single-match goals, events, blue cards and safety aggregates paginate beyond 1,000 rows", async () => {
  const count = 1201;
  const makeRows = (extra = {}) => Array.from({ length: count }, (_, index) => ({
    id: `row-${String(index).padStart(4, "0")}`, game_id: "busy", created_at: "2099-01-01T00:00:00Z", ...extra,
  }));
  const db = database({
    open_queue_games: [solo("busy", "LIVE")],
    open_queue_bookings: [{ id: "booking", game_id: "busy", profile_id: "player", status: "CONFIRMED" }],
    open_queue_goals: makeRows({ team: "WHITE", profile_id: "player" }),
    open_queue_events: makeRows({ event_type: "GOAL", team: "WHITE" }),
    open_queue_blue_cards: makeRows({ team: "WHITE", profile_id: "player" }),
    moderation_reports: makeRows({ subject_type: "PLAYER", subject_profile_id: "player", status: "ACTIONED", priority: "HIGH" }),
  });
  const game = await loadAdminOpenQueueGame(db, "busy");
  assert.equal(game.goals.length, count);
  assert.equal(game.events.length, count);
  assert.equal(game.blueCards.length, count);
  assert.equal(game.riskContext.players[0].priorReports, count);
  assert.equal(new Set(game.events.map((row) => row.id)).size, count);
});

test("a later hydration page failure remains an error", async () => {
  const events = Array.from({ length: 501 }, (_, index) => ({ id: String(index), game_id: "busy" }));
  const error = { message: "later page unavailable" };
  const db = database({ open_queue_games: [solo("busy", "LIVE")], open_queue_events: events }, {
    open_queue_events: ([from]) => from === 500 ? error : null,
  });
  await assert.rejects(loadAdminOpenQueueGame(db, "busy"), (actual) => actual === error);
});
