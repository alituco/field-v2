// Isolated PostgreSQL behavior: no hosted connection and no Auth API calls.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const actor = '15000300-0000-4000-8000-000000000001';
const player = '15000300-0000-4000-8000-000000000002';
const fresh = '15000300-0000-4000-8000-000000000003';
const failed = '15000300-0000-4000-8000-000000000004';
const playerPhone = '+15551500002';
await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create schema auth; create schema fieldrush_private;
  create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$;
  create table auth.users(id uuid primary key,phone text,deleted_at timestamptz,banned_until timestamptz,
    encrypted_password text,raw_user_meta_data jsonb,phone_confirmed_at timestamptz);
  create table auth.identities(id uuid primary key,user_id uuid,provider text,identity_data jsonb);
  create table public.profiles(id uuid primary key,auth_user_id uuid,display_name text,phone text,
    username text,bio text,avatar_url text,date_of_birth date,account_deleted_at timestamptz);
  create table fieldrush_private.accounts(user_id uuid primary key,status text,first_name text,last_name text,
    email text,date_of_birth date);
  create table public.referee_profiles(profile_id uuid primary key references profiles(id),display_name text,
    phone text unique,role text,is_active boolean,created_at timestamptz default now(),updated_at timestamptz default now());
  create table public.admin_audit_events(actor_referee_id uuid,action text,entity_type text,entity_id uuid,
    reason text,before_state jsonb,after_state jsonb);
  insert into auth.users values
    ('${actor}','15551500001',null,null,gen_random_uuid()::text,'{}',now()),
    ('${player}','15551500002',null,null,gen_random_uuid()::text,'{"name":"Original Player","preserve":true}',now()),
    ('${fresh}','15551500003',null,null,null,'{}',null),
    ('${failed}','15551500004',null,null,null,'{}',null);
  insert into auth.identities values
    (gen_random_uuid(),'${player}','phone','{"phone":"15551500002"}'),
    (gen_random_uuid(),'${player}','google','{"email":"player@example.test","email_verified":true}');
  insert into profiles values
    ('${actor}','${actor}','Admin Actor','+15551500001','admin_actor','','',null,null),
    ('${player}','${player}','Original P.','${playerPhone}','original_player','Keep my bio','keep-avatar','2000-01-01',null);
  insert into fieldrush_private.accounts values('${player}','active','Original','Player','private@example.test','2000-01-01');
  insert into referee_profiles(profile_id,display_name,phone,role,is_active)
    values('${actor}','Admin Actor','+15551500001','admin',true);
  select set_config('request.jwt.claim.role','service_role',false);
`);
const migration = await readFile(new URL('../migrations/20261015000300_safe_fieldrush_staff_provisioning.sql', import.meta.url), 'utf8');
await db.exec(migration);
let checks = 0;
const sql = value => `'${String(value).replaceAll("'", "''")}'`;
const grant = (id = player, phone = playerPhone, role = 'referee', by = actor) =>
  `select public.admin_grant_fieldrush_staff(${sql(by)},${sql(id)},${sql(phone)},'Staff Display',${sql(role)}) as result`;
async function rows(statement) { return (await db.query(statement)).rows; }
async function check(statement, expected = true) {
  assert.equal(Object.values((await rows(statement))[0])[0], expected, statement); checks++;
}
async function rejects(statement, pattern) { await assert.rejects(db.exec(statement), pattern); checks++; }
async function identitySnapshot() {
  return rows(`select (select to_jsonb(u) from auth.users u where id='${player}') as auth,
    (select jsonb_agg(to_jsonb(i) order by id) from auth.identities i where user_id='${player}') as identities,
    (select to_jsonb(p) from public.profiles p where id='${player}') as profile,
    (select to_jsonb(a) from fieldrush_private.accounts a where user_id='${player}') as private_account`);
}
const before = await identitySnapshot();
await db.exec(grant());
assert.deepEqual(await identitySnapshot(), before); checks++;
await check(`select role='referee' and is_active and display_name='Staff Display' from referee_profiles where profile_id='${player}'`);
await check(`select count(*)::integer from admin_audit_events where action='STAFF_ACCESS_GRANTED'`, 1);
await check(`select not (after_state ? 'phone') and not (after_state ? 'display_name') from admin_audit_events where entity_id='${player}'`);
await check(`select (public.admin_grant_fieldrush_staff('${actor}','${player}','${playerPhone}','Different Staff Label','referee')->>'already_active')::boolean`);
await check(`select display_name='Staff Display' from referee_profiles where profile_id='${player}'`);
await check(`select count(*)::integer from admin_audit_events`, 1);
await rejects(grant(player, playerPhone, 'admin'), /separate audited flow/);
await rejects(grant(actor, '+15551500001', 'referee'), /separate audited flow/);
await rejects(grant(player, '+15551509999'), /exact phone account changed/);
await rejects(grant(player, playerPhone, 'owner'), /valid access level/);
await db.exec(`update referee_profiles set is_active=false where profile_id='${actor}'`);
await rejects(grant(), /Active administrator/);
await db.exec(`update referee_profiles set is_active=true where profile_id='${actor}';
  update fieldrush_private.accounts set status='deletion_pending' where user_id='${player}'`);
await rejects(grant(), /pending deletion/);
await db.exec(`update fieldrush_private.accounts set status='active' where user_id='${player}';
  update referee_profiles set is_active=false where profile_id='${player}'`);
await db.exec(grant());
await check(`select is_active from referee_profiles where profile_id='${player}'`);
await check(`select count(*)::integer from admin_audit_events where action='STAFF_REACTIVATED'`, 1);
assert.deepEqual(await identitySnapshot(), before); checks++;

await db.exec(grant(fresh, '+15551500003'));
await check(`select display_name='Staff Display' and username is null and auth_user_id='${fresh}' from profiles where id='${fresh}'`);
await check(`select phone_confirmed_at is null and encrypted_password is null from auth.users where id='${fresh}'`);
await db.exec(`create function public.reject_test_staff_audit() returns trigger language plpgsql as $$begin
  if new.entity_id='${failed}' then raise exception 'fixture audit failure'; end if; return new; end$$;
  create trigger reject_test_staff_audit before insert on public.admin_audit_events
  for each row execute function public.reject_test_staff_audit()`);
await rejects(grant(failed, '+15551500004'), /fixture audit failure/);
await check(`select not exists(select 1 from referee_profiles where profile_id='${failed}')
  and not exists(select 1 from profiles where id='${failed}')`);
for (const role of ['anon', 'authenticated']) {
  await check(`select not has_function_privilege('${role}','public.admin_grant_fieldrush_staff(uuid,uuid,text,text,text)','EXECUTE')`);
}
await check(`select has_function_privilege('service_role','public.admin_grant_fieldrush_staff(uuid,uuid,text,text,text)','EXECUTE')`);
await db.exec(`select set_config('request.jwt.claim.role','authenticated',false)`);
await rejects(grant(), /staff administration service/);
assert.match(migration, /pg_advisory_xact_lock\(hashtextextended\('fieldrush-staff-offboarding',0\)\)/); checks++;
assert.doesNotMatch(migration, /update auth\.(?:users|identities)|delete from auth\.(?:users|identities)/i); checks++;
console.log(`${checks} isolated safe staff provisioning checks passed.`);
await db.close();
