import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import * as identities from '../src/lib/staff-identities.ts';

const actor = { profileId: '10000000-0000-4000-8000-000000000001', role: 'admin' };
const email = 'referee+staff@example.test';
const authId = '30000000-0000-4000-8000-000000000001';
const stableId = '40000000-0000-4000-8000-000000000001';
const input = { displayName: 'Staff Display', email, role: 'referee', sendOtp: true };
const player = { id: '20000000-0000-4000-8000-000000000001', email: 'player@example.test', phone: '15551234567',
  encrypted_password: 'unchanged-password-hash', phone_confirmed_at: '2026-01-01T00:00:00Z',
  user_metadata: { display_name: 'Original Player' }, app_metadata: {},
  identities: [{ provider: 'google' }, { provider: 'phone' }] };
const staffUser = (extra = {}) => ({ id: authId, email, app_metadata: { fieldrush_account_type: 'staff' }, ...extra });

function route(options = {}) {
  const calls = { list: [], create: [], rpc: [], otp: [], tables: [] };
  let users = structuredClone(options.users ?? [player]);
  const db = {
    auth: { admin: {
      listUsers: async args => { calls.list.push(args); return options.list ? options.list(args) : { data: { users }, error: null }; },
      createUser: async args => {
        calls.create.push(args);
        if (options.create) return options.create(args, value => { users = value; });
        const user = staffUser({ email: args.email, app_metadata: args.app_metadata });
        users = [...users, user];
        return { data: { user }, error: null };
      },
      updateUserById: () => { throw new Error('Provisioning must never edit Auth identities'); },
      deleteUser: () => { throw new Error('Provisioning must never delete Auth identities'); },
    } },
    from: table => {
      calls.tables.push(table);
      if (options.directoryRows) {
        const chain = { select: () => chain, order: () => chain,
          then: resolve => resolve({ data: options.directoryRows, error: null }) };
        return chain;
      }
      assert.equal(table, 'referee_profiles');
      const chain = { select: () => chain, eq: () => chain,
        maybeSingle: async () => ({ data: Object.hasOwn(options, 'existingStaffRow') ? options.existingStaffRow : {
          profile_id: stableId, display_name: input.displayName, role: input.role, is_active: true,
        }, error: options.existingStaffError ?? null }) };
      return chain;
    },
    rpc: async (name, args) => {
      calls.rpc.push([name, args]);
      if (options.rpc) return options.rpc(name, args);
      return { data: { staff: { profile_id: args.existing_staff_profile_id ?? stableId,
        auth_user_id: args.target_auth_user_id, display_name: args.display_name_to_use,
        email: args.expected_email, phone: null, role: args.role_to_use, is_active: true }, already_active: false }, error: null };
    },
  };
  const modules = {
    'next/server': { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200 }) } },
    '@/lib/staff-identities': identities,
    '@/lib/referee-session': {
      requireReferee: async () => options.identity === null ? { status: 401 } : { referee: options.identity ?? actor, db },
      isRefereeContext: value => 'referee' in value,
      adminOnly: value => value.role === 'admin' ? null : { status: 403 },
    },
    '@/lib/supabase-admin': { createSupabasePublic: () => {
      if (options.publicError) throw new Error('private provider setup diagnostic');
      return { auth: { signInWithOtp: async args => { calls.otp.push(args); return { error: options.otpError ?? null }; } } };
    } },
  };
  const ts = createRequire(import.meta.url)('typescript');
  const source = readFileSync(new URL('../src/app/api/referee/referees/route.ts', import.meta.url), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, Error, require: name => { assert.ok(name in modules, name); return modules[name]; } });
  return { ...exports, calls, users: () => users, post: (body = input) => exports.POST({ json: async () => body }) };
}

test('only an authenticated administrator can provision independent staff', async () => {
  for (const [identity, status] of [[null, 401], [{ ...actor, role: 'referee' }, 403]]) {
    const api = route({ identity });
    assert.equal((await api.post()).status, status);
    assert.deepEqual(api.calls, { list: [], create: [], rpc: [], otp: [], tables: [] });
  }
});

