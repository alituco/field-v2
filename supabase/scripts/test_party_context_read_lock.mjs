// Real two-connection locking regression in a disposable local PostgreSQL cluster.
// Requires PostgreSQL server binaries, e.g.:
// PG_BINDIR="$(brew --prefix postgresql@18)/bin" node supabase/scripts/test_party_context_read_lock.mjs
// No database URL is accepted: the server has no TCP listener and uses only a
// private temporary Unix socket. No existing local or hosted database is used.
// The fixture uses the real context/ensure bodies and migration transformations,
// with minimal tables. Full-schema authorization/privacy coverage lives in
// verify_party_context_read_lock.sql; the masking helper here is a test double.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

assert.equal(process.argv.length, 2, 'This local-only test accepts no connection arguments.');
const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('PG')));
const discovered = spawnSync('pg_config', ['--bindir'], { encoding: 'utf8', env: environment });
const bin = process.env.PG_BINDIR || discovered.stdout?.trim();
assert(bin, 'Install PostgreSQL server binaries and set PG_BINDIR to their directory.');
const root = await mkdtemp('/tmp/fr-party-lock-');
const data = join(root, 'data');
const socket = join(root, 'socket');
await mkdir(socket, { mode: 0o700 });
const psqlArgs = ['-X', '-q', '-A', '-t', '-h', socket, '-p', '55439', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'];
const migration = name => readFile(new URL(`../migrations/${name}`, import.meta.url), 'utf8');
const game = '10000000-0000-4000-8000-000000000001';
const player = '20000000-0000-4000-8000-000000000001';
const outsider = '20000000-0000-4000-8000-000000000002';
const policy = '30000000-0000-4000-8000-000000000001';
let started = false;
let holder;
let checks = 0;

function command(name, args, input) {
  const result = spawnSync(join(bin, name), args, { input, encoding: 'utf8', env: environment, timeout: 15000 });
  assert.equal(result.status, 0, `${name}: ${result.error?.message || result.stderr || result.stdout}`);
  return result.stdout.trim();
}
function sql(source, allowFailure = false) {
  const result = spawnSync(join(bin, 'psql'), psqlArgs, { input: source, encoding: 'utf8', env: environment, timeout: 10000 });
  if (!allowFailure) assert.equal(result.status, 0, result.error?.message || result.stderr);
  return result;
}
function value(source) { return sql(source).stdout.trim(); }
function check(condition, message) { assert(condition, message); checks++; }
function functionFrom(source, name) {
  const start = source.indexOf(`create or replace function public.${name}(`);
  assert(start >= 0, `Missing function ${name}`);
  const end = source.indexOf('\n$$;', start);
  assert(end > start, `Missing function terminator for ${name}`);
  return source.slice(start, end + 4);
}
function migrationBlock(source, comment) {
  const marker = source.indexOf(comment);
  assert(marker >= 0, `Missing migration marker: ${comment}`);
  const start = source.indexOf('do $migration$', marker);
  const end = source.indexOf('$migration$;', start);
  assert(start >= 0 && end > start, 'Missing migration block');
  return source.slice(start, end + '$migration$;'.length);
}
function session() {
  const child = spawn(join(bin, 'psql'), psqlArgs, { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
  let output = ''; let error = ''; let closed = false;
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { error += chunk; });
  child.on('error', cause => { error += cause.message; closed = true; });
  child.stdin.on('error', cause => { error += cause.message; closed = true; });
  child.on('close', () => { closed = true; });
  return {
    send(source) { child.stdin.write(source + '\n'); },
    async marker(marker) {
      const deadline = Date.now() + 6000;
      while (!output.split(/\r?\n/).includes(marker)) {
        assert(!closed && Date.now() < deadline, error || `Session did not reach ${marker}`);
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    },
    close() { if (!child.stdin.destroyed) child.stdin.end('rollback;\n\\q\n'); },
  };
}
const readContext = (user = player) => `begin; set local lock_timeout='300ms'; set local statement_timeout='3s';
  set local role authenticated; set local request.jwt.claim.sub='${user}';
  select public.get_open_queue_party_context('${game}'); commit;`;
function context() {
  return JSON.parse(value(readContext()).split(/\r?\n/).at(-1));
}
function expectLock(label) {
  const result = sql('\\set VERBOSITY verbose\n' + readContext(), true);
  check(result.status !== 0 && result.stderr.includes('55P03') &&
    result.stderr.includes('ensure_match_reliability_terms'), `${label}: expected the real ensure helper to wait for the game row lock, got ${result.stderr}`);
  console.log(`PASS ${label}: lock timeout inside ensure_match_reliability_terms`);
}
function assertContract(payload, label) {
  check(payload.game_id === game && payload.game_status === 'OPEN' && payload.can_use_parties === true, `${label}: game context`);
  check(payload.policy_version_id === policy && payload.max_party_size === 4 &&
    payload.party_lock_lead_minutes === 180 && payload.team_assignment_lead_minutes === 180, `${label}: committed policy values`);
  const row = JSON.parse(value(`select jsonb_build_object('party_lock_at',party_lock_at,'team_assignment_at',team_assignment_at)
    from match_reliability_terms where open_queue_game_id='${game}';`));
  check(payload.party_lock_at === row.party_lock_at && payload.team_assignment_at === row.team_assignment_at, `${label}: stored timestamps`);
}

try {
  command('initdb', ['-D', data, '-U', 'postgres', '--auth-local=trust', '--auth-host=reject', '--no-locale', '-E', 'UTF8']);
  await writeFile(join(data, 'postgresql.auto.conf'), `listen_addresses = ''\nunix_socket_directories = '${socket}'\nunix_socket_permissions = 0700\nport = 55439\n`);
  command('pg_ctl', ['-D', data, '-l', join(root, 'postgres.log'), '-w', 'start']);
  started = true;
  check(value('show listen_addresses;') === '', 'The isolated server must not listen on TCP.');
  const attendance = await migration('20260716000002_enforce_reliability_attendance.sql');
  sql(`create role anon; create role authenticated; create role service_role;
    create schema auth; create schema fieldrush_rating_private;
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    create table open_queue_games(id uuid primary key,status text,starts_at timestamptz);
    create table profiles(id uuid primary key,display_name text,username text,avatar_url text);
    create table open_queue_bookings(game_id uuid,profile_id uuid,status text,role text);
    create table open_queue_parties(id uuid primary key,game_id uuid,owner_profile_id uuid,status text);
    create table open_queue_party_members(id uuid,party_id uuid,game_id uuid,profile_id uuid,status text,invited_at timestamptz,joined_at timestamptz);
    create table fixtures(id uuid primary key,match_date date,time_slot text,home_paid_by uuid,away_paid_by uuid);
    create function fixture_start_at(date,text) returns timestamptz language sql stable as $$select ($1::text||' '||$2||' UTC')::timestamptz$$;
    create table reliability_policy_versions(id uuid primary key,state text,effective_from timestamptz,version integer,config jsonb);
    ${attendance.slice(attendance.indexOf('create table public.match_reliability_terms ('), attendance.indexOf('create table public.field_wallet_accounts ('))}
    create table match_attendance_records(terms_id uuid,outcome text,policy_version_id uuid,check_in_deadline_at timestamptz,no_show_cutoff_at timestamptz);
    ${functionFrom(attendance, 'ensure_match_reliability_terms')}
    ${functionFrom(await migration('20260715000008_allow_open_queue_party_switches.sql'), 'get_open_queue_party_context')}
    ${migrationBlock(await migration('20260716000000_finalize_open_queue_teams_three_hours_before.sql'), '-- Hide actionable invites')}
    ${migrationBlock(await migration('20260716000003_apply_reliability_policy_to_solo_cutoffs.sql'), '-- Expose the exact server boundary')}
    alter function public.get_open_queue_party_context(uuid) rename to get_open_queue_party_context_before_sr_privacy;
    revoke all on function public.get_open_queue_party_context_before_sr_privacy(uuid) from public,anon,authenticated,service_role;
    create function fieldrush_rating_private.mask_public_rating_payload(jsonb,uuid,text,integer,uuid)
      returns jsonb language sql stable as $$select $1$$;
    create function public.get_open_queue_party_context(game_id_to_use uuid) returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
      select fieldrush_rating_private.mask_public_rating_payload(public.get_open_queue_party_context_before_sr_privacy($1),null::uuid,'OUTFIELD',null::integer,$1)||'{}'::jsonb $$;
    revoke all on function public.get_open_queue_party_context(uuid) from public,anon;
    grant execute on function public.get_open_queue_party_context(uuid) to authenticated,service_role;
    ${await migration('20261014002200_restore_party_context_write_transaction.sql')}
    insert into open_queue_games values('${game}','OPEN',now()+interval '10 days');
    insert into open_queue_bookings values('${game}','${player}','CONFIRMED','DEF');
    insert into reliability_policy_versions values('${policy}','PUBLISHED',now()-interval '1 day',1,
      '{"attendance":{"checkInOpenLeadMinutes":30,"checkInLeadMinutes":10,"noShowGraceMinutes":0},"solo":{"teamAssignmentLeadMinutes":180,"partyLockLeadMinutes":180},"replacement":{"maxPartySize":4}}');
    select public.ensure_match_reliability_terms('SOLO','${game}');
    -- A later policy cannot replace the contract already disclosed to a booked player.
    insert into reliability_policy_versions values(gen_random_uuid(),'PUBLISHED',now(),2,
      '{"attendance":{"checkInOpenLeadMinutes":30,"checkInLeadMinutes":10,"noShowGraceMinutes":0},"solo":{"teamAssignmentLeadMinutes":90,"partyLockLeadMinutes":90},"replacement":{"maxPartySize":2}}');
  `);
  const before = context();
  assertContract(before, 'Unlocked baseline');
  const wrapperBefore = value("select pg_get_functiondef('public.get_open_queue_party_context(uuid)'::regprocedure);");
  holder = session();
  holder.send(`begin; select id from open_queue_games where id='${game}' for update;
    select id from match_reliability_terms where open_queue_game_id='${game}' for update;\n\\echo BASELINE_LOCKED`);
  await holder.marker('BASELINE_LOCKED');
  expectLock('Old context with existing terms');

  sql(await migration('20261023000300_party_context_read_lock.sql'));
  assertContract(context(), 'Patched context while game and terms are locked');
  check(value("select pg_get_functiondef('public.get_open_queue_party_context(uuid)'::regprocedure);") === wrapperBefore, 'The public privacy wrapper changed.');
  console.log('PASS patched context returns committed policy while both game and terms rows remain locked');

  for (const [user, expected] of [['', 'You need to sign in again.'], [outsider, 'You need a confirmed booking in this solo game.']]) {
    const result = sql(readContext(user), true);
    check(result.status !== 0 && result.stderr.includes(expected) && !result.stderr.includes('lock timeout'), `Authorization must reject before fallback: ${expected}`);
  }
  check(value(`select not has_function_privilege('anon','public.get_open_queue_party_context(uuid)','execute')
    and has_function_privilege('authenticated','public.get_open_queue_party_context(uuid)','execute')
    and has_function_privilege('service_role','public.get_open_queue_party_context(uuid)','execute')
    and not has_function_privilege('authenticated','public.get_open_queue_party_context_before_sr_privacy(uuid)','execute')
    and not has_function_privilege('service_role','public.get_open_queue_party_context_before_sr_privacy(uuid)','execute')
    and not has_function_privilege('anon','public.get_open_queue_party_context_before_sr_privacy(uuid)','execute');`) === 't', 'Caller grants and private implementation must remain unchanged.');
  holder.send('rollback;\n\\echo BASELINE_RELEASED');
  await holder.marker('BASELINE_RELEASED');

  // Missing terms must still serialize and initialize, not return null cutoffs.
  sql(`delete from match_reliability_terms where open_queue_game_id='${game}';
    delete from reliability_policy_versions where id<>'${policy}';`);
  holder.send(`begin; select id from open_queue_games where id='${game}' for update;\n\\echo MISSING_LOCKED`);
  await holder.marker('MISSING_LOCKED');
  expectLock('Patched context with missing terms');
  holder.send('rollback;\n\\echo MISSING_RELEASED');
  await holder.marker('MISSING_RELEASED');
  assertContract(context(), 'Missing terms initialized after release');
  check(value(`select count(*) from match_reliability_terms where open_queue_game_id='${game}';`) === '1', 'Missing terms should initialize exactly once.');

  // A committed schedule change must retain the existing locked rebind path.
  sql(`update open_queue_games set starts_at=starts_at+interval '1 day' where id='${game}';`);
  holder.send(`begin; select id from open_queue_games where id='${game}' for update;
    select id from match_reliability_terms where open_queue_game_id='${game}' for update;\n\\echo STALE_LOCKED`);
  await holder.marker('STALE_LOCKED');
  expectLock('Patched context with stale kickoff terms');
  holder.send('rollback;\n\\echo STALE_RELEASED');
  await holder.marker('STALE_RELEASED');
  assertContract(context(), 'Stale terms rebound after release');
  check(value(`select t.kickoff_at=g.starts_at from match_reliability_terms t join open_queue_games g on g.id=t.open_queue_game_id where g.id='${game}';`) === 't', 'Stale terms must rebind to the committed kickoff.');
  check(value(`select count(*) from pg_proc where oid in ('public.get_open_queue_party_context(uuid)'::regprocedure,
    'public.get_open_queue_party_context_before_sr_privacy(uuid)'::regprocedure) and provolatile='v';`) === '2', 'Both function transaction contracts must remain volatile.');
  console.log(`party context read lock: ${checks} local PostgreSQL checks passed`);
} finally {
  holder?.close();
  if (started) command('pg_ctl', ['-D', data, '-m', 'immediate', '-w', 'stop']);
  await rm(root, { recursive: true, force: true });
}
