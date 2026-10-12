// Isolated PostgreSQL behavior checks; never connects to any hosted project.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_game_schedules.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const admin = '10000000-0000-0000-0000-000000000001';
const nonAdmin = '10000000-0000-0000-0000-000000000002';
const inactiveAdmin = '10000000-0000-0000-0000-000000000003';
const legacy = '20000000-0000-0000-0000-000000000001';
const q = (value) => `'${String(value).replaceAll("'", "''")}'`;
const json = (value) => `${q(JSON.stringify(value))}::jsonb`;
async function source(file) { return readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8'); }
function extractFn(sql, name) {
  const start = sql.indexOf(`create or replace function public.${name}(`);
  assert(start >= 0, name);
  return sql.slice(start, sql.indexOf('\n$$;', start) + 4);
}
await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema fieldrush_private; revoke all on schema fieldrush_private from public;
create schema cron;
create table cron.job(jobname text,schedule text,command text);
create function cron.schedule(text,text,text) returns bigint language plpgsql as $$
begin insert into cron.job values($1,$2,$3); return 1; end$$;
create table public.referee_profiles(profile_id uuid primary key,role text,is_active boolean);
insert into referee_profiles values('${admin}','admin',true),('${nonAdmin}','referee',true),('${inactiveAdmin}','admin',false);
create function public.is_active_moderation_admin(uuid) returns boolean language sql as $$
select exists(select 1 from referee_profiles where profile_id=$1 and role='admin' and is_active)$$;
create function public.set_updated_at() returns trigger language plpgsql as $$begin new.updated_at=now();return new;end$$;
create table public.admin_audit_events(actor_referee_id uuid not null references referee_profiles(profile_id),action text,
entity_type text check(entity_type in ('ACTION','SOLO_MATCH')),entity_id uuid not null,reason text,before_state jsonb,after_state jsonb);
create table public.open_queue_games(id uuid primary key default gen_random_uuid(),status text not null default 'OPEN',venue text not null,
starts_at timestamptz not null,ends_at timestamptz not null,timezone text not null default 'America/Phoenix',
price_fils integer not null default 13000,age_label text not null default '18+',created_by uuid,
format_version text not null default 'FIELDRUSH_7V7',currency text not null default 'USD',
capacity integer not null default 14,goalkeeper_capacity integer not null default 2,defender_capacity integer not null default 6,
midfielder_capacity integer not null default 0,attacker_capacity integer not null default 6,teams_assigned_at timestamptz,
constraint open_queue_games_versioned_format_check check (
  (format_version='LEGACY_6V6' and currency='BHD' and timezone='Asia/Bahrain' and capacity=12)
  or (format_version='FIELDRUSH_7V7' and currency='USD' and timezone='America/Phoenix' and capacity=14 and price_fils%10=0)));
create unique index open_queue_games_one_active_start_idx on open_queue_games(starts_at) where status<>'CANCELLED';
create unique index open_queue_games_venue_start_unique_idx on open_queue_games(lower(venue),starts_at) where status<>'CANCELLED';
insert into open_queue_games(id,venue,starts_at,ends_at,format_version,currency,timezone,capacity)
values('${legacy}','Historical pitch','2025-10-03T17:30Z','2025-10-03T18:30Z','LEGACY_6V6','BHD','Asia/Bahrain',12);
`);
const phoenix = await source('20261010000000_fieldrush_phoenix_game_format.sql');
await db.exec(extractFn(phoenix, 'enforce_open_queue_permanent_schedule'));
await db.exec(`create trigger enforce_open_queue_permanent_schedule before insert or update of status,starts_at,ends_at,timezone
on open_queue_games for each row execute function enforce_open_queue_permanent_schedule();`);
await db.exec(extractFn(await source('20260713000007_create_open_queue_player_sr_system.sql'), 'referee_start_open_queue_game'));
await db.exec(await source('20261011000100_saved_fields_and_game_locations.sql'));
const migration = await source('20261011000200_configurable_solo_schedules.sql');
await db.exec(migration);
let checks = 0;
async function value(sql) { return Object.values((await db.query(sql)).rows[0])[0]; }
async function check(sql, expected = true) { assert.deepEqual(await value(sql), expected, sql); checks++; }
async function rejects(sql, message) { await assert.rejects(db.exec(sql), message); checks++; }
async function saveField(name) { return (await value(`select admin_save_field('${admin}',null,${json({name,address:`123 ${name} Road`,latitude:33.45,longitude:-112.08})})`)).id; }
const field = await saveField('Pitch One');
const field2 = await saveField('Pitch Two');
const field3 = await saveField('Pitch Three');
const today = await value(`select (now() at time zone 'America/Phoenix')::date::text`);
async function datePlus(days) { return value(`select (${q(today)}::date+${days})::text`); }
const tomorrow = await datePlus(1);
const after = await datePlus(2);
const allDays = [1,2,3,4,5,6,7];
const details = {name:'Everyday football',field_id:field,weekdays:allDays,kickoff_time:'18:00',starts_on:tomorrow,booking_window_days:7};
async function save(values, id = null, actor = admin) { return value(`select admin_save_game_schedule(${q(actor)},${id?q(id):'null'},${json(values)})`); }
async function generate(id) { return value(`select admin_generate_game_schedule('${admin}',${q(id)})`); }
const createGame = (pitch, timestamp, minutes=60, actor=admin) => `select admin_create_open_queue_game(${q(actor)},${q(pitch)}::uuid,${q(timestamp)}::timestamptz,13000,'18+',${minutes})`;

await check(`select format_version='LEGACY_6V6' and currency='BHD' and field_id is null and starts_at='2025-10-03T17:30Z' from open_queue_games where id='${legacy}'`);
// One-off Saturday, all seven weekdays, whole-minute arbitrary kickoffs and duration.
const saturday = await value(`select min(d)::date::text from generate_series('2099-01-01'::date,'2099-01-07'::date,interval '1 day')d where extract(isodow from d)=6`);
const manual = await value(createGame(field, `${saturday}T15:17:00-07:00`, 90));
await check(`select ends_at=starts_at+interval '90 minutes' and capacity=14 and currency='USD' and location_address='123 Pitch One Road' from open_queue_games where id=${q(manual)}`);
for (let day = 0; day < 7; day++) {
  const date = await value(`select ('2098-06-01'::date+${day})::text`);
  await db.exec(createGame(field, `${date}T11:07:00-07:00`,30)); checks++;
}
await db.exec(createGame(field2, `${saturday}T15:17:00-07:00`,180)); checks++;
await rejects(createGame(field, `${saturday}T16:00:00-07:00`,60), /overlapping/);
await rejects(createGame(field, `${saturday}T14:30:00-07:00`,60), /overlapping/);
await rejects(createGame(field, `${saturday}T14:00:00-07:00`,180), /overlapping/);
await db.exec(createGame(field, `${saturday}T16:47:00-07:00`,60)); checks++;
const sunday = await value(`select (${q(saturday)}::date+1)::text`);
await db.exec(createGame(field, `${saturday}T23:30:00-07:00`,90)); checks++;
await rejects(createGame(field, `${sunday}T00:15:00-07:00`,60), /overlapping/);
await db.exec(createGame(field, `${sunday}T01:00:00-07:00`,60)); checks++;
for (const duration of [29,181,'null']) await rejects(createGame(field3, `${saturday}T18:00:00-07:00`,duration), /Duration/);
await rejects(createGame(field3, `${saturday}T18:00:01-07:00`), /whole-minute/);
await rejects(createGame(field3,'2020-01-01T01:00Z'), /future/);
await rejects(createGame(field3, `${saturday}T18:00:00-07:00`,60,nonAdmin), /Admin referee/);
await rejects(`update open_queue_games set starts_at=starts_at+interval '1 day',ends_at=ends_at+interval '1 day' where id=${q(manual)}`, /cannot be changed/);
await rejects(`update open_queue_games set ends_at=ends_at+interval '1 minute' where id=${q(manual)}`, /cannot be changed/);
await rejects(`update open_queue_games set field_id='${field2}' where id=${q(manual)}`, /location cannot be changed/);
await db.exec(`update open_queue_games set status='CANCELLED' where id=${q(manual)}`);
await db.exec(createGame(field, `${saturday}T15:17:00-07:00`,90)); checks++;
await rejects(`update open_queue_games set status='OPEN' where id=${q(manual)}`, /overlapping/);
await rejects(`insert into open_queue_games(venue,starts_at,ends_at,format_version,currency,timezone,capacity)
values('Bad legacy','2099-01-03T13:00Z','2099-01-03T14:00Z','LEGACY_6V6','BHD','Asia/Bahrain',12)`, /Solo games run Tuesday or Friday/);
await db.exec(`select admin_create_open_queue_game('${admin}','${field3}'::uuid,'2099-02-07T12:22Z',13000,'18+')`);
await check(`select ends_at=starts_at+interval '60 minutes' from open_queue_games where starts_at='2099-02-07T12:22Z'`);

for (const actor of [nonAdmin,inactiveAdmin]) await rejects(`select admin_save_game_schedule('${actor}',null,${json(details)})`, /Admin referee/);
await rejects(`select admin_save_game_schedule(null,null,${json(details)})`, /Admin referee/);
await rejects(`select admin_save_game_schedule('${admin}',null,'{}')`, /Invalid schedule/);
await rejects(`select admin_save_game_schedule('${admin}',null,'[]')`, /Invalid schedule/);
const invalids = [
  {name:''},{name:3},{field_id:null},{field_id:field,is_active:'true'},
  {weekdays:[]},{weekdays:[0]},{weekdays:[8]},{weekdays:[1,1]},{weekdays:['1']},{weekdays:[1,null]},{weekdays:'Saturday'},
  {kickoff_time:'25:00'},{kickoff_time:'18:00:30'},{kickoff_time:'12:30 AM'},
  {duration_minutes:29},{duration_minutes:181},{duration_minutes:'60'},{duration_minutes:60.5},
  {booking_window_days:6},{booking_window_days:85},{price_fils:13001},{price_fils:100010},
  {starts_on:'infinity'},{starts_on:'2026-02-30'},{ends_on:'2020-01-01'},
  {ends_on:15},{timezone:'Europe/London'},{created_by:nonAdmin},
];
for (const invalid of invalids) {
  await assert.rejects(save({...details,...invalid})); checks++;
}
const s = await save(details);
await check(`select duration_minutes=60 and price_fils=13000 and age_label='18+' and timezone='America/Phoenix' from game_schedules where id=${q(s.id)}`);
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(s.id)} and status='CREATED'`,6);
await check(`select count(*)::integer from game_schedule_occurrences o join open_queue_games g on g.id=o.game_id
where schedule_id=${q(s.id)} and g.starts_at=(o.match_date+time '18:00') at time zone 'America/Phoenix'
and g.ends_at=g.starts_at+interval '60 minutes' and g.currency='USD' and g.capacity=14`,6);
assert.deepEqual(await generate(s.id),{created:0,conflicts:0,skipped:0}); checks++;
const original = await value(`select jsonb_agg(to_jsonb(g) order by g.id) from game_schedule_occurrences o join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(s.id)}`);
await save({name:'Saturday changes',field_id:field2,weekdays:[6],kickoff_time:'09:30',duration_minutes:90,price_fils:15000},s.id);
assert.deepEqual(await value(`select jsonb_agg(to_jsonb(g) order by g.id) from game_schedule_occurrences o join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(s.id)}`),original); checks++;
await save({is_active:false},s.id);
await check(`select count(*)::integer from admin_audit_events where action='GAME_SCHEDULE_PAUSED' and entity_id=${q(s.id)}`,1);
assert.deepEqual(await generate(s.id),{created:0,conflicts:0,skipped:0}); checks++;
// No generated game is moved/cancelled by pause or changes. Delete/cancelled
// occurrence tombstones survive even after returning to the original rule.
const occurrences = (await db.query(`select game_id,match_date::text from game_schedule_occurrences where schedule_id=${q(s.id)} order by match_date`)).rows;
await db.exec(`update open_queue_games set status='CANCELLED' where id=${q(occurrences[0].game_id)};
delete from open_queue_games where id=${q(occurrences[1].game_id)};`);
await save({...details,is_active:true},s.id);
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(s.id)} and status='CREATED'`,6);
await check(`select game_id is null and status='CREATED' from game_schedule_occurrences where schedule_id=${q(s.id)} and match_date=${q(occurrences[1].match_date)}`);
await check(`select status='CANCELLED' from open_queue_games where id=${q(occurrences[0].game_id)}`);
await rejects(`select admin_set_game_schedule_skip('${admin}',${q(s.id)},${q(occurrences[2].match_date)},'Holiday closure',true)`, /Cancel it from its game page first/);
await db.exec(`select admin_set_game_schedule_skip('${admin}',${q(s.id)},${q(occurrences[0].match_date)},'Cancelled by admin',true);
select admin_set_game_schedule_skip('${admin}',${q(s.id)},${q(occurrences[0].match_date)},'Clear skipped date',false);`);
await check(`select status='CANCELLED' from open_queue_games where id=${q(occurrences[0].game_id)}`);

// Paused creation lets an admin add holidays before publishing any games.
const paused = await save({...details,name:'Holiday games',field_id:field2,is_active:false});
await db.exec(`select admin_set_game_schedule_skip('${admin}',${q(paused.id)},${q(tomorrow)},'Field closed for holiday',true)`);
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(paused.id)}`,0);
await save({is_active:true},paused.id);
await check(`select status='SKIPPED' and game_id is null from game_schedule_occurrences where schedule_id=${q(paused.id)} and match_date=${q(tomorrow)}`);
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(paused.id)} and status='CREATED'`,5);
await db.exec(`select admin_set_game_schedule_skip('${admin}',${q(paused.id)},${q(tomorrow)},'Field reopened for bookings',false)`);
await check(`select status='CREATED' and game_id is not null from game_schedule_occurrences where schedule_id=${q(paused.id)} and match_date=${q(tomorrow)}`);
await rejects(`select admin_set_game_schedule_skip('${nonAdmin}',${q(paused.id)},${q(tomorrow)},'Unauthorized request',true)`, /Admin referee/);
await rejects(`select admin_generate_game_schedule('${nonAdmin}',${q(paused.id)})`, /Admin referee/);
await rejects(`select admin_set_game_schedule_skip('${admin}',${q(paused.id)},'2020-01-01','Old date',true)`, /current or future/);
await rejects(`select admin_set_game_schedule_skip('${admin}',${q(paused.id)},${q(tomorrow)},'',true)`, /reason/);

// Conflicts persist visibly, retry on a later run, never create duplicates.
const conflict = await save({...details,name:'Conflicting schedule',field_id:field2,kickoff_time:'18:30'});
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(conflict.id)} and status='CONFLICT' and error_message like '%overlapping%'`,6);
const blockedGame = await value(`select game_id from game_schedule_occurrences where schedule_id=${q(paused.id)} and match_date=${q(tomorrow)}`);
await db.exec(`update open_queue_games set status='CANCELLED' where id=${q(blockedGame)}`);
assert.deepEqual(await generate(conflict.id),{created:1,conflicts:5,skipped:0}); checks++;
await check(`select status='CREATED' and error_message is null from game_schedule_occurrences where schedule_id=${q(conflict.id)} and match_date=${q(tomorrow)}`);
assert.deepEqual(await generate(conflict.id),{created:0,conflicts:5,skipped:0}); checks++;
const retainedCreated = await value(`select game_id from game_schedule_occurrences where schedule_id=${q(conflict.id)} and status='CREATED'`);
const tomorrowWeekday = await value(`select extract(isodow from ${q(tomorrow)}::date)::integer`);
await save({weekdays:[tomorrowWeekday]},conflict.id);
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(conflict.id)} and status='CONFLICT'`,0);
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(conflict.id)}`,1);
await check(`select game_id=${q(retainedCreated)} and status='CREATED' from game_schedule_occurrences where schedule_id=${q(conflict.id)} and match_date=${q(tomorrow)}`);
// Archived fields stop NEW games, without removing previously published ones.
const inactive = await save({...details,name:'Archived-field schedule',field_id:field3,is_active:false});
await db.exec(`select admin_save_field('${admin}','${field3}','{"is_active":false}')`);
await rejects(`select admin_save_game_schedule('${admin}',${q(inactive.id)},'{"is_active":true}')`, /active saved field/);
await save({name:'Still paused while field is archived'},inactive.id);
await db.exec(`update game_schedules set is_active=true where id=${q(inactive.id)}`); // simulate field archived after enabling.
assert.deepEqual(await generate(inactive.id),{created:0,conflicts:6,skipped:0}); checks++;
await check(`select bool_and(error_message like '%active saved field%') from game_schedule_occurrences where schedule_id=${q(inactive.id)}`);
await db.exec(`select admin_save_field('${admin}','${field3}','{"is_active":true}')`);
assert.deepEqual(await generate(inactive.id),{created:6,conflicts:0,skipped:0}); checks++;

