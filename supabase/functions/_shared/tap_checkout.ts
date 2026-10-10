import { parsePhoneNumberFromString } from "npm:libphonenumber-js@1.13.15/min";

export type TapPaymentCurrency = "BHD" | "USD";

export function tapPaymentCurrency(value: unknown): TapPaymentCurrency | null {
  const normalized = typeof value === "string"
    ? value.trim().toUpperCase()
    : "";
  return normalized === "BHD" || normalized === "USD" ? normalized : null;
}

// Existing *_fils columns store thousandths for both currencies. USD checkout
// must already be rounded by the authoritative quote to whole cents; do not
// silently round a different amount while signing or submitting the payment.
export function formatTapCheckoutAmount(
  amountMills: number,
  currency: TapPaymentCurrency,
): string {
  if (
    !Number.isSafeInteger(amountMills) || amountMills <= 0 ||
    (currency === "USD" && amountMills % 10 !== 0)
  ) {
    throw new RangeError("The checkout amount has invalid currency precision.");
  }
  return (amountMills / 1000).toFixed(currency === "USD" ? 2 : 3);
}

export function tapChargeAmountMatches(
  amount: unknown,
  expectedMills: number,
  currencyValue: unknown,
): boolean {
  const currency = tapPaymentCurrency(currencyValue);
  if (!currency || (typeof amount !== "number" && typeof amount !== "string")) {
    return false;
  }
  if (typeof amount === "string" && !/^\d+(?:\.\d+)?$/.test(amount.trim())) {
    return false;
  }
  const numeric = Number(amount);
  if (!Number.isFinite(numeric) || numeric <= 0) return false;
  try {
    formatTapCheckoutAmount(expectedMills, currency);
  } catch {
    return false;
  }
  const minorUnits = numeric * (currency === "USD" ? 100 : 1000);
  if (Math.abs(minorUnits - Math.round(minorUnits)) > 0.000001) return false;
  return Math.abs(numeric * 1000 - expectedMills) < 0.000001;
}

export function tapSupportedPaymentMethods(
  currency: TapPaymentCurrency,
  applePayEnabled: boolean,
): string[] {
  return [
    ...(applePayEnabled ? ["APPLE_PAY"] : []),
    ...(currency === "BHD" ? ["BENEFIT_PAY"] : []),
    "VISA",
    "MASTERCARD",
  ];
}

export function tapCheckoutHashInput(
  publicKey: string,
  amount: string,
  currency: TapPaymentCurrency,
  transactionReference: string,
  postUrl: string,
): string {
  return `x_publickey${publicKey}` +
    `x_amount${amount}` +
    `x_currency${currency}` +
    `x_transaction${transactionReference}` +
    `x_post${postUrl}`;
}

export function tapCustomerPhone(raw: string): {
  countryCode: string;
  number: string;
} | null {
  const trimmed = raw.trim();
  // Supabase stores verified numbers with or without their leading +.
  const phone = parsePhoneNumberFromString(
    trimmed.startsWith("+") ? trimmed : `+${trimmed}`,
  );
  if (!phone?.isPossible()) return null;
  return {
    countryCode: phone.countryCallingCode,
    number: phone.nationalNumber,
  };
}
