import assert from 'node:assert/strict';
import test from 'node:test';
import { configure, preflight, productionStripeEvents, sqlLiteral, validateConfiguration } from './configure-stripe-production.mjs';

const env = {
  SUPABASE_PROJECT_REF: 'zjsjuuhborxrlmdcpvlj',
  PRODUCTION_STRIPE_LIVE_ROLLOUT: 'LIVE_STRIPE_READY',
  STRIPE_ACCOUNT_ID: 'acct_fixture',
  STRIPE_SECRET_KEY: 'sk_live_fixture',
  STRIPE_PUBLISHABLE_KEY: 'pk_live_fixture',
  STRIPE_WEBHOOK_SECRET: 'whsec_fixture',
  STRIPE_RECONCILE_SECRET: 'fixture_private_worker_secret_32_characters',
  STRIPE_WEBHOOK_ENDPOINT_ID: 'we_fixture',
  SUPABASE_ACCESS_TOKEN: 'fixture_private_token',
};
const account = { id: env.STRIPE_ACCOUNT_ID, charges_enabled: true, payouts_enabled: true, details_submitted: true };
const endpoint = {
  id: env.STRIPE_WEBHOOK_ENDPOINT_ID, livemode: true,
  url: 'https://zjsjuuhborxrlmdcpvlj.supabase.co/functions/v1/stripe-payment-webhook',
  api_version: '2026-09-30.endive', status: 'disabled',
};
const activated = { ...endpoint, status: 'enabled', enabled_events: [...productionStripeEvents] };

function provider(options = {}) {
  const calls = [];
  return {
    calls,
    fetcher: async (url, init) => {
      calls.push({ url, ...init });
      const n = calls.length;
      if (options.failAt === n) return new Response('private provider response', { status: 400 });
      if (options.throwAt === n) throw new Error('private credential in network diagnostic');
      if (n === 1) return Response.json(options.account ?? account);
      if (n === 2) return Response.json(options.endpoint ?? endpoint);
      if (n === 3) return Response.json([]);
      return Response.json(options.activation ?? activated);
    },
  };
}

test('production preflight reads only the selected live merchant and endpoint', async () => {
  const fixture = provider();
  assert.deepEqual(await preflight(env, fixture.fetcher), { project: env.SUPABASE_PROJECT_REF, verified: true });
  assert.equal(fixture.calls.length, 2);
  for (const call of fixture.calls) {
    assert.equal(call.method, undefined);
    assert.equal(new URL(call.url).origin, 'https://api.stripe.com');
    assert.equal(call.headers['Stripe-Version'], '2026-09-30.endive');
  }
});

test('requires exact production, explicit live confirmation, matching key modes and bounded worker secrets before requests', async () => {
  for (const changes of [
    { SUPABASE_PROJECT_REF: 'nfdkdhdevpstfspazbfn' },
    { SUPABASE_PROJECT_REF: 'lookalikeprojectxxxxx' },
    { PRODUCTION_STRIPE_LIVE_ROLLOUT: undefined },
    { PRODUCTION_STRIPE_LIVE_ROLLOUT: 'true' },
    { STRIPE_SECRET_KEY: 'sk_test_fixture' },
    { STRIPE_SECRET_KEY: 'sk_live_fixture\nOTHER=bad' },
    { STRIPE_PUBLISHABLE_KEY: 'pk_test_fixture' },
    { STRIPE_WEBHOOK_SECRET: '' },
    { STRIPE_WEBHOOK_ENDPOINT_ID: '../other' },
    { STRIPE_ACCOUNT_ID: undefined },
    { STRIPE_ACCOUNT_ID: 'acct_other/route' },
    { STRIPE_RECONCILE_SECRET: 'short' },
    { STRIPE_RECONCILE_SECRET: 'x'.repeat(513) },
    { STRIPE_RECONCILE_SECRET: 'x'.repeat(32) + '\n' },
    ...['"', "'", '$', '#', '\\'].map(character => ({ STRIPE_RECONCILE_SECRET: character + 'x'.repeat(32) })),
    { SUPABASE_ACCESS_TOKEN: ' ' },
  ]) {
    const fixture = provider();
    assert.throws(() => validateConfiguration({ ...env, ...changes }));
    await assert.rejects(preflight({ ...env, ...changes }, fixture.fetcher));
    assert.deepEqual(fixture.calls, []);
  }
});

for (const changes of [
  { id: 'acct_other' }, { charges_enabled: false }, { payouts_enabled: false },
  { details_submitted: false }, { charges_enabled: 'true' },
]) {
  test(`account readiness mismatch refuses all activation: ${JSON.stringify(changes)}`, async () => {
    const fixture = provider({ account: { ...account, ...changes } });
    await assert.rejects(configure(env, fixture.fetcher), /configured merchant|ready for charges/);
    assert.equal(fixture.calls.length, 1);
  });
}

for (const changes of [
  { id: 'we_other' }, { livemode: false }, { api_version: '2025-01-01' },
  { url: 'https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/stripe-payment-webhook' },
  { url: endpoint.url + '?other=1' },
]) {
  test(`webhook mismatch refuses all activation: ${JSON.stringify(changes)}`, async () => {
    const fixture = provider({ endpoint: { ...endpoint, ...changes } });
    await assert.rejects(configure(env, fixture.fetcher), /production endpoint/);
    assert.equal(fixture.calls.length, 2);
  });
}

test('schedules only production recovery before enabling and verifying the required webhook events', async () => {
  const fixture = provider();
  await configure(env, fixture.fetcher);
  assert.equal(fixture.calls.length, 4);
  const worker = fixture.calls[2];
  assert.equal(worker.url, 'https://api.supabase.com/v1/projects/zjsjuuhborxrlmdcpvlj/database/query');
  assert.equal(worker.method, 'POST');
  assert.match(JSON.parse(worker.body).query, /https:\/\/zjsjuuhborxrlmdcpvlj\.supabase\.co\/functions\/v1\/stripe-payment-reconcile/);
  assert.match(JSON.parse(worker.body).query, /configure_stripe_reconciliation/);
  const activation = fixture.calls[3];
  assert.equal(activation.method, 'POST');
  assert.equal(activation.body.get('disabled'), 'false');
  assert.deepEqual(activation.body.getAll('enabled_events[]'), [...productionStripeEvents]);
  assert.equal(sqlLiteral("a'worker"), "'a''worker'");
});

test('worker failure never enables a webhook and suppresses provider diagnostics', async () => {
  const fixture = provider({ failAt: 3 });
  await assert.rejects(configure(env, fixture.fetcher), { message: 'Could not schedule the protected production Stripe recovery worker.' });
  assert.equal(fixture.calls.length, 3);
});

for (const changes of [
  { status: 'disabled' }, { livemode: false }, { id: 'we_other' },
  { enabled_events: [] }, { enabled_events: [...productionStripeEvents, '*'] },
]) {
  test(`activation acknowledgement is required: ${JSON.stringify(changes)}`, async () => {
    const fixture = provider({ activation: { ...activated, ...changes } });
    await assert.rejects(configure(env, fixture.fetcher), /activation was not acknowledged/);
    assert.equal(fixture.calls.length, 4);
  });
}

for (const n of [1, 2, 3, 4]) {
  test(`network failure ${n} is sanitized and stops subsequent operations`, async () => {
    const fixture = provider({ throwAt: n });
    await assert.rejects(configure(env, fixture.fetcher), error => {
      assert.doesNotMatch(error.message, /private|credential/);
      return true;
    });
    assert.equal(fixture.calls.length, n);
  });
}
