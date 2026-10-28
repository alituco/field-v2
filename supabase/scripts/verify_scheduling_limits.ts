import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.86.0";
import { assertSafeDevDataTarget } from "./_shared/environment_guard.ts";
import { completeLocalFieldrushFixture } from "./_shared/fieldrush_fixture.ts";

type ProfileRow = { id: string; phone: string };
type GameRow = { id: string; starts_at: string };
type RpcError = { message: string };
type BookingAttempt = {
  game: GameRow;
  bookingId: string | null;
  error: RpcError | null;
};
const SOLO_LIMIT_ERROR =
  "You can only be registered in one upcoming or active game.";
const CHECKOUT_LIMIT_ERROR = "Finish or cancel your earlier game checkout";
const CLAN_PAUSED_ERROR = "Clan games are currently paused.";
const url = requireEnv("SUPABASE_URL");
assert(
  assertSafeDevDataTarget(url, "scheduling-limit verification").environment ===
    "local",
  "Synthetic captured-payment verification is local-only.",
);
const publishableKey = requireEnv("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = requireEnv("DEV_SEED_PASSWORD");
const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const userIds = new Set<string>();
const gameIds = new Set<string>();
const intentIds = new Set<string>();
const slotSeed = 5000 + crypto.getRandomValues(new Uint32Array(1))[0] % 1000;

try {
  const profile = await createVerificationProfile();
  const client = await signedInClient(profile.phone);
  await verifyClanCheckoutPaused(client, profile);
  await verifySoloSchedulingLimit(client, profile);
  console.log(
    "Scheduling verified locally: clan checkout stays paused at its future USD 80 default; 7v7/USD 13 solo bookings enforce one upcoming/active game, concurrent checkout limits, original-method refunds and released terminal slots.",
  );
} finally {
  await cleanup();
}

async function verifyClanCheckoutPaused(
  client: SupabaseClient,
  profile: ProfileRow,
) {
  const { data: settings, error: settingsError } = await client.rpc(
    "get_game_payment_settings",
  );
  if (settingsError) throw settingsError;
  assert(
    settings.clan_enabled === false && settings.currency === "USD" &&
      settings.clan_price_fils === 80000,
    "Fresh settings must leave clans paused with the future USD 80 team fee.",
  );
  const clanId = crypto.randomUUID();
  const fixtureId = crypto.randomUUID();
  const matchDate = "2040-01-03";
  const createArgs = {
    clan_id_to_use: clanId,
    match_date_to_use: matchDate,
    time_slot_to_use: "7:00 PM - 8:00 PM",
  };
  for (
    const [name, args] of [
      ["preview_create_clan_fixture_charge", createArgs],
      ["preview_join_clan_fixture_charge", {
        fixture_id_to_use: fixtureId,
        clan_id_to_use: clanId,
      }],
    ] as const
  ) {
    const { error } = await client.rpc(name, args);
    assertError(error, CLAN_PAUSED_ERROR, name);
  }
  for (
    const [name, args] of [
      ["create_fixture", {
        home_clan_id_to_use: clanId,
        fixture_venue: "Limit verification",
        fixture_date: matchDate,
        fixture_time_slot: "7:00 PM - 8:00 PM",
      }],
      ["join_fixture", {
        fixture_id_to_join: fixtureId,
        away_clan_id_to_use: clanId,
      }],
    ] as const
  ) {
    const { error } = await admin.rpc(name, args);
    assertError(error, CLAN_PAUSED_ERROR, name);
  }
  const { error } = await admin.from("fixtures").insert({
    id: fixtureId,
    home_clan_id: clanId,
    venue: "Limit verification",
    day: "TUESDAY",
    match_date: matchDate,
    time_slot: "7:00 PM - 8:00 PM",
    created_by: profile.id,
  });
  assertError(error, CLAN_PAUSED_ERROR, "Direct fixture insertion");
}

async function verifySoloSchedulingLimit(
  client: SupabaseClient,
  profile: ProfileRow,
) {
  const games = await Promise.all([0, 1, 2, 3].map(createOpenQueueGame));
  const attempts = await Promise.all([
    attemptBookOpenQueueGame(client, games[0]),
    attemptBookOpenQueueGame(client, games[1]),
  ]);
  const successes = attempts.filter((attempt) => attempt.error === null);
  const failures = attempts.filter((attempt) => attempt.error !== null);
  assert(
    successes.length === 1 && failures.length === 1,
    "Exactly one concurrent solo checkout may claim the only upcoming slot.",
  );
  assert(
    failures[0].error?.message.includes(SOLO_LIMIT_ERROR) === true ||
      failures[0].error?.message.includes(CHECKOUT_LIMIT_ERROR) === true,
    `The concurrent second checkout returned the wrong error: ${
      failures[0].error?.message
    }`,
  );
  const firstBooking = successes[0].bookingId;
  assert(firstBooking, "The winning checkout returned no booking id.");
  assert(
    await activeSoloBookingCount(profile.id) === 1,
    "Concurrent checkouts must leave exactly one active registration.",
  );
  const priorIntentCount = intentIds.size;
  const secondGame = await attemptBookOpenQueueGame(client, games[2]);
  assertError(
    secondGame.error,
    SOLO_LIMIT_ERROR,
    "Non-overlapping second game",
  );
  assert(
    intentIds.size === priorIntentCount,
    "The single-game preflight must reject a second day before a payment intent exists.",
  );

  const { data: cancelled, error } = await client.rpc(
    "cancel_open_queue_booking",
    { booking_id_to_cancel: firstBooking },
  );
  if (error) throw error;
  assert(
    cancelled.status === "CANCELLED" &&
      cancelled.refund_destination === "ORIGINAL_PAYMENT_METHOD",
    "Cancellation must release the slot and return new payment money to its original method.",
  );
  const { data: refunds, error: refundsError } = await admin.from(
    "payment_refunds",
  ).select("currency,status,provider_status")
    .eq("intent_id", cancelled.payment_intent_id);
  if (refundsError) throw refundsError;
  assert(
    refunds.length === 1 && refunds[0].currency === "USD" &&
      refunds[0].status === "SUCCEEDED" &&
      refunds[0].provider_status === "staging_e2e",
    "Local synthetic cancellation must record a settled USD original-method refund without external calls.",
  );
  const { data: credits, error: creditError } = await admin.from(
    "field_wallet_transactions",
  ).select("id").eq("booking_id", firstBooking);
  if (creditError) throw creditError;
  assert(
    credits.length === 0,
    "A new-payment cancellation must not credit Field Wallet.",
  );

  await bookOpenQueueGame(client, games[2]);
  const { error: terminalError } = await admin.from("open_queue_games").update({
    status: "CANCELLED",
    cancellation_code: "ADMIN_DECISION",
    cancellation_reason:
      "Scheduling-limit verification terminal-state transition.",
    cancelled_at: new Date().toISOString(),
    cancelled_by: profile.id,
    cancellation_context: { source: "SCHEDULING_LIMIT_VERIFICATION" },
  }).eq("id", games[2].id);
  if (terminalError) throw terminalError;
  await bookOpenQueueGame(client, games[3]);
  assert(
    await activeSoloBookingCount(profile.id) === 1,
    "Cancelled bookings and terminal games must release the sole upcoming slot.",
  );
}

async function createVerificationProfile(): Promise<ProfileRow> {
  const digits = String(Math.floor(1_000_000 + Math.random() * 8_999_999));
  const phone = `+1480${digits}`;
  const { data, error } = await admin.auth.admin.createUser({
    phone,
    password,
    phone_confirm: true,
    user_metadata: {
      display_name: "Scheduling Verification",
      date_of_birth: "2000-01-01",
    },
  });
  if (error) throw error;
  userIds.add(data.user.id);
  await completeLocalFieldrushFixture({
    url,
    publishableKey,
    phone,
    password,
    firstName: "Scheduling",
    lastName: "Verification",
    username: `limit_verify_${digits}`,
    dateOfBirth: "2000-01-01",
  });
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

async function createOpenQueueGame(slotOffset: number): Promise<GameRow> {
  const startsAt = futurePhoenixOpenQueueStart(slotOffset);
  const { data, error } = await admin.from("open_queue_games").insert({
    format_version: "FIELDRUSH_7V7",
    currency: "USD",
    timezone: "America/Phoenix",
    capacity: 14,
    goalkeeper_capacity: 2,
    defender_capacity: 6,
    midfielder_capacity: 0,
    attacker_capacity: 6,
    venue: `[LIMIT VERIFY ${slotOffset}] ${crypto.randomUUID().slice(0, 8)}`,
    starts_at: startsAt.toISOString(),
    ends_at: new Date(startsAt.getTime() + 3600_000).toISOString(),
    price_fils: 13000,
  }).select("id,starts_at").single();
  if (error) throw error;
  gameIds.add(data.id);
  return data;
}

async function bookOpenQueueGame(client: SupabaseClient, game: GameRow) {
  const attempt = await attemptBookOpenQueueGame(client, game);
  if (attempt.error) throw attempt.error;
  assert(attempt.bookingId, "Solo booking returned no booking id.");
  return attempt.bookingId;
}

async function attemptBookOpenQueueGame(
  client: SupabaseClient,
  game: GameRow,
): Promise<BookingAttempt> {
  const { data: user, error: userError } = await client.auth.getUser();
  if (userError || !user.user) {
    throw userError ?? new Error("Verification user is signed out.");
  }
  const { data: quote, error: quoteError } = await client.rpc(
    "preview_open_queue_booking_cost",
    { game_id_to_book: game.id, role_to_book: "DEF" },
  );
  if (quoteError) return { game, bookingId: null, error: quoteError };
  assert(
    quote.currency === "USD" && quote.total_fils === 13000,
    "Solo quote must remain USD 13.",
  );
  const id = crypto.randomUUID();
  const compact = id.replaceAll("-", "");
  const { error: insertError } = await admin.from("payment_intents").insert({
    id,
    profile_id: user.user.id,
    purpose: "SOLO_BOOKING",
    status: "CAPTURED",
    provider: "STAGING_E2E",
    currency: quote.currency,
    amount_fils: quote.total_fils,
    payload: { game_id: game.id, role: "DEF" },
    quote_snapshot: quote,
    transaction_reference: `field_limit_${compact}`,
    provider_intent_id: `field_e2e_intent_${compact}`,
    provider_payment_id: `field_e2e_${compact}`,
    payment_method: "CARD",
    provider_status: "SUCCEEDED",
    captured_at: new Date().toISOString(),
  });
  if (insertError) return { game, bookingId: null, error: insertError };
  intentIds.add(id);
  const { data, error } = await admin.rpc("finalize_payment_intent", {
    intent_id_to_finalize: id,
  });
  return {
    game,
    bookingId: data?.resource_id ?? null,
    error: error ??
      (data?.status === "FINALIZED"
        ? null
        : { message: data?.failure_reason ?? "Payment finalization failed." }),
  };
}

async function activeSoloBookingCount(profileId: string) {
  const { data: bookings, error } = await admin.from("open_queue_bookings")
    .select("game_id").eq("profile_id", profileId).eq("status", "CONFIRMED");
  if (error) throw error;
  if (!bookings.length) return 0;
  const { data: games, error: gameError } = await admin.from("open_queue_games")
    .select("id")
    .in("id", bookings.map((booking) => booking.game_id)).in("status", [
      "OPEN",
      "FULL",
    ]).gt("starts_at", new Date().toISOString());
  if (gameError) throw gameError;
  return games.length;
}

function futurePhoenixOpenQueueStart(slotOffset: number) {
  const local = new Date(Date.now() - 7 * 3600_000);
  let found = 0;
  for (let day = slotSeed; day < slotSeed + 370; day++) {
    const date = new Date(
      Date.UTC(
        local.getUTCFullYear(),
        local.getUTCMonth(),
        local.getUTCDate() + day,
        12,
      ),
    );
    if (date.getUTCDay() !== 2 && date.getUTCDay() !== 5) continue;
    if (found++ !== slotOffset) continue;
    return new Date(
      Date.UTC(
        date.getUTCFullYear(),
        date.getUTCMonth(),
        date.getUTCDate() + 1,
        3,
        30,
      ),
    );
  }
  throw new Error("No future Phoenix Tuesday/Friday 20:30 slot found.");
}

async function cleanup() {
  if (gameIds.size) {
    const { error } = await admin.from("open_queue_games").delete().in("id", [
      ...gameIds,
    ]);
    if (error) {
      console.error("Could not clean up verification games:", error.message);
    }
  }
  if (intentIds.size) {
    for (const table of ["payment_refunds", "payment_intents"]) {
      const { error } = await admin.from(table).delete().in(
        table === "payment_refunds" ? "intent_id" : "id",
        [...intentIds],
      );
      if (error) {
        console.error(
          "Could not clean up synthetic payment fixtures:",
          error.message,
        );
      }
    }
  }
  for (const id of userIds) {
    const { error } = await admin.auth.admin.deleteUser(id);
    if (error) {
      console.error("Could not clean up verification user:", error.message);
    }
  }
}

function assertError(
  error: RpcError | null,
  expected: string,
  context: string,
) {
  assert(
    error && error.message.includes(expected),
    `${context} returned the wrong error: ${error?.message ?? "no error"}`,
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