test('staff creation uses a new dedicated email identity and leaves player credentials and Google links intact', async () => {
  const api = route();
  const result = await api.post({ ...input, email: ' Referee+STAFF@example.test ' });
  assert.equal(result.status, 200);
  assert.equal(result.body.accountCreated, true);
  assert.equal(result.body.profileId, stableId);
  assert.equal(result.body.staff.email, email);
  assert.deepEqual(api.users().find(user => user.id === player.id), player);
  assert.deepEqual(JSON.parse(JSON.stringify(api.calls.create)), [{ email, email_confirm: false,
    app_metadata: { fieldrush_account_type: 'staff' }, user_metadata: { display_name: input.displayName } }]);
  assert.deepEqual(JSON.parse(JSON.stringify(api.calls.otp)), [{ email, options: { shouldCreateUser: false } }]);
  assert.equal(api.calls.tables.length, 0);
  assert.equal(api.calls.rpc[0][0], 'admin_grant_independent_staff');
  assert.equal(api.calls.rpc[0][1].actor_admin_id, actor.profileId);
  assert.equal(api.calls.rpc[0][1].target_auth_user_id, authId);
});

test('an email already used by a player is rejected even if user metadata claims staff', async () => {
  for (const app_metadata of [{}, { fieldrush_account_type: 'player' }]) {
    const existing = { ...player, email, app_metadata, user_metadata: { fieldrush_account_type: 'staff' } };
    const api = route({ users: [existing] });
    assert.equal((await api.post()).status, 400);
    assert.deepEqual(api.users(), [existing]);
    assert.equal(api.calls.create.length, 0);
    assert.equal(api.calls.rpc.length, 0);
    assert.equal(api.calls.otp.length, 0);
  }
});

test('retries reuse only independently marked staff and preserve the stable historical staff key', async () => {
  const api = route({ users: [player, staffUser()] });
  const result = await api.post({ ...input, existingStaffProfileId: stableId, sendOtp: false });
  assert.equal(result.status, 200);
  assert.equal(result.body.accountCreated, false);
  assert.equal(result.body.profileId, stableId);
  assert.equal(api.calls.create.length, 0);
  assert.equal(api.calls.otp.length, 0);
  assert.equal(api.calls.rpc[0][1].existing_staff_profile_id, stableId);
});

test('inactive, missing or changed retained staff cannot create an Auth invitation or commit a binding', async () => {
  for (const existingStaffRow of [null,
    { profile_id: stableId, display_name: input.displayName, role: input.role, is_active: false },
    { profile_id: stableId, display_name: 'Changed Staff', role: input.role, is_active: true },
    { profile_id: stableId, display_name: input.displayName, role: 'admin', is_active: true },
  ]) {
    const api = route({ existingStaffRow });
    const result = await api.post({ ...input, existingStaffProfileId: stableId });
    assert.equal(result.status, 400);
    assert.equal(api.calls.list.length, 0);
    assert.equal(api.calls.create.length, 0);
    assert.equal(api.calls.rpc.length, 0);
    assert.equal(api.calls.otp.length, 0);
    assert.deepEqual(api.users(), [player]);
  }
  const failed = route({ existingStaffError: { message: 'private database diagnostic' } });
  const result = await failed.post({ ...input, existingStaffProfileId: stableId });
  assert.equal(result.status, 400);
  assert.doesNotMatch(result.body.error, /private/);
  assert.equal(failed.calls.create.length, 0);
});

test('an offboarding race rejected by the database never sends an invitation code', async () => {
  const api = route({ rpc: () => ({ data: null, error: { code: '22023', message: 'inactive retained staff' } }) });
  const result = await api.post({ ...input, existingStaffProfileId: stableId });
  assert.equal(result.status, 400);
  assert.equal(api.calls.rpc.length, 1);
  assert.equal(api.calls.otp.length, 0);
});