// Explicit end date and distant starts respect a rolling window, not N days
// after the start date. Extending the window fills only unmaterialized dates.
const ended = await save({...details,name:'Short run',field_id:field3,kickoff_time:'10:00',ends_on:after});
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(ended.id)} and status='CREATED'`,2);
const futureDate = await datePlus(40);
const distant = await save({...details,name:'Future season',field_id:field3,kickoff_time:'10:00',starts_on:futureDate,booking_window_days:28});
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(distant.id)}`,0);
await save({booking_window_days:42},distant.id);
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(distant.id)} and status='CREATED'`,2);
await save({booking_window_days:41},distant.id);
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(distant.id)} and status='CREATED'`,2);
const futureSkip = await datePlus(50);
await db.exec(`select admin_set_game_schedule_skip('${admin}',${q(distant.id)},${q(futureSkip)},'Holiday in future',true)`);
await save({booking_window_days:52},distant.id);
await check(`select status='SKIPPED' from game_schedule_occurrences where schedule_id=${q(distant.id)} and match_date=${q(futureSkip)}`);
const saturdays = await save({...details,name:'Saturday mornings',field_id:field,kickoff_time:'07:00',weekdays:[6],booking_window_days:28});
await check(`select bool_and(extract(isodow from match_date)=6) and count(*) between 3 and 4 from game_schedule_occurrences where schedule_id=${q(saturdays.id)}`);
const nonSaturday = await value(`select min(d)::date::text from generate_series(${q(tomorrow)}::date,${q(after)}::date,interval '1 day')d where extract(isodow from d)<>6`);
await rejects(`select admin_set_game_schedule_skip('${admin}',${q(saturdays.id)},${q(nonSaturday)},'Not a scheduled day',true)`, /included in this schedule/);
const expired = await save({...details,name:'Finished schedule',field_id:field,starts_on:'2020-01-01',ends_on:'2020-12-31'});
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(expired.id)}`,0);

// Different pitches at one address/name are independent; labels are not locks.
await db.exec(`select admin_save_field('${admin}','${field2}',${json({name:'Pitch One'})})`);
const concurrent = await save({...details,name:'Same-name pitch',field_id:field2,kickoff_time:'08:00'});
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(concurrent.id)} and status='CREATED'`,6);
// Retired schedule author does not prevent the trusted cron keeping it current.
await db.exec(`update referee_profiles set is_active=false where profile_id='${admin}';
update game_schedules set booking_window_days=8 where id=${q(concurrent.id)};
select fieldrush_private.generate_due_game_schedules();
update referee_profiles set is_active=true where profile_id='${admin}';`);
await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(concurrent.id)} and status='CREATED'`,7);
await check(`select count(*)::integer from cron.job where jobname='fieldrush-game-schedule-generation' and schedule='7 * * * *'
and command='select fieldrush_private.generate_due_game_schedules();'`,1);
await check(`select position('least(10800, coalesce(duration_seconds_to_use, extract(epoch from (game_to_start.ends_at-game_to_start.starts_at))::integer, 3600))'
in pg_get_functiondef('public.referee_start_open_queue_game(uuid,uuid[],integer)'::regprocedure))>0`);
// Server-only authorization and direct-write lockdown, including inherited PUBLIC.
for (const table of ['game_schedules','game_schedule_skips','game_schedule_occurrences']) {
  await check(`select relrowsecurity from pg_class where oid='public.${table}'::regclass`);
  for (const role of ['anon','authenticated']) await check(`select not has_table_privilege('${role}','public.${table}','SELECT')
    and not has_table_privilege('${role}','public.${table}','INSERT')`);
  await check(`select has_table_privilege('service_role','public.${table}','SELECT') and not has_table_privilege('service_role','public.${table}','UPDATE')`);
}
for (const signature of ['admin_save_game_schedule(uuid,uuid,jsonb)','admin_generate_game_schedule(uuid,uuid)',
  'admin_set_game_schedule_skip(uuid,uuid,date,text,boolean)','admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer)',
  'admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text)']) {
  for (const role of ['anon','authenticated']) await check(`select not has_function_privilege('${role}','public.${signature}','EXECUTE')`);
  await check(`select has_function_privilege('service_role','public.${signature}','EXECUTE')`);
}
for (const signature of ['generate_game_schedule(uuid)','generate_due_game_schedules()']) {
  for (const role of ['anon','authenticated','service_role']) await check(`select not has_function_privilege('${role}','fieldrush_private.${signature}','EXECUTE')`);
}
assert.match(migration,/pg_advisory_xact_lock\(hashtextextended\('open-queue-field\|'/); checks++;
assert.match(migration,/select \* into s from public\.game_schedules where id=schedule_id_to_use for update/); checks++;
assert.match(migration,/select id from public\.game_schedules where is_active order by id for update skip locked/); checks++;
await check(`select position('order by id for update skip locked' in
  pg_get_functiondef('fieldrush_private.generate_due_game_schedules()'::regprocedure))>0`);
await check(`select count(*)>0 from admin_audit_events where action='GAME_SCHEDULE_DATE_SKIPPED'`);
await check(`select count(*)>0 from admin_audit_events where action='SOLO_GAME_SCHEDULED'`);
await db.close();
console.log(`${checks} isolated game-schedule PostgreSQL checks passed (not a full migration replay or concurrent-connection test).`);
