import {
  createAdminClient,
  createE2EStaffClient,
  createE2EUserClient,
  E2E_STAFF_EMAIL,
  isTerminalGameStatus,
  listAuthUsers,
  loadManifestConfig,
  logStep,
  requireIndependentE2EStaff,
  unwrapRpcRow,
  updateAuthUser,
} from "./_shared.ts";
import { cleanAndAssertE2ECheckoutPool } from "./checkouts.ts";
import { isCurrentRunFixture } from "../../functions/_shared/dev_auth.ts";

if (Deno.args.includes("--help")) {
  console.log(`Usage:
  deno run --allow-env --allow-net --allow-read \\
    supabase/scripts/e2e/cleanup_staging.ts

Required environment:
  SUPABASE_URL
  SUPABASE_SERVICE_ROLE_KEY
  FIELD_ENVIRONMENT=staging
  E2E_CONFIRM_TARGET=FIELD_STAGING_E2E
  E2E_RUN_ID
  E2E_MANIFEST_PATH

Cleanup deliberately does not delete FINAL matches, Player SR events,
attendance decisions, wallet entries, or admin audit events. Those records
are append-only by design. It cancels transient games, removes the temporary
referee assignment, closes test queues, and restores the reusable accounts.`);
  Deno.exit(0);
}

const config = await loadManifestConfig("staging E2E cleanup");
const manifest = config.manifest;
const staffIdentity = requireIndependentE2EStaff(manifest);
const admin = createAdminClient(config.supabaseUrl, config.serviceRoleKey);
const errors: string[] = [];

logStep(`Cleaning transient state for E2E run ${manifest.runId}.`);
await bestEffort("cancel transient E2E games", cancelTransientGames);
await bestEffort(
  "close unpaid legacy E2E checkouts",
  () =>
    cleanAndAssertE2ECheckoutPool(
      admin,
      [...manifest.accounts.players, manifest.accounts.onboarding],
      manifest.accounts.admin,
    ),
);
await bestEffort("remove E2E referee assignment", removeRefereeAssignment);
await bestEffort("dismiss E2E moderation reports", dismissReports);
await bestEffort("close E2E support requests", closeSupportTickets);
await bestEffort(
  "revoke owned E2E sessions and credentials",
  restoreAccountBaselines,
);

if (errors.length > 0) {
  throw new Error(
    `E2E cleanup completed with ${errors.length} error(s):\n- ${
      errors.join("\n- ")
    }`,
  );
}

logStep(
  "Cleanup complete. Tagged FINAL/SR/attendance/audit history was retained.",
);
console.log("FIELD_E2E_CLEANUP=complete");

async function cancelTransientGames(): Promise<void> {
  const { data, error } = await admin
    .from("open_queue_games")
    .select("id,status,venue,created_by,created_by_staff_id")
    .in("id", [manifest.games.match.id, manifest.games.cancellation.id]);
  if (error) throw new Error(`load manifest games: ${error.message}`);

  for (const game of data ?? []) {
    if (isTerminalGameStatus(String(game.status))) continue;
    if (
      (game.created_by_staff_id ?? game.created_by) !==
        manifest.accounts.admin.profileId ||
      !String(game.venue).startsWith(manifest.markers.venuePrefix)
    ) {
      throw new Error(
        `refusing to cancel untagged manifest game ${game.id}`,
      );
    }
    const { error: cancellationError } = await admin.rpc(
      "admin_cancel_match",
      {
        actor_admin_id: manifest.accounts.admin.profileId,
        match_kind_to_use: "SOLO",
        match_id_to_cancel: game.id,
        reason_code_to_use: "ADMIN_DECISION",
        reason_to_use:
          `Automated Field staging E2E cleanup for run ${manifest.runId}.`,
      },
    );
    if (cancellationError) {
      throw new Error(
        `cancel game ${game.id}: ${cancellationError.message}`,
      );
    }
  }
}

