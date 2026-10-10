import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.86.0";
import { completeLocalFieldrushFixture } from "./_shared/fieldrush_fixture.ts";
import { legacyOpenQueueFormat } from "./_shared/legacy_open_queue_format.ts";

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
let first: ProfileRow;
let second: ProfileRow;
let participants: ProfileRow[];
let firstClient: SupabaseClient;
let secondClient: SupabaseClient;

participants = [];
for (let index = 1; index <= 12; index += 1) {
  participants.push(await createVerificationProfile(String(index)));
}
[first, second] = participants;

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
await verifyFullGameReopensWithPolicyRefund();
console.log(
  "Open Queue verified locally: atomic final spot, no waitlist state, hard caps, policy-backed cancellation/refund, wallet credit, and FULL→OPEN.",
);

async function verifyFinalRoleRace() {
  const game = await createGame(futureBahrainOpenQueueStart(0), "RACE");
  await insertBooking(game.id, participants[2], "GK", "verify-race-existing");

  const paymentReferences = await Promise.all([
    prepareCapturedPayment(firstClient, first.id, game.id, "GK"),
    prepareCapturedPayment(secondClient, second.id, game.id, "GK"),
  ]);
  const calls = [firstClient, secondClient].map((client, index) =>
    client.rpc("book_open_queue_game", {
      game_id_to_book: game.id,
      role_to_book: "GK",
      payment_method_to_use: "CARD",
      payment_reference_to_use: paymentReferences[index],
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

  const id = crypto.randomUUID();
  const compactId = id.replaceAll("-", "");
  const chargeId = `chg_verify_${compactId}`;
  const { error } = await admin.from("tap_payment_intents").insert({
    id,
    profile_id: profileId,
    purpose: "SOLO_BOOKING",
    status: "CAPTURED",
    currency: "BHD",
    amount_fils: Number(quote.total_fils),
    payload: { game_id: gameId, role },
    quote_snapshot: quote,
    transaction_reference: `field_verify_${compactId}`,
    tap_charge_id: chargeId,
    tap_payment_method: "CARD",
    tap_status: "CAPTURED",
    captured_at: new Date().toISOString(),
  });
  if (error) throw error;
  return chargeId;
}

async function verifyFullGameReopensWithPolicyRefund() {
  const game = await createGame(futureBahrainOpenQueueStart(2), "FULL");
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
      Math.floor(3000 * preview.refund_bps / 10000),
    "The quoted refund must be calculated from the stored base price.",
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
    const { data: walletCredit, error: walletError } = await admin
      .from("field_wallet_transactions")
      .select("amount_fils,transaction_type")
      .eq("booking_id", booking.id)
      .eq("transaction_type", "BOOKING_REFUND")
      .single();
    if (walletError) throw walletError;
    assert(
      walletCredit.amount_fils === preview.refund_amount_fils,
      "A refundable cancellation must credit the quoted amount to Field Wallet.",
    );
  }
}

async function verifyWaitlistStateIsRejected() {
  const game = await createGame(
    futureBahrainOpenQueueStart(1),
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
    role: "MID",
    status: "WAITLIST",
    player_rating_at_booking: rating.skill_rating,
    amount_paid_fils: 3000,
    base_amount_fils: 3000,
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
      ...legacyOpenQueueFormat,
      venue: `[OQ VERIFY ${suffix}] ${crypto.randomUUID().slice(0, 8)}`,
      starts_at: startsAt.toISOString(),
      ends_at: new Date(startsAt.getTime() + 60 * 60 * 1000).toISOString(),
      price_fils: 3000,
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
    amount_paid_fils: 3000,
    base_amount_fils: 3000,
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
  const digits = String(Math.floor(10_000_000 + Math.random() * 89_999_999));
  const phone = `+973${digits}`;
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
    lastName: `Verify ${label}`,
    dateOfBirth: "2000-01-01",
    username: `oq_verify_${digits}`,
  });
  return { id: data.user.id, phone };
}

function futureBahrainOpenQueueStart(slotOffset: number) {
  assert(
    Number.isInteger(slotOffset) && slotOffset >= 0,
    "Open Queue slot offset must be a non-negative integer.",
  );
  const nowInBahrain = new Date(Date.now() + 3 * 60 * 60 * 1000);
  let matchingSlot = 0;
  for (
    let daysAhead = testSlotSeed;
    daysAhead < testSlotSeed + 370;
    daysAhead += 1
  ) {
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
