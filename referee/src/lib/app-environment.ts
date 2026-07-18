export type FieldEnvironment =
  | "local"
  | "staging"
  | "production"
  | "unknown";

export type FieldEnvironmentConfig = {
  environment: FieldEnvironment;
  label: string | null;
  error: string | null;
};

export const stagingProjectRef = "nfdkdhdevpstfspazbfn";
export const productionProjectRef = "zjsjuuhborxrlmdcpvlj";

function isHostedProject(url: string | undefined, ref: string) {
  if (!url) return null;
  try {
    const parsed = new URL(url);
    return (
      parsed.protocol === "https:" &&
      parsed.hostname === `${ref}.supabase.co` &&
      parsed.port === "" &&
      parsed.username === "" &&
      parsed.password === "" &&
      parsed.pathname === "/" &&
      parsed.search === "" &&
      parsed.hash === ""
    );
  } catch {
    return false;
  }
}

function isLoopback(url: string | undefined) {
  if (!url) return false;
  try {
    const parsed = new URL(url);
    return (
      parsed.protocol === "http:" &&
      ["127.0.0.1", "localhost", "10.0.2.2"].includes(parsed.hostname) &&
      parsed.username === "" &&
      parsed.password === "" &&
      parsed.pathname === "/" &&
      parsed.search === "" &&
      parsed.hash === ""
    );
  } catch {
    return false;
  }
}

export function resolveFieldEnvironment(
  appEnvironment = process.env.NEXT_PUBLIC_APP_ENV,
  supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL,
): FieldEnvironmentConfig {
  const requested = appEnvironment?.trim().toLowerCase();
  const isStagingProject = isHostedProject(supabaseUrl, stagingProjectRef);
  const isProductionProject = isHostedProject(
    supabaseUrl,
    productionProjectRef,
  );

  const environment: FieldEnvironment = requested === "local" ||
      requested === "staging" ||
      requested === "production"
    ? requested
    : isLoopback(supabaseUrl)
    ? "local"
    : isStagingProject
    ? "staging"
    : isProductionProject
    ? "production"
    : "unknown";

  if (environment === "unknown") {
    return {
      environment,
      label: null,
      error: requested
        ? "NEXT_PUBLIC_APP_ENV must be local, staging, or production."
        : "Set NEXT_PUBLIC_APP_ENV and a matching Supabase URL.",
    };
  }
  if (environment === "local" && !isLoopback(supabaseUrl)) {
    return {
      environment,
      label: "LOCAL",
      error: "The local referee app must use local Supabase.",
    };
  }
  if (environment === "staging" && !isStagingProject) {
    return {
      environment,
      label: "STAGING",
      error: "The staging referee app is not pointing at Field Staging.",
    };
  }
  if (environment === "production" && !isProductionProject) {
    return {
      environment,
      label: null,
      error: "The production referee app is not pointing at Field Production.",
    };
  }

  return {
    environment,
    label: environment === "local"
      ? "LOCAL"
      : environment === "staging"
      ? "STAGING"
      : null,
    error: null,
  };
}

export function assertSupabaseAdminEnvironment(
  supabaseUrl: string,
  appEnvironment = process.env.NEXT_PUBLIC_APP_ENV,
) {
  const environment = resolveFieldEnvironment(appEnvironment, supabaseUrl);
  if (environment.error) {
    throw new Error(
      `Refusing Supabase service-role initialization: ${environment.error}`,
    );
  }
  return environment;
}
