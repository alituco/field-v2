import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type SourceType = "CLAN" | "SOLO";
// deno-lint-ignore no-explicit-any
type SupabaseAnyClient = ReturnType<typeof createClient<any, "public", any>>;

type FunctionResult = {
  status: number;
  body: Record<string, unknown>;
};

const url = requireEnv("SUPABASE_URL");
const publishableKey = requireEnv("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = requireEnv("DEV_SEED_PASSWORD");
const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
}) as SupabaseAnyClient;
const cleanupHighlightIds: string[] = [];
let viewerId: string | null = null;

let verificationError: unknown;
try {
  await verifyProfileMatchClips();
} catch (error) {
  verificationError = error;
}
const cleanupErrors: unknown[] = [];
if (cleanupHighlightIds.length > 0) {
  const { error } = await admin.from("profile_highlights").delete().in(
    "id",
    cleanupHighlightIds,
  );
  if (error) cleanupErrors.push(error);
}
if (viewerId) {
  const { error } = await admin.auth.admin.deleteUser(viewerId);
  if (error) cleanupErrors.push(error);
}
if (verificationError) throw verificationError;
if (cleanupErrors.length > 0) throw cleanupErrors[0];

async function verifyProfileMatchClips() {
  const source = await findRecordedAssistedGoal();
  const assistant = await signedInProfileClient(source.assistProfileId);
  const scorer = await signedInProfileClient(source.scorerProfileId);
  const viewer = await createViewer();

  const existing = await highlightsForGoal(source);
  assert(existing.length === 0, "Choose an assisted goal with no saved clips.");

  const assistantSave = await invoke(assistant, {
    action: "create",
    source_type: source.sourceType,
    match_id: source.matchId,
    event_id: source.eventId,
    title: "Assist verification clip",
  });
  assert(assistantSave.status === 200, "The assister could not save the goal.");
  const assistantHighlight = objectValue(assistantSave.body.highlight);
  assert(
    assistantHighlight.profile_id === source.assistProfileId &&
      assistantHighlight.is_public === true,
    "The assist clip was saved to the wrong profile.",
  );
  const assistantHighlightId = requiredString(assistantHighlight.id);
  cleanupHighlightIds.push(assistantHighlightId);

  const scorerSave = await invoke(scorer, {
    action: "create",
    source_type: source.sourceType,
    match_id: source.matchId,
    event_id: source.eventId,
    title: "Scorer verification clip",
  });
  assert(
    scorerSave.status === 200,
    "The scorer could not independently save the assisted goal.",
  );
  const scorerHighlight = objectValue(scorerSave.body.highlight);
  assert(
    scorerHighlight.profile_id === source.scorerProfileId,
    "The scorer clip was saved to the wrong profile.",
  );
  cleanupHighlightIds.push(requiredString(scorerHighlight.id));

  assert(
    (await visibleHighlight(scorer, assistantHighlightId))?.is_public === true,
    "A public clip was hidden from another authenticated user.",
  );

  const rejectedVisibilityUpdate = await invoke(scorer, {
    action: "update_visibility",
    highlight_id: assistantHighlightId,
    is_public: false,
  });
  assert(
    rejectedVisibilityUpdate.status === 404,
    "A non-owner changed another player's clip visibility.",
  );

  const privateUpdate = await invoke(assistant, {
    action: "update_visibility",
    highlight_id: assistantHighlightId,
    is_public: false,
  });
  assert(
    privateUpdate.status === 200 &&
      objectValue(privateUpdate.body.highlight).is_public === false,
    "The owner could not make their clip private.",
  );
  assert(
    await visibleHighlight(scorer, assistantHighlightId) == null,
    "A private clip was visible to another authenticated user.",
  );
  assert(
    (await visibleHighlight(assistant, assistantHighlightId))?.is_public ===
      false,
    "The owner could not read their private clip.",
  );

  const { error: privateViewError } = await scorer.rpc(
    "record_profile_highlight_view",
    { highlight_id_to_use: assistantHighlightId },
  );
  assert(
    privateViewError != null,
    "A non-owner recorded a view against a private clip.",
  );
  const { error: ownerViewError } = await assistant.rpc(
    "record_profile_highlight_view",
    { highlight_id_to_use: assistantHighlightId },
  );
  assert(
    ownerViewError == null,
    "The owner could not play their private clip.",
  );

  const publicUpdate = await invoke(assistant, {
    action: "update_visibility",
    highlight_id: assistantHighlightId,
    is_public: true,
  });
  assert(
    publicUpdate.status === 200 &&
      objectValue(publicUpdate.body.highlight).is_public === true &&
      (await visibleHighlight(scorer, assistantHighlightId)) != null,
    "The owner could not make their clip public again.",
  );

  const goalRowsBeforeDownload = await highlightsForGoal(source);
  const goalDownload = await invoke(viewer, {
    action: "goal_download",
    source_type: source.sourceType,
    match_id: source.matchId,
    event_id: source.eventId,
  });
  assert(
    goalDownload.status === 200,
    "An arbitrary viewer cannot download a goal.",
  );
  assertMedia(objectValue(goalDownload.body.media), 0, 60);
  const goalRowsAfterDownload = await highlightsForGoal(source);
  assert(
    goalRowsAfterDownload.length === goalRowsBeforeDownload.length,
    "Downloading a goal unexpectedly saved it to a profile.",
  );

  const customDownload = await invoke(viewer, {
    action: "custom_clip",
    source_type: source.sourceType,
    match_id: source.matchId,
    start_seconds: 0,
    end_seconds: 60,
    save_to_profile: false,
  });
  assert(customDownload.status === 200, "A valid 60-second clip was rejected.");
  const customMedia = objectValue(customDownload.body.media);
  assertMedia(customMedia, 60, 60);

  const tooLong = await invoke(viewer, {
    action: "custom_clip",
    source_type: source.sourceType,
    match_id: source.matchId,
    start_seconds: 0,
    end_seconds: 60.001,
    save_to_profile: false,
  });
  assert(tooLong.status === 400, "A clip longer than 60 seconds was accepted.");

  const customSave = await invoke(viewer, {
    action: "custom_clip",
    source_type: source.sourceType,
    match_id: source.matchId,
    start_seconds: 5,
    end_seconds: 20,
    title: "Custom verification clip",
    save_to_profile: true,
  });
  assert(
    customSave.status === 200,
    "A valid custom profile clip was rejected.",
  );
  const customHighlight = objectValue(customSave.body.highlight);
  assert(
    customHighlight.profile_id === viewerId &&
      customHighlight.source_event_id == null &&
      customHighlight.clip_start_seconds === 5 &&
      customHighlight.clip_end_seconds === 20,
    "The custom profile clip metadata is incorrect.",
  );
  cleanupHighlightIds.push(requiredString(customHighlight.id));

  const fullGame = await invoke(viewer, {
    action: "full_game_download",
    source_type: source.sourceType,
    match_id: source.matchId,
  });
  const fullGameStatus = requiredString(fullGame.body.status);
  assert(
    fullGame.status === 200 || fullGame.status === 202,
    "The full-game download action returned an HTTP error.",
  );
  assert(
    ["PROCESSING", "READY", "FAILED"].includes(fullGameStatus),
    "The full-game download status is not normalized.",
  );
  if (fullGameStatus === "READY") {
    assertUrl(fullGame.body.download_url, "Full-game download");
  }

  const rejectedDelete = await invoke(scorer, {
    action: "delete",
    highlight_id: assistantHighlightId,
  });
  assert(
    rejectedDelete.status === 404 &&
      (await visibleHighlight(assistant, assistantHighlightId)) != null,
    "A non-owner deleted another player's clip.",
  );
  const ownerDelete = await invoke(assistant, {
    action: "delete",
    highlight_id: assistantHighlightId,
  });
  assert(
    ownerDelete.status === 200 &&
      ownerDelete.body.deleted === true &&
      ownerDelete.body.highlight_id === assistantHighlightId &&
      (await visibleHighlight(assistant, assistantHighlightId)) == null,
    "The owner could not delete their clip.",
  );
  cleanupHighlightIds.splice(
    cleanupHighlightIds.indexOf(assistantHighlightId),
    1,
  );

  console.log("Profile match clips verified:");
  console.log(
    `- assisted ${source.sourceType.toLowerCase()} goal saved by both credited players`,
  );
  console.log(
    "- arbitrary authenticated viewer downloaded the goal without a profile row",
  );
  console.log(
    "- exact 60-second custom clip accepted; 60.001-second clip rejected",
  );
  console.log("- 15-second custom clip saved with trusted source bounds");
  console.log(`- full-game download returned ${fullGameStatus}`);
  console.log("- owner-only public/private and delete actions enforced");
  console.log(
    "- private clip reads and view recording restricted to its owner",
  );
}

