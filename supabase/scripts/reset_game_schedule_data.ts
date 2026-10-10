import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";
import { assertSafeDevDataTarget } from "./_shared/environment_guard.ts";
import { legacyOpenQueueFormat } from "./_shared/legacy_open_queue_format.ts";

type ProfileRow = {
  id: string;
  phone: string | null;
};

type ClanRow = {
  id: string;
  name: string;
  tag: string;
  created_by: string;
};

type SeedClan = ClanRow & {
  roster: ProfileRow[];
};

type SeedContext = {
  profiles: ProfileRow[];
  eligibleClans: SeedClan[];
  historyClans: [SeedClan, SeedClan, SeedClan, SeedClan];
  futureClans: SeedClan[];
  refereeIds: string[];
};

type CloudflareEnvelope<T> = {
  success?: boolean;
  result?: T;
  errors?: Array<{ message?: string }>;
};

type CloudflareVideo = { uid: string };

type GoalRow = {
  fixture_id: string;
  clan_id: string;
  profile_id: string;
  assist_profile_id: string | null;
  minute: number;
  created_at: string;
};

type SoloPlayerRow = {
  profile_id: string;
  role: string;
  team: "WHITE" | "BLACK";
};

const SEED_PREFIX = "[SCHEDULE SEED]";
const CLAN_TIME_SLOT = "7:00 PM - 8:00 PM";
const DEFAULT_DEV_PHONE = "+97338883670";
const ALLOWED_ARGS = new Set([
  "--confirm",
  "--clear-only",
  "--skip-cloudflare",
]);
const HISTORY_PAIRS = [
  [0, 1],
  [2, 3],
  [0, 2],
  [1, 3],
  [0, 3],
  [1, 2],
  [0, 1],
  [2, 3],
] as const;
const HISTORY_SCORES = [
  [3, 1],
  [2, 4],
  [1, 2],
  [4, 2],
  [2, 0],
  [1, 3],
  [2, 1],
  [1, 2],
] as const;
const FULL_SOLO_ROLES = [
  "GK",
  "GK",
  "DEF",
  "DEF",
  "DEF",
  "DEF",
  "MID",
  "MID",
  "MID",
  "MID",
  "ATT",
  "ATT",
] as const;
const FUTURE_SOLO_ROLES = [
  ["GK", "GK", "DEF", "DEF", "DEF", "MID", "MID", "ATT"],
  ["GK", "GK", "DEF", "DEF", "DEF", "MID", "MID", "MID", "ATT", "ATT"],
  [...FULL_SOLO_ROLES],
  ["GK", "DEF", "DEF", "MID", "MID", "MID", "ATT"],
  ["GK", "GK", "DEF", "DEF", "DEF", "MID", "MID", "MID", "ATT"],
] as const;

for (const argument of Deno.args) {
  if (!ALLOWED_ARGS.has(argument)) {
    throw new Error(`Unknown argument: ${argument}`);
  }
}
if (!Deno.args.includes("--confirm")) {
  throw new Error(
    "This permanently deletes every game and game-derived rating. Re-run with --confirm.",
  );
}

const clearOnly = Deno.args.includes("--clear-only");
const skipCloudflare = Deno.args.includes("--skip-cloudflare");
const url = requireEnv("SUPABASE_URL");
assertSafeDevDataTarget(url, "game schedule reset/seed");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const profiles = await loadProfiles();
const seedContext = clearOnly ? null : await loadSeedContext(profiles);
const broadcasts = await loadBroadcasts();

if (broadcasts.length > 0 && !skipCloudflare) {
  await deleteCloudflareAssets(broadcasts);
} else if (broadcasts.length > 0) {
  console.warn(
    `Leaving ${broadcasts.length} Cloudflare live inputs/recordings untouched ` +
      "because --skip-cloudflare was provided.",
  );
}

await clearGameData(profiles);

if (clearOnly) {
  console.log(
    "Clean slate complete: all clan fixtures, solo games, bookings, game metadata, and game-derived ratings were removed.",
  );
} else {
  const seeded = await seedCanonicalSchedule(seedContext!);
  console.log(
    `Clean schedule seeded: ${seeded.finalFixtures} completed clan games, ` +
      `${seeded.upcomingFixtures} upcoming clan games, ` +
      `${seeded.finalSoloGames} completed solo games, ` +
      `${seeded.upcomingSoloGames} upcoming solo games, and ` +
      `${seeded.soloBookings} confirmed solo bookings.`,
  );
}

