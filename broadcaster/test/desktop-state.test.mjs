import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DesktopState } from '../src/desktop-state.mjs';
const fakeKeychain = { isEncryptionAvailable: () => true, encryptString: value => Buffer.from(value).reverse(), decryptString: value => Buffer.from(value).reverse().toString() };
test('credentials persist encrypted with restrictive file permissions', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fieldrush-state-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const store = new DesktopState(dir, fakeKeychain); await store.load();
  await store.update({ pairing: { token: 'private-device-token' } });
  const disk = await fs.readFile(path.join(dir, 'settings.enc')); assert.equal(disk.includes('private-device-token'), false);
  assert.equal((await fs.stat(path.join(dir, 'settings.enc'))).mode & 0o777, 0o600);
  const reloaded = new DesktopState(dir, fakeKeychain); await reloaded.load(); assert.equal(reloaded.value.pairing.token, 'private-device-token');
});
test('keychain unavailable never falls back to a plaintext credential file', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fieldrush-state-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const store = new DesktopState(dir, { ...fakeKeychain, isEncryptionAvailable: () => false });
  await assert.rejects(store.update({ pairing: { token: 'private' } }), /keychain/);
  assert.deepEqual(await fs.readdir(dir), []);
});
test('overlapping state saves preserve both settings and latest OBS state', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fieldrush-state-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const store = new DesktopState(dir, fakeKeychain);
  await Promise.all([store.update({ cameraId: 'usb' }), store.update({ obsState: { streaming: true } })]);
  const reloaded = new DesktopState(dir, fakeKeychain); await reloaded.load();
  assert.equal(reloaded.value.cameraId, 'usb'); assert.equal(reloaded.value.obsState.streaming, true);
});