async function findRecordedAssistedGoal() {
  const { data: broadcasts, error: broadcastError } = await admin
    .from("fixture_broadcasts")
    .select("fixture_id")
    .eq("status", "REPLAY_READY")
    .not("active_video_id", "is", null);
  if (broadcastError) throw broadcastError;
  for (const broadcast of broadcasts ?? []) {
    const { data: fixture, error: fixtureError } = await admin
      .from("fixtures")
      .select("id,status")
      .eq("id", broadcast.fixture_id)
      .eq("status", "FINAL")
      .maybeSingle();
    if (fixtureError) throw fixtureError;
    if (!fixture) continue;
    const candidate = await assistedGoalWithoutSavedProfiles(
      "CLAN",
      fixture.id,
    );
    if (candidate) return candidate;
  }

  const { data: soloBroadcasts, error: soloBroadcastError } = await admin
    .from("open_queue_broadcasts")
    .select("game_id")
    .eq("status", "REPLAY_READY")
    .not("active_video_id", "is", null);
  if (soloBroadcastError) throw soloBroadcastError;
  for (const broadcast of soloBroadcasts ?? []) {
    const { data: game, error: gameError } = await admin
      .from("open_queue_games")
      .select("id,status")
      .eq("id", broadcast.game_id)
      .eq("status", "FINAL")
      .maybeSingle();
    if (gameError) throw gameError;
    if (!game) continue;
    const candidate = await assistedGoalWithoutSavedProfiles("SOLO", game.id);
    if (candidate) return candidate;
  }
  throw new Error(
    "A final recorded match with an unsaved assisted goal is required.",
  );
}

