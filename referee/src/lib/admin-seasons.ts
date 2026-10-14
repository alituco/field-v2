import type { AdminCity } from "./admin-cities";

export type RatingTrack = "OUTFIELD" | "GOALKEEPER";
export type RewardAction = "SAVE" | "PUBLISH" | "CORRECT";
export type SeasonLifecycle = "DRAFT" | "SCHEDULED" | "ACTIVE" | "ENDED";
export type SeasonReadiness = { code: string; message: string; blocking: boolean };
export type AdminSeason = {
  id: string; label: string; startsOn: string; endsOn: string; minimumRatedGames: number;
  revision: number; editable: boolean; publishedRewardsLocked: boolean;
  lifecycle: SeasonLifecycle; visible: boolean; canChangeEnd: boolean;
  canHide: boolean; transitionState: "READY" | "BLOCKED_LIVE"; blockedReason: string | null;
  gamesPlayed: number; rankedPlayers: number; placementPlayers: number;
  unfinishedGames: number; liveGames: number; publishedPrizeCents: number;
  readiness: SeasonReadiness[];
};
export type AdminSeasonReward = {
  seasonId: string; cityId: string; ratingTrack: RatingTrack; currency: "USD";
  firstPrizeCents: number; secondPrizeCents: number; thirdPrizeCents: number;
  status: "DRAFT" | "PUBLISHED"; revision: number; publishedAt: string | null;
};
export type SeasonAuditItem = {
  id: string; seasonId: string; cityId: string | null; ratingTrack: RatingTrack | null;
  action: string; actorAdminId: string | null; reason: string | null; createdAt: string;
  beforeState: Record<string, unknown> | null; afterState: Record<string, unknown> | null;
};
export type AdminSeasonCatalog = {
  today: string; seasons: AdminSeason[]; rewards: AdminSeasonReward[];
  audit: SeasonAuditItem[]; cities: AdminCity[]; currentSeasonId: string | null;
};
export type SeasonTransitionGame = { id: string; venue: string; status: string; kind: string };
export type SeasonTransitionPreview = { currentSeason: AdminSeason; nextSeason: AdminSeason;
  startsOn: string; endsOn: string; liveGames: SeasonTransitionGame[]; unfinishedGames: SeasonTransitionGame[];
  affectedFutureGames: SeasonTransitionGame[]; canSchedule: boolean; blockers: string[] };
export type SeasonEndPreview = { currentSeason: AdminSeason; endsOn: string; liveGames: SeasonTransitionGame[];
  unfinishedGames: SeasonTransitionGame[]; affectedFutureGames: SeasonTransitionGame[]; canSave: boolean; blockers: string[] };

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid season details.");
  return value as Record<string, unknown>;
}

function strict(value: unknown, keys: string[]) {
  const body = record(value);
  if (Object.keys(body).some((key) => !keys.includes(key))) throw new Error("Unknown season detail. Refresh and try again.");
  return body;
}

function integer(value: unknown, label: string, min: number, max: number) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > max) throw new Error(`${label} must be a whole number from ${min} to ${max}.`);
  return value;
}

export function parseSeasonId(value: unknown) {
  if (typeof value !== "string" || value.length > 60 || !/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(value)) throw new Error("Choose a valid season.");
  return value;
}

export function parseRatingTrack(value: unknown): RatingTrack {
  if (value !== "OUTFIELD" && value !== "GOALKEEPER") throw new Error("Choose Outfield or Keeper rewards.");
  return value;
}

function date(value: unknown) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error("Choose a valid season date.");
  const parsed = new Date(`${value}T12:00:00Z`);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value || parsed.getUTCFullYear() < 2000) throw new Error("Choose a valid season date.");
  return value;
}

function label(value: unknown) {
  if (typeof value !== "string" || value.trim().length < 1 || value.trim().length > 40) throw new Error("Season name must be between 1 and 40 characters.");
  return value.trim();
}

export function parseSeasonChangeReason(value: unknown) {
  if (typeof value !== "string" || value.trim().length < 10 || value.trim().length > 1000) throw new Error("Explain this season change in 10–1,000 characters.");
  return value.trim();
}

export function parseAdminSeasonActionInput(value: unknown) {
  const body = strict(value, ["action", "label", "visible", "endsOn", "reason", "expectedRevision"]);
  const actions = ["RENAME", "VISIBILITY", "SCHEDULE", "MAKE_DRAFT", "END_DATE"];
  if (!actions.includes(String(body.action))) throw new Error("Choose a valid season action.");
  const action = String(body.action);
  const values: Record<string, unknown> = {};
  if (action === "RENAME") values.label = label(body.label);
  if (action === "VISIBILITY") {
    if (typeof body.visible !== "boolean") throw new Error("Choose whether this season is visible to players.");
    values.visible_to_players = body.visible;
  }
  if (action === "END_DATE") values.ends_on = date(body.endsOn);
  const permitted = action === "RENAME" ? "label" : action === "VISIBILITY" ? "visible" : action === "END_DATE" ? "endsOn" : null;
  for (const key of ["label", "visible", "endsOn"]) if (key !== permitted && body[key] !== undefined) throw new Error("Unknown detail for this season action.");
  if (action !== "END_DATE" && body.reason !== undefined && body.reason !== null && body.reason !== "") throw new Error("A reason is only used for end-date changes.");
  return { action, values, reason: action === "END_DATE" ? parseSeasonChangeReason(body.reason) : null,
    expectedRevision: integer(body.expectedRevision, "Revision", 1, 2147483647) };
}

