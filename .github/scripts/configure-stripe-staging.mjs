// Called only by the staging deployment after migrations and Edge Functions.
// Secret material stays in process memory and request bodies, never CLI arguments.
const project = 'nfdkdhdevpstfspazbfn';
const webhookUrl = `https://${project}.supabase.co/functions/v1/stripe-payment-webhook`;
const workerUrl = `https://${project}.supabase.co/functions/v1/stripe-payment-reconcile`;

export function sqlLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

export function validateConfiguration(env) {
  if (env.SUPABASE_PROJECT_REF !== project ||
      !env.STRIPE_SECRET_KEY?.startsWith('sk_test_') ||
      !env.STRIPE_WEBHOOK_SECRET?.startsWith('whsec_') ||
      (env.STRIPE_RECONCILE_SECRET?.length ?? 0) < 32 ||
      !/^we_[A-Za-z0-9]+$/.test(env.STRIPE_WEBHOOK_ENDPOINT_ID ?? '') ||
      !env.SUPABASE_ACCESS_TOKEN) {
    throw new Error('Staging Stripe configuration is incomplete or targets the wrong project.');
  }
}

export async function configure(env, fetcher = fetch) {
  validateConfiguration(env);
  const stripeHeaders = {
    Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
    'Stripe-Version': '2026-09-30.endive',
  };
  const endpointUrl = `https://api.stripe.com/v1/webhook_endpoints/${env.STRIPE_WEBHOOK_ENDPOINT_ID}`;
  const endpointResponse = await fetcher(endpointUrl, {
    headers: stripeHeaders,
    signal: AbortSignal.timeout(30_000),
  });
  if (!endpointResponse.ok) throw new Error('Could not verify the Stripe sandbox webhook.');
  const endpoint = await endpointResponse.json();
  if (endpoint.livemode || endpoint.url !== webhookUrl ||
      endpoint.api_version !== '2026-09-30.endive') {
    throw new Error('The Stripe webhook does not match the staging URL/API version.');
  }

  const configured = await fetcher(`https://api.supabase.com/v1/projects/${project}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      query: `begin; select set_config('request.jwt.claim.role', 'service_role', true); select public.configure_stripe_reconciliation(${sqlLiteral(workerUrl)}, ${sqlLiteral(env.STRIPE_RECONCILE_SECRET)}); commit;`,
    }),
    signal: AbortSignal.timeout(30_000),
  });
  // Do not print SQL errors: database diagnostics can include secret arguments.
  if (!configured.ok) throw new Error('Could not schedule the protected Stripe recovery worker.');

  const events = ['payment_intent.succeeded', 'payment_intent.payment_failed',
    'payment_intent.processing', 'payment_intent.canceled', 'refund.created',
    'refund.updated', 'refund.failed'];
  const body = new URLSearchParams({ disabled: 'false' });
  for (const event of events) body.append('enabled_events[]', event);
  const enabled = await fetcher(endpointUrl, {
    method: 'POST', headers: stripeHeaders, body,
    signal: AbortSignal.timeout(30_000),
  });
  if (!enabled.ok) throw new Error('Could not enable the Stripe sandbox webhook.');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    await configure(process.env);
    console.log('Staging Stripe webhook and five-minute recovery schedule configured.');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
