"use client";

import { createClient } from "@supabase/supabase-js";
import { staffStorageKey } from "./staff-browser-session";

export function createSupabaseBrowserClient() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  if (!supabaseUrl || !publishableKey) {
    throw new Error("Supabase browser config is missing.");
  }

  return createClient(supabaseUrl, publishableKey, {
    auth: { storageKey: staffStorageKey(supabaseUrl), detectSessionInUrl: false },
  });
}
