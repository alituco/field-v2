export const fieldStagingProjectRef = "nfdkdhdevpstfspazbfn";
export const fieldStagingSupabaseUrl =
  `https://${fieldStagingProjectRef}.supabase.co`;

export function isExactFieldStagingSupabaseUrl(
  value: string | undefined,
): value is string {
  if (!value) return false;

  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      url.hostname === `${fieldStagingProjectRef}.supabase.co` &&
      url.port === "" &&
      url.username === "" &&
      url.password === "" &&
      url.pathname === "/" &&
      url.search === "" &&
      url.hash === ""
    );
  } catch {
    return false;
  }
}

export function isLocalSupabaseUrl(
  value: string | undefined,
): value is string {
  if (!value) return false;

  try {
    const url = new URL(value);
    const isPublicLoopback =
      ["127.0.0.1", "localhost", "host.docker.internal"].includes(
        url.hostname,
      ) && url.port === "54321";
    const isLocalContainer =
      (url.hostname === "kong" || url.hostname.startsWith("supabase_kong_")) &&
      url.port === "8000";
    return (
      url.protocol === "http:" &&
      (isPublicLoopback || isLocalContainer) &&
      url.username === "" &&
      url.password === "" &&
      url.pathname === "/" &&
      url.search === "" &&
      url.hash === ""
    );
  } catch {
    return false;
  }
}
