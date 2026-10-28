type GoalBody = Record<string, unknown>;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
function identity(value: unknown, message: string) {
  if (typeof value !== "string" || !uuid.test(value)) throw new Error(message);
  return value;
}

export function clanGoalInput(body: GoalBody) {
  if (body.action !== "goal") throw new Error("Choose a goal operation.");
  const clan = identity(body.clanId, "Choose the scoring team.");
  const scorer = identity(body.profileId, "Choose the scorer.");
  const assist = body.assistProfileId ? identity(body.assistProfileId, "Choose a valid assist.") : null;
  return { action: "ADD", clan_id: clan, profile_id: scorer, assist_profile_id: assist };
}

export class ClanGoalActionError extends Error {
  readonly definitivelyRejected: boolean;
  constructor(message: string, definitivelyRejected: boolean) { super(message); this.definitivelyRejected = definitivelyRejected; }
}

export async function mutateClanGoal(db: { rpc: (name: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string; code?: string } | null }> }, actorId: string, fixtureId: string, body: GoalBody) {
  let input: ReturnType<typeof clanGoalInput>; let requestId: string;
  try {
    input = clanGoalInput(body);
    requestId = identity(body.requestId, "Refresh before recording a goal; a request ID is required.");
  } catch (failure) { throw new ClanGoalActionError(failure instanceof Error ? failure.message : "Invalid goal action.", true); }
  const { data, error } = await db.rpc("referee_record_fixture_goal_atomic", {
    actor_referee_id: actorId, fixture_id_to_use: fixtureId, request_id_to_use: requestId, goal_input: input,
  });
  if (error) throw new ClanGoalActionError(error.message,
    ["22023", "42501", "23514", "23503", "23502", "23505", "40001", "40P01", "P0001"].includes(error.code ?? "") ||
    (error.code === "57014" && error.message.trim().toLowerCase() === "canceling statement due to statement timeout"));
  assertClanGoalAcknowledgement(data, fixtureId, requestId);
  return { goalOperation: data };
}

export function assertClanGoalAcknowledgement(data: unknown, fixtureId: string, requestId: string) {
  const value = data as Record<string, unknown> | null;
  if (!value || Array.isArray(value) || value.fixture_id !== fixtureId || value.request_id !== requestId || value.action !== "ADD" ||
    typeof value.goal_id !== "string" || !uuid.test(value.goal_id) || typeof value.event_id !== "string" || !uuid.test(value.event_id) ||
    !Number.isInteger(value.home_score) || (value.home_score as number) < 0 || !Number.isInteger(value.away_score) || (value.away_score as number) < 0) {
    throw new Error("The goal operation was not acknowledged. Retry the same action before recording another goal.");
  }
}

/** A lost response must retain the same payload and receipt through refresh. */
export function prepareClanGoalRequest(actorId: string, fixtureId: string, body: GoalBody, storage: Pick<Storage, "getItem" | "setItem" | "removeItem">, newId: () => string = () => crypto.randomUUID()) {
  const key = `fieldrush:clan-goal:${actorId}:${fixtureId}`;
  const input = clanGoalInput(body);
  const saved = storage.getItem(key);
  if (saved) {
    const previous = JSON.parse(saved) as { requestId: string; input: unknown };
    if (JSON.stringify(previous.input) !== JSON.stringify(input)) throw new Error("A previous goal action is still unconfirmed. Retry that same scorer and assist before making another change.");
    return { ...body, requestId: identity(previous.requestId, "The saved goal request is invalid. Ask an organizer to verify the match.") };
  }
  const requestId = newId();
  storage.setItem(key, JSON.stringify({ requestId, input }));
  return { ...body, requestId };
}

export function acknowledgeClanGoalRequest(actorId: string, fixtureId: string, body: GoalBody, payload: unknown, storage: Pick<Storage, "removeItem">) {
  const response = payload as { goalOperation?: unknown } | null;
  assertClanGoalAcknowledgement(response?.goalOperation, fixtureId, String(body.requestId));
  rejectClanGoalRequest(actorId, fixtureId, storage);
}

export function rejectClanGoalRequest(actorId: string, fixtureId: string, storage: Pick<Storage, "removeItem">) {
  storage.removeItem(`fieldrush:clan-goal:${actorId}:${fixtureId}`);
}

export function pendingClanGoalRequest(actorId: string, fixtureId: string, storage: Pick<Storage, "getItem">) {
  const saved = storage.getItem(`fieldrush:clan-goal:${actorId}:${fixtureId}`);
  if (!saved) return null;
  const previous = JSON.parse(saved) as { requestId: string; input: Record<string, unknown> };
  identity(previous.requestId, "The saved goal request is invalid. Ask an organizer to verify the match.");
  const input = previous.input;
  const body = { action: "goal", clanId: input.clan_id, profileId: input.profile_id, assistProfileId: input.assist_profile_id };
  clanGoalInput(body);
  return body;
}
