import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

// deno-lint-ignore no-explicit-any
type SupabaseAnyClient = ReturnType<typeof createClient<any, "public", any>>;

const url = requireEnv("SUPABASE_URL");
const publishableKey = requireEnv("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
}) as SupabaseAnyClient;

const createdUserIds: string[] = [];
let highlightId: string | null = null;
let verificationError: unknown;
try {
  await verifyProfileClipPrivacy();
} catch (error) {
  verificationError = error;
}

const cleanupErrors: unknown[] = [];
if (highlightId) {
  const { error } = await admin.from("profile_highlights").delete().eq(
    "id",
    highlightId,
  );
  if (error) cleanupErrors.push(error);
}
for (const userId of createdUserIds.reverse()) {
  const { error } = await admin.auth.admin.deleteUser(userId);
  if (error) cleanupErrors.push(error);
}
if (verificationError) throw verificationError;
if (cleanupErrors.length > 0) throw cleanupErrors[0];

async function verifyProfileClipPrivacy() {
  const password = `Clip!${crypto.randomUUID()}`;
  const owner = await createSignedInUser("owner", password);
  const viewer = await createSignedInUser("viewer", password);

  const { data: inserted, error: insertError } = await admin
    .from("profile_highlights")
    .insert({
      profile_id: owner.userId,
      title: "Privacy verification clip",
      thumbnail_url: null,
      video_url: null,
      duration: "0:10",
      views: 0,
      clan_tag: null,
      sort_order: 0,
      source_type: "CLAN",
      source_match_id: crypto.randomUUID(),
      source_event_id: null,
      processing_status: "PROCESSING",
      download_status: "NOT_REQUESTED",
    })
    .select("id,is_public,views,processing_status")
    .single();
  if (insertError) throw insertError;
  highlightId = requiredString(inserted.id);
  assert(inserted.is_public === true, "A legacy-style clip was not public.");

  assert(
    (await visibleHighlight(viewer.client, highlightId))?.is_public === true,
    "A public clip was hidden from an authenticated viewer.",
  );

  const publicPendingStatus = await invoke(viewer.client, {
    action: "status",
    highlight_id: highlightId,
  });
  assert(
    publicPendingStatus.status === 202 &&
      objectValue(publicPendingStatus.body.highlight).processing_status ===
        "PROCESSING",
    "A viewer could not poll a public processing clip.",
  );
  const { data: stillPending, error: stillPendingError } = await admin
    .from("profile_highlights")
    .select("processing_status,download_status")
    .eq("id", highlightId)
    .single();
  if (stillPendingError) throw stillPendingError;
  assert(
    stillPending.processing_status === "PROCESSING" &&
      stillPending.download_status === "NOT_REQUESTED",
    "A non-owner status request mutated the processing clip.",
  );

  const { error: readyError } = await admin
    .from("profile_highlights")
    .update({
      thumbnail_url: "https://example.com/privacy-verification.jpg",
      video_url: "https://example.com/privacy-verification.m3u8",
      processing_status: "READY",
      processing_error: null,
      download_status: "READY",
      download_url: "https://example.com/privacy-verification.mp4",
    })
    .eq("id", highlightId);
  if (readyError) throw readyError;
  const publicReadyStatus = await invoke(viewer.client, {
    action: "status",
    highlight_id: highlightId,
  });
  const publicReadyHighlight = objectValue(
    publicReadyStatus.body.highlight,
  );
  assert(
    publicReadyStatus.status === 200 &&
      publicReadyHighlight.processing_status === "READY" &&
      publicReadyHighlight.download_url ===
        "https://example.com/privacy-verification.mp4",
    "A viewer could not retrieve ready metadata for a public clip.",
  );

  const rejectedUpdate = await invoke(viewer.client, {
    action: "update_visibility",
    highlight_id: highlightId,
    is_public: false,
  });
  assert(
    rejectedUpdate.status === 404,
    "A non-owner changed another user's clip visibility.",
  );

  const missingVisibility = await invoke(owner.client, {
    action: "update_visibility",
    highlight_id: highlightId,
  });
  assert(
    missingVisibility.status === 400,
    "A visibility update without a boolean was accepted.",
  );

  const privateUpdate = await invoke(owner.client, {
    action: "update_visibility",
    highlight_id: highlightId,
    is_public: false,
  });
  assert(
    privateUpdate.status === 200 &&
      objectValue(privateUpdate.body.highlight).is_public === false,
    "The owner could not make their clip private.",
  );
  assert(
    await visibleHighlight(viewer.client, highlightId) == null,
    "A private clip was visible to another authenticated user.",
  );
  assert(
    (await visibleHighlight(owner.client, highlightId))?.is_public === false,
    "The owner could not read their private clip.",
  );
  const privateViewerStatus = await invoke(viewer.client, {
    action: "status",
    highlight_id: highlightId,
  });
  assert(
    privateViewerStatus.status === 404,
    "A non-owner polled a private clip.",
  );
  const privateOwnerStatus = await invoke(owner.client, {
    action: "status",
    highlight_id: highlightId,
  });
  assert(
    privateOwnerStatus.status === 200 &&
      objectValue(privateOwnerStatus.body.highlight).is_public === false,
    "The owner could not poll their private clip.",
  );

  const { error: privateViewError } = await viewer.client.rpc(
    "record_profile_highlight_view",
    { highlight_id_to_use: highlightId },
  );
  assert(
    privateViewError != null,
    "A non-owner recorded a view against a private clip.",
  );
  const { data: beforeOwnerView, error: beforeOwnerViewError } = await admin
    .from("profile_highlights")
    .select("views")
    .eq("id", highlightId)
    .single();
  if (beforeOwnerViewError) throw beforeOwnerViewError;

  const { data: ownerViews, error: ownerViewError } = await owner.client.rpc(
    "record_profile_highlight_view",
    { highlight_id_to_use: highlightId },
  );
  if (ownerViewError) throw ownerViewError;
  assert(
    ownerViews === beforeOwnerView.views + 1,
    "The owner could not record playback of their private clip.",
  );

  const { error: directUpdateError } = await owner.client
    .from("profile_highlights")
    .update({ is_public: true })
    .eq("id", highlightId);
  assert(
    directUpdateError != null,
    "A direct authenticated table update bypassed the clip API.",
  );
  const { error: directDeleteError } = await owner.client
    .from("profile_highlights")
    .delete()
    .eq("id", highlightId);
  assert(
    directDeleteError != null,
    "A direct authenticated table delete bypassed the clip API.",
  );

  const publicUpdate = await invoke(owner.client, {
    action: "update_visibility",
    highlight_id: highlightId,
    is_public: true,
  });
  assert(
    publicUpdate.status === 200 &&
      objectValue(publicUpdate.body.highlight).is_public === true &&
      (await visibleHighlight(viewer.client, highlightId)) != null,
    "The owner could not make their clip public again.",
  );

  const rejectedDelete = await invoke(viewer.client, {
    action: "delete",
    highlight_id: highlightId,
  });
  assert(
    rejectedDelete.status === 404 &&
      (await visibleHighlight(owner.client, highlightId)) != null,
    "A non-owner deleted another user's clip.",
  );

  const ownerDelete = await invoke(owner.client, {
    action: "delete",
    highlight_id: highlightId,
  });
  assert(
    ownerDelete.status === 200 &&
      ownerDelete.body.deleted === true &&
      ownerDelete.body.highlight_id === highlightId &&
      (await visibleHighlight(owner.client, highlightId)) == null,
    "The owner could not delete their clip.",
  );
  highlightId = null;

  console.log("Profile clip privacy verified:");
  console.log("- new clips default to public");
  console.log(
    "- viewers can poll public processing clips without mutating them",
  );
  console.log("- public viewers receive ready playback and download metadata");
  console.log("- private clips are readable and playable only by their owner");
  console.log("- visibility changes and deletes reject non-owners");
  console.log("- direct authenticated table mutations are revoked");
  console.log("- owner delete succeeded; all verification data was cleaned up");
}

