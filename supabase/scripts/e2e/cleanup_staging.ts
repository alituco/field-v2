import {
  createAdminClient,
  isTerminalGameStatus,
  listAuthUsers,
  loadManifestConfig,
  logStep,
  unwrapRpcRow,
  updateAuthUser,
} from "./_shared.ts";

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
const admin = createAdminClient(config.supabaseUrl, config.serviceRoleKey);
const errors: string[] = [];

logStep(`Cleaning transient state for E2E run ${manifest.runId}.`);
await bestEffort("cancel transient E2E games", cancelTransientGames);
await bestEffort("remove E2E referee assignment", removeRefereeAssignment);
await bestEffort("dismiss E2E moderation reports", dismissReports);
await bestEffort("close E2E support requests", closeSupportTickets);
await bestEffort("verify isolated account ownership", restoreAccountBaselines);

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
    .select("id,status,venue,created_by")
    .in("id", [manifest.games.match.id, manifest.games.cancellation.id]);
  if (error) throw new Error(`load manifest games: ${error.message}`);

  for (const game of data ?? []) {
    if (isTerminalGameStatus(String(game.status))) continue;
    if (
      game.created_by !== manifest.accounts.admin.profileId ||
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

  for (const account of accounts) {
    const existing = authUsersById.get(account.profileId);
    if (!existing) {
      throw new Error(
        `load auth baseline ${account.profileId}: user missing`,
      );
    }

    if (existing.user_metadata?.field_e2e !== true) {
      throw new Error(
        `refusing to change unmarked account ${account.profileId}`,
      );
    }
    // Never reset the server-owned signup state or rewrite private DOB into
    // public profiles. The dedicated onboarding actor is recreated next setup.
    await updateAuthUser(
      config.supabaseUrl,
      config.serviceRoleKey,
      account.profileId,
      {
        user_metadata: {
          ...existing.user_metadata,
          field_e2e: true,
          field_e2e_role: account.profileId ===
              manifest.accounts.admin.profileId
            ? "admin"
            : "player",
        },
      },
    ).catch((error) => {
      throw new Error(
        `restore auth baseline ${account.profileId}: ${String(error)}`,
      );
    });
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
