import assert from "node:assert/strict";
import test from "node:test";
import { parseRecoveryInput, parseRecordingStart, prepareBroadcastRecovery, inspectBroadcastRecovery, attachBroadcastRecovery, cloudflareRecoveryProvider } from "../src/lib/broadcast-recovery.ts";

const id = "b1000000-0000-4000-8000-000000000001";
const gameId = "c1000000-0000-4000-8000-000000000001";
const uid = "abcdef1234567890abcdef1234567890";
const startedAt = new Date(Date.now() - 7_200_000).toISOString();
const input = { fileName: "match-backup.mkv", size: 1024 * 1024 * 1024, recordingStartedAt: startedAt };

function harness(options = {}) {
  const calls = [];
  const row = { id, device_key: "paired-mac", match_kind: "SOLO", match_id: gameId, recording_started_at: startedAt,
    file_name: input.fileName, file_size: input.size, status: "UPLOADING", provider_video_id: uid,
    upload_url: "https://upload.videodelivery.net/private-upload", expires_at: new Date(Date.now() + 6 * 3_600_000).toISOString(), ...options.row };
  const db = {
    from(table) {
      assert.equal(table, "broadcast_recording_recoveries");
      const filters = []; let update;
      const query = {
        select() { return query; }, update(value) { update = value; return query; },
        eq(key, value) { filters.push([key, value]); return query; },
        async maybeSingle() {
          calls.push(["read", filters]);
          return { data: filters.every(([key,value]) => row[key] === value) ? { ...row } : null, error: null };
        },
        then(resolve) { calls.push(["update", update, filters]); if (filters.every(([key,value]) => row[key] === value)) Object.assign(row, update); resolve({ error: null }); },
      }; return query;
    },
    async rpc(name, params) {
      calls.push([name, params]);
      if (options.rpcError) return { data: null, error: { message: options.rpcError } };
      if (name === "begin_broadcast_recovery") return { data: { ...row }, error: null };
      if (name === "store_broadcast_recovery_upload") { row.status = "UPLOADING"; return { error: options.storeError ? { message: "save failed" } : null }; }
      if (name === "reserve_broadcast_recovery_attachment") {
        if (options.reserveError) return { error: { message: options.reserveError } };
        row.status = "ATTACHING";
        return { data: { reserved: true, attached: false }, error: null };
      }
      if (name === "attach_broadcast_recovery") {
        if (!options.attachError || options.commitOnError) row.status = "ATTACHED";
        return options.attachError ? { error: { message: "Replay changed" } } : { data: { attached: true }, error: null };
      }
      throw new Error(`Unexpected RPC ${name}`);
    },
  };
  const provider = {
    async create(...args) { calls.push(["create", ...args]); return { uid, uploadUrl: row.upload_url }; },
    async video(videoId) { calls.push(["video", videoId]); return options.video === null ? null : { uid, readyToStream: true, status: { state: "ready" }, duration: 7_000, ...options.video }; },
    async preview(videoId) { calls.push(["preview", videoId]); return "https://customer-example.cloudflarestream.com/signed-preview/manifest/video.m3u8"; },
    async publish(videoId, visible) { calls.push(["publish", videoId, visible]); if (options.publishError) throw new Error(options.publishError); },
    playback(videoId) { return `https://customer-example.cloudflarestream.com/${videoId}/manifest/video.m3u8`; },
  };
  return { row, calls, provider, context: { db, tokenHash: "hash", deviceKey: "paired-mac", matchKind: "SOLO", matchId: gameId } };
}

test("recovery accepts only a basename, bounded size and an exact recent UTC start", () => {
  assert.equal(parseRecoveryInput(input).recordingStartedAt, startedAt);
  for (const changed of [{ fileName: "/Users/ref/private.mkv" }, { fileName: "C:\\files\\backup.mkv" }, { fileName: "secret\n.mkv" }, { fileName: "photo.png" }, { size: "100" }, { size: 0 }, { size: 21 * 1024 ** 3 }, { size: 1.1 }, { recordingStartedAt: "yesterday" }, { recordingStartedAt: new Date(Date.now() + 3_600_000).toISOString() }]) {
    assert.throws(() => parseRecoveryInput({ ...input, ...changed }));
  }
  assert.throws(() => parseRecordingStart("2026-02-31T12:00:00Z", Date.parse("2026-03-03T13:00:00Z")), /invalid/);
});

