import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import * as cities from "../src/lib/admin-cities.ts";

const base = { displayName: " New York ", state: " NY ", countryCode: "us", timezone: "America/New_York", active: false };
const actor = { role: "admin", profileId: "10000000-0000-4000-8000-000000000001" };

test("city inputs validate the permanent identifier, IANA timezone and strict public fields", () => {
  assert.equal(cities.parseCityId("new-york"), "new-york");
  for (const invalid of ["", "New-York", "new york", "-phoenix", "phoenix-", "../phoenix", 1, null]) assert.throws(() => cities.parseCityId(invalid));
  assert.deepEqual(cities.parseAdminCityInput(base), { display_name: "New York", state: "NY", country_code: "US", timezone: "America/New_York", active: false });
  for (const changes of [{ timezone: "Fake/City" }, { timezone: "-07:00" }, { active: "yes" }, { active: null }, { countryCode: "USA" }, { state: "" }, { displayName: "" }, { actor_admin_id: "forged" }, { id: "other" }]) assert.throws(() => cities.parseAdminCityInput({ ...base, ...changes }));
});

function route(file, identity = actor) {
  const calls = [];
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200 }) } },
    "@/lib/admin-cities": cities,
    "@/lib/referee-session": {
      requireReferee: async () => identity ? { referee: identity, db: { rpc: async (...args) => { calls.push(args); return { data: { id: "new-york", ...cities.parseAdminCityInput(base), created_by: "private" }, error: null }; }, from: () => { throw new Error("Unexpected table read"); } } } : { status: 401 },
      isRefereeContext: (value) => "referee" in value,
      adminOnly: (value) => value.role === "admin" ? null : { status: 403 },
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL(`../src/app/api/referee/admin/cities/${file}`, import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, require: (name) => { if (!(name in modules)) throw new Error(`Unknown dependency ${name}`); return modules[name]; } });
  return { calls, ...exports };
}

test("cities endpoints require an authenticated admin before database access", async () => {
  for (const [identity, status] of [[null, 401], [{ ...actor, role: "referee" }, 403]]) {
    assert.equal((await route("route.ts", identity).GET({})).status, status);
    const api = route("[id]/route.ts", identity);
    assert.equal((await api.PUT({ json: async () => base }, { params: Promise.resolve({ id: "new-york" }) })).status, status);
    assert.equal(api.calls.length, 0);
  }
});

test("city writes pass only validated values and authenticated actor to the guarded RPC", async () => {
  const api = route("[id]/route.ts");
  const result = await api.PUT({ json: async () => base }, { params: Promise.resolve({ id: "new-york" }) });
  assert.equal(result.status, 200);
  assert.equal(api.calls[0][0], "admin_save_fieldrush_city");
  assert.equal(api.calls[0][1].actor_admin_id, actor.profileId);
  assert.equal(api.calls[0][1].city_id_to_use, "new-york");
  assert.deepEqual(api.calls[0][1].values_to_use, cities.parseAdminCityInput(base));
  assert.equal(result.body.city.created_by, undefined);
  assert.equal(result.body.city.active, false);
  assert.equal((await api.PUT({ json: async () => ({ ...base, actor_admin_id: "forged" }) }, { params: Promise.resolve({ id: "new-york" }) })).status, 400);
  assert.equal(api.calls.length, 1);
});
