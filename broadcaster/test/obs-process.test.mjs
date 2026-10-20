import test from 'node:test';
import assert from 'node:assert/strict';
import { obsProcessIdentity } from '../src/obs-process.mjs';

test('OBS process evidence binds the listening PID, launch time and binary', async () => {
  const run = async (cmd, args) => {
    assert.ok(args.every(arg => typeof arg === 'string'));
    if (cmd.endsWith('lsof')) return { stdout: 'p123\nf9\np123\nf10\n' };
    assert.equal(args[1], '123');
    return { stdout: 'Sun Oct 18 11:20:30 2026 /Applications/OBS.app/Contents/MacOS/OBS\n' };
  };
  assert.equal(await obsProcessIdentity(run), '123:Sun Oct 18 11:20:30 2026:/Applications/OBS.app/Contents/MacOS/OBS');
});
test('ambiguous, missing or foreign listeners never prove OBS restarted', async () => {
  for (const stdout of ['', 'p12\np13\n']) assert.equal(await obsProcessIdentity(async () => ({ stdout })), null);
  assert.equal(await obsProcessIdentity(async cmd => ({ stdout: cmd.endsWith('lsof') ? 'p123\n' : 'Sun Oct 18 11:20:30 2026 /tmp/not-obs\n' })), null);
  assert.equal(await obsProcessIdentity(async () => { throw new Error('not running'); }), null);
});
