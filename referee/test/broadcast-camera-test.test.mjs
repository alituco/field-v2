import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import * as crypto from "node:crypto";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const { NextRequest, NextResponse } = require("next/server");
function load(file, overrides = {}) {
  const exports = {};
  const code = ts.transpileModule(readFileSync(new URL(file, import.meta.url), "utf8"), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  vm.runInNewContext(code, {
    exports, URL, Date, Buffer, AbortSignal, fetch, process: { env: {} },
    require(name) {
      if (name in overrides) return overrides[name];
      if (name === "node:crypto") return crypto;
      if (name === "next/server") return { NextRequest, NextResponse };
      throw new Error(`Unexpected import ${name}`);
    },
  });
  return exports;
}
const lib = load("../src/lib/broadcast-camera-test.ts");
const uid = "a".repeat(32);
const videoUid = "b".repeat(32);
const deviceKey = "paired-e3e87fce-55f2-405a-9fac-9db222ef3381";
const tokenHash = "d".repeat(64);

function fixture() {
  const operations = [];
  const credentials = { device_key: deviceKey, token_hash: tokenHash, revoked_at: null,
    expires_at: new Date(Date.now() + 12 * 3600_000).toISOString(),
    reservation_active: false, test_input_id: null, test_started_at: null };
  const camera = { device_key: deviceKey, obs_streaming: false };
  let dbFailure = null;
  const db = {
    from(table) {
      assert.ok(["broadcast_device_credentials", "broadcast_devices"].includes(table));
      const filters = [];
      let patch = null;
      const query = {
        select() { return query; },
        eq(key, value) { filters.push([key, value, "eq"]); return query; },
        is(key, value) { filters.push([key, value, "eq"]); return query; },
        not(key, comparison, value) { assert.equal(comparison, "is"); filters.push([key, value, "not"]); return query; },
        gt(key, value) { filters.push([key, value, "gt"]); return query; },
        update(value) { patch = value; return query; },
        async maybeSingle() {
          const row = table === "broadcast_device_credentials" ? credentials : camera;
          const matches = filters.every(([key, value, op]) => op === "eq" ? row[key] === value : op === "not" ? row[key] !== value : row[key] > value);
          let action = "read";
          if (patch) action = patch.test_input_id === null ? "clear" : patch.test_input_id.startsWith("preparing:") ? "reserve" : "save";
          operations.push({ source: "db", action, filters, matches });
          if (dbFailure === action) return { data: null, error: { message: "private database diagnostic" } };
          if (!matches) return { data: null, error: null };
          if (patch) Object.assign(row, patch);
          return { data: structuredClone(row), error: null };
        },
      };
      return query;
    },
  };
  const context = { db, deviceKey, tokenHash, matchKind: "SOLO", matchId: crypto.randomUUID() };
  const inputs = new Map();
  const createdByKey = new Map();
  const videos = new Map();
  let providerFailure = null;
  let loseFirstCreate = false;
  const provider = {
    async create(key, requestId) {
      operations.push({ source: "provider", action: "create", key, requestId });
      if (providerFailure === "create") throw new Error("Create failed");
      if (!createdByKey.has(requestId)) {
        const input = { uid, enabled: true, status: null,
          meta: { purpose: "fieldrush-camera-test", device_key: key, request_id: requestId },
          recording: { mode: "off", requireSignedURLs: true },
          rtmps: { url: "rtmps://live.cloudflare.com:443/live/", streamKey: "test-private-stream-key" } };
        createdByKey.set(requestId, input);
        inputs.set(uid, input);
      }
      if (loseFirstCreate) { loseFirstCreate = false; throw new Error("Response lost after creation"); }
      return structuredClone(createdByKey.get(requestId));
    },
    async input(id) { operations.push({ source: "provider", action: "input", id }); return structuredClone(inputs.get(id) ?? null); },
    async disable(id) {
      operations.push({ source: "provider", action: "disable", id });
      if (providerFailure === "disable") throw new Error("Disable failed");
      if (inputs.has(id)) inputs.get(id).enabled = false;
    },
    async videos(id) {
      operations.push({ source: "provider", action: "videos", id });
      return structuredClone(videos.get(id) ?? []);
    },
    async deleteVideo(id) {
      operations.push({ source: "provider", action: "deleteVideo", id });
      if (providerFailure === "deleteVideo") throw new Error("Delete failed");
      for (const [inputId, recordings] of videos) videos.set(inputId, recordings.filter((video) => video.uid !== id));
    },
    async deleteInput(id) {
      operations.push({ source: "provider", action: "deleteInput", id });
      if (providerFailure === "deleteInput") throw new Error("Delete failed");
      inputs.delete(id);
    },
  };
  return { context, provider, credentials, camera, operations, inputs, videos, createdByKey,
    failProvider(action) { providerFailure = action; }, failDb(action) { dbFailure = action; },
    loseCreate() { loseFirstCreate = true; } };
}

test("prepare reserves idle device with CAS before provider creation and returns only ingest credentials", async () => {
  const f = fixture();
  const result = await lib.prepareCameraTest(f.context, f.provider);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { rtmpsUrl: "rtmps://live.cloudflare.com:443/live/", streamKey: "test-private-stream-key" });
  assert.equal(f.credentials.test_input_id, uid);
  const reserve = f.operations.find((op) => op.action === "reserve");
  for (const guard of [["reservation_active", false, "eq"], ["test_input_id", null, "eq"], ["token_hash", tokenHash, "eq"], ["revoked_at", null, "eq"]]) {
    assert.ok(reserve.filters.some((filter) => JSON.stringify(filter) === JSON.stringify(guard)));
  }
  assert.ok(f.operations.indexOf(reserve) < f.operations.findIndex((op) => op.action === "create"));
  assert.equal(f.inputs.get(uid).recording.requireSignedURLs, true);
  assert.equal(f.inputs.get(uid).recording.mode, "off");
});

