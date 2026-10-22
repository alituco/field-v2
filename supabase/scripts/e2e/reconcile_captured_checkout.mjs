// Local operator command, never called by deployment/cleanup. Node 22.18+.
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { assertSafeDevDataTarget, FIELD_STAGING_PROJECT_REF } from '../_shared/environment_guard.ts';

export function reconciliationConfig(args, env) {
  const options = new Map();
  for (const arg of args) {
    const match = /^--(run|intent|player|game|creator|confirm)=(.+)$/.exec(arg);
    const key = arg === '--apply' ? 'apply' : match?.[1];
    if (!key || options.has(key)) throw new Error('Unknown or duplicate maintenance argument.');
    options.set(key, match?.[2] ?? true);
  }
  const target = assertSafeDevDataTarget(env.SUPABASE_URL ?? '', 'reconcile captured E2E checkout');
  if (target.environment !== 'staging' || env.FIELD_ENVIRONMENT !== 'staging') {
    throw new Error('Captured E2E reconciliation requires the exact hosted staging project and FIELD_ENVIRONMENT=staging.');
  }
  const run = options.get('run');
  if (typeof run !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(run)) throw new Error('An exact E2E run is required.');
  for (const key of ['intent', 'player', 'game', 'creator']) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(options.get(key) ?? '')) {
      throw new Error(`An exact ${key} UUID is required.`);
    }
    options.set(key, options.get(key).toLowerCase());
  }
  const confirmation = `RECONCILE_STAGING_E2E:${run}:${options.get('intent')}`;
  if ((options.has('apply') || options.has('confirm')) && options.get('confirm') !== confirmation) {
    throw new Error('Applying maintenance requires --confirm=RECONCILE_STAGING_E2E:<run>:<intent>.');
  }
  let db;
  try { db = new URL(env.SUPABASE_DB_URL); } catch { throw new Error('SUPABASE_DB_URL must be an explicit staging PostgreSQL connection URL.'); }
  const username = decodeURIComponent(db.username);
  const direct = db.hostname === `db.${FIELD_STAGING_PROJECT_REF}.supabase.co` && username === 'postgres';
  const pooled = /^[a-z0-9.-]+\.pooler\.supabase\.com$/.test(db.hostname) && username === `postgres.${FIELD_STAGING_PROJECT_REF}`;
  if (!['postgres:', 'postgresql:'].includes(db.protocol) || (!direct && !pooled)
    || db.pathname !== '/postgres' || !db.password || db.hash
    || (db.port && !['5432', '6543'].includes(db.port))
    || [...db.searchParams].some(([key, value]) => key !== 'sslmode' || !['require', 'verify-full'].includes(value))) {
    throw new Error('Database connection is not the exact allow-listed staging direct/pooler identity.');
  }
  return {
    apply: options.has('apply'), hostname: db.hostname, port: db.port || '5432', username,
    password: decodeURIComponent(db.password), sslmode: db.searchParams.get('sslmode') || 'require',
    settings: { project_ref: FIELD_STAGING_PROJECT_REF, run_id: run, intent_id: options.get('intent'),
      player_id: options.get('player'), game_id: options.get('game'), creator_id: options.get('creator'), confirmation },
  };
}

export function reconciliationSql(config, maintenanceSql) {
  const quoted = value => `'${String(value).replaceAll("'", "''")}'`;
  const settings = Object.entries(config.settings).map(([key, value]) =>
    `select set_config('field.reconcile_${key}',${quoted(value)},true);`).join('\n');
  return `begin;\nset local statement_timeout='30s';\nset local lock_timeout='2s';\n${settings}\n${maintenanceSql}\n${config.apply ? 'commit' : 'rollback'};\n`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const config = reconciliationConfig(process.argv.slice(2), process.env);
    const sql = await readFile(new URL('./reconcile_captured_checkout.sql', import.meta.url), 'utf8');
    const result = spawnSync(process.env.PSQL_BIN || 'psql', [
      '--no-psqlrc', '--quiet', '--set=ON_ERROR_STOP=1', '--host', config.hostname,
      '--port', config.port, '--username', config.username, '--dbname', 'postgres',
    ], { input: reconciliationSql(config, sql), encoding: 'utf8', timeout: 35_000,
      env: { PATH: process.env.PATH, HOME: process.env.HOME,
        PGPASSWORD: config.password, PGSSLMODE: config.sslmode, PGCONNECT_TIMEOUT: '10' } });
    if (result.error || result.status !== 0) {
      // Do not dump the environment, connection URL or database row diagnostics.
      throw new Error('Guarded reconciliation failed or timed out; commit acknowledgement is unconfirmed. Inspect the exact intent/refund and private database diagnostics before retrying.');
    }
    console.log(`${config.apply ? 'Committed' : 'Dry run rolled back'}: verified normal-finalizer full synthetic refund for ${config.settings.intent_id}.`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : 'Guarded reconciliation failed.');
    process.exitCode = 1;
  }
}
