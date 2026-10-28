export type SoloFormation = {
  goalkeepersPerSide: number;
  defendersPerSide: number;
  attackersPerSide: number;
};

export const DEFAULT_SOLO_FORMATION: SoloFormation = {
  goalkeepersPerSide: 1, defendersPerSide: 2, attackersPerSide: 4,
};

/** Seven-a-side always reserves one keeper; the six outfield spots are configurable. */
export function parseSoloFormation(body: Record<string, unknown>, useDefaults = false): SoloFormation {
  const read = (key: keyof SoloFormation, label: string) => {
    const value = body[key] === undefined && useDefaults ? DEFAULT_SOLO_FORMATION[key] : body[key];
    if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 6) {
      throw new Error(`${label} per team must be a whole number from 0 to 6.`);
    }
    return value;
  };
  const goalkeepersPerSide = read("goalkeepersPerSide", "Goalkeepers");
  const defendersPerSide = read("defendersPerSide", "Defenders");
  const attackersPerSide = read("attackersPerSide", "Attackers");
  if (goalkeepersPerSide !== 1) throw new Error("Seven-a-side games require exactly one goalkeeper per team.");
  if (defendersPerSide + attackersPerSide !== 6) throw new Error("Defenders and attackers must add up to six players per team.");
  return { goalkeepersPerSide, defendersPerSide, attackersPerSide };
}

export type AdminSoloGameCreateInput = SoloFormation & {
  minimumPlayers: number;
  fieldId: string;
  matchDate: string;
  startsAt: string;
  durationMinutes: number;
  priceFils: number;
  ageLabel: string;
  highestDivision: number;
  lowestDivision: number;
};

export const DEFAULT_SOLO_MINIMUM_PLAYERS = 10;

export function parseSoloMinimumPlayers(value: unknown = DEFAULT_SOLO_MINIMUM_PLAYERS): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 2 || value > 14) {
    throw new Error("Minimum players must be a whole number from 2 to 14, counting both teams together.");
  }
  return value;
}

export type AdminSoloGameRemoveInput = {
  reason: string;
};

function inputRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid request.");
  }
  return value as Record<string, unknown>;
}

function cleanText(value: unknown, label: string, min: number, max: number) {
  if (typeof value !== "string") throw new Error(`${label} is required.`);
  const cleaned = value.trim();
  if (cleaned.length < min || cleaned.length > max) {
    throw new Error(`${label} must be between ${min} and ${max} characters.`);
  }
  return cleaned;
}

/** Interpret a wall-clock kickoff using the saved field's trusted IANA timezone. */
export function cityKickoffToUtc(value: unknown, kickoffTime: unknown, timezone: string): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new Error("Choose a valid match date.");
  }

  const [year, month, day] = value.split("-").map(Number);
  const calendarDate = new Date(Date.UTC(year, month - 1, day));
  if (
    calendarDate.getUTCFullYear() !== year ||
    calendarDate.getUTCMonth() !== month - 1 ||
    calendarDate.getUTCDate() !== day
  ) {
    throw new Error("Choose a valid match date.");
  }

  if (typeof kickoffTime !== "string" || !/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(kickoffTime)) {
    throw new Error("Choose a valid kickoff time (HH:MM).");
  }
  let formatter: Intl.DateTimeFormat;
  try {
    formatter = new Intl.DateTimeFormat("en-US", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" });
  } catch { throw new Error("The field’s competition city has an invalid timezone. Update it in Cities."); }
  const [hour, minute] = kickoffTime.split(":").map(Number);
  const wall = Date.UTC(year, month - 1, day, hour, minute);
  const localTimestamp = (instant: number) => {
    const parts = formatter.formatToParts(instant);
    const part = (type: string) => Number(parts.find((item) => item.type === type)?.value);
    return Date.UTC(part("year"), part("month") - 1, part("day"), part("hour"), part("minute"), part("second"));
  };
  // Sample either side of possible daylight-saving changes, then round-trip candidates.
  const offsets = new Set([-36, -12, 0, 12, 36].map((hours) => {
    const instant = wall + hours * 3_600_000;
    return localTimestamp(instant) - instant;
  }));
  const candidates = [...offsets].map((offset) => wall - offset).filter((instant) => localTimestamp(instant) === wall);
  if (candidates.length === 0) throw new Error("That local kickoff time does not exist because the clocks change. Choose another time.");
  if (candidates.length > 1) throw new Error("That local kickoff time happens twice because the clocks change. Choose an unambiguous time.");
  return new Date(candidates[0]).toISOString();
}

