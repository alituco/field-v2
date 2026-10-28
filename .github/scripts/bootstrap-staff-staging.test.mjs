import assert from 'node:assert/strict';
import test from 'node:test';
import { bootstrapStaffStaging, stagingStaffProject } from './bootstrap-staff-staging.mjs';
const staffId = '20000400-0000-4000-8000-000000000001';
const userId = '20000400-0000-4000-8000-000000000002';
const email = 'operator+staff@example.test';
const env = { SUPABASE_URL: `https://${stagingStaffProject}.supabase.co`, SUPABASE_SERVICE_ROLE_KEY: 'private-service-key' };
function harness({ collision = null, failBinding = false, bound = false, otherAdmin = false } = {}) {
  const calls = [];
  const fetcher = async (url, options) => {
    const path = new URL(url).pathname;
    const body = options.body && JSON.parse(options.body);
    calls.push({ path, method: options.method, body });
    if (path === '/rest/v1/referee_profiles' && new URL(url).searchParams.has('role')) return Response.json(otherAdmin ? [{ profile_id: userId }] : []);
    if (path === '/rest/v1/referee_profiles') return Response.json([{ profile_id: staffId, role: 'admin', is_active: true, auth_user_id: bound ? userId : null, email: bound ? email : null }]);
    if (path === '/auth/v1/admin/users' && options.method === 'GET') return Response.json({ users: collision ? [collision] : [] });
    if (path === '/rest/v1/profiles') return Response.json([]);
    if (path === '/auth/v1/admin/users') return Response.json({ id: userId, email, app_metadata: { fieldrush_account_type: 'staff' } });
    if (path.endsWith('/bootstrap_independent_staff_admin')) return failBinding ? new Response('provider secret', { status: 409 }) : Response.json({ staff: { profile_id: staffId, auth_user_id: userId, email } });
    if (path === '/auth/v1/otp') return Response.json({});
    throw new Error('Unexpected request');
  };
  return { calls, fetcher };
}
const input = { staffId, email, apply: false, sendCode: false };
test('staff bootstrap refuses production, missing credentials and implicit writes', async () => {
  const h = harness();
  for (const bad of [{ ...env, SUPABASE_URL: 'https://production.supabase.co' }, { ...env, SUPABASE_SERVICE_ROLE_KEY: '' }]) {
    await assert.rejects(bootstrapStaffStaging(bad, input, h), /exact staging/);
  }
  await assert.rejects(bootstrapStaffStaging(env, { ...input, sendCode: true }, h), /explicit apply/);
  assert.equal(h.calls.length, 0);
});
test('dry-run inspects exact staff and directory without creating, binding or sending', async () => {
  const h = harness();
  const result = await bootstrapStaffStaging(env, input, h);
  assert.equal(result.mode, 'dry-run');
  assert.ok(h.calls.every(call => call.method === 'GET'));
  assert.equal(result.bound, false);
});
test('an already bootstrapped installation cannot create orphan bootstrap identities', async () => {
  const h = harness({ otherAdmin: true });
  await assert.rejects(bootstrapStaffStaging(env, { ...input, apply: true }, h), /independent administrator already exists/);
  assert.ok(h.calls.every(call => call.method === 'GET'));
  assert.ok(!h.calls.some(call => call.path === '/auth/v1/admin/users'));
});
test('apply creates an unconfirmed dedicated identity, binds stable staff ID and only explicitly sends code', async () => {
  const h = harness();
  const result = await bootstrapStaffStaging(env, { ...input, apply: true, sendCode: true }, h);
  assert.equal(result.bound, true);
  assert.equal(result.loginCodeSent, true);
  const create = h.calls.find(call => call.path === '/auth/v1/admin/users' && call.method === 'POST');
  assert.deepEqual(create.body, { email, email_confirm: false, app_metadata: { fieldrush_account_type: 'staff' } });
  assert.deepEqual(h.calls.at(-1).body, { email, create_user: false });
  assert.ok(!h.calls.some(call => ['DELETE', 'PUT', 'PATCH'].includes(call.method)));
});
test('player email collision never modifies or repurposes that identity', async () => {
  const h = harness({ collision: { id: userId, email, app_metadata: {}, phone: '+15551112222' } });
  await assert.rejects(bootstrapStaffStaging(env, { ...input, apply: true }, h), /staff-only email/);
  assert.ok(h.calls.every(call => call.method === 'GET'));
});
test('binding failure neither deletes Auth nor sends a code and does not log provider diagnostics', async () => {
  const h = harness({ failBinding: true });
  await assert.rejects(bootstrapStaffStaging(env, { ...input, apply: true, sendCode: true }, h), error => /HTTP 409/.test(error.message) && !error.message.includes('provider secret'));
  assert.ok(!h.calls.some(call => call.method === 'DELETE' || call.path === '/auth/v1/otp'));
});
test('retry reuses only the same marked phone-free staff identity without resetting credentials', async () => {
  const h = harness({ collision: { id: userId, email, app_metadata: { fieldrush_account_type: 'staff' } }, bound: true });
  const result = await bootstrapStaffStaging(env, { ...input, apply: true }, h);
  assert.equal(result.bound, true);
  assert.ok(!h.calls.some(call => call.path === '/auth/v1/admin/users' && call.method !== 'GET'));
});
