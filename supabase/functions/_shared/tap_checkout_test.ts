import {
  formatTapCheckoutAmount,
  tapChargeAmountMatches,
  tapCheckoutHashInput,
  tapCustomerPhone,
  tapPaymentCurrency,
  tapSupportedPaymentMethods,
} from "./tap_checkout.ts";

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

Deno.test("USD quotes retain thousandths internally but render dollars and cents", () => {
  equal(formatTapCheckoutAmount(13000, "USD"), "13.00");
  equal(formatTapCheckoutAmount(13520, "USD"), "13.52");
  equal(formatTapCheckoutAmount(13001, "BHD"), "13.001");
});

Deno.test("checkout rejects sub-cent USD instead of silently changing the charge", () => {
  for (const amount of [13001, 13005, 0, -13000, NaN, Infinity, 13.5, 1e20]) {
    let rejected = false;
    try {
      formatTapCheckoutAmount(amount, "USD");
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error(`Accepted invalid amount ${amount}`);
  }
});

Deno.test("only explicitly supported currencies are accepted", () => {
  equal(tapPaymentCurrency(" usd "), "USD");
  equal(tapPaymentCurrency("BHD"), "BHD");
  for (const value of ["EUR", "", "US", 1, null, undefined]) {
    equal(tapPaymentCurrency(value), null);
  }
});

Deno.test("capture validation rejects amount or precision mismatches", () => {
  equal(tapChargeAmountMatches(13, 13000, "USD"), true);
  equal(tapChargeAmountMatches("13.52", 13520, "USD"), true);
  equal(tapChargeAmountMatches(13.001, 13001, "BHD"), true);
  equal(tapChargeAmountMatches(13.001, 13001, "USD"), false);
  equal(tapChargeAmountMatches(13.0001, 13000, "USD"), false);
  equal(tapChargeAmountMatches(13.0001, 13000, "BHD"), false);
  equal(tapChargeAmountMatches(12.99, 13000, "USD"), false);
  equal(tapChargeAmountMatches("", 13000, "USD"), false);
  equal(tapChargeAmountMatches(null, 13000, "USD"), false);
  equal(tapChargeAmountMatches(NaN, 13000, "USD"), false);
  equal(tapChargeAmountMatches(13, 13000, "EUR"), false);
});

Deno.test("checkout signature binds the actual currency and its precision", () => {
  equal(
    tapCheckoutHashInput(
      "pk_test",
      "13.00",
      "USD",
      "field_123",
      "https://example.com/hook",
    ),
    "x_publickeypk_testx_amount13.00x_currencyUSDx_transactionfield_123x_posthttps://example.com/hook",
  );
  equal(
    tapCheckoutHashInput(
      "pk_test",
      "13.000",
      "BHD",
      "field_123",
      "https://example.com/hook",
    ),
    "x_publickeypk_testx_amount13.000x_currencyBHDx_transactionfield_123x_posthttps://example.com/hook",
  );
});

Deno.test("USD checkout does not advertise the Bahrain-only BenefitPay method", () => {
  equal(tapSupportedPaymentMethods("USD", true), [
    "APPLE_PAY",
    "VISA",
    "MASTERCARD",
  ]);
  equal(tapSupportedPaymentMethods("USD", false), ["VISA", "MASTERCARD"]);
  equal(tapSupportedPaymentMethods("BHD", false), [
    "BENEFIT_PAY",
    "VISA",
    "MASTERCARD",
  ]);
});

Deno.test("Tap customer phone respects international calling codes", () => {
  equal(tapCustomerPhone("+16025550101"), {
    countryCode: "1",
    number: "6025550101",
  });
  equal(tapCustomerPhone("16025550101"), {
    countryCode: "1",
    number: "6025550101",
  });
  equal(tapCustomerPhone("+97336000001"), {
    countryCode: "973",
    number: "36000001",
  });
  equal(tapCustomerPhone("+447911123456"), {
    countryCode: "44",
    number: "7911123456",
  });
  equal(tapCustomerPhone("+919876543210"), {
    countryCode: "91",
    number: "9876543210",
  });
  equal(tapCustomerPhone(""), null);
  equal(tapCustomerPhone("not a number"), null);
  equal(tapCustomerPhone("+1602"), null);
});
