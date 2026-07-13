import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.86.0";

type ProfileRow = { id: string; phone: string | null };

const url = requireEnv("SUPABASE_URL");
const publishableKey = requireEnv("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = requireEnv("DEV_SEED_PASSWORD");
const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const testGameIds: string[] = [];
const testUserIds: string[] = [];
let first: ProfileRow;
let second: ProfileRow;
let participants: ProfileRow[];
let firstClient: SupabaseClient;
let secondClient: SupabaseClient;

try {
  first = await createVerificationProfile("One");
  second = await createVerificationProfile("Two");

  const { data: profileRows, error: profilesError } = await admin
    .from("profiles")
    .select("id,phone")
    .not("phone", "is", null)
    .order("created_at")
    .limit(40);
  if (profilesError) throw profilesError;

  const profiles = (profileRows ?? []) as ProfileRow[];
  participants = [
    first,
    second,
    ...profiles.filter((profile) =>
      profile.id !== first.id && profile.id !== second.id
    ),
  ].slice(0, 12);
  assert(
    participants.length === 12,
    "Open Queue verification needs 12 profiles.",
  );

  firstClient = await signedInClient(first.phone!);
  secondClient = await signedInClient(second.phone!);

  const { data: ownRatings, error: ownRatingError } = await firstClient.rpc(
    "get_my_player_rating",
  );
  if (ownRatingError) throw ownRatingError;
  assert(
    ownRatings.length === 1 && ownRatings[0].profile_id === first.id,
    "The current-player rating RPC must return the signed-in player's row.",
  );

  await verifyFinalRoleRace();
  await verifyWaitlistStateIsRejected();
  await verifyFullGameReopensWithHalfRefund();
  await verifyGameDayCancellationHasNoRefund();
  console.log(
    "Open Queue verified: atomic final spot, no waitlist state, hard caps, FULL→OPEN, 50% before game day, and 0% on game day.",
  );
} finally {
  if (testGameIds.length > 0) {
    const { error } = await admin.from("open_queue_games").delete().in(
      "id",
      testGameIds,
    );
    if (error) {
      console.error(
        "Could not clean up Open Queue verification games:",
        error.message,
      );
    }
  }
  for (const userId of testUserIds) {
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) {
      console.error(
        "Could not clean up Open Queue verification user:",
        error.message,
      );
    }
  }
}

async function verifyFinalRoleRace() {
  const game = await createGame(futureBahrainStart(4, 18), "RACE");
  await insertBooking(game.id, participants[2], "GK", "verify-race-existing");

  const calls = [firstClient, secondClient].map((client) =>
    client.rpc("book_open_queue_game", {
      game_id_to_book: game.id,
      role_to_book: "GK",
      payment_method_to_use: "MOCK",
      payment_reference_to_use: crypto.randomUUID(),
    })
  );
  const results = await Promise.all(calls);
  const successes = results.filter((result) => result.error === null);
  const failures = results.filter((result) => result.error !== null);
  assert(
    successes.length === 1,
    "Exactly one player must win the final goalkeeper spot.",
  );
  assert(
    failures.length === 1,
    "Exactly one final-spot booking must be rejected.",
  );
  assert(
    failures[0].error!.message.includes("position just filled"),
    "The losing booking should receive the position-filled business error.",
  );
}

async function verifyFullGameReopensWithHalfRefund() {
  const game = await createGame(futureBahrainStart(6, 18), "FULL");
  const roles = [
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
  ];
  for (let index = 0; index < participants.length; index += 1) {
    await insertBooking(
      game.id,
      participants[index],
      roles[index],
      `verify-full-${index}`,
    );
  }

  const { data: fullGame, error: fullGameError } = await admin
    .from("open_queue_games")
    .select("status")
    .eq("id", game.id)
    .single();
  if (fullGameError) throw fullGameError;
  assert(
    fullGame.status === "FULL",
    "The twelfth confirmed booking must mark a game FULL.",
  );

  const booking = await ownBooking(firstClient, game.id);
  const { data: previews, error: previewError } = await firstClient.rpc(
    "preview_open_queue_cancellation",
    { booking_id_to_preview: booking.id },
  );
  if (previewError) throw previewError;
  assert(
    previews[0].refund_percent === 50,
    "A pre-game-day cancellation must refund 50%.",
  );

  const { data: cancelled, error: cancelError } = await firstClient.rpc(
    "cancel_open_queue_booking",
    { booking_id_to_cancel: booking.id },
  );
  if (cancelError) throw cancelError;
  assert(
    cancelled.refund_percent === 50,
    "The stored refund must be 50% before game day.",
  );

  const { data: reopened, error: reopenedError } = await admin
    .from("open_queue_games")
    .select("status")
    .eq("id", game.id)
    .single();
  if (reopenedError) throw reopenedError;
  assert(
    reopened.status === "OPEN",
    "Cancelling from a full game must reopen the slot.",
  );
}

