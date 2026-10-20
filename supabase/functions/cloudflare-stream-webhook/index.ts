import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";
import { syncFinishedRecording } from "./replay.ts";

type CloudflareVideoPayload = {
  uid?: unknown;
  created?: unknown;
  readyToStream?: unknown;
  status?: {
    state?: unknown;
    errorReasonText?: unknown;
  };
  playback?: {
    hls?: unknown;
  };
  meta?: {
    fixture_id?: unknown;
    open_queue_game_id?: unknown;
  };
};

type MatchedBroadcast = {
  kind: "CLAN" | "SOLO";
  id: string;
  streamRequestedAt: string | null;
  liveInputId: string | null;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  const webhookSecret = Deno.env.get("CLOUDFLARE_STREAM_WEBHOOK_SECRET");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("FIELD_SUPABASE_SECRET_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!webhookSecret || !supabaseUrl || !serviceRoleKey) {
    return json({ error: "Stream webhook is not configured." }, 500);
  }

  const rawBody = await request.text();
  const signature = request.headers.get("Webhook-Signature");
  if (!await hasValidSignature(rawBody, signature, webhookSecret)) {
    return json({ error: "Invalid webhook signature." }, 401);
  }

  let payload: CloudflareVideoPayload;
  try {
    payload = JSON.parse(rawBody) as CloudflareVideoPayload;
  } catch {
    return json({ error: "Invalid webhook payload." }, 400);
  }

  const videoId = stringValue(payload.uid);
  const metadataFixtureId = stringValue(payload.meta?.fixture_id);
  const metadataOpenQueueGameId = stringValue(
    payload.meta?.open_queue_game_id,
  );
  if (!videoId) {
    return json({ received: true, ignored: true });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const fixtureByVideo = await admin
    .from("fixture_broadcasts")
    .select("fixture_id,stream_requested_at,live_input_id")
    .eq("active_video_id", videoId)
    .limit(1)
    .maybeSingle();
  if (fixtureByVideo.error) {
    return json({ error: "Could not match the recording." }, 500);
  }

  let broadcast: MatchedBroadcast | null = fixtureByVideo.data
    ? {
      kind: "CLAN",
      id: String(fixtureByVideo.data.fixture_id),
      streamRequestedAt: stringValue(fixtureByVideo.data.stream_requested_at),
      liveInputId: stringValue(fixtureByVideo.data.live_input_id),
    }
    : null;
  if (!broadcast) {
    const soloByVideo = await admin
      .from("open_queue_broadcasts")
      .select("game_id,stream_requested_at,live_input_id")
      .eq("active_video_id", videoId)
      .limit(1)
      .maybeSingle();
    if (soloByVideo.error) {
      return json({ error: "Could not match the solo recording." }, 500);
    }
    if (soloByVideo.data) {
      broadcast = {
        kind: "SOLO",
        id: String(soloByVideo.data.game_id),
        streamRequestedAt: stringValue(soloByVideo.data.stream_requested_at),
        liveInputId: stringValue(soloByVideo.data.live_input_id),
      };
    }
  }

  if (!broadcast && metadataFixtureId && isUuid(metadataFixtureId)) {
    const byFixture = await admin
      .from("fixture_broadcasts")
      .select("fixture_id,stream_requested_at,live_input_id")
      .eq("fixture_id", metadataFixtureId)
      .maybeSingle();
    if (byFixture.error) {
      return json({ error: "Could not match the fixture." }, 500);
    }
    if (byFixture.data) {
      broadcast = {
        kind: "CLAN",
        id: String(byFixture.data.fixture_id),
        streamRequestedAt: stringValue(byFixture.data.stream_requested_at),
        liveInputId: stringValue(byFixture.data.live_input_id),
      };
    }
  }

  if (
    !broadcast &&
    metadataOpenQueueGameId &&
    isUuid(metadataOpenQueueGameId)
  ) {
    const byGame = await admin
      .from("open_queue_broadcasts")
      .select("game_id,stream_requested_at,live_input_id")
      .eq("game_id", metadataOpenQueueGameId)
      .maybeSingle();
    if (byGame.error) {
      return json({ error: "Could not match the solo game." }, 500);
    }
    if (byGame.data) {
      broadcast = {
        kind: "SOLO",
        id: String(byGame.data.game_id),
        streamRequestedAt: stringValue(byGame.data.stream_requested_at),
        liveInputId: stringValue(byGame.data.live_input_id),
      };
    }
  }

  if (!broadcast) {
    return json({ received: true, ignored: true });
  }

  const matchId = broadcast.id;
  const broadcastTable = broadcast.kind === "SOLO"
    ? "open_queue_broadcasts"
    : "fixture_broadcasts";
  const broadcastIdColumn = broadcast.kind === "SOLO"
    ? "game_id"
    : "fixture_id";
  const recordingStartedAt = validRecordingTimestamp(payload.created);
  if (
    isRecordingOlderThanRequest(
      recordingStartedAt,
      broadcast.streamRequestedAt,
    )
  ) {
    return json({ received: true, ignored: true, reason: "stale recording" });
  }
  const state = stringValue(payload.status?.state)?.toLowerCase();
  if (state === "error") {
    const errorMessage = stringValue(payload.status?.errorReasonText) ??
      "Cloudflare could not process the match recording.";
    let errorUpdate = admin
      .from(broadcastTable)
      .update({
        active_video_id: videoId,
        status: "ERROR",
        error_message: errorMessage,
      })
      .eq(broadcastIdColumn, matchId)
      .is("recovery_upload_id", null)
      .or(`active_video_id.is.null,active_video_id.eq.${videoId}`);
    errorUpdate = broadcast.streamRequestedAt
      ? errorUpdate.eq("stream_requested_at", broadcast.streamRequestedAt)
      : errorUpdate.is("stream_requested_at", null);
    errorUpdate = broadcast.liveInputId
      ? errorUpdate.eq("live_input_id", broadcast.liveInputId)
      : errorUpdate.is("live_input_id", null);
    const { data, error } = await errorUpdate
      .select(broadcastIdColumn)
      .maybeSingle();
    if (error) return json({ error: "Could not save recording error." }, 500);
    if (!data) {
      return json({ received: true, ignored: true, reason: "stale recording" });
    }
    return json({ received: true });
  }

  const isReady = payload.readyToStream === true || state === "ready";
  if (!isReady) {
    return json({ received: true, processing: true });
  }

  const replayUrl = stringValue(payload.playback?.hls) ??
    cloudflareHlsUrl(videoId);
  if (!replayUrl) {
    return json({ received: true, processing: true });
  }

  const readyAt = new Date().toISOString();
  const result = await syncFinishedRecording(admin, {
    kind: broadcast.kind,
    target_id: matchId,
    video_id: videoId,
    replay_url: replayUrl,
    ready_at: readyAt,
    expected_requested_at: broadcast.streamRequestedAt,
    recording_started_at: recordingStartedAt,
    expected_input_id: broadcast.liveInputId,
  });
  if (result === "error") {
    return json({ error: "Could not save the finished recording." }, 500);
  }
  if (result === "stale") {
    return json({ received: true, ignored: true, reason: "stale recording" });
  }

  return json({ received: true });
});