export function parseAdminSeasonDuplicateInput(value: unknown) {
  const body = strict(value, ["id", "label", "startsOn", "endsOn", "minimumRatedGames", "expectedSourceRevision"]);
  const parsed = parseAdminSeasonInput({ label: body.label, startsOn: body.startsOn, endsOn: body.endsOn,
    minimumRatedGames: body.minimumRatedGames, expectedRevision: 0 });
  return { id: parseSeasonId(body.id), values: parsed.values,
    expectedSourceRevision: integer(body.expectedSourceRevision, "Source revision", 1, 2147483647) };
}

export function parseAdminSeasonTransitionInput(value: unknown, scheduling = false) {
  const body = strict(value, scheduling ? ["currentSeasonId", "nextSeasonId", "startsOn", "reason", "expectedCurrentRevision", "expectedNextRevision"] : ["currentSeasonId", "nextSeasonId", "startsOn"]);
  const currentSeasonId = parseSeasonId(body.currentSeasonId); const nextSeasonId = parseSeasonId(body.nextSeasonId);
  if (currentSeasonId === nextSeasonId) throw new Error("Choose a different next season.");
  return { currentSeasonId, nextSeasonId, startsOn: date(body.startsOn),
    ...(scheduling ? { reason: parseSeasonChangeReason(body.reason),
      expectedCurrentRevision: integer(body.expectedCurrentRevision, "Current season revision", 1, 2147483647),
      expectedNextRevision: integer(body.expectedNextRevision, "Next season revision", 1, 2147483647) } : {}) };
}

export function parseAdminSeasonEndPreviewInput(value: unknown) {
  return { endsOn: date(strict(value, ["endsOn"]).endsOn) };
}

export function parseAdminSeasonInput(value: unknown) {
  const body = strict(value, ["label", "startsOn", "endsOn", "minimumRatedGames", "expectedRevision"]);
  const seasonLabel = label(body.label);
  const startsOn = date(body.startsOn); const endsOn = date(body.endsOn);
  if (endsOn < startsOn) throw new Error("Season end date must be on or after its start date.");
  if (Date.parse(endsOn) - Date.parse(startsOn) > 370 * 86400000) throw new Error("A season can span at most 370 days between its start and end dates.");
  return {
    expectedRevision: integer(body.expectedRevision, "Revision", 0, 2147483647),
    values: { label: seasonLabel, starts_on: startsOn, ends_on: endsOn,
      minimum_rated_games: integer(body.minimumRatedGames, "Prize qualification games", 2, 100) },
  };
}

/** Parse decimal dollars exactly into cents; never round a submitted third decimal. */
export function parsePrizeUsd(value: unknown): number {
  if (typeof value !== "string" || !/^\d{1,7}(?:\.\d{1,2})?$/.test(value.trim())) throw new Error("Enter a USD prize with at most two decimal places.");
  const [dollars, decimals = ""] = value.trim().split(".");
  const cents = Number(dollars) * 100 + Number(decimals.padEnd(2, "0"));
  if (cents > 100000000) throw new Error("Each cash prize must be between $0 and $1,000,000 USD.");
  return cents;
}

export function parseAdminRewardInput(value: unknown) {
  const body = strict(value, ["firstPrizeUsd", "secondPrizeUsd", "thirdPrizeUsd", "action", "reason", "expectedRevision"]);
  if (!["SAVE", "PUBLISH", "CORRECT"].includes(String(body.action))) throw new Error("Choose save, publish or correct rewards.");
  const action = body.action as RewardAction;
  const reason = typeof body.reason === "string" ? body.reason.trim() : null;
  if (action === "CORRECT" && (!reason || reason.length < 10 || reason.length > 1000)) throw new Error("Explain this published correction in 10–1,000 characters.");
  if (action !== "CORRECT" && body.reason !== undefined && body.reason !== null && body.reason !== "") throw new Error("A correction reason is only used for published corrections.");
  return {
    action, reason: action === "CORRECT" ? reason : null,
    expectedRevision: integer(body.expectedRevision, "Revision", 0, 2147483647),
    values: { first_prize_cents: parsePrizeUsd(body.firstPrizeUsd), second_prize_cents: parsePrizeUsd(body.secondPrizeUsd), third_prize_cents: parsePrizeUsd(body.thirdPrizeUsd) },
  };
}