test("concurrent and repeated preparation shares one private input", async () => {
  const f = fixture();
  const results = await Promise.all([lib.prepareCameraTest(f.context, f.provider), lib.prepareCameraTest(f.context, f.provider)]);
  assert.equal(results[0].streamKey, results[1].streamKey);
  assert.equal(f.createdByKey.size, 1);
  const createCount = f.operations.filter((op) => op.action === "create").length;
  await lib.prepareCameraTest(f.context, f.provider);
  assert.equal(f.operations.filter((op) => op.action === "create").length, createCount);
});

test("active match reservation or OBS streaming prevents test creation", async () => {
  for (const cause of ["reservation", "obs"]) {
    const f = fixture();
    if (cause === "reservation") f.credentials.reservation_active = true;
    else f.camera.obs_streaming = true;
    await assert.rejects(lib.prepareCameraTest(f.context, f.provider), /Stop/);
    assert.equal(f.operations.some((op) => op.source === "provider"), false);
    assert.equal(f.credentials.test_input_id, null);
  }
});

test("a lost provider creation response retries its stable request id and preserves the hold", async () => {
  const f = fixture();
  f.loseCreate();
  await assert.rejects(lib.prepareCameraTest(f.context, f.provider));
  assert.match(f.credentials.test_input_id, /^preparing:/);
  assert.equal(f.inputs.size, 1);
  await lib.prepareCameraTest(f.context, f.provider);
  assert.equal(f.inputs.size, 1);
  const creates = f.operations.filter((op) => op.action === "create");
  assert.equal(creates[0].requestId, creates[1].requestId);
});

test("database save failure keeps a preparation marker and recovers without duplication", async () => {
  const f = fixture();
  f.failDb("save");
  await assert.rejects(lib.prepareCameraTest(f.context, f.provider), /could not be saved/);
  assert.match(f.credentials.test_input_id, /^preparing:/);
  f.failDb(null);
  await lib.prepareCameraTest(f.context, f.provider);
  assert.equal(f.createdByKey.size, 1);
  assert.equal(f.credentials.test_input_id, uid);
});

test("GET reports only verified current ingestion and never returns credentials", async () => {
  const f = fixture();
  assert.equal((await lib.inspectCameraTest(f.context, f.provider)).connected, false);
  await lib.prepareCameraTest(f.context, f.provider);
  for (const [state, expected] of [["connected", true], ["reconnected", true], ["reconnecting", false], ["failed_to_connect", false], [null, false]]) {
    f.inputs.get(uid).status = state;
    const status = await lib.inspectCameraTest(f.context, f.provider);
    assert.deepEqual(Object.keys(status), ["connected"]);
    assert.equal(status.connected, expected);
  }
  f.inputs.get(uid).enabled = false;
  f.inputs.get(uid).status = "connected";
  assert.equal((await lib.inspectCameraTest(f.context, f.provider)).connected, false);
});

