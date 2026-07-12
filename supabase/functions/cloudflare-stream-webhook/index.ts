import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type CloudflareVideoPayload = {
  uid?: unknown;
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
  };
};

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  const webhookSecret = Deno.env.get("CLOUDFLARE_STREAM_WEBHOOK_SECRET");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
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
  if (!videoId) {
    return json({ received: true, ignored: true });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const byVideo = await admin
    .from("fixture_broadcasts")
    .select("fixture_id, replay_hls_url")
    .eq("active_video_id", videoId)
    .limit(1)
    .maybeSingle();
  if (byVideo.error) {
    return json({ error: "Could not match the recording." }, 500);
  }

  let broadcast = byVideo.data;
  if (!broadcast && metadataFixtureId && isUuid(metadataFixtureId)) {
    const byFixture = await admin
      .from("fixture_broadcasts")
      .select("fixture_id, replay_hls_url")
      .eq("fixture_id", metadataFixtureId)
      .maybeSingle();
    if (byFixture.error) {
      return json({ error: "Could not match the fixture." }, 500);
    }
    broadcast = byFixture.data;
  }

  if (!broadcast) {
    return json({ received: true, ignored: true });
  }

  const fixtureId = String(broadcast.fixture_id);
  const state = stringValue(payload.status?.state)?.toLowerCase();
  if (state === "error") {
    const errorMessage = stringValue(payload.status?.errorReasonText) ??
      "Cloudflare could not process the match recording.";
    const { error } = await admin
      .from("fixture_broadcasts")
      .update({
        active_video_id: videoId,
        status: "ERROR",
        error_message: errorMessage,
      })
      .eq("fixture_id", fixtureId);
    if (error) return json({ error: "Could not save recording error." }, 500);
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
  const { error: broadcastError } = await admin
    .from("fixture_broadcasts")
    .update({
      active_video_id: videoId,
      status: "REPLAY_READY",
      replay_hls_url: replayUrl,
      recording_ready_at: readyAt,
      error_message: null,
    })
    .eq("fixture_id", fixtureId);
  if (broadcastError) {
    return json({ error: "Could not save the finished recording." }, 500);
  }

  const { error: fixtureError } = await admin
    .from("fixtures")
    .update({ video_url: replayUrl })
    .eq("id", fixtureId);
  if (fixtureError) {
    return json({ error: "Could not attach the recording to the match." }, 500);
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
