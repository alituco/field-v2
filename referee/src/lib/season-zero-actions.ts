import type { SupabaseClient } from "@supabase/supabase-js";

export const SEASON_ZERO_POLICY = "field-sr-season0-v2";

export type SeasonZeroMatchState = {
  game_id: string;
  revision: number;
  lifecycle: "LIVE" | "REVIEW" | "FINAL";
  rating_status: string;
  settlement_status: "UNSETTLED" | "RATED" | "NOT_RATED" | "HELD";
  referee_can_reopen?: boolean;
  elapsed_seconds: number;
  scheduled_seconds: number;
  server_now: string;
  observed_roster: { id: string; team: "A" | "B"; booked_role: string }[];
  events: { type: string; player_id: string | null; second: number; recorded_at: string }[];
  audit: { players: Record<string, { actual_seconds: number; final_state: string; exit_reason: string }> };
};

const participationActions = new Set([
  "JOIN", "EXCUSED_LEAVE", "RETURN", "QUIT", "RED_CARD", "BLUE_CARD", "BLUE_RETURN",
]);

export function seasonZeroActionInput(body: Record<string, unknown>): Record<string, unknown> | null {
  switch (body.action) {
    case "start":
      if (!Array.isArray(body.participantIds) || !body.participantIds.every(id => typeof id === "string")) {
        throw new Error("Confirm the actual starting players.");
      }
      return { action: "START", participant_ids: body.participantIds };
    case "pause": return { action: "PAUSE" };
    case "resume": return { action: "RESUME" };
    case "participation": {
      if (typeof body.participationAction !== "string" || !participationActions.has(body.participationAction)) {
        throw new Error("Choose a valid participation action.");
      }
      if (typeof body.profileId !== "string" || !body.profileId.trim()) throw new Error("Choose a player.");
      return { action: body.participationAction, profile_id: body.profileId, note: String(body.note ?? "").trim() };
    }
    case "blue_card":
      if (typeof body.profileId !== "string" || !body.profileId.trim()) throw new Error("Choose a player.");
      return { action: "BLUE_CARD", profile_id: body.profileId, note: "Two-minute suspension recorded by referee." };
    case "expire_blue_card": throw new Error("Confirm the player’s actual return in Playing time after the two-minute timer expires.");
    case "set_time": throw new Error("This policy needs an audited timeline correction and rating replay. Use the organizer’s rating review.");
    case "override_score": throw new Error("Use the organizer’s Season 0 rating review so this correction also replays dependent matches.");
    // Keep the existing injury/refund evidence path separate from SR events.
    // It does not remove a player from the actual participation timeline.
    case "record_verified_injury": return null;
    case "start_shorthanded":
    case "end_shorthanded":
      throw new Error("Record the individual player’s departure or return in Playing time. Team-level estimates cannot settle this policy.");
    default: return null;
  }
}

export async function loadSeasonZeroState(db: SupabaseClient, actorId: string, gameId: string): Promise<SeasonZeroMatchState | null> {
  const { data, error } = await db.rpc("get_season_zero_match_state", { actor_referee_id: actorId, game_id_to_use: gameId });
  if (error) throw new Error(`Could not load playing time: ${error.message}`);
  if (data !== null && (!data || data.game_id !== gameId || !Number.isInteger(data.revision) || data.revision < 1)) {
    throw new Error("The playing-time response was invalid. Refresh the match before continuing.");
  }
  return data as SeasonZeroMatchState | null;
}

