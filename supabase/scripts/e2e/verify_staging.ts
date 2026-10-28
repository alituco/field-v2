import {
  createAdminClient,
  createE2EUserClient,
  getAuthUser,
  loadManifestConfig,
  logStep,
  requireIndependentE2EStaff,
} from "./_shared.ts";
import {
  bookedRoleRatingBaselines,
  ratingTrackForRole,
} from "./rating_tracks.ts";
import { assertJourneyKickoffWindow } from "./game_slots.ts";
import { assertCompletedSeasonZeroEvidence } from "./completion_evidence.ts";

if (Deno.args.includes("--help")) {
  console.log(`Usage:
  deno run --allow-env --allow-net --allow-read \\
    supabase/scripts/e2e/verify_staging.ts [--phase=prepared|complete]

Required environment:
  SUPABASE_URL
  SUPABASE_SERVICE_ROLE_KEY
  FIELD_ENVIRONMENT=staging
  E2E_CONFIRM_TARGET=FIELD_STAGING_E2E
  E2E_RUN_ID
  E2E_MANIFEST_PATH

The prepared phase validates setup output before UI automation.
The complete phase validates the full player/referee/admin journey.`);
  Deno.exit(0);
}

const phase = readPhase(Deno.args);
const config = await loadManifestConfig(`staging E2E ${phase} verification`);
const manifest = config.manifest;
const staffIdentity = requireIndependentE2EStaff(manifest);
const admin = createAdminClient(config.supabaseUrl, config.serviceRoleKey);
const playerIds = manifest.accounts.players.map((player) => player.profileId);
const allProfileIds = [
  ...playerIds,
  manifest.accounts.onboarding.profileId,
];

await verifyProfiles();
await verifyPreparedGames();
if (phase === "complete") {
  await verifyCompletedMatch();
  await verifyCancellation();
  await verifyParty();
  await verifyAttendanceCorrection();
  await verifyModerationAndSupport();
}

logStep(
  phase === "prepared"
    ? `Prepared fixture ${manifest.runId} is valid.`
    : `Completed E2E journey ${manifest.runId} is valid.`,
);
console.log(`FIELD_E2E_VERIFIED=${phase}`);

async function verifyProfiles(): Promise<void> {
  const { data, error } = await admin
    .from("profiles")
    .select("id,display_name,username,date_of_birth")
    .in("id", allProfileIds);
  if (error) throw new Error(`verify E2E profiles: ${error.message}`);
  assert(
    (data ?? []).length === (phase === "prepared" ? 14 : 15),
    "Expected 14 match players; the signup profile exists only after completion. Staff must not create a player profile.",
  );

  const onboardingProfile = (data ?? []).find((row) =>
    row.id === manifest.accounts.onboarding.profileId
  );
  assert(
    (data ?? []).filter((row) =>
      row.id !== manifest.accounts.onboarding.profileId
    ).every((row) => String(row.display_name).startsWith("[E2E]")),
    "An E2E profile lost its explicit test label.",
  );
  if (phase === "prepared") {
    assert(
      onboardingProfile == null,
      "An incomplete signup must not create a publicly discoverable profile.",
    );
  } else {
    assert(
      onboardingProfile?.display_name === "E2E O." &&
        onboardingProfile.date_of_birth == null,
      "Signup must create a first-name/last-initial profile without a public birthday.",
    );
  }

  const signupAccount = await readAccount(manifest.accounts.onboarding.phone);
  if (phase === "prepared") {
    assert(
      signupAccount.onboarding_completed === false &&
        signupAccount.skill_assessment_required === true &&
        !hasNonEmptyString(signupAccount.first_name) &&
        signupAccount.date_of_birth == null,
      "The prepared signup actor must have a blank server-owned onboarding state.",
    );
  } else {
    assert(
      signupAccount.onboarding_completed === true &&
        signupAccount.skill_assessment === "not_sure" &&
        signupAccount.rating_initialized === true &&
        signupAccount.skill_assessment_required === false &&
        signupAccount.phone_verified === true &&
        isEligiblePlayerBirthDate(signupAccount.date_of_birth),
      "The onboarding journey did not persist a verified-phone,18+ server-completed account.",
    );
  }

  const mainProfile = (data ?? []).find((row) =>
    row.id === manifest.accounts.main.profileId
  );
  assert(
    mainProfile != null &&
      hasNonEmptyString(mainProfile.display_name) &&
      mainProfile.date_of_birth == null,
    "The main match account must stay fully onboarded.",
  );
  const mainAccount = await readAccount(manifest.accounts.main.phone);
  assert(
    mainAccount.onboarding_completed === true &&
      mainAccount.tour_completed === true &&
      isEligiblePlayerBirthDate(mainAccount.date_of_birth),
    "The main match account must have completed signup and tour.",
  );

  const { data: referee, error: refereeError } = await admin
    .from("referee_profiles")
    .select("profile_id,auth_user_id,email,role,is_active")
    .eq("profile_id", manifest.accounts.admin.profileId)
    .single();
  if (refereeError) {
    throw new Error(`verify E2E admin: ${refereeError.message}`);
  }
  assert(
    referee.role === "admin" && referee.is_active === true &&
      referee.auth_user_id === staffIdentity.authUserId &&
      referee.email === staffIdentity.email,
    "The E2E admin referee is not active.",
  );
  const identity = await getAuthUser(
    config.supabaseUrl,
    config.serviceRoleKey,
    staffIdentity.authUserId,
  );
  assert(
    identity.email === staffIdentity.email && !identity.phone &&
      identity.email_confirmed_at != null &&
      identity.app_metadata?.fieldrush_account_type === "staff" &&
      identity.app_metadata?.fieldrush_e2e === true &&
      identity.app_metadata?.fieldrush_e2e_role === "admin" &&
      identity.app_metadata?.fieldrush_e2e_run_id === manifest.runId,
    "The isolated staff sign-in is not a verified, protected email identity for this run.",
  );
  const { data: staffPlayers, error: staffPlayerError } = await admin.from(
    "profiles",
  ).select("id")
    .or(
      `id.eq.${staffIdentity.authUserId},auth_user_id.eq.${staffIdentity.authUserId}`,
    );
  if (staffPlayerError) throw staffPlayerError;
  assert(
    staffPlayers?.length === 0,
    "The staff Auth identity must not own any player profile.",
  );
}

