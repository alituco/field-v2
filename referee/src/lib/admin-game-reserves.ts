import type { SupabaseClient } from "@supabase/supabase-js";

export type AdminGameReserve = {
  id: string;
  matchKind: "SOLO" | "CLAN";
  profileId: string;
  displayName: string;
  username: string | null;
  avatarUrl: string | null;
  side: "HOME" | "AWAY" | "WHITE" | "BLACK" | null;
  status: "ACTIVE" | "REMOVED";
  note: string;
  addedByName: string;
  addedAt: string;
  removedByName: string | null;
  removedAt: string | null;
  removalReason: string | null;
};

export type AdminReserveCandidate = {
  profileId: string;
  displayName: string;
  username: string | null;
  avatarUrl: string | null;
  outfieldRating: number;
  keeperRating: number;
  eligible: boolean;
  unavailableReason: string | null;
};

type Row = Record<string, unknown>;

const reserveSelect = `
  id,
  match_kind,
  profile_id,
  side,
  status,
  note,
  added_at,
  removed_at,
  removal_reason,
  profile:profiles!match_reserve_assignments_profile_id_fkey(
    id,
    display_name,
    username,
    avatar_url
  ),
  added_by_profile:referee_profiles!match_reserve_assignments_added_by_fkey(
    display_name
  ),
  removed_by_profile:referee_profiles!match_reserve_assignments_removed_by_fkey(
    display_name
  )
`;

export async function loadAdminGameReserves(
  db: SupabaseClient,
  matchKind: "SOLO" | "CLAN",
  matchId: string,
): Promise<{ active: AdminGameReserve[]; history: AdminGameReserve[] }> {
  let query = db
    .from("match_reserve_assignments")
    .select(reserveSelect)
    .eq("match_kind", matchKind)
    .order("added_at", { ascending: false });
  query = matchKind === "SOLO"
    ? query.eq("open_queue_game_id", matchId)
    : query.eq("fixture_id", matchId);
  const { data, error } = await query.limit(30);
  if (error) throw new Error(`Could not load reserves: ${error.message}`);
  const reserves = rows(data).map(normalizeReserve);
  return {
    active: reserves.filter((reserve) => reserve.status === "ACTIVE"),
    history: reserves.filter((reserve) => reserve.status === "REMOVED"),
  };
}

export async function loadAdminReserveCandidates(
  db: SupabaseClient,
  matchKind: "SOLO" | "CLAN",
  matchId: string,
  search: string,
): Promise<AdminReserveCandidate[]> {
  const normalizedSearch = search.trim().slice(0, 80);
  let participantIds: string[] = [];

  if (matchKind === "CLAN") {
    const { data: fixture, error: fixtureError } = await db
      .from("fixtures")
      .select("id")
      .eq("id", matchId)
      .maybeSingle();
    if (fixtureError) throw new Error(`Could not load fixture: ${fixtureError.message}`);
    if (!fixture) throw new Error("Clan fixture not found.");
    const [rosterResult, appearanceResult] = await Promise.all([
      db.from("fixture_reliability_roster_history").select("profile_id")
        .eq("fixture_id", matchId).eq("status", "CONFIRMED"),
      db.from("fixture_player_appearances").select("profile_id")
        .eq("fixture_id", matchId).eq("played", true),
    ]);
    if (rosterResult.error) throw new Error(`Could not load confirmed roster: ${rosterResult.error.message}`);
    if (appearanceResult.error) throw new Error(`Could not load recorded players: ${appearanceResult.error.message}`);
    participantIds = [...new Set([
      ...rows(rosterResult.data).map((row) => String(row.profile_id)),
      ...rows(appearanceResult.data).map((row) => String(row.profile_id)),
    ])];
  } else {
    const { data, error } = await db.from("open_queue_bookings")
      .select("profile_id")
      .eq("game_id", matchId)
      .eq("status", "CONFIRMED");
    if (error) throw new Error(`Could not load confirmed bookings: ${error.message}`);
    participantIds = rows(data).map((row) => String(row.profile_id));
  }

  const profiles = await searchProfiles(db, normalizedSearch);
  const { active } = await loadAdminGameReserves(db, matchKind, matchId);
  const activeReserveIds = new Set(active.map((reserve) => reserve.profileId));
  const participantSet = new Set(participantIds);

  return profiles.map((profile) => {
    const profileId = String(profile.id);
    const isParticipant = participantSet.has(profileId);
    const isReserve = activeReserveIds.has(profileId);
    return {
      profileId,
      displayName: text(profile.display_name, "Player"),
      username: nullableText(profile.username),
      avatarUrl: nullableText(profile.avatar_url),
      outfieldRating: ratingFrom(rows(profile.fieldrush_player_rating_tracks).find((row) => row.rating_track === "OUTFIELD")),
      keeperRating: ratingFrom(rows(profile.fieldrush_player_rating_tracks).find((row) => row.rating_track === "GOALKEEPER")),
      eligible: !isParticipant && !isReserve,
      unavailableReason: isParticipant
        ? "Already in the official roster"
        : isReserve
          ? "Already assigned as a reserve"
          : null,
    };
  });
}

