import type { User } from "https://esm.sh/@supabase/supabase-js@2.86.0";
import { isAuthOnlyOnboardingFixture } from "../../functions/dev-switch-user/fixture.ts";
import { legacyOpenQueueFormat } from "../_shared/legacy_open_queue_format.ts";

import {
  type AdminClient,
  assertNoError,
  createAdminClient,
  createAuthUser,
  createE2EUserClient,
  E2E_DEFAULT_BIRTH_DATE,
  E2E_PROFILE_PREFIX,
  E2E_SCHEMA_VERSION,
  E2E_VENUE_PREFIX,
  type E2EAccount,
  type E2EGame,
  type E2EManifest,
  isTerminalGameStatus,
  listAuthUsers,
  loadSetupConfig,
  logStep,
  requireUuid,
  selectRotatingIndex,
  shortRunId,
  targetProjectRef,
  unwrapRpcRow,
  updateAuthUser,
  writeManifest,
} from "./_shared.ts";

const PLAYER_DEFINITIONS = [
  ["+97339009001", "Ali E2E", "field_e2e_01"],
  ["+97339009002", "Omar E2E", "field_e2e_02"],
  ["+97339009003", "Khalid E2E", "field_e2e_03"],
  ["+97339009004", "Yousef E2E", "field_e2e_04"],
  ["+97339009005", "Hasan E2E", "field_e2e_05"],
  ["+97339009006", "Hamad E2E", "field_e2e_06"],
  ["+97339009007", "Salman E2E", "field_e2e_07"],
  ["+97339009008", "Rashid E2E", "field_e2e_08"],
  ["+97339009009", "Sami E2E", "field_e2e_09"],
  ["+97339009010", "Faisal E2E", "field_e2e_10"],
  ["+97339009011", "Jassim E2E", "field_e2e_11"],
  ["+97339009012", "Rami E2E", "field_e2e_12"],
] as const;

const ADMIN_DEFINITION = [
  "+97339009099",
  "Nasser E2E Referee",
  "field_e2e_admin",
] as const;

