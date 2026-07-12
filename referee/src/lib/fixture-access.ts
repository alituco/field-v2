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