export function serializeAdminSeason(row: Record<string, unknown>): AdminSeason {
  const stats = row.stats && typeof row.stats === "object" ? row.stats as Record<string, unknown> : {};
  return { id: String(row.id), label: String(row.label), startsOn: String(row.starts_on), endsOn: String(row.ends_on),
    minimumRatedGames: Number(row.minimum_rated_games), revision: Number(row.revision),
    editable: row.editable === true, publishedRewardsLocked: row.published_rewards_locked === true,
    lifecycle: ["DRAFT", "SCHEDULED", "ACTIVE", "ENDED"].includes(String(row.lifecycle)) ? row.lifecycle as SeasonLifecycle : "DRAFT",
    visible: row.visible_to_players === true, canHide: row.can_hide === true, canChangeEnd: row.can_change_end === true,
    transitionState: row.transition_state === "BLOCKED_LIVE" ? "BLOCKED_LIVE" : "READY", blockedReason: row.blocked_reason ? String(row.blocked_reason) : null,
    gamesPlayed: Number(stats.games ?? 0), rankedPlayers: Number(stats.ranked_players ?? 0), placementPlayers: Number(stats.in_placement ?? 0),
    unfinishedGames: Number(stats.unfinished_games ?? 0), liveGames: Number(stats.live_games ?? 0), publishedPrizeCents: Number(stats.published_prize_cents ?? 0),
    readiness: Array.isArray(row.readiness) ? row.readiness.map((message) => ({ code: String(message), message: String(message), blocking: false })) : [] };
}

export function serializeSeasonTransition(row: Record<string, unknown>): SeasonTransitionPreview {
  function games(value: unknown): SeasonTransitionGame[] {
    return Array.isArray(value) ? value.map((item) => ({ id: String(item.id), venue: String(item.venue ?? "Game"), status: String(item.status), kind: String(item.kind) })) : [];
  }
  return { currentSeason: serializeAdminSeason(record(row.current_season)), nextSeason: serializeAdminSeason(record(row.next_season)),
    startsOn: String(row.starts_on), endsOn: String(row.ends_on), liveGames: games(row.live_games), unfinishedGames: games(row.unfinished_games),
    affectedFutureGames: games(row.affected_future_games), canSchedule: row.can_schedule === true, blockers: Array.isArray(row.blockers) ? row.blockers.map(String) : [] };
}

export function serializeSeasonEndPreview(row: Record<string, unknown>): SeasonEndPreview {
  const transition = serializeSeasonTransition({ ...row, next_season: row.current_season });
  return { currentSeason: transition.currentSeason, endsOn: transition.endsOn, liveGames: transition.liveGames,
    unfinishedGames: transition.unfinishedGames, affectedFutureGames: transition.affectedFutureGames,
    canSave: row.can_save === true, blockers: transition.blockers };
}

export function serializeAdminSeasonReward(row: Record<string, unknown>): AdminSeasonReward {
  return { seasonId: String(row.season_id), cityId: String(row.city_id), ratingTrack: parseRatingTrack(row.rating_track), currency: "USD",
    firstPrizeCents: Number(row.first_prize_cents), secondPrizeCents: Number(row.second_prize_cents), thirdPrizeCents: Number(row.third_prize_cents),
    status: row.status === "PUBLISHED" ? "PUBLISHED" : "DRAFT", revision: Number(row.revision), publishedAt: row.published_at ? String(row.published_at) : null };
}

export function serializeSeasonAudit(row: Record<string, unknown>): SeasonAuditItem {
  return { id: String(row.id), seasonId: String(row.season_id), cityId: row.city_id ? String(row.city_id) : null,
    ratingTrack: row.rating_track ? parseRatingTrack(row.rating_track) : null, action: String(row.action), actorAdminId: row.actor_admin_id ? String(row.actor_admin_id) : null,
    reason: row.reason ? String(row.reason) : null, createdAt: String(row.created_at),
    beforeState: row.before_state && typeof row.before_state === "object" ? row.before_state as Record<string, unknown> : null,
    afterState: row.after_state && typeof row.after_state === "object" ? row.after_state as Record<string, unknown> : null };
}

export function seasonErrorMessage(error: { code?: string; message?: string }) {
  if (["42P01", "42703", "PGRST202", "PGRST204", "PGRST205"].includes(error.code ?? "")) return "The seasons and rewards database update is not installed yet. Apply the latest migration, then reload.";
  if (error.code === "40001") return "These settings changed in another session. Refresh before saving again.";
  if (error.code === "23P01") return "Those dates overlap another season. Choose a separate date range.";
  return error.message ?? "Could not update season settings.";
}

export function formatPrize(cents: number) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: cents % 100 === 0 ? 0 : 2, maximumFractionDigits: 2 }).format(cents / 100);
}
