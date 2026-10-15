// Never accept a caller-supplied target user ID. Deletion always targets the
// identity returned by Supabase Auth after validating the bearer token.
export function readDeletionConfirmation(body: unknown): boolean {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return false;
  }
  const values = body as Record<string, unknown>;
  return Object.keys(values).length === 2 && values.confirmation === "DELETE" &&
    values.wallet_forfeiture_confirmed === true;
}