const FILLER_ROLES = [
  "GK",
  "GK",
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

if (Deno.args.includes("--help")) {
  console.log(`Usage:
  deno run --allow-env --allow-net --allow-write \\
    supabase/scripts/e2e/setup_staging.ts

Required environment:
  SUPABASE_URL
  SUPABASE_SERVICE_ROLE_KEY
  FIELD_ENVIRONMENT=staging
  E2E_CONFIRM_TARGET=FIELD_STAGING_E2E
  E2E_RUN_ID
  E2E_TEST_PASSWORD
  E2E_ONBOARDING_PHONE
  E2E_MANIFEST_PATH

Optional:
  E2E_BOOTSTRAP_PHONE  (defaults to a configured staging fake user)
  E2E_DEV_OTP_CODE    (defaults to 000000)

Use --dry-run to validate the target and environment without changing data.`);
  Deno.exit(0);
}

const config = loadSetupConfig("staging E2E fixture setup");
if (Deno.args.includes("--dry-run")) {
  logStep(
    `Dry run passed for ${config.target.environment}, run ${config.runId}.`,
  );
  Deno.exit(0);
}

const admin = createAdminClient(config.supabaseUrl, config.serviceRoleKey);
if (config.onboardingPhone !== "+97339009100") {
  throw new Error(
    "The auth-only onboarding fixture must use the server-allowlisted +97339009100 test number.",
  );
}
const authUsersByPhone = await loadAuthUsersByPhone();
await ensureBootstrapAccount();
const selectedMainIndex = selectRotatingIndex(
  config.runId,
  PLAYER_DEFINITIONS.length,
);

logStep("Creating or refreshing the isolated E2E account pool.");
const players: E2EAccount[] = [];
for (const definition of PLAYER_DEFINITIONS) {
  players.push(
    await ensureAccount(admin, {
      phone: definition[0],
      displayName: `${E2E_PROFILE_PREFIX} ${definition[1]}`,
      username: definition[2],
      password: config.testPassword,
      dateOfBirth: E2E_DEFAULT_BIRTH_DATE,
      role: "player",
    }),
  );
}

if (
  PLAYER_DEFINITIONS.some((definition) =>
    definition[0] === config.onboardingPhone
  ) ||
  config.onboardingPhone === config.bootstrapPhone
) {
  throw new Error(
    "E2E_ONBOARDING_PHONE must be reserved for the isolated onboarding account " +
      "and cannot be the bootstrap login.",
  );
}
const onboarding = await ensureAccount(admin, {
  phone: config.onboardingPhone,
  displayName: `${E2E_PROFILE_PREFIX} Onboarding Player`,
  username: "field_e2e_onboarding",
  password: config.testPassword,
  dateOfBirth: null,
  role: "player",
  clearAuthOnboarding: true,
});

const e2eAdmin = await ensureAccount(admin, {
  phone: ADMIN_DEFINITION[0],
  displayName: `${E2E_PROFILE_PREFIX} ${ADMIN_DEFINITION[1]}`,
  username: ADMIN_DEFINITION[2],
  password: config.testPassword,
  dateOfBirth: E2E_DEFAULT_BIRTH_DATE,
  role: "admin",
});

await admin.from("referee_profiles").upsert(
  {
    profile_id: e2eAdmin.profileId,
    display_name: e2eAdmin.displayName,
    phone: e2eAdmin.phone,
    role: "admin",
    is_active: true,
  },
  { onConflict: "profile_id" },
).then(({ error }) => {
  if (error) throw new Error(`upsert E2E referee: ${error.message}`);
});

logStep("Closing stale transient E2E state from earlier interrupted runs.");
await closeStaleTransientState(admin, e2eAdmin, [...players, onboarding]);
await assertPoolHasNoForeignUpcomingBookings(
  admin,
  [...players, onboarding],
  e2eAdmin,
);

const main = players[selectedMainIndex];
const partyTarget = players[
  (selectedMainIndex + 1) % players.length
];
const shortId = shortRunId(config.runId);
const venuePrefix = `${E2E_VENUE_PREFIX} ${shortId}]`;

const createdGames: Array<Omit<E2EGame, "seededConfirmedCount">> = [];
try {
  logStep("Reserving two unused permanent solo schedule slots.");
  const [matchStart, cancellationStart] = await findUnusedSoloSlots(admin, 2);
  const match = await createGame(
    admin,
    e2eAdmin.profileId,
    `${venuePrefix} Match`,
    matchStart,
    "DEF",
  );
  createdGames.push(match);
  const cancellation = await createGame(
    admin,
    e2eAdmin.profileId,
    `${venuePrefix} Cancel`,
    cancellationStart,
    "ATT",
  );
  createdGames.push(cancellation);

  await assertNoError(
    admin.from("open_queue_referee_assignments").upsert(
      {
        game_id: match.id,
        referee_id: e2eAdmin.profileId,
        assigned_by: e2eAdmin.profileId,
      },
      { onConflict: "game_id" },
    ),
    "assign E2E referee",
  );

  const fillers = players.filter((player) =>
    player.profileId !== main.profileId
  );
  if (fillers.length !== FILLER_ROLES.length) {
    throw new Error("The E2E roster must leave exactly one player unbooked.");
  }

  const policyVersionId = await ensurePolicyTerms(admin, match.id);
  const ratingsBefore = await loadRatings(admin, players);

  logStep("Seeding 11 of 12 match bookings; the UI creates the final booking.");
  const bookingRows = fillers.map((player, index) => ({
    game_id: match.id,
    profile_id: player.profileId,
    role: FILLER_ROLES[index],
    player_rating_at_booking: ratingsBefore[player.profileId],
    amount_paid_fils: 3000,
    base_amount_fils: 3000,
    discount_bps: 0,
    reliability_deposit_fils: 0,
    reliability_deposit_status: "NOT_REQUIRED",
    reliability_policy_version_id: policyVersionId,
    payment_method: "MOCK",
    payment_reference: `field-e2e:${config.runId}:seed:${index + 1}`,
    payment_status: "PAID",
  }));
  await assertNoError(
    admin.from("open_queue_bookings").insert(bookingRows),
    "seed E2E match roster",
  );

  const reportDetails =
    `[FIELD E2E ${config.runId}] Automated player report verification.`;
  const supportDetails =
    `[FIELD E2E ${config.runId}] Automated support request verification.`;

  const manifest: E2EManifest = {
    schemaVersion: E2E_SCHEMA_VERSION,
    runId: config.runId,
    createdAt: new Date().toISOString(),
    target: {
      environment: config.target.environment,
      supabaseUrl: config.supabaseUrl,
      projectRef: targetProjectRef(config.target),
    },
    login: {
      bootstrapPhone: config.bootstrapPhone,
      otpCode: config.otpCode,
      adminProfileId: e2eAdmin.profileId,
      adminPhone: e2eAdmin.phone,
    },
    accounts: {
      main,
      partyTarget,
      onboarding,
      admin: e2eAdmin,
      players,
    },
    games: {
      match: {
        ...match,
        seededConfirmedCount: 11,
      },
      cancellation: {
        ...cancellation,
        seededConfirmedCount: 0,
      },
    },
    markers: {
      venuePrefix,
      reportDetails,
      supportDetails,
      supportContext: {
        field_e2e: true,
        e2e_run_id: config.runId,
      },
    },
    ratingsBefore,
  };

  await writeManifest(config.manifestPath, manifest);
  logStep(
    `Fixture ready. Main player ${main.displayName}; match ${match.id}.`,
  );
} catch (error) {
  const recoveryErrors = await recoverFailedSetup(
    admin,
    e2eAdmin,
    createdGames,
    venuePrefix,
    config.runId,
  );
  if (recoveryErrors.length > 0) {
    throw new Error(
      `${errorMessage(error)} Setup recovery also failed:\n- ${
        recoveryErrors.join("\n- ")
      }`,
      { cause: error },
    );
  }
  throw error;
}

async function recoverFailedSetup(
  client: AdminClient,
  actor: E2EAccount,
  games: Array<Omit<E2EGame, "seededConfirmedCount">>,
  expectedVenuePrefix: string,
  runId: string,
): Promise<string[]> {
  const errors: string[] = [];
  for (const game of [...games].reverse()) {
    if (!game.venue.startsWith(`${expectedVenuePrefix} `)) {
      errors.push(`refused to recover untagged game ${game.id}`);
      continue;
    }
    const { error: cancellationError } = await client.rpc(
      "admin_cancel_match",
      {
        actor_admin_id: actor.profileId,
        match_kind_to_use: "SOLO",
        match_id_to_cancel: game.id,
        reason_code_to_use: "ADMIN_DECISION",
        reason_to_use:
          `Automated Field staging E2E setup recovery for run ${runId}.`,
      },
    );
    if (cancellationError) {
      errors.push(`cancel ${game.id}: ${cancellationError.message}`);
    }
  }

  if (games.length > 0) {
    const { error: assignmentError } = await client
      .from("open_queue_referee_assignments")
      .delete()
      .in("game_id", games.map((game) => game.id))
      .eq("referee_id", actor.profileId);
    if (assignmentError) {
      errors.push(`remove referee assignment: ${assignmentError.message}`);
    }
  }
  return errors;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function ensureAccount(
  client: AdminClient,
  input: {
    phone: string;
    displayName: string;
    username: string;
    password: string;
    dateOfBirth: string | null;
    role: "player" | "admin";
    clearAuthOnboarding?: boolean;
  },
): Promise<E2EAccount> {
  const normalizedPhone = input.phone.replace(/\D/g, "");
  let user = authUsersByPhone.get(normalizedPhone) ?? null;
  const { data: usernameOwner, error: usernameOwnerError } = await client
    .from("profiles")
    .select("id,display_name,username")
    .ilike("username", input.username)
    .maybeSingle();
  if (usernameOwnerError) {
    throw new Error(
      `inspect E2E username ${input.username}: ${usernameOwnerError.message}`,
    );
  }
  if (usernameOwner && usernameOwner.id !== user?.id) {
    throw new Error(
      `Refusing to claim ${input.username}: it belongs to another profile.`,
    );
  }
  const metadata = {
    display_name: input.clearAuthOnboarding ? null : input.displayName,
    name: input.clearAuthOnboarding ? null : input.displayName,
    date_of_birth: input.clearAuthOnboarding ? null : input.dateOfBirth,
    field_e2e: true,
    field_e2e_role: input.role,
  };

  if (user) {
    if (user.user_metadata?.field_e2e !== true) {
      throw new Error(
        `Refusing to reuse ${input.phone}: the existing auth user is not ` +
          "owned by Field E2E.",
      );
    }
    const { data: existingProfile, error: existingProfileError } = await client
      .from("profiles")
      .select("id,display_name,username")
      .eq("id", user.id)
      .maybeSingle();
    if (existingProfileError) {
      throw new Error(
        `inspect existing profile ${input.phone}: ${existingProfileError.message}`,
      );
    }
    if (
      existingProfile &&
      !(
        (existingProfile.username === input.username &&
          String(existingProfile.display_name).startsWith(
            E2E_PROFILE_PREFIX,
          )) ||
        (input.clearAuthOnboarding &&
          existingProfile.username ===
            `e2e_${user.id.replaceAll("-", "").slice(0, 12)}` &&
          existingProfile.display_name === "E2E O.")
      )
    ) {
      throw new Error(
        `Refusing to reuse ${input.phone}: its profile is not owned by ` +
          "Field E2E.",
      );
    }
    if (input.clearAuthOnboarding) {
      if (!isAuthOnlyOnboardingFixture(user)) {
        throw new Error(
          "The existing onboarding fixture predates protected Fieldrush ownership markers. " +
            "Verify its identity and mark or remove that one synthetic Auth user using an administrator before rerunning; " +
            "editable user metadata is not sufficient authority to delete it.",
        );
      }
      // This dedicated, marker-checked signup actor is disposable. Deleting
      // Auth cascades its private account state; clearing editable metadata
      // would not actually reset the server-owned completion state.
      const { error: deletionError } = await client.auth.admin.deleteUser(
        user.id,
      );
      if (deletionError) {
        throw new Error(
          `reset isolated onboarding actor: ${deletionError.message}`,
        );
      }
      authUsersByPhone.delete(normalizedPhone);
      user = null;
    } else {
      user = await updateAuthUser(
        config.supabaseUrl,
        config.serviceRoleKey,
        user.id,
        {
          phone: input.phone,
          phone_confirm: true,
          password: input.password,
          user_metadata: {
            ...user.user_metadata,
            ...metadata,
          },
          app_metadata: {
            ...user.app_metadata,
            fieldrush_e2e: true,
            fieldrush_e2e_role: input.role,
          },
        },
      ).catch((error) => {
        throw new Error(
          `refresh auth user ${input.phone}: ${errorMessage(error)}`,
        );
      });
    }
  }
  if (!user) {
    user = await createAuthUser(
      config.supabaseUrl,
      config.serviceRoleKey,
      {
        phone: input.phone,
        phone_confirm: true,
        password: input.password,
        user_metadata: metadata,
        app_metadata: {
          fieldrush_e2e: true,
          fieldrush_e2e_role: input.clearAuthOnboarding
            ? "onboarding"
            : input.role,
        },
      },
    ).catch((error) => {
      throw new Error(
        `create auth user ${input.phone}: ${errorMessage(error)}`,
      );
    });
  }

  let publicDisplayName = input.displayName;
  if (!input.clearAuthOnboarding) {
    const actor = await createE2EUserClient(config.supabaseUrl, input.phone);
    try {
      const words = input.displayName.trim().split(/\s+/);
      const lastName = words.pop()!;
      const firstName = words.join(" ");
      const { error: signupError } = await actor.rpc(
        "complete_fieldrush_onboarding",
        {
          draft: {
            first_name: firstName,
            last_name: lastName,
            username: input.username,
            date_of_birth: input.dateOfBirth,
            email: `${input.username}@fieldrush-e2e.example`,
          },
          terms_version: "fieldrush-v1",
          privacy_version: "fieldrush-v1",
        },
      );
      if (signupError) {
        throw new Error(`complete E2E signup: ${signupError.message}`);
      }
      const { error: tourError } = await actor.rpc("complete_fieldrush_tour");
      if (tourError) throw tourError;
      publicDisplayName = `${firstName} ${lastName[0].toUpperCase()}.`;
    } finally {
      await actor.auth.signOut();
    }
  }
  authUsersByPhone.set(normalizedPhone, user);

  return {
    profileId: user.id,
    phone: input.phone,
    displayName: publicDisplayName,
    username: input.username,
  };
}

async function ensureBootstrapAccount(): Promise<void> {
  const target = authUsersByPhone.get(config.bootstrapPhone.replace(/\D/g, ""));
  if (
    !target || target.app_metadata?.fieldrush_e2e !== true ||
    target.app_metadata?.fieldrush_e2e_role !== "bootstrap"
  ) {
    throw new Error(
      "The configured bootstrap account needs administrator-verified protected app_metadata " +
        "fieldrush_e2e=true and fieldrush_e2e_role=bootstrap. Refusing to onboard an unmarked staging user.",
    );
  }
  const actor = await createE2EUserClient(
    config.supabaseUrl,
    config.bootstrapPhone,
  );
  try {
    const { data: account, error: accountError } = await actor.rpc(
      "get_my_fieldrush_account",
    );
    if (accountError) throw accountError;
    if (account.onboarding_completed !== true) {
      const { error } = await actor.rpc("complete_fieldrush_onboarding", {
        draft: {
          first_name: account.first_name || "E2E Bootstrap",
          last_name: account.last_name || "Player",
          username: account.username || "field_e2e_bootstrap",
          date_of_birth: account.date_of_birth || E2E_DEFAULT_BIRTH_DATE,
          email: account.email || "field_e2e_bootstrap@fieldrush-e2e.example",
        },
        terms_version: "fieldrush-v1",
        privacy_version: "fieldrush-v1",
      });
      if (error) {
        throw new Error(`complete marked E2E bootstrap: ${error.message}`);
      }
    }
    const { error: tourError } = await actor.rpc("complete_fieldrush_tour");
    if (tourError) throw tourError;
  } finally {
    await actor.auth.signOut();
  }
}

async function loadAuthUsersByPhone(): Promise<Map<string, User>> {
  const usersByPhone = new Map<string, User>();
  for (let page = 1; page <= 20; page += 1) {
    const users = await listAuthUsers(
      config.supabaseUrl,
      config.serviceRoleKey,
      page,
      1000,
    ).catch((error) => {
      throw new Error(`list auth users: ${errorMessage(error)}`);
    });
    for (const user of users) {
      const phone = (user.phone ?? "").replace(/\D/g, "");
      if (phone.length > 0) usersByPhone.set(phone, user);
    }
    if (users.length < 1000) break;
  }
  return usersByPhone;
}

async function closeStaleTransientState(
  client: AdminClient,
  actor: E2EAccount,
  playersToUse: E2EAccount[],
): Promise<void> {
  const { data: games, error: gamesError } = await client
    .from("open_queue_games")
    .select("id,status,venue,created_by")
    .eq("created_by", actor.profileId)
    .like("venue", `${E2E_VENUE_PREFIX}%`)
    .in("status", ["OPEN", "FULL", "LIVE"]);
  if (gamesError) {
    throw new Error(`load stale E2E games: ${gamesError.message}`);
  }

  for (const game of games ?? []) {
    const { error } = await client.rpc("admin_cancel_match", {
      actor_admin_id: actor.profileId,
      match_kind_to_use: "SOLO",
      match_id_to_cancel: game.id,
      reason_code_to_use: "ADMIN_DECISION",
      reason_to_use:
        "Automated Field staging E2E cleanup after an interrupted test run.",
    });
    if (error) {
      throw new Error(`cancel stale E2E game ${game.id}: ${error.message}`);
    }
  }

  const playerIds = playersToUse.map((player) => player.profileId);
  const { data: reports, error: reportsError } = await client
    .from("moderation_reports")
    .select("id,status,details")
    .in("reporter_profile_id", playerIds)
    .like("details", "[FIELD E2E%")
    .in("status", ["OPEN", "TRIAGED", "INVESTIGATING"]);
  if (reportsError) {
    throw new Error(`load stale E2E reports: ${reportsError.message}`);
  }
  for (const report of reports ?? []) {
    const { error } = await client.rpc("admin_update_moderation_report", {
      actor_admin_id: actor.profileId,
      report_id_to_update: report.id,
      action_to_take: "DISMISS",
      resolution_note_to_use:
        "Automated Field staging E2E cleanup after an interrupted run.",
    });
    if (error) {
      throw new Error(
        `dismiss stale E2E report ${report.id}: ${error.message}`,
      );
    }
  }

  const { data: tickets, error: ticketsError } = await client
    .from("support_tickets")
    .select("id,status,revision,details")
    .in("requester_profile_id", playerIds)
    .like("details", "[FIELD E2E%")
    .in("status", ["OPEN", "IN_PROGRESS", "RESOLVED"]);
  if (ticketsError) {
    throw new Error(`load stale E2E tickets: ${ticketsError.message}`);
  }
  for (const ticket of tickets ?? []) {
    let status = String(ticket.status);
    let revision = Number(ticket.revision);

    if (status === "OPEN" || status === "IN_PROGRESS") {
      const { data: resolved, error } = await client.rpc(
        "admin_update_support_ticket",
        {
          actor_admin_id: actor.profileId,
          ticket_id_to_update: ticket.id,
          action_to_take: "RESOLVE",
          expected_revision_to_use: revision,
          resolution_note_to_use:
            "Automated Field staging E2E cleanup completed this test request.",
          admin_note_to_use: "E2E-only support request.",
        },
      );
      if (error) {
        throw new Error(
          `resolve stale E2E ticket ${ticket.id}: ${error.message}`,
        );
      }
      const resolvedRow = unwrapRpcRow(resolved);
      status = String(resolvedRow.status ?? "RESOLVED");
      revision = Number(resolvedRow.revision ?? revision + 1);
    }

    if (status === "RESOLVED") {
      const { error } = await client.rpc("admin_update_support_ticket", {
        actor_admin_id: actor.profileId,
        ticket_id_to_update: ticket.id,
        action_to_take: "CLOSE",
        expected_revision_to_use: revision,
        resolution_note_to_use: null,
        admin_note_to_use: "Closing stale E2E-only support request.",
      });
      if (error) {
        throw new Error(
          `close stale E2E ticket ${ticket.id}: ${error.message}`,
        );
      }
    }
  }
}

async function assertPoolHasNoForeignUpcomingBookings(
  client: AdminClient,
  playersToUse: E2EAccount[],
  actor: E2EAccount,
): Promise<void> {
  const playerIds = playersToUse.map((player) => player.profileId);
  const { data: bookings, error } = await client
    .from("open_queue_bookings")
    .select("game_id,profile_id")
    .in("profile_id", playerIds)
    .eq("status", "CONFIRMED");
  if (error) throw new Error(`load E2E bookings: ${error.message}`);

  const gameIds = [
    ...new Set((bookings ?? []).map((row) => String(row.game_id))),
  ];
  if (gameIds.length === 0) return;
  const { data: games, error: gameError } = await client
    .from("open_queue_games")
    .select("id,status,venue,created_by,starts_at")
    .in("id", gameIds)
    .in("status", ["OPEN", "FULL", "LIVE"]);
  if (gameError) throw new Error(`load booked E2E games: ${gameError.message}`);

  const foreign = (games ?? []).filter((game) =>
    game.created_by !== actor.profileId ||
    !String(game.venue).startsWith(E2E_VENUE_PREFIX)
  );
  if (foreign.length > 0) {
    throw new Error(
      "Refusing E2E setup: a reusable E2E account is booked into a " +
        `non-E2E upcoming game (${foreign.map((game) => game.id).join(", ")}).`,
    );
  }
  const stale = (games ?? []).filter((game) =>
    !isTerminalGameStatus(String(game.status))
  );
  if (stale.length > 0) {
    throw new Error(
      `Stale E2E games remained active after cleanup: ${
        stale.map((game) => game.id).join(", ")
      }.`,
    );
  }
}

async function findUnusedSoloSlots(
  client: AdminClient,
  count: number,
): Promise<Date[]> {
  const now = new Date();
  const earliest = new Date(now.getTime() + 3 * 24 * 60 * 60 * 1000);
  const latest = new Date(Date.now() + 730 * 24 * 60 * 60 * 1000);
  const { data: existing, error } = await client
    .from("open_queue_games")
    .select("starts_at,status")
    .gte("starts_at", now.toISOString())
    .lte("starts_at", latest.toISOString())
    .neq("status", "CANCELLED")
    .order("starts_at")
    .limit(2000);
  if (error) throw new Error(`load occupied solo slots: ${error.message}`);

  const occupied = new Set(
    (existing ?? []).map((row) =>
      new Date(String(row.starts_at)).toISOString()
    ),
  );
  const slots: Date[] = [];
  const cursor = new Date(Date.UTC(
    earliest.getUTCFullYear(),
    earliest.getUTCMonth(),
    earliest.getUTCDate(),
    12,
  ));

  while (cursor <= latest && slots.length < count) {
    // Bahrain is UTC+3 year-round. 20:30 Bahrain is 17:30 UTC.
    const weekday = cursor.getUTCDay();
    if (weekday === 2 || weekday === 5) {
      const candidate = new Date(Date.UTC(
        cursor.getUTCFullYear(),
        cursor.getUTCMonth(),
        cursor.getUTCDate(),
        17,
        30,
      ));
      if (
        candidate.getTime() > earliest.getTime() &&
        !occupied.has(candidate.toISOString())
      ) {
        slots.push(candidate);
      }
    }
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }

  if (slots.length !== count) {
    throw new Error(
      `Could not find ${count} unused Tuesday/Friday solo slots.`,
    );
  }

  const visibleStarts = (existing ?? [])
    .filter((row) => row.status === "OPEN" || row.status === "FULL")
    .map((row) => new Date(String(row.starts_at)).getTime());
  for (const [index, slot] of slots.entries()) {
    const earlierExisting = visibleStarts.filter((start) =>
      start < slot.getTime()
    ).length;
    const earlierFixtureSlots =
      slots.slice(0, index).filter((start) => start < slot).length;
    const feedPosition = earlierExisting + earlierFixtureSlots + 1;
    if (feedPosition > 40) {
      throw new Error(
        "Could not create a discoverable E2E game without touching normal " +
          `staging fixtures; candidate feed position was ${feedPosition}.`,
      );
    }
  }
  return slots;
}

async function createGame(
  client: AdminClient,
  createdBy: string,
  venue: string,
  start: Date,
  mainRole: E2EGame["mainRole"],
): Promise<Omit<E2EGame, "seededConfirmedCount">> {
  const endsAt = new Date(start.getTime() + 60 * 60 * 1000);
  const { data, error } = await client.from("open_queue_games").insert({
    ...legacyOpenQueueFormat,
    venue,
    starts_at: start.toISOString(),
    ends_at: endsAt.toISOString(),
    timezone: "Asia/Bahrain",
    price_fils: 3000,
    age_label: "16+ · E2E",
    created_by: createdBy,
  }).select("id,venue,starts_at,ends_at,capacity").single();
  if (error || !data) {
    throw new Error(`create E2E game ${venue}: ${error?.message ?? "no row"}`);
  }
  return {
    id: requireUuid(data.id, "E2E game id"),
    venue: String(data.venue),
    startsAt: String(data.starts_at),
    endsAt: String(data.ends_at),
    mainRole,
    capacity: 12,
  };
}

async function ensurePolicyTerms(
  client: AdminClient,
  gameId: string,
): Promise<string> {
  const { data, error } = await client.rpc("ensure_match_reliability_terms", {
    match_kind_to_use: "SOLO",
    match_id_to_use: gameId,
  });
  if (error) {
    throw new Error(`bind E2E reliability policy: ${error.message}`);
  }
  const row = unwrapRpcRow(data);
  return requireUuid(row.policy_version_id, "reliability policy version");
}

async function loadRatings(
  client: AdminClient,
  playersToUse: E2EAccount[],
): Promise<Record<string, number>> {
  const playerIds = playersToUse.map((player) => player.profileId);
  const { data, error } = await client
    .from("player_ratings")
    .select("profile_id,skill_rating")
    .in("profile_id", playerIds);
  if (error) throw new Error(`load E2E player ratings: ${error.message}`);
  const ratings: Record<string, number> = {};
  for (const row of data ?? []) {
    ratings[String(row.profile_id)] = Number(row.skill_rating);
  }
  for (const player of playersToUse) {
    if (!Number.isFinite(ratings[player.profileId])) {
      throw new Error(`Missing Player SR for ${player.displayName}.`);
    }
  }
  return ratings;
}
