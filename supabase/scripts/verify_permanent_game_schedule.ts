import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type FixtureRow = {
  id: string;
  status: string;
  day: string;
  time_slot: string;
  match_date: string;
  venue: string;
  home_clan_id: string;
  away_clan_id: string | null;
  home_score: number | null;
  away_score: number | null;
  created_by: string;
};

type GameRow = {
  id: string;
  status: string;
  venue: string;
  starts_at: string;
  ends_at: string;
  timezone: string;
  white_score: number | null;
  black_score: number | null;
};

type BookingRow = {
  game_id: string;
  profile_id: string;
  status: string;
  team: string | null;
};

const SEED_PREFIX = "[SCHEDULE SEED]";
const CLAN_SLOT = "7:00 PM - 8:00 PM";
const url = requireEnv("SUPABASE_URL");
const key = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const admin = createClient(url, key, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const [
  fixturesResult,
  gamesResult,
  bookingsResult,
  appearancesResult,
  ratingEventsResult,
  ratingsResult,
  broadcastsResult,
] = await Promise.all([
  admin.from("fixtures").select(
    "id,status,day,time_slot,match_date,venue,home_clan_id,away_clan_id,home_score,away_score,created_by",
  ),
  admin.from("open_queue_games").select(
    "id,status,venue,starts_at,ends_at,timezone,white_score,black_score",
  ),
  admin.from("open_queue_bookings").select(
    "game_id,profile_id,status,team",
  ),
  admin.from("fixture_player_appearances").select(
    "fixture_id,profile_id,played",
  ),
  admin.from("player_rating_events").select(
    "profile_id,source_type,source_id",
  ),
  admin.from("player_ratings").select("profile_id,matches_played"),
  admin.from("fixture_broadcasts").select("fixture_id"),
]);

for (
  const result of [
    fixturesResult,
    gamesResult,
    bookingsResult,
    appearancesResult,
    ratingEventsResult,
    ratingsResult,
    broadcastsResult,
  ]
) {
  if (result.error) throw result.error;
}

const fixtures = (fixturesResult.data ?? []) as FixtureRow[];
const games = (gamesResult.data ?? []) as GameRow[];
const bookings = (bookingsResult.data ?? []) as BookingRow[];
const appearances = appearancesResult.data ?? [];
const ratingEvents = ratingEventsResult.data ?? [];
const ratings = ratingsResult.data ?? [];

assert(fixtures.length >= 8, "Expected historical and upcoming clan games.");
assert(games.length >= 8, "Expected historical and upcoming solo games.");
assert(
  fixtures.every((fixture) => fixture.venue.startsWith(SEED_PREFIX)),
  "The clean slate still contains a clan game outside the schedule seed.",
);
assert(
  games.every((game) => game.venue.startsWith(SEED_PREFIX)),
  "The clean slate still contains a solo game outside the schedule seed.",
);
assert(
  (broadcastsResult.data ?? []).length === 0,
  "Old fixture broadcast metadata still exists.",
);

for (const fixture of fixtures) {
  assert(
    fixture.time_slot === CLAN_SLOT,
    `${fixture.venue} is not in the permanent 7:00 PM clan slot.`,
  );
  const weekday = weekdayForDate(fixture.match_date);
  assert(
    weekday === 2 || weekday === 5,
    `${fixture.venue} is not on Tuesday or Friday.`,
  );
  assert(
    fixture.day === (weekday === 2 ? "TUESDAY" : "FRIDAY"),
    `${fixture.venue} has a day/date mismatch.`,
  );
}

const startsSeen = new Set<string>();
for (const game of games) {
  assert(
    game.timezone === "Asia/Bahrain",
    `${game.venue} has the wrong timezone.`,
  );
  const local = bahrainParts(game.starts_at);
  assert(
    local.weekday === "Tue" || local.weekday === "Fri",
    `${game.venue} is not on Tuesday or Friday in Bahrain.`,
  );
  assert(
    local.hour === "20" && local.minute === "30",
    `${game.venue} does not start at 8:30 PM Bahrain time.`,
  );
  assert(
    new Date(game.ends_at).getTime() - new Date(game.starts_at).getTime() ===
      60 * 60 * 1000,
    `${game.venue} does not end at 9:30 PM.`,
  );
  assert(
    !startsSeen.has(game.starts_at),
    `More than one solo game exists at ${game.starts_at}.`,
  );
  startsSeen.add(game.starts_at);
}

const fixtureDates = new Set(fixtures.map((fixture) => fixture.match_date));
const soloDates = new Set(
  games.map((game) => bahrainParts(game.starts_at).date),
);
assert(
  setsEqual(fixtureDates, soloDates),
  "Clan and solo seed dates are not paired on the same match days.",
);

const finalFixtures = fixtures.filter((fixture) => fixture.status === "FINAL");
const upcomingFixtures = fixtures.filter((fixture) =>
  fixture.status === "OPEN" || fixture.status === "SCHEDULED"
);
const finalGames = games.filter((game) => game.status === "FINAL");
const upcomingGames = games.filter((game) =>
  game.status === "OPEN" || game.status === "FULL"
);
assert(finalFixtures.length >= 4, "Expected completed clan match history.");
assert(upcomingFixtures.length >= 3, "Expected upcoming clan matches.");
assert(finalGames.length >= 4, "Expected completed solo match history.");
assert(upcomingGames.length >= 3, "Expected upcoming solo games.");

for (const fixture of finalFixtures) {
  assert(fixture.away_clan_id, `${fixture.venue} has no away clan.`);
  assert(
    fixture.home_score !== null && fixture.away_score !== null,
    `${fixture.venue} has no final score.`,
  );
  const played = appearances.filter((appearance) =>
    appearance.fixture_id === fixture.id && appearance.played === true
  );
  assert(
    played.length === 14,
    `${fixture.venue} should have exactly seven confirmed players per clan.`,
  );
}

for (const game of finalGames) {
  const confirmed = bookings.filter((booking) =>
    booking.game_id === game.id && booking.status === "CONFIRMED"
  );
  assert(
    confirmed.length === 12,
    `${game.venue} should have twelve historical solo players.`,
  );
  assert(
    confirmed.every((booking) =>
      booking.team === "WHITE" || booking.team === "BLACK"
    ),
    `${game.venue} has historical players without assigned teams.`,
  );
  assert(
    game.white_score !== null && game.black_score !== null,
    `${game.venue} has no final score.`,
  );
}

assert(
  upcomingGames.some((game) =>
    bookings.some((booking) =>
      booking.game_id === game.id && booking.status === "CONFIRMED"
    )
  ),
  "No players were scheduled into upcoming solo games.",
);

const now = Date.now();
const upcomingClanCounts = new Map<string, number>();
for (const fixture of upcomingFixtures) {
  if (fixtureStartAt(fixture.match_date).getTime() <= now) continue;
  increment(upcomingClanCounts, fixture.home_clan_id);
  if (fixture.away_clan_id) increment(upcomingClanCounts, fixture.away_clan_id);
}
assert(
  [...upcomingClanCounts.values()].every((count) => count <= 2),
  "A clan exceeds two upcoming matches.",
);

const upcomingGameIds = new Set(
  upcomingGames
    .filter((game) => new Date(game.starts_at).getTime() > now)
    .map((game) => game.id),
);
const upcomingSoloCounts = new Map<string, number>();
for (const booking of bookings) {
  if (booking.status === "CONFIRMED" && upcomingGameIds.has(booking.game_id)) {
    increment(upcomingSoloCounts, booking.profile_id);
  }
}
assert(
  [...upcomingSoloCounts.values()].every((count) => count <= 2),
  "A player exceeds two upcoming solo games.",
);

const currentFixtureIds = new Set(finalFixtures.map((fixture) => fixture.id));
const currentSoloGameIds = new Set(finalGames.map((game) => game.id));
assert(
  ratingEvents.every((event) =>
    (event.source_type === "CLAN_FIXTURE" &&
      currentFixtureIds.has(String(event.source_id))) ||
    (event.source_type === "OPEN_QUEUE" &&
      currentSoloGameIds.has(String(event.source_id)))
  ),
  "A rating event from the deleted game slate still exists.",
);
const eventCounts = new Map<string, number>();
for (const event of ratingEvents) {
  increment(eventCounts, String(event.profile_id));
}
for (const rating of ratings) {
  assert(
    Number(rating.matches_played) ===
      (eventCounts.get(String(rating.profile_id)) ?? 0),
    "Player rating aggregates do not match the new rated match ledger.",
  );
}
assert(
  [...eventCounts.values()].filter((count) => count >= 2).length >= 14,
  "The new history does not produce enough season-ranking eligible players.",
);

await verifyDatabaseRejectsInvalidSchedules(fixtures, games);

console.log(
  `Permanent schedule verified: ${fixtures.length} clan games, ` +
    `${games.length} solo games, ${finalFixtures.length + finalGames.length} ` +
    "completed games, paired Tuesday/Friday slots, and both two-game caps.",
);

async function verifyDatabaseRejectsInvalidSchedules(
  fixtureRows: FixtureRow[],
  gameRows: GameRow[],
) {
  const fixture = fixtureRows[0];
  const invalidFixture = await admin.from("fixtures").insert({
    status: "FINAL",
    home_clan_id: fixture.home_clan_id,
    venue: `${SEED_PREFIX} Invalid Clan Slot`,
    day: fixture.day,
    time_slot: "8:30 PM - 9:30 PM",
    match_date: fixture.match_date,
    created_by: fixture.created_by,
    home_paid_by: fixture.created_by,
    home_paid_at: new Date().toISOString(),
  }).select("id").maybeSingle();
  if (invalidFixture.data?.id) {
    await admin.from("fixtures").delete().eq("id", invalidFixture.data.id);
  }
  assert(
    invalidFixture.error?.message.includes("fixtures_time_slot_check"),
    "The database did not reject a late clan fixture with the schedule constraint.",
  );

  const game = gameRows[0];
  const invalidStart = new Date(game.starts_at);
  invalidStart.setUTCHours(invalidStart.getUTCHours() - 1);
  const invalidSolo = await admin.from("open_queue_games").insert({
    venue: `${SEED_PREFIX} Invalid Solo Slot`,
    starts_at: invalidStart.toISOString(),
    ends_at: new Date(invalidStart.getTime() + 60 * 60 * 1000).toISOString(),
    timezone: "Asia/Bahrain",
  }).select("id").maybeSingle();
  if (invalidSolo.data?.id) {
    await admin.from("open_queue_games").delete().eq("id", invalidSolo.data.id);
  }
  assert(
    invalidSolo.error?.message.includes(
      "Open Queue games must start at 8:30 PM Bahrain time.",
    ),
    "The database did not reject a 7:30 PM solo game with the schedule rule.",
  );

  const duplicateSolo = await admin.from("open_queue_games").insert({
    venue: `${SEED_PREFIX} Duplicate Solo Slot`,
    starts_at: game.starts_at,
    ends_at: game.ends_at,
    timezone: "Asia/Bahrain",
  }).select("id").maybeSingle();
  if (duplicateSolo.data?.id) {
    await admin.from("open_queue_games").delete().eq(
      "id",
      duplicateSolo.data.id,
    );
  }
  assert(
    duplicateSolo.error?.message.includes(
      "An Open Queue game already exists at that start time.",
    ),
    "The database accepted a second solo game in the same slot.",
  );
}

function bahrainParts(iso: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Bahrain",
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(iso));
  const value = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value ?? "";
  return {
    weekday: value("weekday"),
    hour: value("hour"),
    minute: value("minute"),
    date: `${value("year")}-${value("month")}-${value("day")}`,
  };
}

function weekdayForDate(date: string) {
  return new Date(`${date}T12:00:00Z`).getUTCDay();
}

function fixtureStartAt(date: string) {
  return new Date(`${date}T16:00:00Z`);
}

function increment(counts: Map<string, number>, key: string) {
  counts.set(key, (counts.get(key) ?? 0) + 1);
}

function setsEqual(left: Set<string>, right: Set<string>) {
  return left.size === right.size &&
    [...left].every((value) => right.has(value));
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
