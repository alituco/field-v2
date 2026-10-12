export function parseGamePriceUpdate(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid price update.");
  const body = value as Record<string, unknown>;
  if (Object.keys(body).some((key) => !["priceUsd", "expectedPriceFils", "reason"].includes(key))) throw new Error("Only the new game price and reason can be changed here.");
  const raw = typeof body.priceUsd === "string" ? body.priceUsd.trim() : "";
  if (!/^\d{1,3}(?:\.\d{1,2})?$/.test(raw)) throw new Error("Enter a USD price with no more than two decimal places.");
  const priceFils = Math.round(Number(raw) * 1000);
  if (!Number.isSafeInteger(priceFils) || priceFils > 100000 || (priceFils !== 0 && priceFils < 500)) throw new Error("Use $0 for a free game, or a price from $0.50 to $100 USD.");
  if (typeof body.expectedPriceFils !== "number" || !Number.isSafeInteger(body.expectedPriceFils) || body.expectedPriceFils < 0) throw new Error("Refresh the current game price before saving.");
  const reason = typeof body.reason === "string" ? body.reason.trim() : "";
  if (reason.length < 8 || reason.length > 1000) throw new Error("Explain this price change in 8 to 1000 characters.");
  return { priceFils, expectedPriceFils: body.expectedPriceFils, reason };
}