async function verifyWaitlistStateIsRejected() {
  const game = await createGame(futureBahrainStart(5, 18), "NO-WAITLIST");
  const { data: rating, error: ratingError } = await admin
    .from("player_ratings")
    .select("skill_rating")
    .eq("profile_id", first.id)
    .single();
  if (ratingError) throw ratingError;

  const { error } = await admin.from("open_queue_bookings").insert({
    game_id: game.id,
    profile_id: first.id,
    role: "MID",
    status: "WAITLIST",
    player_rating_at_booking: rating.skill_rating,
    amount_paid_fils: 3000,
    payment_method: "MOCK",
  });
  assert(
    error !== null,
    "The database must reject every waitlist booking state.",
  );
}

async function verifyGameDayCancellationHasNoRefund() {
  const nowInBahrain = new Date(Date.now() + 3 * 60 * 60 * 1000);
  const startsAt = new Date(Date.UTC(
    nowInBahrain.getUTCFullYear(),
    nowInBahrain.getUTCMonth(),
    nowInBahrain.getUTCDate(),
    17,
  ));
  assert(
    startsAt.getTime() > Date.now(),
    "Run game-day verification before 8 PM Bahrain.",
  );

  const game = await createGame(startsAt, "GAME-DAY");
  const { data: bookingId, error: bookingError } = await firstClient.rpc(
    "book_open_queue_game",
    {
      game_id_to_book: game.id,
      role_to_book: "MID",
      payment_method_to_use: "MOCK",
      payment_reference_to_use: crypto.randomUUID(),
    },
  );
  if (bookingError) throw bookingError;

  const { data: previews, error: previewError } = await firstClient.rpc(
    "preview_open_queue_cancellation",
    { booking_id_to_preview: bookingId },
  );
  if (previewError) throw previewError;
  assert(
    previews[0].refund_percent === 0,
    "A game-day cancellation must have no refund.",
  );

  const { data: cancelled, error: cancelError } = await firstClient.rpc(
    "cancel_open_queue_booking",
    { booking_id_to_cancel: bookingId },
  );
  if (cancelError) throw cancelError;
  assert(
    cancelled.refund_percent === 0,
    "A game-day cancellation must store a 0% refund.",
  );
}

async function createGame(startsAt: Date, suffix: string) {
  const { data, error } = await admin
    .from("open_queue_games")
    .insert({
      venue: `[OQ VERIFY ${suffix}] ${crypto.randomUUID().slice(0, 8)}`,
      starts_at: startsAt.toISOString(),
      ends_at: new Date(startsAt.getTime() + 60 * 60 * 1000).toISOString(),
      price_fils: 3000,
    })
    .select("id")
    .single();
  if (error) throw error;
  testGameIds.push(data.id);
  return data as { id: string };
}

async function insertBooking(
  gameId: string,
  profile: ProfileRow,
  role: string,
  paymentReference: string,
) {
  const { data: rating, error: ratingError } = await admin
    .from("player_ratings")
    .select("skill_rating")
    .eq("profile_id", profile.id)
    .single();
  if (ratingError) throw ratingError;
  const { error } = await admin.from("open_queue_bookings").insert({
    game_id: gameId,
    profile_id: profile.id,
    role,
    player_rating_at_booking: rating.skill_rating,
    amount_paid_fils: 3000,
    payment_method: "MOCK",
    payment_reference: paymentReference,
  });
  if (error) throw error;
}

async function ownBooking(
  client: SupabaseClient,
  gameId: string,
) {
  const { data, error } = await client
    .from("open_queue_bookings")
    .select("id")
    .eq("game_id", gameId)
    .eq("status", "CONFIRMED")
    .single();
  if (error) throw error;
  return data as { id: string };
}

async function signedInClient(phone: string) {
  const client = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { error } = await client.auth.signInWithPassword({ phone, password });
  if (error) throw error;
  return client;
}

async function createVerificationProfile(label: string): Promise<ProfileRow> {
  const digits = String(Math.floor(10_000_000 + Math.random() * 89_999_999));
  const phone = `+973${digits}`;
  const { data, error } = await admin.auth.admin.createUser({
    phone,
    password,
    phone_confirm: true,
    user_metadata: { display_name: `Open Queue Verify ${label}` },
  });
  if (error) throw error;
  testUserIds.push(data.user.id);

  const { error: profileError } = await admin.from("profiles").upsert({
    id: data.user.id,
    phone,
    display_name: `Open Queue Verify ${label}`,
    username: `oq_verify_${digits}`,
  });
  if (profileError) throw profileError;
  return { id: data.user.id, phone };
}

function futureBahrainStart(daysAhead: number, localHour: number) {
  const nowInBahrain = new Date(Date.now() + 3 * 60 * 60 * 1000);
  return new Date(Date.UTC(
    nowInBahrain.getUTCFullYear(),
    nowInBahrain.getUTCMonth(),
    nowInBahrain.getUTCDate() + daysAhead,
    localHour - 3,
  ));
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
