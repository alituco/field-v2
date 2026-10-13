export type AdminField = {
  id: string;
  name: string;
  address: string;
  city: string;
  state: string;
  countryCode: string;
  marketCityId: string;
  marketCityName: string;
  marketTimezone: string;
  marketActive: boolean;
  latitude: number;
  longitude: number;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
};

export const FIELD_SELECT = "id,name,address,city,state,country_code,market_city_id,market:fieldrush_cities!market_city_id(id,display_name,timezone,active),latitude,longitude,is_active,created_at,updated_at";

const FIELD_KEYS = ["name", "address", "city", "state", "countryCode", "marketCityId", "latitude", "longitude", "isActive"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function parseFieldId(value: unknown): string {
  if (typeof value !== "string" || !UUID.test(value)) {
    throw new Error("Choose a saved field before creating the game.");
  }
  return value;
}

function text(value: unknown, label: string, min: number, max: number): string {
  if (typeof value !== "string") throw new Error(`${label} is required.`);
  const result = value.trim();
  if (result.length < min || result.length > max) {
    throw new Error(`${label} must be between ${min} and ${max} characters.`);
  }
  return result;
}

function coordinate(value: unknown, label: string, limit: number): number {
  if ((typeof value !== "number" && typeof value !== "string") ||
      (typeof value === "string" && !/^-?\d+(?:\.\d+)?$/.test(value.trim()))) {
    throw new Error(`${label} is required. Enter a valid map coordinate.`);
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < -limit || parsed > limit) {
    throw new Error(`${label} must be between -${limit} and ${limit}.`);
  }
  return parsed;
}

/** Produces only allowed database keys; partial updates never clear omitted values. */
export function parseAdminFieldInput(value: unknown, partial = false): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid field details.");
  const body = value as Record<string, unknown>;
  if (Object.keys(body).some((key) => !FIELD_KEYS.includes(key))) throw new Error("Unknown field detail. Refresh the page and try again.");
  if (partial && Object.keys(body).length === 0) throw new Error("Choose a field detail to update.");
  const result: Record<string, unknown> = {};
  if (!partial || "marketCityId" in body) {
    if (typeof body.marketCityId !== "string" || !/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(body.marketCityId) || body.marketCityId.length > 60) {
      throw new Error("Competition city is required. Choose an available city.");
    }
    result.market_city_id = body.marketCityId;
  }
  if (!partial || "name" in body) result.name = text(body.name, "Field name", 2, 80);
  if (!partial || "address" in body) result.address = text(body.address, "Street address", 5, 240);
  if (!partial || "city" in body) result.city = text(body.city ?? (!partial ? "Phoenix" : null), "City", 2, 80);
  if (!partial || "state" in body) result.state = text(body.state ?? (!partial ? "AZ" : null), "State / region", 1, 80);
  if (!partial || "countryCode" in body) {
    const country = text(body.countryCode ?? (!partial ? "US" : null), "Country code", 2, 2).toUpperCase();
    if (!/^[A-Z]{2}$/.test(country)) throw new Error("Use a two-letter country code, such as US.");
    result.country_code = country;
  }
  if (!partial || "latitude" in body) result.latitude = coordinate(body.latitude, "Latitude", 90);
  if (!partial || "longitude" in body) result.longitude = coordinate(body.longitude, "Longitude", 180);
  if ("isActive" in body) {
    if (typeof body.isActive !== "boolean") throw new Error("Active status must be true or false.");
    result.is_active = body.isActive;
  }
  return result;
}

export function serializeAdminField(row: Record<string, unknown>): AdminField {
  const market = row.market && typeof row.market === "object" && !Array.isArray(row.market) ? row.market as Record<string, unknown> : {};
  return {
    id: String(row.id), name: String(row.name), address: String(row.address), city: String(row.city),
    state: String(row.state), countryCode: String(row.country_code), latitude: Number(row.latitude),
    longitude: Number(row.longitude), isActive: row.is_active === true,
    marketCityId: String(row.market_city_id ?? ""), marketCityName: String(market.display_name ?? ""),
    marketTimezone: String(market.timezone ?? ""), marketActive: market.active === true,
    createdAt: String(row.created_at), updatedAt: String(row.updated_at),
  };
}

export function adminFieldsErrorMessage(error: { code?: string; message?: string }): string {
  if (["42P01", "42703", "PGRST202", "PGRST204", "PGRST205"].includes(error.code ?? "")) {
    return "The saved-fields database update is not installed yet. Apply the latest migration to this environment, then reload.";
  }
  if (error.code === "23505") return "This field already exists. Choose it from the saved fields instead.";
  return error.message ?? "Could not save the field.";
}
