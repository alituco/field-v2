import { readDeletionConfirmation } from "./request.ts";

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