test("GET recognizes Cloudflare's current status object through the real provider adapter", async () => {
  const f = fixture();
  await lib.prepareCameraTest(f.context, f.provider);
  const requests = [];
  const provider = lib.cloudflareCameraTestProvider({ accountId: "f".repeat(32), token: "test-token", fetcher: async (url, init) => {
    requests.push({ url, init });
    return Response.json({ success: true, result: f.inputs.get(uid) });
  } });
  for (const state of ["connected", "reconnected"]) {
    f.inputs.get(uid).status = {
      current: { ingestProtocol: "rtmp", reason: "connected", state,
        statusEnteredAt: "2026-10-19T01:00:00Z", statusLastSeen: "2026-10-19T01:00:10Z" },
      history: [],
    };
    const result = await lib.inspectCameraTest(f.context, provider);
    assert.deepEqual(Object.keys(result), ["connected"]);
    assert.equal(result.connected, true);
    assert.equal(JSON.stringify(result).includes("test-private-stream-key"), false);
  }
  assert.ok(requests.every(({ url, init }) => url.endsWith(`/live_inputs/${uid}`) && init.cache === "no-store"));
});

test("GET never treats historical connections, reasons, or malformed status as current ingestion", async () => {
  const f = fixture();
  await lib.prepareCameraTest(f.context, f.provider);
  for (const status of [
    { current: { state: "disconnected", reason: "client_disconnect" }, history: [{ state: "connected" }] },
    { current: { state: "disconnected", reason: "connected" } },
    { current: { reason: "connected" }, history: [{ state: "connected" }] },
    { current: { state: "reconnecting" } },
    { current: { state: "failed_to_connect" } },
    { current: { state: true } }, { current: { state: ["connected"] } },
    { current: "connected" }, { current: ["connected"] }, { current: null },
    { history: [{ state: "connected" }] }, {}, ["connected"], true, 1, null, undefined,
  ]) {
    f.inputs.get(uid).status = status;
    assert.equal((await lib.inspectCameraTest(f.context, f.provider)).connected, false);
  }
  f.inputs.get(uid).status = { current: { state: "connected" } };
  for (const enabled of [false, null, undefined, "true", 1]) {
    f.inputs.get(uid).enabled = enabled;
    assert.equal((await lib.inspectCameraTest(f.context, f.provider)).connected, false);
  }
});

test("current connected status cannot bypass the private input ownership and recording guards", async () => {
  for (const mismatch of ["owner", "purpose", "private", "recording", "uid"]) {
    const f = fixture();
    await lib.prepareCameraTest(f.context, f.provider);
    const input = f.inputs.get(uid);
    input.status = { current: { state: "connected" } };
    if (mismatch === "owner") input.meta.device_key = "another-device";
    if (mismatch === "purpose") input.meta.purpose = "match-stream";
    if (mismatch === "private") input.recording.requireSignedURLs = false;
    if (mismatch === "recording") input.recording.mode = "automatic";
    if (mismatch === "uid") input.uid = "f".repeat(32);
    await assert.rejects(lib.inspectCameraTest(f.context, f.provider), /could not be verified/);
    assert.equal(f.operations.some((op) => ["disable", "deleteInput", "deleteVideo"].includes(op.action)), false);
  }
});

test("finish disables, removes only test recordings/input, verifies cleanup, then clears its hold", async () => {
  const f = fixture();
  await lib.prepareCameraTest(f.context, f.provider);
  f.videos.set(uid, [{ uid: videoUid, liveInput: uid }]);
  assert.equal((await lib.finishCameraTest(f.context, f.provider)).finished, true);
  assert.equal(f.credentials.test_input_id, null);
  const actions = f.operations.map((op) => op.action);
  assert.ok(actions.indexOf("disable") < actions.indexOf("deleteVideo"));
  assert.ok(actions.indexOf("deleteVideo") < actions.indexOf("deleteInput"));
  assert.ok(actions.indexOf("deleteInput") < actions.indexOf("clear"));
  const count = f.operations.filter((op) => op.source === "provider").length;
  await lib.finishCameraTest(f.context, f.provider);
  assert.equal(f.operations.filter((op) => op.source === "provider").length, count);
});

