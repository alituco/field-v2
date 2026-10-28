// Isolated PostgreSQL tests: no hosted requests or real payment/account data.
// Set PGLITE_MODULE to an existing @electric-sql/pglite installation if needed.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import { reconciliationConfig, reconciliationSql } from './e2e/reconcile_captured_checkout.mjs';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const q = value => value == null ? 'null' : `'${String(value).replaceAll("'", "''")}'`;
const j = value => `${q(JSON.stringify(value))}::jsonb`;
const uuid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const [player, creator, staffAuth, game, intent] = [1, 2, 3, 4, 5].map(uuid);
const run = 'isolated-run-42';
const settings = { project_ref: 'nfdkdhdevpstfspazbfn', run_id: run, intent_id: intent,
  player_id: player, game_id: game, creator_id: creator,
  confirmation: `RECONCILE_STAGING_E2E:${run}:${intent}` };
const args = [`--run=${run}`, `--intent=${intent}`, `--player=${player}`, `--game=${game}`, `--creator=${creator}`];
const fakeConnection = new URL('postgresql://aws-0-us-east-1.pooler.supabase.com:5432/postgres');
fakeConnection.username = 'postgres.nfdkdhdevpstfspazbfn';
fakeConnection.password = randomUUID();
const env = { SUPABASE_URL: 'https://nfdkdhdevpstfspazbfn.supabase.co', FIELD_ENVIRONMENT: 'staging',
  SUPABASE_DB_URL: fakeConnection.href };
let checks = 0;
const sql = await readFile(new URL('./e2e/reconcile_captured_checkout.sql', import.meta.url), 'utf8');
const migration = await readFile(new URL('../migrations/20261010001000_replace_payment_provider.sql', import.meta.url), 'utf8');
const fn = name => {
  const start = migration.search(new RegExp(`create (?:or replace )?function public\\.${name}\\(`));
  assert(start >= 0);
  return migration.slice(start, migration.indexOf('\n$$;', start) + 4);
};
const val = async query => Object.values((await db.query(query)).rows[0])[0];
const snapshot = () => val(`select jsonb_build_object(
  'auth',(select jsonb_agg(to_jsonb(t) order by id) from auth.users t),
  'profiles',(select jsonb_agg(to_jsonb(t) order by id) from profiles t),
  'staff',(select jsonb_agg(to_jsonb(t) order by profile_id) from referee_profiles t),
  'games',(select jsonb_agg(to_jsonb(t) order by id) from open_queue_games t),
  'intents',(select jsonb_agg(to_jsonb(t) order by id) from payment_intents t),
  'refunds',(select jsonb_agg(to_jsonb(t) order by id) from payment_refunds t),
  'bookings',(select jsonb_agg(to_jsonb(t) order by id) from open_queue_bookings t))`);
async function execute({ overrides = {}, mutation = '', apply = true } = {}) {
  await db.exec('begin');
  try {
    for (const [key, value] of Object.entries({ ...settings, ...overrides })) {
      await db.query('select set_config($1,$2,true)', [`field.reconcile_${key}`, value ?? '']);
    }
    if (mutation) await db.exec(mutation);
    await db.exec(sql);
    await db.exec(apply ? 'commit' : 'rollback');
  } catch (error) { await db.exec('rollback'); throw error; }
}
async function rejected(options, pattern = /./s) {
  const before = await snapshot();
  await assert.rejects(execute(options), pattern); checks++;
  assert.deepEqual(await snapshot(), before); checks++;
}

