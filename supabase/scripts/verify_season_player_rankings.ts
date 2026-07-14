import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.86.0";

type ProfileRow = { id: string; phone: string };
type RankingRow = {
  rank: number;
  profile_id: string;
  skill_rating: number;
  matches_played: number;
  wins: number;
  losses: number;
  draws: number;
  last_change: number;
};

const url = requireEnv("SUPABASE_URL");
const publishableKey = requireEnv("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = requireEnv("DEV_SEED_PASSWORD");
const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const userIds: string[] = [];
const clanIds: string[] = [];
const fixtureIds: string[] = [];
const verificationRegion = `rank-${crypto.randomUUID().slice(0, 8)}`;

await cleanupStaleVerificationData();

try {
  const eligible = await createVerificationProfile("Eligible");
  const ineligible = await createVerificationProfile("Ineligible");
  const fallback = await createVerificationProfile("Fallback");
  const eligibleClient = await signedInClient(eligible.phone);
  const ineligibleClient = await signedInClient(ineligible.phone);

  const homeClanId = await createClan(eligible, "Home");
  const awayClanId = await createClan(ineligible, "Away");

  await admin.from("player_ratings").update({
    skill_rating: 1600,
    matches_played: 20,
    wins: 12,
    losses: 6,
    draws: 2,
    last_change: 99,
    region: verificationRegion,
  }).eq("profile_id", eligible.id).throwOnError();
  await admin.from("player_ratings").update({
    skill_rating: 1700,
    matches_played: 20,
    wins: 12,
    losses: 6,
    draws: 2,
    last_change: 99,
    region: verificationRegion,
  }).eq("profile_id", ineligible.id).throwOnError();
  await admin.from("player_ratings").update({
    skill_rating: 9000,
    matches_played: 20,
    wins: 12,
    losses: 6,
    draws: 2,
    last_change: 99,
    region: verificationRegion,
  }).eq("profile_id", fallback.id).throwOnError();

  const firstSeasonFixture = await createFinalFixture({
    homeClanId,
    awayClanId,
    createdBy: eligible.id,
    matchDate: "2026-06-02",
    homeScore: 2,
    awayScore: 1,
  });
  const secondSeasonFixture = await createFinalFixture({
    homeClanId,
    awayClanId,
    createdBy: eligible.id,
    matchDate: "2026-09-29",
    homeScore: 1,
    awayScore: 1,
  });
  const outsideSeasonFixture = await createFinalFixture({
    homeClanId: awayClanId,
    awayClanId: homeClanId,
    createdBy: ineligible.id,
    matchDate: "2026-10-02",
    homeScore: 3,
    awayScore: 0,
  });

  // Build every frozen lineup before adding its ledger events. Rated lineups
  // are intentionally immutable once the first event for a fixture exists.
  await insertAppearance({
    fixtureId: secondSeasonFixture,
    profileId: eligible.id,
    clanId: homeClanId,
    side: "HOME",
    played: true,
    ratingBefore: 1300,
    ratingChange: 20,
    createdAt: "2026-09-29T18:00:00Z",
  });
  await insertAppearance({
    fixtureId: firstSeasonFixture,
    profileId: eligible.id,
    clanId: homeClanId,
    side: "HOME",
    played: true,
    ratingBefore: 1320,
    ratingChange: 80,
    createdAt: "2026-10-03T18:00:00Z",
  });
  await insertAppearance({
    fixtureId: firstSeasonFixture,
    profileId: ineligible.id,
    clanId: awayClanId,
    side: "AWAY",
    played: true,
    ratingBefore: 1405,
    ratingChange: -5,
    createdAt: "2026-06-02T18:00:01Z",
  });
  await insertAppearance({
    fixtureId: outsideSeasonFixture,
    profileId: ineligible.id,
    clanId: awayClanId,
    side: "HOME",
    played: true,
    ratingBefore: 1400,
    ratingChange: 100,
    createdAt: "2026-10-02T18:00:00Z",
  });

  await insertAppearance({
    fixtureId: secondSeasonFixture,
    profileId: ineligible.id,
    clanId: awayClanId,
    side: "AWAY",
    played: false,
    ratingBefore: 1400,
    ratingChange: null,
    createdAt: "2026-09-29T17:59:00Z",
  });
  await insertAppearance({
    fixtureId: firstSeasonFixture,
    profileId: fallback.id,
    clanId: homeClanId,
    side: "HOME",
    played: true,
    ratingBefore: 1300,
    ratingChange: 10,
    createdAt: "2026-06-02T18:00:02Z",
  });
  await insertAppearance({
    fixtureId: secondSeasonFixture,
    profileId: fallback.id,
    clanId: homeClanId,
    side: "HOME",
    played: true,
    ratingBefore: 1310,
    ratingChange: 5,
    createdAt: "2026-09-29T18:00:02Z",
  });

  await insertRatingEvent({
    fixtureId: secondSeasonFixture,
    profileId: eligible.id,
    side: "HOME",
    result: "DRAW",
    ratingBefore: 1300,
    ratingChange: 20,
    ratingAfter: 1320,
    createdAt: "2026-09-29T18:00:00Z",
  });
  await insertRatingEvent({
    fixtureId: firstSeasonFixture,
    profileId: eligible.id,
    side: "HOME",
    result: "WIN",
    ratingBefore: 1320,
    ratingChange: 80,
    ratingAfter: 1400,
    createdAt: "2026-10-03T18:00:00Z",
  });
  await insertRatingEvent({
    fixtureId: firstSeasonFixture,
    profileId: ineligible.id,
    side: "AWAY",
    result: "LOSS",
    ratingBefore: 1405,
    ratingChange: -5,
    ratingAfter: 1400,
    createdAt: "2026-06-02T18:00:01Z",
  });
  await insertRatingEvent({
    fixtureId: outsideSeasonFixture,
    profileId: ineligible.id,
    side: "HOME",
    result: "WIN",
    ratingBefore: 1400,
    ratingChange: 100,
    ratingAfter: 1500,
    createdAt: "2026-10-02T18:00:00Z",
  });
  await insertRatingEvent({
    fixtureId: firstSeasonFixture,
    profileId: fallback.id,
    side: "HOME",
    result: "WIN",
    ratingBefore: 1300,
    ratingChange: 10,
    ratingAfter: 1310,
    createdAt: "2026-06-02T18:00:02Z",
  });
  await insertRatingEvent({
    fixtureId: secondSeasonFixture,
    profileId: fallback.id,
    side: "HOME",
    result: "DRAW",
    ratingBefore: 1310,
    ratingChange: 5,
    ratingAfter: 1315,
    createdAt: "2026-09-29T18:00:02Z",
  });

  const seasonParams = {
    region_to_use: verificationRegion,
    season_starts_on: "2026-06-01",
    season_ends_on: "2026-09-30",
  };
  const { data: leaderboard, error: leaderboardError } = await eligibleClient
    .rpc("list_season_player_rating_leaderboard", seasonParams);
  if (leaderboardError) throw leaderboardError;
  const rankingRows = leaderboard as RankingRow[];

  const eligibleRow = rankingRows.find((row) => row.profile_id === eligible.id);
  const ineligibleRow = rankingRows.find((row) =>
    row.profile_id === ineligible.id
  );
  const fallbackRow = rankingRows.find((row) => row.profile_id === fallback.id);
  assert(eligibleRow, "A player with two season games must be ranked.");
  assert(
    eligibleRow.rank === 1 && rankingRows.length === 2,
    "The eligible player's rank must be calculated after filtering.",
  );
  assert(
    eligibleRow.matches_played === 2 &&
      eligibleRow.wins === 1 &&
      eligibleRow.draws === 1 &&
      eligibleRow.losses === 0,
    "The leaderboard record must include only selected-season games.",
  );
  assert(
    eligibleRow.skill_rating === 1400 && eligibleRow.last_change === 80,
    "The leaderboard must use the last-applied in-season rating event.",
  );
  assert(
    !ineligibleRow,
    "A player with only one game in the selected season must be excluded.",
  );
  assert(
    fallbackRow?.rank === 2 &&
      fallbackRow.skill_rating === 1315 &&
      fallbackRow.last_change === 5,
    "Season rankings must use the latest applied in-season ledger event.",
  );

  const eligiblePersonal = await loadPersonalRating(
    eligibleClient,
    seasonParams,
  );
  assert(
    eligiblePersonal.rank === 1 && eligiblePersonal.matches_played === 2,
    "An eligible player must see the same personal season rank.",
  );

  const ineligiblePersonal = await loadPersonalRating(
    ineligibleClient,
    seasonParams,
  );
  assert(
    ineligiblePersonal.rank === 0 &&
      ineligiblePersonal.matches_played === 1,
    "An ineligible player must see 1 of 2 games and no rank.",
  );
  assert(
    ineligiblePersonal.skill_rating === 1400,
    "A game outside the selected season must not change its displayed rating.",
  );

  const anonymous = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { error: anonymousError } = await anonymous.rpc(
    "list_season_player_rating_leaderboard",
    seasonParams,
  );
  assert(anonymousError, "Anonymous users must not call season rankings.");

  const { error: helperError } = await eligibleClient.rpc(
    "season_player_rating_rankings",
    seasonParams,
  );
  assert(
    helperError,
    "Authenticated users must not call the internal ranking helper.",
  );

  console.log(
    "Season Player Rankings verified: exact boundaries, 2-game eligibility, played=false exclusion, late finalization, stable fallback, personal progress, and RPC privileges.",
  );
} finally {
  if (fixtureIds.length > 0) {
    const { error: eventError } = await admin.from("player_rating_events")
      .delete().eq("source_type", "CLAN_FIXTURE").in("source_id", fixtureIds);
    if (eventError) {
      console.error("Could not clean up rating events:", eventError.message);
    }
    const { error } = await admin.from("fixtures").delete().in(
      "id",
      fixtureIds,
    );
    if (error) console.error("Could not clean up fixtures:", error.message);
  }
  if (clanIds.length > 0) {
    const { error } = await admin.from("clans").delete().in("id", clanIds);
    if (error) console.error("Could not clean up clans:", error.message);
  }
  for (const userId of userIds) {
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) console.error("Could not clean up user:", error.message);
  }
}

