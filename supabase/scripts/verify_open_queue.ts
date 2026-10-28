import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.86.0";
import { completeLocalFieldrushFixture } from "./_shared/fieldrush_fixture.ts";

type ProfileRow = { id: string; phone: string | null };

const url = requireEnv("SUPABASE_URL");
const publishableKey = requireEnv("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = requireEnv("DEV_SEED_PASSWORD");
assertLocalSupabase(url);
const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const testSlotSeed = 3650 +
  crypto.getRandomValues(new Uint32Array(1))[0] % 1000;
const participants: ProfileRow[] = [];
for (let index = 1; index <= 14; index += 1) {
  participants.push(await createVerificationProfile(String(index)));
}
const [first, second] = participants;

const firstClient = await signedInClient(first.phone!);
const secondClient = await signedInClient(second.phone!);

const { data: season, error: seasonError } = await admin.from(
  "fieldrush_seasons",
)
  .select("starts_on,ends_on").eq("lifecycle", "ACTIVE").single();
if (seasonError) throw seasonError;
const { data: ownRatings, error: ownRatingError } = await firstClient.rpc(
  "get_fieldrush_player_ratings",
  {
    profile_id_to_use: first.id,
    season_starts_on: season.starts_on,
    season_ends_on: season.ends_on,
  },
);
if (ownRatingError) throw ownRatingError;
assert(
  ownRatings.profile_id === first.id &&
    ownRatings.ratings.OUTFIELD.skill_rating === null &&
    ownRatings.ratings.GOALKEEPER.skill_rating === null &&
    ownRatings.ratings.OUTFIELD.lifetime_counted_matches === 0,
  "The role-aware rating RPC must return the signed-in player with numeric SR hidden before placement.",
);

await verifyFinalRoleRace();
await verifyWaitlistStateIsRejected();
await verifyFullGameReopensWithPolicyRefund();
console.log(
  "Open Queue verified locally: USD 13, 7v7 hard caps, atomic final spot, one upcoming/active game total, no waitlist, original-method policy refund with no wallet credit, and FULL→OPEN.",
);

async function verifyFinalRoleRace() {
  const game = await createGame(futurePhoenixOpenQueueStart(0), "RACE");
  await insertBooking(game.id, participants[2], "GK", "verify-race-existing");

  const paymentReferences = await Promise.all([
    prepareCapturedPayment(firstClient, first.id, game.id, "GK"),
    prepareCapturedPayment(secondClient, second.id, game.id, "GK"),
  ]);
  const calls = paymentReferences.map((intentId) =>
    admin.rpc("finalize_payment_intent", {
      intent_id_to_finalize: intentId,
    })
  );
  const results = await Promise.all(calls);
  const successes = results.filter((result) =>
    result.error === null && result.data?.status === "FINALIZED"
  );
  const failures = results.filter((result) =>
    result.error !== null || result.data?.status !== "FINALIZED"
  );
  assert(
    successes.length === 1,
    "Exactly one player must win the final goalkeeper spot.",
  );
  assert(
    failures.length === 1,
    "Exactly one final-spot booking must be rejected.",
  );
  assert(
    (failures[0].error?.message ?? failures[0].data?.failure_reason ?? "")
      .includes("position just filled"),
    "The losing booking should receive the position-filled business error.",
  );

  // A different non-overlapping day is still a second registration. Verify
  // both the player-facing preflight and direct fixture insertion reject it.
  const nextGame = await createGame(futurePhoenixOpenQueueStart(3), "LIMIT");
  const winningClient = results[0].data?.status === "FINALIZED"
    ? firstClient
    : secondClient;
  const { error: limitError } = await winningClient.rpc(
    "preview_open_queue_booking_cost",
    { game_id_to_book: nextGame.id, role_to_book: "DEF" },
  );
  assert(
    limitError?.message.includes("one upcoming or active game") === true,
    "A player with one registered game must not start checkout for another day.",
  );
  let directRejected = false;
  try {
    await insertBooking(nextGame.id, participants[2], "DEF", "verify-limit");
  } catch (error) {
    assert(
      (error as { message?: string }).message?.includes(
        "one upcoming or active game",
      ) === true,
      "Direct second-game registration must fail at the same one-game rule.",
    );
    directRejected = true;
  }
  assert(directRejected, "Direct registration bypassed the one-game limit.");

  // Retire this completed synthetic scenario before the next scenario reuses
  // its participants. Never bypass the registration guard or erase payments.
  const { error: retireError } = await admin.from("open_queue_games").update({
    status: "CANCELLED",
    cancellation_code: "ADMIN_DECISION",
    cancellation_reason: "Open Queue final-spot verification completed.",
    cancelled_at: new Date().toISOString(),
    cancelled_by: first.id,
    cancellation_context: { source: "OPEN_QUEUE_VERIFICATION" },
  }).eq("id", game.id);
  if (retireError) throw retireError;
}

async function prepareCapturedPayment(
  client: SupabaseClient,
  profileId: string,
  gameId: string,
  role: string,
) {
  const { data: quote, error: quoteError } = await client.rpc(
    "preview_open_queue_booking_cost",
    { game_id_to_book: gameId, role_to_book: role },
  );
  if (quoteError) throw quoteError;
  assert(
    quote.currency === "USD" && quote.total_fils === 13000,
    "Synthetic captured checkout must use the authoritative USD 13 quote.",
  );

  const id = crypto.randomUUID();
  const compactId = id.replaceAll("-", "");
  const chargeId = `chg_verify_${compactId}`;
  const { error } = await admin.from("payment_intents").insert({
    id,
    profile_id: profileId,
    purpose: "SOLO_BOOKING",
    status: "CAPTURED",
    provider: "STAGING_E2E",
    currency: quote.currency,
    amount_fils: Number(quote.total_fils),
    payload: { game_id: gameId, role },
    quote_snapshot: quote,
    transaction_reference: `field_verify_${compactId}`,
    provider_intent_id: `field_e2e_intent_${compactId}`,
    provider_payment_id: chargeId,
    payment_method: "CARD",
    provider_status: "SUCCEEDED",
    captured_at: new Date().toISOString(),
  });
  if (error) throw error;
  return id;
}

async function verifyFullGameReopensWithPolicyRefund() {
  const game = await createGame(futurePhoenixOpenQueueStart(2), "FULL");
  const roles = [
    "GK",
    "GK",
    "DEF",
    "DEF",
    "DEF",
    "DEF",
    "DEF",
    "DEF",
    "ATT",
    "ATT",
    "ATT",
    "ATT",
    "ATT",
    "ATT",
  ];
  for (let index = 0; index < participants.length; index += 1) {
    if (index === 0) {
      const intentId = await prepareCapturedPayment(
        firstClient,
        first.id,
        game.id,
        roles[index],
      );
      const { data, error } = await admin.rpc("finalize_payment_intent", {
        intent_id_to_finalize: intentId,
      });
      if (error) throw error;
      assert(
        data?.status === "FINALIZED",
        "The cancellable booking must have a verified synthetic provider payment.",
      );
      continue;
    }
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
    "The fourteenth confirmed booking must mark a game FULL.",
  );

  const booking = await ownBooking(firstClient, game.id);
  const { data: previews, error: previewError } = await firstClient.rpc(
    "preview_open_queue_cancellation",
    { booking_id_to_preview: booking.id },
  );
  if (previewError) throw previewError;
  const preview = previews[0];
  assert(
    preview.can_cancel === true,
    "A future confirmed booking must be cancellable.",
  );
  assert(
    preview.outcome_code === "CANCELLED_EARLY",
    "A far-future cancellation must use the active policy's early band.",
  );
  assert(
    Number.isInteger(preview.refund_bps) &&
      preview.refund_bps >= 0 &&
      preview.refund_bps <= 10000,
    "The active policy must quote a valid refund basis-points value.",
  );
  assert(
    preview.refund_amount_fils ===
      Math.floor(13000 * preview.refund_bps / 10000),
    "The quoted refund must be calculated from the stored base price.",
  );
  assert(
    preview.refund_destination === "ORIGINAL_PAYMENT_METHOD",
    "The new payment cancellation quote must not offer wallet credit.",
  );

  const { data: cancelled, error: cancelError } = await firstClient.rpc(
    "cancel_open_queue_booking",
    { booking_id_to_cancel: booking.id },
  );
  if (cancelError) throw cancelError;
  assert(
    cancelled.refund_bps === preview.refund_bps &&
      cancelled.refund_amount_fils === preview.refund_amount_fils,
    "The applied refund must exactly match the policy-backed preview.",
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

  if (preview.refund_amount_fils > 0) {
    assert(
      cancelled.refund_destination === "ORIGINAL_PAYMENT_METHOD" &&
        cancelled.refund_status === "PROCESSED",
      "Local synthetic cancellation must settle its original-method refund.",
    );
    const { data: refund, error: refundError } = await admin.from(
      "payment_refunds",
    )
      .select("amount_fils,amount_minor,currency,status,provider_status")
      .eq("intent_id", cancelled.payment_intent_id).single();
    if (refundError) throw refundError;
    assert(
      refund.amount_fils === preview.refund_amount_fils &&
        refund.amount_minor === Math.floor(preview.refund_amount_fils / 10) &&
        refund.currency === "USD" && refund.status === "SUCCEEDED" &&
        refund.provider_status === "staging_e2e",
      "The isolated refund ledger must match the quoted USD amount; no real provider is contacted.",
    );
    const { data: credits, error: walletError } = await admin.from(
      "field_wallet_transactions",
    ).select("id,currency").eq("booking_id", booking.id);
    if (walletError) throw walletError;
    assert(
      credits.length === 0,
      "Original-method refunds must never credit a USD or historical wallet.",
    );
  }
}

async function verifyWaitlistStateIsRejected() {
  const game = await createGame(
    futurePhoenixOpenQueueStart(1),
    "NO-WAITLIST",
  );
  const { data: rating, error: ratingError } = await admin
    .from("player_ratings")
    .select("skill_rating")
    .eq("profile_id", first.id)
    .single();
  if (ratingError) throw ratingError;
  const policyVersionId = await policyVersionForGame(game.id);

  const { error } = await admin.from("open_queue_bookings").insert({
    game_id: game.id,
    profile_id: first.id,
    role: "DEF",
    status: "WAITLIST",
    player_rating_at_booking: rating.skill_rating,
    amount_paid_fils: 13000,
    base_amount_fils: 13000,
    discount_bps: 0,
    reliability_deposit_fils: 0,
    reliability_deposit_status: "NOT_REQUIRED",
    reliability_policy_version_id: policyVersionId,
    payment_method: "MOCK",
  });
  assert(
    error !== null &&
      error.message.includes("open_queue_bookings_status_check"),
    "The database must reject WAITLIST specifically at the booking-status constraint.",
  );
}

async function createGame(startsAt: Date, suffix: string) {
  const { data, error } = await admin
    .from("open_queue_games")
    .insert({
      format_version: "FIELDRUSH_7V7",
      currency: "USD",
      timezone: "America/Phoenix",
      capacity: 14,
      goalkeeper_capacity: 2,
      defender_capacity: 6,
      midfielder_capacity: 0,
      attacker_capacity: 6,
      venue: `[OQ VERIFY ${suffix}] ${crypto.randomUUID().slice(0, 8)}`,
      starts_at: startsAt.toISOString(),
      ends_at: new Date(startsAt.getTime() + 60 * 60 * 1000).toISOString(),
      price_fils: 13000,
    })
    .select("id")
    .single();
  if (error) throw error;
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
  const policyVersionId = await policyVersionForGame(gameId);
  const { error } = await admin.from("open_queue_bookings").insert({
    game_id: gameId,
    profile_id: profile.id,
    role,
    player_rating_at_booking: rating.skill_rating,
    amount_paid_fils: 13000,
    base_amount_fils: 13000,
    discount_bps: 0,
    reliability_deposit_fils: 0,
    reliability_deposit_status: "NOT_REQUIRED",
    reliability_policy_version_id: policyVersionId,
    payment_method: "MOCK",
    payment_reference: paymentReference,
  });
  if (error) throw error;
}

async function policyVersionForGame(gameId: string) {
  const { data, error } = await admin
    .from("match_reliability_terms")
    .select("policy_version_id")
    .eq("open_queue_game_id", gameId)
    .single();
  if (error) throw error;
  return data.policy_version_id as string;
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
  const digits = String(Math.floor(1_000_000 + Math.random() * 8_999_999));
  const phone = `+1480${digits}`;
  const { data, error } = await admin.auth.admin.createUser({
    phone,
    password,
    phone_confirm: true,
    user_metadata: {
      display_name: `Open Queue Verify ${label}`,
      date_of_birth: "2000-01-01",
    },
  });
  if (error) throw error;

  await completeLocalFieldrushFixture({
    url,
    publishableKey,
    phone,
    password,
    firstName: "Open Queue",
    lastName: "Verification",
    dateOfBirth: "2000-01-01",
    username: `oq_verify_${digits}`,
  });
  return { id: data.user.id, phone };
}

function futurePhoenixOpenQueueStart(slotOffset: number) {
  assert(
    Number.isInteger(slotOffset) && slotOffset >= 0,
    "Open Queue slot offset must be a non-negative integer.",
  );
  const nowInPhoenix = new Date(Date.now() - 7 * 60 * 60 * 1000);
  let matchingSlot = 0;
  for (
    let daysAhead = testSlotSeed;
    daysAhead < testSlotSeed + 370;
    daysAhead += 1
  ) {
    const localDate = new Date(Date.UTC(
      nowInPhoenix.getUTCFullYear(),
      nowInPhoenix.getUTCMonth(),
      nowInPhoenix.getUTCDate() + daysAhead,
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
      localDate.getUTCDate() + 1,
      3,
      30,
    ));
  }
  throw new Error("Could not find a future Tuesday/Friday Open Queue slot.");
}

function assertLocalSupabase(rawUrl: string) {
  const hostname = new URL(rawUrl).hostname;
  assert(
    hostname === "127.0.0.1" || hostname === "localhost" ||
      hostname === "::1",
    "This destructive integration verification can only run against local Supabase.",
  );
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
