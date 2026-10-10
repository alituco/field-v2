export const FIELD_STAGING_PROJECT_REF = "nfdkdhdevpstfspazbfn";
export const FIELD_PRODUCTION_PROJECT_REF = "zjsjuuhborxrlmdcpvlj";

const SUPABASE_HOST_SUFFIX = ".supabase.co";
const LOOPBACK_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]"]);

export type SafeDevDataTarget =
  | { environment: "local"; hostname: string }
  | {
    environment: "staging";
    hostname: string;
    projectRef: typeof FIELD_STAGING_PROJECT_REF;
  };

/**
 * Allows destructive development-data operations only against Field Staging
 * or a loopback Supabase instance.
 *
 * This is intentionally an allow-list, not an overridable production check:
 * a typo, a new hosted project, or a custom production hostname must fail
 * closed until this source-controlled policy is deliberately updated.
 */
export function assertSafeDevDataTarget(
  rawSupabaseUrl: string,
  operation: string,
): SafeDevDataTarget {
  let target: URL;
  try {
    target = new URL(rawSupabaseUrl);
  } catch {
    throw new Error(
      `Refusing ${operation}: SUPABASE_URL is not a valid absolute URL.`,
    );
  }

  if (target.protocol !== "http:" && target.protocol !== "https:") {
    throw new Error(
      `Refusing ${operation}: SUPABASE_URL must use HTTP or HTTPS.`,
    );
  }

  const hostname = target.hostname.toLowerCase();
  const projectRef = projectRefFromHostname(hostname);
  if (projectRef === FIELD_PRODUCTION_PROJECT_REF) {
    throw new Error(
      `Refusing ${operation}: Field Production ` +
        `(${FIELD_PRODUCTION_PROJECT_REF}) is protected. This guard cannot ` +
        "be overridden.",
    );
  }

  if (
    target.username !== "" ||
    target.password !== "" ||
    target.pathname !== "/" ||
    target.search !== "" ||
    target.hash !== ""
  ) {
    throw new Error(
      `Refusing ${operation}: SUPABASE_URL must be a bare origin without ` +
        "credentials, a path, query, or fragment.",
    );
  }

  if (LOOPBACK_HOSTNAMES.has(hostname)) {
    return { environment: "local", hostname };
  }

  if (
    target.protocol === "https:" &&
    target.port === "" &&
    projectRef === FIELD_STAGING_PROJECT_REF
  ) {
    return {
      environment: "staging",
      hostname,
      projectRef: FIELD_STAGING_PROJECT_REF,
    };
  }

  throw new Error(
    `Refusing ${operation}: ${hostname || "the configured target"} is not ` +
      `Field Staging (${FIELD_STAGING_PROJECT_REF}) or a loopback local ` +
      "Supabase URL.",
  );
}

function projectRefFromHostname(hostname: string): string | null {
  if (!hostname.endsWith(SUPABASE_HOST_SUFFIX)) return null;

  const projectRef = hostname.slice(0, -SUPABASE_HOST_SUFFIX.length);
  return projectRef.length > 0 && !projectRef.includes(".") ? projectRef : null;
}