async function loadProfiles() {
  const { data, error } = await admin
    .from("profiles")
    .select("id,phone")
    .order("id");
  if (error) throw error;
  const rows = (data ?? []) as ProfileRow[];
  if (rows.length < 24 && !clearOnly) {
    throw new Error(
      `The canonical schedule needs at least 24 profiles; found ${rows.length}.`,
    );
  }
  return rows;
}

async function loadSeedContext(
  profileRows: ProfileRow[],
): Promise<SeedContext> {
  const [{ data: clanRows, error: clanError }, {
    data: memberRows,
    error: memberError,
  }, { data: refereeRows, error: refereeError }] = await Promise.all([
    admin
      .from("clans")
      .select("id,name,tag,created_by")
      .is("archived_at", null),
    admin
      .from("clan_members")
      .select("clan_id,profile_id")
      .is("left_at", null),
    admin
      .from("referee_profiles")
      .select("profile_id")
      .eq("is_active", true)
      .order("display_name"),
  ]);
  if (clanError) throw clanError;
  if (memberError) throw memberError;
  if (refereeError) throw refereeError;

  const profilesById = new Map(
    profileRows.map((profile) => [profile.id, profile]),
  );
  const membersByClan = new Map<string, ProfileRow[]>();
  for (const member of memberRows ?? []) {
    const profile = profilesById.get(String(member.profile_id));
    if (!profile) continue;
    const clanId = String(member.clan_id);
    const roster = membersByClan.get(clanId) ?? [];
    roster.push(profile);
    membersByClan.set(clanId, roster);
  }

  const preferredTags = [
    "MMAV",
    "RIFR",
    "NRYL",
    "CDRF",
    "PEAR",
    "DILM",
    "HIDD",
    "TIDE",
    "SAAR",
    "TTR",
  ];
  const preferredOrder = new Map(
    preferredTags.map((tag, index) => [tag, index]),
  );
  const eligibleClans = ((clanRows ?? []) as ClanRow[])
    .map((clan) => ({
      ...clan,
      roster: [...(membersByClan.get(clan.id) ?? [])].sort((left, right) =>
        left.id.localeCompare(right.id)
      ),
    }))
    .filter((clan) => clan.roster.length >= 7)
    .sort((left, right) => {
      const leftOrder = preferredOrder.get(left.tag) ?? 1000;
      const rightOrder = preferredOrder.get(right.tag) ?? 1000;
      return leftOrder - rightOrder || left.tag.localeCompare(right.tag);
    });

  if (eligibleClans.length < 9) {
    throw new Error(
      `The canonical schedule needs at least 9 active clans with 7 players; found ${eligibleClans.length}.`,
    );
  }

  const historyClans = eligibleClans.slice(0, 4) as SeedContext["historyClans"];
  assert(historyClans.length === 4, "Could not choose four history clans.");

  return {
    profiles: [...profileRows].sort((left, right) => {
      if (left.phone === DEFAULT_DEV_PHONE) return -1;
      if (right.phone === DEFAULT_DEV_PHONE) return 1;
      return left.id.localeCompare(right.id);
    }),
    eligibleClans,
    historyClans,
    futureClans: eligibleClans.slice(0, 9),
    refereeIds: (refereeRows ?? []).map((row) => String(row.profile_id)),
  };
}

async function loadBroadcasts() {
  const [fixtureResult, soloResult] = await Promise.all([
    admin
      .from("fixture_broadcasts")
      .select("live_input_id,active_video_id"),
    admin
      .from("open_queue_broadcasts")
      .select("live_input_id,active_video_id"),
  ]);
  if (fixtureResult.error) throw fixtureResult.error;
  if (soloResult.error) throw soloResult.error;
  return [
    ...(fixtureResult.data ?? []),
    ...(soloResult.data ?? []),
  ] as Array<{
    live_input_id: string | null;
    active_video_id: string | null;
  }>;
}