async function removeRefereeAssignment(): Promise<void> {
  const { data, error } = await admin
    .from("open_queue_referee_assignments")
    .select("game_id,referee_id")
    .eq("game_id", manifest.games.match.id)
    .maybeSingle();
  if (error) {
    throw new Error(`load E2E referee assignment: ${error.message}`);
  }
  if (!data) return;
  if (data.referee_id !== manifest.accounts.admin.profileId) {
    throw new Error(
      "refusing to remove an assignment owned by another referee",
    );
  }
  const { error: deleteError } = await admin
    .from("open_queue_referee_assignments")
    .delete()
    .eq("game_id", manifest.games.match.id)
    .eq("referee_id", manifest.accounts.admin.profileId);
  if (deleteError) {
    throw new Error(`remove E2E referee assignment: ${deleteError.message}`);
  }
}

async function dismissReports(): Promise<void> {
  const { data, error } = await admin
    .from("moderation_reports")
    .select("id,status,details")
    .eq("details", manifest.markers.reportDetails);
  if (error) throw new Error(`load E2E reports: ${error.message}`);

  for (const report of data ?? []) {
    if (
      ["ACTIONED", "RESOLVED", "DISMISSED", "DUPLICATE"].includes(
        String(report.status),
      )
    ) {
      continue;
    }
    const { error: updateError } = await admin.rpc(
      "admin_update_moderation_report",
      {
        actor_admin_id: manifest.accounts.admin.profileId,
        report_id_to_update: report.id,
        action_to_take: "DISMISS",
        resolution_note_to_use:
          `Automated E2E cleanup for run ${manifest.runId}.`,
      },
    );
    if (updateError) {
      throw new Error(`dismiss report ${report.id}: ${updateError.message}`);
    }
  }
}

async function closeSupportTickets(): Promise<void> {
  const { data, error } = await admin
    .from("support_tickets")
    .select("id,status,revision,details,requester_profile_id")
    .eq("requester_profile_id", manifest.accounts.main.profileId)
    .eq("details", manifest.markers.supportDetails);
  if (error) throw new Error(`load E2E support tickets: ${error.message}`);

  for (const ticket of data ?? []) {
    let status = String(ticket.status);
    let revision = Number(ticket.revision);

    if (status === "OPEN" || status === "IN_PROGRESS") {
      const { data: resolved, error: resolveError } = await admin.rpc(
        "admin_update_support_ticket",
        {
          actor_admin_id: manifest.accounts.admin.profileId,
          ticket_id_to_update: ticket.id,
          action_to_take: "RESOLVE",
          expected_revision_to_use: revision,
          resolution_note_to_use:
            `Automated E2E verification completed for run ${manifest.runId}.`,
          admin_note_to_use: "Field staging E2E request.",
        },
      );
      if (resolveError) {
        throw new Error(
          `resolve support ticket ${ticket.id}: ${resolveError.message}`,
        );
      }
      const resolvedRow = unwrapRpcRow(resolved);
      status = String(resolvedRow.status ?? "RESOLVED");
      revision = Number(resolvedRow.revision ?? revision + 1);
    }

    if (status === "RESOLVED") {
      const { error: closeError } = await admin.rpc(
        "admin_update_support_ticket",
        {
          actor_admin_id: manifest.accounts.admin.profileId,
          ticket_id_to_update: ticket.id,
          action_to_take: "CLOSE",
          expected_revision_to_use: revision,
          resolution_note_to_use: null,
          admin_note_to_use:
            `Closing completed staging E2E request ${manifest.runId}.`,
        },
      );
      if (closeError) {
        throw new Error(
          `close support ticket ${ticket.id}: ${closeError.message}`,
        );
      }
    }
  }
}