async function readAccount(phone: string): Promise<Record<string, unknown>> {
  const actor = await createE2EUserClient(config.supabaseUrl, phone);
  try {
    const { data, error } = await actor.rpc("get_my_fieldrush_account");
    if (error) {
      throw new Error(`read server-owned E2E account: ${error.message}`);
    }
    return data as Record<string, unknown>;
  } finally {
    await actor.auth.signOut();
  }
}

async function verifyPreparedGames(): Promise<void> {
  const { data, error } = await admin
    .from("open_queue_games")
    .select(
      "id,status,venue,starts_at,ends_at,capacity,created_by,created_by_staff_id,currency,price_fils,format_version,timezone,rating_policy_id",
    )
    .in("id", [manifest.games.match.id, manifest.games.cancellation.id]);
  if (error) throw new Error(`verify E2E games: ${error.message}`);
  assert((data ?? []).length === 2, "Both E2E games must exist.");
  for (const game of data ?? []) {
    if (phase === "prepared" && game.id === manifest.games.match.id) {
      assert(
        game.rating_policy_id === "field-sr-season0-v2",
        "The played E2E fixture must exercise the active Season 0 policy.",
      );
      assertJourneyKickoffWindow(String(game.starts_at), new Date());
      assert(
        new Date(game.ends_at).getTime() -
            new Date(game.starts_at).getTime() === 30 * 60 * 1000,
        "The played E2E match must use the real 30-minute minimum duration.",
      );
    }
    assert(
      String(game.venue).startsWith(manifest.markers.venuePrefix),
      "An E2E game lost its run marker.",
    );
    assert(
      game.created_by_staff_id === manifest.accounts.admin.profileId &&
        game.created_by == null,
      "An E2E game is not owned by the isolated test admin.",
    );
    assert(Number(game.capacity) === 14, "E2E solo capacity must be 14.");
    assert(
      game.currency === "USD" && Number(game.price_fils) === 13000 &&
        game.format_version === "FIELDRUSH_7V7" &&
        game.timezone === "America/Phoenix",
      "E2E must exercise current Phoenix USD pricing and 7v7 rules.",
    );
  }

  const { data: bookings, error: bookingError } = await admin
    .from("open_queue_bookings")
    .select(
      "game_id,profile_id,status,role,rating_track,player_rating_at_booking",
    )
    .in("game_id", [manifest.games.match.id, manifest.games.cancellation.id])
    .eq("status", "CONFIRMED");
  if (bookingError) {
    throw new Error(`verify prepared E2E bookings: ${bookingError.message}`);
  }

  if (phase === "prepared") {
    const matchBookings = (bookings ?? []).filter((row) =>
      row.game_id === manifest.games.match.id
    );
    const cancelBookings = (bookings ?? []).filter((row) =>
      row.game_id === manifest.games.cancellation.id
    );
    assert(
      matchBookings.length === manifest.games.match.seededConfirmedCount,
      "Prepared match must contain exactly 13 seeded bookings.",
    );
    assert(
      !matchBookings.some((row) =>
        row.profile_id === manifest.accounts.main.profileId
      ),
      "The main UI player must create the fourteenth booking.",
    );
    assert(
      cancelBookings.length === 0,
      "The cancellation game must begin without a booking.",
    );
    assertRoleCounts(matchBookings, {
      GK: 2,
      DEF: 3,
      ATT: 8,
    });
    assert(
      matchBookings.every((booking) =>
        booking.rating_track === ratingTrackForRole(booking.role) &&
        Number(booking.player_rating_at_booking) ===
          manifest.ratingsBefore[booking.profile_id]
      ),
      "Prepared bookings must snapshot their booked role's manifest rating.",
    );
  }

  const { data: assignment, error: assignmentError } = await admin
    .from("open_queue_referee_assignments")
    .select("game_id,referee_id")
    .eq("game_id", manifest.games.match.id)
    .single();
  if (assignmentError) {
    throw new Error(
      `verify E2E referee assignment: ${assignmentError.message}`,
    );
  }
  assert(
    assignment.referee_id === manifest.accounts.admin.profileId,
    "The E2E match is not assigned to its test referee.",
  );
}

