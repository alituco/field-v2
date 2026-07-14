import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type GameRow = {
  id: string;
  status: string;
  starts_at: string;
  ends_at: string;
  white_score: number | null;
  black_score: number | null;
};

type BookingRow = {
  profile_id: string;
  team: "WHITE" | "BLACK" | null;
  played: boolean;
};

type PlannedGoal = {
  game_id: string;
  team: "WHITE" | "BLACK";
  profile_id: string;
  assist_profile_id: string | null;
  minute: number;
  second: number;
  occurred_at: string;
};

const url = requireEnv("SUPABASE_URL");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const SCHEDULE_SEED_PREFIX = "[SCHEDULE SEED]";
const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const [{ data: games, error: gamesError }, {
  data: referees,
  error: refereesError,
}] = await Promise.all([
  admin
    .from("open_queue_games")
    .select("id,status,starts_at,ends_at,white_score,black_score")
    .neq("status", "CANCELLED")
    .order("starts_at"),
  admin
    .from("referee_profiles")
    .select("profile_id")
    .eq("is_active", true)
    .order("created_at"),
]);
if (gamesError) throw gamesError;
if (refereesError) throw refereesError;

const refereeIds = (referees ?? []).map((row) => String(row.profile_id));
if (refereeIds.length === 0) {
  throw new Error(
    "Create at least one active referee before seeding assignments.",
  );
}

let assignmentsSeeded = 0;
let finalGamesSeeded = 0;
let fixtureTimestampsCorrected = 0;

for (let index = 0; index < (games ?? []).length; index += 1) {
  const game = games![index] as GameRow;
  const refereeId = refereeIds[index % refereeIds.length];
  const { error: assignmentError } = await admin
    .from("open_queue_referee_assignments")
    .upsert(
      {
        game_id: game.id,
        referee_id: refereeId,
        assigned_by: refereeId,
      },
      { onConflict: "game_id" },
    );
  if (assignmentError) throw assignmentError;
  assignmentsSeeded += 1;

  if (game.status !== "FINAL") continue;
  await seedFinalGame(game);
  finalGamesSeeded += 1;
}

fixtureTimestampsCorrected = await correctHistoricFixtureEventTimestamps();

console.log(
  `Seeded ${assignmentsSeeded} solo referee assignments and match timelines for ` +
    `${finalGamesSeeded} completed solo games. Corrected ` +
    `${fixtureTimestampsCorrected} historic clan event timestamps.`,
);

