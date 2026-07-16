import type { SupabaseClient } from "@supabase/supabase-js";

import {
  cloudflareHlsUrl,
  createCloudflareLiveInput,
  getCloudflareLifecycle,
  getCloudflareLiveInput,
  getCloudflareVideo,
  listCloudflareLiveInputVideos,
  setCloudflareLiveInputEnabled,
} from "./cloudflare-stream";
import { broadcastDeviceKey, broadcastDeviceName } from "./broadcast-agent-auth";

export type BroadcastStatus =
  | "NOT_CONFIGURED"
  | "READY"
  | "STARTING"
  | "LIVE"
  | "STOPPING"
  | "PROCESSING"
  | "REPLAY_READY"
  | "ERROR";

export type FixtureBroadcast = {
  matchKind?: "CLAN" | "SOLO";
  fixtureId: string;
  openQueueGameId?: string | null;
  liveInputId: string | null;
  activeVideoId: string | null;
  status: BroadcastStatus;
  hlsUrl: string | null;
  replayHlsUrl: string | null;
  streamRequestedAt: string | null;
  streamStartedAt: string | null;
  streamStoppedAt: string | null;
  recordingReadyAt: string | null;
  errorMessage: string | null;
};

export type BroadcastDevice = {
  deviceKey: string;
  displayName: string;
  status: "OFFLINE" | "READY" | "STREAMING" | "ERROR";
  obsConnected: boolean;
  obsStreaming: boolean;
  currentFixtureId: string | null;
  currentOpenQueueGameId: string | null;
  lastSeenAt: string | null;
  errorMessage: string | null;
};

type FixtureForBroadcast = {
  id: string;
  status: string;
  homeClanId: string;
  awayClanId: string;
  homeName: string;
  awayName: string;
};

export async function getFixtureBroadcast(
  db: SupabaseClient,
  fixtureId: string,
) {
  const { data, error } = await db
    .from("fixture_broadcasts")
    .select("*")
    .eq("fixture_id", fixtureId)
    .maybeSingle();

  if (error) throw new Error(`Could not load broadcast: ${error.message}`);
  return data ? normalizeBroadcast(data) : null;
}

export async function getBroadcastDevice(db: SupabaseClient) {
  const key = broadcastDeviceKey();
  const { data, error } = await db
    .from("broadcast_devices")
    .select("*")
    .eq("device_key", key)
    .maybeSingle();

  if (error) throw new Error(`Could not load camera device: ${error.message}`);
  if (!data) return null;

  const device = normalizeDevice(data);
  if (
    device.lastSeenAt &&
    Date.now() - new Date(device.lastSeenAt).getTime() > 15_000
  ) {
    return { ...device, status: "OFFLINE" as const, obsStreaming: false };
  }
  return device;
}

export async function ensureBroadcastDevice(db: SupabaseClient) {
  const deviceKey = broadcastDeviceKey();
  const { error } = await db.from("broadcast_devices").upsert(
    {
      device_key: deviceKey,
      display_name: broadcastDeviceName(),
    },
    { onConflict: "device_key" },
  );

  if (error) throw new Error(`Could not configure camera device: ${error.message}`);
  return deviceKey;
}

export async function ensureFixtureBroadcast(
  db: SupabaseClient,
  fixtureId: string,
  requestedBy: string,
) {
  const fixture = await loadFixtureForBroadcast(db, fixtureId);
  assertBroadcastableFixture(fixture);

  const existing = await getFixtureBroadcast(db, fixtureId);
  if (existing?.liveInputId) {
    return existing;
  }

  const input = await createCloudflareLiveInput({
    fixtureId,
    name: `${fixture.homeName} vs ${fixture.awayName}`,
  });
  const hlsUrl = cloudflareHlsUrl(input.uid);
  const { data, error } = await db
    .from("fixture_broadcasts")
    .upsert(
      {
        fixture_id: fixtureId,
        provider: "cloudflare",
        live_input_id: input.uid,
        status: "READY",
        hls_url: hlsUrl,
        created_by: requestedBy,
        error_message: null,
      },
      { onConflict: "fixture_id" },
    )
    .select("*")
    .single();

  if (error) throw new Error(`Could not save broadcast: ${error.message}`);
  return normalizeBroadcast(data);
}

