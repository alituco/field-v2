import { randomUUID } from "node:crypto";
import type { BroadcastAgentContext } from "./broadcast-pairing";

type TestReservation = {
  test_input_id: string | null;
  test_started_at: string | null;
  reservation_active: boolean;
};
export type CameraTestInput = {
  uid: string;
  enabled: boolean;
  // Cloudflare may return its legacy string or a current/history status object.
  // Treat the raw provider response as untrusted until its current state is read.
  status?: unknown;
  meta: { purpose: string; device_key: string; request_id?: string };
  recording: { mode: string; requireSignedURLs: boolean };
  rtmps: { url: string; streamKey: string };
};
export type CameraTestProvider = {
  create(deviceKey: string, requestId: string): Promise<CameraTestInput>;
  input(uid: string): Promise<CameraTestInput | null>;
  disable(uid: string): Promise<void>;
  videos(uid: string): Promise<{ uid: string; liveInput: string }[]>;
  deleteVideo(uid: string): Promise<void>;
  deleteInput(uid: string): Promise<void>;
};
const inputPattern = /^[a-f0-9]{32}$/;
const preparationPattern = /^preparing:([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$/;
const purpose = "fieldrush-camera-test";
const reservationColumns = "test_input_id,test_started_at,reservation_active";

async function testReservation(context: BroadcastAgentContext): Promise<TestReservation> {
  const { data, error } = await context.db.from("broadcast_device_credentials")
    .select(reservationColumns).eq("device_key", context.deviceKey).eq("token_hash", context.tokenHash)
    .is("revoked_at", null).gt("expires_at", new Date().toISOString()).maybeSingle();
  if (error || !data || typeof data.reservation_active !== "boolean") throw new Error("Could not verify this laptop's connection test. Reconnect and try again.");
  return data as TestReservation;
}

function verifiedInput(input: CameraTestInput, deviceKey: string, expectedUid?: string) {
  if (!input || !inputPattern.test(input.uid) || (expectedUid && input.uid !== expectedUid) ||
      input.meta?.purpose !== purpose || input.meta?.device_key !== deviceKey ||
      input.recording?.requireSignedURLs !== true || input.recording?.mode !== "off") {
    throw new Error("The private test input could not be verified. Its reservation has been kept for cleanup.");
  }
  return input;
}

function streamCredentials(input: CameraTestInput) {
  let destination: URL;
  try { destination = new URL(input.rtmps?.url); } catch { throw new Error("The video service did not return valid private test credentials."); }
  if (destination.protocol !== "rtmps:" || destination.hostname !== "live.cloudflare.com" ||
      destination.username || destination.password || destination.search || destination.hash ||
      typeof input.rtmps?.streamKey !== "string" || input.rtmps.streamKey.length < 1 || input.enabled !== true) {
    throw new Error("The private connection test is not ready. Finish it before starting another test.");
  }
  return { rtmpsUrl: input.rtmps.url, streamKey: input.rtmps.streamKey };
}

async function recoverPreparationInput(deviceKey: string, reservation: TestReservation, provider: CameraTestProvider) {
  const pending = preparationPattern.exec(reservation.test_input_id ?? "");
  if (!pending) throw new Error("The connection test has invalid preparation state. Ask an administrator to inspect it.");
  // Cloudflare guarantees creation idempotency for six hours. Never recreate an
  // uncertain old request outside that window: it may already own a live input.
  const started = Date.parse(reservation.test_started_at ?? "");
  if (!Number.isFinite(started) || started > Date.now() + 60_000 || Date.now() - started >= 5.5 * 60 * 60 * 1000) {
    throw new Error("This unfinished connection test needs administrator cleanup before another test can start.");
  }
  const input = verifiedInput(await provider.create(deviceKey, pending[1]), deviceKey);
  if (input.meta.request_id !== pending[1]) throw new Error("The video service returned a different connection test. The reservation is still held.");
  return input;
}

async function resolvePreparation(context: BroadcastAgentContext, reservation: TestReservation, provider: CameraTestProvider) {
  const input = await recoverPreparationInput(context.deviceKey, reservation, provider);
  const { data, error } = await context.db.from("broadcast_device_credentials")
    .update({ test_input_id: input.uid }).eq("device_key", context.deviceKey).eq("token_hash", context.tokenHash)
    .eq("reservation_active", false).eq("test_input_id", reservation.test_input_id)
    .is("revoked_at", null).gt("expires_at", new Date().toISOString())
    .select(reservationColumns).maybeSingle();
  if (error) throw new Error("The test was created but its reservation could not be saved. Retry to recover the same test.");
  if (!data) {
    const current = await testReservation(context);
    if (current.test_input_id !== input.uid || current.reservation_active) {
      throw new Error("The connection test changed while preparing. Finish the current test before trying again.");
    }
  }
  return input;
}

export async function prepareCameraTest(context: BroadcastAgentContext, provider: CameraTestProvider) {
  let reservation = await testReservation(context);
  if (reservation.reservation_active) throw new Error("Stop the match broadcast before running a connection test.");
  if (!reservation.test_input_id) {
    const { data: camera, error: cameraError } = await context.db.from("broadcast_devices")
      .select("obs_streaming").eq("device_key", context.deviceKey).maybeSingle();
    if (cameraError || camera?.obs_streaming !== false) throw new Error("Stop streaming in OBS before running a connection test.");
    const marker = `preparing:${randomUUID()}`;
    const { data, error } = await context.db.from("broadcast_device_credentials")
      .update({ test_input_id: marker, test_started_at: new Date().toISOString() })
      .eq("device_key", context.deviceKey).eq("token_hash", context.tokenHash)
      .is("revoked_at", null).gt("expires_at", new Date().toISOString())
      .eq("reservation_active", false).is("test_input_id", null)
      .select(reservationColumns).maybeSingle();
    if (error) throw new Error("Could not reserve a private connection test. Try again.");
    reservation = data as TestReservation ?? await testReservation(context);
    if (reservation.reservation_active || !reservation.test_input_id) throw new Error("The match stream or another test is starting. Wait and try again.");
  }
  const input = preparationPattern.test(reservation.test_input_id)
    ? await resolvePreparation(context, reservation, provider)
    : await provider.input(reservation.test_input_id);
  if (!input) throw new Error("This test input no longer exists. Finish the test to clear its reservation.");
  return streamCredentials(verifiedInput(input, context.deviceKey,
    inputPattern.test(reservation.test_input_id) ? reservation.test_input_id : undefined));
}

function hasConnectedCurrentInput(status: unknown): boolean {
  if (typeof status === "string") return status === "connected" || status === "reconnected";
  if (!status || typeof status !== "object" || Array.isArray(status)) return false;
  const current = (status as { current?: unknown }).current;
  if (!current || typeof current !== "object" || Array.isArray(current)) return false;
  const state = (current as { state?: unknown }).state;
  // A previous connection or a reason string must not make a disconnected input ready.
  return state === "connected" || state === "reconnected";
}

export async function inspectCameraTest(context: BroadcastAgentContext, provider: CameraTestProvider) {
  const reservation = await testReservation(context);
  if (!reservation.test_input_id || preparationPattern.test(reservation.test_input_id)) return { connected: false };
  if (!inputPattern.test(reservation.test_input_id)) throw new Error("The connection test has invalid state. Ask an administrator to inspect it.");
  const input = await provider.input(reservation.test_input_id);
  if (!input) return { connected: false };
  verifiedInput(input, context.deviceKey, reservation.test_input_id);
  return { connected: input.enabled === true && hasConnectedCurrentInput(input.status) };
}

/** For an authenticated device (or explicit admin recovery), never a submitted provider ID. */
export async function cleanupCameraTestInput(uid: string, deviceKey: string, provider: CameraTestProvider) {
  if (!inputPattern.test(uid)) throw new Error("The private test input is invalid.");
  const input = await provider.input(uid);
  if (input) {
    verifiedInput(input, deviceKey, uid);
    await provider.disable(uid);
    const disabled = await provider.input(uid);
    if (disabled && (verifiedInput(disabled, deviceKey, uid).enabled !== false)) {
      throw new Error("The private test input is still enabled. Cleanup will need to be retried.");
    }
  }
  // Deleting an input retains recordings. Only the exact test input's recordings
  // may be removed, including on a retry after the input itself was deleted.
  for (let pass = 0; pass < 3; pass++) {
    const videos = await provider.videos(uid);
    if (!Array.isArray(videos) || videos.some((video) => !inputPattern.test(video.uid) || video.liveInput !== uid)) {
      throw new Error("Could not verify the private test recordings. Cleanup is paused.");
    }
    if (videos.length === 0) break;
    for (const video of videos) await provider.deleteVideo(video.uid);
    if (pass === 2) throw new Error("Private test recording cleanup is still pending. Try finishing the test again.");
  }
  await provider.deleteInput(uid);
  if (await provider.input(uid) || (await provider.videos(uid)).length !== 0) {
    throw new Error("The private test is still being removed. Try finishing it again.");
  }
}

export async function finishCameraTest(context: BroadcastAgentContext, provider: CameraTestProvider) {
  let reservation = await testReservation(context);
  if (!reservation.test_input_id) return { finished: true };
  if (reservation.reservation_active) throw new Error("A match broadcast is using this laptop. Stop it before cleaning up the test.");
  if (preparationPattern.test(reservation.test_input_id)) {
    const input = await resolvePreparation(context, reservation, provider);
    reservation = { ...reservation, test_input_id: input.uid };
  }
  await cleanupCameraTestInput(reservation.test_input_id!, context.deviceKey, provider);
  const { data, error } = await context.db.from("broadcast_device_credentials")
    .update({ test_input_id: null, test_started_at: null }).eq("device_key", context.deviceKey)
    .eq("token_hash", context.tokenHash).eq("reservation_active", false).eq("test_input_id", reservation.test_input_id)
    .select(reservationColumns).maybeSingle();
  if (error) throw new Error("The private test was removed but cleanup could not be saved. Retry finishing the test.");
  if (!data && (await testReservation(context)).test_input_id !== null) throw new Error("The laptop's test changed during cleanup. Finish the current test before continuing.");
  return { finished: true };
}

/** Call only after begin_broadcast_device_revocation has authorized the admin and revoked the capability. */
export async function cleanupRevokedCameraTest(
  context: Pick<BroadcastAgentContext, "db" | "deviceKey">,
  expectedInputId: string,
  provider: CameraTestProvider,
) {
  const read = async () => {
    const { data, error } = await context.db.from("broadcast_device_credentials")
      .select(`${reservationColumns},revoked_at`).eq("device_key", context.deviceKey)
      .not("revoked_at", "is", null).maybeSingle();
    if (error || !data?.revoked_at) throw new Error("Revoke the laptop's access before administrator test cleanup.");
    return data as TestReservation;
  };
  let reservation = await read();
  if (!reservation.test_input_id) return;
  if (reservation.test_input_id !== expectedInputId) throw new Error("The laptop's private test changed. Reload its status before administrator cleanup.");
  if (preparationPattern.test(reservation.test_input_id)) {
    // A capability cannot perform this write after revocation. Recover its exact
    // idempotent provider request, retain the ID, then clean up that input only.
    const input = await recoverPreparationInput(context.deviceKey, reservation, provider);
    const { data, error } = await context.db.from("broadcast_device_credentials")
      .update({ test_input_id: input.uid }).eq("device_key", context.deviceKey)
      .not("revoked_at", "is", null).eq("test_input_id", reservation.test_input_id)
      .select(reservationColumns).maybeSingle();
    if (error) throw new Error("The private test was found but its cleanup state could not be saved. Retry administrator cleanup.");
    if (!data) {
      const current = await read();
      if (!current.test_input_id) return;
      if (current.test_input_id !== input.uid) throw new Error("The laptop's private test changed during administrator cleanup.");
      reservation = current;
    } else reservation = data as TestReservation;
  }
  await cleanupCameraTestInput(reservation.test_input_id!, context.deviceKey, provider);
  const { data, error } = await context.db.from("broadcast_device_credentials")
    .update({ test_input_id: null, test_started_at: null }).eq("device_key", context.deviceKey)
    .not("revoked_at", "is", null).eq("test_input_id", reservation.test_input_id)
    .select(reservationColumns).maybeSingle();
  if (error) throw new Error("The private test was removed but its cleanup state could not be saved. Retry administrator cleanup.");
  if (!data && (await read()).test_input_id !== null) throw new Error("The laptop's private test changed during administrator cleanup.");
}

export function cloudflareCameraTestProvider(options: { fetcher?: typeof fetch; accountId?: string; token?: string } = {}): CameraTestProvider {
  const accountId = options.accountId ?? process.env.CLOUDFLARE_ACCOUNT_ID?.trim();
  const token = options.token ?? process.env.CLOUDFLARE_STREAM_API_TOKEN?.trim();
  if (!accountId || !/^[a-f0-9]{32}$/i.test(accountId) || !token) throw new Error("Private connection testing is not configured.");
  const fetcher = options.fetcher ?? fetch;
  const base = `https://api.cloudflare.com/client/v4/accounts/${accountId}/stream`;
  const request = async (path: string, init: RequestInit = {}, missingIsEmpty = false): Promise<unknown> => {
    let response: Response;
    try {
      response = await fetcher(`${base}${path}`, {
        ...init, cache: "no-store", redirect: "error", signal: AbortSignal.timeout(15_000),
        headers: { authorization: `Bearer ${token}`, "Content-Type": "application/json", ...init.headers },
      });
    } catch { throw new Error("The video service could not be reached. The private test reservation is still held; retry cleanup."); }
    if (response.status === 404 && missingIsEmpty) return null;
    if (!response.ok) throw new Error("The video service could not complete the private test request. Retry cleanup.");
    if (response.status === 204) return null;
    const text = await response.text();
    if (init.method === "DELETE" && text.length === 0) return null;
    let body: { success?: unknown; result?: unknown };
    try { body = JSON.parse(text); } catch { throw new Error("The video service returned an invalid private test response."); }
    if (body?.success !== true) throw new Error("The video service could not complete the private test request.");
    return body.result;
  };
  const validUid = (uid: string) => {
    if (!inputPattern.test(uid)) throw new Error("The private test resource is invalid.");
    return uid;
  };
  return {
    async create(deviceKey, requestId) {
      return await request("/live_inputs", {
        method: "POST", headers: { "Idempotency-Key": `${purpose}-${deviceKey}-${requestId}` },
        body: JSON.stringify({ enabled: true,
          meta: { name: "Fieldrush private connection test", purpose, device_key: deviceKey, request_id: requestId },
          recording: { mode: "off", requireSignedURLs: true, timeoutSeconds: 0 } }),
      }) as CameraTestInput;
    },
    async input(uid) { return await request(`/live_inputs/${validUid(uid)}`, {}, true) as CameraTestInput | null; },
    async disable(uid) { await request(`/live_inputs/${validUid(uid)}`, { method: "PUT", body: JSON.stringify({ enabled: false }) }, true); },
    async videos(uid) {
      const result = await request(`?live_input_id=${validUid(uid)}&limit=1000`);
      if (!Array.isArray(result)) throw new Error("The video service did not return a complete private recording list.");
      return result as { uid: string; liveInput: string }[];
    },
    async deleteVideo(uid) { await request(`/${validUid(uid)}`, { method: "DELETE" }, true); },
    async deleteInput(uid) { await request(`/live_inputs/${validUid(uid)}`, { method: "DELETE" }, true); },
  };
}
