/** An Auth-only fixture must be explicitly tagged by a service-role creator. */
export function isAuthOnlyOnboardingFixture(target: {
  phone?: string;
  app_metadata?: Record<string, unknown>;
}): boolean {
  return target.phone?.replace(/\D/g, "") === "97339009100" &&
    target.app_metadata?.fieldrush_e2e === true &&
    target.app_metadata?.fieldrush_e2e_role === "onboarding";
}

export function isProtectedBootstrapFixture(target: {
  phone?: string;
  app_metadata?: Record<string, unknown>;
}): boolean {
  return target.phone?.replace(/\D/g, "") === "97339009098" &&
    target.app_metadata?.fieldrush_e2e === true &&
    target.app_metadata?.fieldrush_e2e_role === "bootstrap";
}
