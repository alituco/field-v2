import { loadAllRows } from "../src/lib/paginated-rows.ts";
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import * as identities from '../src/lib/staff-identities.ts';

const email = 'referee+staff@example.test';
const authId = '30000000-0000-4000-8000-000000000001';
const staffId = '40000000-0000-4000-8000-000000000001';
const identity = { id: authId, email, email_confirmed_at: '2026-10-20T00:00:00Z', app_metadata: { fieldrush_account_type: 'staff' } };
const staff = { profile_id: staffId, auth_user_id: authId, email, display_name: 'Independent Referee', phone: null, role: 'admin', is_active: true };
const ts = createRequire(import.meta.url)('typescript');
class Response {
  constructor(body, init = {}) { this.body = body; this.status = init.status ?? 200; this.headers = init.headers ?? {}; }
  static json(body, init) { return new Response(body, init); }
}
function load(path, modules) {
  const source = readFileSync(new URL(path, import.meta.url), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, Error, Date, require: name => { assert.ok(name in modules, name); return modules[name]; } });
  return exports;
}

function session(options = {}) {
  const calls = { auth: [], reads: [] };
  const chain = { select: () => chain, eq: (...args) => { calls.reads.push(args); return chain; },
    maybeSingle: async () => ({ data: options.staff === undefined ? staff : options.staff, error: options.readError ?? null }) };
  const db = { auth: { getUser: async token => { calls.auth.push(token); return { data: { user: options.user === undefined ? identity : options.user }, error: options.authError ?? null }; } },
    from: table => { assert.equal(table, 'referee_profiles'); return chain; } };
  const api = load('../src/lib/referee-session.ts', { 'next/server': { NextResponse: Response },
    './supabase-admin': { createSupabaseAdmin: () => db }, './staff-identities': identities });
  return { ...api, calls, run: token => api.requireReferee({ headers: { get: () => token } }) };
}

test('staff authorization requires an independent verified email identity before any staff lookup', async () => {
  const missing = session();
  assert.equal((await missing.run(null)).status, 401);
  assert.equal(missing.calls.auth.length, 0);
  for (const user of [
    { ...identity, app_metadata: {}, user_metadata: { fieldrush_account_type: 'staff' } },
    { ...identity, email_confirmed_at: null }, { ...identity, phone: '15551234567' },
    { ...identity, banned_until: '2099-01-01T00:00:00Z' }, { ...identity, deleted_at: '2026-01-01T00:00:00Z' },
  ]) {
    const api = session({ user });
    assert.equal((await api.run('Bearer valid-token')).status, 403);
    assert.equal(api.calls.reads.length, 0);
  }
});

test('staff sessions map independent Auth IDs to stable operational staff IDs', async () => {
  const api = session();
  const result = await api.run('Bearer valid-token');
  assert.equal(result.referee.profileId, staffId);
  assert.equal(result.referee.email, email);
  assert.equal(result.referee.phone, '');
  assert.equal(result.referee.role, 'admin');
  assert.deepEqual(api.calls.reads, [['auth_user_id', authId]]);
});

test('missing, inactive and mismatched mappings fail closed with sanitized errors', async () => {
  for (const record of [null, { ...staff, is_active: false }, { ...staff, auth_user_id: 'other' }, { ...staff, email: 'player@example.test' }]) {
    assert.equal((await session({ staff: record }).run('Bearer valid-token')).status, 403);
  }
  assert.equal((await session({ authError: new Error('private Auth diagnostic') }).run('Bearer invalid-token')).status, 401);
  const failed = await session({ readError: new Error('private DB diagnostic') }).run('Bearer valid-token');
  assert.equal(failed.status, 500);
  assert.doesNotMatch(failed.body.error, /private/);
});

