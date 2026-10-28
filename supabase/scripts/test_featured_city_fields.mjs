// Isolated behavioral/security checks; never connects to a hosted database.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const admin = '10000000-0000-0000-0000-000000000001';
const referee = '10000000-0000-0000-0000-000000000002';
const inactive = '10000000-0000-0000-0000-000000000003';
const first = '20000000-0000-0000-0000-000000000001';
const second = '20000000-0000-0000-0000-000000000002';
const other = '20000000-0000-0000-0000-000000000003';
const archived = '20000000-0000-0000-0000-000000000004';
const closed = '20000000-0000-0000-0000-000000000005';
await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema auth;
create function auth.uid() returns uuid language sql as $$
  select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
create table public.referee_profiles(profile_id uuid primary key,role text,is_active boolean);
insert into referee_profiles values('${admin}','admin',true),('${referee}','referee',true),('${inactive}','admin',false);
create function public.is_active_moderation_admin(uuid) returns boolean language sql as $$
  select exists(select 1 from referee_profiles where profile_id=$1 and role='admin' and is_active)
$$;
create table public.fieldrush_cities(id text primary key,active boolean not null default true);
insert into fieldrush_cities values('phoenix',true),('bahrain',true),('closed',false);
create table public.fields(id uuid primary key,name text,address text,city text,state text,country_code text,
  latitude double precision,longitude double precision,is_active boolean not null default true,
  market_city_id text not null references fieldrush_cities(id),created_by uuid,created_at timestamptz default now());
alter table public.fields enable row level security;
alter table public.fieldrush_cities enable row level security;
revoke all on public.fields,public.fieldrush_cities from public,anon,authenticated;
create table public.admin_audit_events(actor_referee_id uuid not null,action text,entity_type text,entity_id uuid,
  reason text,before_state jsonb,after_state jsonb);
insert into fields(id,name,address,city,state,country_code,latitude,longitude,market_city_id,created_by) values
  ('${first}','Diablo Field 07','48th St and Alameda Dr','Tempe','AZ','US',33.4,-111.9,'phoenix','${admin}'),
  ('${second}','Second field','123 Test Road','Phoenix','AZ','US',33.5,-112.0,'phoenix','${admin}'),
  ('${other}','Other city field','123 Other Road','Manama','Capital','BH',26.2,50.6,'bahrain','${admin}'),
  ('${archived}','Archived field','123 Old Road','Tempe','AZ','US',33.4,-111.8,'phoenix','${admin}'),
  ('${closed}','Closed city field','123 Closed Road','Test','AA','US',33.4,-111.8,'closed','${admin}');
