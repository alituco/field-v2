import type { AdminCity } from "./admin-cities";

export type RatingTrack = "OUTFIELD" | "GOALKEEPER";
export type RewardAction = "SAVE" | "PUBLISH" | "CORRECT";
export type AdminSeason = {
  id: string; label: string; startsOn: string; endsOn: string; minimumRatedGames: number;
  revision: number; editable: boolean; publishedRewardsLocked: boolean;
};
export type AdminSeasonReward = {
  seasonId: string; cityId: string; ratingTrack: RatingTrack; currency: "USD";
  firstPrizeCents: number; secondPrizeCents: number; thirdPrizeCents: number;
  status: "DRAFT" | "PUBLISHED"; revision: number; publishedAt: string | null;
};
export type SeasonAuditItem = {
  id: string; seasonId: string; cityId: string | null; ratingTrack: RatingTrack | null;
  action: string; actorAdminId: string; reason: string | null; createdAt: string;
  beforeState: Record<string, unknown> | null; afterState: Record<string, unknown> | null;
};
export type AdminSeasonCatalog = {
  today: string; seasons: AdminSeason[]; rewards: AdminSeasonReward[];
  audit: SeasonAuditItem[]; cities: AdminCity[];
};

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

export function parseAdminSeasonInput(value: unknown) {
  const body = strict(value, ["label", "startsOn", "endsOn", "minimumRatedGames", "expectedRevision"]);
  if (typeof body.label !== "string" || body.label.trim().length < 1 || body.label.trim().length > 40) throw new Error("Season name must be between 1 and 40 characters.");
  const startsOn = date(body.startsOn); const endsOn = date(body.endsOn);
  if (endsOn < startsOn) throw new Error("Season end date must be on or after its start date.");
  if (Date.parse(endsOn) - Date.parse(startsOn) > 370 * 86400000) throw new Error("A season can span at most 370 days between its start and end dates.");
  return {
    expectedRevision: integer(body.expectedRevision, "Revision", 0, 2147483647),
    values: { label: body.label.trim(), starts_on: startsOn, ends_on: endsOn,
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
  return { id: String(row.id), label: String(row.label), startsOn: String(row.starts_on), endsOn: String(row.ends_on),
    minimumRatedGames: Number(row.minimum_rated_games), revision: Number(row.revision),
    editable: row.editable === true, publishedRewardsLocked: row.published_rewards_locked === true };
}

export function serializeAdminSeasonReward(row: Record<string, unknown>): AdminSeasonReward {
  return { seasonId: String(row.season_id), cityId: String(row.city_id), ratingTrack: parseRatingTrack(row.rating_track), currency: "USD",
    firstPrizeCents: Number(row.first_prize_cents), secondPrizeCents: Number(row.second_prize_cents), thirdPrizeCents: Number(row.third_prize_cents),
    status: row.status === "PUBLISHED" ? "PUBLISHED" : "DRAFT", revision: Number(row.revision), publishedAt: row.published_at ? String(row.published_at) : null };
}

export function serializeSeasonAudit(row: Record<string, unknown>): SeasonAuditItem {
  return { id: String(row.id), seasonId: String(row.season_id), cityId: row.city_id ? String(row.city_id) : null,
    ratingTrack: row.rating_track ? parseRatingTrack(row.rating_track) : null, action: String(row.action), actorAdminId: String(row.actor_admin_id),
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
