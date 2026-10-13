// Exercise the actual production SQL builder against a disposable database.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { buildApplySql, buildPreflightSql, buildSnapshotSql, buildVerifySql } from './deploy-launch-interest.mjs';

if (process.env.PGHOST !== '127.0.0.1' || process.env.PGDATABASE !== 'interest_release_test') {
  throw new Error('This test requires the isolated local interest_release_test database.');
}
const sql = (query) => execFileSync('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1'], {
  input: query, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'],
}).trim();
const load = (path) => readFileSync(path, 'utf8');
sql(load('supabase/scripts/launch_interest_release_fixture.sql'));
const predecessors = [
  ['20260717000000', 'create_season_zero_waitlist'],
  ['20260717000001', 'add_waitlist_age_and_position'],
  ['20260717000002', 'lower_waitlist_minimum_age'],
];
for (const [version, name] of predecessors) {
  sql(load(`supabase/migrations/${version}_${name}.sql`));
  sql(`insert into supabase_migrations.schema_migrations(version,name) values('${version}','${name}');`);
}
sql(`insert into public.season_zero_waitlist(full_name,email,interest,status,age)
  values('Existing applicant','preserved-release@example.test','SOLO_PLAYER','CONTACTED',24);`);
assert.equal(sql(buildPreflightSql()), 'f');
const snapshot = JSON.parse(sql(buildSnapshotSql()));
const migration = load('supabase/migrations/20261012000600_capture_fieldrush_launch_interest.sql');
assert.throws(() => sql(buildApplySql(migration, '0'.repeat(32))), /Command failed/);
assert.equal(sql("select to_regnamespace('fieldrush_private') is null;"), 't');
assert.equal(sql('select count(*) from supabase_migrations.schema_migrations;'), '3');
sql(buildApplySql(migration, snapshot.row_digest));
assert.equal(sql(buildVerifySql(migration)), 'verified');
assert.equal(sql(buildPreflightSql()), 't');
assert.deepEqual(JSON.parse(sql(`select jsonb_agg(to_jsonb(w) - array[
  'signup_placement','launch_updates_consented_at','launch_updates_consent_version'] order by id)
  from public.season_zero_waitlist w;`)), snapshot.rows);
assert.equal(sql("select count(*) from supabase_migrations.schema_migrations where version='20261012000600';"), '1');
assert.equal(sql("select to_regclass('fieldrush_private.accounts') is null;"), 't');
sql(load('supabase/scripts/verify_launch_interest.sql'));
assert.equal(sql('select count(*) from public.season_zero_waitlist;'), '1');
// An already-recorded migration with a missing RPC must not report success.
sql('drop function public.save_launch_update(text,text,text,text);');
assert.throws(() => sql(buildVerifySql(migration)), /Command failed/);
console.log('Interest-only production SQL, preservation, rollback, idempotent verification and signup behavior passed.');
