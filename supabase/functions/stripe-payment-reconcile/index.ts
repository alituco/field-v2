import { handleReconcile } from "../_shared/stripe_payment_handler.ts";
Deno.serve(handleReconcile);
