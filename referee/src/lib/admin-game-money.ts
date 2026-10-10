export type AdminGameCurrency = "BHD" | "USD";

/** Legacy clan payments are BHD; solo payments use the persisted game currency. */
export function adminGameCurrency(
  matchKind: "CLAN" | "SOLO",
  persistedCurrency?: unknown,
): AdminGameCurrency {
  if (matchKind === "CLAN") return "BHD";
  if (persistedCurrency === "BHD" || persistedCurrency === "USD") {
    return persistedCurrency;
  }
  throw new Error("The solo game's payment currency is missing or unsupported.");
}

/** The legacy *_fils ledger names denote thousandths in either currency. */
export function formatGameMoney(
  thousandths: number,
  currency: AdminGameCurrency,
) {
  if (!Number.isSafeInteger(thousandths)) {
    throw new Error("Invalid game payment amount.");
  }
  if (currency !== "USD" && currency !== "BHD") {
    throw new Error("Unsupported game payment currency.");
  }
  // Policy refunds may contain fractional USD cents. Never round money away.
  const decimals = currency === "USD" && thousandths % 10 === 0 ? 2 : 3;
  const value = (thousandths / 1000).toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
  return currency === "USD" ? `$${value} USD` : `${value} BHD`;
}
