export type AdminCity = {
  id: string;
  displayName: string;
  state: string;
  countryCode: string;
  timezone: string;
  active: boolean;
};

export const CITY_SELECT = "id,display_name,state,country_code,timezone,active";
const KEYS = ["displayName", "state", "countryCode", "timezone", "active"];

export function parseCityId(value: unknown): string {
  if (typeof value !== "string" || !/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(value) || value.length > 60) {
    throw new Error("Choose a city, or use a lowercase city ID such as phoenix or new-york.");
  }
  return value;
}

export function isValidCityTimezone(value: unknown): value is string {
  if (typeof value !== "string" || !value.includes("/") || value.length > 80) return false;
  try { new Intl.DateTimeFormat("en-US", { timeZone: value }).format(); return true; }
  catch { return false; }
}

export function parseAdminCityInput(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid city details.");
  const body = value as Record<string, unknown>;
  if (Object.keys(body).some((key) => !KEYS.includes(key))) throw new Error("Unknown city detail. Refresh and try again.");
  function text(key: string, label: string, min: number, max: number) {
    if (typeof body[key] !== "string") throw new Error(`${label} is required.`);
    const result = (body[key] as string).trim();
    if (result.length < min || result.length > max) throw new Error(`${label} must be between ${min} and ${max} characters.`);
    return result;
  }
  const timezone = text("timezone", "Timezone", 3, 80);
  if (!isValidCityTimezone(timezone)) throw new Error("Use an IANA timezone such as America/Phoenix or America/New_York.");
  const countryCode = text("countryCode", "Country code", 2, 2).toUpperCase();
  if (!/^[A-Z]{2}$/.test(countryCode)) throw new Error("Use a two-letter country code such as US.");
  if (typeof body.active !== "boolean") throw new Error("Choose whether the city is available to players.");
  return { display_name: text("displayName", "City name", 2, 80), state: text("state", "State / region", 1, 80),
    country_code: countryCode, timezone, active: body.active };
}

export function serializeAdminCity(row: Record<string, unknown>): AdminCity {
  return { id: String(row.id), displayName: String(row.display_name), state: String(row.state),
    countryCode: String(row.country_code), timezone: String(row.timezone), active: row.active === true };
}

export function adminCitiesErrorMessage(error: { code?: string; message?: string }): string {
  if (["42P01", "42703", "PGRST202", "PGRST204", "PGRST205"].includes(error.code ?? "")) {
    return "The city and rankings database update is not installed yet. Apply the latest migration, then reload.";
  }
  return error.message ?? "Could not save city details.";
}
