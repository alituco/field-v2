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