async function verifyCompletedMatch(): Promise<void> {
  const { data: game, error: gameError } = await admin
    .from("open_queue_games")
    .select(
      "status,rating_policy_id,starts_at,ends_at,white_score,black_score,teams_assigned_at,white_average_sr,black_average_sr",
    )
    .eq("id", manifest.games.match.id)
    .single();
  if (gameError) {
    throw new Error(`verify final E2E match: ${gameError.message}`);
  }
  assert(game.status === "FINAL", "The E2E match was not finalized.");
  assert(game.teams_assigned_at != null, "E2E teams were not assigned.");
  const whiteScore = Number(game.white_score ?? 0);
  const blackScore = Number(game.black_score ?? 0);
  assert(
    whiteScore + blackScore >= 1,
    "The E2E match must contain at least one recorded goal.",
  );
  assert(
    whiteScore !== blackScore,
    "The E2E match must finish with a winner to exercise SR gains and losses.",
  );
  assert(
    Number.isFinite(Number(game.white_average_sr)) &&
      Number.isFinite(Number(game.black_average_sr)),
    "The final E2E match is missing team rating snapshots.",
  );

  const { data: bookings, error: bookingsError } = await admin
    .from("open_queue_bookings")
    .select(
      "profile_id,status,role,rating_track,team,played,rating_at_match_start,rating_change",
    )
    .eq("game_id", manifest.games.match.id)
    .eq("status", "CONFIRMED");
  if (bookingsError) {
    throw new Error(`verify final E2E lineup: ${bookingsError.message}`);
  }
  assert(
    (bookings ?? []).length === 14,
    "Final E2E lineup must have 14 players.",
  );
  assert(
    (bookings ?? []).every((row) =>
      row.played === true &&
      row.rating_track === ratingTrackForRole(row.role) &&
      (row.team === "WHITE" || row.team === "BLACK") &&
      Number.isFinite(Number(row.rating_at_match_start)) &&
      Number.isFinite(Number(row.rating_change))
    ),
    "Every E2E player needs a played lineup and SR snapshot.",
  );
  assert(
    (bookings ?? []).filter((row) => row.team === "WHITE").length === 7 &&
      (bookings ?? []).filter((row) => row.team === "BLACK").length === 7,
    "E2E teams must contain seven players each.",
  );
  for (const team of ["WHITE", "BLACK"]) {
    assertRoleCounts((bookings ?? []).filter((row) => row.team === team), {
      GK: 1,
      DEF: 2,
      ATT: 4,
    });
  }

  const { data: ratingEvents, error: ratingError } = await admin
    .from("player_rating_events")
    .select(
      "profile_id,rating_track,source_type,source_id,side,result,rating_before,rating_after,rating_change",
    )
    .eq("source_type", "OPEN_QUEUE")
    .eq("source_id", manifest.games.match.id);
  if (ratingError) {
    throw new Error(`verify E2E SR events: ${ratingError.message}`);
  }
  assert(
    (ratingEvents ?? []).length === 14,
    "Final E2E match must create one immutable SR event per player.",
  );
  assert(
    new Set((ratingEvents ?? []).map((event) => event.profile_id)).size ===
        playerIds.length &&
      playerIds.every((profileId) =>
        (ratingEvents ?? []).some((event) =>
          event.profile_id === profileId &&
          event.rating_track === (bookings ?? []).find((booking) =>
              booking.profile_id === profileId
            )?.rating_track &&
          Number(event.rating_before) === manifest.ratingsBefore[profileId]
        )
      ),
    "The final SR ledger must start from every manifest player baseline.",
  );
  assert(
    (ratingEvents ?? []).every((event) =>
      Number(event.rating_after) - Number(event.rating_before) ===
        Number(event.rating_change)
    ),
    "An E2E Player SR ledger event is internally inconsistent.",
  );
  const winningSide = whiteScore > blackScore ? "WHITE" : "BLACK";
  const losingSide = winningSide === "WHITE" ? "BLACK" : "WHITE";
  assert(
    (ratingEvents ?? []).filter((event) =>
      event.side === winningSide &&
      event.result === "WIN" &&
      Number(event.rating_change) > 0
    ).length === 7,
    "All seven winning E2E players must receive a positive SR change.",
  );
  assert(
    (ratingEvents ?? []).filter((event) =>
      event.side === losingSide &&
      event.result === "LOSS" &&
      Number(event.rating_change) < 0
    ).length === 7,
    "All seven losing E2E players must receive a negative SR change.",
  );

  const { data: currentRatings, error: currentRatingsError } = await admin
    .from("fieldrush_player_rating_tracks")
    .select("profile_id,rating_track,skill_rating")
    .in("profile_id", playerIds);
  if (currentRatingsError) {
    throw new Error(
      `verify current E2E Player SR: ${currentRatingsError.message}`,
    );
  }
  const rolesByProfile = Object.fromEntries(
    (bookings ?? []).map((booking) => [booking.profile_id, booking.role]),
  );
  const currentBookedRatings = bookedRoleRatingBaselines(
    currentRatings ?? [],
    rolesByProfile,
  );
  assert(
    Object.keys(currentBookedRatings).length === playerIds.length &&
      Object.entries(currentBookedRatings).every(([profileId, skillRating]) =>
        (ratingEvents ?? []).some((event) =>
          event.profile_id === profileId &&
          event.rating_track ===
            ratingTrackForRole(rolesByProfile[profileId]) &&
          Number(event.rating_after) === skillRating
        )
      ),
    "Current Player SR must exactly match the immutable final ledger.",
  );

  const { data: attendance, error: attendanceError } = await admin
    .from("match_attendance_records")
    .select("profile_id,checked_in_at,outcome,finalized_at")
    .eq("match_kind", "SOLO")
    .eq("open_queue_game_id", manifest.games.match.id);
  if (attendanceError) {
    throw new Error(`verify E2E attendance: ${attendanceError.message}`);
  }
  assert(
    (attendance ?? []).length === 14 &&
      (attendance ?? []).every((row) =>
        row.checked_in_at != null &&
        row.outcome != null &&
        row.finalized_at != null
      ),
    "Every E2E player must have finalized referee attendance.",
  );

  // S0 uses the ordinary ±24h kickoff path. The legacy admin test-start
  // audit is neither emitted nor required; verify the real persisted evidence.
  const { data: state, error: stateError } = await admin.rpc(
    "get_season_zero_match_state",
    {
      actor_referee_id: manifest.accounts.admin.profileId,
      game_id_to_use: manifest.games.match.id,
    },
  );
  if (stateError) {
    throw new Error(`verify E2E participation evidence: ${stateError.message}`);
  }
  const { data: matchEvents, error: matchEventsError } = await admin
    .from("open_queue_events")
    .select("game_id,event_type,occurred_at,minute,second")
    .eq("game_id", manifest.games.match.id)
    .in("event_type", ["MATCH_STARTED", "MATCH_ENDED"]);
  if (matchEventsError) {
    throw new Error(`verify E2E match evidence: ${matchEventsError.message}`);
  }
  const { data: clock, error: clockError } = await admin
    .from("open_queue_clock_states")
    .select("game_id,status,started_at,accumulated_seconds,duration_seconds")
    .eq("game_id", manifest.games.match.id)
    .single();
  if (clockError) {
    throw new Error(`verify E2E stopped clock: ${clockError.message}`);
  }
  assertCompletedSeasonZeroEvidence(
    {
      id: manifest.games.match.id,
      startsAt: game.starts_at,
      endsAt: game.ends_at,
      ratingPolicy: game.rating_policy_id,
    },
    state,
    matchEvents,
    clock,
  );
}

