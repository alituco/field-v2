import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import test from 'node:test';
import {
  PROJECT_REF, MIGRATION_VERSION, validateEnvironment, validateExactMigration,
  buildPreflightSql, buildApplySql, buildVerifySql, queryManagement,
  encryptSnapshot, decryptSnapshot, main,
} from './deploy-launch-interest.mjs';

const migration = await readFile(new URL('../../supabase/migrations/20261012000600_capture_fieldrush_launch_interest.sql', import.meta.url), 'utf8');
const validEnv = {
  EXPECTED_PROJECT_REF: PROJECT_REF, SUPABASE_ACCESS_TOKEN: 'test-token',
  SUPABASE_DB_PASSWORD: 'synthetic-backup-password',
  GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/prod',
  RELEASE_CONFIRMATION: 'DEPLOY_INTEREST_ONLY', BACKUP_PATH: '/tmp/interest-test.enc',
};

test('apply gates require exact production target, manual prod dispatch, and explicit scope', () => {
  validateEnvironment(validEnv, true);
  for (const [key, value] of [
    ['EXPECTED_PROJECT_REF','nfdkdhdevpstfspazbfn'], ['EXPECTED_PROJECT_REF',''],
    ['SUPABASE_ACCESS_TOKEN',''], ['SUPABASE_DB_PASSWORD',''],
    ['GITHUB_EVENT_NAME','push'], ['GITHUB_EVENT_NAME','pull_request'],
    ['GITHUB_REF','refs/heads/staging'], ['GITHUB_REF','refs/pull/1/merge'],
    ['RELEASE_CONFIRMATION','DEPLOY_ALL'], ['BACKUP_PATH','relative.enc'],
    ['BACKUP_PATH','/tmp/interest-test.json'],
    ['BACKUP_PATH',resolve('.github/interest-test.enc')],
  ]) assert.throws(() => validateEnvironment({ ...validEnv, [key]: value }, true), undefined, key);
});

test('read-only check does not require deployment gates or backup secret', () => {
  validateEnvironment({ EXPECTED_PROJECT_REF: PROJECT_REF, SUPABASE_ACCESS_TOKEN: 'test-token' });
});

test('only the exact reviewed migration may be assembled for deployment', () => {
  assert.equal(validateExactMigration(migration), migration);
  for (const altered of [migration + '\n', migration.replace('LAUNCH_UPDATES','OTHER'), 'select 1;']) {
    assert.throws(() => validateExactMigration(altered), /SHA-256/);
    assert.throws(() => buildApplySql(altered, 'a'.repeat(32)), /SHA-256/);
  }
  assert.throws(() => buildApplySql(migration, "'; drop table profiles;--"), /digest/);
});

test('transaction includes snapshot consistency, row preservation, exact history, and postchecks before commit', () => {
  const sql = buildApplySql(migration, 'a'.repeat(32));
  assert.match(sql, /^begin;/);
  assert.match(sql, /lock table public\.season_zero_waitlist in access exclusive mode/);
  assert.match(sql, /Waitlist changed after backup/);
  assert.match(sql, /create temporary table launch_interest_preimage on commit drop/);
  assert.match(sql, /Existing waitlist records changed; rolling back/);
  assert.match(sql, /create schema if not exists fieldrush_private/);
  assert.equal((sql.match(/insert into supabase_migrations\.schema_migrations/g) ?? []).length, 1);
  assert.ok(sql.includes(`values ('${MIGRATION_VERSION}','capture_fieldrush_launch_interest'`));
  assert.ok(sql.indexOf('Expected interest migration history is missing') < sql.lastIndexOf('commit;'));
  assert.doesNotMatch(sql, /alter table public\.(profiles|bookings|matches)|create table fieldrush_private\.accounts|supabase db push/);
});