test("cleanup failure keeps the reservation and retries without deleting a match recording", async () => {
  for (const action of ["disable", "deleteVideo", "deleteInput"]) {
    const f = fixture();
    await lib.prepareCameraTest(f.context, f.provider);
    f.videos.set(uid, [{ uid: videoUid, liveInput: uid }]);
    f.failProvider(action);
    await assert.rejects(lib.finishCameraTest(f.context, f.provider));
    assert.equal(f.credentials.test_input_id, uid);
    assert.equal(f.operations.some((op) => op.action === "clear"), false);
    f.failProvider(null);
    await lib.finishCameraTest(f.context, f.provider);
    assert.equal(f.credentials.test_input_id, null);
  }
  const f = fixture();
  await lib.prepareCameraTest(f.context, f.provider);
  f.videos.set(uid, [{ uid: videoUid, liveInput: "c".repeat(32) }]);
  await assert.rejects(lib.finishCameraTest(f.context, f.provider), /verify the private test recordings/);
  assert.equal(f.operations.some((op) => op.action === "deleteVideo"), false);
  assert.equal(f.credentials.test_input_id, uid);
});

test("lost database cleanup acknowledgement can repeat after provider input is gone", async () => {
  const f = fixture();
  await lib.prepareCameraTest(f.context, f.provider);
  f.failDb("clear");
  await assert.rejects(lib.finishCameraTest(f.context, f.provider), /cleanup could not be saved/);
  assert.equal(f.inputs.size, 0);
  assert.equal(f.credentials.test_input_id, uid);
  f.failDb(null);
  await lib.finishCameraTest(f.context, f.provider);
  assert.equal(f.credentials.test_input_id, null);
});

test("finish resolves an uncertain preparing marker using the same provider request", async () => {
  const f = fixture();
  f.loseCreate();
  await assert.rejects(lib.prepareCameraTest(f.context, f.provider));
  await lib.finishCameraTest(f.context, f.provider);
  assert.equal(f.createdByKey.size, 1);
  assert.equal(f.inputs.size, 0);
  assert.equal(f.credentials.test_input_id, null);
});

test("expired creation idempotency window does not risk orphaning or recreate an input", async () => {
  const f = fixture();
  f.credentials.test_input_id = `preparing:${crypto.randomUUID()}`;
  f.credentials.test_started_at = new Date(Date.now() - 6 * 3600_000).toISOString();
  for (const action of [lib.prepareCameraTest, lib.finishCameraTest]) {
    await assert.rejects(action(f.context, f.provider), /administrator cleanup/);
  }
  assert.equal(f.operations.some((op) => op.source === "provider"), false);
  assert.match(f.credentials.test_input_id, /^preparing:/);
});

test("foreign or unsigned inputs cannot expose credentials or be destroyed", async () => {
  for (const mismatch of ["owner", "purpose", "private", "recording", "uid"]) {
    const f = fixture();
    await lib.prepareCameraTest(f.context, f.provider);
    const input = f.inputs.get(uid);
    if (mismatch === "owner") input.meta.device_key = "another-device";
    if (mismatch === "purpose") input.meta.purpose = "match-stream";
    if (mismatch === "private") input.recording.requireSignedURLs = false;
    if (mismatch === "recording") input.recording.mode = "automatic";
    if (mismatch === "uid") input.uid = "f".repeat(32);
    await assert.rejects(lib.prepareCameraTest(f.context, f.provider), /could not be verified/);
    await assert.rejects(lib.finishCameraTest(f.context, f.provider), /could not be verified/);
    assert.equal(f.operations.some((op) => op.action === "disable" || op.action === "deleteInput"), false);
  }
});