async function verifyCancellation(): Promise<void> {
  const { data: bookings, error } = await admin
    .from("open_queue_bookings")
    .select(
      "id,status,cancelled_at,refund_bps,refund_amount_fils,refund_status,refund_destination,payment_intent_id,payment_status,reliability_policy_version_id",
    )
    .eq("game_id", manifest.games.cancellation.id)
    .eq("profile_id", manifest.accounts.main.profileId);
  if (error) throw new Error(`verify E2E cancellation: ${error.message}`);
  assert(
    (bookings ?? []).length === 1,
    "The main player must have exactly one cancellation-game booking.",
  );
  const booking = bookings![0];
  assert(
    booking.status === "CANCELLED" && booking.cancelled_at != null,
    "The E2E booking was not cancelled.",
  );
  assert(
    Number.isInteger(Number(booking.refund_bps)) &&
      Number(booking.refund_bps) > 0 &&
      Number(booking.refund_amount_fils) > 0 &&
      booking.refund_status === "PROCESSED" &&
      booking.refund_destination === "ORIGINAL_PAYMENT_METHOD",
    "The E2E cancellation is missing its policy-backed refund snapshot.",
  );

  const { data: refunds, error: refundError } = await admin
    .from("payment_refunds")
    .select(
      "id,recipient_profile_id,status,amount_fils,currency,idempotency_key",
    )
    .eq("intent_id", booking.payment_intent_id);
  if (refundError) {
    throw new Error(
      `verify E2E original-method refund: ${refundError.message}`,
    );
  }
  assert(
    (refunds ?? []).length === 1,
    "The cancellation must create exactly one idempotent original-method refund.",
  );
  const refund = refunds![0];
  assert(
    refund.recipient_profile_id === manifest.accounts.main.profileId &&
      refund.status === "SUCCEEDED" && refund.currency === "USD" &&
      Number(refund.amount_fils) === Number(booking.refund_amount_fils) &&
      refund.idempotency_key === `booking-refund:${booking.id}`,
    "The synthetic provider refund does not match the cancellation snapshot.",
  );
  const { count: walletCredits, error: walletError } = await admin
    .from("field_wallet_transactions").select("id", {
      count: "exact",
      head: true,
    })
    .eq("booking_id", booking.id);
  if (walletError) {
    throw new Error(
      `verify no duplicate wallet credit: ${walletError.message}`,
    );
  }
  assert(
    walletCredits === 0,
    "An original-method refund must not also credit a wallet.",
  );

  const { data: game, error: gameError } = await admin
    .from("open_queue_games")
    .select("status")
    .eq("id", manifest.games.cancellation.id)
    .single();
  if (gameError) {
    throw new Error(`verify reopened E2E game: ${gameError.message}`);
  }
  assert(
    game.status === "OPEN",
    "Cancelling the E2E booking must reopen its game before cleanup.",
  );
}

