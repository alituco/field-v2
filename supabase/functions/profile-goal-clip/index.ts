import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

// deno-lint-ignore no-explicit-any
type SupabaseAnyClient = ReturnType<typeof createClient<any, "public", any>>;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const leadInSeconds = 10;
const followThroughSeconds = 20;

type JsonBody = {
  action?: unknown;
  source_type?: unknown;
  match_id?: unknown;
  event_id?: unknown;
  title?: unknown;
  highlight_id?: unknown;
  start_seconds?: unknown;
  end_seconds?: unknown;
  save_to_profile?: unknown;
};

type ProfileHighlightRow = {
  id: string;
  profile_id: string;
  title: string;
  thumbnail_url: string | null;
  video_url: string | null;
  duration: string;
  views: number;
  clan_tag: string | null;
  source_type: "CLAN" | "SOLO" | null;
  source_match_id: string | null;
  source_event_id: string | null;
  provider_source_video_id: string | null;
  provider_source_duration_seconds: number | null;
  provider_video_id: string | null;
  provider_request_started_at: string | null;
  clip_start_seconds: number | null;
  clip_end_seconds: number | null;
  processing_status: "PROCESSING" | "READY" | "FAILED";
  processing_error: string | null;
  download_status:
    | "UNAVAILABLE"
    | "NOT_REQUESTED"
    | "PROCESSING"
    | "READY"
    | "FAILED";
  download_url: string | null;
};

type GoalClipRequest = {
  highlight: ProfileHighlightRow;
  source_video_id: string;
  goal_occurred_at: string;
  goal_timestamps: unknown;
  stream_started_at: string;
  stream_stopped_at: string | null;
};

type CloudflareVideo = {
  uid?: unknown;
  duration?: unknown;
  readyToStream?: unknown;
  thumbnail?: unknown;
  playback?: {
    hls?: unknown;
  };
  status?: {
    state?: unknown;
    errorReasonText?: unknown;
  };
};

type CloudflareEnvelope<T> = {
  success?: boolean;
  result?: T;
  errors?: Array<{ message?: unknown }>;
};

type MatchSource = {
  sourceType: "CLAN" | "SOLO";
  matchId: string;
  sourceVideoId: string;
  streamStartedAt: string;
  streamStoppedAt: string | null;
};

type ReadyMatchSource = MatchSource & {
  durationSeconds: number;
};

type GoalSource = MatchSource & {
  goalOccurredAt: string;
  goalTimestamps: string[];
};

type CloudflareDownloads = {
  default?: {
    status?: unknown;
    url?: unknown;
    percentComplete?: unknown;
  };
};

type FunctionContext = {
  admin: SupabaseAnyClient;
  accountId: string;
  apiToken: string;
  customerCode: string;
  userId: string;
};

