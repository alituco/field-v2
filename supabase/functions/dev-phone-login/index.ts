import { handleDevAuth } from "../_shared/dev_auth_handler.ts";

Deno.serve((request) =>
  handleDevAuth(request, "phone", { env: (name) => Deno.env.get(name) })
);
