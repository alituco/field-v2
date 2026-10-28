import { isAccountDeletionEnabled } from "./environment.ts";

const staging = "https://nfdkdhdevpstfspazbfn.supabase.co";
const production = "https://zjsjuuhborxrlmdcpvlj.supabase.co";

function enabled(values: Record<string, string | undefined>) {
  return isAccountDeletionEnabled((name) => values[name]);
}

Deno.test("production deletion requires both the exact origin and explicit server activation", () => {
  const ready = {
    SUPABASE_URL: production,
    FIELD_ENVIRONMENT: "production",
    FIELDRUSH_ACCOUNT_DELETION_ENABLED: "true",
  };
  if (!enabled(ready)) {
    throw new Error("Explicit production activation refused.");
  }
  for (
    const changes of [
      { FIELDRUSH_ACCOUNT_DELETION_ENABLED: undefined },
      { FIELDRUSH_ACCOUNT_DELETION_ENABLED: "false" },
      { FIELDRUSH_ACCOUNT_DELETION_ENABLED: "TRUE" },
      { FIELD_ENVIRONMENT: undefined },
      { FIELD_ENVIRONMENT: "" },
      { FIELD_ENVIRONMENT: "staging" },
      { FIELD_ENVIRONMENT: "local" },
      { FIELD_ENVIRONMENT: "unknown" },
      { SUPABASE_URL: staging },
      { SUPABASE_URL: "http://127.0.0.1:54321" },
      { SUPABASE_URL: `${production}.evil.example` },
      { SUPABASE_URL: `${production}/path` },
      { SUPABASE_URL: `${production}?other=1` },
      { SUPABASE_URL: `${production}#other` },
      { SUPABASE_URL: `${production}:444` },
      { SUPABASE_URL: production.replace("https://", "http://") },
      {
        SUPABASE_URL: production.replace("https://", "https://user:password@"),
      },
    ]
  ) {
    if (enabled({ ...ready, ...changes })) {
      throw new Error(
        "Deletion accepted a disabled or mismatched environment.",
      );
    }
  }
});

Deno.test("existing staging/local activation stays available without permitting environment mismatches", () => {
  for (
    const [url, label] of [
      [staging, "staging"],
      ["http://127.0.0.1:54321", "local"],
      ["http://kong:8000", "local"],
    ]
  ) {
    for (const environment of [label, undefined]) {
      if (
        !enabled({
          SUPABASE_URL: url,
          FIELD_ENVIRONMENT: environment,
          FIELDRUSH_ACCOUNT_DELETION_ENABLED: "true",
        })
      ) throw new Error("Existing staging/local activation refused.");
    }
    if (
      enabled({
        SUPABASE_URL: url,
        FIELD_ENVIRONMENT: "production",
        FIELDRUSH_ACCOUNT_DELETION_ENABLED: "true",
      })
    ) throw new Error("Production accepted another environment's URL.");
    if (
      enabled({ SUPABASE_URL: url, FIELD_ENVIRONMENT: label })
    ) throw new Error("Missing server enable flag accepted.");
  }
});