test("provider uses a signed private input, six-hour idempotency key and exact-input cleanup endpoints", async () => {
  const requests = [];
  const provider = lib.cloudflareCameraTestProvider({ accountId: "f".repeat(32), token: "test-token", fetcher: async (url, init) => {
    requests.push({ url, init });
    if (init.method === "DELETE") return new Response(null, { status: 204 });
    return Response.json({ success: true, result: url.includes("?live_input_id=") ? [] : {} });
  } });
  await provider.create(deviceKey, "request-id");
  await provider.videos(uid);
  await provider.deleteVideo(videoUid);
  await provider.deleteInput(uid);
  const creation = JSON.parse(requests[0].init.body);
  assert.equal(creation.recording.requireSignedURLs, true);
  assert.equal(creation.recording.mode, "off");
  assert.equal(creation.meta.fixture_id, undefined);
  assert.equal(creation.meta.open_queue_game_id, undefined);
  assert.equal(requests[0].init.headers["Idempotency-Key"], `fieldrush-camera-test-${deviceKey}-request-id`);
  assert.match(requests[1].url, new RegExp(`\\?live_input_id=${uid}&limit=1000$`));
  assert.match(requests[2].url, new RegExp(`/stream/${videoUid}$`));
  assert.match(requests[3].url, new RegExp(`/live_inputs/${uid}$`));
  assert.ok(requests.every(({ init }) => init.redirect === "error" && init.cache === "no-store"));
});

test("provider tolerates absent resources only for explicit cleanup/get and sanitizes failures", async () => {
  const provider = lib.cloudflareCameraTestProvider({ accountId: "f".repeat(32), token: "test-token", fetcher: async () => new Response("private diagnostic", { status: 404 }) });
  assert.equal(await provider.input(uid), null);
  await provider.disable(uid);
  await provider.deleteVideo(videoUid);
  await provider.deleteInput(uid);
  await assert.rejects(provider.videos(uid), (error) => !error.message.includes("private diagnostic"));
  await assert.rejects(provider.create(deviceKey, "request"));
  const malformed = lib.cloudflareCameraTestProvider({ accountId: "f".repeat(32), token: "test-token", fetcher: async () => Response.json({ success: false, errors: [{ message: "private diagnostic" }] }) });
  await assert.rejects(malformed.input(uid), (error) => !error.message.includes("private diagnostic"));
  await assert.rejects(provider.deleteInput("../../match"), /invalid/);
});

test("API requires pairing for GET and POST and returns no-store responses", async () => {
  let providerCreated = 0;
  const routeFile = "../src/app/api/broadcast-agent/test/route.ts";
  const denied = load(routeFile, {
    "@/lib/broadcast-pairing": { getBroadcastAgentContext: async () => NextResponse.json({ error: "Pair first" }, { status: 401 }) },
    "@/lib/broadcast-camera-test": { cloudflareCameraTestProvider: () => { providerCreated++; } },
  });
  const url = "https://ops.example/api/broadcast-agent/test";
  assert.equal((await denied.GET(new NextRequest(url))).status, 401);
  assert.equal((await denied.POST(new NextRequest(url, { method: "POST", body: JSON.stringify({ action: "prepare" }) }))).status, 401);
  assert.equal(providerCreated, 0);
  const allowed = load(routeFile, {
    "@/lib/broadcast-pairing": { getBroadcastAgentContext: async () => ({ deviceKey }) },
    "@/lib/broadcast-camera-test": {
      cloudflareCameraTestProvider: () => ({}), inspectCameraTest: async () => ({ connected: true }),
      prepareCameraTest: async () => ({ rtmpsUrl: "rtmps://live.cloudflare.com/live/", streamKey: "test-key" }),
      finishCameraTest: async () => ({ finished: true }),
    },
  });
  const status = await allowed.GET(new NextRequest(url));
  assert.equal(status.headers.get("cache-control"), "no-store");
  assert.deepEqual(await status.json(), { connected: true });
  const finish = await allowed.POST(new NextRequest(url, { method: "POST", body: JSON.stringify({ action: "finish", inputId: "untrusted-id" }) }));
  assert.deepEqual(await finish.json(), { finished: true });
  assert.equal(finish.headers.get("cache-control"), "no-store");
  for (const body of [null, [], {}, { action: "delete" }]) {
    assert.equal((await allowed.POST(new NextRequest(url, { method: "POST", body: JSON.stringify(body) }))).status, 400);
  }
});

test("admin cleanup requires revoked capability and removes only its stored test", async () => {
  const f = fixture();
  await lib.prepareCameraTest(f.context, f.provider);
  await assert.rejects(lib.cleanupRevokedCameraTest(f.context, uid, f.provider), /Revoke the laptop/);
  f.credentials.revoked_at = new Date().toISOString();
  await assert.rejects(lib.cleanupRevokedCameraTest(f.context, "c".repeat(32), f.provider), /changed/);
  assert.equal(f.operations.some((op) => op.action === "disable"), false);
  await lib.cleanupRevokedCameraTest(f.context, uid, f.provider);
  assert.equal(f.credentials.test_input_id, null);
  assert.equal(f.inputs.size, 0);
});

