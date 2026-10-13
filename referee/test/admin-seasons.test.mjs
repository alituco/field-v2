import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import * as seasons from "../src/lib/admin-seasons.ts";
import * as cities from "../src/lib/admin-cities.ts";

const actor = { role: "admin", profileId: "10000000-0000-4000-8000-000000000001" };
const season = { label: " Season 2 ", startsOn: "2027-01-01", endsOn: "2027-03-31", minimumRatedGames: 2, expectedRevision: 1 };
const reward = { firstPrizeUsd: "150.00", secondPrizeUsd: "100", thirdPrizeUsd: "50", action: "SAVE", reason: null, expectedRevision: 1 };
const dbSeason = { id: "s2", label: "Season 2", starts_on: "2027-01-01", ends_on: "2027-03-31", minimum_rated_games: 2, revision: 1, editable: true, published_rewards_locked: false };
const dbReward = { season_id: "s2", city_id: "phoenix", rating_track: "OUTFIELD", currency: "USD", first_prize_cents: 15000, second_prize_cents: 10000, third_prize_cents: 5000, status: "DRAFT", revision: 1, published_at: null };

test("season inputs validate exact revision, dates, qualification and allowlisted fields", () => {
  assert.deepEqual(seasons.parseAdminSeasonInput(season), { expectedRevision: 1, values: { label: "Season 2", starts_on: "2027-01-01", ends_on: "2027-03-31", minimum_rated_games: 2 } });
  assert.equal(seasons.parseAdminSeasonInput({ ...season, minimumRatedGames: 100 }).values.minimum_rated_games, 100);
  for (const changes of [{ label: "" }, { label: "a".repeat(41) }, { startsOn: "2027-02-29" }, { endsOn: "2026-12-31" }, { endsOn: "2029-01-01" }, { minimumRatedGames: 1 }, { minimumRatedGames: 101 }, { minimumRatedGames: 2.5 }, { minimumRatedGames: "2" }, { expectedRevision: undefined }, { expectedRevision: -1 }, { expectedRevision: "1" }, { actor_admin_id: "forged" }, { revision: 4 }]) assert.throws(() => seasons.parseAdminSeasonInput({ ...season, ...changes }));
  for (const id of ["s0", "s42", "summer-2027"]) assert.equal(seasons.parseSeasonId(id), id);
  for (const id of ["", "S0", "../s1", "x".repeat(61), null]) assert.throws(() => seasons.parseSeasonId(id));
});

test("USD prizes convert exact decimals to cents without accepting rounded input", () => {
  for (const [value, expected] of [["0", 0], ["0.01", 1], ["150", 15000], [" 150.3 ", 15030], ["1000000.00", 100000000]]) assert.equal(seasons.parsePrizeUsd(value), expected);
  for (const value of ["-1", "+1", ".50", "1.001", "1e3", "NaN", "Infinity", "1,000", "$150", "1000000.01", "", 150, null]) assert.throws(() => seasons.parsePrizeUsd(value));
  assert.equal(seasons.formatPrize(15000), "$150");
  assert.equal(seasons.formatPrize(1001), "$10.01");
});

test("reward actions require correction evidence and reject actor/status/currency injection", () => {
  assert.deepEqual(seasons.parseAdminRewardInput(reward), { action: "SAVE", reason: null, expectedRevision: 1, values: { first_prize_cents: 15000, second_prize_cents: 10000, third_prize_cents: 5000 } });
  assert.equal(seasons.parseAdminRewardInput({ ...reward, action: "CORRECT", reason: "  Correcting a data entry error.  " }).reason, "Correcting a data entry error.");
  for (const changes of [{ action: "CORRECT" }, { action: "CORRECT", reason: "Too short" }, { action: "CORRECT", reason: "a".repeat(1001) }, { action: "PAY" }, { action: "PUBLISH", reason: "Not a correction" }, { expectedRevision: undefined }, { expectedRevision: 1.1 }, { currency: "BHD" }, { actor_admin_id: "forged" }, { status: "PUBLISHED" }, { firstPrizeUsd: "15.001" }]) assert.throws(() => seasons.parseAdminRewardInput({ ...reward, ...changes }));
  for (const invalid of ["KEEPER", "CLAN", "outfield", null]) assert.throws(() => seasons.parseRatingTrack(invalid));
});

