import {
  isAuthOnlyOnboardingFixture,
  isProtectedBootstrapFixture,
} from "./fixture.ts";

Deno.test("auth-only onboarding exception requires protected marker and reserved phone", () => {
  const valid = {
    phone: "+97339009100",
    app_metadata: { fieldrush_e2e: true, fieldrush_e2e_role: "onboarding" },
  };
  const cases: [Parameters<typeof isAuthOnlyOnboardingFixture>[0], boolean][] =
    [
      [valid, true],
      [{ phone: valid.phone }, false],
      [{ ...valid, phone: "+16025550123" }, false],
      [{ ...valid, app_metadata: { fieldrush_e2e: true } }, false],
      [{
        ...valid,
        app_metadata: { fieldrush_e2e: true, fieldrush_e2e_role: "player" },
      }, false],
      [{
        ...valid,
        app_metadata: {
          fieldrush_e2e: "true",
          fieldrush_e2e_role: "onboarding",
        },
      }, false],
    ];
  for (const [target, expected] of cases) {
    if (isAuthOnlyOnboardingFixture(target) !== expected) {
      throw new Error("Auth-only fixture guard failed");
    }
  }
});

Deno.test("bootstrap refresh refuses unmarked or different accounts", () => {
  const valid = {
    phone: "+97339009099",
    app_metadata: { fieldrush_e2e: true, fieldrush_e2e_role: "bootstrap" },
  };
  if (
    !isProtectedBootstrapFixture(valid) ||
    isProtectedBootstrapFixture({ phone: valid.phone }) ||
    isProtectedBootstrapFixture({ ...valid, phone: "+97338883672" }) ||
    isProtectedBootstrapFixture({
      ...valid,
      app_metadata: { fieldrush_e2e: true, fieldrush_e2e_role: "player" },
    })
  ) {
    throw new Error("Bootstrap ownership guard failed");
  }
});
