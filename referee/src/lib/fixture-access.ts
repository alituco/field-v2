import type { SupabaseClient } from "@supabase/supabase-js";

export async function assertCanManageFixture(
  db: SupabaseClient,
  fixtureId: string,
  refereeId: string,
  role: "admin" | "referee",
) {
  if (role === "admin") return;

  const { data, error } = await db
    .from("fixture_referee_assignments")
    .select("fixture_id")
    .eq("fixture_id", fixtureId)
    .eq("referee_id", refereeId)
    .maybeSingle();

  if (error) throw new Error(`Could not verify assignment: ${error.message}`);
  if (!data) throw new Error("This match is not assigned to you.");
}

export async function assertCanManageOpenQueueGame(
  db: SupabaseClient,
  gameId: string,
  refereeId: string,
  role: "admin" | "referee",
) {
  if (role === "admin") return;

  const { data, error } = await db
    .from("open_queue_referee_assignments")
    .select("game_id")
    .eq("game_id", gameId)
    .eq("referee_id", refereeId)
    .maybeSingle();

  if (error) throw new Error(`Could not verify assignment: ${error.message}`);
  if (!data) throw new Error("This solo game is not assigned to you.");
}