test("prepare authorizes and reserves before provisioning a private TUS upload", async () => {
  const h = harness({ row: { status: "PREPARING", provider_video_id: null } });
  const result = await prepareBroadcastRecovery(h.context, input, h.provider);
  assert.equal(result.protocol, "tus"); assert.equal(result.uploadId, id);
  assert.deepEqual(h.calls.map(c => c[0]), ["begin_broadcast_recovery", "create", "store_broadcast_recovery_upload"]);
  assert.equal(h.calls[0][1].credential_hash, "hash");
  assert.equal(h.calls[2][1].video_id, uid);
  assert.equal(JSON.stringify(result).includes("hash"), false);
});

test("prepare reuses the same upload after an interrupted response", async () => {
  const h = harness();
  const first = await prepareBroadcastRecovery(h.context, input, h.provider);
  const second = await prepareBroadcastRecovery(h.context, input, h.provider);
  assert.deepEqual(first, second);
  assert.equal(h.calls.some(c => c[0] === "create"), false);
});

test("authorization and active-stream errors never reach Cloudflare", async () => {
  const h = harness({ rpcError: "Stop the stream first" });
  await assert.rejects(prepareBroadcastRecovery(h.context, input, h.provider), /Stop the stream/);
  assert.deepEqual(h.calls.map(c => c[0]), ["begin_broadcast_recovery"]);
});

test("inspection is private, exact-device scoped, and returns preview only after ready", async () => {
  const h = harness();
  const result = await inspectBroadcastRecovery(h.context, id, h.provider);
  assert.equal(result.status, "READY"); assert.match(result.playbackUrl, /signed-preview/);
  assert.deepEqual(h.calls[0], ["read", [["id",id],["device_key","paired-mac"],["match_kind","SOLO"],["match_id",gameId]]]);
  assert.equal(h.calls.some(c => c[0] === "publish"), false);
  const processing = harness({ video: { readyToStream: false, status: { state: "inprogress" } } });
  const pending = await inspectBroadcastRecovery(processing.context, id, processing.provider);
  assert.equal(pending.status, "PROCESSING"); assert.equal("playbackUrl" in pending, false);
});

test("another device, game, or absent upload cannot be inspected or attached", async () => {
  for (const changed of [{ deviceKey: "someone-else" }, { matchId: "different-game" }, { matchKind: "CLAN" }]) {
    const h = harness(); Object.assign(h.context, changed);
    await assert.rejects(inspectBroadcastRecovery(h.context, id, h.provider), /unavailable/);
    await assert.rejects(attachBroadcastRecovery(h.context, { uploadId:id,recordingStartedAt:startedAt }, h.provider), /unavailable/);
    assert.equal(h.calls.some(c => ["video","publish"].includes(c[0])), false);
  }
});

test("only a ready complete-duration verified upload can be explicitly attached", async () => {
  for (const video of [null, { uid: "wrong-id" }, { readyToStream: false }, { status: { state: "inprogress" } }, { duration: 0 }, { duration: NaN }, { duration: 10801 }, { duration: undefined }]) {
    const h = harness({ video });
    await assert.rejects(attachBroadcastRecovery(h.context, { uploadId:id,recordingStartedAt:startedAt }, h.provider));
    assert.equal(h.calls.some(c => c[0] === "publish"), false);
  }
  const h = harness();
  await assert.rejects(attachBroadcastRecovery(h.context, { uploadId:id,recordingStartedAt:new Date(Date.parse(startedAt)-1000).toISOString() }, h.provider), /does not match/);
  const result = await attachBroadcastRecovery(h.context, { uploadId:id,recordingStartedAt:startedAt }, h.provider);
  assert.equal(result.attached, true);
  assert.deepEqual(h.calls.filter(c => c[0] === "publish"), [["publish",uid,true]]);
  const attach = h.calls.find(c => c[0] === "attach_broadcast_recovery");
  assert.equal(attach[1].recorded_started_at, startedAt); assert.equal(attach[1].provider_duration, 7000);
  assert.deepEqual(h.calls.slice(-3).map(c => c[0]), ["reserve_broadcast_recovery_attachment", "publish", "attach_broadcast_recovery"]);
});