async function createVerificationProfile(label: string): Promise<ProfileRow> {
  const digits = String(Math.floor(10_000_000 + Math.random() * 89_999_999));
  const phone = `+973${digits}`;
  const { data, error } = await admin.auth.admin.createUser({
    phone,
    password,
    phone_confirm: true,
    user_metadata: { display_name: `Rank Verify ${label}` },
  });
  if (error) throw error;
  userIds.push(data.user.id);

  const { error: profileError } = await admin.from("profiles").upsert({
    id: data.user.id,
    phone,
    display_name: `Rank Verify ${label}`,
    username: `season_rank_${digits}`,
  });
  if (profileError) throw profileError;
  return { id: data.user.id, phone };
}

async function signedInClient(phone: string) {
  const client = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { error } = await client.auth.signInWithPassword({ phone, password });
  if (error) throw error;
  return client;
}

async function createClan(owner: ProfileRow, label: string) {
  const suffix = owner.id.replaceAll("-", "").slice(0, 4).toUpperCase();
  const { data, error } = await admin.from("clans").insert({
    name: `Verify ${label} ${suffix}`,
    tag: `V${suffix}`.slice(0, 5),
    created_by: owner.id,
    region: "bahrain",
  }).select("id").single();
  if (error) throw error;
  clanIds.push(data.id);
  return data.id as string;
}