async function verifyParty(): Promise<void> {
  const { data, error } = await admin
    .from("open_queue_party_members")
    .select("party_id,profile_id,status,game_id")
    .eq("game_id", manifest.games.match.id)
    .in("profile_id", [
      manifest.accounts.main.profileId,
      manifest.accounts.partyTarget.profileId,
    ])
    .eq("status", "ACCEPTED");
  if (error) throw new Error(`verify E2E party: ${error.message}`);
  assert(
    (data ?? []).length === 2,
    "The E2E party invitation was not accepted.",
  );
  assert(
    new Set((data ?? []).map((row) => row.party_id)).size === 1,
    "The two E2E players did not finish in the same party.",
  );

  const { data: bookings, error: bookingError } = await admin
    .from("open_queue_bookings")
    .select("profile_id,team")
    .eq("game_id", manifest.games.match.id)
    .in("profile_id", [
      manifest.accounts.main.profileId,
      manifest.accounts.partyTarget.profileId,
    ])
    .eq("status", "CONFIRMED");
  if (bookingError) {
    throw new Error(
      `verify E2E party team assignment: ${bookingError.message}`,
    );
  }
  assert(
    (bookings ?? []).length === 2 &&
      (bookings![0].team === "WHITE" || bookings![0].team === "BLACK") &&
      bookings![0].team === bookings![1].team,
    "Accepted E2E party members must be assigned to the same final team.",
  );
}