export async function runSeasonZeroAction(db: SupabaseClient, actorId: string, gameId: string, body: Record<string, unknown>) {
  if (body.action === "assign_teams") {
    const { data, error } = await db.rpc("referee_assign_season_zero_teams", {
      actor_referee_id: actorId, game_id_to_use: gameId,
      request_id_to_use: typeof body.requestId === "string" ? body.requestId : crypto.randomUUID(),
    });
    if (error) throw new Error(`Could not assign booked teams: ${error.message}`);
    if (!data || data.game_id !== gameId || data.action !== "ASSIGN") {
      throw new Error("The team assignment was not acknowledged. Refresh before retrying.");
    }
    return { assignment: data };
  }
  if (body.action === "rebalance") {
    const moves = parseSeasonZeroRebalance(body);
    const { data, error } = await db.rpc("referee_rebalance_season_zero_match", {
      actor_referee_id: actorId, game_id_to_use: gameId,
      request_id_to_use: typeof body.requestId === "string" ? body.requestId : crypto.randomUUID(),
      moves_input: moves, reason_to_use: String(body.reason).trim(),
    });
    if (error) throw new Error(`Could not rebalance teams: ${error.message}`);
    if (!data || data.game_id !== gameId || data.action !== "REBALANCE") {
      throw new Error("The team changes were not acknowledged. Refresh before retrying.");
    }
    return { rebalance: data };
  }
  const input = seasonZeroActionInput(body);
  if (!input && body.action !== "finish" && body.action !== "reopen") return null;
  const state = await loadSeasonZeroState(db, actorId, gameId);
  const revision = body.expectedRevision ?? state?.revision ?? 0;
  if (!Number.isInteger(revision) || Number(revision) < 0) throw new Error("Refresh the match before recording this action.");
  const common = {
    actor_referee_id: actorId, game_id_to_use: gameId,
    request_id_to_use: typeof body.requestId === "string" ? body.requestId : crypto.randomUUID(),
    expected_revision: revision,
  };
  const { data, error } = body.action === "finish"
    ? await db.rpc("referee_finish_season_zero_match", common)
    : body.action === "reopen"
      ? await db.rpc("referee_reopen_season_zero_match", common)
    : await db.rpc("referee_season_zero_action", { ...common, action_input: input });
  if (error) throw new Error(`Could not record match action: ${error.message}`);
  assertSeasonZeroAcknowledgement(data, gameId, body.action === "finish");
  if (body.action === "reopen" && (data.lifecycle !== "LIVE" || data.settlement_status !== "HELD" || data.rating_status !== "pending_review")) {
    throw new Error("Reopening was not acknowledged. Refresh its state before retrying.");
  }
  return { seasonZeroState: data };
}

export function assertSeasonZeroAcknowledgement(data: unknown, gameId: string, finished = false): asserts data is SeasonZeroMatchState {
  const state = data as Partial<SeasonZeroMatchState> | null;
  if (!state || state.game_id !== gameId || !Number.isInteger(state.revision) || Number(state.revision) < 1 ||
      !["LIVE", "REVIEW", "FINAL"].includes(String(state.lifecycle)) ||
      (finished && (state.lifecycle !== "FINAL" || !["RATED", "HELD", "NOT_RATED"].includes(String(state.settlement_status))))) {
    throw new Error("The match action was not acknowledged. Refresh its state before retrying.");
  }
}

export function parseSeasonZeroRebalance(body: Record<string, unknown>) {
  if (typeof body.reason !== "string" || body.reason.trim().length < 10 || body.reason.length > 2000 ||
      !Array.isArray(body.moves) || body.moves.length < 1 || body.moves.length > 14) {
    throw new Error("Choose the booked players to move and explain why in at least ten characters.");
  }
  const moves = body.moves.map(value => {
    if (!value || typeof value !== "object" || typeof value.profile_id !== "string" ||
        !["WHITE", "BLACK"].includes(value.to_team) || typeof value.consented !== "boolean") {
      throw new Error("Choose a valid team and record consent for each move.");
    }
    return { profile_id: value.profile_id, to_team: value.to_team as "WHITE" | "BLACK", consented: value.consented };
  });
  if (new Set(moves.map(value => value.profile_id)).size !== moves.length) throw new Error("Choose each player only once.");
  return moves;
}

export function parseSeasonZeroResolution(body: Record<string, unknown>) {
  const input = body.resolution;
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("Choose a rating resolution.");
  const resolution = input as Record<string, unknown>;
  if (Object.keys(resolution).some(key => !["status", "winner", "reason", "played_seconds", "events", "white_score", "black_score"].includes(key)) ||
      !["completed", "forfeit_confirmed", "no_contest", "cancelled", "unranked", "pending_review"].includes(String(resolution.status)) ||
      typeof resolution.reason !== "string" || resolution.reason.trim().length < 10 || resolution.reason.length > 2000 ||
      (resolution.winner != null && !["A", "B"].includes(String(resolution.winner)))) {
    throw new Error("Choose a valid outcome and give an auditable reason of at least ten characters. Rating inputs cannot be edited.");
  }
  for (const key of ["played_seconds", "white_score", "black_score"]) {
    if (resolution[key] !== undefined && (!Number.isInteger(resolution[key]) || Number(resolution[key]) < 0 || Number(resolution[key]) > (key === "played_seconds" ? 10800 : 999))) {
      throw new Error("Use valid whole-number match times and scores.");
    }
  }
  if (resolution.events !== undefined) {
    if (!Array.isArray(resolution.events) || resolution.events.length > 500 || resolution.events.some(event =>
      !event || typeof event !== "object" || Array.isArray(event) ||
      Object.keys(event).some(key => !["id", "type", "second", "player_id", "recorded_at", "note"].includes(key)) ||
      ![...participationActions, "PAUSE", "RESUME"].includes(event.type) ||
      !Number.isInteger(event.second) || event.second < 0 || event.second > 10800)) {
      throw new Error("Provide valid participation events only. The server verifies the entire corrected timeline.");
    }
  }
  return { ...resolution, status: String(resolution.status), reason: resolution.reason.trim() };
}
