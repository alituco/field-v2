import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type DetailRow = {
  id: string;
  status: string;
  white_score: number | null;
  black_score: number | null;
  events: Array<Record<string, unknown>>;
  scorers: Array<Record<string, unknown>>;
};

type HistoryRow = {
  match_id: string;
  match_type: "CLAN" | "SOLO";
  home_score: number;
  away_score: number;
  player_side: string;
};

type CareerRow = {
  tag: string;
  apps: number;
  goals: number;
  is_current: boolean;
};

const url = requireEnv("SUPABASE_URL");
const publishableKey = requireEnv("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = requireEnv("DEV_SEED_PASSWORD");
const verifierPhone = `+97337${
  String(Math.floor(100000 + Math.random() * 900000))
}`;

const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const authenticated = createClient(url, publishableKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const anonymous = createClient(url, publishableKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const { data: verifier, error: createError } = await admin.auth.admin
  .createUser(
    {
      phone: verifierPhone,
      password,
      phone_confirm: true,
      user_metadata: { display_name: "Solo Match System Verifier" },
    },
  );
if (createError) throw createError;

try {
  await verifySystem();
} finally {
  const { error } = await admin.auth.admin.deleteUser(verifier.user.id);
  if (error) throw error;
}

async function verifySystem() {
  const { error: signInError } = await authenticated.auth.signInWithPassword({
    phone: verifierPhone,
    password,
  });
  if (signInError) throw signInError;

  const [{ data: finalGames, error: gameError }, {
    data: assignments,
    error: assignmentError,
  }, { count: gameCount, error: gameCountError }] = await Promise.all([
    admin
      .from("open_queue_games")
      .select("id,status,white_score,black_score")
      .eq("status", "FINAL")
      .order("starts_at")
      .limit(1),
    admin.from("open_queue_referee_assignments").select("game_id,referee_id"),
    admin
      .from("open_queue_games")
      .select("id", { count: "exact", head: true })
      .neq("status", "CANCELLED"),
  ]);
  if (gameError) throw gameError;
  if (assignmentError) throw assignmentError;
  if (gameCountError) throw gameCountError;
  const finalGame = finalGames?.[0];
  assert(finalGame, "A final solo game is required for verification.");
  assert(
    assignments?.length === gameCount,
    "Every active solo game must have a referee assignment in seeded data.",
  );

  const [detailResult, anonymousDetail] = await Promise.all([
    authenticated.rpc("get_open_queue_match_detail", {
      game_id_to_use: finalGame.id,
    }),
    anonymous.rpc("get_open_queue_match_detail", {
      game_id_to_use: finalGame.id,
    }),
  ]);
  if (detailResult.error) throw detailResult.error;
  assert(
    anonymousDetail.error != null,
    "Anonymous users must not be able to load solo match details.",
  );
  const detail = firstObject(detailResult.data) as DetailRow;
  assert(detail.id === finalGame.id, "The detail RPC returned the wrong game.");
  assert(detail.status === "FINAL", "The detail RPC lost final status.");
  assert(
    detail.scorers.length ===
      Number(finalGame.white_score) + Number(finalGame.black_score),
    "Solo scorer rows do not match the scoreline.",
  );
  const eventTypes = new Set(
    detail.events.map((event) => String(event.event_type)),
  );
  assert(eventTypes.has("MATCH_STARTED"), "Solo timeline has no kickoff.");
  assert(eventTypes.has("MATCH_ENDED"), "Solo timeline has no final whistle.");
  assert(
    detail.events
      .filter((event) => event.event_type === "GOAL")
      .every((event) => {
        const value = event.occurred_at;
        return typeof value === "string" && Number.isFinite(Date.parse(value));
      }),
    "Every solo goal needs a recording-aligned occurred_at timestamp.",
  );

  const profileId = await findProfileWithBothMatchTypes();
  const [historyResult, careerResult, anonymousHistory] = await Promise.all([
    authenticated.rpc("list_profile_previous_games", {
      profile_id_to_use: profileId,
    }),
    authenticated.rpc("list_profile_career_entries", {
      profile_id_to_use: profileId,
    }),
    anonymous.rpc("list_profile_previous_games", {
      profile_id_to_use: profileId,
    }),
  ]);
  if (historyResult.error) throw historyResult.error;
  if (careerResult.error) throw careerResult.error;
  assert(
    anonymousHistory.error != null,
    "Anonymous users must not be able to load profile match history.",
  );
  const history = (historyResult.data ?? []) as HistoryRow[];
  assert(
    history.some((row) => row.match_type === "CLAN"),
    "Career history omitted completed clan games.",
  );
  assert(
    history.some((row) => row.match_type === "SOLO"),
    "Career history omitted completed solo games.",
  );
  assert(
    history.every((row) =>
      row.match_id && Number.isInteger(row.home_score) &&
      Number.isInteger(row.away_score) && row.player_side
    ),
    "Career history returned an incomplete match row.",
  );
  await verifyCurrentCareerTotals(
    profileId,
    (careerResult.data ?? []) as CareerRow[],
  );

  console.log(
    `Verified solo detail with ${detail.scorers.length} goals and ` +
      `${detail.events.length} timeline events; verified ${history.length} ` +
      "Career matches across clan and solo play, plus referee assignments.",
  );
}

async function verifyCurrentCareerTotals(
  profileId: string,
  careers: CareerRow[],
) {
  const current = careers.find((career) => career.is_current);
  assert(current, "A player with recorded clan games has no current career.");

  const { data: clan, error: clanError } = await admin.from("clans")
    .select("id")
    .ilike("tag", current.tag)
    .limit(1)
    .single();
  if (clanError) throw clanError;

  const [{ count: appearanceCount, error: appearanceError }, {
    count: goalCount,
    error: goalError,
  }] = await Promise.all([
    admin.from("fixture_player_appearances")
      .select("fixture_id,fixtures!inner(status)", {
        count: "exact",
        head: true,
      })
      .eq("profile_id", profileId)
      .eq("clan_id", clan.id)
      .eq("played", true)
      .eq("fixtures.status", "FINAL"),
    admin.from("fixture_scorers")
      .select("id,fixtures!inner(status)", { count: "exact", head: true })
      .eq("profile_id", profileId)
      .eq("clan_id", clan.id)
      .eq("fixtures.status", "FINAL"),
  ]);
  if (appearanceError) throw appearanceError;
  if (goalError) throw goalError;
  assert(
    current.apps === (appearanceCount ?? 0),
    "Current career apps do not match played final clan appearances.",
  );
  assert(
    current.goals === (goalCount ?? 0),
    "Current career goals do not match recorded final clan goals.",
  );
}

async function findProfileWithBothMatchTypes() {
  const [{ data: clanRows, error: clanError }, {
    data: soloRows,
    error: soloError,
  }] = await Promise.all([
    admin
      .from("fixture_player_appearances")
      .select("profile_id,fixtures!inner(status)")
      .eq("played", true)
      .eq("fixtures.status", "FINAL"),
    admin
      .from("open_queue_bookings")
      .select("profile_id,open_queue_games!inner(status)")
      .eq("status", "CONFIRMED")
      .eq("open_queue_games.status", "FINAL"),
  ]);
  if (clanError) throw clanError;
  if (soloError) throw soloError;
  const soloProfiles = new Set(
    (soloRows ?? []).map((row) => String(row.profile_id)),
  );
  const profileId = (clanRows ?? [])
    .map((row) => String(row.profile_id))
    .find((id) => soloProfiles.has(id));
  assert(profileId, "No seeded profile has both clan and solo match history.");
  return profileId;
}

function firstObject(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return firstObject(value[0]);
  if (value && typeof value === "object") {
    return value as Record<string, unknown>;
  }
  return {};
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