function route(file, { identity = actor, error = null } = {}) {
  const calls = [];
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200, headers: init.headers }) } },
    "@/lib/admin-seasons": seasons,
    "@/lib/admin-cities": cities,
    "@/lib/referee-session": {
      requireReferee: async () => identity ? { referee: identity, db: {
        rpc: async (name, params) => { calls.push([name, params]); return { error, data: name === "admin_list_fieldrush_seasons" ? { today: "2026-10-13", seasons: [dbSeason], rewards: [dbReward], audit: [{ id: "audit-1", season_id: "s2", city_id: "phoenix", rating_track: "OUTFIELD", action: "REWARD_SAVE", actor_admin_id: actor.profileId, reason: null, before_state: null, after_state: dbReward, created_at: "2026-10-13T12:00:00Z" }] } : name === "admin_save_fieldrush_season" ? dbSeason : dbReward }; },
        from: (name) => ({ select: (columns) => ({ order: async () => { calls.push([name, columns]); return { error: null, data: [{ id: "phoenix", display_name: "Phoenix", state: "AZ", country_code: "US", timezone: "America/Phoenix", active: true }] }; } }) }),
      } } : { status: 401 },
      isRefereeContext: (value) => "referee" in value,
      adminOnly: (value) => value.role === "admin" ? null : { status: 403 },
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL(`../src/app/api/referee/admin/seasons/${file}`, import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, require: (name) => { if (!(name in modules)) throw new Error(`Unknown dependency ${name}`); return modules[name]; } });
  return { calls, ...exports };
}
const routeParams = { params: Promise.resolve({ id: "s2", cityId: "phoenix", ratingTrack: "OUTFIELD" }) };
const rewardRoute = "[id]/rewards/[cityId]/[ratingTrack]/route.ts";

test("all seasons endpoints deny anonymous/referee callers before database access", async () => {
  for (const [identity, status] of [[null, 401], [{ ...actor, role: "referee" }, 403]]) {
    const api = route("route.ts", { identity }); assert.equal((await api.GET({})).status, status); assert.equal(api.calls.length, 0);
    for (const file of ["[id]/route.ts", rewardRoute]) {
      const api = route(file, { identity }); assert.equal((await api.PUT({ json: async () => reward }, routeParams)).status, status); assert.equal(api.calls.length, 0);
    }
  }
});

test("catalog is admin-only, uncached, and serializes seasons, rewards, cities and audit", async () => {
  const api = route("route.ts"); const result = await api.GET({});
  assert.equal(result.status, 200); assert.equal(result.headers["Cache-Control"], "private, no-store");
  assert.equal(api.calls.find(([name]) => name === "admin_list_fieldrush_seasons")[1].actor_admin_id, actor.profileId);
  assert.equal(result.body.today, "2026-10-13"); assert.equal(result.body.seasons[0].minimumRatedGames, 2);
  assert.equal(result.body.rewards[0].firstPrizeCents, 15000); assert.equal(result.body.cities[0].displayName, "Phoenix");
  assert.equal(result.body.audit[0].actorAdminId, actor.profileId);
});

test("season save passes the authenticated actor and concurrency revision only", async () => {
  const api = route("[id]/route.ts"); const result = await api.PUT({ json: async () => season }, routeParams);
  assert.equal(result.status, 200); assert.equal(api.calls[0][0], "admin_save_fieldrush_season");
  assert.equal(api.calls[0][1].actor_admin_id, actor.profileId); assert.equal(api.calls[0][1].expected_revision_to_use, 1);
  assert.deepEqual(api.calls[0][1].values_to_use, seasons.parseAdminSeasonInput(season).values);
  assert.equal((await api.PUT({ json: async () => ({ ...season, actor_admin_id: "forged" }) }, routeParams)).status, 400); assert.equal(api.calls.length, 1);
});

test("reward save scopes role/city/season and passes a reason only for audited correction", async () => {
  const api = route(rewardRoute); const body = { ...reward, action: "CORRECT", reason: "Fixing a published amount typo." };
  const result = await api.PUT({ json: async () => body }, routeParams);
  assert.equal(result.status, 200); assert.equal(api.calls[0][0], "admin_save_fieldrush_season_reward");
  const input = api.calls[0][1]; assert.equal(input.actor_admin_id, actor.profileId); assert.equal(input.season_id_to_use, "s2"); assert.equal(input.city_id_to_use, "phoenix"); assert.equal(input.rating_track_to_use, "OUTFIELD"); assert.equal(input.action_to_use, "CORRECT"); assert.equal(input.reason_to_use, body.reason); assert.equal(input.expected_revision_to_use, 1);
  assert.equal((await api.PUT({ json: async () => ({ ...reward, expectedRevision: undefined }) }, routeParams)).status, 400); assert.equal(api.calls.length, 1);
});

test("stale revisions and missing migrations surface actionable errors, never success", async () => {
  const stale = await route(rewardRoute, { error: { code: "40001", message: "stale" } }).PUT({ json: async () => reward }, routeParams);
  assert.equal(stale.status, 409); assert.match(stale.body.error, /another session/);
  const missing = await route("route.ts", { error: { code: "PGRST202", message: "function missing" } }).GET({});
  assert.equal(missing.status, 500); assert.match(missing.body.error, /database update is not installed/);
});
