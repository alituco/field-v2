// Isolated schema/behavior checks: never connects to a hosted project.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_saved_fields.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const admin = '10000000-0000-0000-0000-000000000001';
const nonAdmin = '10000000-0000-0000-0000-000000000002';
const legacy = '20000000-0000-0000-0000-000000000001';
await db.exec(`
create role anon; create role authenticated; create role service_role;
create table public.referee_profiles(profile_id uuid primary key,role text,is_active boolean);
insert into referee_profiles values('${admin}','admin',true),('${nonAdmin}','referee',true);
create function public.is_active_moderation_admin(uuid) returns boolean language sql as $$
select exists(select 1 from referee_profiles where profile_id=$1 and role='admin' and is_active)$$;
create function public.set_updated_at() returns trigger language plpgsql as $$begin new.updated_at=now();return new;end$$;
create table public.admin_audit_events(actor_referee_id uuid,action text,entity_type text,entity_id uuid,reason text,before_state jsonb,after_state jsonb);
create table public.open_queue_games(id uuid primary key default gen_random_uuid(),status text default 'OPEN',venue text not null,
starts_at timestamptz,ends_at timestamptz,timezone text default 'America/Phoenix',price_fils integer,age_label text,created_by uuid);
insert into open_queue_games(id,venue,starts_at,ends_at) values('${legacy}','Historical free-text venue','2025-10-01Z','2025-10-02Z');
`);
const migration = await readFile(new URL('../migrations/20261011000100_saved_fields_and_game_locations.sql', import.meta.url), 'utf8');
await db.exec(migration);
let checks = 0;
async function check(sql, expected = true) {
  const { rows } = await db.query(sql); assert.equal(Object.values(rows[0])[0], expected, sql); checks++;
}
async function rejects(sql, message) { await assert.rejects(db.exec(sql), message); checks++; }
const details = JSON.stringify({ name: 'Test field', address: '123 Test Avenue', latitude: 33.45, longitude: -112.08 });
await rejects(`select admin_save_field('${nonAdmin}',null,'${details}')`, /Admin referee/);
await rejects(`select admin_save_field(null,null,'${details}')`, /Admin referee/);
const result = await db.query(`select admin_save_field('${admin}',null,'${details}') as field`);
const field = result.rows[0].field.id;
await check(`select name='Test field' and city='Phoenix' and state='AZ' and country_code='US' and is_active from fields where id='${field}'`);
await check(`select count(*)::integer from admin_audit_events where action='FIELD_CREATED'`, 1);
await check(`select venue='Historical free-text venue' and field_id is null and location_latitude is null from open_queue_games where id='${legacy}'`);
for (const invalid of [{ latitude: 91 }, { longitude: -181 }, { latitude: 'NaN' }, { longitude: 'Infinity' }, { address: '' }, { latitude: null }, { created_by: nonAdmin }]) {
  await rejects(`select admin_save_field('${admin}','${field}','${JSON.stringify(invalid)}')`, /check constraint|not-null constraint|Invalid field details/);
}
await rejects(`select admin_create_open_queue_game('${admin}',null::uuid,'2099-10-24T03:30:00Z',13000,'18+')`, /saved field/);
await rejects(`select admin_create_open_queue_game('${nonAdmin}','${field}'::uuid,'2099-10-24T03:30:00Z',13000,'18+')`, /Admin referee/);
await rejects(`select admin_create_open_queue_game('${admin}','30000000-0000-0000-0000-000000000099'::uuid,'2099-10-24T03:30:00Z',13000,'18+')`, /active saved field/);
await rejects(`select admin_create_open_queue_game('${admin}','Free text'::text,'2099-10-24T03:30:00Z',13000,'18+')`, /saved field/);
await rejects(`select admin_create_open_queue_game('${admin}','${field}'::uuid,'2099-10-24T03:30:00Z',13001,'18+')`, /whole cents/);
const created = await db.query(`select admin_create_open_queue_game('${admin}','${field}'::uuid,'2099-10-24T03:30:00Z',13000,'18+') as id`);
const game = created.rows[0].id;
await check(`select field_id='${field}' and venue='Test field' and location_address='123 Test Avenue'
 and location_city='Phoenix' and location_state='AZ' and location_country_code='US' and location_latitude=33.45
 and location_longitude=-112.08 and price_fils=13000 and ends_at=starts_at+interval '1 hour' from open_queue_games where id='${game}'`);