test("rejected authorization, incomplete coverage or stale replay never makes the backup public", async () => {
  for (const reserveError of ["The match replay changed", "This file does not cover the complete match", "Pairing expired"]) {
    const h = harness({ reserveError });
    await assert.rejects(attachBroadcastRecovery(h.context, { uploadId:id,recordingStartedAt:startedAt }, h.provider), new RegExp(reserveError));
    assert.equal(h.calls.some(c => c[0] === "publish" || c[0] === "attach_broadcast_recovery"), false);
    assert.equal(h.row.status, "UPLOADING");
  }
});

test("failed publication leaves a durable reservation and can safely be retried", async () => {
  const options = { publishError: "Lost publication response" };
  const h = harness(options);
  await assert.rejects(attachBroadcastRecovery(h.context, { uploadId:id,recordingStartedAt:startedAt }, h.provider), /Lost publication/);
  assert.equal(h.row.status, "ATTACHING");
  assert.equal(h.calls.some(c => c[0] === "attach_broadcast_recovery"), false);
  options.publishError = null;
  assert.equal((await attachBroadcastRecovery(h.context, { uploadId:id,recordingStartedAt:startedAt }, h.provider)).attached, true);
  assert.deepEqual(h.calls.filter(c => c[0] === "publish"), [["publish",uid,true],["publish",uid,true]]);
});

test("uncertain finalization never makes a potentially committed replay private", async () => {
  const refused = harness({ attachError: true });
  await assert.rejects(attachBroadcastRecovery(refused.context, { uploadId:id,recordingStartedAt:startedAt }, refused.provider), /Replay changed/);
  assert.equal(refused.row.status, "ATTACHING");
  assert.deepEqual(refused.calls.filter(c => c[0] === "publish"), [["publish",uid,true]]);
  const committed = harness({ attachError:true,commitOnError:true });
  assert.equal((await attachBroadcastRecovery(committed.context, { uploadId:id,recordingStartedAt:startedAt }, committed.provider)).attached,true);
  assert.deepEqual(committed.calls.filter(c => c[0] === "publish"), [["publish",uid,true]]);
});

test("a reserved publication remains resumable after upload expiry", async () => {
  const h = harness({ row: { status: "ATTACHING", expires_at: new Date(Date.now()-1000).toISOString() } });
  const prepared = await prepareBroadcastRecovery(h.context,input,h.provider);
  assert.equal(prepared.uploaded,true);
  assert.equal(prepared.status,"ATTACHING");
  assert.equal(prepared.uploadId,id);
  assert.equal("uploadUrl" in prepared,false);
  const inspected = await inspectBroadcastRecovery(h.context,id,h.provider);
  assert.equal(inspected.status,"READY");
  assert.equal(inspected.publicationPending,true);
  assert.equal((await attachBroadcastRecovery(h.context,{uploadId:id,recordingStartedAt:startedAt},h.provider)).attached,true);
});

test("Cloudflare creation uses TUS size and private metadata and keeps the API token server-side", async (t) => {
  const keys = ["CLOUDFLARE_ACCOUNT_ID","CLOUDFLARE_STREAM_API_TOKEN","CLOUDFLARE_STREAM_CUSTOMER_CODE"];
  const previous = keys.map(key => process.env[key]);
  keys.forEach((key,i) => process.env[key] = ["fake-account","private-api-token","example"][i]);
  t.after(() => keys.forEach((key,i) => { if(previous[i]===undefined)delete process.env[key];else process.env[key]=previous[i]; }));
  let request;
  t.mock.method(globalThis,"fetch",async (url,options) => { request={url,options}; return new Response(null,{status:201,headers:{location:"https://upload.videodelivery.net/one-use", "stream-media-id":uid}}); });
  const result = await cloudflareRecoveryProvider().create(input.fileName,input.size,new Date(Date.now()+3600000).toISOString());
  assert.match(request.url,/\/stream\?direct_user=true$/);
  assert.equal(request.options.headers["Tus-Resumable"],"1.0.0");
  assert.equal(request.options.headers["Upload-Length"],String(input.size));
  assert.match(request.options.headers["Upload-Metadata"],/,requiresignedurls$/);
  assert.equal(JSON.stringify(result).includes("private-api-token"),false);
});