update fields set is_active=false where id='${archived}';
`);
await db.exec(await readFile(new URL('../migrations/20261027000600_featured_city_fields.sql', import.meta.url), 'utf8'));
let checks = 0;
async function value(sql, expected) {
  const { rows } = await db.query(sql);
  assert.deepEqual(Object.values(rows[0])[0], expected, sql);
  checks++;
}
async function rejects(sql, message) { await assert.rejects(db.exec(sql), message); checks++; }
const feature = (field, city = 'phoenix', enabled = true, actor = admin) =>
  `select admin_set_featured_field('${actor}','${city}','${field}',${enabled})`;
await rejects(`select get_featured_field('phoenix')`, /sign in/);
await db.exec(`set request.jwt.claim.sub='${referee}'`);
await value(`select get_featured_field('phoenix')`, null);
await value(`select get_featured_field('missing')`, null);
await rejects(feature(first, 'phoenix', true, referee), /Admin referee/);
await rejects(feature(first, 'phoenix', true, inactive), /Admin referee/);
await rejects(`select admin_set_featured_field(null,'phoenix','${first}',true)`, /Admin referee/);
await rejects(feature('20000000-0000-0000-0000-000000000099'), /saved field/);
await rejects(feature(other), /another competition city/);
await rejects(feature(archived), /active field/);
await rejects(feature(closed, 'closed'), /active field/);
await rejects(`select admin_set_featured_field('${admin}','phoenix','${first}',null)`, /whether to feature/);
await value(`select count(*)::integer from admin_audit_events`, 0);
await db.exec(feature(first));
await value(`select get_featured_field('phoenix')`, {
  id: first, name: 'Diablo Field 07', address: '48th St and Alameda Dr', city: 'Tempe', state: 'AZ',
  country_code: 'US', latitude: 33.4, longitude: -111.9, market_city_id: 'phoenix',
});
await value(`select get_featured_field('bahrain')`, null);
await value(`select before_state->'featured_field_id'='null'::jsonb and after_state->>'featured_field_id'='${first}'
  and actor_referee_id='${admin}' from admin_audit_events where action='FEATURED_FIELD_CHANGED'`, true);
await db.exec(feature(first));
await value(`select count(*)::integer from admin_audit_events`, 1);
await db.exec(feature(second));
await value(`select get_featured_field('phoenix')->>'id'`, second);
await rejects(feature(first, 'phoenix', false), /featured field changed/);
await value(`select featured_field_id::text from fieldrush_cities where id='phoenix'`, second);
await db.exec(feature(other, 'bahrain'));
await value(`select get_featured_field('bahrain')->>'id'`, other);
await value(`select get_featured_field('phoenix')->>'id'`, second);
await db.exec(`update fields set is_active=false where id='${second}'`);
await value(`select get_featured_field('phoenix')`, null);
await db.exec(`update fields set is_active=true where id='${second}'; update fieldrush_cities set active=false where id='phoenix'`);
await value(`select get_featured_field('phoenix')`, null);
// Removing a feature remains possible after its city closes.
await db.exec(feature(second, 'phoenix', false));
await value(`select featured_field_id from fieldrush_cities where id='phoenix'`, null);
await db.exec(`update fieldrush_cities set active=true where id='phoenix'`);
await db.exec(feature(first));
// Even an out-of-band field move cannot leak the former city's featured field.
await db.exec(`update fields set market_city_id='bahrain' where id='${first}'`);
await value(`select get_featured_field('phoenix')`, null);
await db.exec(`update fields set market_city_id='phoenix' where id='${first}'`);
await value(`select get_featured_field('phoenix')->>'id'`, first);
await db.exec(`create function reject_feature_audit() returns trigger language plpgsql as $$begin
  raise exception 'audit unavailable'; end$$;
  create trigger reject_feature_audit before insert on admin_audit_events for each row execute function reject_feature_audit()`);
await rejects(feature(second), /audit unavailable/);
await value(`select featured_field_id::text from fieldrush_cities where id='phoenix'`, first);
await db.exec(`drop trigger reject_feature_audit on admin_audit_events`);
for (const role of ['anon', 'authenticated']) {
  await value(`select not has_table_privilege('${role}','public.fields','SELECT')
    and not has_table_privilege('${role}','public.fieldrush_cities','UPDATE')`, true);
  await value(`select not has_function_privilege('${role}','public.admin_set_featured_field(uuid,text,uuid,boolean)','EXECUTE')`, true);
}
await value(`select not has_function_privilege('anon','public.get_featured_field(text)','EXECUTE')`, true);
await value(`select has_function_privilege('authenticated','public.get_featured_field(text)','EXECUTE')`, true);
await value(`select has_function_privilege('service_role','public.admin_set_featured_field(uuid,text,uuid,boolean)','EXECUTE')`, true);
await db.exec(`set role authenticated`);
await value(`select get_featured_field('phoenix')->>'id'`, first);
await rejects(`select * from fields`, /permission denied/);
await rejects(feature(second), /permission denied/);
await db.exec(`reset role; set role anon`);
await rejects(`select get_featured_field('phoenix')`, /permission denied/);
await db.exec(`reset role`);
console.log(`${checks} isolated featured-city-field checks passed.`);
await db.close();