export function cityToday(timezone: string, now = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(now);
  return ["year", "month", "day"].map((type) => parts.find((part) => part.type === type)?.value).join("-");
}

function parseMatchDate(value: unknown, kickoffTime: unknown, timezone: string) {
  const startsAt = cityKickoffToUtc(value, kickoffTime, timezone);
  if (new Date(startsAt).getTime() <= Date.now()) {
    throw new Error("The solo game must be scheduled in the future.");
  }
  return { matchDate: value as string, startsAt };
}

function parsePriceFils(value: unknown) {
  const raw = typeof value === "number" ? String(value) : value;
  if (typeof raw !== "string" || !/^\d{1,3}(?:\.\d{1,2})?$/.test(raw.trim())) {
    throw new Error("Price must be a valid USD amount with up to 2 decimals.");
  }
  const priceFils = Math.round(Number(raw) * 1000);
  if (!Number.isSafeInteger(priceFils) || priceFils > 100_000 || (priceFils !== 0 && priceFils < 500)) {
    throw new Error("Price must be $0 for a free game, or between $0.50 and $100 USD.");
  }
  return priceFils;
}

function parseSavedFieldId(value: unknown) {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
    throw new Error("Choose a saved field before creating the game.");
  }
  return value;
}

function parseDivision(value: unknown, fallback: number, label: string) {
  const division = value === undefined ? fallback : value;
  if (typeof division !== "number" || !Number.isInteger(division) || division < 1 || division > 5) {
    throw new Error(`${label} must be a whole-number division from 1 to 5.`);
  }
  return division;
}

export function parseAdminSoloGameCreateInput(
  value: unknown,
  timezone = "America/Phoenix",
): AdminSoloGameCreateInput {
  const body = inputRecord(value);
  if ("priceBhd" in body) {
    throw new Error("This form now creates USD games. Refresh the page and enter a USD price.");
  }
  const schedule = parseMatchDate(body.matchDate, body.kickoffTime ?? "20:30", timezone);
  const durationMinutes = body.durationMinutes ?? 60;
  if (typeof durationMinutes !== "number" || !Number.isInteger(durationMinutes) || durationMinutes < 30 || durationMinutes > 180) {
    throw new Error("Duration must be a whole number from 30 to 180 minutes.");
  }
  const highestDivision = parseDivision(body.highestDivision, 1, "Highest division");
  const lowestDivision = parseDivision(body.lowestDivision, 5, "Lowest division");
  if (highestDivision > lowestDivision) {
    throw new Error("Highest division must be less than or equal to lowest division.");
  }
  return {
    fieldId: parseSavedFieldId(body.fieldId),
    minimumPlayers: parseSoloMinimumPlayers(body.minimumPlayers),
    ...schedule,
    durationMinutes,
    // The ledger retains thousandths internally for legacy BHD compatibility.
    // USD inputs are always whole cents; never reinterpret a BHD request as USD.
    priceFils: parsePriceFils(body.priceUsd ?? "13.00"),
    ageLabel: cleanText(body.ageLabel, "Age label", 2, 40),
    highestDivision,
    lowestDivision,
    ...parseSoloFormation(body, true),
  };
}

export function parseAdminSoloGameRemoveInput(
  value: unknown,
): AdminSoloGameRemoveInput {
  const body = inputRecord(value);
  return {
    reason: cleanText(body.reason, "Removal reason", 8, 1000),
  };
}
