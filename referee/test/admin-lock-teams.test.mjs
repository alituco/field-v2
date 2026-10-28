import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
const id = "10000000-0000-4000-8000-000000000001";
function route(role = "admin", error = null) {
  const calls = [];
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200 }) } },
    "@/lib/referee-session": {
      requireReferee: async () => role ? { referee: { role, profileId: id }, db: { rpc: async (...args) => { calls.push(args); return { data: { alreadyLocked: false }, error }; } } } : { status: 401 },
      isRefereeContext: (v) => "referee" in v,
      adminOnly: (v) => v.role === "admin" ? null : { status: 403 },
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL("../src/app/api/referee/admin/games/[matchKind]/[gameId]/lock-teams/route.ts", import.meta.url), "utf8");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, { exports, require: (n) => modules[n] });
  return { calls, post: (matchKind = "solo", gameId = id) => exports.POST({}, { params: Promise.resolve({ matchKind, gameId }) }) };
}
test("lock teams requires an authenticated admin", async () => {
  for (const [role, status] of [[null, 401], ["referee", 403]]) {
    const api = route(role);
    assert.equal((await api.post()).status, status);
    assert.equal(api.calls.length, 0);
  }
});
test("lock teams rejects clan games and invalid identifiers", async () => {
  const api = route();
  assert.equal((await api.post("clan")).status, 400);
  assert.equal((await api.post("solo", "bad")).status, 400);
  assert.equal(api.calls.length, 0);
});
test("lock teams uses the server-verified admin and dedicated atomic RPC", async () => {
  const api = route();
  assert.equal((await api.post()).status, 200);
  assert.equal(api.calls[0][0], "admin_lock_open_queue_teams");
  assert.equal(api.calls[0][1].actor_admin_id, id);
  assert.equal(api.calls[0][1].game_id_to_use, id);
});
test("database conflicts and missing migrations are not reported as success", async () => {
  assert.equal((await route("admin", { message: "Game is no longer full" }).post()).status, 409);
  assert.match((await route("admin", { code: "PGRST202" }).post()).body.error, /migration/);
});
