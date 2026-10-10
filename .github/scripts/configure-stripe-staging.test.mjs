import test from 'node:test';
import assert from 'node:assert/strict';
import { configure, validateConfiguration, sqlLiteral } from './configure-stripe-staging.mjs';

const env = {
  SUPABASE_PROJECT_REF: 'nfdkdhdevpstfspazbfn',
  STRIPE_SECRET_KEY: 'sk_test_placeholder',
  STRIPE_WEBHOOK_SECRET: 'whsec_placeholder',
  STRIPE_RECONCILE_SECRET: 'worker_test_placeholder_32_characters',
  STRIPE_WEBHOOK_ENDPOINT_ID: 'we_placeholder',
  SUPABASE_ACCESS_TOKEN: 'test_token',
};
test('refuses production, live keys and incomplete worker setup', () => {
  for (const changes of [
    { SUPABASE_PROJECT_REF: 'zjsjuuhborxrlmdcpvlj' },
    { STRIPE_SECRET_KEY: 'sk_live_placeholder' },
    { STRIPE_RECONCILE_SECRET: '' },
    { STRIPE_WEBHOOK_ENDPOINT_ID: '../other' },
  ]) assert.throws(() => validateConfiguration({ ...env, ...changes }));
  assert.doesNotThrow(() => validateConfiguration(env));
});
test('SQL literals escape quotes in worker credentials', () => {
  assert.equal(sqlLiteral("secret'quote"), "'secret''quote'");
});
test('only enables matching webhook after protected worker configuration succeeds', async () => {
  const calls = [];
  await configure(env, async (url, options) => {
    calls.push({ url, options });
    return Response.json(calls.length === 1 ? {
      livemode: false, api_version: '2026-09-30.endive',
      url: 'https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/stripe-payment-webhook',
    } : {});
  });
  assert.equal(calls.length, 3);
  assert.match(JSON.parse(calls[1].options.body).query, /configure_stripe_reconciliation/);
  assert.equal(calls[2].options.body.get('disabled'), 'false');
  assert.equal(calls[2].options.body.getAll('enabled_events[]').length, 7);
});
test('does not activate a webhook when scheduling fails; hides provider response body', async () => {
  let calls = 0;
  await assert.rejects(configure(env, async () => {
    calls++;
    return calls === 1 ? Response.json({
      livemode: false, api_version: '2026-09-30.endive',
      url: 'https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/stripe-payment-webhook',
    }) : new Response('private server diagnostics', { status: 400 });
  }), { message: 'Could not schedule the protected Stripe recovery worker.' });
  assert.equal(calls, 2);
});
