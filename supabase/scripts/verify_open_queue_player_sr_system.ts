import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";
import { assertSafeDevDataTarget } from "./_shared/environment_guard.ts";

type GameRow = {
  id: string;
  status: string;
  starts_at: string;
  white_average_sr: number | string | null;
  black_average_sr: number | string | null;
  match_average_sr: number | string | null;
  team_sr_spread: number | string | null;
  teams_assigned_at: string | null;
  white_score: number | null;
  black_score: number | null;
};

type BookingRow = {
  id: string;
  game_id: string;
  profile_id: string;
  role: "GK" | "DEF" | "MID" | "ATT";
  status: string;
  team: "WHITE" | "BLACK" | null;
  played: boolean;
  rating_at_team_assignment: number | null;
  rating_at_match_start: number | null;
  rating_change: number | null;
};

type RatingEventRow = {
  id: string;
  profile_id: string;
  source_type: "CLAN_FIXTURE" | "OPEN_QUEUE";
  source_id: string;
  rating_before: number;
  rating_change: number;
  rating_after: number;
  opponent_average_rating: number | string | null;
  expected_score: number | string | null;
  calculation_version: string;
  effective_at: string;
  applied_sequence: number | string;
};

type AppearanceRow = {
  fixture_id: string;
  profile_id: string;
  played: boolean;
  rating_change: number | null;
};

const url = requireEnv("SUPABASE_URL");
assertSafeDevDataTarget(url, "Open Queue player-SR verification");
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

