import { handleStagingAdminSession } from "../_shared/staging_admin_session.ts";

Deno.serve((request) =>
  handleStagingAdminSession(request, { env: (name) => Deno.env.get(name) })
);
