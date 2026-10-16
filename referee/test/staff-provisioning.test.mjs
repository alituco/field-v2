import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { normalizePhoneNumber } from '../src/lib/phone.ts';

const actor = { profileId: '10000000-0000-4000-8000-000000000001', role: 'admin' };
const phone = '+15551234567';
const input = { displayName: 'Staff Display', phone, role: 'referee', sendOtp: true };
const player = {
  id: '20000000-0000-4000-8000-000000000001', phone: phone.slice(1),
  encrypted_password: randomUUID(), phone_confirmed_at: '2026-01-01T00:00:00Z',
  user_metadata: { name: 'Original Player', display_name: 'Original Player', private_value: 'keep' },
  identities: [{ provider: 'google', identity_data: { email: 'player@example.test', email_verified: true } }, { provider: 'phone' }],
};

function route(options = {}) {
  const calls = { list: [], create: [], rpc: [], otp: [], tables: [] };
  let users = structuredClone(options.users ?? [player]);
  const db = {
    auth: { admin: {
      listUsers: async (args) => { calls.list.push(args); return options.list ? options.list(args) : { data: { users }, error: null }; },
      createUser: async (args) => {
        calls.create.push(args);
        if (options.create) return options.create(args, (value) => { users = value; });
        const user = { id: '30000000-0000-4000-8000-000000000001', phone: args.phone.slice(1) };
        users = [user];
        return { data: { user }, error: null };
      },
      updateUserById: () => { throw new Error('Existing Auth identity must never be updated'); },
      deleteUser: () => { throw new Error('Provisioning must never delete an Auth identity'); },
    } },
    from: (table) => { calls.tables.push(table); throw new Error('Profiles must only be changed by the guarded RPC'); },
    rpc: async (name, args) => {
      calls.rpc.push([name, args]);
      if (options.rpc) return options.rpc(name, args);
      return { data: { staff: { profile_id: args.target_profile_id, display_name: args.display_name_to_use, phone: args.expected_phone, role: args.role_to_use, is_active: true }, already_active: false }, error: null };
    },
  };
  const modules = {
    'next/server': { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200 }) } },
    '@/lib/phone': { normalizePhoneNumber },
    '@/lib/referee-session': {
      requireReferee: async () => options.identity === null ? { status: 401 } : { referee: options.identity ?? actor, db },
      isRefereeContext: (value) => 'referee' in value,
      adminOnly: (value) => value.role === 'admin' ? null : { status: 403 },
    },
    '@/lib/supabase-admin': { createSupabasePublic: () => {
      if (options.publicError) throw new Error('private provider setup diagnostic');
      return { auth: { signInWithOtp: async (args) => { calls.otp.push(args); return { error: options.otpError ?? null }; } } };
    } },
  };
  const ts = createRequire(import.meta.url)('typescript');
  const source = readFileSync(new URL('../src/app/api/referee/referees/route.ts', import.meta.url), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, Error, require: (name) => { assert.ok(name in modules, name); return modules[name]; } });
  return { ...exports, calls, users: () => users, post: (body = input) => exports.POST({ json: async () => body }) };
}

test('only an authenticated admin can provision staff', async () => {
  for (const [identity, status] of [[null, 401], [{ ...actor, role: 'referee' }, 403]]) {
    const api = route({ identity });
    assert.equal((await api.post()).status, status);
    assert.deepEqual(api.calls, { list: [], create: [], rpc: [], otp: [], tables: [] });
  }
});

test('promoting a Google-and-phone player preserves their Auth identity and player profile', async () => {
  const api = route();
  const before = structuredClone(api.users());
  const result = await api.post();
  assert.equal(result.status, 200);
  assert.equal(result.body.accountCreated, false);
  assert.equal(result.body.staff.profileId, player.id);
  assert.deepEqual(api.users(), before);
  assert.equal(api.calls.create.length, 0);
  assert.equal(api.calls.tables.length, 0);
  assert.equal(api.calls.rpc[0][0], 'admin_grant_fieldrush_staff');
  assert.equal(api.calls.rpc[0][1].actor_admin_id, actor.profileId);
  assert.equal(api.calls.rpc[0][1].target_profile_id, player.id);
  assert.deepEqual(JSON.parse(JSON.stringify(api.calls.otp)), [{ phone, options: { shouldCreateUser: false } }]);
});

