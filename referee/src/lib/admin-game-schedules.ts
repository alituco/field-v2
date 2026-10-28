import { parseSoloFormation, parseSoloMinimumPlayers, type SoloFormation } from "./admin-solo-games.ts";

export type ScheduleOccurrence = {
  matchDate: string;
  status: "CREATED" | "SKIPPED" | "CONFLICT";
  gameId: string | null;
  errorMessage: string | null;
};

export type AdminGameSchedule = SoloFormation & {
  minimumPlayers: number;
  participationRulesVersion: string;
  id: string; name: string; fieldId: string; fieldName: string;
  weekdays: number[]; kickoffTime: string; durationMinutes: number;
  startsOn: string; endsOn: string | null; bookingWindowDays: number;
  priceUsd: string; ageLabel: string; highestDivision: number; lowestDivision: number;
  isActive: boolean; timezone: string;
  createdAt: string; updatedAt: string;
  occurrences: ScheduleOccurrence[];
  skips: Array<{ matchDate: string; reason: string }>;
};

export const SCHEDULE_SELECT = "id,name,field_id,weekdays,kickoff_time,duration_minutes,starts_on,ends_on,booking_window_days,price_fils,age_label,highest_division,lowest_division,goalkeepers_per_side,defenders_per_side,attackers_per_side,minimum_players,participation_rules_version,is_active,timezone,created_at,updated_at";
const FORMATION_KEYS = ["goalkeepersPerSide", "defendersPerSide", "attackersPerSide"];
const KEYS = ["name", "fieldId", "weekdays", "kickoffTime", "durationMinutes", "startsOn", "endsOn", "bookingWindowDays", "priceUsd", "ageLabel", "highestDivision", "lowestDivision", "minimumPlayers", "isActive", ...FORMATION_KEYS];

export function parseScheduleId(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw new Error("Choose a valid schedule.");
  return value;
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid schedule details.");
  return value as Record<string, unknown>;
}

function text(value: unknown, label: string, min: number, max: number): string {
  if (typeof value !== "string" || value.trim().length < min || value.trim().length > max) throw new Error(`${label} must be between ${min} and ${max} characters.`);
  return value.trim();
}