async function assistedGoalWithoutSavedProfiles(
  sourceType: SourceType,
  matchId: string,
) {
  const table = sourceType === "CLAN" ? "fixture_events" : "open_queue_events";
  const matchColumn = sourceType === "CLAN" ? "fixture_id" : "game_id";
  const { data: goals, error } = await admin
    .from(table)
    .select("id,profile_id,assist_profile_id")
    .eq(matchColumn, matchId)
    .eq("event_type", "GOAL")
    .not("assist_profile_id", "is", null);
  if (error) throw error;
  for (const goal of goals ?? []) {
    const source = {
      sourceType,
      matchId,
      eventId: requiredString(goal.id),
      scorerProfileId: requiredString(goal.profile_id),
      assistProfileId: requiredString(goal.assist_profile_id),
    };
    if ((await highlightsForGoal(source)).length === 0) return source;
  }
  return null;
}

async function highlightsForGoal(source: {
  sourceType: SourceType;
  eventId: string;
}) {
  const { data, error } = await admin
    .from("profile_highlights")
    .select("id,profile_id")
    .eq("source_type", source.sourceType)
    .eq("source_event_id", source.eventId);
  if (error) throw error;
  return data ?? [];
}

async function signedInProfileClient(profileId: string) {
  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("phone")
    .eq("id", profileId)
    .single();
  if (profileError) throw profileError;
  const client = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  }) as SupabaseAnyClient;
  const { error } = await client.auth.signInWithPassword({
    phone: requiredString(profile.phone),
    password,
  });
  if (error) throw error;
  return client;
}

async function createViewer() {
  const digits = String(Math.floor(10_000_000 + Math.random() * 89_999_999));
  const phone = `+973${digits}`;
  const { data, error } = await admin.auth.admin.createUser({
    phone,
    password,
    phone_confirm: true,
    user_metadata: {
      display_name: "Match Clip Verifier",
      date_of_birth: "2000-01-01",
    },
  });
  if (error) throw error;
  viewerId = data.user.id;
  const { error: profileError } = await admin.from("profiles").upsert({
    id: viewerId,
    phone,
    username: `clip_verify_${digits}`,
    display_name: "Match Clip Verifier",
    date_of_birth: "2000-01-01",
  });
  if (profileError) throw profileError;
  return await signedInProfileClient(viewerId);
}

async function invoke(
  client: SupabaseAnyClient,
  body: Record<string, unknown>,
): Promise<FunctionResult> {
  const { data: sessionData, error: sessionError } = await client.auth
    .getSession();
  if (sessionError) throw sessionError;
  const token = sessionData.session?.access_token;
  if (!token) throw new Error("The verification client has no access token.");
  const response = await fetch(`${url}/functions/v1/profile-goal-clip`, {
    method: "POST",
    headers: {
      apikey: publishableKey,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const value = await response.json();
  return { status: response.status, body: objectValue(value) };
}

async function visibleHighlight(
  client: SupabaseAnyClient,
  highlightId: string,
) {
  const { data, error } = await client
    .from("profile_highlights")
    .select("id,is_public")
    .eq("id", highlightId)
    .maybeSingle();
  if (error) throw error;
  return data as { id: string; is_public: boolean } | null;
}

function assertMedia(
  media: Record<string, unknown>,
  expectedDuration: number,
  maximumDuration: number,
) {
  assertUrl(media.video_url, "Clip video");
  assertUrl(media.download_url, "Clip download");
  assertUrl(media.thumbnail_url, "Clip thumbnail");
  const duration = Number(media.duration_seconds);
  assert(
    Number.isFinite(duration) && duration > expectedDuration - 0.001 &&
      duration <= maximumDuration,
    "The clip duration is outside its expected range.",
  );
}

function assertUrl(value: unknown, label: string) {
  const url = requiredString(value);
  assert(/^https:\/\//.test(url), `${label} URL is invalid.`);
}

function objectValue(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Expected an object, received ${JSON.stringify(value)}.`);
  }
  return value as Record<string, unknown>;
}

function requiredString(value: unknown) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error("Expected a non-empty string.");
  }
  return value;
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
