/** Parse map coordinates without relying on a browser's locale-specific number widget. */
export function parseFieldCoordinateInput(
  input: string,
  axis: "latitude" | "longitude",
): number | null {
  const normalized = input.trim().normalize("NFKC").replace(/\u2212/g, "-");
  // One decimal value only: never accept a coordinate pair, grouping, exponent,
  // hexadecimal literal, or a partial numeric prefix followed by other text.
  if (!/^[+-]?(?:\d+(?:[.,]\d+)?|[.,]\d+)$/.test(normalized)) return null;
  const value = Number(normalized.replace(",", "."));
  const limit = axis === "latitude" ? 90 : 180;
  return Number.isFinite(value) && Math.abs(value) <= limit ? value : null;
}