export function parseScheduleDate(value: unknown): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error("Choose a valid calendar date.");
  const date = new Date(`${value}T12:00:00Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== value || date.getUTCFullYear() < 2000) throw new Error("Choose a valid calendar date.");
  return value;
}

export function parseKickoffTime(value: unknown): string {
  if (typeof value !== "string" || !/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value)) throw new Error("Choose a valid kickoff time (HH:MM).");
  return value;
}

function integer(value: unknown, label: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) throw new Error(`${label} must be a whole number from ${min} to ${max}.`);
  return value;
}

export function parseGameDuration(value: unknown): number {
  return integer(value, "Duration in minutes", 30, 180);
}

export function parseSchedulePrice(value: unknown): number {
  if ((typeof value !== "string" && typeof value !== "number") || !/^\d{1,3}(?:\.\d{1,2})?$/.test(String(value).trim())) throw new Error("Price must be a valid USD amount with up to 2 decimals.");
  const mills = Math.round(Number(value) * 1000);
  if (!Number.isSafeInteger(mills) || mills > 100000 || (mills !== 0 && mills < 500)) throw new Error("Price must be $0 for a free game, or between $0.50 and $100 USD.");
  return mills;
}

/** Returns a strict allowlisted DB payload. The server supplies the actor. */
export function parseAdminGameScheduleInput(value: unknown, partial = false): Record<string, unknown> {
  const body = record(value);
  if (Object.keys(body).some((key) => !KEYS.includes(key)) || Object.keys(body).length === 0) throw new Error("Unknown or missing schedule detail. Refresh and try again.");
  const result: Record<string, unknown> = {};
  if (!partial || "minimumPlayers" in body) result.minimum_players = parseSoloMinimumPlayers(body.minimumPlayers);
  if (!partial || FORMATION_KEYS.some((key) => key in body)) {
    const formation = parseSoloFormation(body, !partial);
    result.goalkeepers_per_side = formation.goalkeepersPerSide;
    result.defenders_per_side = formation.defendersPerSide;
    result.attackers_per_side = formation.attackersPerSide;
  }
  if (!partial || "name" in body) result.name = text(body.name, "Schedule name", 2, 80);
  if (!partial || "fieldId" in body) {
    try { result.field_id = parseScheduleId(body.fieldId); } catch { throw new Error("Choose an active saved field."); }
  }
  if (!partial || "weekdays" in body) {
    if (!Array.isArray(body.weekdays) || !body.weekdays.length || body.weekdays.length > 7 || body.weekdays.some((day) => !Number.isInteger(day) || day < 1 || day > 7) || new Set(body.weekdays).size !== body.weekdays.length) throw new Error("Choose one or more different weekdays.");
    result.weekdays = [...body.weekdays].sort((a, b) => a - b);
  }
  if (!partial || "kickoffTime" in body) result.kickoff_time = parseKickoffTime(body.kickoffTime);
  if (!partial || "durationMinutes" in body) result.duration_minutes = parseGameDuration(body.durationMinutes ?? (!partial ? 60 : null));
  if (!partial || "startsOn" in body) result.starts_on = parseScheduleDate(body.startsOn);
  if (!partial || "endsOn" in body) result.ends_on = body.endsOn === null || body.endsOn === "" || (!partial && body.endsOn === undefined) ? null : parseScheduleDate(body.endsOn);
  if (typeof result.starts_on === "string" && typeof result.ends_on === "string" && result.ends_on < result.starts_on) throw new Error("End date must be on or after the start date.");
  if (!partial || "bookingWindowDays" in body) result.booking_window_days = integer(body.bookingWindowDays ?? (!partial ? 28 : null), "Booking window in days", 7, 84);
  if (!partial || "priceUsd" in body) result.price_fils = parseSchedulePrice(body.priceUsd ?? (!partial ? "13.00" : null));
  if (!partial || "ageLabel" in body) result.age_label = text(body.ageLabel ?? (!partial ? "18+" : null), "Age label", 2, 40);
  if (!partial || "highestDivision" in body) result.highest_division = integer("highestDivision" in body ? body.highestDivision : 1, "Highest division", 1, 5);
  if (!partial || "lowestDivision" in body) result.lowest_division = integer("lowestDivision" in body ? body.lowestDivision : 5, "Lowest division", 1, 5);
  if (typeof result.highest_division === "number" && typeof result.lowest_division === "number" && result.highest_division > result.lowest_division) throw new Error("Highest division must be less than or equal to lowest division.");
  if (!partial || "isActive" in body) {
    const active = body.isActive ?? (!partial ? true : null);
    if (typeof active !== "boolean") throw new Error("Active status must be true or false.");
    result.is_active = active;
  }
  return result;
}

export function parseScheduleSkipInput(value: unknown) {
  const body = record(value);
  if (Object.keys(body).some((key) => !["matchDate", "reason", "skip"].includes(key))) throw new Error("Unknown skip-date detail.");
  if (typeof body.skip !== "boolean") throw new Error("Choose whether to skip or restore this date.");
  return { matchDate: parseScheduleDate(body.matchDate), reason: text(body.reason, "Reason", 3, 500), skip: body.skip };
}

export function serializeGameSchedule(row: Record<string, unknown>, fieldName: string, occurrences: Record<string, unknown>[] = [], skips: Record<string, unknown>[] = []): AdminGameSchedule {
  return {
    id: String(row.id), name: String(row.name), fieldId: String(row.field_id), fieldName,
    minimumPlayers: Number.isInteger(row.minimum_players) ? Number(row.minimum_players) : 10,
    participationRulesVersion: typeof row.participation_rules_version === "string" ? row.participation_rules_version : "s0-standard-v1",
    weekdays: row.weekdays as number[], kickoffTime: String(row.kickoff_time).slice(0, 5), durationMinutes: Number(row.duration_minutes),
    startsOn: String(row.starts_on), endsOn: row.ends_on ? String(row.ends_on) : null, bookingWindowDays: Number(row.booking_window_days),
    priceUsd: (Number(row.price_fils) / 1000).toFixed(2), ageLabel: String(row.age_label),
    highestDivision: Number(row.highest_division), lowestDivision: Number(row.lowest_division), isActive: row.is_active === true,
    goalkeepersPerSide: Number(row.goalkeepers_per_side), defendersPerSide: Number(row.defenders_per_side), attackersPerSide: Number(row.attackers_per_side),
    timezone: String(row.timezone), createdAt: String(row.created_at), updatedAt: String(row.updated_at),
    occurrences: occurrences.map((item) => ({ matchDate: String(item.match_date), status: item.status as ScheduleOccurrence["status"], gameId: item.game_id ? String(item.game_id) : null, errorMessage: item.error_message ? String(item.error_message) : null })),
    skips: skips.map((item) => ({ matchDate: String(item.match_date), reason: String(item.reason) })),
  };
}

export function scheduleErrorMessage(error: { code?: string; message?: string }): string {
  if (["42P01", "42703", "PGRST202", "PGRST204", "PGRST205"].includes(error.code ?? "")) return "The game-schedules database update is not installed yet. Apply the latest migration to this environment, then reload.";
  if (error.code === "23505" || error.code === "23P01") return "This pitch already has a game at that time. Choose another time or pitch.";
  return error.message ?? "Could not update the schedule.";
}
