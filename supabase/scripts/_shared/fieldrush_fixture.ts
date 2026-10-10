import { createClient } from "npm:@supabase/supabase-js@2.86.0";
import { assertSafeDevDataTarget } from "./environment_guard.ts";

/** Complete synthetic local users through the real, authenticated signup RPC.
 * No test-only SQL bypass or auto-completion trigger is installed in the DB.
 */
export async function completeLocalFieldrushFixture(input: {
  url: string;
  publishableKey: string;
  phone: string;
  password: string;
  firstName: string;
  lastName: string;
  username: string;
  dateOfBirth: string;
}): Promise<void> {
  if (
    assertSafeDevDataTarget(input.url, "Fieldrush fixture signup")
      .environment !== "local"
  ) {
    throw new Error("Fieldrush fixture signup is local-only.");
  }
  const client = createClient(input.url, input.publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { error: loginError } = await client.auth.signInWithPassword({
    phone: input.phone,
    password: input.password,
  });
  if (loginError) throw loginError;
  try {
    const { error } = await client.rpc("complete_fieldrush_onboarding", {
      draft: {
        first_name: input.firstName,
        last_name: input.lastName,
        username: input.username,
        date_of_birth: input.dateOfBirth,
        email: `${input.username}@fieldrush-fixture.example`,
      },
      terms_version: "fieldrush-v1",
      privacy_version: "fieldrush-v1",
    });
    if (error) throw error;
    const { error: tourError } = await client.rpc("complete_fieldrush_tour");
    if (tourError) throw tourError;
  } finally {
    await client.auth.signOut();
  }
}
