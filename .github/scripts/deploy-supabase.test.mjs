import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./deploy-supabase.sh', import.meta.url));
const baseEnv = {
  PATH: process.env.PATH,
  SUPABASE_ACCESS_TOKEN: 'test-placeholder',
  SUPABASE_DB_PASSWORD: 'test-placeholder',
};

test('refuses production payment cutover before invoking deployment tools', () => {
  const result = spawnSync('bash', [script, 'production', 'zjsjuuhborxrlmdcpvlj'], {
    env: baseEnv, encoding: 'utf8', timeout: 5000,
  });
  assert.equal(result.status, 64);
  assert.match(result.stderr, /Production payment cutover is not configured/);
  assert.equal(result.stdout, '');
});

test('rejects the wrong project before performing any deployment', () => {
  const result = spawnSync('bash', [script, 'staging', 'zjsjuuhborxrlmdcpvlj'], {
    env: baseEnv, encoding: 'utf8', timeout: 5000,
  });
  assert.equal(result.status, 64);
  assert.match(result.stderr, /not Field's exact staging project/);
  assert.equal(result.stdout, '');
});

test('requires sandbox keys and recovery credentials before staging migrations', () => {
  for (const extra of [
    {},
    { STRIPE_SECRET_KEY: 'sk_live_placeholder' },
    { STRIPE_RECONCILE_SECRET: 'short' },
  ]) {
    const result = spawnSync('bash', [script, 'staging', 'nfdkdhdevpstfspazbfn'], {
      env: { ...baseEnv, ...extra }, encoding: 'utf8', timeout: 5000,
    });
    assert.equal(result.status, 64);
    assert.match(result.stderr, /Stripe sandbox keys/);
    assert.equal(result.stdout, '');
  }
});
