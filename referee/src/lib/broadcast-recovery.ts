import type { BroadcastAgentContext } from "./broadcast-pairing";

type Recovery = {
  id: string; device_key: string; match_kind: string; match_id: string;
  recording_started_at: string; file_name: string; file_size: number;
  status: "PREPARING" | "UPLOADING" | "ATTACHING" | "ATTACHED" | "FAILED";
  provider_video_id: string | null; upload_url: string | null; expires_at: string;
};
type RecoveryVideo = { uid: string; readyToStream?: boolean; duration?: number; status?: { state?: string } };
export type RecoveryProvider = {
  create: (fileName: string, size: number, expiresAt: string) => Promise<{ uid: string; uploadUrl: string }>;
  video: (uid: string) => Promise<RecoveryVideo | null>;
  preview: (uid: string) => Promise<string>;
  publish: (uid: string, visible: boolean) => Promise<void>;
  playback: (uid: string) => string;
};

export function parseRecoveryInput(body: Record<string, unknown>, now = Date.now()) {
  if (typeof body.fileName !== "string" || body.fileName.length < 1 || body.fileName.length > 180
    || /[/\\\x00-\x1f]/.test(body.fileName) || !/\.(mkv|mp4|mov)$/i.test(body.fileName)) {
    throw new Error("Choose the original MKV, MP4, or MOV recording; a local path is not accepted.");
  }
  if (typeof body.size !== "number" || !Number.isSafeInteger(body.size) || body.size < 1 || body.size > 20 * 1024 ** 3) {
    throw new Error("Choose a complete recording of at most 20 GiB.");
  }
  return { fileName: body.fileName, size: body.size, recordingStartedAt: parseRecordingStart(body.recordingStartedAt, now) };
}

export function parseRecordingStart(value: unknown, now = Date.now()) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(value)
    || !Number.isFinite(Date.parse(value)) || Date.parse(value) > now || Date.parse(value) < now - 36 * 60 * 60 * 1_000) {
    throw new Error("The original recording's saved start time is required. Do not estimate it.");
  }
  if (new Date(value).toISOString().slice(0, 19) !== value.slice(0, 19)) throw new Error("The original recording's saved start time is invalid.");
  return new Date(value).toISOString();
}

function recoveryId(value: unknown) {
  if (typeof value !== "string" || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value)) throw new Error("Choose a valid recovery upload.");
  return value;
}

async function ownRecovery(context: BroadcastAgentContext, id: unknown): Promise<Recovery> {
  const { data, error } = await context.db.from("broadcast_recording_recoveries").select("*")
    .eq("id", recoveryId(id)).eq("device_key", context.deviceKey).eq("match_kind", context.matchKind).eq("match_id", context.matchId).maybeSingle();
  if (error || !data) throw new Error("This recovery upload is unavailable for the paired match.");
  return data as Recovery;
}

export async function prepareBroadcastRecovery(context: BroadcastAgentContext, body: Record<string, unknown>, provider: RecoveryProvider) {
  const input = parseRecoveryInput(body);
  const { data, error } = await context.db.rpc("begin_broadcast_recovery", {
    credential_hash: context.tokenHash, recorded_started_at: input.recordingStartedAt,
    input_file_name: input.fileName, input_size: input.size,
  });
  if (error) throw new Error(error.message ?? "Could not prepare this recovery.");
  const recovery = data as Recovery;
  if (!recovery?.id || !Number.isFinite(Date.parse(recovery.expires_at))) throw new Error("Could not verify the recovery upload.");
  if (recovery.status === "ATTACHED") return { uploadId: recovery.id, status: "ATTACHED", attached: true };
  if (recovery.status === "ATTACHING") return { uploadId: recovery.id, status: "ATTACHING", uploaded: true, expiresAt: recovery.expires_at };
  if (recovery.status === "UPLOADING" && recovery.upload_url && recovery.provider_video_id) {
    return { uploadId: recovery.id, uploadUrl: recovery.upload_url, protocol: "tus", expiresAt: recovery.expires_at };
  }
  if (recovery.status !== "PREPARING") throw new Error("This recovery upload is unavailable.");
  try {
    const upload = await provider.create(input.fileName, input.size, recovery.expires_at);
    const saved = await context.db.rpc("store_broadcast_recovery_upload", {
      credential_hash: context.tokenHash, recovery_id: recovery.id, video_id: upload.uid, upload_destination: upload.uploadUrl,
    });
    if (saved.error) throw new Error("Could not save the recording upload. Try preparing it again.");
    return { uploadId: recovery.id, uploadUrl: upload.uploadUrl, protocol: "tus", expiresAt: recovery.expires_at };
  } catch (error) {
    await context.db.from("broadcast_recording_recoveries").update({ status: "FAILED" })
      .eq("id", recovery.id).eq("device_key", context.deviceKey).eq("status", "PREPARING");
    throw error;
  }
}

