import { createClient } from "npm:@supabase/supabase-js@2.86.0";
import { createPushDispatchHandler } from "./handler.ts";

Deno.serve(createPushDispatchHandler({
  env: (name) => Deno.env.get(name),
  createDb: (url, key) =>
    createClient(url, key, {
      auth: { autoRefreshToken: false, persistSession: false },
    }),
}));