export async function queueBroadcastStart(
  db: SupabaseClient,
  fixtureId: string,
  requestedBy: string,
) {
  const deviceKey = await ensureBroadcastDevice(db);
  const broadcast = await ensureFixtureBroadcast(db, fixtureId, requestedBy);
  if (!broadcast.liveInputId) throw new Error("Broadcast input is unavailable.");

  await setCloudflareLiveInputEnabled(broadcast.liveInputId, true);
  await failActiveCommands(db, fixtureId, "STOP_STREAM", "Superseded by start.");
  await queueCommand(db, fixtureId, deviceKey, "START_STREAM", requestedBy);

  const now = new Date().toISOString();
  const { error } = await db
    .from("fixture_broadcasts")
    .update({
      status: "STARTING",
      stream_requested_at: now,
      stream_started_at: null,
      stream_stopped_at: null,
      recording_ready_at: null,
      replay_hls_url: null,
      active_video_id: null,
      error_message: null,
    })
    .eq("fixture_id", fixtureId);

  if (error) throw new Error(`Could not start broadcast: ${error.message}`);
  return getFixtureBroadcast(db, fixtureId);
}

export async function queueBroadcastStop(
  db: SupabaseClient,
  fixtureId: string,
  requestedBy: string,
  delaySeconds = 0,
) {
  const broadcast = await getFixtureBroadcast(db, fixtureId);
  if (!broadcast?.liveInputId) return null;
  if (broadcast.streamStoppedAt || broadcast.status === "REPLAY_READY") {
    return broadcast;
  }

  const deviceKey = await ensureBroadcastDevice(db);
  await failActiveCommands(db, fixtureId, "START_STREAM", "Superseded by stop.");

  const availableAt = new Date(Date.now() + delaySeconds * 1000).toISOString();
  const { data: existing, error: existingError } = await db
    .from("broadcast_commands")
    .select("id,status,available_at")
    .eq("fixture_id", fixtureId)
    .eq("action", "STOP_STREAM")
    .in("status", ["PENDING", "CLAIMED"])
    .maybeSingle();

  if (existingError) {
    throw new Error(`Could not inspect stop command: ${existingError.message}`);
  }

  if (
    existing?.status === "PENDING" &&
    isEarlierTimestamp(availableAt, existing.available_at)
  ) {
    const { error } = await db
      .from("broadcast_commands")
      .update({ available_at: availableAt })
      .eq("id", existing.id);
    if (error) throw new Error(`Could not update stop command: ${error.message}`);
  } else if (!existing) {
    await queueCommand(
      db,
      fixtureId,
      deviceKey,
      "STOP_STREAM",
      requestedBy,
      availableAt,
    );
  }

  const { error } = await db
    .from("fixture_broadcasts")
    .update({ status: "STOPPING", error_message: null })
    .eq("fixture_id", fixtureId)
    .is("stream_stopped_at", null)
    .neq("status", "REPLAY_READY");
  if (error) throw new Error(`Could not stop broadcast: ${error.message}`);

  return getFixtureBroadcast(db, fixtureId);
}