const { data: verifier, error: createError } = await admin.auth.admin
  .createUser(
    {
      phone: verifierPhone,
      password,
      phone_confirm: true,
      user_metadata: { display_name: "Player SR System Verifier" },
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

  const { error: finalizerError } = await admin.rpc(
    "finalize_due_open_queue_teams",
  );
  if (finalizerError) throw finalizerError;

  const [
    gamesResult,
    bookingsResult,
    appearancesResult,
    eventsResult,
    ratingsResult,
  ] = await Promise
    .all([
      admin.from("open_queue_games").select(
        "id,status,starts_at,white_average_sr,black_average_sr,match_average_sr,team_sr_spread,teams_assigned_at,white_score,black_score",
      ).in("status", ["FULL", "LIVE", "FINAL"]).order("starts_at"),
      admin.from("open_queue_bookings").select(
        "id,game_id,profile_id,role,status,team,played,rating_at_team_assignment,rating_at_match_start,rating_change",
      ).eq("status", "CONFIRMED"),
      admin.from("fixture_player_appearances").select(
        "fixture_id,profile_id,played,rating_change",
      ),
      admin.from("player_rating_events").select(
        "id,profile_id,source_type,source_id,rating_before,rating_change,rating_after,opponent_average_rating,expected_score,calculation_version,effective_at,applied_sequence",
      ).order("applied_sequence"),
      admin.from("player_ratings").select(
        "profile_id,matches_played,wins,losses,draws,skill_rating,last_change",
      ),
    ]);

  for (
    const result of [
      gamesResult,
      bookingsResult,
      appearancesResult,
      eventsResult,
      ratingsResult,
    ]
  ) {
    if (result.error) throw result.error;
  }

  const games = (gamesResult.data ?? []) as GameRow[];
  const bookings = (bookingsResult.data ?? []) as BookingRow[];
  const appearances = (appearancesResult.data ?? []) as AppearanceRow[];
  const events = (eventsResult.data ?? []) as RatingEventRow[];
  assert(games.length > 0, "No assigned Open Queue games were found.");

  const fullGames = games.filter((game) =>
    game.status === "FULL" && game.teams_assigned_at !== null
  );
  const awaitingCutoffGames = games.filter((game) =>
    game.status === "FULL" && game.teams_assigned_at === null
  );

  for (const game of awaitingCutoffGames) {
    assert(
      Date.parse(game.starts_at) - 3 * 60 * 60 * 1000 > Date.now(),
      `${game.id} is inside its three-hour cutoff without assigned teams.`,
    );
    const gameBookings = bookings.filter((booking) =>
      booking.game_id === game.id
    );
    assert(
      gameBookings.every((booking) =>
        booking.team === null && booking.rating_at_team_assignment === null
      ),
      `${game.id} leaked a team or assignment SR before its cutoff.`,
    );
  }

  for (const game of fullGames) {
    const gameBookings = bookings.filter((booking) =>
      booking.game_id === game.id
    );
    verifyExactBalance(game, gameBookings);
  }

  const immutableGame = fullGames[0];
  if (immutableGame) {
    const before = snapshotAssignment(
      immutableGame,
      bookings.filter((booking) => booking.game_id === immutableGame.id),
    );
    const { error: repeatError } = await admin.rpc("assign_open_queue_teams", {
      game_id_to_assign: immutableGame.id,
    });
    if (repeatError) throw repeatError;
    const [{ data: repeatedGame, error: repeatedGameError }, {
      data: repeatedBookings,
      error: repeatedBookingsError,
    }] = await Promise.all([
      admin.from("open_queue_games").select(
        "id,status,starts_at,white_average_sr,black_average_sr,match_average_sr,team_sr_spread,teams_assigned_at,white_score,black_score",
      ).eq("id", immutableGame.id).single(),
      admin.from("open_queue_bookings").select(
        "id,game_id,profile_id,role,status,team,played,rating_at_team_assignment,rating_at_match_start,rating_change",
      ).eq("game_id", immutableGame.id).eq("status", "CONFIRMED"),
    ]);
    if (repeatedGameError) throw repeatedGameError;
    if (repeatedBookingsError) throw repeatedBookingsError;
    const after = snapshotAssignment(
      repeatedGame as GameRow,
      (repeatedBookings ?? []) as BookingRow[],
    );
    assert(
      before === after,
      "Re-running assignment changed a frozen team snapshot.",
    );
  }

  verifyLedger(events, ratingsResult.data ?? []);
  verifyFinalSoloRatings(games, bookings, events);
  verifyDenormalizedRatingChanges(bookings, appearances, events);

  const missingFixtureId = crypto.randomUUID();
  const [{ error: startContractError }, { error: finishContractError }] =
    await Promise.all([
      admin.rpc("referee_start_fixture_atomic", {
        fixture_id_to_start: missingFixtureId,
        participant_ids_to_use: [],
        duration_seconds_to_use: 3600,
      }),
      admin.rpc("referee_finish_fixture_atomic", {
        fixture_id_to_complete: missingFixtureId,
      }),
    ]);
  assert(
    startContractError?.message.includes("Match not found") &&
      finishContractError?.message.includes("Match not found"),
    "Atomic clan start/finish RPC contracts are missing or renamed.",
  );

  const sourceTypes = new Set(events.map((event) => event.source_type));
  assert(
    sourceTypes.has("CLAN_FIXTURE") && sourceTypes.has("OPEN_QUEUE"),
    "The Player SR ledger must contain both clan and solo match sources.",
  );

  const auditedProfileId = events.find((event) =>
    event.source_type === "OPEN_QUEUE"
  )
    ?.profile_id;
  assert(
    auditedProfileId,
    "No solo Player SR event is available for history verification.",
  );
  const { data: historyData, error: historyError } = await authenticated.rpc(
    "get_player_rating_history",
    { profile_id_to_use: auditedProfileId, limit_to_use: 100 },
  );
  if (historyError) throw historyError;
  const history = asObject(historyData);
  assert(
    Number.isInteger(Number(history.skill_rating)),
    "History has no current SR.",
  );
  assert(
    Number.isInteger(Number(history.matches_played)),
    "History has no match total.",
  );
  assert(Array.isArray(history.events), "History has no events array.");
  const historyEvents = history.events as Array<Record<string, unknown>>;
  assert(historyEvents.length > 0, "History returned no ledger events.");
  assert(
    historyEvents.every((event) =>
      event.event_id && event.source_id && event.played_at &&
      event.opponent_label && event.calculation_version === "PLAYER_ELO_V1" &&
      Number.isFinite(Number(event.opponent_average_rating)) &&
      Number.isFinite(Number(event.expected_score))
    ),
    "History omitted a public calculation audit field.",
  );
  assert(
    historyEvents.every((event, index) =>
      index === 0 ||
      Number(historyEvents[index - 1].applied_sequence) >
        Number(event.applied_sequence)
    ),
    "History is not ordered by descending ledger application sequence.",
  );

  console.log(
    `Verified ${fullGames.length} exact team balance(s), ${events.length} ` +
      `append-only Player SR events across clan and solo play, and ` +
      `${historyEvents.length} public history rows.`,
  );
}

function verifyExactBalance(game: GameRow, bookings: BookingRow[]) {
  assert(bookings.length === 12, `${game.id} does not have twelve players.`);
  assert(game.teams_assigned_at, `${game.id} has no assignment timestamp.`);
  assert(
    bookings.every((booking) =>
      booking.team != null && booking.rating_at_team_assignment != null
    ),
    `${game.id} has an incomplete assignment snapshot.`,
  );

  const white = bookings.filter((booking) => booking.team === "WHITE");
  const black = bookings.filter((booking) => booking.team === "BLACK");
  assertRoleSplit(white, game.id, "WHITE");
  assertRoleSplit(black, game.id, "BLACK");

  const byRole = new Map<string, BookingRow[]>();
  for (const role of ["GK", "DEF", "MID", "ATT"]) {
    byRole.set(role, bookings.filter((booking) => booking.role === role));
  }
  assert(byRole.get("GK")?.length === 2, `${game.id} has the wrong GK total.`);
  assert(
    byRole.get("DEF")?.length === 4,
    `${game.id} has the wrong DEF total.`,
  );
  assert(
    byRole.get("MID")?.length === 4,
    `${game.id} has the wrong MID total.`,
  );
  assert(
    byRole.get("ATT")?.length === 2,
    `${game.id} has the wrong ATT total.`,
  );

  const candidates: BookingRow[][] = [];
  for (const goalkeeper of byRole.get("GK")!) {
    for (const defenders of chooseTwo(byRole.get("DEF")!)) {
      for (const midfielders of chooseTwo(byRole.get("MID")!)) {
        for (const attacker of byRole.get("ATT")!) {
          candidates.push([goalkeeper, ...defenders, ...midfielders, attacker]);
        }
      }
    }
  }
  assert(
    candidates.length === 144,
    "The verifier did not enumerate 144 candidates.",
  );

  const total = sumSr(bookings);
  const optimalDifference = Math.min(
    ...candidates.map((candidate) => Math.abs(sumSr(candidate) * 2 - total)),
  );
  const actualDifference = Math.abs(sumSr(white) - sumSr(black));
  assert(
    actualDifference === optimalDifference,
    `${game.id} has SR sum spread ${actualDifference}, but ${optimalDifference} is possible.`,
  );

  const whiteAverage = round2(sumSr(white) / white.length);
  const blackAverage = round2(sumSr(black) / black.length);
  const matchAverage = round2(total / bookings.length);
  assert(
    Number(game.white_average_sr) === whiteAverage &&
      Number(game.black_average_sr) === blackAverage &&
      Number(game.match_average_sr) === matchAverage &&
      Number(game.team_sr_spread) ===
        round2(Math.abs(whiteAverage - blackAverage)),
    `${game.id} stored averages do not match its frozen player snapshots.`,
  );
}

function verifyLedger(
  events: RatingEventRow[],
  ratings: Array<Record<string, unknown>>,
) {
  const sequences = new Set<number>();
  const eventsByProfile = new Map<string, RatingEventRow[]>();
  for (const event of events) {
    const sequence = Number(event.applied_sequence);
    assert(Number.isInteger(sequence), `${event.id} has no applied sequence.`);
    assert(
      !sequences.has(sequence),
      `Ledger sequence ${sequence} is duplicated.`,
    );
    sequences.add(sequence);
    assert(
      event.rating_before + event.rating_change === event.rating_after,
      `${event.id} breaks the before + change = after invariant.`,
    );
    assert(event.effective_at, `${event.id} has no source match timestamp.`);
    assert(
      event.calculation_version === "PLAYER_ELO_V1",
      `${event.id} has the wrong calculation version.`,
    );
    assert(
      Number.isFinite(Number(event.opponent_average_rating)) &&
        Number.isFinite(Number(event.expected_score)),
      `${event.id} is missing calculation inputs.`,
    );
    const profileEvents = eventsByProfile.get(event.profile_id) ?? [];
    profileEvents.push(event);
    eventsByProfile.set(event.profile_id, profileEvents);
  }

  for (const [profileId, profileEvents] of eventsByProfile) {
    const applied = profileEvents.toSorted((left, right) =>
      Number(left.applied_sequence) - Number(right.applied_sequence)
    );
    for (let index = 1; index < applied.length; index += 1) {
      assert(
        applied[index].rating_before === applied[index - 1].rating_after,
        `${profileId} ledger chain breaks between ${
          applied[index - 1].id
        } and ${applied[index].id}.`,
      );
    }
  }

  for (const rating of ratings) {
    const profileId = String(rating.profile_id);
    const profileEvents = eventsByProfile.get(profileId) ?? [];
    assert(
      Number(rating.matches_played) === profileEvents.length,
      `${profileId} aggregate match count does not match its ledger.`,
    );
    if (profileEvents.length === 0) continue;
    const latest = profileEvents.toSorted((left, right) =>
      Number(right.applied_sequence) - Number(left.applied_sequence)
    )[0];
    assert(
      Number(rating.skill_rating) === latest.rating_after &&
        Number(rating.last_change) === latest.rating_change,
      `${profileId} current SR does not match its latest ledger event.`,
    );
  }
}

function verifyFinalSoloRatings(
  games: GameRow[],
  bookings: BookingRow[],
  events: RatingEventRow[],
) {
  for (const game of games.filter((row) => row.status === "FINAL")) {
    const played = bookings.filter((booking) =>
      booking.game_id === game.id && booking.played
    );
    if (played.length === 0) continue;
    const gameEvents = events.filter((event) =>
      event.source_type === "OPEN_QUEUE" && event.source_id === game.id
    );
    assert(
      gameEvents.length === played.length,
      `${game.id} did not apply exactly one solo SR event per played booking.`,
    );
    const eventByProfile = new Map(
      gameEvents.map((event) => [event.profile_id, event]),
    );
    for (const booking of played) {
      const event = eventByProfile.get(booking.profile_id);
      assert(event, `${game.id} is missing ${booking.profile_id}'s SR event.`);
      assert(
        booking.rating_at_match_start != null &&
          booking.rating_change === event.rating_change,
        `${game.id} booking and ledger snapshots disagree.`,
      );
    }
  }
}

function verifyDenormalizedRatingChanges(
  bookings: BookingRow[],
  appearances: AppearanceRow[],
  events: RatingEventRow[],
) {
  for (const event of events) {
    if (event.source_type === "OPEN_QUEUE") {
      const booking = bookings.find((candidate) =>
        candidate.game_id === event.source_id &&
        candidate.profile_id === event.profile_id
      );
      assert(
        booking?.rating_change === event.rating_change,
        `${event.id} does not match its Open Queue booking rating change.`,
      );
      continue;
    }

    const appearance = appearances.find((candidate) =>
      candidate.fixture_id === event.source_id &&
      candidate.profile_id === event.profile_id
    );
    assert(
      appearance?.rating_change === event.rating_change,
      `${event.id} does not match its fixture appearance rating change.`,
    );
  }
}

function assertRoleSplit(
  players: BookingRow[],
  gameId: string,
  team: string,
) {
  const counts = new Map<string, number>();
  for (const player of players) {
    counts.set(player.role, (counts.get(player.role) ?? 0) + 1);
  }
  assert(
    players.length === 6 && counts.get("GK") === 1 &&
      counts.get("DEF") === 2 && counts.get("MID") === 2 &&
      counts.get("ATT") === 1,
    `${gameId} ${team} does not preserve the 1/2/2/1 role split.`,
  );
}

function chooseTwo(players: BookingRow[]) {
  const choices: Array<[BookingRow, BookingRow]> = [];
  for (let first = 0; first < players.length; first += 1) {
    for (let second = first + 1; second < players.length; second += 1) {
      choices.push([players[first], players[second]]);
    }
  }
  return choices;
}

function sumSr(players: BookingRow[]) {
  return players.reduce(
    (sum, player) => sum + Number(player.rating_at_team_assignment),
    0,
  );
}

function round2(value: number) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function snapshotAssignment(game: GameRow, bookings: BookingRow[]) {
  return JSON.stringify({
    teamsAssignedAt: game.teams_assigned_at,
    whiteAverage: Number(game.white_average_sr),
    blackAverage: Number(game.black_average_sr),
    matchAverage: Number(game.match_average_sr),
    spread: Number(game.team_sr_spread),
    players: bookings.toSorted((left, right) => left.id.localeCompare(right.id))
      .map((booking) => ({
        id: booking.id,
        team: booking.team,
        rating: booking.rating_at_team_assignment,
      })),
  });
}

function asObject(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return asObject(value[0]);
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