async function createFinalFixture({
  homeClanId,
  awayClanId,
  createdBy,
  matchDate,
  homeScore,
  awayScore,
}: {
  homeClanId: string;
  awayClanId: string;
  createdBy: string;
  matchDate: string;
  homeScore: number;
  awayScore: number;
}) {
  const { data, error } = await admin.from("fixtures").insert({
    status: "FINAL",
    home_clan_id: homeClanId,
    away_clan_id: awayClanId,
    venue: "Season Rank Verification",
    day: dayLabel(matchDate),
    time_slot: "7:00 PM - 8:00 PM",
    match_date: matchDate,
    home_score: homeScore,
    away_score: awayScore,
    winner_clan_id: homeScore === awayScore
      ? null
      : homeScore > awayScore
      ? homeClanId
      : awayClanId,
    created_by: createdBy,
  }).select("id").single();
  if (error) throw error;
  fixtureIds.push(data.id);
  return data.id as string;
}

function dayLabel(matchDate: string): "TUESDAY" | "FRIDAY" {
  const weekday = new Date(`${matchDate}T12:00:00Z`).getUTCDay();
  assert(
    weekday === 2 || weekday === 5,
    "Ranking verification fixtures must be on Tuesday or Friday.",
  );
  return weekday === 2 ? "TUESDAY" : "FRIDAY";
}