async function createSignedInUser(label: string, password: string) {
  const suffix = randomDigits();
  const phone = `+973${suffix}`;
  const { data, error } = await admin.auth.admin.createUser({
    phone,
    password,
    phone_confirm: true,
    user_metadata: {
      display_name: `Clip Privacy ${label}`,
      date_of_birth: "2000-01-01",
    },
  });
  if (error) throw error;
  const userId = data.user.id;
  createdUserIds.push(userId);

  const { error: profileError } = await admin.from("profiles").upsert({
    id: userId,
    phone,
    username: `cp_${label}_${suffix}`,
    display_name: `Clip Privacy ${label}`,
    date_of_birth: "2000-01-01",
  });
  if (profileError) throw profileError;

  const client = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  }) as SupabaseAnyClient;
  const { error: signInError } = await client.auth.signInWithPassword({
    phone,
    password,
  });
  if (signInError) throw signInError;
  return { client, userId };
}

async function visibleHighlight(
  client: SupabaseAnyClient,
  id: string,
) {
  const { data, error } = await client
    .from("profile_highlights")
    .select("id,is_public,views")
    .eq("id", id)
    .maybeSingle();
  if (error) throw error;
  return data as { id: string; is_public: boolean; views: number } | null;
}

async function invoke(
  client: SupabaseAnyClient,
  body: Record<string, unknown>,
) {
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

function randomDigits() {
  return String(Math.floor(10_000_000 + Math.random() * 89_999_999));
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
