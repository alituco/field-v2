// Production cutover only. Secrets stay in process memory/request bodies.
// --preflight makes provider reads only and must run before deployment mutates
// Supabase; the final configuration repeats those reads before activation.
import { pathToFileURL } from 'node:url';
import { realpathSync } from 'node:fs';

const project = 'zjsjuuhborxrlmdcpvlj';
const stripeApiVersion = '2026-09-30.endive';
const webhookUrl = `https://${project}.supabase.co/functions/v1/stripe-payment-webhook`;
const workerUrl = `https://${project}.supabase.co/functions/v1/stripe-payment-reconcile`;
export const productionStripeEvents = Object.freeze([
  'payment_intent.amount_capturable_updated', 'payment_intent.succeeded',
  'payment_intent.payment_failed', 'payment_intent.processing',
  'payment_intent.canceled', 'refund.created', 'refund.updated', 'refund.failed',
]);

function matchesEntire(pattern, value) {
  // JavaScript's $ may also match before a final newline. Secret-file inputs
  // must occupy exactly one line, so require the match to cover the full value.
  return typeof value === 'string' && pattern.exec(value)?.[0] === value;
}

export function validateConfiguration(env) {
  if (env.SUPABASE_PROJECT_REF !== project ||
      env.PRODUCTION_STRIPE_LIVE_ROLLOUT !== 'LIVE_STRIPE_READY' ||
      !matchesEntire(/^(?:sk|rk)_live_[A-Za-z0-9_]+$/, env.STRIPE_SECRET_KEY) ||
      !matchesEntire(/^pk_live_[A-Za-z0-9_]+$/, env.STRIPE_PUBLISHABLE_KEY) ||
      !matchesEntire(/^whsec_[A-Za-z0-9_]+$/, env.STRIPE_WEBHOOK_SECRET) ||
      !matchesEntire(/^acct_[A-Za-z0-9]+$/, env.STRIPE_ACCOUNT_ID) ||
      !matchesEntire(/^we_[A-Za-z0-9]+$/, env.STRIPE_WEBHOOK_ENDPOINT_ID) ||
      !matchesEntire(/^[A-Za-z0-9_-]{32,512}$/, env.STRIPE_RECONCILE_SECRET) ||
      !env.SUPABASE_ACCESS_TOKEN?.trim()) {
    throw new Error('Production live Stripe configuration or explicit cutover confirmation is incomplete.');
  }
}

function stripeHeaders(env) {
  return { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`, 'Stripe-Version': stripeApiVersion };
}

async function checkedRequest(fetcher, url, options, failure) {
  let response;
  try {
    response = await fetcher(url, { ...options, signal: AbortSignal.timeout(30_000) });
  } catch { throw new Error(failure); }
  if (!response.ok) throw new Error(failure);
  return response;
}

async function checkedJson(response, failure) {
  try {
    const result = await response.json();
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error();
    return result;
  } catch { throw new Error(failure); }
}

export async function preflight(env, fetcher = fetch) {
  validateConfiguration(env);
  const headers = stripeHeaders(env);
  const account = await checkedJson(await checkedRequest(fetcher,
    'https://api.stripe.com/v1/account', { headers },
    'Could not verify the live Stripe account.'), 'Live Stripe account response was invalid.');
  if (account.id !== env.STRIPE_ACCOUNT_ID || account.charges_enabled !== true ||
      account.payouts_enabled !== true || account.details_submitted !== true) {
    throw new Error('The live Stripe account does not match the configured merchant or is not ready for charges and payouts.');
  }
  const endpoint = await checkedJson(await checkedRequest(fetcher,
    `https://api.stripe.com/v1/webhook_endpoints/${env.STRIPE_WEBHOOK_ENDPOINT_ID}`,
    { headers }, 'Could not verify the live Stripe webhook.'), 'Live Stripe webhook response was invalid.');
  if (endpoint.id !== env.STRIPE_WEBHOOK_ENDPOINT_ID || endpoint.livemode !== true ||
      endpoint.url !== webhookUrl || endpoint.api_version !== stripeApiVersion) {
    throw new Error('The live Stripe webhook does not match the production endpoint/API version.');
  }
  return { project, verified: true };
}

export function sqlLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

export async function configure(env, fetcher = fetch) {
  await preflight(env, fetcher);
  await checkedRequest(fetcher, `https://api.supabase.com/v1/projects/${project}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      query: `begin; select set_config('request.jwt.claim.role', 'service_role', true); select public.configure_stripe_reconciliation(${sqlLiteral(workerUrl)}, ${sqlLiteral(env.STRIPE_RECONCILE_SECRET)}); commit;`,
    }),
  }, 'Could not schedule the protected production Stripe recovery worker.');

  const body = new URLSearchParams({ disabled: 'false' });
  for (const event of productionStripeEvents) body.append('enabled_events[]', event);
  const enabled = await checkedJson(await checkedRequest(fetcher,
    `https://api.stripe.com/v1/webhook_endpoints/${env.STRIPE_WEBHOOK_ENDPOINT_ID}`,
    { method: 'POST', headers: stripeHeaders(env), body },
    'Could not enable the live Stripe webhook.'), 'Live Stripe webhook activation response was invalid.');
  if (enabled.id !== env.STRIPE_WEBHOOK_ENDPOINT_ID || enabled.livemode !== true ||
      enabled.url !== webhookUrl || enabled.api_version !== stripeApiVersion || enabled.status !== 'enabled' ||
      !Array.isArray(enabled.enabled_events) ||
      enabled.enabled_events.length !== productionStripeEvents.length ||
      !productionStripeEvents.every(event => enabled.enabled_events.includes(event))) {
    throw new Error('Live Stripe webhook activation was not acknowledged with the required production settings. Inspect the endpoint before retrying.');
  }
  return { project, verified: true };
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2);
    if (args.length > 1 || args.some(arg => arg !== '--preflight')) throw new Error('Only --preflight is supported; omission performs the confirmed production configuration.');
    if (args.includes('--preflight')) {
      await preflight(process.env);
      console.log('Production live Stripe account and webhook preflight verified.');
    } else {
      await configure(process.env);
      console.log('Production live Stripe webhook and five-minute recovery schedule configured.');
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : 'Production Stripe configuration failed.');
    process.exitCode = 1;
  }
}