function otp(options = {}) {
  const calls = { otp: [], auth: [] };
  const chain = { select: () => chain, eq: () => chain, maybeSingle: async () => ({ data: options.staff === undefined ? staff : options.staff, error: options.readError ?? null }) };
  const db = { from: () => chain, auth: { admin: { getUserById: async id => { calls.auth.push(id);
    return { data: { user: options.user === undefined ? identity : options.user }, error: options.authError ?? null }; } } } };
  const api = load('../src/app/api/staff-auth/code/route.ts', { 'next/server': { NextResponse: Response },
    '@/lib/staff-identities': identities, '@/lib/supabase-admin': {
      createSupabaseAdmin: () => db, createSupabasePublic: () => ({ auth: { signInWithOtp: async args => {
        calls.otp.push(args); if (options.deliveryError) throw new Error('private SMTP diagnostic'); return { error: null };
      } } }),
    } });
  return { calls, run: (body = { email }) => api.POST({ json: async () => body }) };
}

test('only invited active staff receive email OTP and login cannot create users', async () => {
  for (const email_confirmed_at of [null, identity.email_confirmed_at]) {
    const api = otp({ user: { ...identity, email_confirmed_at } });
    const reply = await api.run({ email: ' Referee+STAFF@example.test ' });
    assert.equal(reply.status, 200);
    assert.deepEqual(JSON.parse(JSON.stringify(reply.body)), { ok: true });
    assert.equal(reply.headers['Cache-Control'], 'private, no-store');
    assert.deepEqual(JSON.parse(JSON.stringify(api.calls.otp)), [{ email, options: { shouldCreateUser: false } }]);
  }
});

test('unknown, inactive, unmigrated, player and failed requests expose the same public reply', async () => {
  for (const options of [
    { staff: null }, { staff: { ...staff, is_active: false } }, { staff: { ...staff, auth_user_id: null } },
    { user: { ...identity, app_metadata: {} } }, { user: { ...identity, email: 'player@example.test' } },
    { user: { ...identity, id: 'other-user' } },
    { readError: new Error('private') }, { authError: new Error('private') }, { deliveryError: true },
  ]) {
    const api = otp(options);
    const reply = await api.run();
    assert.equal(reply.status, 200);
    assert.deepEqual(JSON.parse(JSON.stringify(reply.body)), { ok: true });
    if (!options.deliveryError) assert.equal(api.calls.otp.length, 0);
  }
  for (const email of [null, 'bad', 'a@b', 'name\n@host.test']) {
    const api = otp();
    assert.deepEqual(JSON.parse(JSON.stringify((await api.run({ email })).body)), { ok: true });
    assert.equal(api.calls.otp.length, 0);
  }
});

test('assignment choices include verified independent staff and sanitize optional contact fields', async () => {
  const reads = [];
  const rows = [staff, { ...staff, profile_id: 'unverified', auth_user_id: 'unverified-auth' }];
  const db = { from: table => {
    const chain = { select: () => chain, eq: () => chain, not: (...args) => { reads.push(args); return chain; },
      in: () => chain, order: () => chain, range: () => chain,
      then: resolve => resolve({ data: table === 'referee_profiles' ? rows : [], error: null }) };
    return chain;
  }, auth: { admin: { getUserById: async id => ({ data: { user: id === authId ? identity : { ...identity, id, email_confirmed_at: null } }, error: null }) } } };
  const api = load('../src/app/api/referee/assignments/route.ts', { 'next/server': { NextResponse: Response },
    '@/lib/staff-identities': identities,
    '@/lib/paginated-rows': { loadAllRows },
    '@/lib/referee-session': { requireReferee: async () => ({ db, referee: { profileId: staffId, role: 'admin' } }),
      isRefereeContext: () => true, adminOnly: () => null },
  });
  const result = await api.GET({});
  assert.equal(result.status, 200);
  assert.equal(result.body.referees.length, 1);
  assert.equal(result.body.referees[0].profileId, staffId);
  assert.equal(result.body.referees[0].email, email);
  assert.equal(result.body.referees[0].phone, '');
  assert.ok(reads.some(args => args[0] === 'auth_user_id'));
});
