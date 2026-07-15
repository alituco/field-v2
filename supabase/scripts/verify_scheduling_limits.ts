import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.86.0";

type ProfileRow = { id: string; phone: string };
type FixtureSlot = {
  matchDate: string;
  timeSlot: "7:00 PM - 8:00 PM";
};
type FixtureRow = { id: string; status: string };
type GameRow = { id: string; starts_at: string };
type RpcError = { message: string };
type FixtureAttempt = {
  slot: FixtureSlot;
  fixture: FixtureRow | null;
  error: RpcError | null;
};
type BookingAttempt = {
  game: GameRow;
  bookingId: string | null;
  error: RpcError | null;
};

const CLAN_LIMIT_ERROR =
  "Your clan can have a maximum of 2 upcoming matches. Finish or cancel one before scheduling another.";
const SOLO_LIMIT_ERROR =
  "You can have a maximum of 2 upcoming solo games. Cancel one before booking another.";

const url = requireEnv("SUPABASE_URL");
const publishableKey = requireEnv("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = requireEnv("DEV_SEED_PASSWORD");
const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const userIds = new Set<string>();
const clanIds = new Set<string>();
const fixtureIds = new Set<string>();
const gameIds = new Set<string>();

try {
  const homeProfiles = await createVerificationRoster("Home");
  const awayProfiles = await createVerificationRoster("Away");
  const homeOwner = homeProfiles[0];
  const awayOwner = awayProfiles[0];
  const homeClient = await signedInClient(homeOwner.phone);

  const homeClanId = await createClanWithRoster("Home", homeProfiles);
  const awayClanId = await createClanWithRoster("Away", awayProfiles);
  const slots = await findAvailableFixtureSlots(5);

  await verifyClanSchedulingLimit({
    homeOwner,
    awayOwner,
    homeClanId,
    awayClanId,
    slots,
  });
  await verifySoloSchedulingLimit(homeClient, homeOwner);

  console.log(
    "Scheduling limits verified: clans and solo players stop at 2 upcoming games, concurrent third attempts fail, and CANCELLED/FINAL games release their slots.",
  );
} finally {
  await cleanup();
}

async function verifyClanSchedulingLimit({
  homeOwner,
  awayOwner,
  homeClanId,
  awayClanId,
  slots,
}: {
  homeOwner: ProfileRow;
  awayOwner: ProfileRow;
  homeClanId: string;
  awayClanId: string;
  slots: FixtureSlot[];
}) {
  const firstFixture = await createFixture(
    homeOwner.id,
    homeClanId,
    slots[0],
    "FIRST",
  );
  await joinFixture(firstFixture.id, awayClanId, awayOwner.id);

  const concurrentAttempts = await Promise.all([
    attemptCreateFixture(homeOwner.id, homeClanId, slots[1], "RACE-A"),
    attemptCreateFixture(homeOwner.id, homeClanId, slots[2], "RACE-B"),
  ]);
  const concurrentSuccesses = concurrentAttempts.filter((attempt) =>
    attempt.error === null
  );
  const concurrentFailures = concurrentAttempts.filter((attempt) =>
    attempt.error !== null
  );
  assert(
    concurrentSuccesses.length === 1,
    "Exactly one concurrent clan fixture must claim the second upcoming slot.",
  );
  assert(
    concurrentFailures.length === 1,
    "Exactly one concurrent clan fixture must be rejected at the limit.",
  );
  assertLimitError(
    concurrentFailures[0].error,
    CLAN_LIMIT_ERROR,
    "Concurrent third clan fixture",
  );

  const secondFixture = concurrentSuccesses[0].fixture;
  assert(secondFixture, "The winning clan fixture must be returned.");
  await joinFixture(secondFixture.id, awayClanId, awayOwner.id);

  const awayThirdAttempt = await attemptCreateFixture(
    awayOwner.id,
    awayClanId,
    slots[3],
    "AWAY-THIRD",
  );
  assertLimitError(
    awayThirdAttempt.error,
    CLAN_LIMIT_ERROR,
    "Clan with two away fixtures",
  );
  assert(
    awayThirdAttempt.fixture === null,
    "Two away fixtures must consume the clan's full upcoming allowance.",
  );

  await cancelFixture(firstFixture.id, homeOwner.id);

  const rejectedConcurrentAttempt = concurrentFailures[0];
  const replacementFixture = await createFixture(
    homeOwner.id,
    homeClanId,
    rejectedConcurrentAttempt.slot,
    "AFTER-CANCEL",
  );
  await joinFixture(replacementFixture.id, awayClanId, awayOwner.id);

  await finalizeFixture(secondFixture.id);
  await createFixture(
    homeOwner.id,
    homeClanId,
    slots[3],
    "AFTER-FINAL",
  );

  const homeUpcomingCount = await activeFixtureCount(homeClanId);
  const awayUpcomingCount = await activeFixtureCount(awayClanId);
  assert(
    homeUpcomingCount === 2,
    "The home clan must end with exactly two upcoming fixtures.",
  );
  assert(
    awayUpcomingCount === 1,
    "CANCELLED and FINAL fixtures must no longer count for the away clan.",
  );
}

async function verifySoloSchedulingLimit(
  soloClient: SupabaseClient,
  soloProfile: ProfileRow,
) {
  const games = [
    await createOpenQueueGame(0, "FIRST"),
    await createOpenQueueGame(1, "RACE-A"),
    await createOpenQueueGame(2, "RACE-B"),
    await createOpenQueueGame(3, "AFTER-FINAL"),
  ];

  const firstBookingId = await bookOpenQueueGame(soloClient, games[0]);
  const concurrentAttempts = await Promise.all([
    attemptBookOpenQueueGame(soloClient, games[1]),
    attemptBookOpenQueueGame(soloClient, games[2]),
  ]);
  const concurrentSuccesses = concurrentAttempts.filter((attempt) =>
    attempt.error === null
  );
  const concurrentFailures = concurrentAttempts.filter((attempt) =>
    attempt.error !== null
  );
  assert(
    concurrentSuccesses.length === 1,
    "Exactly one concurrent solo booking must claim the second upcoming slot.",
  );
  assert(
    concurrentFailures.length === 1,
    "Exactly one concurrent solo booking must be rejected at the limit.",
  );
  assertLimitError(
    concurrentFailures[0].error,
    SOLO_LIMIT_ERROR,
    "Concurrent third solo booking",
  );

  const { data: cancelled, error: cancellationError } = await soloClient.rpc(
    "cancel_open_queue_booking",
    { booking_id_to_cancel: firstBookingId },
  );
  if (cancellationError) throw cancellationError;
  assert(
    cancelled?.status === "CANCELLED",
    "Cancelling a solo booking must store CANCELLED status.",
  );

  const rejectedGame = concurrentFailures[0].game;
  await bookOpenQueueGame(soloClient, rejectedGame);

  const secondGame = concurrentSuccesses[0].game;
  const { error: finalError } = await admin
    .from("open_queue_games")
    .update({ status: "FINAL", white_score: 0, black_score: 0 })
    .eq("id", secondGame.id);
  if (finalError) throw finalError;

  await bookOpenQueueGame(soloClient, games[3]);
  const scheduledCount = await activeSoloBookingCount(soloProfile.id);
  assert(
    scheduledCount === 2,
    "A CANCELLED booking and a booking on a FINAL game must not consume solo slots.",
  );
}

async function createVerificationRoster(label: string) {
  const profiles: ProfileRow[] = [];
  for (let index = 1; index <= 7; index += 1) {
    profiles.push(await createVerificationProfile(`${label} ${index}`));
  }
  return profiles;
}

async function createVerificationProfile(label: string): Promise<ProfileRow> {
  const digits = String(Math.floor(10_000_000 + Math.random() * 89_999_999));
  const phone = `+973${digits}`;
  const { data, error } = await admin.auth.admin.createUser({
    phone,
    password,
    phone_confirm: true,
    user_metadata: {
      display_name: `Limit Verify ${label}`,
      date_of_birth: "2000-01-01",
    },
  });
  if (error) throw error;
  userIds.add(data.user.id);

  const { error: profileError } = await admin.from("profiles").upsert({
    id: data.user.id,
    phone,
    display_name: `Limit Verify ${label}`,
    date_of_birth: "2000-01-01",
    username: `limit_verify_${digits}`,
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

async function createClanWithRoster(
  label: string,
  profiles: ProfileRow[],
) {
  assert(profiles.length === 7, "Verification clans require seven profiles.");
  const suffix = crypto.randomUUID().replaceAll("-", "").slice(0, 4)
    .toUpperCase();
  const { data, error } = await admin.from("clans").insert({
    name: `Limit ${label} ${suffix}`,
    tag: `L${suffix}`,
    created_by: profiles[0].id,
    region: "bahrain",
  }).select("id").single();
  if (error) throw error;
  clanIds.add(data.id);

  const { error: membersError } = await admin.from("clan_members").insert(
    profiles.slice(1).map((profile) => ({
      clan_id: data.id,
      profile_id: profile.id,
      role: "member",
    })),
  );
  if (membersError) throw membersError;
  return data.id as string;
}

async function findAvailableFixtureSlots(count: number) {
  const { data, error } = await admin
    .from("fixtures")
    .select("match_date,time_slot")
    .in("status", ["OPEN", "SCHEDULED", "LIVE"])
    .limit(5000);
  if (error) throw error;
  const occupied = new Set(
    (data ?? []).map((fixture) => `${fixture.match_date}|${fixture.time_slot}`),
  );

  const slots: FixtureSlot[] = [];
  const cursor = new Date();
  cursor.setUTCHours(12, 0, 0, 0);
  cursor.setUTCDate(cursor.getUTCDate() + 3650);
  for (
    let dayOffset = 0;
    dayOffset < 730 && slots.length < count;
    dayOffset++
  ) {
    const date = new Date(cursor);
    date.setUTCDate(cursor.getUTCDate() + dayOffset);
    if (date.getUTCDay() !== 2 && date.getUTCDay() !== 5) continue;

    const matchDate = date.toISOString().slice(0, 10);
    const timeSlot = "7:00 PM - 8:00 PM" as const;
    if (!occupied.has(`${matchDate}|${timeSlot}`)) {
      slots.push({ matchDate, timeSlot });
    }
  }
  assert(slots.length === count, "Could not find enough free fixture slots.");
  return slots;
}

async function createFixture(
  createdBy: string,
  clanId: string,
  slot: FixtureSlot,
  suffix: string,
) {
  const attempt = await attemptCreateFixture(createdBy, clanId, slot, suffix);
  if (attempt.error) throw attempt.error;
  assert(attempt.fixture, "Fixture creation returned no fixture.");
  return attempt.fixture;
}

async function attemptCreateFixture(
  createdBy: string,
  clanId: string,
  slot: FixtureSlot,
  suffix: string,
): Promise<FixtureAttempt> {
  const { data, error } = await admin.from("fixtures").insert({
    home_clan_id: clanId,
    venue: `Limit Verify ${suffix}`,
    day: fixtureDay(slot.matchDate),
    time_slot: slot.timeSlot,
    match_date: slot.matchDate,
    created_by: createdBy,
    home_paid_by: createdBy,
    home_paid_at: new Date().toISOString(),
  }).select("id,status").single();
  const fixture = data as FixtureRow | null;
  if (fixture?.id) fixtureIds.add(fixture.id);
  return { slot, fixture, error };
}

async function joinFixture(
  fixtureId: string,
  clanId: string,
  paidBy: string,
) {
  const { data, error } = await admin.from("fixtures").update({
    away_clan_id: clanId,
    status: "SCHEDULED",
    away_paid_by: paidBy,
    away_paid_at: new Date().toISOString(),
  }).eq("id", fixtureId).select("id,status").single();
  if (error) throw error;
  assert(
    data?.status === "SCHEDULED",
    "Joining a fixture must schedule it.",
  );
}

async function cancelFixture(fixtureId: string, cancelledBy: string) {
  const { data, error } = await admin.from("fixtures").update({
    status: "CANCELLED",
    cancellation_code: "ADMIN_CANCELLED",
    cancellation_reason: "Scheduling limit verification cancellation.",
    cancelled_at: new Date().toISOString(),
    cancelled_by: cancelledBy,
    cancellation_context: { source: "SCHEDULING_LIMIT_VERIFICATION" },
  }).eq("id", fixtureId).select("status").single();
  if (error) throw error;
  assert(data.status === "CANCELLED", "Fixture cancellation must persist.");
}

async function finalizeFixture(fixtureId: string) {
  const { data, error } = await admin.from("fixtures").update({
    status: "FINAL",
    home_score: 0,
    away_score: 0,
    winner_clan_id: null,
  }).eq("id", fixtureId).select("status").single();
  if (error) throw error;
  assert(data.status === "FINAL", "Fixture final status must persist.");
}

async function activeFixtureCount(clanId: string) {
  const now = new Date().toISOString();
  const { data, error } = await admin
    .from("fixtures")
    .select("id,match_date,time_slot")
    .in("status", ["OPEN", "SCHEDULED"])
    .or(`home_clan_id.eq.${clanId},away_clan_id.eq.${clanId}`);
  if (error) throw error;
  return (data ?? []).filter((fixture) =>
    fixtureStartAt(fixture.match_date, fixture.time_slot) > now
  ).length;
}

async function createOpenQueueGame(slotOffset: number, suffix: string) {
  const startsAt = futureBahrainOpenQueueStart(slotOffset);
  const { data, error } = await admin.from("open_queue_games").insert({
    venue: `[LIMIT VERIFY ${suffix}] ${crypto.randomUUID().slice(0, 8)}`,
    starts_at: startsAt.toISOString(),
    ends_at: new Date(startsAt.getTime() + 60 * 60 * 1000).toISOString(),
    price_fils: 3000,
  }).select("id,starts_at").single();
  if (error) throw error;
  gameIds.add(data.id);
  return data as GameRow;
}

async function bookOpenQueueGame(
  client: SupabaseClient,
  game: GameRow,
) {
  const attempt = await attemptBookOpenQueueGame(client, game);
  if (attempt.error) throw attempt.error;
  assert(attempt.bookingId, "Solo booking returned no booking id.");
  return attempt.bookingId;
}

async function attemptBookOpenQueueGame(
  client: SupabaseClient,
  game: GameRow,
): Promise<BookingAttempt> {
  const { data, error } = await client.rpc("book_open_queue_game", {
    game_id_to_book: game.id,
    role_to_book: "MID",
    payment_method_to_use: "MOCK",
    payment_reference_to_use: crypto.randomUUID(),
  });
  return { game, bookingId: data as string | null, error };
}

async function activeSoloBookingCount(profileId: string) {
  const { data: bookings, error: bookingsError } = await admin
    .from("open_queue_bookings")
    .select("game_id")
    .eq("profile_id", profileId)
    .eq("status", "CONFIRMED");
  if (bookingsError) throw bookingsError;
  const bookedGameIds = (bookings ?? []).map((booking) => booking.game_id);
  if (bookedGameIds.length === 0) return 0;

  const { data: games, error: gamesError } = await admin
    .from("open_queue_games")
    .select("id")
    .in("id", bookedGameIds)
    .in("status", ["OPEN", "FULL"])
    .gt("starts_at", new Date().toISOString());
  if (gamesError) throw gamesError;
  return games?.length ?? 0;
}

function fixtureStartAt(matchDate: string, timeSlot: string) {
  assert(
    timeSlot === "7:00 PM - 8:00 PM",
    "Clan fixtures must use the 7:00 PM - 8:00 PM slot.",
  );
  return new Date(`${matchDate}T19:00:00+03:00`).toISOString();
}

function fixtureDay(matchDate: string) {
  const weekday = new Date(`${matchDate}T12:00:00Z`).getUTCDay();
  assert(
    weekday === 2 || weekday === 5,
    "Verification fixtures must be on Tuesday or Friday.",
  );
  return weekday === 2 ? "TUESDAY" : "FRIDAY";
}

function futureBahrainOpenQueueStart(slotOffset: number) {
  assert(
    Number.isInteger(slotOffset) && slotOffset >= 0,
    "Open Queue slot offset must be a non-negative integer.",
  );
  const nowInBahrain = new Date(Date.now() + 3 * 60 * 60 * 1000);
  let matchingSlot = 0;
  for (let daysAhead = 3650; daysAhead < 4020; daysAhead += 1) {
    const localDate = new Date(Date.UTC(
      nowInBahrain.getUTCFullYear(),
      nowInBahrain.getUTCMonth(),
      nowInBahrain.getUTCDate() + daysAhead,
      12,
    ));
    const weekday = localDate.getUTCDay();
    if (weekday !== 2 && weekday !== 5) continue;
    if (matchingSlot !== slotOffset) {
      matchingSlot += 1;
      continue;
    }
    return new Date(Date.UTC(
      localDate.getUTCFullYear(),
      localDate.getUTCMonth(),
      localDate.getUTCDate(),
      17,
      30,
    ));
  }
  throw new Error("Could not find a future Tuesday/Friday Open Queue slot.");
}

async function cleanup() {
  if (gameIds.size > 0) {
    const { error } = await admin.from("open_queue_games").delete().in(
      "id",
      [...gameIds],
    );
    if (error) console.error("Could not clean up games:", error.message);
  }
  if (fixtureIds.size > 0) {
    const { error } = await admin.from("fixtures").delete().in(
      "id",
      [...fixtureIds],
    );
    if (error) console.error("Could not clean up fixtures:", error.message);
  }
  if (clanIds.size > 0) {
    const { error } = await admin.from("clans").delete().in(
      "id",
      [...clanIds],
    );
    if (error) console.error("Could not clean up clans:", error.message);
  }
  for (const userId of userIds) {
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) console.error("Could not clean up user:", error.message);
  }
}

function assertLimitError(
  error: RpcError | null,
  expectedMessage: string,
  context: string,
) {
  assert(error, `${context} must be rejected.`);
  assert(
    error.message.includes(expectedMessage),
    `${context} returned the wrong error: ${error.message}`,
  );
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
