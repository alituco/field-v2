import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const hosted = readFileSync(new URL('./verify-hosted-schema.sql', import.meta.url), 'utf8');
const rankings = readFileSync(new URL('../../supabase/migrations/20261014000300_fieldrush_city_and_role_rankings.sql', import.meta.url), 'utf8');
const privacy = readFileSync(new URL('../../supabase/migrations/20261014001500_lifetime_rating_visibility.sql', import.meta.url), 'utf8');
const mobile = readFileSync(new URL('../../mobile/lib/src/leaderboard/leaderboard_repository.dart', import.meta.url), 'utf8');

test('hosted staff schema rejects player-profile linkage and public provisioning authority', () => {
  assert.match(hosted, /conrelid='public\.referee_profiles'::regclass[\s\S]*confrelid='public\.profiles'::regclass/);
  assert.match(hosted, /column_name='auth_user_id'/);
  assert.match(hosted, /column_name='email'/);
  for (const signature of ['public.admin_grant_independent_staff(uuid,uuid,text,text,text,uuid)', 'public.bootstrap_independent_staff_admin(uuid,uuid,text)']) {
    assert.ok(hosted.includes(signature));
  }
  const guard = hosted.slice(hosted.indexOf("'public.admin_grant_independent_staff("));
  assert.match(guard, /has_function_privilege\('anon',checked_rpc,'EXECUTE'\)/);
  assert.match(guard, /has_function_privilege\('authenticated',checked_rpc,'EXECUTE'\)/);
  assert.match(guard, /not has_function_privilege\('service_role',checked_rpc,'EXECUTE'\)/);
});

test('hosted Ranks checks the RPC and named arguments used by the role-aware mobile client', () => {
  const checked = hosted.match(/ranks_function\s*:=\s*to_regprocedure\(\s*'public\.(\w+)\(([^']+)\)'\s*\)/);
  assert.ok(checked, 'Hosted verifier must check an exact Ranks signature');
  const [, name, types] = checked;
  assert.equal(name, 'list_fieldrush_rating_page');
  const definition = rankings.match(new RegExp(`create function public\\.${name}\\(([^)]+)\\)`));
  assert.ok(definition, 'Checked RPC must be supplied by the city/role migration');
  const parameters = definition[1].split(',').map(value => value.trim().split(/\s+/));
  assert.equal(types, parameters.map(([, type]) => type).join(','));
  const checkedArguments = hosted.match(/proargnames from pg_proc where oid = ranks_function\) is distinct from\s*array\[([^\]]+)\]/);
  assert.ok(checkedArguments, 'Hosted verifier must validate PostgREST named arguments');
  const names = [...checkedArguments[1].matchAll(/'([^']+)'/g)].map(match => match[1]);
  assert.deepEqual(names, parameters.map(([name]) => name));
  const request = mobile.match(new RegExp(`_client\\.rpc\\(\\s*'${name}',\\s*params: \\{([^}]+)\\}`));
  assert.ok(request, 'Current mobile client must call the checked RPC');
  const mobileNames = [...request[1].matchAll(/^\s*'([^']+)'\s*:/gm)].map(match => match[1]);
  assert.deepEqual(mobileNames, names);
});

test('hosted schema rejects public access to every single-pool API retired by rating privacy', () => {
  const retiredNames = privacy.match(/p\.proname in \(([^)]+)\) loop/);
  const checkedNames = hosted.match(/p\.proname in \(([^)]+)\)\s*loop/);
  assert.ok(retiredNames);
  assert.ok(checkedNames);
  const names = value => [...value.matchAll(/'([^']+)'/g)].map(match => match[1]).sort();
  assert.deepEqual(names(checkedNames[1]), names(retiredNames[1]));
  const guard = hosted.match(/for retired_rpc in([\s\S]+?)end loop;/)?.[1];
  assert.match(guard, /if has_function_privilege\('anon', retired_rpc, 'EXECUTE'\)\s*or has_function_privilege\('authenticated', retired_rpc, 'EXECUTE'\)\s*then\s*raise exception/);
});

test('hosted schema requires a writable party-context RPC without exposing its unmasked implementation', () => {
  const guard = hosted.match(/party_context := to_regprocedure\('public\.get_open_queue_party_context\(uuid\)'\);([\s\S]+?)if not exists/);
  assert.ok(guard, 'Hosted deployment must check the exact mobile party RPC');
  assert.match(guard[1], /provolatile from pg_proc where oid = party_context\) is distinct from 'v'::"char"/);
  assert.match(guard[1], /not \(select prosecdef from pg_proc where oid = party_context\)/);
  assert.match(guard[1], /has_function_privilege\('anon', party_context, 'EXECUTE'\)/);
  for (const role of ['authenticated', 'service_role']) {
    assert.ok(guard[1].includes(`not has_function_privilege('${role}', party_context, 'EXECUTE')`));
  }
  assert.match(guard[1], /get_open_queue_party_context_before_sr_privacy\(uuid\)/);
  for (const role of ['anon', 'authenticated', 'service_role']) {
    assert.ok(guard[1].includes(`or has_function_privilege('${role}', checked_rpc, 'EXECUTE')`));
  }
  assert.match(guard[1], /raise exception 'Hosted party context/);
  assert.match(guard[1], /raise exception 'Hosted unmasked party context/);
});