async function searchProfiles(
  db: SupabaseClient,
  search: string,
): Promise<Row[]> {
  const select = "id,display_name,username,avatar_url,fieldrush_player_rating_tracks(rating_track,skill_rating)";
  const build = () => {
    let query = db.from("profiles").select(select).order("display_name").limit(20);
    return query;
  };
  if (!search) {
    const { data, error } = await build();
    if (error) throw new Error(`Could not load players: ${error.message}`);
    return rows(data);
  }
  const [names, usernames] = await Promise.all([
    build().ilike("display_name", `%${search}%`),
    build().ilike("username", `%${search.replace(/^@/, "")}%`),
  ]);
  if (names.error) throw new Error(`Could not search player names: ${names.error.message}`);
  if (usernames.error) throw new Error(`Could not search usernames: ${usernames.error.message}`);
  const found = new Map<string, Row>();
  for (const row of [...rows(names.data), ...rows(usernames.data)]) {
    found.set(String(row.id), row);
  }
  return [...found.values()].slice(0, 20);
}

function normalizeReserve(row: Row): AdminGameReserve {
  const profile = relation(row.profile);
  const addedBy = relation(row.added_by_profile);
  const removedBy = relation(row.removed_by_profile);
  return {
    id: text(row.id),
    matchKind: row.match_kind === "CLAN" ? "CLAN" : "SOLO",
    profileId: text(row.profile_id),
    displayName: text(profile.display_name, "Player"),
    username: nullableText(profile.username),
    avatarUrl: nullableText(profile.avatar_url),
    side: nullableSide(row.side),
    status: row.status === "REMOVED" ? "REMOVED" : "ACTIVE",
    note: text(row.note),
    addedByName: text(addedBy.display_name, "Administrator"),
    addedAt: text(row.added_at),
    removedByName: nullableText(removedBy.display_name),
    removedAt: nullableText(row.removed_at),
    removalReason: nullableText(row.removal_reason),
  };
}

function nullableSide(value: unknown): AdminGameReserve["side"] {
  return value === "HOME" || value === "AWAY" || value === "WHITE" || value === "BLACK"
    ? value
    : null;
}

function ratingFrom(value: unknown) {
  const row = relation(value);
  const parsed = Number(row.skill_rating);
  return Number.isFinite(parsed) ? Math.round(parsed) : 1200;
}

function relation(value: unknown): Row {
  if (Array.isArray(value)) return relation(value[0]);
  return value && typeof value === "object" ? value as Row : {};
}

function rows(value: unknown): Row[] {
  return Array.isArray(value)
    ? value.filter((row): row is Row => Boolean(row) && typeof row === "object")
    : [];
}

function text(value: unknown, fallback = "") {
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function nullableText(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}