async function verifyAttendanceCorrection(): Promise<void> {
  const { data: attendance, error: attendanceError } = await admin
    .from("match_attendance_records")
    .select("id")
    .eq("match_kind", "SOLO")
    .eq("open_queue_game_id", manifest.games.match.id)
    .eq("profile_id", manifest.accounts.main.profileId)
    .single();
  if (attendanceError) {
    throw new Error(
      `load corrected E2E attendance: ${attendanceError.message}`,
    );
  }
  const { data: events, error: eventError } = await admin
    .from("attendance_events")
    .select("event_type")
    .eq("attendance_id", attendance.id)
    .in("event_type", ["CHECKED_IN", "CHECK_IN_REMOVED"]);
  if (eventError) {
    throw new Error(`verify E2E check-in correction: ${eventError.message}`);
  }
  assert(
    (events ?? []).filter((event) => event.event_type === "CHECKED_IN")
          .length >=
        2 &&
      (events ?? []).some((event) => event.event_type === "CHECK_IN_REMOVED"),
    "The referee did not check in, remove, and re-check the E2E player.",
  );
}

async function verifyModerationAndSupport(): Promise<void> {
  const { data: reports, error: reportError } = await admin
    .from("moderation_reports")
    .select(
      "id,status,source,subject_type,subject_profile_id,reporter_profile_id,details",
    )
    .eq("reporter_profile_id", manifest.accounts.main.profileId)
    .eq("details", manifest.markers.reportDetails);
  if (reportError) {
    throw new Error(`verify E2E moderation report: ${reportError.message}`);
  }
  assert(
    (reports ?? []).length === 1 &&
      reports![0].source === "MOBILE" &&
      reports![0].subject_type === "PLAYER" &&
      reports![0].subject_profile_id ===
        manifest.accounts.partyTarget.profileId,
    "The mobile E2E moderation report is missing from the admin queue.",
  );

  const { data: tickets, error: ticketError } = await admin
    .from("support_tickets")
    .select("id,status,requester_profile_id,details")
    .eq("requester_profile_id", manifest.accounts.main.profileId)
    .eq("details", manifest.markers.supportDetails);
  if (ticketError) {
    throw new Error(`verify E2E support ticket: ${ticketError.message}`);
  }
  assert(
    (tickets ?? []).length === 1,
    "The mobile E2E support request is missing from the admin queue.",
  );
}

function assertRoleCounts(
  rows: Array<Record<string, unknown>>,
  expected: Record<string, number>,
): void {
  for (const [role, count] of Object.entries(expected)) {
    assert(
      rows.filter((row) => row.role === role).length === count,
      `E2E roster needs ${count} ${role} booking(s).`,
    );
  }
}

function readPhase(args: string[]): "prepared" | "complete" {
  const value = args.find((arg) => arg.startsWith("--phase="))?.split("=")[1] ??
    "complete";
  if (value !== "prepared" && value !== "complete") {
    throw new Error("E2E verification phase must be prepared or complete.");
  }
  return value;
}

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function hasNonEmptyString(value: unknown): boolean {
  return typeof value === "string" && value.trim().length > 0;
}

function isEligiblePlayerBirthDate(value: unknown): boolean {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false;
  }
  const date = new Date();
  date.setUTCFullYear(date.getUTCFullYear() - 18);
  const latestEligible = [
    date.getUTCFullYear().toString().padStart(4, "0"),
    (date.getUTCMonth() + 1).toString().padStart(2, "0"),
    date.getUTCDate().toString().padStart(2, "0"),
  ].join("-");
  return value <= latestEligible;
}