test("admin recovers pending creation through the same key after revoking client access", async () => {
  const f = fixture();
  f.loseCreate();
  await assert.rejects(lib.prepareCameraTest(f.context, f.provider));
  const marker = f.credentials.test_input_id;
  f.credentials.revoked_at = new Date().toISOString();
  f.credentials.reservation_active = true;
  f.failProvider("disable");
  await assert.rejects(lib.cleanupRevokedCameraTest(f.context, marker, f.provider));
  assert.equal(f.credentials.test_input_id, uid);
  assert.equal(f.credentials.reservation_active, true);
  assert.equal(f.createdByKey.size, 1);
  f.failProvider(null);
  await lib.cleanupRevokedCameraTest(f.context, uid, f.provider);
  assert.equal(f.credentials.test_input_id, null);
  // Releasing the pitch remains the authenticated route's separate last step.
  assert.equal(f.credentials.reservation_active, true);
});

test("admin does not release an expired uncertain preparation marker", async () => {
  const f = fixture();
  f.credentials.revoked_at = new Date().toISOString();
  f.credentials.test_input_id = `preparing:${crypto.randomUUID()}`;
  f.credentials.test_started_at = new Date(Date.now() - 6 * 3600_000).toISOString();
  f.credentials.reservation_active = true;
  await assert.rejects(lib.cleanupRevokedCameraTest(f.context, f.credentials.test_input_id, f.provider), /administrator cleanup/);
  assert.equal(f.credentials.reservation_active, true);
  assert.match(f.credentials.test_input_id, /^preparing:/);
  assert.equal(f.operations.some((op) => op.source === "provider"), false);
});

test("forced-disconnect route cleans test before releasing pitch, and retains hold on cleanup failure", async () => {
  for (const failure of [false, true]) {
    const operations = [];
    const db = {
      rpc: async (name, args) => {
        assert.equal(name, "begin_broadcast_device_revocation");
        assert.equal(args.target_device_key, deviceKey);
        operations.push("revoke");
        return { data: { testInputId: `preparing:${crypto.randomUUID()}`, inputId: null }, error: null };
      },
      from(table) {
        const filters = [];
        const query = {
          update() { operations.push(`update:${table}`); return query; },
          eq(key, value) { filters.push([key, value]); return query; },
          not(key, comparison, value) { filters.push([key, comparison, value]); return query; },
          is(key, value) { filters.push([key, value]); return query; },
          select() { return query; },
          async maybeSingle() {
            assert.ok(filters.some(([key, value]) => key === "test_input_id" && value === null));
            return { data: { device_key: deviceKey }, error: null };
          },
          then(resolve) { resolve({ error: null }); },
        };
        return query;
      },
    };
    const route = load("../src/app/api/referee/broadcast-pairing/route.ts", {
      "@/lib/referee-session": { requireReferee: async () => ({ db, referee: { profileId: "admin", role: "admin" } }), isRefereeContext: () => true },
      "@/lib/broadcast-pairing": {}, "@/lib/cloudflare-stream": {}, "@/lib/broadcasts": {},
      "@/lib/broadcast-camera-test": {
        cloudflareCameraTestProvider: () => ({}),
        cleanupRevokedCameraTest: async (context, marker) => {
          assert.equal(context.deviceKey, deviceKey);
          assert.match(marker, /^preparing:/);
          operations.push("cleanup");
          if (failure) throw new Error("Administrator cleanup needs a retry.");
        },
      },
    });
    const result = await route.DELETE(new NextRequest("https://ops.example/api/referee/broadcast-pairing", {
      method: "DELETE", body: JSON.stringify({ deviceKey, force: true }),
    }));
    assert.equal(result.status, failure ? 400 : 200);
    if (failure) assert.deepEqual(operations, ["revoke", "cleanup"]);
    else assert.deepEqual(operations, ["revoke", "cleanup", "update:broadcast_device_credentials", "update:broadcast_devices"]);
  }
});
