type GoalBody = Record<string, unknown>;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
function identity(value: unknown, message: string) {
  if (typeof value !== "string" || !uuid.test(value)) throw new Error(message);
  return value;
}

export function soloGoalInput(body: GoalBody) {
  if (body.action === "remove_goal") {
    const note = typeof body.note === "string" ? body.note.trim() : "";
    if (note.length < 5 || note.length > 500) throw new Error("Explain why this goal should be removed (5–500 characters).");
    return { action: "REMOVE", goal_id: identity(body.goalId, "Choose the recorded goal."), note };
  }
  if (body.action !== "goal") throw new Error("Choose a goal operation.");
  if (body.clanId !== "WHITE" && body.clanId !== "BLACK") throw new Error("Choose White or Black.");
  const scorer = identity(body.profileId, "Choose the scorer.");
  const assist = body.assistProfileId ? identity(body.assistProfileId, "Choose a valid assist.") : null;
  if (assist === scorer) throw new Error("The scorer cannot assist their own goal.");
  return { action: "ADD", team: body.clanId, profile_id: scorer, assist_profile_id: assist };
}

export class SoloGoalActionError extends Error {
  readonly definitivelyRejected: boolean;
  constructor(message: string, definitivelyRejected: boolean) { super(message); this.definitivelyRejected = definitivelyRejected; }
}

export async function mutateSoloGoal(db: { rpc: (name: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string; code?: string } | null }> }, actorId: string, gameId: string, body: GoalBody) {
  let input: ReturnType<typeof soloGoalInput>; let requestId: string;
  try {
    input = soloGoalInput(body);
    requestId = identity(body.requestId, "Refresh before recording a goal; a request ID is required.");
  } catch (failure) { throw new SoloGoalActionError(failure instanceof Error ? failure.message : "Invalid goal action.", true); }
  const { data, error } = await db.rpc("referee_mutate_solo_goal", {
    actor_referee_id: actorId, game_id_to_use: gameId, request_id_to_use: requestId, goal_input: input,
  });
  if (error) throw new SoloGoalActionError(error.message,
    ["22023", "42501", "23514", "23503", "23502", "23505", "40001", "40P01", "P0001"].includes(error.code ?? "") ||
    (error.code === "57014" && error.message.trim().toLowerCase() === "canceling statement due to statement timeout"));
  assertSoloGoalAcknowledgement(data, gameId, requestId, input.action);
  return { goalOperation: data };
}

export function assertSoloGoalAcknowledgement(data: unknown, gameId: string, requestId: string, action: unknown) {
  const value = data as Record<string, unknown> | null;
  if (!value || Array.isArray(value) || value.game_id !== gameId || value.request_id !== requestId || value.action !== action ||
    typeof value.goal_id !== "string" || !uuid.test(value.goal_id) || typeof value.event_id !== "string" || !uuid.test(value.event_id) ||
    !Number.isInteger(value.white_score) || (value.white_score as number) < 0 || !Number.isInteger(value.black_score) || (value.black_score as number) < 0) {
    throw new Error("The goal operation was not acknowledged. Retry the same action before recording another goal.");
  }
}

/** Keep an ambiguous operation locked to its original payload until acknowledged.
 * Receipts live in sessionStorage too, so refresh/reopening cannot duplicate it.
 */
export function prepareSoloGoalRequest(actorId: string, gameId: string, body: GoalBody, storage: Pick<Storage, "getItem" | "setItem" | "removeItem">, newId: () => string = () => crypto.randomUUID()) {
  const key = `fieldrush:solo-goal:${actorId}:${gameId}`;
  const input = soloGoalInput(body);
  const saved = storage.getItem(key);
  if (saved) {
    const previous = JSON.parse(saved) as { requestId: string; input: unknown };
    if (JSON.stringify(previous.input) !== JSON.stringify(input)) throw new Error("A previous goal action is still unconfirmed. Retry that same scorer/assist or goal removal before making another change.");
    return { ...body, requestId: identity(previous.requestId, "The saved goal request is invalid. Ask an organizer to verify the match.") };
  }
  const requestId = newId();
  storage.setItem(key, JSON.stringify({ requestId, input }));
  return { ...body, requestId };
}

export function acknowledgeSoloGoalRequest(actorId: string, gameId: string, body: GoalBody, payload: unknown, storage: Pick<Storage, "removeItem">) {
  const response = payload as { goalOperation?: unknown } | null;
  assertSoloGoalAcknowledgement(response?.goalOperation, gameId, String(body.requestId), soloGoalInput(body).action);
  rejectSoloGoalRequest(actorId, gameId, storage);
}

export function rejectSoloGoalRequest(actorId: string, gameId: string, storage: Pick<Storage, "removeItem">) {
  storage.removeItem(`fieldrush:solo-goal:${actorId}:${gameId}`);
}

export function pendingSoloGoalRequest(actorId: string, gameId: string, storage: Pick<Storage, "getItem">) {
  const saved = storage.getItem(`fieldrush:solo-goal:${actorId}:${gameId}`);
  if (!saved) return null;
  const previous = JSON.parse(saved) as { requestId: string; input: Record<string, unknown> };
  identity(previous.requestId, "The saved goal request is invalid. Ask an organizer to verify the match.");
  const input = previous.input;
  const body = input.action === "ADD"
    ? { action: "goal", clanId: input.team, profileId: input.profile_id, assistProfileId: input.assist_profile_id }
    : { action: "remove_goal", goalId: input.goal_id, note: input.note };
  soloGoalInput(body);
  return body;
}