class HttpError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const accountId = Deno.env.get("CLOUDFLARE_ACCOUNT_ID");
  const apiToken = Deno.env.get("CLOUDFLARE_STREAM_API_TOKEN");
  const customerCode = normalizedCustomerCode(
    Deno.env.get("CLOUDFLARE_STREAM_CUSTOMER_CODE"),
  );
  if (
    !supabaseUrl ||
    !anonKey ||
    !serviceRoleKey ||
    !accountId ||
    !apiToken ||
    !customerCode
  ) {
    return json({ error: "Goal clip processing is not configured." }, 500);
  }

  const bearerToken = readBearerToken(request.headers.get("Authorization"));
  if (!bearerToken) {
    return json({ error: "Sign in to use match clips." }, 401);
  }

  let body: JsonBody;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  }) as SupabaseAnyClient;
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${bearerToken}` } },
  }) as SupabaseAnyClient;

  const { data: authData, error: authError } = await admin.auth.getUser(
    bearerToken,
  );
  if (authError || !authData.user) {
    return json({ error: "Your session has expired. Sign in again." }, 401);
  }

  const context: FunctionContext = {
    admin,
    accountId,
    apiToken,
    customerCode,
    userId: authData.user.id,
  };

  try {
    const action = normalizedString(body.action)?.toLowerCase();
    if (action === "create") {
      return await createGoalClip(context, userClient, body);
    }
    if (action === "status") {
      return await refreshGoalClip(
        context,
        requireUuid(
          body.highlight_id,
          "Choose a valid clip.",
        ),
      );
    }
    if (action === "goal_download") {
      return await downloadGoalClip(context, body);
    }
    if (action === "custom_clip") {
      return await createCustomClip(context, body);
    }
    if (action === "full_game_download") {
      return await prepareFullGameDownload(context, body);
    }
    throw new HttpError("Choose a valid match clip action.", 400);
  } catch (error) {
    if (error instanceof HttpError) {
      return json({ error: error.message }, error.status);
    }
    console.error("profile-goal-clip failed", error);
    return json({ error: errorMessage(error) }, 500);
  }
});

async function createGoalClip(
  context: FunctionContext,
  userClient: SupabaseAnyClient,
  body: JsonBody,
) {
  const sourceType = normalizedString(body.source_type)?.toUpperCase();
  if (sourceType !== "CLAN" && sourceType !== "SOLO") {
    throw new HttpError("Choose a valid match type.", 400);
  }
  const matchId = requireUuid(body.match_id, "Choose a valid match.");
  const eventId = requireUuid(body.event_id, "Choose a valid goal.");
  const title = normalizedString(body.title);
  if (!title || title.length < 2 || title.length > 80) {
    throw new HttpError("Clip title must be between 2 and 80 characters.", 400);
  }

  const { data, error } = await userClient.rpc("request_profile_goal_clip", {
    source_type_to_use: sourceType,
    source_match_id_to_use: matchId,
    source_event_id_to_use: eventId,
    title_to_use: title,
  });
  if (error) {
    throw new HttpError(error.message, 400);
  }

  const clipRequest = goalClipRequest(data);
  let highlight = clipRequest.highlight;
  if (
    highlight.processing_status === "READY" &&
    highlight.video_url &&
    highlight.download_url
  ) {
    return json({ highlight });
  }
  if (highlight.processing_status === "FAILED") {
    const { data: retried, error: retryError } = await context.admin
      .from("profile_highlights")
      .update({
        processing_status: "PROCESSING",
        processing_error: null,
        provider_request_started_at: null,
      })
      .eq("id", highlight.id)
      .eq("profile_id", context.userId)
      .is("provider_video_id", null)
      .select(highlightSelect)
      .single();
    if (retryError) throw retryError;
    highlight = profileHighlightRow(retried);
  }

  const { data: claimed, error: claimError } = await context.admin.rpc(
    "claim_profile_goal_clip_provider_request",
    { highlight_id_to_use: highlight.id },
  );
  if (claimError) throw claimError;
  if (claimed !== true) {
    const current = await loadOwnedHighlight(context, highlight.id);
    return json({ highlight: current }, 202);
  }

  try {
    const sourceVideo = await cloudflareRequest<CloudflareVideo>(
      context,
      `/stream/${encodeURIComponent(clipRequest.source_video_id)}`,
    );
    const sourceDuration = positiveNumber(sourceVideo.duration);
    if (!sourceDuration) {
      throw new HttpError(
        "The match recording duration is not ready yet.",
        409,
      );
    }
    const sourceState = normalizedString(sourceVideo.status?.state)
      ?.toLowerCase();
    if (
      sourceVideo.readyToStream !== true &&
      sourceState !== "ready"
    ) {
      throw new HttpError("The match recording is still processing.", 409);
    }

    const bounds = replayClipBounds({
      sourceDuration,
      goalOccurredAt: clipRequest.goal_occurred_at,
      goalTimestamps: timestampList(clipRequest.goal_timestamps),
      streamStartedAt: clipRequest.stream_started_at,
      streamStoppedAt: clipRequest.stream_stopped_at,
    });
    const clipDuration = bounds.end - bounds.start;
    const urls = liveInstantClipUrls(
      context.customerCode,
      clipRequest.source_video_id,
      bounds.start,
      clipDuration,
      clamp(bounds.goal, 0, sourceDuration),
      highlight.title,
    );

    const { data: updated, error: updateError } = await context.admin
      .from("profile_highlights")
      .update({
        provider_source_video_id: clipRequest.source_video_id,
        provider_source_duration_seconds: roundMilliseconds(sourceDuration),
        provider_video_id: null,
        clip_start_seconds: roundMilliseconds(bounds.start),
        clip_end_seconds: roundMilliseconds(bounds.end),
        duration: formattedDuration(clipDuration),
        thumbnail_url: urls.thumbnail,
        video_url: urls.playback,
        processing_status: "READY",
        processing_error: null,
        download_status: "READY",
        download_url: urls.download,
      })
      .eq("id", highlight.id)
      .eq("profile_id", context.userId)
      .select(highlightSelect)
      .single();
    if (updateError) throw updateError;

    return json({ highlight: profileHighlightRow(updated) });
  } catch (error) {
    await context.admin
      .from("profile_highlights")
      .update({
        processing_status: "FAILED",
        processing_error: errorMessage(error),
        provider_request_started_at: null,
      })
      .eq("id", highlight.id)
      .eq("profile_id", context.userId)
      .is("provider_video_id", null);
    throw error;
  }
}

async function refreshGoalClip(
  context: FunctionContext,
  highlightId: string,
) {
  let highlight = await loadOwnedHighlight(context, highlightId);
  if (!highlight.source_type) {
    throw new HttpError("That legacy highlight cannot be processed.", 400);
  }
  if (
    highlight.processing_status === "READY" &&
    highlight.download_status === "READY" &&
    highlight.video_url &&
    highlight.download_url
  ) {
    return json({ highlight });
  }
  if (
    highlight.provider_source_video_id &&
    highlight.clip_start_seconds != null &&
    highlight.clip_end_seconds != null &&
    highlight.clip_end_seconds > highlight.clip_start_seconds
  ) {
    const clipDuration = highlight.clip_end_seconds -
      highlight.clip_start_seconds;
    const thumbnailTime = highlight.clip_start_seconds +
      Math.min(leadInSeconds, clipDuration / 2);
    const urls = liveInstantClipUrls(
      context.customerCode,
      highlight.provider_source_video_id,
      highlight.clip_start_seconds,
      clipDuration,
      thumbnailTime,
      highlight.title,
    );
    highlight = await updateOwnedHighlight(context, highlight.id, {
      thumbnail_url: urls.thumbnail,
      video_url: urls.playback,
      processing_status: "READY",
      processing_error: null,
      download_status: "READY",
      download_url: urls.download,
    });
    return json({ highlight });
  }
  return json(
    { highlight },
    highlight.processing_status === "FAILED" ? 200 : 202,
  );
}

async function downloadGoalClip(
  context: FunctionContext,
  body: JsonBody,
) {
  const sourceType = requireSourceType(body.source_type);
  const matchId = requireUuid(body.match_id, "Choose a valid match.");
  const eventId = requireUuid(body.event_id, "Choose a valid goal.");
  const goalSource = await loadGoalSource(
    context,
    sourceType,
    matchId,
    eventId,
  );
  const source = await readyMatchSource(context, goalSource);
  const bounds = replayClipBounds({
    sourceDuration: source.durationSeconds,
    goalOccurredAt: goalSource.goalOccurredAt,
    goalTimestamps: goalSource.goalTimestamps,
    streamStartedAt: goalSource.streamStartedAt,
    streamStoppedAt: goalSource.streamStoppedAt,
  });
  return json({
    media: instantMedia(
      context.customerCode,
      source.sourceVideoId,
      bounds.start,
      bounds.end,
      clamp(bounds.goal, 0, source.durationSeconds),
      "Field goal clip",
    ),
  });
}

async function createCustomClip(
  context: FunctionContext,
  body: JsonBody,
) {
  const sourceType = requireSourceType(body.source_type);
  const matchId = requireUuid(body.match_id, "Choose a valid match.");
  const start = requiredSeconds(
    body.start_seconds,
    "Choose a valid clip start time.",
  );
  const end = requiredSeconds(
    body.end_seconds,
    "Choose a valid clip end time.",
  );
  if (typeof body.save_to_profile !== "boolean") {
    throw new HttpError("Choose whether to save or download the clip.", 400);
  }
  const saveToProfile = body.save_to_profile;
  const requestedTitle = normalizedString(body.title);
  if (
    saveToProfile &&
    (!requestedTitle || requestedTitle.length < 2 || requestedTitle.length > 80)
  ) {
    throw new HttpError("Clip title must be between 2 and 80 characters.", 400);
  }
  if (requestedTitle && requestedTitle.length > 80) {
    throw new HttpError("Clip title must be 80 characters or fewer.", 400);
  }

  const source = await readyMatchSource(
    context,
    await loadMatchSource(context, sourceType, matchId),
  );
  const bounds = customClipBounds(start, end, source.durationSeconds);
  const title = requestedTitle || "Field match clip";
  const media = instantMedia(
    context.customerCode,
    source.sourceVideoId,
    bounds.start,
    bounds.end,
    bounds.start + ((bounds.end - bounds.start) / 2),
    title,
  );

  if (!saveToProfile) {
    return json({ media });
  }

  const { data: latest, error: latestError } = await context.admin
    .from("profile_highlights")
    .select("sort_order")
    .eq("profile_id", context.userId)
    .order("sort_order", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (latestError) throw latestError;
  const latestSortOrder = typeof latest?.sort_order === "number"
    ? latest.sort_order
    : Number(latest?.sort_order ?? -1);
  const sortOrder = Number.isFinite(latestSortOrder) ? latestSortOrder + 1 : 0;

  const { data: inserted, error: insertError } = await context.admin
    .from("profile_highlights")
    .insert({
      profile_id: context.userId,
      title,
      thumbnail_url: media.thumbnail_url,
      video_url: media.video_url,
      duration: media.duration,
      views: 0,
      clan_tag: null,
      sort_order: sortOrder,
      source_type: source.sourceType,
      source_match_id: source.matchId,
      source_event_id: null,
      provider_source_video_id: source.sourceVideoId,
      provider_source_duration_seconds: roundMilliseconds(
        source.durationSeconds,
      ),
      provider_video_id: null,
      provider_request_started_at: new Date().toISOString(),
      clip_start_seconds: bounds.start,
      clip_end_seconds: bounds.end,
      processing_status: "READY",
      processing_error: null,
      download_status: "READY",
      download_url: media.download_url,
    })
    .select(highlightSelect)
    .single();
  if (insertError) throw insertError;
  return json({ highlight: profileHighlightRow(inserted) });
}

async function prepareFullGameDownload(
  context: FunctionContext,
  body: JsonBody,
) {
  const sourceType = requireSourceType(body.source_type);
  const matchId = requireUuid(body.match_id, "Choose a valid match.");
  const source = await readyMatchSource(
    context,
    await loadMatchSource(context, sourceType, matchId),
  );
  let downloads = await cloudflareRequest<CloudflareDownloads>(
    context,
    `/stream/${encodeURIComponent(source.sourceVideoId)}/downloads`,
  );
  if (!downloads.default) {
    downloads = await cloudflareRequest<CloudflareDownloads>(
      context,
      `/stream/${encodeURIComponent(source.sourceVideoId)}/downloads`,
      "POST",
    );
  }
  const result = downloads.default;
  if (!result) {
    return json({ status: "PROCESSING" }, 202);
  }
  const providerStatus = normalizedString(result?.status)?.toLowerCase();
  const providerUrl = normalizedString(result?.url);
  if (providerStatus === "ready" && providerUrl) {
    return json({
      status: "READY",
      download_url: namedDownloadUrl(providerUrl, "Field_full_match"),
    });
  }
  if (providerStatus === "error") {
    return json({
      status: "FAILED",
      error: "Cloudflare could not prepare this match download.",
    });
  }
  if (providerStatus === "inprogress") {
    return json({ status: "PROCESSING" }, 202);
  }
  throw new HttpError("Cloudflare returned an invalid download status.", 502);
}

async function loadGoalSource(
  context: FunctionContext,
  sourceType: "CLAN" | "SOLO",
  matchId: string,
  eventId: string,
): Promise<GoalSource> {
  const source = await loadMatchSource(context, sourceType, matchId);
  const table = sourceType === "CLAN" ? "fixture_events" : "open_queue_events";
  const matchColumn = sourceType === "CLAN" ? "fixture_id" : "game_id";
  const { data: selectedGoal, error: goalError } = await context.admin
    .from(table)
    .select("id,event_type,occurred_at,note")
    .eq("id", eventId)
    .eq(matchColumn, matchId)
    .eq("event_type", "GOAL")
    .maybeSingle();
  if (goalError) throw goalError;
  const occurredAt = normalizedString(selectedGoal?.occurred_at);
  if (
    !occurredAt ||
    normalizedString(selectedGoal?.event_type)?.toUpperCase() !== "GOAL" ||
    normalizedString(selectedGoal?.note)?.toLowerCase() === "admin correction"
  ) {
    throw new HttpError("That goal is not available in this replay.", 404);
  }

  const { data: allGoals, error: allGoalsError } = await context.admin
    .from(table)
    .select("id,occurred_at,note")
    .eq(matchColumn, matchId)
    .eq("event_type", "GOAL")
    .order("occurred_at", { ascending: true })
    .order("id", { ascending: true });
  if (allGoalsError) throw allGoalsError;
  const goalTimestamps = (allGoals ?? [])
    .filter((row) =>
      normalizedString(row.note)?.toLowerCase() !== "admin correction"
    )
    .map((row) => normalizedString(row.occurred_at))
    .filter((value): value is string => value != null);

  return {
    ...source,
    goalOccurredAt: occurredAt,
    goalTimestamps,
  };
}

async function loadMatchSource(
  context: FunctionContext,
  sourceType: "CLAN" | "SOLO",
  matchId: string,
): Promise<MatchSource> {
  const matchTable = sourceType === "CLAN" ? "fixtures" : "open_queue_games";
  const broadcastTable = sourceType === "CLAN"
    ? "fixture_broadcasts"
    : "open_queue_broadcasts";
  const matchColumn = sourceType === "CLAN" ? "fixture_id" : "game_id";
  const { data: match, error: matchError } = await context.admin
    .from(matchTable)
    .select("id,status")
    .eq("id", matchId)
    .maybeSingle();
  if (matchError) throw matchError;
  if (normalizedString(match?.status)?.toUpperCase() !== "FINAL") {
    throw new HttpError("Clips are available after the match is final.", 409);
  }

  const { data: broadcast, error: broadcastError } = await context.admin
    .from(broadcastTable)
    .select(
      `${matchColumn},status,active_video_id,stream_started_at,stream_stopped_at`,
    )
    .eq(matchColumn, matchId)
    .maybeSingle();
  if (broadcastError) throw broadcastError;
  const sourceVideoId = normalizedString(broadcast?.active_video_id);
  const streamStartedAt = normalizedString(broadcast?.stream_started_at);
  if (
    normalizedString(broadcast?.status)?.toUpperCase() !== "REPLAY_READY" ||
    !sourceVideoId ||
    !streamStartedAt
  ) {
    throw new HttpError("The match recording is not ready yet.", 409);
  }
  return {
    sourceType,
    matchId,
    sourceVideoId,
    streamStartedAt,
    streamStoppedAt: normalizedString(broadcast?.stream_stopped_at),
  };
}

async function readyMatchSource(
  context: FunctionContext,
  source: MatchSource,
): Promise<ReadyMatchSource> {
  const sourceVideo = await cloudflareRequest<CloudflareVideo>(
    context,
    `/stream/${encodeURIComponent(source.sourceVideoId)}`,
  );
  const durationSeconds = positiveNumber(sourceVideo.duration);
  if (!durationSeconds) {
    throw new HttpError("The match recording duration is not ready yet.", 409);
  }
  const sourceState = normalizedString(sourceVideo.status?.state)
    ?.toLowerCase();
  if (sourceVideo.readyToStream !== true && sourceState !== "ready") {
    throw new HttpError("The match recording is still processing.", 409);
  }
  return { ...source, durationSeconds };
}

function replayClipBounds({
  sourceDuration,
  goalOccurredAt,
  goalTimestamps,
  streamStartedAt,
  streamStoppedAt,
}: {
  sourceDuration: number;
  goalOccurredAt: string;
  goalTimestamps: string[];
  streamStartedAt: string;
  streamStoppedAt: string | null;
}) {
  const startedOrigin = timestampSeconds(
    streamStartedAt,
    "The recording start time is invalid.",
  );
  const goal = timestampSeconds(
    goalOccurredAt,
    "The goal timestamp is invalid.",
  );
  const goals = goalTimestamps.map((value) =>
    timestampSeconds(value, "A goal timestamp is invalid.")
  );

  let replayOrigin = startedOrigin;
  if (streamStoppedAt && sourceDuration > 0) {
    const stoppedOrigin = timestampSeconds(
      streamStoppedAt,
      "The recording stop time is invalid.",
    ) - sourceDuration;
    const startedUsable = usableHighlightCount(
      goals,
      startedOrigin,
      sourceDuration,
    );
    const stoppedUsable = usableHighlightCount(
      goals,
      stoppedOrigin,
      sourceDuration,
    );
    // Match the app: on a tie, the stop-derived recording boundary wins.
    replayOrigin = startedUsable > stoppedUsable
      ? startedOrigin
      : stoppedOrigin;
  }

  const goalOffset = goal - replayOrigin;
  const start = Math.max(0, goalOffset - leadInSeconds);
  const end = Math.min(sourceDuration, goalOffset + followThroughSeconds);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) {
    throw new HttpError(
      "That goal falls outside the available match recording.",
      409,
    );
  }
  return { start, end, goal: goalOffset };
}

function customClipBounds(
  requestedStart: number,
  requestedEnd: number,
  sourceDuration: number,
) {
  const start = roundMilliseconds(requestedStart);
  const end = roundMilliseconds(requestedEnd);
  if (start < 0 || end <= start) {
    throw new HttpError("The clip end must be after its start.", 400);
  }
  if ((end - start) > 60) {
    throw new HttpError("A custom clip can be at most 60 seconds.", 400);
  }
  const roundedSourceDuration = roundMilliseconds(sourceDuration);
  if (start >= roundedSourceDuration || end > roundedSourceDuration) {
    throw new HttpError(
      "The selected clip falls outside the match recording.",
      400,
    );
  }
  return {
    start,
    end,
  };
}

function usableHighlightCount(
  goalTimestamps: number[],
  replayOrigin: number,
  replayDuration: number,
) {
  let count = 0;
  for (const goalTimestamp of goalTimestamps) {
    const offset = goalTimestamp - replayOrigin;
    const end = offset + followThroughSeconds;
    if (end <= 0) continue;
    const start = Math.max(0, offset - leadInSeconds);
    if (start < replayDuration) count += 1;
  }
  return count;
}

async function loadOwnedHighlight(
  context: FunctionContext,
  highlightId: string,
) {
  const { data, error } = await context.admin
    .from("profile_highlights")
    .select(highlightSelect)
    .eq("id", highlightId)
    .eq("profile_id", context.userId)
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new HttpError("Goal clip not found.", 404);
  return profileHighlightRow(data);
}

async function updateOwnedHighlight(
  context: FunctionContext,
  highlightId: string,
  values: Record<string, unknown>,
) {
  const { data, error } = await context.admin
    .from("profile_highlights")
    .update(values)
    .eq("id", highlightId)
    .eq("profile_id", context.userId)
    .select(highlightSelect)
    .single();
  if (error) throw error;
  return profileHighlightRow(data);
}

async function cloudflareRequest<T>(
  context: FunctionContext,
  path: string,
  method = "GET",
  body?: Record<string, unknown>,
): Promise<T> {
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${context.accountId}${path}`,
    {
      method,
      headers: {
        Authorization: `Bearer ${context.apiToken}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    },
  );
  const raw = await response.text();
  let payload: CloudflareEnvelope<T>;
  try {
    payload = raw ? JSON.parse(raw) as CloudflareEnvelope<T> : {};
  } catch {
    throw new HttpError("Cloudflare returned an invalid response.", 502);
  }
  if (!response.ok || payload.success === false || payload.result == null) {
    const providerMessage = payload.errors?.map((entry) =>
      normalizedString(entry.message)
    ).filter((value): value is string => value != null).join(" ");
    throw new HttpError(
      providerMessage || `Cloudflare request failed (${response.status}).`,
      response.status >= 500 ? 502 : 409,
    );
  }
  return payload.result;
}

function goalClipRequest(value: unknown): GoalClipRequest {
  const row = objectValue(value);
  const highlight = profileHighlightRow(row.highlight);
  const sourceVideoId = normalizedString(row.source_video_id);
  const goalOccurredAt = normalizedString(row.goal_occurred_at);
  const streamStartedAt = normalizedString(row.stream_started_at);
  if (!sourceVideoId || !goalOccurredAt || !streamStartedAt) {
    throw new Error("The goal clip request is incomplete.");
  }
  return {
    highlight,
    source_video_id: sourceVideoId,
    goal_occurred_at: goalOccurredAt,
    goal_timestamps: row.goal_timestamps,
    stream_started_at: streamStartedAt,
    stream_stopped_at: normalizedString(row.stream_stopped_at),
  };
}

function profileHighlightRow(value: unknown): ProfileHighlightRow {
  const row = objectValue(value);
  const id = normalizedString(row.id);
  const profileId = normalizedString(row.profile_id);
  const title = normalizedString(row.title);
  if (!id || !profileId || !title) {
    throw new Error("The goal clip response is invalid.");
  }
  return row as unknown as ProfileHighlightRow;
}

function objectValue(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Expected an object response.");
  }
  return value as Record<string, unknown>;
}

function timestampList(value: unknown) {
  if (!Array.isArray(value)) return [];
  return value.map(normalizedString).filter((item): item is string =>
    item != null
  );
}

function timestampSeconds(value: string, message: string) {
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) throw new HttpError(message, 409);
  return milliseconds / 1000;
}

function positiveNumber(value: unknown) {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function liveInstantClipUrls(
  customerCode: string,
  videoId: string,
  startSeconds: number,
  durationSeconds: number,
  thumbnailSeconds: number,
  title: string,
) {
  const base =
    `https://customer-${customerCode}.cloudflarestream.com/${videoId}`;
  const time = `${roundMilliseconds(startSeconds)}s`;
  const duration = `${roundMilliseconds(durationSeconds)}s`;
  const clipQuery = new URLSearchParams({ time, duration }).toString();
  const fileName = `${safeProviderName(title).replaceAll(" ", "_")}.mp4`;
  const downloadQuery = new URLSearchParams({
    time,
    duration,
    filename: fileName,
  }).toString();
  const thumbnailQuery = new URLSearchParams({
    time: `${roundMilliseconds(thumbnailSeconds)}s`,
  }).toString();
  return {
    playback: `${base}/manifest/clip.m3u8?${clipQuery}`,
    download: `${base}/clip.mp4?${downloadQuery}`,
    thumbnail: `${base}/thumbnails/thumbnail.jpg?${thumbnailQuery}`,
  };
}

function instantMedia(
  customerCode: string,
  videoId: string,
  startSeconds: number,
  endSeconds: number,
  thumbnailSeconds: number,
  title: string,
) {
  const start = roundMilliseconds(startSeconds);
  const end = roundMilliseconds(endSeconds);
  const durationSeconds = roundMilliseconds(end - start);
  const urls = liveInstantClipUrls(
    customerCode,
    videoId,
    start,
    durationSeconds,
    thumbnailSeconds,
    title,
  );
  return {
    video_url: urls.playback,
    download_url: urls.download,
    thumbnail_url: urls.thumbnail,
    duration: formattedDuration(durationSeconds),
    duration_seconds: durationSeconds,
    start_seconds: start,
    end_seconds: end,
  };
}

function namedDownloadUrl(url: string, fileName: string) {
  try {
    const parsed = new URL(url);
    parsed.searchParams.set("filename", safeProviderName(fileName));
    return parsed.toString();
  } catch {
    throw new HttpError("Cloudflare returned an invalid download URL.", 502);
  }
}

function normalizedCustomerCode(value: unknown) {
  const raw = normalizedString(value);
  if (!raw) return null;
  const withoutProtocol = raw.replace(/^https?:\/\//i, "");
  const customerCode = withoutProtocol
    .split("/")[0]
    .replace(/\.$/, "")
    .replace(/^customer-/i, "")
    .replace(/\.cloudflarestream\.com$/i, "");
  return /^[a-z0-9-]+$/i.test(customerCode) ? customerCode : null;
}

function formattedDuration(seconds: number) {
  const rounded = Math.max(0, Math.round(seconds));
  const minutes = Math.floor(rounded / 60);
  return `${minutes}:${String(rounded % 60).padStart(2, "0")}`;
}

function safeProviderName(title: string) {
  return title.replace(/[^a-z0-9 _-]/gi, "").trim().slice(0, 80) ||
    "Field goal clip";
}

function roundMilliseconds(value: number) {
  return Math.round(value * 1000) / 1000;
}

function clamp(value: number, minimum: number, maximum: number) {
  return Math.min(maximum, Math.max(minimum, value));
}

function requireUuid(value: unknown, message: string) {
  const string = normalizedString(value);
  if (!string || !isUuid(string)) throw new HttpError(message, 400);
  return string;
}

function requireSourceType(value: unknown): "CLAN" | "SOLO" {
  const sourceType = normalizedString(value)?.toUpperCase();
  if (sourceType !== "CLAN" && sourceType !== "SOLO") {
    throw new HttpError("Choose a valid match type.", 400);
  }
  return sourceType;
}

function requiredSeconds(value: unknown, message: string) {
  const seconds = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(seconds)) throw new HttpError(message, 400);
  return seconds;
}

function isUuid(value: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function normalizedString(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function readBearerToken(value: string | null) {
  const match = value?.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || null;
}

function errorMessage(error: unknown) {
  if (error instanceof Error && error.message.trim()) return error.message;
  if (
    error &&
    typeof error === "object" &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message;
  }
  return "Could not process this match clip.";
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Cache-Control": "no-store",
      "Content-Type": "application/json",
    },
  });
}

const highlightSelect = `
  id,
  profile_id,
  title,
  thumbnail_url,
  video_url,
  duration,
  views,
  clan_tag,
  sort_order,
  source_type,
  source_match_id,
  source_event_id,
  provider_source_video_id,
  provider_source_duration_seconds,
  provider_video_id,
  provider_request_started_at,
  clip_start_seconds,
  clip_end_seconds,
  processing_status,
  processing_error,
  download_status,
  download_url,
  created_at,
  updated_at
`;