async function verifiedVideo(recovery: Recovery, provider: RecoveryProvider) {
  if (!recovery.provider_video_id || !/^[a-f0-9]{32}$/.test(recovery.provider_video_id)) throw new Error("This recovery has no valid recording upload.");
  const video = await provider.video(recovery.provider_video_id);
  if (video && video.uid !== recovery.provider_video_id) throw new Error("The uploaded recording could not be verified.");
  return video;
}

export async function inspectBroadcastRecovery(context: BroadcastAgentContext, id: unknown, provider: RecoveryProvider) {
  const recovery = await ownRecovery(context, id);
  if (recovery.status === "ATTACHED") return { uploadId: recovery.id, status: "ATTACHED", playbackUrl: provider.playback(recovery.provider_video_id!), attached: true };
  if (recovery.status !== "ATTACHING" && Date.parse(recovery.expires_at) <= Date.now()) return { uploadId: recovery.id, status: "EXPIRED" };
  if (recovery.status === "FAILED" || recovery.status === "PREPARING") return { uploadId: recovery.id, status: recovery.status };
  const video = await verifiedVideo(recovery, provider);
  if (video?.status?.state === "error") return { uploadId: recovery.id, status: "FAILED" };
  if (!video?.readyToStream || video.status?.state !== "ready") return { uploadId: recovery.id, status: "PROCESSING" };
  return { uploadId: recovery.id, status: "READY", playbackUrl: await provider.preview(video.uid), duration: video.duration, publicationPending: recovery.status === "ATTACHING" };
}

export async function attachBroadcastRecovery(context: BroadcastAgentContext, body: Record<string, unknown>, provider: RecoveryProvider) {
  const recovery = await ownRecovery(context, body.uploadId);
  const startedAt = parseRecordingStart(body.recordingStartedAt);
  if (Date.parse(startedAt) !== Date.parse(recovery.recording_started_at)) throw new Error("The saved recording start time does not match this upload.");
  if (recovery.status === "ATTACHED") return { uploadId: recovery.id, attached: true, playbackUrl: provider.playback(recovery.provider_video_id!) };
  if (!["UPLOADING", "ATTACHING"].includes(recovery.status) || (recovery.status !== "ATTACHING" && Date.parse(recovery.expires_at) <= Date.now())) throw new Error("This recovery upload has expired or is unavailable.");
  const video = await verifiedVideo(recovery, provider);
  if (video?.readyToStream !== true || video.status?.state !== "ready" || typeof video.duration !== "number"
    || !Number.isFinite(video.duration) || video.duration <= 0 || video.duration > 10_800) {
    throw new Error("Wait for the complete recording to finish processing before replacing the replay.");
  }
  const parameters = {
    credential_hash: context.tokenHash, recovery_id: recovery.id, recorded_started_at: startedAt,
    provider_duration: video.duration, replay_url: provider.playback(video.uid),
  };
  // Validate and reserve before publication. This keeps the original replay
  // playable and prevents polling/webhooks from changing the source in between.
  const reserved = await context.db.rpc("reserve_broadcast_recovery_attachment", parameters);
  if (reserved.error) throw new Error(reserved.error.message ?? "Could not reserve this replay replacement.");
  if (reserved.data?.attached === true) return { uploadId: recovery.id, attached: true, playbackUrl: provider.playback(video.uid) };
  if (reserved.data?.reserved !== true) throw new Error("The replay replacement was not reserved.");
  // Publish is idempotent. A process/network failure leaves ATTACHING in the
  // database; retrying the same explicit action resumes this exact recording.
  await provider.publish(video.uid, true);
  let result: { data?: { attached?: boolean } | null; error?: { message?: string } | null };
  try {
    result = await context.db.rpc("attach_broadcast_recovery", parameters);
  } catch {
    result = { error: { message: "Could not confirm the replay replacement. Check the match and try again." } };
  }
  if (result.error || result.data?.attached !== true) {
    // A response may be lost while a commit is still in flight. Never make the
    // file private based on a non-locking read; it could take a committed replay
    // offline. The durable reservation makes another attach safe to retry.
    const current = await ownRecovery(context, recovery.id);
    if (current.status === "ATTACHED") return { uploadId: recovery.id, attached: true, playbackUrl: provider.playback(video.uid) };
    throw new Error(result.error?.message ?? "The replay was not replaced. Check the match and try again.");
  }
  return { uploadId: recovery.id, attached: true, playbackUrl: provider.playback(video.uid) };
}

