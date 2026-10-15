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

const { loadRefereeOpenQueueGames } = loadModule(new URL("../src/lib/open-queue-referee-data.ts", import.meta.url));
const { loadRefereeFixtures } = loadModule(new URL("../src/lib/referee-data.ts", import.meta.url));
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
