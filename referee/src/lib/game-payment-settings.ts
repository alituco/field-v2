export type GamePaymentSettings = {
  clan_enabled: boolean;
  clan_price_fils: number;
  currency: "USD";
  updated_at: string;
};

export function parseGamePaymentSettingsUpdate(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid price update.");
  const body = value as Record<string, unknown>;
  if (Object.keys(body).some((key) => !["clanPriceUsd", "reason", "expectedUpdatedAt"].includes(key))) {
    throw new Error("Only the future USD clan price can be edited here. Clan games remain paused.");
  }
  const raw = typeof body.clanPriceUsd === "string" ? body.clanPriceUsd.trim() : "";
  if (!/^\d{1,4}(?:\.\d{1,2})?$/.test(raw)) throw new Error("Enter a USD price with no more than two decimal places.");
  const price = Math.round(Number(raw) * 1000);
  if (!Number.isSafeInteger(price) || price < 500 || price > 1000000) throw new Error("The future clan price must be between $0.50 and $1,000 USD.");
  const reason = typeof body.reason === "string" ? body.reason.trim() : "";
  if (reason.length < 10 || reason.length > 1000) throw new Error("Explain this price change in 10 to 1000 characters.");
  const revision = typeof body.expectedUpdatedAt === "string" ? body.expectedUpdatedAt : "";
  if (!revision || !Number.isFinite(Date.parse(revision))) throw new Error("Reload the current price before saving.");
  return { priceFils: price, reason, expectedUpdatedAt: revision };
}