test('preflight catches partial rollout and verify checks actual definitions rather than history alone', () => {
  assert.match(buildPreflightSql(), /Partial interest rollout found without migration history/);
  assert.match(buildPreflightSql(), /Required July waitlist migrations are missing/);
  const verify = buildVerifySql(migration);
  assert.match(verify, /prosrc=/);
  assert.match(verify, /search_path=pg_catalog/);
  assert.match(verify, /Signup function definition or access control/);
  assert.match(verify, /Private signup rate limiter is missing/);
  assert.match(verify, /has_function_privilege\('anon'/);
});

test('backup encryption roundtrips privately and detects wrong keys or modified ciphertext', () => {
  const snapshot = { rows: [{ email: 'private-person@example.test', phone: '+15555550100' }] };
  const encrypted = encryptSnapshot(snapshot, 'password-one');
  assert.doesNotMatch(encrypted, /private-person|15555550100|password-one/);
  assert.deepEqual(decryptSnapshot(encrypted, 'password-one'), snapshot);
  assert.notEqual(encryptSnapshot(snapshot, 'password-one'), encrypted);
  assert.throws(() => decryptSnapshot(encrypted, 'wrong-password'));
  const corrupted = JSON.parse(encrypted);
  corrupted.tag = Buffer.alloc(16).toString('base64');
  assert.throws(() => decryptSnapshot(JSON.stringify(corrupted), 'password-one'));
});

test('management transport uses only guarded project and withholds error bodies and exceptions', async () => {
  let calls = 0;
  await assert.rejects(queryManagement('select 1', 'secret-value', async (url, init) => {
    calls++;
    assert.equal(url, `https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`);
    assert.equal(init.headers.Authorization, 'Bearer secret-value');
    assert.deepEqual(JSON.parse(init.body), { query: 'select 1' });
    return { ok: false, status: 400, text: async () => 'private-person@example.test secret-value' };
  }), (error) => /HTTP 400/.test(error.message) && !/private-person|secret-value/.test(error.message));
  assert.equal(calls, 1);
  await assert.rejects(queryManagement('select 1', 'secret-value', async () => {
    throw new Error('secret-value private-person@example.test');
  }), (error) => /no automatic retry/i.test(error.message) && !/private-person|secret-value/.test(error.message));
  await assert.rejects(queryManagement('select 1', 'secret-value', async () => ({
    ok: true, json: async () => ({ error: 'private-person@example.test' }),
  })), /unexpected response/);
});

test('apply saves a verified mode600 encrypted backup before sending transaction; idempotent rerun verifies', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'interest-unit-'));
  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const messages = [];
  const snapshot = { rows: [{ id: 'synthetic', email: 'private@example.test' }], row_digest: 'a'.repeat(32) };
  let calls = 0;
  const backupPath = join(directory, 'backup.enc');
  try {
    console.log = (line) => messages.push(line);
    globalThis.fetch = async (_url, init) => {
      const sql = JSON.parse(init.body).query;
      calls++;
      if (calls === 1) return { ok: true, json: async () => [{ already_applied: false }] };
      if (calls === 2) return { ok: true, json: async () => [{ snapshot }] };
      if (calls === 3) {
        assert.match(sql, /^begin;/);
        const encrypted = await readFile(backupPath, 'utf8');
        assert.deepEqual(decryptSnapshot(encrypted, validEnv.SUPABASE_DB_PASSWORD), snapshot);
        assert.equal((await stat(backupPath)).mode & 0o777, 0o600);
      }
      return { ok: true, json: async () => [{ status: 'verified' }] };
    };
    await main(['--apply'], { ...validEnv, BACKUP_PATH: backupPath });
    assert.equal(calls, 4);
    assert.doesNotMatch(messages.join('\n'), /private@example\.test|synthetic-backup-password|test-token/);
    calls = 0;
    globalThis.fetch = async (_url, init) => {
      calls++;
      if (calls === 1) return { ok: true, json: async () => [{ already_applied: true }] };
      assert.match(JSON.parse(init.body).query, /Signup function definition or access control/);
      return { ok: true, json: async () => [{ status: 'verified' }] };
    };
    await main(['--apply'], { ...validEnv, BACKUP_PATH: backupPath });
    assert.equal(calls, 2);
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    await rm(directory, { recursive: true, force: true });
  }
});