async function insertRatingEvent({
  fixtureId,
  profileId,
  side,
  result,
  ratingBefore,
  ratingChange,
  ratingAfter,
  createdAt,
}: {
  fixtureId: string;
  profileId: string;
  side: "HOME" | "AWAY";
  result: "WIN" | "LOSS" | "DRAW";
  ratingBefore: number;
  ratingChange: number;
  ratingAfter: number;
  createdAt: string;
}) {
  const { data: fixture, error: fixtureError } = await admin
    .from("fixtures")
    .select("match_date,time_slot")
    .eq("id", fixtureId)
    .single();
  if (fixtureError) throw fixtureError;
  const effectiveAt = `${fixture.match_date}T${
    fixture.time_slot === "7:00 PM - 8:00 PM" ? "16:00:00" : "17:00:00"
  }Z`;

  const { error: eventError } = await admin.from("player_rating_events").insert(
    {
      profile_id: profileId,
      source_type: "CLAN_FIXTURE",
      source_id: fixtureId,
      side,
      result,
      rating_before: ratingBefore,
      rating_change: ratingChange,
      rating_after: ratingAfter,
      created_at: createdAt,
      effective_at: effectiveAt,
    },
  );
  if (eventError) throw eventError;
}

async function cleanupStaleVerificationData() {
  const { data: fixtures, error: fixtureLoadError } = await admin
    .from("fixtures")
    .select("id")
    .eq("venue", "Season Rank Verification");
  if (fixtureLoadError) throw fixtureLoadError;
  const staleFixtureIds = (fixtures ?? []).map((fixture) => String(fixture.id));
  if (staleFixtureIds.length > 0) {
    await admin.from("player_rating_events").delete()
      .eq("source_type", "CLAN_FIXTURE")
      .in("source_id", staleFixtureIds).throwOnError();
    await admin.from("fixtures").delete().in("id", staleFixtureIds)
      .throwOnError();
  }

  const { data: profiles, error: profileLoadError } = await admin
    .from("profiles")
    .select("id")
    .like("username", "season_rank_%");
  if (profileLoadError) throw profileLoadError;
  const staleUserIds = (profiles ?? []).map((profile) => String(profile.id));
  if (staleUserIds.length === 0) return;

  await admin.from("clans").delete().in("created_by", staleUserIds)
    .throwOnError();
  for (const userId of staleUserIds) {
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) throw error;
  }
}

async function insertAppearance({
  fixtureId,
  profileId,
  clanId,
  side,
  played,
  ratingBefore,
  ratingChange,
  createdAt,
}: {
  fixtureId: string;
  profileId: string;
  clanId: string;
  side: "HOME" | "AWAY";
  played: boolean;
  ratingBefore: number;
  ratingChange: number | null;
  createdAt: string;
}) {
  const { error } = await admin.from("fixture_player_appearances").insert({
    fixture_id: fixtureId,
    profile_id: profileId,
    clan_id: clanId,
    side,
    played,
    rating_at_start: ratingBefore,
    rating_change: ratingChange,
    created_at: createdAt,
  });
  if (error) throw error;
}

async function loadPersonalRating(
  client: SupabaseClient,
  params: Record<string, string>,
) {
  const { data, error } = await client.rpc(
    "get_my_season_player_rating",
    params,
  );
  if (error) throw error;
  assert(data.length === 1, "Personal season rating must return one row.");
  return data[0] as RankingRow;
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