test('phone grants, resets, forged metadata and malformed inputs are refused before account lookup', async () => {
  for (const extra of [{ phone: '+15551234567' }, { password: 'secret' }, { resetPassword: true },
    { actor_admin_id: player.id }, { userId: player.id }, { app_metadata: { fieldrush_account_type: 'staff' } },
    { role: 'owner' }, { sendOtp: 'yes' }, { email: 'bad' }, { existingStaffProfileId: 'bad' }]) {
    const api = route();
    assert.equal((await api.post({ ...input, ...extra })).status, 400);
    assert.equal(api.calls.list.length, 0);
    assert.equal(api.calls.rpc.length, 0);
  }
});

test('concurrent invitation recovery never edits or promotes a player that wins the email race', async () => {
  for (const [winner, expected] of [[staffUser(), 200], [{ ...player, email }, 400]]) {
    const api = route({ users: [], create: (_args, setUsers) => {
      setUsers([winner]); return { data: { user: null }, error: { message: 'private duplicate diagnostic' } };
    } });
    const result = await api.post();
    assert.equal(result.status, expected);
    assert.deepEqual(api.users(), [winner]);
    assert.equal(result.body.accountCreated, expected === 200 ? false : undefined);
    if (expected === 400) assert.equal(api.calls.rpc.length, 0);
  }
});

test('revoked administrator authority and malformed grant acknowledgements never send email', async () => {
  for (const response of [
    { data: null, error: { code: '42501', message: 'private database diagnostic' } },
    { data: { staff: { profile_id: stableId, auth_user_id: 'wrong', email, role: 'referee', display_name: 'Staff', is_active: true } }, error: null },
    { data: { staff: { profile_id: 'wrong', auth_user_id: authId, email, role: 'referee', display_name: 'Staff', is_active: true } }, error: null },
  ]) {
    const api = route({ rpc: () => response });
    const result = await api.post({ ...input, existingStaffProfileId: stableId });
    assert.equal(result.status, 400);
    assert.doesNotMatch(result.body.error, /private/);
    assert.equal(api.calls.otp.length, 0);
    assert.deepEqual(api.users().find(user => user.id === player.id), player);
  }
});

test('delivery failures preserve an acknowledged grant and expose no provider diagnostics', async () => {
  for (const options of [{ otpError: { message: 'private email diagnostic' } }, { publicError: true }]) {
    const api = route(options);
    const result = await api.post();
    assert.equal(result.status, 200);
    assert.match(result.body.warning, /Staff access is ready, but the email code/);
    assert.doesNotMatch(result.body.warning, /private/);
    assert.equal(api.calls.rpc.length, 1);
  }
});

test('an incomplete directory scan or failed Auth create cannot grant staff access', async () => {
  const failed = route({ users: [], create: () => ({ data: { user: null }, error: { message: 'private' } }) });
  assert.equal((await failed.post()).status, 400);
  assert.equal(failed.calls.rpc.length, 0);
  const full = route({ list: () => ({ data: { users: Array(1000).fill({ email: 'other@example.test' }) }, error: null }) });
  assert.equal((await full.post()).status, 400);
  assert.equal(full.calls.list.length, 10);
  assert.equal(full.calls.create.length, 0);
});

test('staff directory distinguishes independent sign-ins from retained records awaiting setup', async () => {
  const api = route({ directoryRows: [
    { profile_id: stableId, auth_user_id: authId, email, display_name: 'Staff', phone: null, role: 'admin', is_active: true },
    { profile_id: player.id, auth_user_id: null, email: null, display_name: 'Retained Staff', phone: '+15551234567', role: 'referee', is_active: true },
  ] });
  const result = await api.GET({});
  assert.equal(result.status, 200);
  assert.equal(result.body.staff[0].setupRequired, false);
  assert.equal(result.body.staff[0].email, email);
  assert.equal(result.body.staff[0].phone, '');
  assert.equal(result.body.staff[1].setupRequired, true);
  assert.equal(result.body.staff[1].email, null);
  assert.equal('auth_user_id' in result.body.staff[0], false);
});
