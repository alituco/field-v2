import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import vm from "node:vm";
const require = createRequire(import.meta.url);
const ts = require("typescript");
const { NextResponse } = require("next/server");

function harness(readiness = true, rpcError = null) {
  let creations = 0;
  const checks = [];
  const db = {
    async rpc(name, args) { checks.push({ name, args }); return { data: readiness, error: rpcError }; },
    from(table) {
      assert.equal(table, "open_queue_broadcasts");
      let value;
      const query = {
        select() { return query; }, eq() { return query; },
        upsert(row) { value = row; return query; },
        async maybeSingle() { return { data: null, error: null }; },
        async single() { return { data: value, error: null }; },
      };
      return query;
    },
  };
  const exports = {};
  const source = ts.transpileModule(readFileSync(new URL("../src/lib/broadcasts.ts", import.meta.url), "utf8"), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  vm.runInNewContext(source, { exports, process: { env: {} }, Date, require(name) {
    if (name === "./cloudflare-stream") return {
      createCloudflareLiveInput: async () => { creations++; return { uid: "a".repeat(32) }; },
      cloudflareHlsUrl: id => `https://stream.example/${id}/manifest.m3u8`,
    };
    if (["./broadcast-agent-auth", "./broadcast-pairing"].includes(name)) return {};
    throw new Error(`Unexpected import ${name}`);
  } });
  return { db, exports, checks, get creations() { return creations; } };
}

test("a server-approved partly booked game prepares its stream", async () => {
  const h = harness(true);
  const result = await h.exports.ensureOpenQueueBroadcast(h.db, "game-1", "ref-1");
  assert.equal(result.liveInputId, "a".repeat(32));
  assert.equal(h.creations, 1);
  assert.equal(h.checks.length, 1);
  assert.equal(h.checks[0].name, "solo_game_stream_ready");
  assert.equal(h.checks[0].args.game_id_to_use, "game-1");
});

test("losing the minimum or assigned teams never creates a provider stream", async () => {
  const h = harness(false);
  await assert.rejects(h.exports.ensureOpenQueueBroadcast(h.db, "game-1", "ref-1"), /minimum.*start window/);
  assert.equal(h.creations, 0);
});

test("readiness errors and malformed success replies fail before provider writes", async () => {
  for (const value of [null, "true", 1, {}, []]) {
    const h = harness(value);
    await assert.rejects(h.exports.ensureOpenQueueBroadcast(h.db, "game-1", "ref-1"), /readiness response was invalid/);
    assert.equal(h.creations, 0);
  }
  const h = harness(true, { message: "Database unavailable" });
  await assert.rejects(h.exports.ensureOpenQueueBroadcast(h.db, "game-1", "ref-1"), /Could not check solo stream readiness/);
  assert.equal(h.creations, 0);
});

function commandHarness(ready, action = "START_STREAM") {
  const command = { id: "command-1", fixture_id: null, open_queue_game_id: "game-1", action, status: "PENDING" };
  let credentialReads = 0;
  let readinessChecks = 0;
  const db = { from(table) {
    assert.equal(table, "broadcast_commands");
    const filters = [];
    let values;
    const query = {
      select() { return query; }, eq(key, value) { filters.push([key, value]); return query; },
      lt() { return query; }, lte() { return query; }, order() { return query; }, limit() { return query; },
      update(value) { values = value; return query; },
      async maybeSingle() {
        if (filters.some(([key, value]) => key in command && command[key] !== value)) return { data: null, error: null };
        if (values) Object.assign(command, values);
        return { data: { ...command }, error: null };
      },
      then(resolve, reject) {
        if (values && !filters.some(([key, value]) => key in command && command[key] !== value)) Object.assign(command, values);
        return Promise.resolve({ data: null, error: null }).then(resolve, reject);
      },
    };
    return query;
  } };
  const modules = {
    "next/server": { NextResponse },
    "@/lib/broadcast-agent-auth": { pairedBroadcastOverlayToken: () => "scoped-token" },
    "@/lib/broadcast-pairing": { getBroadcastAgentContext: async () => ({ db, deviceKey: "device-1", matchKind: "SOLO", matchId: "game-1", matchStatus: "OPEN" }) },
    "@/lib/broadcasts": {
      getOpenQueueBroadcast: async () => ({ liveInputId: "a".repeat(32) }),
      isOpenQueueStreamReady: async () => { readinessChecks++; return ready; },
      getStreamCredentials: async () => { credentialReads++; return { url: "rtmps://stream.example/live", streamKey: "private-key" }; },
    },
  };
  const exports = {};
  const source = ts.transpileModule(readFileSync(new URL("../src/app/api/broadcast-agent/commands/route.ts", import.meta.url), "utf8"), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  vm.runInNewContext(source, { exports, Date, URL, encodeURIComponent, require(name) { assert.ok(name in modules, name); return modules[name]; } });
  return {
    claim: () => exports.GET({ nextUrl: new URL("http://localhost:3000/api/broadcast-agent/commands") }),
    command, get credentialReads() { return credentialReads; }, get readinessChecks() { return readinessChecks; },
  };
}

test("a queued start rechecks the saved minimum before releasing stream credentials", async () => {
  const h = commandHarness(false);
  const response = await h.claim();
  assert.equal(response.status, 200);
  assert.equal((await response.json()).command, null);
  assert.equal(h.command.status, "FAILED");
  assert.equal(h.credentialReads, 0);
  assert.equal(h.readinessChecks, 1);
});

test("a ready partial game may claim START while STOP never depends on headcount", async () => {
  const start = commandHarness(true);
  const response = await start.claim();
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.command.action, "START_STREAM");
  assert.equal(start.credentialReads, 1);
  assert.match(body.command.overlayUrl, /^http:\/\/127\.0\.0\.1:3000\/broadcast\/obs\/game-1\?kind=solo#/);
  const stop = commandHarness(false, "STOP_STREAM");
  assert.equal((await (await stop.claim()).json()).command.action, "STOP_STREAM");
  assert.equal(stop.credentialReads, 0);
  assert.equal(stop.readinessChecks, 0);
});
