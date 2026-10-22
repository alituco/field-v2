// Isolated PostgreSQL/PGlite regression; no hosted database, bookings or payment.
// PGLITE_MODULE=/path/to/@electric-sql/pglite node supabase/scripts/test_solo_schedule_timezone_validation.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const source = file => readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8');
const q = value => `'${String(value).replaceAll("'", "''")}'`;
let checks = 0;
async function value(sql) { return Object.values((await db.query(sql)).rows[0])[0]; }
async function check(sql, expected = true) {
  assert.deepEqual(await value(sql), expected, sql);
  checks++;
}
async function rejects(sql, pattern) {
  await assert.rejects(db.exec(sql), pattern);
  checks++;
}

try {
  await db.exec(`
    create table public.open_queue_games(
      id uuid primary key default gen_random_uuid(), status text not null default 'OPEN',
      starts_at timestamptz not null, ends_at timestamptz not null,
      timezone text not null default 'America/Phoenix',
      format_version text not null default 'FIELDRUSH_7V7', field_id uuid);
  `);
  // Load the real schedule function and the exact subsequent city-catalogue
  // transformation, then apply this migration. No application guard is stubbed.
  const schedule = await source('20261011000200_configurable_solo_schedules.sql');
  const start = schedule.indexOf('create or replace function public.enforce_open_queue_permanent_schedule()');
  assert(start >= 0);
  const end = schedule.indexOf('\n$$;', start);
  assert(end > start);
  let original = schedule.slice(start, end + 4);
  const city = await source('20261014000100_fieldrush_city_catalog.sql');
  const oldTimezone = "if new.timezone is distinct from 'America/Phoenix' then raise exception 'Fieldrush games must use America/Phoenix time.'; end if;";
  const currentTimezone = "if not exists(select 1 from pg_timezone_names where name=new.timezone) then raise exception 'Choose a valid game timezone.'; end if;";
  assert(city.includes(oldTimezone.replaceAll("'", "''")));
  assert(city.includes(currentTimezone.replaceAll("'", "''")));
  assert(original.includes(oldTimezone));
  original = original.replace(oldTimezone, currentTimezone);
  await db.exec(original);
  await db.exec(await source('20261022000100_bound_solo_schedule_timezone_validation.sql'));
  await db.exec(`create trigger enforce_schedule before insert or update of status,starts_at,ends_at,timezone,field_id
    on public.open_queue_games for each row execute function public.enforce_open_queue_permanent_schedule()`);

  const installed = await value("select pg_get_functiondef('public.enforce_open_queue_permanent_schedule()'::regprocedure)");
  assert.match(installed, /if tg_op='INSERT' or new\.timezone is distinct from old\.timezone then\s+if not exists\(select 1 from pg_timezone_names/);
  checks++;

  const kickoff = '2026-12-01 20:30:00-07';
  const first = await value(`insert into open_queue_games(starts_at,ends_at)
    values(${q(kickoff)},${q(kickoff)}::timestamptz+interval '1 hour') returning id`);
  await check(`select timezone='America/Phoenix' and status='OPEN' from open_queue_games where id=${q(first)}`);
  await rejects(`insert into open_queue_games(starts_at,ends_at,timezone)
    values('2026-12-02 20:30-07','2026-12-02 21:30-07','Invalid/Timezone')`, /time zone|valid game timezone/);
  await rejects(`update open_queue_games set timezone='Invalid/Timezone' where id=${q(first)}`, /time zone|valid game timezone/);
  await rejects(`insert into open_queue_games(starts_at,ends_at)
    values('2026-12-02 20:30-07','2026-12-02 20:59-07')`, /between 30 and 180 whole minutes/);
  await rejects(`insert into open_queue_games(starts_at,ends_at)
    values('2026-12-02 20:30:01-07','2026-12-02 21:30:01-07')`, /whole-minute kickoff/);
  await rejects(`update open_queue_games set starts_at=starts_at+interval '1 minute',ends_at=ends_at+interval '1 minute'
    where id=${q(first)}`, /scheduled game time or duration cannot be changed/);
  await rejects(`insert into open_queue_games(starts_at,ends_at)
    values(${q(kickoff)},${q(kickoff)}::timestamptz+interval '1 hour')`, /already exists at that start time/);

  // Deterministic catalogue instrumentation: the production function body is
  // unchanged. An explicit, isolated search_path makes its unqualified view
  // resolve to this counting/failing fixture instead of the real catalogue.
  // Timing thresholds cannot reliably prove a catalogue scan was skipped.
  await db.exec(`
    create sequence public.timezone_catalogue_scans;
    create function public.probe_timezone(name text) returns text language plpgsql volatile as $$
    begin
      if current_setting('test.catalogue_disabled',true)='true' then
        raise exception 'Timezone catalogue was scanned';
      end if;
      perform nextval('public.timezone_catalogue_scans');
      return name;
    end $$;
    create view public.pg_timezone_names as
      select public.probe_timezone(name) as name
      from (values('America/Phoenix'::text),('Europe/London'::text)) zones(name);
    alter function public.enforce_open_queue_permanent_schedule() set search_path=public,pg_catalog,pg_temp;
    select set_config('test.catalogue_disabled','true',false);
  `);
  for (const status of ['FULL', 'OPEN', 'FULL']) {
    await db.exec(`update open_queue_games set status=${q(status)},timezone=timezone where id=${q(first)}`);
    await check(`select status=${q(status)} from open_queue_games where id=${q(first)}`);
  }
  await check('select is_called from timezone_catalogue_scans', false);
  await rejects(`insert into open_queue_games(starts_at,ends_at)
    values('2026-12-03 20:30-07','2026-12-03 21:30-07')`, /Timezone catalogue was scanned/);
  await rejects(`update open_queue_games set timezone='Europe/London' where id=${q(first)}`, /Timezone catalogue was scanned/);
  await db.exec("select set_config('test.catalogue_disabled','false',false)");
  await db.exec(`update open_queue_games set timezone='Europe/London' where id=${q(first)}`);
  await check('select is_called from timezone_catalogue_scans');
  await check(`select timezone='Europe/London' from open_queue_games where id=${q(first)}`);
  // UTC is recognized by PostgreSQL's AT TIME ZONE but is intentionally absent
  // from the fixture catalogue: prove the catalogue check still rejects it.
  await rejects(`update open_queue_games set timezone='UTC' where id=${q(first)}`, /Choose a valid game timezone/);
  await rejects(`insert into open_queue_games(starts_at,ends_at,timezone)
    values('2026-12-03 20:30-07','2026-12-03 21:30-07','UTC')`, /Choose a valid game timezone/);

  const pitch = '10000000-0000-4000-8000-000000000001';
  await db.exec(`insert into open_queue_games(starts_at,ends_at,field_id)
    values('2026-12-04 20:30-07','2026-12-04 21:30-07',${q(pitch)})`);
  await rejects(`insert into open_queue_games(starts_at,ends_at,field_id)
    values('2026-12-04 21:00-07','2026-12-04 22:00-07',${q(pitch)})`, /field already has a game overlapping/);
  const cancelled = await value(`insert into open_queue_games(starts_at,ends_at,field_id,status)
    values('2026-12-04 21:00-07','2026-12-04 22:00-07',${q(pitch)},'CANCELLED') returning id`);
  await db.exec("select set_config('test.catalogue_disabled','true',false)");
  await rejects(`update open_queue_games set status='OPEN' where id=${q(cancelled)}`, /field already has a game overlapping/);
  await db.exec(`update open_queue_games set status='CANCELLED' where id=${q(first)}`);
  await check(`select status='CANCELLED' from open_queue_games where id=${q(first)}`);
  console.log(`PASS: ${checks} solo schedule timezone/safety checks; unchanged status updates never scan the timezone catalogue.`);
} finally {
  await db.close();
}
