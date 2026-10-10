import { handleWebhook } from "../_shared/stripe_payment_handler.ts";
Deno.serve(handleWebhook);
