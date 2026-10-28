type DatabaseError = { code?: string; message: string };
type DatabaseResult = { data: unknown; error: DatabaseError | null };
type FinalizationStore = {
  complete: () => PromiseLike<DatabaseResult>;
  readGame: () => PromiseLike<DatabaseResult>;
};

const retryDelayMs = 250;
const wait = (milliseconds: number) => new Promise<void>((resolve) => setTimeout(resolve, milliseconds));

function isStatementTimeout(error: DatabaseError) {
  // 57014 also covers explicit user cancellation. Only this PostgreSQL message
  // confirms the timed-out statement was cancelled and its writes rolled back.
  return error.code === "57014" &&
    error.message.trim().toLowerCase() === "canceling statement due to statement timeout";
}

function verifiedGame(data: unknown, gameId: string) {
  const row = Array.isArray(data) && data.length === 1 ? data[0] : data;
  if (!row || typeof row !== "object" || Array.isArray(row) ||
      !("id" in row) || row.id !== gameId ||
      !("status" in row) || typeof row.status !== "string") {
    throw new Error("Could not verify the solo game completion. Refresh the game before trying again.");
  }
  return row as { id: string; status: string };
}

/** Recover one confirmed database cancellation, never an ambiguous transport failure. */
export async function finalizeSoloMatch(
  gameId: string,
  store: FinalizationStore,
  delay: (milliseconds: number) => Promise<void> = wait,
): Promise<void> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const result = await store.complete();
    if (!result.error) {
      if (verifiedGame(result.data, gameId).status !== "FINAL") {
        throw new Error("Could not verify the solo game completion. Refresh the game before trying again.");
      }
      return;
    }
    const failure = new Error(`Could not finalize solo game: ${result.error.message}`);
    if (!isStatementTimeout(result.error)) throw failure;

    // Back off before the state check, keeping its result adjacent to the next
    // mutation instead of leaving a deliberate stale-state window afterwards.
    if (attempt === 0) await delay(retryDelayMs);
    // Another referee may have completed the game since our rollback. Read
    // before retrying so a committed completion never runs its effects twice.
    const current = await store.readGame();
    if (current.error) {
      throw new Error(`Could not verify solo game after the timeout: ${current.error.message}`);
    }
    const game = verifiedGame(current.data, gameId);
    if (game.status === "FINAL") return;
    if (game.status !== "LIVE" || attempt === 1) throw failure;
  }
}
