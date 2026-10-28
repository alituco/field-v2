import {
  isExactFieldStagingSupabaseUrl,
  isLocalSupabaseUrl,
} from "../_shared/staging_guard.ts";

type EnvironmentReader = (name: string) => string | undefined;

function isExactProductionSupabaseUrl(value: string | undefined): boolean {
  if (!value) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" &&
      url.hostname === "zjsjuuhborxrlmdcpvlj.supabase.co" &&
      url.port === "" && url.username === "" && url.password === "" &&
      url.pathname === "/" && url.search === "" && url.hash === "";
  } catch {
    return false;
  }
}

/** Deployment is inert until the server-only enable flag is explicitly set. */
export function isAccountDeletionEnabled(env: EnvironmentReader): boolean {
  if (env("FIELDRUSH_ACCOUNT_DELETION_ENABLED") !== "true") return false;
  const url = env("SUPABASE_URL");
  switch (env("FIELD_ENVIRONMENT")) {
    case "production":
      return isExactProductionSupabaseUrl(url);
    case "staging":
      return isExactFieldStagingSupabaseUrl(url);
    case "local":
      return isLocalSupabaseUrl(url);
    case undefined:
    case "":
      // Preserve existing staging/local deployments. Production additionally
      // requires its explicit environment label and cannot fall through here.
      return isExactFieldStagingSupabaseUrl(url) || isLocalSupabaseUrl(url);
    default:
      return false;
  }
}
