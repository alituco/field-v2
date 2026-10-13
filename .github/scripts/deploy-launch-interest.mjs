import { createCipheriv, createDecipheriv, createHash, randomBytes, scryptSync } from 'node:crypto';
import { deepStrictEqual } from 'node:assert';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROJECT_REF = 'zjsjuuhborxrlmdcpvlj';
export const MIGRATION_VERSION = '20261012000600';
export const MIGRATION_NAME = 'capture_fieldrush_launch_interest';
export const MIGRATION_SHA256 = '3e7c035d0e7976317234d9ae04ad925b99439cc282c8145f627468b5533f9f56';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const migrationFile = resolve(root, `supabase/migrations/${MIGRATION_VERSION}_${MIGRATION_NAME}.sql`);
const addedColumns = ['signup_placement', 'launch_updates_consented_at', 'launch_updates_consent_version'];
const literal = (value) => `'${String(value).replaceAll("'", "''")}'`;

export function validateEnvironment(env, apply = false, repoRoot = root) {
  if (env.EXPECTED_PROJECT_REF !== PROJECT_REF) throw new Error('EXPECTED_PROJECT_REF must be the exact production project.');
  if (!env.SUPABASE_ACCESS_TOKEN?.trim()) throw new Error('SUPABASE_ACCESS_TOKEN is required.');
  if (!apply) return;
  if (env.GITHUB_EVENT_NAME !== 'workflow_dispatch' || env.GITHUB_REF !== 'refs/heads/prod') {
    throw new Error('Apply requires a manual workflow dispatch from prod.');
  }
  if (env.RELEASE_CONFIRMATION !== 'DEPLOY_INTEREST_ONLY') throw new Error('Interest-only release confirmation is required.');
  if (!env.SUPABASE_DB_PASSWORD?.trim()) throw new Error('SUPABASE_DB_PASSWORD is required for backup encryption.');
  const path = env.BACKUP_PATH;
  if (!path || !isAbsolute(path) || !path.endsWith('.enc')) throw new Error('BACKUP_PATH must be an absolute .enc path outside the repository.');
  const rel = relative(resolve(repoRoot), resolve(path));
  if (!rel.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`)) {
    throw new Error('BACKUP_PATH must be outside the repository.');
  }
}

export function validateExactMigration(sql) {
  if (createHash('sha256').update(sql).digest('hex') !== MIGRATION_SHA256) {
    throw new Error('The interest migration does not match the reviewed SHA-256.');
  }
  return sql;
}

// Management API bodies can contain contact details or credentials in an error.
// Neither failed response bodies nor network exception messages are surfaced.
export async function queryManagement(sql, token, fetcher = fetch) {
  let response;
  try {
    response = await fetcher(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: sql }),
      signal: AbortSignal.timeout(120_000),
    });
  } catch {
    throw new Error('Production database request could not be confirmed. Inspect the schema before rerunning; no automatic retry was made.');
  }
  if (!response.ok) throw new Error(`Production database request failed (HTTP ${response.status}); response details withheld. No automatic retry was made.`);
  try {
    const result = await response.json();
    if (!Array.isArray(result)) throw new Error();
    return result;
  } catch {
    throw new Error('Production database returned an unexpected response; inspect before rerunning.');
  }
}

function prerequisiteAssertions() {
  return `
  if to_regclass('public.season_zero_waitlist') is null
    or to_regclass('supabase_migrations.schema_migrations') is null then
    raise exception 'Required waitlist or migration history is missing';
  end if;
  if (select count(*) from supabase_migrations.schema_migrations where version in
    ('20260717000000','20260717000001','20260717000002')) <> 3 then
    raise exception 'Required July waitlist migrations are missing';
  end if;
  if (select count(*) from information_schema.columns where table_schema='public'
    and table_name='season_zero_waitlist' and column_name in
    ('id','full_name','email','phone','interest','source','status','created_at','updated_at','age','preferred_position')) <> 11 then
    raise exception 'Required waitlist columns are missing';
  end if;
  if not exists (select 1 from pg_index i join pg_class c on c.oid=i.indexrelid
    where i.indrelid='public.season_zero_waitlist'::regclass and i.indisunique and i.indisvalid
    and i.indpred is null and pg_get_indexdef(i.indexrelid, 1, true)='lower(email)' and i.indnkeyatts=1) then
    raise exception 'Required case-insensitive email unique index is missing';
  end if;
  if (select count(*) from pg_constraint where conrelid='public.season_zero_waitlist'::regclass
    and convalidated and conname in ('season_zero_waitlist_interest_check','season_zero_waitlist_source_check',
      'season_zero_waitlist_age_check','season_zero_waitlist_preferred_position_check')) <> 4 then
    raise exception 'Required waitlist constraints are missing';
  end if;
  if not exists (select 1 from pg_class where oid='public.season_zero_waitlist'::regclass and relrowsecurity)
    or has_table_privilege('anon','public.season_zero_waitlist','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    or has_table_privilege('authenticated','public.season_zero_waitlist','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    or not has_table_privilege('service_role','public.season_zero_waitlist','SELECT')
    or not has_table_privilege('service_role','public.season_zero_waitlist','INSERT')
    or not has_table_privilege('service_role','public.season_zero_waitlist','UPDATE') then
    raise exception 'Waitlist access controls differ from the reviewed private-list boundary';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid='public.season_zero_waitlist'::regclass
    and not tgisinternal and tgenabled in ('O','A') and tgfoid=to_regprocedure('public.set_updated_at()')) then
    raise exception 'Waitlist update timestamp trigger is missing';
  end if;`;
}

export function buildPreflightSql() {
  return `do $preflight$ begin
${prerequisiteAssertions()}
  if not exists (select 1 from supabase_migrations.schema_migrations where version='${MIGRATION_VERSION}') then
    if exists (select 1 from information_schema.columns where table_schema='public'
      and table_name='season_zero_waitlist' and column_name in (${addedColumns.map(literal).join(',')}))
      or to_regclass('fieldrush_private.launch_update_rate_limits') is not null
      or to_regprocedure('public.save_launch_update(text,text,text,text)') is not null
      or to_regprocedure('public.save_waitlist_application(text,text,text,integer,text,text)') is not null then
      raise exception 'Partial interest rollout found without migration history; inspect before continuing';
    end if;
  end if;
end $preflight$;
select exists (select 1 from supabase_migrations.schema_migrations
  where version='${MIGRATION_VERSION}') as already_applied;`;
}

export function buildVerifySql(migrationSql) {
  validateExactMigration(migrationSql);
  const functions = [...migrationSql.matchAll(/create function public\.(\w+)\([\s\S]*?as \$\$([\s\S]*?)\$\$;/g)];
  if (functions.length !== 2) throw new Error('Expected exactly two reviewed signup functions.');
  const signatures = ['public.save_launch_update(text,text,text,text)', 'public.save_waitlist_application(text,text,text,integer,text,text)'];
  const fnAssertions = functions.map((entry, index) => `
  if not exists (select 1 from pg_proc where oid=to_regprocedure(${literal(signatures[index])})
    and prosrc=${literal(entry[2])} and prosecdef
    and proconfig @> array['search_path=pg_catalog'])
    or has_function_privilege('anon',${literal(signatures[index])},'EXECUTE')
    or has_function_privilege('authenticated',${literal(signatures[index])},'EXECUTE')
    or not has_function_privilege('service_role',${literal(signatures[index])},'EXECUTE') then
    raise exception 'Signup function definition or access control differs from the reviewed migration';
  end if;`).join('');
  return `do $verify$ begin
${prerequisiteAssertions()}
  if not exists (select 1 from supabase_migrations.schema_migrations
    where version='${MIGRATION_VERSION}' and name='${MIGRATION_NAME}') then
    raise exception 'Expected interest migration history is missing';
  end if;
  if (select count(*) from information_schema.columns where table_schema='public'
    and table_name='season_zero_waitlist' and column_name in (${addedColumns.map(literal).join(',')})) <> 3
    or not exists (select 1 from information_schema.columns where table_schema='public'
      and table_name='season_zero_waitlist' and column_name='full_name' and is_nullable='YES') then
    raise exception 'Interest list columns are incomplete';
  end if;
  if (select count(*) from pg_constraint where conrelid='public.season_zero_waitlist'::regclass
    and convalidated and conname in ('season_zero_waitlist_applicant_name_check',
      'season_zero_waitlist_launch_consent_check','season_zero_waitlist_launch_interest_check')) <> 3 then
    raise exception 'Interest consent constraints are incomplete';
  end if;
  if to_regclass('fieldrush_private.launch_update_rate_limits') is null then
    raise exception 'Private signup rate limiter is missing';
  end if;
  if (select count(*) from information_schema.columns where table_schema='fieldrush_private'
    and table_name='launch_update_rate_limits' and is_nullable='NO' and
    ((column_name='rate_identity' and data_type='text') or
      (column_name='window_started_at' and data_type='timestamp with time zone') or
      (column_name='request_count' and data_type='smallint'))) <> 3
    or not exists (select 1 from pg_constraint where conrelid='fieldrush_private.launch_update_rate_limits'::regclass
      and contype='p' and pg_get_constraintdef(oid)='PRIMARY KEY (rate_identity)')
    or (select count(*) from pg_constraint where conrelid='fieldrush_private.launch_update_rate_limits'::regclass
      and convalidated and contype='c') <> 2 then
    raise exception 'Private signup rate limiter structure is incomplete';
  end if;
  if not exists (select 1 from pg_class where oid='fieldrush_private.launch_update_rate_limits'::regclass and relrowsecurity)
    or has_schema_privilege('anon','fieldrush_private','USAGE')
    or has_schema_privilege('authenticated','fieldrush_private','USAGE')
    or has_table_privilege('anon','fieldrush_private.launch_update_rate_limits','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    or has_table_privilege('authenticated','fieldrush_private.launch_update_rate_limits','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    or has_table_privilege('service_role','fieldrush_private.launch_update_rate_limits','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
    raise exception 'Private signup rate limiter access controls are incorrect';
  end if;
${fnAssertions}
end $verify$;
select 'verified' as status;`;
}

export function buildSnapshotSql() {
  return `select jsonb_build_object(
    'project_ref', '${PROJECT_REF}', 'migration_version', '${MIGRATION_VERSION}',
    'captured_at', now(),
    'rows', coalesce((select jsonb_agg(to_jsonb(w) order by id) from public.season_zero_waitlist w),'[]'::jsonb),
    'row_digest', (select md5(coalesce(jsonb_agg(to_jsonb(w) order by id),'[]'::jsonb)::text) from public.season_zero_waitlist w),
    'columns', (select jsonb_agg(to_jsonb(c)) from information_schema.columns c where table_schema='public' and table_name='season_zero_waitlist'),
    'constraints', (select jsonb_agg(jsonb_build_object('name',conname,'definition',pg_get_constraintdef(oid))) from pg_constraint where conrelid='public.season_zero_waitlist'::regclass),
    'indexes', (select jsonb_agg(indexdef) from pg_indexes where schemaname='public' and tablename='season_zero_waitlist'),
    'triggers', (select jsonb_agg(pg_get_triggerdef(oid)) from pg_trigger where tgrelid='public.season_zero_waitlist'::regclass and not tgisinternal),
    'table_access', (select jsonb_build_object('owner',pg_get_userbyid(relowner),'acl',relacl,'rls',relrowsecurity)
      from pg_class where oid='public.season_zero_waitlist'::regclass),
    'migration_history', (select jsonb_agg(to_jsonb(m)) from supabase_migrations.schema_migrations m)
  ) as snapshot;`;
}

export function encryptSnapshot(snapshot, password) {
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const key = scryptSync(password, salt, 32);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(snapshot), 'utf8'), cipher.final()]);
  return JSON.stringify({ format: 'fieldrush-interest-backup-v1', algorithm: 'aes-256-gcm', kdf: 'scrypt',
    salt: salt.toString('base64'), iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), ciphertext: ciphertext.toString('base64') });
}

export function decryptSnapshot(encrypted, password) {
  const data = JSON.parse(encrypted);
  if (data.format !== 'fieldrush-interest-backup-v1' || data.algorithm !== 'aes-256-gcm' || data.kdf !== 'scrypt') {
    throw new Error('Unrecognized encrypted backup format.');
  }
  const key = scryptSync(password, Buffer.from(data.salt, 'base64'), 32);
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(data.iv, 'base64'));
  decipher.setAuthTag(Buffer.from(data.tag, 'base64'));
  return JSON.parse(Buffer.concat([decipher.update(Buffer.from(data.ciphertext, 'base64')), decipher.final()]).toString('utf8'));
}

export function buildApplySql(migrationSql, rowDigest) {
  validateExactMigration(migrationSql);
  if (!/^[a-f0-9]{32}$/.test(rowDigest)) throw new Error('A valid snapshot row digest is required.');
  return `begin;
set local lock_timeout = '10s';
set local statement_timeout = '60s';
select pg_advisory_xact_lock(hashtextextended('fieldrush-production-launch-interest',0));
lock table public.season_zero_waitlist in access exclusive mode;
${buildPreflightSql()}
do $guard$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version='${MIGRATION_VERSION}') then
    raise exception 'Interest migration was applied concurrently; verify before rerunning';
  end if;
  if (select md5(coalesce(jsonb_agg(to_jsonb(w) order by id),'[]'::jsonb)::text) from public.season_zero_waitlist w) <> '${rowDigest}' then
    raise exception 'Waitlist changed after backup; take a fresh backup before applying';
  end if;
end $guard$;
create temporary table launch_interest_preimage on commit drop as select to_jsonb(w) as row_data from public.season_zero_waitlist w;
create schema if not exists fieldrush_private;
revoke all on schema fieldrush_private from public, anon, authenticated;
${migrationSql}
do $preserve$ begin
  if exists (
    (select row_data from launch_interest_preimage except
     select to_jsonb(w) - array[${addedColumns.map(literal).join(',')}] from public.season_zero_waitlist w)
    union all
    (select to_jsonb(w) - array[${addedColumns.map(literal).join(',')}] from public.season_zero_waitlist w except
     select row_data from launch_interest_preimage)
  ) then raise exception 'Existing waitlist records changed; rolling back'; end if;
end $preserve$;
insert into supabase_migrations.schema_migrations (version, name, statements)
values ('${MIGRATION_VERSION}','${MIGRATION_NAME}',array[${literal(migrationSql)}]);
${buildVerifySql(migrationSql)}
notify pgrst, 'reload schema';
commit;
select 'applied_and_verified' as status;`;
}

export async function main(args = process.argv.slice(2), env = process.env) {
  if (args.length !== 1 || !['--check', '--apply'].includes(args[0])) throw new Error('Use --check or --apply.');
  const apply = args[0] === '--apply';
  validateEnvironment(env, apply);
  const migrationSql = validateExactMigration(await readFile(migrationFile, 'utf8'));
  const preflight = await queryManagement(buildPreflightSql(), env.SUPABASE_ACCESS_TOKEN);
  if (preflight.length !== 1 || typeof preflight[0].already_applied !== 'boolean') throw new Error('Preflight did not return a recognizable migration state.');
  if (preflight[0].already_applied) {
    await queryManagement(buildVerifySql(migrationSql), env.SUPABASE_ACCESS_TOKEN);
    console.log('Interest-only migration is already applied and its schema and permissions are verified.');
    return;
  }
  if (!apply) {
    console.log('Production prerequisites passed. The reviewed interest-only migration is pending.');
    return;
  }
  const result = await queryManagement(buildSnapshotSql(), env.SUPABASE_ACCESS_TOKEN);
  const snapshot = result[0]?.snapshot;
  if (result.length !== 1 || !Array.isArray(snapshot?.rows) || !/^[a-f0-9]{32}$/.test(snapshot?.row_digest ?? '')) {
    throw new Error('Could not obtain a complete private waitlist backup.');
  }
  await mkdir(dirname(env.BACKUP_PATH), { recursive: true, mode: 0o700 });
  await writeFile(env.BACKUP_PATH, encryptSnapshot(snapshot, env.SUPABASE_DB_PASSWORD), { mode: 0o600, flag: 'wx' });
  try {
    deepStrictEqual(decryptSnapshot(await readFile(env.BACKUP_PATH, 'utf8'), env.SUPABASE_DB_PASSWORD), snapshot);
  } catch {
    throw new Error('Encrypted backup verification failed; no migration was attempted.');
  }
  console.log('Encrypted waitlist backup saved and verified outside the repository.');
  await queryManagement(buildApplySql(migrationSql, snapshot.row_digest), env.SUPABASE_ACCESS_TOKEN);
  await queryManagement(buildVerifySql(migrationSql), env.SUPABASE_ACCESS_TOKEN);
  console.log('Production interest-only migration applied. Existing records, schema, and private access controls verified.');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