try {
  // CLI never permits a production/custom/local connection, even when the
  // public URL falsely claims staging. Passwords remain in child env, not argv.
  const config = reconciliationConfig(args, env);
  assert.equal(config.apply, false); checks++;
  assert.match(reconciliationSql(config, sql), /rollback;\n$/); checks++;
  assert.match(reconciliationSql(reconciliationConfig([...args, '--apply', `--confirm=${settings.confirmation}`], env), sql), /commit;\n$/); checks++;
  for (const badEnv of [
    { FIELD_ENVIRONMENT: 'production' }, { FIELD_ENVIRONMENT: '' },
    { SUPABASE_URL: 'https://zjsjuuhborxrlmdcpvlj.supabase.co' },
    { SUPABASE_URL: 'http://127.0.0.1:54321' },
    { SUPABASE_URL: 'https://nfdkdhdevpstfspazbfn.supabase.co/other' },
    { SUPABASE_DB_URL: '' },
    { SUPABASE_DB_URL: env.SUPABASE_DB_URL.replace('postgres.nfdkdhdevpstfspazbfn', 'postgres.zjsjuuhborxrlmdcpvlj') },
    { SUPABASE_DB_URL: env.SUPABASE_DB_URL.replace('aws-0-us-east-1.pooler.supabase.com', 'evil.example') },
    { SUPABASE_DB_URL: `${env.SUPABASE_DB_URL}?options=-c%20search_path=evil` },
    { SUPABASE_DB_URL: `${env.SUPABASE_DB_URL}?sslmode=disable` },
  ]) { assert.throws(() => reconciliationConfig(args, { ...env, ...badEnv })); checks++; }
  for (const badArgs of [
    [...args, '--apply'], [...args, '--apply', '--confirm=wrong'], [...args, '--unknown=true'],
    [...args, `--intent=${intent}`], args.slice(1), args.filter(x => !x.startsWith('--player=')),
    args.map(x => x.startsWith('--intent=') ? '--intent=not-a-uuid' : x),
  ]) { assert.throws(() => reconciliationConfig(badArgs, env)); checks++; }

  await db.exec(`
    create schema auth; create schema fieldrush_private;
    create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$;
    create table auth.users(id uuid primary key,email text,phone text,email_confirmed_at timestamptz,raw_app_meta_data jsonb);
    create table auth.identities(user_id uuid,provider text);
    create table fieldrush_private.accounts(user_id uuid primary key);
    create table profiles(id uuid primary key,auth_user_id uuid,display_name text,username text);
    create table referee_profiles(profile_id uuid primary key,auth_user_id uuid,email text,display_name text,role text,is_active boolean);
    create table open_queue_games(id uuid primary key,status text,venue text,created_by_staff_id uuid);
    create table payment_intents(id uuid primary key,profile_id uuid,provider text,purpose text,status text,currency text,
      amount_fils integer,amount_minor integer generated always as(case when currency='USD' then amount_fils/10 else amount_fils end) stored,
      payload jsonb,quote_snapshot jsonb,transaction_reference text,provider_intent_id text,provider_payment_id text,
      provider_status text,payment_method text,captured_at timestamptz,finalized_at timestamptz,
      resource_id uuid,resource_type text,failure_reason text);
    create table open_queue_bookings(id uuid default gen_random_uuid(),game_id uuid,profile_id uuid,payment_intent_id uuid,refund_status text);
    create table fixtures(id uuid,home_payment_intent_id uuid,away_payment_intent_id uuid,home_amount_paid_fils integer,away_amount_paid_fils integer);
    create table payment_refunds(id uuid primary key default gen_random_uuid(),intent_id uuid,recipient_profile_id uuid,
      idempotency_key text unique,provider_intent_id text,amount_fils integer,amount_minor integer,currency text,
      reason text,metadata jsonb,status text,provider_status text,provider_refund_id text);
    create function book_open_queue_game_server(uuid,text,text,text) returns uuid language plpgsql as $$
      begin raise exception 'This game is not open for booking.'; end $$;
    insert into auth.users(id,raw_app_meta_data) values(${q(player)},${j({ fieldrush_e2e: true, fieldrush_e2e_role: 'player', fieldrush_e2e_run_id: run })});
    insert into auth.users values(${q(staffAuth)},'field_e2e_staff@fieldrush-e2e.example',null,now(),
      ${j({ fieldrush_e2e: true, fieldrush_e2e_role: 'admin', fieldrush_account_type: 'staff', fieldrush_e2e_run_id: run })});
    insert into fieldrush_private.accounts values(${q(player)});
    insert into profiles values(${q(player)},${q(player)},'[E2E] Isolated Player','field_e2e_isolated');
    insert into referee_profiles values(${q(creator)},${q(staffAuth)},'field_e2e_staff@fieldrush-e2e.example','[E2E] Staff','admin',false);
    insert into open_queue_games values(${q(game)},'CANCELLED',${q(`[FIELD E2E ${run}] Match`)},${q(creator)});
    insert into payment_intents(id,profile_id,provider,purpose,status,currency,amount_fils,payload,quote_snapshot,
      transaction_reference,provider_intent_id,provider_payment_id,provider_status,payment_method,captured_at)
      values(${q(intent)},${q(player)},'STAGING_E2E','SOLO_BOOKING','CAPTURED','USD',8000,
        ${j({ game_id: game, role: 'DEF' })},${j({ currency: 'USD', total_fils: 8000 })},
        ${q(`field_e2e_${run}_${intent.replaceAll('-', '')}`)},${q(`field_e2e_intent_${intent.replaceAll('-', '')}`)},
        ${q(`field_e2e_${intent.replaceAll('-', '')}`)},'SUCCEEDED','CARD',now());
  `);
  await db.exec(fn('request_payment_refund'));
  await db.exec(fn('finalize_payment_intent'));

  for (const key of Object.keys(settings)) await rejected({ overrides: { [key]: '' } });
  for (const key of ['intent_id', 'player_id', 'game_id', 'creator_id']) await rejected({ overrides: { [key]: uuid(99) } });
  for (const mutation of [
    `update profiles set display_name='Real player'`, `update profiles set username='real_user'`,
    `update profiles set auth_user_id=${q(staffAuth)}`,
    `update auth.users set raw_app_meta_data='{}' where id=${q(player)}`,
    `update auth.users set raw_app_meta_data=raw_app_meta_data||'{"fieldrush_e2e_run_id":"another-run"}' where id=${q(player)}`,
    `update auth.users set raw_app_meta_data=raw_app_meta_data||'{"fieldrush_e2e_run_id":null}' where id=${q(player)}`,
    `update auth.users set raw_app_meta_data=raw_app_meta_data||'{"fieldrush_e2e_run_id":null,"fieldrush_e2e_revoked_run_id":"another-run"}' where id=${q(player)}`,
    `update auth.users set raw_app_meta_data=raw_app_meta_data||'{"fieldrush_e2e_revoked_run_id":"another-run"}' where id=${q(player)}`,
    `update referee_profiles set auth_user_id=${q(player)}`,
    `update referee_profiles set role='referee'`, `update referee_profiles set email='real@example.test'`,
    `update auth.users set phone='+15550000000' where id=${q(staffAuth)}`,
    `update auth.users set email_confirmed_at=null where id=${q(staffAuth)}`,
    `update auth.users set raw_app_meta_data='{}' where id=${q(staffAuth)}`,
    `update auth.users set raw_app_meta_data=raw_app_meta_data||'{"fieldrush_e2e_run_id":"another-run"}' where id=${q(staffAuth)}`,
    `insert into auth.identities values(${q(staffAuth)},'google')`,
    `insert into profiles values(${q(staffAuth)},${q(staffAuth)},'[E2E] Staff player','field_e2e_staff')`,
    `update open_queue_games set status='OPEN'`, `update open_queue_games set venue='A real venue'`,
    `update open_queue_games set created_by_staff_id=${q(uuid(99))}`,
    `update payment_intents set provider='STRIPE'`, `update payment_intents set provider='LEGACY'`,
    `update payment_intents set purpose='CLAN_JOIN'`, `update payment_intents set status='FINALIZED'`,
    `update payment_intents set provider_status='PENDING'`, `update payment_intents set captured_at=null`,
    `update payment_intents set transaction_reference='field_e2e_another_run'`,
    `update payment_intents set provider_intent_id='pi_real'`, `update payment_intents set provider_payment_id='ch_real'`,
    `update payment_intents set payment_method='MOCK'`, `update payment_intents set finalized_at=now()`,
    `update payment_intents set resource_id=${q(uuid(90))}`, `update payment_intents set resource_type='OPEN_QUEUE_BOOKING'`,
    `update payment_intents set quote_snapshot='{"currency":"USD","total_fils":9000}'`,
    `update payment_intents set quote_snapshot='{"currency":"BHD","total_fils":8000}'`,
    `update payment_intents set currency='BHD',quote_snapshot='{"currency":"BHD","total_fils":8000}'`,
    `update payment_intents set amount_fils=8001,quote_snapshot='{"currency":"USD","total_fils":8001}'`,
    `update payment_intents set payload=payload||'{"role":"OTHER"}'`,
    `update payment_intents set payload=payload||'{"unexpected":"key"}'`,
    `update payment_intents set failure_reason='Prior failure'`,
    `insert into open_queue_bookings(game_id,profile_id,payment_intent_id) values(${q(game)},${q(player)},${q(intent)})`,
    `insert into open_queue_bookings(game_id,profile_id) values(${q(game)},${q(player)})`,
    `insert into fixtures(id,home_payment_intent_id) values(${q(uuid(90))},${q(intent)})`,
    `insert into payment_refunds(intent_id) values(${q(intent)})`,
  ]) await rejected({ mutation });

  // Both current and cleanup-revoked run ownership work, with staff access
  // unchanged. Dry-run executes the ordinary SQL finalizer then rolls back.
  const before = await snapshot();
  await execute({ apply: false });
  assert.deepEqual(await snapshot(), before); checks++;
  const longRun = 'isolated-run-with-more-than-twenty-eight-characters-42';
  await execute({ apply: false,
    overrides: { run_id: longRun, confirmation: `RECONCILE_STAGING_E2E:${longRun}:${intent}` },
    mutation: `update auth.users set raw_app_meta_data=raw_app_meta_data||${j({ fieldrush_e2e_run_id: longRun })};
      update open_queue_games set venue=${q(`[FIELD E2E ${longRun.slice(0,28)}] Match`)};
      update payment_intents set transaction_reference=${q(`field_e2e_${longRun}_${intent.replaceAll('-', '')}`)};` });
  assert.deepEqual(await snapshot(), before); checks++;
  await execute({ mutation: `update auth.users set raw_app_meta_data=raw_app_meta_data||
    ${j({ fieldrush_e2e_run_id: null, fieldrush_e2e_revoked_run_id: run })}` });
  assert.equal(await val(`select status from payment_intents where id=${q(intent)}`), 'REFUNDED'); checks++;
  assert.equal(await val('select count(*)::int from payment_refunds where status=\'SUCCEEDED\' and provider_status=\'staging_e2e\''), 1); checks++;
  assert.equal(await val('select is_active from referee_profiles'), false); checks++;
  const terminal = await snapshot();
  await execute();
  assert.deepEqual(await snapshot(), terminal); checks++;
  for (const mutation of [
    `update payment_refunds set amount_fils=1`, `update payment_refunds set amount_minor=1`,
    `update payment_refunds set status='PENDING'`,
    `update payment_refunds set provider_status='real-provider'`,
    `update payment_refunds set provider_refund_id='re_real'`, `update payment_refunds set idempotency_key='other'`,
    `update payment_refunds set recipient_profile_id=${q(uuid(99))}`,
    `update payment_refunds set metadata='{}'`,
  ]) await rejected({ mutation });

  console.log(`e2e-captured-checkout-reconciliation: ${checks} isolated safety/behavior checks passed`);
} finally { await db.close(); }
