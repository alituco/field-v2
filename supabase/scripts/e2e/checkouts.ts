import type { AdminClient, E2EAccount } from "./_shared.ts";

/**
 * The service RPC owns the narrowly guarded legacy cleanup. Everything left
 * afterward is a blocker, not permission for the runner to cancel a payment.
 */
export async function cleanAndAssertE2ECheckoutPool(
  client: AdminClient,
  players: E2EAccount[],
  actor: E2EAccount,
): Promise<void> {
  const profileIds = players.map((player) => player.profileId);
  const { error: cleanupError } = await client.rpc(
    "expire_staging_e2e_legacy_checkouts",
    {
      actor_admin_id: actor.profileId,
      player_ids_to_check: profileIds,
    },
  );
  if (cleanupError) {
    throw new Error(
      `E2E checkout cleanup failed: ${cleanupError.message}`,
    );
  }

  const { data, error } = await client
    .from("payment_intents")
    .select("id,profile_id,provider,status,payload")
    .in("profile_id", profileIds)
    .eq("purpose", "SOLO_BOOKING")
    .in("status", ["PENDING", "CAPTURED"]);
  if (error) {
    throw new Error(`E2E checkout preflight failed: ${error.message}`);
  }
  if (!data?.length) return;

  const playerNames = new Map(
    players.map((player) => [player.profileId, player.displayName]),
  );
  const blockers = data.map((intent) => {
    const payload: unknown = intent.payload;
    const gameId = typeof payload === "object" && payload !== null &&
        "game_id" in payload && typeof payload.game_id === "string"
      ? payload.game_id
      : "missing game ID";
    const playerName = playerNames.get(intent.profile_id) ?? "Unknown player";
    return `${playerName} (${intent.profile_id}): intent ${intent.id}, ` +
      `${intent.provider}/${intent.status}, game ${gameId}`;
  });
  throw new Error(
    `E2E checkout preflight found unresolved payments:\n- ${
      blockers.join("\n- ")
    }\nNo remaining payments were altered. Manual reconciliation is required before rerunning E2E.`,
  );
}