async function hasValidSignature(
  rawBody: string,
  signatureHeader: string | null,
  secret: string,
) {
  if (!signatureHeader) return false;

  const values = signatureHeader.split(",").map((value) => value.trim());
  const timestamp = values
    .find((value) => value.startsWith("time="))
    ?.slice("time=".length);
  const signatures = values
    .filter((value) => value.startsWith("sig1="))
    .map((value) => value.slice("sig1=".length).toLowerCase());
  if (!timestamp || signatures.length === 0 || !/^\d+$/.test(timestamp)) {
    return false;
  }

  const ageSeconds = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (!Number.isFinite(ageSeconds) || ageSeconds > 300) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${timestamp}.${rawBody}`),
  );
  const expected = Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return signatures.some((signature) => constantTimeEqual(expected, signature));
}

function cloudflareHlsUrl(videoId: string) {
  const rawCustomerCode = Deno.env.get("CLOUDFLARE_STREAM_CUSTOMER_CODE");
  if (!rawCustomerCode) return null;
  const withoutProtocol = rawCustomerCode.trim().replace(/^https?:\/\//i, "");
  const customerCode = withoutProtocol
    .split("/")[0]
    .replace(/\.$/, "")
    .replace(/^customer-/i, "")
    .replace(/\.cloudflarestream\.com$/i, "");
  if (!/^[a-z0-9-]+$/i.test(customerCode)) return null;
  return `https://customer-${customerCode}.cloudflarestream.com/${videoId}/manifest/video.m3u8`;
}

function constantTimeEqual(left: string, right: string) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function stringValue(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function validRecordingTimestamp(value: unknown) {
  const raw = stringValue(value);
  if (!raw) return null;
  const milliseconds = Date.parse(raw);
  if (!Number.isFinite(milliseconds) || milliseconds > Date.now() + 60_000) {
    return null;
  }
  return new Date(milliseconds).toISOString();
}

function isRecordingOlderThanRequest(
  recordingStartedAt: string | null,
  streamRequestedAt: string | null,
) {
  if (!recordingStartedAt || !streamRequestedAt) return false;
  const recordingMilliseconds = Date.parse(recordingStartedAt);
  const requestMilliseconds = Date.parse(streamRequestedAt);
  if (
    !Number.isFinite(recordingMilliseconds) ||
    !Number.isFinite(requestMilliseconds)
  ) {
    return false;
  }
  return recordingMilliseconds < requestMilliseconds - 60_000;
}

function isUuid(value: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json",
    },
  });
}
