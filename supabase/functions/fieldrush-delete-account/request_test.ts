import { readDeletionConfirmation } from "./request.ts";

Deno.test("deletion accepts only explicit self-deletion confirmation", () => {
  if (!readDeletionConfirmation({ confirmation: "DELETE" })) {
    throw new Error("Expected explicit confirmation to pass.");
  }
  for (
    const value of [
      null,
      [],
      "DELETE",
      {},
      { confirmation: "delete" },
      { confirmation: "DELETE", user_id: "another-user" },
      { confirmation: "DELETE", profile_id: "another-user" },
      { confirmation: "DELETE", confirmed: true },
    ]
  ) {
    if (readDeletionConfirmation(value)) {
      throw new Error("Unexpected deletion request accepted.");
    }
  }
});
