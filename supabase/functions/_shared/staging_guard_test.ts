import {
  fieldStagingSupabaseUrl,
  isExactFieldStagingSupabaseUrl,
} from "./staging_guard.ts";

Deno.test("the exact Field Staging origin is accepted", () => {
  if (!isExactFieldStagingSupabaseUrl(fieldStagingSupabaseUrl)) {
    throw new Error("Field Staging should be accepted.");
  }
});

Deno.test("production and lookalike staging origins are rejected", () => {
  const unsafeUrls = [
    "https://zjsjuuhborxrlmdcpvlj.supabase.co",
    "https://nfdkdhdevpstfspazbfn.supabase.co.evil.example",
    "http://nfdkdhdevpstfspazbfn.supabase.co",
    "https://nfdkdhdevpstfspazbfn.supabase.co/path",
    "https://nfdkdhdevpstfspazbfn.supabase.co?preview=true",
    "not-a-url",
    undefined,
  ];

  for (const value of unsafeUrls) {
    if (isExactFieldStagingSupabaseUrl(value)) {
      throw new Error(`Unsafe Supabase URL was accepted: ${value}`);
    }
  }
});
