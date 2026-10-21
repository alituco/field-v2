import {
  isStaffDeletionIdentity,
  readDeletionConfirmation,
} from "./request.ts";

Deno.test("player deletion rejects server-marked staff but not a former staff player identity", () => {
  if (
    !isStaffDeletionIdentity({
      app_metadata: { fieldrush_account_type: "staff" },
    }) ||
    isStaffDeletionIdentity({
      app_metadata: { fieldrush_account_type: "player" },
    }) ||
    isStaffDeletionIdentity({ app_metadata: {} }) || isStaffDeletionIdentity({})
  ) {
    throw new Error(
      "Player and independent staff deletion realms were confused.",
    );
  }
});

Deno.test("deletion accepts only explicit self-deletion confirmation", () => {
  if (
    !readDeletionConfirmation({
      confirmation: "DELETE",
      wallet_forfeiture_confirmed: true,
    })
  ) {
    throw new Error("Expected explicit confirmation to pass.");
  }
  for (
    const value of [
      null,
      [],
      "DELETE",
      {},
      { confirmation: "DELETE" },
      { confirmation: "DELETE", wallet_forfeiture_confirmed: false },
      { confirmation: "DELETE", wallet_forfeiture_confirmed: "true" },
      { confirmation: "DELETE", wallet_forfeiture_confirmed: null },
      { confirmation: "delete" },
      { confirmation: "DELETE", user_id: "another-user" },
      { confirmation: "DELETE", profile_id: "another-user" },
      { confirmation: "DELETE", confirmed: true },
      {
        confirmation: "DELETE",
        wallet_forfeiture_confirmed: true,
        user_id: "another-user",
      },
    ]
  ) {
    if (readDeletionConfirmation(value)) {
      throw new Error("Unexpected deletion request accepted.");
    }
  }
});