await check(`select after_state->>'field_id'='${field}' and after_state->>'location_address'='123 Test Avenue'
 from admin_audit_events where action='SOLO_GAME_CREATED' and entity_id='${game}'`);
await rejects(`update open_queue_games set location_latitude=20 where id='${game}'`, /cannot be changed/);
await rejects(`update open_queue_games set field_id=null where id='${game}'`, /cannot be changed/);
await rejects(`update open_queue_games set venue='Forged name' where id='${game}'`, /cannot be changed/);
await db.exec(`insert into open_queue_games(field_id,venue,location_latitude,location_longitude,starts_at)
 values('${field}','Forged snapshot',0,0,'2099-10-25T03:30:00Z')`);
await check(`select venue='Test field' and location_latitude=33.45 and location_longitude=-112.08
 from open_queue_games where starts_at='2099-10-25T03:30:00Z'`);
await db.exec(`select admin_save_field('${admin}','${field}','{"name":"Renamed pitch","address":"456 Future Street","latitude":33.5}')`);
await check(`select venue='Test field' and location_address='123 Test Avenue' and location_latitude=33.45 from open_queue_games where id='${game}'`);
await rejects(`select admin_create_open_queue_game('${admin}','${field}'::uuid,'2099-10-24T03:30:00Z',13000,'18+')`, /unique constraint/);
await db.exec(`select admin_save_field('${admin}','${field}','{"is_active":false}')`);
await rejects(`select admin_create_open_queue_game('${admin}','${field}'::uuid,'2099-10-30T03:30:00Z',13000,'18+')`, /active saved field/);
await db.exec(`update open_queue_games set status='CANCELLED' where id='${game}'`);
await check(`select location_latitude=33.45 and venue='Test field' from open_queue_games where id='${game}'`);
await db.exec(`select admin_save_field('${admin}','${field}','{"is_active":true}')`);
await db.exec(`select admin_create_open_queue_game('${admin}','${field}'::uuid,'2099-10-30T03:30:00Z',13000,'18+')`);
await check(`select venue='Renamed pitch' and location_address='456 Future Street' and location_latitude=33.5
 from open_queue_games where starts_at='2099-10-30T03:30:00Z'`);
await rejects(`delete from fields where id='${field}'`, /foreign key constraint/);
await rejects(`insert into open_queue_games(venue,location_latitude,location_longitude) values('No field',1,2)`, /saved field/);
await db.exec(`insert into open_queue_games(venue,starts_at) values('Synthetic test helper','2099-11-01T03:30:00Z')`);
await check(`select field_id is null and location_latitude is null from open_queue_games where venue='Synthetic test helper'`);
await check(`select relrowsecurity from pg_class where oid='public.fields'::regclass`);
for (const role of ['anon', 'authenticated']) {
  await check(`select not has_table_privilege('${role}','public.fields','SELECT') and not has_table_privilege('${role}','public.fields','INSERT')`);
  await check(`select not has_function_privilege('${role}','public.admin_save_field(uuid,uuid,jsonb)','EXECUTE')`);
  await check(`select not has_function_privilege('${role}','public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text)','EXECUTE')`);
}
await check(`select has_column_privilege('authenticated','public.open_queue_games','location_latitude','SELECT')`);
await check(`select has_function_privilege('service_role','public.admin_save_field(uuid,uuid,jsonb)','EXECUTE')`);
await check(`select has_function_privilege('service_role','public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text)','EXECUTE')`);
assert.match(migration, /select \* into saved_field from public\.fields where id = new\.field_id for share/i);
checks++;
console.log(`${checks} isolated saved-fields checks passed.`);
await db.close();
