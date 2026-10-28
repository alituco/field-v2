export type GoalCreditClient = {
  rpc: (name: string, args: Record<string, unknown>) => PromiseLike<{
    data: unknown;
    error: unknown;
  }>;
};

/** One server-authoritative list shared by instant downloads and saved clips. */
export async function creditedGoal(
  client: GoalCreditClient,
  sourceType: "CLAN" | "SOLO",
  matchId: string,
  eventId: string,
): Promise<{ occurredAt: string; timestamps: string[] } | null> {
  const { data, error } = await client.rpc("get_credited_replay_goals", {
    source_type_to_use: sourceType,
    match_id_to_use: matchId,
  });
  if (error) throw error;
  if (!Array.isArray(data)) throw new Error("Invalid replay goal response.");
  const goals = data.map((row: unknown) => {
    if (
      !row || typeof row !== "object" || !("id" in row) ||
      !("occurred_at" in row) || typeof row.id !== "string" ||
      typeof row.occurred_at !== "string" ||
      !Number.isFinite(Date.parse(row.occurred_at))
    ) {
      throw new Error("Invalid replay goal response.");
    }
    return { id: row.id, occurredAt: row.occurred_at };
  });
  const selected = goals.find((goal) => goal.id === eventId);
  return selected
    ? {
      occurredAt: selected.occurredAt,
      timestamps: goals.map((g) => g.occurredAt),
    }
    : null;
}