async function seedFinalGame(game: GameRow) {
  const { data: bookings, error: bookingsError } = await admin
    .from("open_queue_bookings")
    .select("profile_id,team,played")
    .eq("game_id", game.id)
    .eq("status", "CONFIRMED")
    .not("team", "is", null)
    .order("booked_at");
  if (bookingsError) throw bookingsError;

  const players = ((bookings ?? []) as BookingRow[]).filter((row) =>
    row.played
  );
  const whitePlayers = players.filter((row) => row.team === "WHITE");
  const blackPlayers = players.filter((row) => row.team === "BLACK");
  if (whitePlayers.length === 0 || blackPlayers.length === 0) {
    throw new Error(
      `Final solo game ${game.id} does not have two assigned teams.`,
    );
  }

  const kickoff = new Date(game.starts_at);
  const finalWhistle = new Date(game.ends_at);
  const elapsedSeconds = Math.max(
    0,
    Math.round((finalWhistle.getTime() - kickoff.getTime()) / 1000),
  );
  const durationSeconds = Math.max(600, Math.min(7200, elapsedSeconds || 3600));

  const { error: clockError } = await admin
    .from("open_queue_clock_states")
    .upsert(
      {
        game_id: game.id,
        status: "ENDED",
        started_at: null,
        accumulated_seconds: durationSeconds,
        duration_seconds: durationSeconds,
        created_at: kickoff.toISOString(),
      },
      { onConflict: "game_id" },
    );
  if (clockError) throw clockError;

  const whiteScore = Number(game.white_score ?? 0);
  const blackScore = Number(game.black_score ?? 0);
  const plannedGoals = [
    ...planGoals(
      game,
      "WHITE",
      whitePlayers,
      whiteScore,
      0,
    ),
    ...planGoals(
      game,
      "BLACK",
      blackPlayers,
      blackScore,
      1,
    ),
  ].sort((left, right) =>
    left.minute - right.minute || left.second - right.second
  );

  const { data: existingGoals, error: goalCountError } = await admin
    .from("open_queue_goals")
    .select("team")
    .eq("game_id", game.id);
  if (goalCountError) throw goalCountError;
  const goalCount = existingGoals?.length ?? 0;
  const existingWhiteGoals =
    (existingGoals ?? []).filter((goal) => goal.team === "WHITE").length;
  const existingBlackGoals =
    (existingGoals ?? []).filter((goal) => goal.team === "BLACK").length;
  if (
    goalCount > 0 &&
    (existingWhiteGoals !== whiteScore || existingBlackGoals !== blackScore)
  ) {
    throw new Error(
      `Solo game ${game.id} goals do not match its ${whiteScore}-${blackScore} scoreline.`,
    );
  }
  if (goalCount === 0 && plannedGoals.length > 0) {
    throw new Error(
      `Solo game ${game.id} is FINAL without its recorded goals. Final goals ` +
        "are immutable after Player SR is applied; reset/reseed the schedule " +
        "instead of repairing its score in place.",
    );
  }

  const { data: existingEvents, error: eventCountError } = await admin
    .from("open_queue_events")
    .select("event_type,team")
    .eq("game_id", game.id);
  if (eventCountError) throw eventCountError;
  const eventCount = existingEvents?.length ?? 0;
  if (eventCount > 0) {
    const eventTypes = (existingEvents ?? []).map((row) => row.event_type);
    const recordedWhiteGoals = (existingEvents ?? []).filter((event) =>
      event.event_type === "GOAL" && event.team === "WHITE"
    ).length;
    const recordedBlackGoals = (existingEvents ?? []).filter((event) =>
      event.event_type === "GOAL" && event.team === "BLACK"
    ).length;
    if (
      recordedWhiteGoals !== whiteScore ||
      recordedBlackGoals !== blackScore ||
      !eventTypes.includes("MATCH_STARTED") ||
      !eventTypes.includes("MATCH_ENDED")
    ) {
      throw new Error(
        `Solo game ${game.id} has a partial or inconsistent match timeline.`,
      );
    }
  }
  if (eventCount === 0) {
    const events = [
      {
        game_id: game.id,
        event_type: "MATCH_STARTED",
        minute: 0,
        second: 0,
        created_at: kickoff.toISOString(),
        occurred_at: kickoff.toISOString(),
      },
      ...plannedGoals.map((goal) => ({
        game_id: goal.game_id,
        event_type: "GOAL",
        team: goal.team,
        profile_id: goal.profile_id,
        assist_profile_id: goal.assist_profile_id,
        minute: goal.minute,
        second: goal.second,
        created_at: goal.occurred_at,
        occurred_at: goal.occurred_at,
      })),
      {
        game_id: game.id,
        event_type: "MATCH_ENDED",
        minute: Math.floor(durationSeconds / 60),
        second: durationSeconds % 60,
        created_at: finalWhistle.toISOString(),
        occurred_at: finalWhistle.toISOString(),
      },
    ];
    const { error } = await admin.from("open_queue_events").insert(events);
    if (error) throw error;
  }
}

function planGoals(
  game: GameRow,
  team: "WHITE" | "BLACK",
  players: BookingRow[],
  score: number,
  offset: number,
): PlannedGoal[] {
  const kickoff = new Date(game.starts_at).getTime();
  return Array.from({ length: score }, (_, goalIndex) => {
    const scorerIndex = (goalIndex * 2 + offset) % players.length;
    const assistIndex = (scorerIndex + 1) % players.length;
    const minute = 6 + ((goalIndex * 11 + offset * 7) % 48);
    const second = (goalIndex * 17 + offset * 23) % 60;
    return {
      game_id: game.id,
      team,
      profile_id: players[scorerIndex].profile_id,
      assist_profile_id: players.length > 1
        ? players[assistIndex].profile_id
        : null,
      minute,
      second,
      occurred_at: new Date(
        kickoff + (minute * 60 + second) * 1000,
      ).toISOString(),
    };
  });
}

async function correctHistoricFixtureEventTimestamps() {
  const { data: seededFixtures, error: fixtureError } = await admin
    .from("fixtures")
    .select("id")
    .ilike("venue", `${SCHEDULE_SEED_PREFIX}%`);
  if (fixtureError) throw fixtureError;
  const fixtureIds = (seededFixtures ?? []).map((row) => String(row.id));
  if (fixtureIds.length === 0) return 0;

  const { data, error } = await admin
    .from("fixture_events")
    .select("id,created_at,occurred_at")
    .in("fixture_id", fixtureIds);
  if (error) throw error;

  const incorrect = (data ?? []).filter((row) => {
    const createdAt = Date.parse(String(row.created_at));
    const occurredAt = Date.parse(String(row.occurred_at));
    return Number.isFinite(createdAt) && Number.isFinite(occurredAt) &&
      Math.abs(occurredAt - createdAt) > 5 * 60 * 1000;
  });
  for (const row of incorrect) {
    const { error: updateError } = await admin
      .from("fixture_events")
      .update({ occurred_at: row.created_at })
      .eq("id", row.id);
    if (updateError) throw updateError;
  }
  return incorrect.length;
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}