test('password resets and forged identity fields are refused before looking up any account', async () => {
  for (const extra of [{ password: 'not-a-password' }, { resetPassword: true }, { actor_admin_id: player.id }, { userId: player.id }, { phone_confirm: true }, { role: 'owner' }, { sendOtp: 'yes' }]) {
    const api = route();
    const result = await api.post({ ...input, ...extra });
    assert.equal(result.status, 400);
    assert.equal(api.calls.list.length, 0);
    assert.equal(api.calls.rpc.length, 0);
  }
});

test('new staff receive a phone-only sign-in without an administrator-set password or fake verification', async () => {
  const api = route({ users: [] });
  const result = await api.post();
  assert.equal(result.status, 200);
  assert.equal(result.body.accountCreated, true);
  const created = api.calls.create[0];
  assert.equal(created.phone, phone);
  assert.equal(created.phone_confirm, false);
  assert.equal('password' in created, false);
  assert.equal(api.calls.rpc[0][1].target_profile_id, result.body.profileId);
});

test('a concurrent duplicate phone creation is reused without resetting or deleting the winning identity', async () => {
  const api = route({ users: [], create: (_args, setUsers) => {
    setUsers([structuredClone(player)]);
    return { data: { user: null }, error: { code: 'phone_exists', message: 'private provider diagnostic' } };
  } });
  const result = await api.post();
  assert.equal(result.status, 200);
  assert.equal(result.body.accountCreated, false);
  assert.equal(result.body.profileId, player.id);
  assert.deepEqual(api.users(), [player]);
  assert.equal(api.calls.create.length, 1);
});

test('permissions revoked during provisioning fail in the RPC before any login message', async () => {
  const api = route({ rpc: () => ({ data: null, error: { code: '42501', message: 'private database diagnostic' } }) });
  const result = await api.post();
  assert.equal(result.status, 400);
  assert.match(result.body.error, /Active administrator/);
  assert.doesNotMatch(result.body.error, /private/);
  assert.equal(api.calls.otp.length, 0);
  assert.deepEqual(api.users(), [player]);
});

test('failed or malformed grants never report staff access or mutate an existing player', async () => {
  for (const response of [
    { data: null, error: { code: 'XX000', message: 'private database diagnostic' } },
    { data: { staff: { profile_id: 'wrong-user', is_active: true } }, error: null },
  ]) {
    const api = route({ rpc: () => response });
    const result = await api.post();
    assert.equal(result.status, 400);
    assert.match(result.body.error, /could not be confirmed/);
    assert.doesNotMatch(result.body.error, /private/);
    assert.equal(api.calls.otp.length, 0);
    assert.deepEqual(api.users(), [player]);
  }
});

test('login delivery failures preserve the successful grant and provide a truthful warning', async () => {
  for (const options of [{ otpError: { message: 'private SMS diagnostic' } }, { publicError: true }]) {
    const api = route(options);
    const result = await api.post();
    assert.equal(result.status, 200);
    assert.match(result.body.warning, /Staff access is ready, but the login code/);
    assert.doesNotMatch(result.body.warning, /private/);
    assert.equal(api.calls.rpc.length, 1);
  }
});

test('a failed Auth creation or incomplete directory scan never grants access', async () => {
  const api = route({ users: [], create: () => ({ data: { user: null }, error: { message: 'private Auth diagnostic' } }) });
  assert.equal((await api.post()).status, 400);
  assert.equal(api.calls.rpc.length, 0);
  const full = route({ list: () => ({ data: { users: Array(1000).fill({ phone: '15550000000' }) }, error: null }) });
  const result = await full.post();
  assert.equal(result.status, 400);
  assert.match(result.body.error, /searched completely/);
  assert.equal(full.calls.list.length, 10);
  assert.equal(full.calls.create.length, 0);
  assert.equal(full.calls.rpc.length, 0);
});

test('UI describes access grants and protects existing player credentials', () => {
  const source = readFileSync(new URL('../src/app/admin/page.tsx', import.meta.url), 'utf8');
  assert.match(source, /Existing players keep their sign-in credentials, linked Google account/);
  assert.match(source, /Add \$\{role\} access/);
  assert.match(source, /This does not reset its password or change its Google link/);
  assert.doesNotMatch(source, /create their Field account/);
});
