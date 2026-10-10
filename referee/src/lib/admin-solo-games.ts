export type AdminSoloGameCreateInput = {
  venue: string;
  matchDate: string;
  startsAt: string;
  priceFils: number;
  ageLabel: string;
};

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

function parsePhoenixMatchDate(value: unknown) {
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

  const weekday = calendarDate.getUTCDay();
  if (weekday !== 2 && weekday !== 5) {
    throw new Error("Solo games can only be created on Tuesday or Friday.");
  }

  const startsAt = new Date(`${value}T20:30:00-07:00`);
  if (Number.isNaN(startsAt.getTime())) throw new Error("Choose a valid match date.");
  if (startsAt.getTime() <= Date.now()) {
    throw new Error("The solo game must be scheduled in the future.");
  }

  return { matchDate: value, startsAt: startsAt.toISOString() };
}

function parsePriceFils(value: unknown) {
  const raw = typeof value === "number" ? String(value) : value;
  if (typeof raw !== "string" || !/^\d{1,3}(?:\.\d{1,2})?$/.test(raw.trim())) {
    throw new Error("Price must be a valid USD amount with up to 2 decimals.");
  }
  const priceFils = Math.round(Number(raw) * 1000);
  if (!Number.isSafeInteger(priceFils) || priceFils < 0 || priceFils > 100_000) {
    throw new Error("Price must be between $0 and $100 USD.");
  }
  return priceFils;
}

export function parseAdminSoloGameCreateInput(
  value: unknown,
): AdminSoloGameCreateInput {
  const body = inputRecord(value);
  if ("priceBhd" in body) {
    throw new Error("This form now creates USD games. Refresh the page and enter a USD price.");
  }
  const schedule = parsePhoenixMatchDate(body.matchDate);
  return {
    venue: cleanText(body.venue, "Venue", 2, 80),
    ...schedule,
    // The ledger retains thousandths internally for legacy BHD compatibility.
    // USD inputs are always whole cents; never reinterpret a BHD request as USD.
    priceFils: parsePriceFils(body.priceUsd ?? "13.00"),
    ageLabel: cleanText(body.ageLabel, "Age label", 2, 40),
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