async function deleteCloudflareAssets(
  broadcasts: Array<{
    live_input_id: string | null;
    active_video_id: string | null;
  }>,
) {
  const accountId = requireEnv("CLOUDFLARE_ACCOUNT_ID");
  const token = requireEnv("CLOUDFLARE_STREAM_API_TOKEN");
  const inputIds = new Set(
    broadcasts.map((broadcast) => broadcast.live_input_id).filter(isString),
  );
  const videoIds = new Set(
    broadcasts.map((broadcast) => broadcast.active_video_id).filter(isString),
  );

  for (const inputId of inputIds) {
    const videos = await cloudflareRequest<CloudflareVideo[]>(
      accountId,
      token,
      `/stream/live_inputs/${encodeURIComponent(inputId)}/videos`,
    );
    for (const video of videos ?? []) videoIds.add(video.uid);
  }

  for (const videoId of videoIds) {
    await cloudflareRequest(
      accountId,
      token,
      `/stream/${encodeURIComponent(videoId)}`,
      "DELETE",
    );
  }
  for (const inputId of inputIds) {
    await cloudflareRequest(
      accountId,
      token,
      `/stream/live_inputs/${encodeURIComponent(inputId)}`,
      "DELETE",
    );
  }

  console.log(
    `Deleted ${videoIds.size} Cloudflare recordings and ${inputIds.size} live inputs.`,
  );
}