async function restoreAccountBaselines(): Promise<void> {
  const accounts = [
    ...manifest.accounts.players,
    manifest.accounts.onboarding,
    manifest.accounts.admin,
  ];
  const authUsersById = new Map<
    string,
    Awaited<ReturnType<typeof listAuthUsers>>[number]
  >();
  for (let page = 1; page <= 20; page += 1) {
    const users = await listAuthUsers(
      config.supabaseUrl,
      config.serviceRoleKey,
      page,
      1000,
    );
    for (const user of users) authUsersById.set(user.id, user);
    if (users.length < 1000) break;
  }

  const bootstrap = [...authUsersById.values()].find((user) =>
    user.phone?.replace(/\D/g, "") ===
      manifest.login.bootstrapPhone.replace(/\D/g, "")
  );
  if (bootstrap) {
    accounts.push({
      profileId: bootstrap.id,
      phone: bootstrap.phone!,
      displayName: "E2E bootstrap",
      username: "field_e2e_bootstrap",
    });
  }

  for (const account of accounts) {
    const isStaff = account.profileId === manifest.accounts.admin.profileId;
    const authUserId = isStaff ? staffIdentity.authUserId : account.profileId;
    const existing = authUsersById.get(authUserId);
    if (!existing) {
      throw new Error(
        `load auth baseline ${account.profileId}: user missing`,
      );
    }

    if (
      isStaff && (existing.email !== E2E_STAFF_EMAIL || existing.phone ||
        existing.app_metadata?.fieldrush_e2e !== true ||
        existing.app_metadata?.fieldrush_e2e_role !== "admin" ||
        existing.app_metadata?.fieldrush_account_type !== "staff")
    ) {
      throw new Error(
        "Refusing to retire an unmarked independent staff fixture.",
      );
    }

    if (
      existing.app_metadata?.fieldrush_e2e_revoked_run_id === manifest.runId &&
      existing.app_metadata?.fieldrush_e2e_run_id == null
    ) {
      if (isStaff) {
        await bestEffort(
          "retire previously revoked staff access",
          retireIndependentStaffAccess,
        );
      }
      continue;
    }
    if (
      !isCurrentRunFixture(existing, manifest.runId, Date.now()) ||
      (isStaff
        ? existing.email !== E2E_STAFF_EMAIL || Boolean(existing.phone) ||
          existing.app_metadata?.fieldrush_account_type !== "staff" ||
          existing.app_metadata?.fieldrush_e2e_role !== "admin"
        : existing.phone?.replace(/\D/g, "") !==
          account.phone.replace(/\D/g, ""))
    ) {
      throw new Error(
        `refusing to change unmarked account ${account.profileId}`,
      );
    }
    await bestEffort(`close owned fixture ${account.profileId}`, async () => {
      // Revoke refresh sessions before rotating the per-run fixture password.
      // A prior JWT is never saved in a manifest or copied into another run.
      let logoutFailed = false;
      try {
        const actor = isStaff
          ? await createE2EStaffClient(config.supabaseUrl, staffIdentity.email)
          : await createE2EUserClient(config.supabaseUrl, account.phone);
        const { data: sessionData } = await actor.auth.getSession();
        const token = sessionData.session?.access_token;
        const { error } = token
          ? await admin.auth.admin.signOut(token, "global")
          : {
            error: new Error("Synthetic E2E logout session was unavailable"),
          };
        logoutFailed = error != null;
      } catch {
        // Still close protected ownership, password and staff access below.
        logoutFailed = true;
      }
      const password = Array.from(
        crypto.getRandomValues(new Uint8Array(32)),
        (byte) => byte.toString(16).padStart(2, "0"),
      ).join("");
      await updateAuthUser(
        config.supabaseUrl,
        config.serviceRoleKey,
        authUserId,
        {
          password,
          app_metadata: {
            ...existing.app_metadata,
            fieldrush_e2e_run_id: null,
            fieldrush_e2e_revoked_run_id: manifest.runId,
          },
        },
      );
      if (isStaff) {
        await retireIndependentStaffAccess();
      }
      if (logoutFailed) {
        throw new Error("Could not confirm isolated E2E session revocation");
      }
    });
  }
}

async function retireIndependentStaffAccess(): Promise<void> {
  const { data, error } = await admin.from("referee_profiles").update({
    is_active: false,
  })
    .eq("profile_id", manifest.accounts.admin.profileId).eq(
      "auth_user_id",
      staffIdentity.authUserId,
    )
    .eq("email", E2E_STAFF_EMAIL).select("profile_id").maybeSingle();
  if (error || !data) {
    throw new Error("Could not retire the exact isolated E2E staff access.");
  }
}

async function bestEffort(
  label: string,
  operation: () => Promise<void>,
): Promise<void> {
  try {
    await operation();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    errors.push(`${label}: ${message}`);
  }
}
