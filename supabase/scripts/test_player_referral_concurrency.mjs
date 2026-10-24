// Real multi-connection regression for the actual referral claim/review bodies.
// PG_BINDIR="$(brew --prefix postgresql@18)/bin" node supabase/scripts/test_player_referral_concurrency.mjs
// This test accepts no database URL. It creates a disposable PostgreSQL cluster
// with no TCP listener and a private Unix socket, then removes it. Identity,
// summary and computed tie helpers are explicit test doubles; the production
// claim/review bodies, permanent tables and review uniqueness come from SQL.
// Full schema, qualification and authorization checks live in verify_player_referrals.sql.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

assert.equal(process.argv.length, 2, 'This local-only test accepts no connection arguments.');
const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('PG')));
const discovered = spawnSync('pg_config', ['--bindir'], { encoding: 'utf8', env: environment });
const bin = process.env.PG_BINDIR || discovered.stdout?.trim();
assert(bin, 'Install PostgreSQL server binaries and set PG_BINDIR to their directory.');
const root = await mkdtemp('/tmp/fr-referral-race-');
const data = join(root, 'data');
const socket = join(root, 'socket');
await mkdir(socket, { mode: 0o700 });
const psqlArgs = ['-X', '-q', '-A', '-t', '-h', socket, '-p', '55438', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'];
const source = await readFile(new URL('../migrations/20261024000200_player_referrals.sql', import.meta.url), 'utf8');
const prefixEnd = source.indexOf('create view fieldrush_referral_private.players as');
assert(prefixEnd > 0, 'Referral schema fixture marker changed.');
const uuid = number => `10000000-0000-4000-8000-${String(number).padStart(12, '0')}`;
const admin = uuid(999);
const token = 'a'.repeat(32);
const sessions = new Set();
let started = false;
let checks = 0;

function command(name, args, input) {
  const result = spawnSync(join(bin, name), args, { input, encoding: 'utf8', env: environment, timeout: 15000 });
  assert.equal(result.status, 0, `${name}: ${result.error?.message || result.stderr || result.stdout}`);
  return result.stdout.trim();
}
function sql(statement) { return command('psql', psqlArgs, statement); }
function check(condition, message) { assert(condition, message); checks++; }
function functionFrom(name) {
  const start = source.indexOf(`create function public.${name}(`);
  assert(start >= 0, `Missing real function ${name}.`);
  const body = source.indexOf('as $$', start);
  const end = source.indexOf('$$;', body + 5);
  assert(body > start && end > body, `Missing terminator for ${name}.`);
  return source.slice(start, end + 3);
}
function session(name) {
  const child = spawn(join(bin, 'psql'), psqlArgs, { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
  let output = ''; let error = ''; let closed = false;
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { error += chunk; });
  child.stdin.on('error', cause => { error += cause.message; });
  let finish;
  const completion = new Promise(resolve => { finish = resolve; });
  child.on('error', cause => { error += cause.message; closed = true; finish({ status: -1, output, error }); });
  child.on('close', status => { closed = true; finish({ status, output, error }); });
  const timeout = setTimeout(() => { error += '\nSession exceeded 15 second deadline.'; child.kill('SIGKILL'); }, 15000);
  completion.finally(() => { clearTimeout(timeout); sessions.delete(handle); });
  const handle = {
    send(statement) { assert(!closed, error || `${name} is closed`); child.stdin.write(statement + '\n'); },
    end(statement = '') { child.stdin.end(statement + '\n'); },
    async marker(marker) {
      const deadline = Date.now() + 5000;
      while (!output.split(/\r?\n/).includes(marker)) {
        assert(!closed && Date.now() < deadline, error || `${name} did not reach ${marker}`);
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    },
    get closed() { return closed; },
    get error() { return error; },
    completion,
    stop() { child.kill('SIGTERM'); },
  };
  sessions.add(handle);
  handle.send(`\\set VERBOSITY verbose\nset application_name='${name}'; set statement_timeout='10s'; set lock_timeout='8s'; set deadlock_timeout='100ms';`);
  return handle;
}
async function waiting(name, client) {
  const deadline = Date.now() + 5000;
  while (sql(`select count(*) from pg_stat_activity where application_name='${name}' and wait_event_type='Lock';`) !== '1') {
    assert(!client.closed && Date.now() < deadline, client.error || `${name} never waited for a real PostgreSQL lock.`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  checks++;
}
async function hold(name, lockSql) {
  const holder = session(name);
  holder.send(`begin; ${lockSql}\n\\echo LOCKED`);
  await holder.marker('LOCKED');
  return holder;
}
function claim(name, player, referrer, checkDeadline = false) {
  const client = session(name);
  client.end(`begin; set local request.jwt.claim.sub='${uuid(player)}';
    ${checkDeadline ? `select 'BEFORE_EXPIRY:'||(clock_timestamp()<onboarding_completed_at+interval '7 days')::text from fieldrush_private.fixture_accounts where profile_id='${uuid(player)}';` : ''}
    select public.claim_fieldrush_referral_code('player${referrer}','${uuid(referrer)}'); commit;`);
  return client;
}
function review(name, order) {
  const client = session(name);
  client.end(`begin; set local request.jwt.claim.sub='${admin}';
    select public.admin_review_fieldrush_referral_tie('${admin}','${token}',
      array[${order.map(id => `'${uuid(id)}'::uuid`).join(',')}], 'Reviewed the verified attendance evidence.'); commit;`);
  return client;
}
async function release(holder) {
  holder.end('commit;');
  const result = await holder.completion;
  assert.equal(result.status, 0, result.error);
}
function succeeded(result, label) { check(result.status === 0, `${label}: ${result.error}`); }
function failed(result, code, label) {
  check(result.status !== 0 && result.error.includes(code), `${label}: expected SQLSTATE ${code}, got ${result.error}`);
}

try {
  command('initdb', ['-D', data, '-U', 'postgres', '--auth-local=trust', '--auth-host=reject', '--no-locale', '-E', 'UTF8']);
  await writeFile(join(data, 'postgresql.auto.conf'), `listen_addresses = ''\nunix_socket_directories = '${socket}'\nunix_socket_permissions = 0700\nport = 55438\n`);
  command('pg_ctl', ['-D', data, '-l', join(root, 'postgres.log'), '-w', 'start']);
  started = true;
  check(sql('show listen_addresses;') === '', 'The disposable server must have no TCP listener.');
  sql(`create role anon; create role authenticated; create role service_role;
    create schema auth; create schema fieldrush_private;
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    create table public.profiles(id uuid primary key,username text not null);
    create table public.referee_profiles(profile_id uuid primary key);
    insert into public.referee_profiles values('${admin}');
    create table public.fieldrush_seasons(id text primary key,visible_to_players boolean,lifecycle text,starts_on date);
    insert into public.fieldrush_seasons values('s0',true,'ACTIVE',current_date-1);
    ${source.slice(0, prefixEnd)}
    -- Only fixture time is adjusted; the production immutable trigger remains
    -- enabled for every call under test. This is a brand-new local cluster.
    alter table fieldrush_referral_private.launch disable trigger immutable_referral_launch;
    update fieldrush_referral_private.launch set launched_at=clock_timestamp()-interval '8 days';
    alter table fieldrush_referral_private.launch enable trigger immutable_referral_launch;
    create table fieldrush_private.fixture_accounts(profile_id uuid primary key,onboarding_completed_at timestamptz);
    create view fieldrush_referral_private.players as
      select p.id,p.username,a.onboarding_completed_at from public.profiles p join fieldrush_private.fixture_accounts a on a.profile_id=p.id;
    create function fieldrush_referral_private.require_player() returns uuid language plpgsql stable as $$
      begin if not exists(select 1 from fieldrush_referral_private.players where id=auth.uid()) then
        raise exception 'Unknown fixture player' using errcode='42501'; end if; return auth.uid(); end$$;
    create function public.get_fieldrush_referrals() returns jsonb language sql stable as $$
      select jsonb_build_object('referrer',referrer_profile_id) from fieldrush_referral_private.links where referred_profile_id=auth.uid()$$;
    create table fieldrush_referral_private.fixture_ties(
      referral_count integer,games_played integer,referred_games_played integer,member_ids uuid[],member_count integer,evidence_token text);
    create view fieldrush_referral_private.tie_groups as select * from fieldrush_referral_private.fixture_ties;
    create view fieldrush_referral_private.competition as select season_id id from fieldrush_referral_private.launch;
    create function public.is_active_moderation_admin(actor uuid) returns boolean language sql stable as $$select actor=auth.uid() and actor='${admin}'::uuid$$;
    create table public.admin_audit_events(actor_referee_id uuid,action text,entity_type text,entity_id uuid,reason text,before_state jsonb,after_state jsonb);
    create function public.admin_get_fieldrush_referrals(actor_admin_id uuid) returns jsonb language sql stable as $$
      select jsonb_build_object('reviews',(select count(*) from fieldrush_referral_private.tie_reviews),
        'order',(select to_jsonb(ordered_profile_ids) from fieldrush_referral_private.tie_reviews where evidence_token='${token}'))$$;
    ${functionFrom('claim_fieldrush_referral_code')}
    ${functionFrom('admin_review_fieldrush_referral_tie')}
    insert into public.profiles(id,username) values ${[101,102,103,201,202,301,302].map(id => `('${uuid(id)}','player${id}')`).join(',')};
    insert into fieldrush_private.fixture_accounts select id,clock_timestamp() from public.profiles;
    insert into fieldrush_referral_private.fixture_ties values(3,7,11,array['${uuid(201)}'::uuid,'${uuid(202)}'::uuid],2,'${token}');
  `);

  // Queue two different choices behind the same real player row lock. The
  // first queued transaction commits one permanent link; the second must fail.
  const sameHolder = await hold('same_holder', `select id from profiles where id='${uuid(101)}' for update;`);
  const first = claim('same_first',101,102); await waiting('same_first',first);
  const second = claim('same_second',101,103); await waiting('same_second',second);
  await release(sameHolder);
  const [one,two] = await Promise.all([first.completion,second.completion]);
  succeeded(one,'First code wins'); failed(two,'22023','Different concurrent code cannot replace it');
  check(sql(`select count(*)||':'||min(referrer_profile_id::text) from fieldrush_referral_private.links where referred_profile_id='${uuid(101)}';`) === `1:${uuid(102)}`, 'Exactly the first permanent referral link must remain.');
  succeeded(await claim('same_retry',101,102).completion,'Same identity retries safely');
  check(sql(`select count(*) from fieldrush_referral_private.links where referred_profile_id='${uuid(101)}';`) === '1','Retry must not add a second link.');
  console.log('PASS same player / two codes: one immutable winner; identical retry succeeds');

  // This interleaving deadlocks if callers lock their own row before the other
  // player. Holding the lower row forces both real bodies into the critical path.
  const reciprocalHolder = await hold('reciprocal_holder', `select id from profiles where id='${uuid(201)}' for update;`);
  const forward = claim('reciprocal_forward',201,202); await waiting('reciprocal_forward',forward);
  const reverse = claim('reciprocal_reverse',202,201); await waiting('reciprocal_reverse',reverse);
  await release(reciprocalHolder);
  const reciprocal = await Promise.all([forward.completion,reverse.completion]);
  reciprocal.forEach((result,index) => succeeded(result,`Reciprocal claim ${index+1} without deadlock`));
  check(sql(`select count(*) from fieldrush_referral_private.links where referred_profile_id in ('${uuid(201)}','${uuid(202)}');`) === '2','Both different players must retain their own referral links.');
  console.log('PASS opposite A→B / B→A requests: deterministic locking avoids deadlock');

  // Wait on the REFERRER row, rather than only the caller row. This catches a
  // deadline computed before waiting for a checked identity's concurrent edit.
  const deadlineHolder = await hold('deadline_holder', `select id from profiles where id='${uuid(302)}' for update;`);
  sql(`update fieldrush_private.fixture_accounts set onboarding_completed_at=clock_timestamp()-interval '7 days'+interval '2500 milliseconds' where profile_id='${uuid(301)}';`);
  check(sql(`select clock_timestamp()<onboarding_completed_at+interval '7 days' from fieldrush_private.fixture_accounts where profile_id='${uuid(301)}';`) === 't','The claim must begin before its deadline.');
  const expiring = claim('deadline_claim',301,302,true); await waiting('deadline_claim',expiring);
  const expiryWait = Date.now()+5000;
  while (sql(`select clock_timestamp()>=onboarding_completed_at+interval '7 days' from fieldrush_private.fixture_accounts where profile_id='${uuid(301)}';`) !== 't') {
    assert(Date.now()<expiryWait,'Fixture deadline did not arrive.');
    await new Promise(resolve=>setTimeout(resolve,25));
  }
  await release(deadlineHolder);
  const expired = await expiring.completion;
  check(expired.output.split(/\r?\n/).includes('BEFORE_EXPIRY:true'),'The blocked session itself must begin before expiry.');
  failed(expired,'22023','A claim crossing expiry while blocked must fail');
  check(expired.error.includes('window has closed'),'Expiry rejection must explain the closed window.');
  check(sql(`select count(*) from fieldrush_referral_private.links where referred_profile_id='${uuid(301)}';`) === '0','A blocked expired claim must not create a link.');
  console.log('PASS claim waits past expiry on referrer identity: rejected without saving');

  const reviewHolder = await hold('review_holder', "select pg_advisory_xact_lock(hashtextextended('fieldrush-referral-review',0));");
  const reviewFirst = review('review_first',[201,202]); await waiting('review_first',reviewFirst);
  const reviewSecond = review('review_second',[202,201]); await waiting('review_second',reviewSecond);
  await release(reviewHolder);
  const [accepted,rejected] = await Promise.all([reviewFirst.completion,reviewSecond.completion]);
  succeeded(accepted,'First admin order is accepted'); failed(rejected,'40001','Concurrent differing admin order is stale');
  check(sql('select (select count(*) from fieldrush_referral_private.tie_reviews)||\':\'||(select count(*) from public.admin_audit_events);') === '1:1','One decision and one audit event must remain.');
  check(sql(`select array_to_string(ordered_profile_ids,',') from fieldrush_referral_private.tie_reviews where evidence_token='${token}';`) === `${uuid(201)},${uuid(202)}`,'Rejected admin must not overwrite the first order.');
  succeeded(await review('review_retry',[201,202]).completion,'Identical admin retry returns success');
  check(sql('select (select count(*) from fieldrush_referral_private.tie_reviews)||\':\'||(select count(*) from public.admin_audit_events);') === '1:1','Idempotent admin retry must not duplicate audit history.');
  console.log('PASS concurrent admin tie orders: first wins; same-order retry is idempotent');
  console.log(`player referral concurrency: ${checks} local PostgreSQL checks passed`);
} finally {
  for (const client of sessions) client.stop();
  await Promise.allSettled([...sessions].map(client => client.completion));
  if (started) command('pg_ctl', ['-D', data, '-m', 'immediate', '-w', 'stop']);
  await rm(root, { recursive: true, force: true });
}