export async function syncBroadcastFromCloudflare(
  db: SupabaseClient,
  fixtureId: string,
) {
  const broadcast = await getFixtureBroadcast(db, fixtureId);
  if (!broadcast?.liveInputId) return broadcast;

  try {
    const lifecycle = await getCloudflareLifecycle(broadcast.liveInputId);
    if (lifecycle.live) {
      // Cloudflare can report the previous live lifecycle briefly after OBS stops.
      // Once our stop is recorded (or its replay is ready), LIVE is no longer a
      // valid state for this broadcast.
      if (broadcast.streamStoppedAt || broadcast.status === "REPLAY_READY") {
        return broadcast;
      }
      let providerStartedAt: string | null = null;
      if (
        lifecycle.videoUID &&
        broadcast.activeVideoId !== lifecycle.videoUID
      ) {
        const liveVideo = await getCloudflareVideo(lifecycle.videoUID);
        providerStartedAt = validRecordingTimestamp(liveVideo?.created);
      }
      const { error } = await db
        .from("fixture_broadcasts")
        .update({
          status: "LIVE",
          active_video_id: lifecycle.videoUID,
          stream_started_at:
            providerStartedAt ??
            broadcast.streamStartedAt ??
            new Date().toISOString(),
          error_message: null,
        })
        .eq("fixture_id", fixtureId)
        .is("stream_stopped_at", null)
        .neq("status", "REPLAY_READY");
      if (error) throw error;
      return getFixtureBroadcast(db, fixtureId);
    }

    let activeVideoId = broadcast.activeVideoId;
    if (
      !activeVideoId &&
      ["STARTING", "LIVE", "STOPPING", "PROCESSING"].includes(
        broadcast.status,
      )
    ) {
      const recordings = await listCloudflareLiveInputVideos(
        broadcast.liveInputId,
      );
      const latest = recordings
        .filter((video) => Boolean(video.uid))
        .sort((left, right) =>
          (right.created ?? "").localeCompare(left.created ?? ""),
        )[0];
      activeVideoId = latest?.uid ?? null;

      if (activeVideoId) {
        const { error } = await db
          .from("fixture_broadcasts")
          .update({ active_video_id: activeVideoId })
          .eq("fixture_id", fixtureId);
        if (error) throw error;
      }
    }

    if (activeVideoId) {
      const video = await getCloudflareVideo(activeVideoId);
      const isReady = video?.readyToStream === true ||
        video?.status?.state === "ready";
      const replayUrl = video?.playback?.hls ??
        cloudflareHlsUrl(activeVideoId);

      if (video?.status?.state === "error") {
        const { error } = await db
          .from("fixture_broadcasts")
          .update({
            status: "ERROR",
            active_video_id: activeVideoId,
            error_message:
              video.status.errorReasonText ?? "Cloudflare could not process the recording.",
          })
          .eq("fixture_id", fixtureId);
        if (error) throw error;
        return getFixtureBroadcast(db, fixtureId);
      }

      if (isReady) {
        const readyAt = new Date().toISOString();
        const { error } = await db
          .from("fixture_broadcasts")
          .update({
            status: "REPLAY_READY",
            active_video_id: activeVideoId,
            replay_hls_url: replayUrl,
            recording_ready_at: readyAt,
            error_message: null,
          })
          .eq("fixture_id", fixtureId);
        if (error) throw error;

        const { error: fixtureError } = await db
          .from("fixtures")
          .update({ video_url: replayUrl })
          .eq("id", fixtureId);
        if (fixtureError) throw fixtureError;
        return getFixtureBroadcast(db, fixtureId);
      }

      if (
        ["LIVE", "STOPPING", "PROCESSING"].includes(broadcast.status)
      ) {
        const { error } = await db
          .from("fixture_broadcasts")
          .update({ status: "PROCESSING", replay_hls_url: replayUrl })
          .eq("fixture_id", fixtureId);
        if (error) throw error;
      }
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Stream status failed.";
    await db
      .from("fixture_broadcasts")
      .update({ error_message: message })
      .eq("fixture_id", fixtureId);
  }

  return getFixtureBroadcast(db, fixtureId);
}

export async function getOpenQueueBroadcast(
  db: SupabaseClient,
  gameId: string,
) {
  const { data, error } = await db
    .from("open_queue_broadcasts")
    .select("*")
    .eq("game_id", gameId)
    .maybeSingle();
  if (error) throw new Error(`Could not load solo broadcast: ${error.message}`);
  return data ? normalizeOpenQueueBroadcast(data) : null;
}

export async function ensureOpenQueueBroadcast(
  db: SupabaseClient,
  gameId: string,
  requestedBy: string,
) {
  const { data: game, error: gameError } = await db
    .from("open_queue_games")
    .select("id,status")
    .eq("id", gameId)
    .single();
  if (gameError) throw new Error(`Could not load solo game: ${gameError.message}`);
  if (!["FULL", "LIVE"].includes(String(game.status))) {
    throw new Error("Only a full or live solo game can be streamed.");
  }

  const existing = await getOpenQueueBroadcast(db, gameId);
  if (existing?.liveInputId) return existing;

  const input = await createCloudflareLiveInput({
    openQueueGameId: gameId,
    name: "White vs Black · Solo game",
  });
  const { data, error } = await db.from("open_queue_broadcasts").upsert(
    {
      game_id: gameId,
      provider: "cloudflare",
      live_input_id: input.uid,
      status: "READY",
      hls_url: cloudflareHlsUrl(input.uid),
      created_by: requestedBy,
      error_message: null,
    },
    { onConflict: "game_id" },
  ).select("*").single();
  if (error) throw new Error(`Could not save solo broadcast: ${error.message}`);
  return normalizeOpenQueueBroadcast(data);
}

export async function queueOpenQueueBroadcastStart(
  db: SupabaseClient,
  gameId: string,
  requestedBy: string,
) {
  const deviceKey = await ensureBroadcastDevice(db);
  const broadcast = await ensureOpenQueueBroadcast(db, gameId, requestedBy);
  if (!broadcast.liveInputId) throw new Error("Broadcast input is unavailable.");

  await setCloudflareLiveInputEnabled(broadcast.liveInputId, true);
  await failActiveOpenQueueCommands(
    db,
    gameId,
    "STOP_STREAM",
    "Superseded by start.",
  );
  await queueOpenQueueCommand(db, gameId, deviceKey, "START_STREAM", requestedBy);
  const { error } = await db.from("open_queue_broadcasts").update({
    status: "STARTING",
    stream_requested_at: new Date().toISOString(),
    stream_started_at: null,
    stream_stopped_at: null,
    recording_ready_at: null,
    replay_hls_url: null,
    active_video_id: null,
    error_message: null,
  }).eq("game_id", gameId);
  if (error) throw new Error(`Could not start solo broadcast: ${error.message}`);
  return getOpenQueueBroadcast(db, gameId);
}

export async function queueOpenQueueBroadcastStop(
  db: SupabaseClient,
  gameId: string,
  requestedBy: string,
  delaySeconds = 0,
) {
  const broadcast = await getOpenQueueBroadcast(db, gameId);
  if (!broadcast?.liveInputId) return null;
  if (broadcast.streamStoppedAt || broadcast.status === "REPLAY_READY") {
    return broadcast;
  }

  const deviceKey = await ensureBroadcastDevice(db);
  await failActiveOpenQueueCommands(
    db,
    gameId,
    "START_STREAM",
    "Superseded by stop.",
  );
  const availableAt = new Date(Date.now() + delaySeconds * 1000).toISOString();
  const { data: existing, error: existingError } = await db
    .from("broadcast_commands")
    .select("id,status,available_at")
    .eq("open_queue_game_id", gameId)
    .eq("action", "STOP_STREAM")
    .in("status", ["PENDING", "CLAIMED"])
    .maybeSingle();
  if (existingError) throw new Error(`Could not inspect stop command: ${existingError.message}`);

  if (
    existing?.status === "PENDING" &&
    isEarlierTimestamp(availableAt, existing.available_at)
  ) {
    const { error } = await db.from("broadcast_commands").update({
      available_at: availableAt,
    }).eq("id", existing.id);
    if (error) throw new Error(`Could not update stop command: ${error.message}`);
  } else if (!existing) {
    await queueOpenQueueCommand(
      db,
      gameId,
      deviceKey,
      "STOP_STREAM",
      requestedBy,
      availableAt,
    );
  }
  const { error } = await db.from("open_queue_broadcasts")
    .update({ status: "STOPPING", error_message: null })
    .eq("game_id", gameId)
    .is("stream_stopped_at", null)
    .neq("status", "REPLAY_READY");
  if (error) throw new Error(`Could not stop solo broadcast: ${error.message}`);
  return getOpenQueueBroadcast(db, gameId);
}

export async function syncOpenQueueBroadcastFromCloudflare(
  db: SupabaseClient,
  gameId: string,
) {
  const broadcast = await getOpenQueueBroadcast(db, gameId);
  if (!broadcast?.liveInputId) return broadcast;

  try {
    const lifecycle = await getCloudflareLifecycle(broadcast.liveInputId);
    if (lifecycle.live) {
      if (broadcast.streamStoppedAt || broadcast.status === "REPLAY_READY") {
        return broadcast;
      }
      let providerStartedAt: string | null = null;
      if (lifecycle.videoUID && broadcast.activeVideoId !== lifecycle.videoUID) {
        const video = await getCloudflareVideo(lifecycle.videoUID);
        providerStartedAt = validRecordingTimestamp(video?.created);
      }
      const { error } = await db.from("open_queue_broadcasts").update({
        status: "LIVE",
        active_video_id: lifecycle.videoUID,
        stream_started_at:
          providerStartedAt ?? broadcast.streamStartedAt ?? new Date().toISOString(),
        error_message: null,
      })
        .eq("game_id", gameId)
        .is("stream_stopped_at", null)
        .neq("status", "REPLAY_READY");
      if (error) throw error;
      return getOpenQueueBroadcast(db, gameId);
    }

    let activeVideoId = broadcast.activeVideoId;
    if (
      !activeVideoId &&
      ["STARTING", "LIVE", "STOPPING", "PROCESSING"].includes(broadcast.status)
    ) {
      const recordings = await listCloudflareLiveInputVideos(broadcast.liveInputId);
      activeVideoId = recordings
        .filter((video) => Boolean(video.uid))
        .sort((left, right) => (right.created ?? "").localeCompare(left.created ?? ""))[0]
        ?.uid ?? null;
      if (activeVideoId) {
        const { error } = await db.from("open_queue_broadcasts")
          .update({ active_video_id: activeVideoId })
          .eq("game_id", gameId);
        if (error) throw error;
      }
    }

    if (activeVideoId) {
      const video = await getCloudflareVideo(activeVideoId);
      const replayUrl = video?.playback?.hls ?? cloudflareHlsUrl(activeVideoId);
      if (video?.status?.state === "error") {
        const { error } = await db.from("open_queue_broadcasts").update({
          status: "ERROR",
          active_video_id: activeVideoId,
          error_message:
            video.status.errorReasonText ?? "Cloudflare could not process the recording.",
        }).eq("game_id", gameId);
        if (error) throw error;
        return getOpenQueueBroadcast(db, gameId);
      }

      if (video?.readyToStream === true || video?.status?.state === "ready") {
        const { error } = await db.from("open_queue_broadcasts").update({
          status: "REPLAY_READY",
          active_video_id: activeVideoId,
          replay_hls_url: replayUrl,
          recording_ready_at: new Date().toISOString(),
          error_message: null,
        }).eq("game_id", gameId);
        if (error) throw error;
        const { error: gameError } = await db.from("open_queue_games")
          .update({ video_url: replayUrl })
          .eq("id", gameId);
        if (gameError) throw gameError;
        return getOpenQueueBroadcast(db, gameId);
      }

      if (["LIVE", "STOPPING", "PROCESSING"].includes(broadcast.status)) {
        const { error } = await db.from("open_queue_broadcasts")
          .update({ status: "PROCESSING", replay_hls_url: replayUrl })
          .eq("game_id", gameId);
        if (error) throw error;
      }
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Stream status failed.";
    await db.from("open_queue_broadcasts").update({ error_message: message })
      .eq("game_id", gameId);
  }
  return getOpenQueueBroadcast(db, gameId);
}

export async function getStreamCredentials(inputId: string) {
  const input = await getCloudflareLiveInput(inputId);
  if (!input.rtmps?.url || !input.rtmps?.streamKey) {
    throw new Error("Cloudflare did not return stream credentials.");
  }
  return input.rtmps;
}

export async function markBroadcastStopped(
  db: SupabaseClient,
  fixtureId: string,
) {
  const broadcast = await getFixtureBroadcast(db, fixtureId);
  if (!broadcast?.liveInputId || broadcast.streamStoppedAt) return;

  if (broadcast.status !== "REPLAY_READY") {
    await setCloudflareLiveInputEnabled(broadcast.liveInputId, false);
  }
  const stoppedAt = new Date().toISOString();
  const replayUrl = broadcast.replayHlsUrl ?? (broadcast.activeVideoId
    ? cloudflareHlsUrl(broadcast.activeVideoId)
    : null);
  const { data: marked, error } = await db
    .from("fixture_broadcasts")
    .update({
      status: "PROCESSING",
      stream_stopped_at: stoppedAt,
      replay_hls_url: replayUrl,
      error_message: null,
    })
    .eq("fixture_id", fixtureId)
    .is("stream_stopped_at", null)
    .neq("status", "REPLAY_READY")
    .select("fixture_id")
    .maybeSingle();
  if (error) throw new Error(`Could not save stopped broadcast: ${error.message}`);
  if (marked) return;

  const { error: replayReadyError } = await db
    .from("fixture_broadcasts")
    .update({ stream_stopped_at: stoppedAt })
    .eq("fixture_id", fixtureId)
    .is("stream_stopped_at", null)
    .eq("status", "REPLAY_READY");
  if (replayReadyError) {
    throw new Error(`Could not save stopped broadcast: ${replayReadyError.message}`);
  }
}

export async function markOpenQueueBroadcastStopped(
  db: SupabaseClient,
  gameId: string,
) {
  const broadcast = await getOpenQueueBroadcast(db, gameId);
  if (!broadcast?.liveInputId || broadcast.streamStoppedAt) return;
  if (broadcast.status !== "REPLAY_READY") {
    await setCloudflareLiveInputEnabled(broadcast.liveInputId, false);
  }
  const stoppedAt = new Date().toISOString();
  const replayUrl = broadcast.replayHlsUrl ?? (broadcast.activeVideoId
    ? cloudflareHlsUrl(broadcast.activeVideoId)
    : null);
  const { data: marked, error } = await db.from("open_queue_broadcasts").update({
    status: "PROCESSING",
    stream_stopped_at: stoppedAt,
    replay_hls_url: replayUrl,
    error_message: null,
  })
    .eq("game_id", gameId)
    .is("stream_stopped_at", null)
    .neq("status", "REPLAY_READY")
    .select("game_id")
    .maybeSingle();
  if (error) throw new Error(`Could not save stopped solo broadcast: ${error.message}`);
  if (marked) return;

  const { error: replayReadyError } = await db
    .from("open_queue_broadcasts")
    .update({ stream_stopped_at: stoppedAt })
    .eq("game_id", gameId)
    .is("stream_stopped_at", null)
    .eq("status", "REPLAY_READY");
  if (replayReadyError) {
    throw new Error(
      `Could not save stopped solo broadcast: ${replayReadyError.message}`,
    );
  }
}

async function loadFixtureForBroadcast(
  db: SupabaseClient,
  fixtureId: string,
): Promise<FixtureForBroadcast> {
  const { data, error } = await db
    .from("fixtures")
    .select(`
      id,
      status,
      home_clan_id,
      away_clan_id,
      home_clan:clans!fixtures_home_clan_id_fkey(name),
      away_clan:clans!fixtures_away_clan_id_fkey(name)
    `)
    .eq("id", fixtureId)
    .single();

  if (error) throw new Error(`Could not load fixture: ${error.message}`);
  const home = firstObject(data.home_clan);
  const away = firstObject(data.away_clan);
  return {
    id: String(data.id),
    status: String(data.status),
    homeClanId: String(data.home_clan_id),
    awayClanId: data.away_clan_id ? String(data.away_clan_id) : "",
    homeName: String(home.name ?? "Home"),
    awayName: String(away.name ?? "Away"),
  };
}

function assertBroadcastableFixture(fixture: FixtureForBroadcast) {
  if (!fixture.awayClanId) throw new Error("An opponent must join before streaming.");
  if (!["SCHEDULED", "LIVE"].includes(fixture.status)) {
    throw new Error("Only scheduled or live matches can be streamed.");
  }
}

async function queueCommand(
  db: SupabaseClient,
  fixtureId: string,
  deviceKey: string,
  action: "START_STREAM" | "STOP_STREAM",
  requestedBy: string,
  availableAt = new Date().toISOString(),
) {
  const { data: existing, error: existingError } = await db
    .from("broadcast_commands")
    .select("id")
    .eq("fixture_id", fixtureId)
    .eq("action", action)
    .in("status", ["PENDING", "CLAIMED"])
    .maybeSingle();
  if (existingError) throw existingError;
  if (existing) return String(existing.id);

  const { data, error } = await db
    .from("broadcast_commands")
    .insert({
      fixture_id: fixtureId,
      device_key: deviceKey,
      action,
      requested_by: requestedBy,
      available_at: availableAt,
    })
    .select("id")
    .single();
  if (error) throw new Error(`Could not queue camera command: ${error.message}`);
  return String(data.id);
}

async function failActiveCommands(
  db: SupabaseClient,
  fixtureId: string,
  action: "START_STREAM" | "STOP_STREAM",
  reason: string,
) {
  const { error } = await db
    .from("broadcast_commands")
    .update({
      status: "FAILED",
      completed_at: new Date().toISOString(),
      error_message: reason,
    })
    .eq("fixture_id", fixtureId)
    .eq("action", action)
    .in("status", ["PENDING", "CLAIMED"]);
  if (error) throw new Error(`Could not clear camera command: ${error.message}`);
}

async function queueOpenQueueCommand(
  db: SupabaseClient,
  gameId: string,
  deviceKey: string,
  action: "START_STREAM" | "STOP_STREAM",
  requestedBy: string,
  availableAt = new Date().toISOString(),
) {
  const { data: existing, error: existingError } = await db
    .from("broadcast_commands")
    .select("id")
    .eq("open_queue_game_id", gameId)
    .eq("action", action)
    .in("status", ["PENDING", "CLAIMED"])
    .maybeSingle();
  if (existingError) throw existingError;
  if (existing) return String(existing.id);

  const { data, error } = await db.from("broadcast_commands").insert({
    fixture_id: null,
    open_queue_game_id: gameId,
    device_key: deviceKey,
    action,
    requested_by: requestedBy,
    available_at: availableAt,
  }).select("id").single();
  if (error) throw new Error(`Could not queue camera command: ${error.message}`);
  return String(data.id);
}

async function failActiveOpenQueueCommands(
  db: SupabaseClient,
  gameId: string,
  action: "START_STREAM" | "STOP_STREAM",
  reason: string,
) {
  const { error } = await db.from("broadcast_commands").update({
    status: "FAILED",
    completed_at: new Date().toISOString(),
    error_message: reason,
  }).eq("open_queue_game_id", gameId)
    .eq("action", action)
    .in("status", ["PENDING", "CLAIMED"]);
  if (error) throw new Error(`Could not clear camera command: ${error.message}`);
}

function normalizeBroadcast(row: Record<string, unknown>): FixtureBroadcast {
  return {
    matchKind: "CLAN",
    fixtureId: String(row.fixture_id),
    openQueueGameId: null,
    liveInputId: nullableString(row.live_input_id),
    activeVideoId: nullableString(row.active_video_id),
    status: String(row.status) as BroadcastStatus,
    hlsUrl: nullableString(row.hls_url),
    replayHlsUrl: nullableString(row.replay_hls_url),
    streamRequestedAt: nullableString(row.stream_requested_at),
    streamStartedAt: nullableString(row.stream_started_at),
    streamStoppedAt: nullableString(row.stream_stopped_at),
    recordingReadyAt: nullableString(row.recording_ready_at),
    errorMessage: nullableString(row.error_message),
  };
}

function normalizeOpenQueueBroadcast(
  row: Record<string, unknown>,
): FixtureBroadcast {
  const gameId = String(row.game_id);
  return {
    matchKind: "SOLO",
    fixtureId: gameId,
    openQueueGameId: gameId,
    liveInputId: nullableString(row.live_input_id),
    activeVideoId: nullableString(row.active_video_id),
    status: String(row.status) as BroadcastStatus,
    hlsUrl: nullableString(row.hls_url),
    replayHlsUrl: nullableString(row.replay_hls_url),
    streamRequestedAt: nullableString(row.stream_requested_at),
    streamStartedAt: nullableString(row.stream_started_at),
    streamStoppedAt: nullableString(row.stream_stopped_at),
    recordingReadyAt: nullableString(row.recording_ready_at),
    errorMessage: nullableString(row.error_message),
  };
}

function normalizeDevice(row: Record<string, unknown>): BroadcastDevice {
  return {
    deviceKey: String(row.device_key),
    displayName: String(row.display_name),
    status: String(row.status) as BroadcastDevice["status"],
    obsConnected: row.obs_connected === true,
    obsStreaming: row.obs_streaming === true,
    currentFixtureId: nullableString(row.current_fixture_id),
    currentOpenQueueGameId: nullableString(row.current_open_queue_game_id),
    lastSeenAt: nullableString(row.last_seen_at),
    errorMessage: nullableString(row.error_message),
  };
}

function firstObject(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return firstObject(value[0]);
  if (value && typeof value === "object") return value as Record<string, unknown>;
  return {};
}

function nullableString(value: unknown) {
  return value === null || value === undefined ? null : String(value);
}

function isEarlierTimestamp(candidate: string, current: unknown) {
  const candidateMilliseconds = Date.parse(candidate);
  const currentMilliseconds = Date.parse(String(current ?? ""));
  return Number.isFinite(candidateMilliseconds) &&
    (!Number.isFinite(currentMilliseconds) ||
      candidateMilliseconds < currentMilliseconds);
}

function validRecordingTimestamp(value: string | undefined) {
  if (!value) return null;
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || milliseconds > Date.now() + 60_000) {
    return null;
  }
  return new Date(milliseconds).toISOString();
}