export function cloudflareRecoveryProvider(): RecoveryProvider {
  const account = requiredEnvironment("CLOUDFLARE_ACCOUNT_ID");
  const token = requiredEnvironment("CLOUDFLARE_STREAM_API_TOKEN");
  const configuredCustomer = requiredEnvironment("CLOUDFLARE_STREAM_CUSTOMER_CODE").replace(/^https?:\/\//i, "").split("/")[0].replace(/^customer-/, "").replace(/\.cloudflarestream\.com$/, "");
  if (!/^[a-z0-9-]+$/i.test(configuredCustomer)) throw new Error("Recording recovery is not configured.");
  const api = `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(account)}/stream`;
  const base = `https://customer-${configuredCustomer}.cloudflarestream.com`;
  const request = async (path: string, init: RequestInit = {}, allowMissing = false) => {
    const response = await fetch(`${api}${path}`, { ...init, cache: "no-store", headers: { authorization: `Bearer ${token}`, "Content-Type": "application/json", ...init.headers } });
    if (allowMissing && response.status === 404) return null;
    const payload = await response.json();
    if (!response.ok || payload.success !== true) throw new Error("The video service could not complete recovery. Try again.");
    return payload.result;
  };
  return {
    async create(fileName, size, expiresAt) {
      const metadata = { name: fileName, maxDurationSeconds: "10800", expiry: expiresAt };
      const response = await fetch(`${api}?direct_user=true`, { method: "POST", cache: "no-store", redirect: "error", headers: {
        authorization: `Bearer ${token}`, "Tus-Resumable": "1.0.0", "Upload-Length": String(size),
        "Upload-Metadata": `${Object.entries(metadata).map(([key, value]) => `${key} ${Buffer.from(value).toString("base64")}`).join(",")},requiresignedurls`,
      } });
      const uid = response.headers.get("stream-media-id");
      const uploadUrl = response.headers.get("location");
      if (!response.ok || !uid || !/^[a-f0-9]{32}$/.test(uid) || !uploadUrl) throw new Error("The video service could not prepare a recording upload.");
      const destination = new URL(uploadUrl);
      if (destination.protocol !== "https:" || destination.hostname !== "upload.videodelivery.net" || destination.username || destination.password) throw new Error("The video service returned an unsupported upload destination.");
      return { uid, uploadUrl };
    },
    async video(uid) { return await request(`/${uid}`, {}, true) as RecoveryVideo | null; },
    async preview(uid) {
      const result = await request(`/${uid}/token`, { method: "POST", body: JSON.stringify({ exp: Math.floor(Date.now() / 1_000) + 3_600, downloadable: false }) });
      if (typeof result.token !== "string" || !/^[A-Za-z0-9_.-]+$/.test(result.token)) throw new Error("The recording preview is unavailable.");
      return `${base}/${result.token}/manifest/video.m3u8`;
    },
    async publish(uid, visible) { await request(`/${uid}`, { method: "POST", body: JSON.stringify({ requireSignedURLs: !visible }) }); },
    playback(uid) { return `${base}/${uid}/manifest/video.m3u8`; },
  };
}

function requiredEnvironment(name: string) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error("Recording recovery is not configured.");
  return value;
}