async function cloudflareRequest<T = Record<string, never>>(
  accountId: string,
  token: string,
  path: string,
  method = "GET",
): Promise<T | null> {
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${accountId}${path}`,
    {
      method,
      headers: { Authorization: `Bearer ${token}` },
    },
  );
  if (response.status === 404) return null;

  const raw = await response.text();
  const payload = raw.length > 0
    ? JSON.parse(raw) as CloudflareEnvelope<T>
    : { success: response.ok };
  if (!response.ok || payload.success === false) {
    const message = payload.errors?.map((error) => error.message).filter(
      isString,
    )
      .join(" ");
    throw new Error(
      message || `Cloudflare cleanup failed (${response.status}) for ${path}.`,
    );
  }
  return payload.result ?? null;
}

async function clearGameData(profileRows: ProfileRow[]) {
  await assertNoError(
    admin.from("player_rating_events").delete().not("id", "is", null),
    "delete player rating events",
  );
  await assertNoError(
    admin.from("open_queue_games").delete().not("id", "is", null),
    "delete Open Queue games",
  );
  await assertNoError(
    admin.from("fixtures").delete().not("id", "is", null),
    "delete clan fixtures",
  );

  if (profileRows.length > 0) {
    await assertNoError(
      admin.from("player_ratings").upsert(
        profileRows.map((profile) => ({ profile_id: profile.id })),
        { onConflict: "profile_id", ignoreDuplicates: true },
      ),
      "ensure player rating rows",
    );
  }
  await assertNoError(
    admin.from("player_ratings").update({
      skill_rating: 1200,
      matches_played: 0,
      wins: 0,
      losses: 0,
      draws: 0,
      last_change: 0,
    }).not("profile_id", "is", null),
    "reset player ratings",
  );
  await assertNoError(
    admin.from("clans").update({
      skill_rating: 1500,
      wins: 0,
      losses: 0,
    }).not("id", "is", null),
    "reset clan ratings",
  );
  await assertNoError(
    admin.from("broadcast_devices").update({
      status: "OFFLINE",
      obs_connected: false,
      obs_streaming: false,
      current_fixture_id: null,
      current_open_queue_game_id: null,
      error_message: null,
    }).not("device_key", "is", null),
    "reset broadcast devices",
  );

  const emptyTables = [
    "fixtures",
    "fixture_scorers",
    "fixture_clock_states",
    "fixture_events",
    "fixture_blue_cards",
    "fixture_referee_assignments",
    "fixture_broadcasts",
    "broadcast_commands",
    "fixture_player_appearances",
    "open_queue_clock_states",
    "open_queue_goals",
    "open_queue_events",
    "open_queue_blue_cards",
    "open_queue_referee_assignments",
    "open_queue_broadcasts",
    "open_queue_games",
    "open_queue_bookings",
    "player_rating_events",
  ];
  for (const table of emptyTables) {
    const { count, error } = await admin
      .from(table)
      .select("*", { count: "exact", head: true });
    if (error) throw error;
    assert(count === 0, `${table} was not fully cleared.`);
  }
}

async function seedCanonicalSchedule(context: SeedContext) {
  const pastDates = matchDates("past", HISTORY_PAIRS.length);
  const futureDates = matchDates("future", FUTURE_SOLO_ROLES.length);
  const temporarySoloStart = soloStartAt(
    matchDates("future", 1, 365)[0],
  );

  for (let index = 0; index < HISTORY_PAIRS.length; index += 1) {
    const [homeIndex, awayIndex] = HISTORY_PAIRS[index];
    const [homeScore, awayScore] = HISTORY_SCORES[index];
    await seedFinalClanFixture({
      index,
      matchDate: pastDates[index],
      home: context.historyClans[homeIndex],
      away: context.historyClans[awayIndex],
      homeScore,
      awayScore,
    });
  }

  const ratingsByProfile = await loadRatings();
  for (let index = 0; index < pastDates.length; index += 1) {
    await seedFinalSoloGame({
      index,
      matchDate: pastDates[index],
      temporaryStart: temporarySoloStart,
      profiles: context.profiles,
      ratingsByProfile,
      refereeId: refereeForIndex(context.refereeIds, index),
    });
  }

  await seedUpcomingClanFixtures(context.futureClans, futureDates);
  const upcomingSoloBookings = await seedUpcomingSoloGames(
    context.profiles,
    ratingsByProfile,
    futureDates,
    context.refereeIds,
  );

  return {
    finalFixtures: pastDates.length,
    upcomingFixtures: futureDates.length,
    finalSoloGames: pastDates.length,
    upcomingSoloGames: futureDates.length,
    soloBookings: pastDates.length * FULL_SOLO_ROLES.length +
      upcomingSoloBookings,
  };
}

async function seedFinalClanFixture({
  index,
  matchDate,
  home,
  away,
  homeScore,
  awayScore,
}: {
  index: number;
  matchDate: string;
  home: SeedClan;
  away: SeedClan;
  homeScore: number;
  awayScore: number;
}) {
  const kickoff = clanStartAt(matchDate);
  const paidAt = new Date(kickoff.getTime() - 7 * 24 * 60 * 60 * 1000)
    .toISOString();
  const { data: fixture, error: fixtureError } = await admin
    .from("fixtures")
    .insert({
      status: "SCHEDULED",
      home_clan_id: home.id,
      away_clan_id: away.id,
      venue: `${SEED_PREFIX} Clan History ${index + 1}`,
      day: dayLabel(matchDate),
      time_slot: CLAN_TIME_SLOT,
      match_date: matchDate,
      created_by: home.created_by,
      home_paid_by: home.created_by,
      away_paid_by: away.created_by,
      home_paid_at: paidAt,
      away_paid_at: paidAt,
      created_at: paidAt,
    })
    .select("id")
    .single();
  if (fixtureError) throw fixtureError;

  const fixtureId = String(fixture.id);
  await assertNoError(
    admin.from("fixture_clock_states").insert({
      fixture_id: fixtureId,
      status: "PAUSED",
      accumulated_seconds: 3600,
      duration_seconds: 3600,
      created_at: kickoff.toISOString(),
    }),
    "create historical fixture clock",
  );
  await assertNoError(
    admin.from("fixtures").update({ status: "LIVE" }).eq("id", fixtureId),
    "start historical clan fixture",
  );

  const playedProfiles = [
    ...home.roster.slice(0, 7),
    ...away.roster.slice(0, 7),
  ];
  const { data: playedRows, error: playedError } = await admin
    .from("fixture_player_appearances")
    .update({ played: true })
    .eq("fixture_id", fixtureId)
    .in("profile_id", playedProfiles.map((profile) => profile.id))
    .select("profile_id");
  if (playedError) throw playedError;
  assert(
    (playedRows ?? []).length === 14,
    `Could not confirm fourteen players for ${fixtureId}.`,
  );

  const goals = [
    ...buildGoals(fixtureId, home, homeScore, kickoff, index * 2),
    ...buildGoals(fixtureId, away, awayScore, kickoff, index * 2 + 1),
  ].sort((left, right) => left.minute - right.minute);
  if (goals.length > 0) {
    await assertNoError(
      admin.from("fixture_scorers").insert(goals),
      "insert historical scorers",
    );
  }

  const events = [
    {
      fixture_id: fixtureId,
      event_type: "MATCH_STARTED",
      minute: 0,
      second: 0,
      occurred_at: kickoff.toISOString(),
      created_at: kickoff.toISOString(),
    },
    ...goals.map((goal, goalIndex) => ({
      fixture_id: fixtureId,
      event_type: "GOAL",
      clan_id: goal.clan_id,
      profile_id: goal.profile_id,
      assist_profile_id: goal.assist_profile_id,
      minute: goal.minute,
      second: (goalIndex * 13 + index * 7) % 60,
      occurred_at: new Date(
        kickoff.getTime() + goal.minute * 60 * 1000 +
          ((goalIndex * 13 + index * 7) % 60) * 1000,
      ).toISOString(),
      created_at: new Date(
        kickoff.getTime() + goal.minute * 60 * 1000 +
          ((goalIndex * 13 + index * 7) % 60) * 1000,
      ).toISOString(),
    })),
    {
      fixture_id: fixtureId,
      event_type: "MATCH_ENDED",
      minute: 60,
      second: 0,
      occurred_at: new Date(kickoff.getTime() + 60 * 60 * 1000)
        .toISOString(),
      created_at: new Date(kickoff.getTime() + 60 * 60 * 1000).toISOString(),
    },
  ];
  await assertNoError(
    admin.from("fixture_events").insert(events),
    "insert historical fixture events",
  );

  const { data: completed, error: completeError } = await admin.rpc(
    "referee_complete_fixture",
    { fixture_id_to_complete: fixtureId },
  );
  if (completeError) throw completeError;
  assert(
    completed?.status === "FINAL" &&
      Number(completed.home_score) === homeScore &&
      Number(completed.away_score) === awayScore,
    `Historical fixture ${fixtureId} did not finalize correctly.`,
  );
}

function buildGoals(
  fixtureId: string,
  clan: SeedClan,
  score: number,
  kickoff: Date,
  offset: number,
): GoalRow[] {
  const roster = clan.roster.slice(0, 7);
  return Array.from({ length: score }, (_, goalIndex) => {
    const scorerIndex = (offset + goalIndex * 2) % roster.length;
    const assistIndex = (scorerIndex + 1) % roster.length;
    const minute = 6 + ((offset * 7 + goalIndex * 13) % 49);
    return {
      fixture_id: fixtureId,
      clan_id: clan.id,
      profile_id: roster[scorerIndex].id,
      assist_profile_id: roster[assistIndex].id,
      minute,
      created_at: new Date(kickoff.getTime() + minute * 60 * 1000)
        .toISOString(),
    };
  });
}

async function seedFinalSoloGame({
  index,
  matchDate,
  temporaryStart,
  profiles: profileRows,
  ratingsByProfile,
  refereeId,
}: {
  index: number;
  matchDate: string;
  temporaryStart: Date;
  profiles: ProfileRow[];
  ratingsByProfile: Map<string, number>;
  refereeId: string | null;
}) {
  const actualStart = soloStartAt(matchDate);
  const createdAt = new Date(actualStart.getTime() - 2 * 24 * 60 * 60 * 1000)
    .toISOString();
  const { data: game, error: gameError } = await admin
    .from("open_queue_games")
    .insert({
      ...legacyOpenQueueFormat,
      venue: `${SEED_PREFIX} Solo History ${index + 1}`,
      starts_at: temporaryStart.toISOString(),
      ends_at: new Date(temporaryStart.getTime() + 60 * 60 * 1000)
        .toISOString(),
      timezone: "Asia/Bahrain",
      age_label: "All ages",
      price_fils: 3000,
      created_at: createdAt,
    })
    .select("id")
    .single();
  if (gameError) throw gameError;
  const gameId = String(game.id);

  const participants = Array.from(
    { length: FULL_SOLO_ROLES.length },
    (_, playerIndex) =>
      profileRows[(index * 11 + playerIndex) % profileRows.length],
  );
  for (
    let playerIndex = 0;
    playerIndex < participants.length;
    playerIndex += 1
  ) {
    const profile = participants[playerIndex];
    await insertSoloBooking({
      gameId,
      profile,
      role: FULL_SOLO_ROLES[playerIndex],
      rating: requireRating(ratingsByProfile, profile.id),
      reference: `schedule-history-${index}-${playerIndex}`,
    });
  }

  const whiteScore = 2 + (index % 4);
  const blackScore = 1 + ((index * 2) % 4);
  const { data: playedRows, error: playedError } = await admin
    .from("open_queue_bookings")
    .update({ played: true, booked_at: createdAt })
    .eq("game_id", gameId)
    .eq("status", "CONFIRMED")
    .select("profile_id,role,team");
  if (playedError) throw playedError;
  assert(
    (playedRows ?? []).length === FULL_SOLO_ROLES.length,
    `Could not confirm the historical solo lineup for ${gameId}.`,
  );
  assert(
    (playedRows ?? []).every((row) =>
      row.team === "WHITE" || row.team === "BLACK"
    ),
    `Historical solo teams were not assigned for ${gameId}.`,
  );
  const soloPlayers = (playedRows ?? []) as SoloPlayerRow[];

  await assertNoError(
    admin.from("open_queue_clock_states").insert({
      game_id: gameId,
      status: "PAUSED",
      accumulated_seconds: 3600,
      duration_seconds: 3600,
      created_at: actualStart.toISOString(),
    }),
    "create historical solo clock",
  );

  const { data: liveGame, error: liveError } = await admin
    .from("open_queue_games")
    .update({
      status: "LIVE",
      starts_at: actualStart.toISOString(),
      ends_at: new Date(actualStart.getTime() + 60 * 60 * 1000).toISOString(),
    })
    .eq("id", gameId)
    .select("status")
    .single();
  if (liveError) throw liveError;
  assert(
    liveGame.status === "LIVE",
    `Solo history ${gameId} did not start.`,
  );

  await assignSoloReferee(gameId, refereeId);

  const goals = [
    ...buildSoloGoals(
      gameId,
      "WHITE",
      soloPlayers.filter((player) => player.team === "WHITE"),
      whiteScore,
      actualStart,
      index * 2,
    ),
    ...buildSoloGoals(
      gameId,
      "BLACK",
      soloPlayers.filter((player) => player.team === "BLACK"),
      blackScore,
      actualStart,
      index * 2 + 1,
    ),
  ].sort((left, right) => left.minute - right.minute);

  if (goals.length > 0) {
    await assertNoError(
      admin.from("open_queue_goals").insert(
        goals.map(({ second: _, ...goal }) => goal),
      ),
      "insert historical solo goals",
    );
  }

  const endAt = new Date(actualStart.getTime() + 60 * 60 * 1000)
    .toISOString();
  await assertNoError(
    admin.from("open_queue_events").insert([
      {
        game_id: gameId,
        event_type: "MATCH_STARTED",
        minute: 0,
        second: 0,
        occurred_at: actualStart.toISOString(),
        created_at: actualStart.toISOString(),
      },
      ...goals.map((goal) => ({
        game_id: gameId,
        event_type: "GOAL",
        team: goal.team,
        profile_id: goal.profile_id,
        assist_profile_id: goal.assist_profile_id,
        minute: goal.minute,
        second: goal.second,
        occurred_at: goal.created_at,
        created_at: goal.created_at,
      })),
      {
        game_id: gameId,
        event_type: "MATCH_ENDED",
        minute: 60,
        second: 0,
        occurred_at: endAt,
        created_at: endAt,
      },
    ]),
    "insert historical solo events",
  );

  const { data: finalGame, error: finalError } = await admin.rpc(
    "referee_complete_open_queue_game",
    { game_id_to_complete: gameId },
  );
  if (finalError) throw finalError;
  assert(
    finalGame?.status === "FINAL" &&
      Number(finalGame.white_score) === whiteScore &&
      Number(finalGame.black_score) === blackScore,
    `Solo history ${gameId} did not finalize.`,
  );
}

function buildSoloGoals(
  gameId: string,
  team: "WHITE" | "BLACK",
  players: SoloPlayerRow[],
  score: number,
  kickoff: Date,
  offset: number,
) {
  assert(players.length > 0, `${team} has no players in ${gameId}.`);
  return Array.from({ length: score }, (_, goalIndex) => {
    const scorerIndex = (offset + goalIndex * 2) % players.length;
    const assistIndex = (scorerIndex + 1) % players.length;
    const minute = 5 + ((offset * 7 + goalIndex * 13) % 50);
    const second = (offset * 11 + goalIndex * 17) % 60;
    return {
      game_id: gameId,
      team,
      profile_id: players[scorerIndex].profile_id,
      assist_profile_id: players.length > 1
        ? players[assistIndex].profile_id
        : null,
      minute,
      second,
      created_at: new Date(
        kickoff.getTime() + minute * 60 * 1000 + second * 1000,
      ).toISOString(),
    };
  });
}

async function assignSoloReferee(gameId: string, refereeId: string | null) {
  if (!refereeId) return;
  await assertNoError(
    admin.from("open_queue_referee_assignments").upsert({
      game_id: gameId,
      referee_id: refereeId,
      assigned_by: refereeId,
    }),
    "assign solo referee",
  );
}

async function seedUpcomingClanFixtures(
  clans: SeedClan[],
  matchDates: string[],
) {
  const matchups = [
    [clans[4], clans[5]],
    [clans[6], clans[7]],
    [clans[2], clans[0]],
    [clans[3], clans[1]],
    [clans[8], null],
  ] as const;

  for (let index = 0; index < matchups.length; index += 1) {
    const [home, away] = matchups[index];
    const paidAt = new Date().toISOString();
    await assertNoError(
      admin.from("fixtures").insert({
        status: away == null ? "OPEN" : "SCHEDULED",
        home_clan_id: home.id,
        away_clan_id: away?.id ?? null,
        venue: `${SEED_PREFIX} Clan Future ${index + 1}`,
        day: dayLabel(matchDates[index]),
        time_slot: CLAN_TIME_SLOT,
        match_date: matchDates[index],
        created_by: home.created_by,
        home_paid_by: home.created_by,
        away_paid_by: away?.created_by ?? null,
        home_paid_at: paidAt,
        away_paid_at: away == null ? null : paidAt,
      }),
      "insert upcoming clan fixture",
    );
  }
}

async function seedUpcomingSoloGames(
  profileRows: ProfileRow[],
  ratingsByProfile: Map<string, number>,
  matchDates: string[],
  refereeIds: string[],
) {
  const counts = new Map<string, number>();
  const defaultProfile = profileRows.find((profile) =>
    profile.phone === DEFAULT_DEV_PHONE
  );
  let cursor = 0;
  let totalBookings = 0;

  for (let gameIndex = 0; gameIndex < matchDates.length; gameIndex += 1) {
    const startsAt = soloStartAt(matchDates[gameIndex]);
    const { data: game, error: gameError } = await admin
      .from("open_queue_games")
      .insert({
        ...legacyOpenQueueFormat,
        venue: `${SEED_PREFIX} Solo Future ${gameIndex + 1}`,
        starts_at: startsAt.toISOString(),
        ends_at: new Date(startsAt.getTime() + 60 * 60 * 1000).toISOString(),
        timezone: "Asia/Bahrain",
        age_label: gameIndex % 2 === 0 ? "Ages 16–30" : "All ages",
        price_fils: 3000,
      })
      .select("id")
      .single();
    if (gameError) throw gameError;
    const gameId = String(game.id);
    await assignSoloReferee(
      gameId,
      refereeForIndex(refereeIds, gameIndex),
    );

    const used = new Set<string>();
    const roles = FUTURE_SOLO_ROLES[gameIndex];
    for (let bookingIndex = 0; bookingIndex < roles.length; bookingIndex += 1) {
      let profile: ProfileRow;
      if (gameIndex === 0 && bookingIndex === 0 && defaultProfile) {
        profile = defaultProfile;
      } else {
        profile = nextEligibleProfile(
          profileRows,
          counts,
          used,
          defaultProfile?.id,
          cursor,
        );
        cursor = (profileRows.indexOf(profile) + 1) % profileRows.length;
      }
      used.add(profile.id);
      increment(counts, profile.id);
      await insertSoloBooking({
        gameId,
        profile,
        role: roles[bookingIndex],
        rating: requireRating(ratingsByProfile, profile.id),
        reference: `schedule-future-${gameIndex}-${bookingIndex}`,
      });
      totalBookings += 1;
    }
  }

  if (defaultProfile) {
    assert(
      counts.get(defaultProfile.id) === 1,
      "The default dev profile must have exactly one upcoming solo booking.",
    );
  }
  assert(
    [...counts.values()].every((count) => count <= 2),
    "The seed assigned a player more than two upcoming solo games.",
  );
  return totalBookings;
}

function nextEligibleProfile(
  profilesToSearch: ProfileRow[],
  counts: Map<string, number>,
  used: Set<string>,
  defaultProfileId: string | undefined,
  startIndex: number,
) {
  for (let offset = 0; offset < profilesToSearch.length; offset += 1) {
    const profile =
      profilesToSearch[(startIndex + offset) % profilesToSearch.length];
    if (
      profile.id !== defaultProfileId &&
      !used.has(profile.id) &&
      (counts.get(profile.id) ?? 0) < 2
    ) {
      return profile;
    }
  }
  throw new Error("Not enough eligible profiles for the future solo seed.");
}

async function insertSoloBooking({
  gameId,
  profile,
  role,
  rating,
  reference,
}: {
  gameId: string;
  profile: ProfileRow;
  role: string;
  rating: number;
  reference: string;
}) {
  await assertNoError(
    admin.from("open_queue_bookings").insert({
      game_id: gameId,
      profile_id: profile.id,
      role,
      player_rating_at_booking: rating,
      amount_paid_fils: 3000,
      payment_method: "MOCK",
      payment_reference: reference,
    }),
    "insert solo booking",
  );
}

async function loadRatings() {
  const { data, error } = await admin
    .from("player_ratings")
    .select("profile_id,skill_rating");
  if (error) throw error;
  return new Map(
    (data ?? []).map((rating) => [
      String(rating.profile_id),
      Number(rating.skill_rating),
    ]),
  );
}

function matchDates(
  direction: "past" | "future",
  count: number,
  minimumDaysAway = 0,
) {
  const today = bahrainToday();
  const dates: string[] = [];
  const step = direction === "future" ? 1 : -1;
  const cursor = new Date(today);
  cursor.setUTCDate(cursor.getUTCDate() + step * Math.max(1, minimumDaysAway));

  for (let checked = 0; dates.length < count && checked < 1000; checked += 1) {
    const weekday = cursor.getUTCDay();
    if (weekday === 2 || weekday === 5) {
      const date = cursor.toISOString().slice(0, 10);
      if (
        direction === "past" ||
        clanStartAt(date).getTime() > Date.now() + 24 * 60 * 60 * 1000
      ) {
        dates.push(date);
      }
    }
    cursor.setUTCDate(cursor.getUTCDate() + step);
  }
  assert(
    dates.length === count,
    `Could not find ${count} ${direction} match days.`,
  );
  return direction === "past" ? dates.reverse() : dates;
}

function bahrainToday() {
  const local = new Date(Date.now() + 3 * 60 * 60 * 1000);
  return new Date(Date.UTC(
    local.getUTCFullYear(),
    local.getUTCMonth(),
    local.getUTCDate(),
  ));
}

function dayLabel(date: string): "TUESDAY" | "FRIDAY" {
  const weekday = new Date(`${date}T12:00:00Z`).getUTCDay();
  assert(weekday === 2 || weekday === 5, `${date} is not Tuesday or Friday.`);
  return weekday === 2 ? "TUESDAY" : "FRIDAY";
}

function clanStartAt(date: string) {
  return new Date(`${date}T16:00:00.000Z`);
}

function soloStartAt(date: string) {
  return new Date(`${date}T17:30:00.000Z`);
}

function increment(counts: Map<string, number>, key: string) {
  counts.set(key, (counts.get(key) ?? 0) + 1);
}

function refereeForIndex(refereeIds: string[], index: number) {
  if (refereeIds.length === 0) return null;
  return refereeIds[index % refereeIds.length];
}

function requireRating(ratings: Map<string, number>, profileId: string) {
  const rating = ratings.get(profileId);
  if (rating == null) {
    throw new Error(`Missing player rating for ${profileId}.`);
  }
  return rating;
}

function isString(value: string | null | undefined): value is string {
  return typeof value === "string" && value.length > 0;
}

async function assertNoError(
  query: PromiseLike<{ error: { message: string } | null }>,
  action: string,
) {
  const { error } = await query;
  if (error) throw new Error(`${action}: ${error.message}`);
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
