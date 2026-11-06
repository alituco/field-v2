import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DesktopState } from '../src/desktop-state.mjs';
import { initializeEnvironment, switchEnvironment, saveEnvironmentObsState, assertRecoveryEnvironment, assertCanForgetPairing } from '../src/desktop-environments.mjs';
import { PRODUCTION_ORIGIN, STAGING_ORIGIN } from '../src/agent-client.mjs';

const matchId = '00000000-0000-4000-8000-000000000001';
const recovery = { deviceKey: 'paired-camera', openQueueGameId: matchId, fixtureId: null,
  path: '/recordings/original.mkv', uploadUrl: 'https://upload.videodelivery.net/private-upload', uploaded: true };
function harness(initial = {}, status = {}, owned = {}) {
  const writes = [], calls = [];
  const store = { value: { workspaceId: 'workspace-staging', server: STAGING_ORIGIN, obsState: { workspaceId: 'workspace-staging' }, ...initial },
    async update(patch) { writes.push(structuredClone(patch)); this.value = { ...this.value, ...patch }; } };
  const obs = { status: async () => ({ connected: true, streaming: false, recording: false, ...status }), getState: () => owned,
    disconnect: async () => { calls.push('disconnect'); } };
  const agent = { busy: false };
  return { store, obs, agent, writes, calls,
    switch: server => switchEnvironment({ store, obs, agent, server }) };
}

test('legacy staging setup keeps its credentials, recording evidence and pending recovery', async () => {
  const evidence = { workspaceId: 'workspace-staging', recordings: [{ ...recovery }], unresolvedRecordings: [{ reason: 'lost stop response' }] };
  const h = harness({ pairing: { token: 'staging-private' }, pendingPair: { token: 'pending-private' }, recovery, obsState: evidence });
  await initializeEnvironment(h.store);
  for (const key of ['pairing', 'pendingPair', 'recovery']) assert.equal(h.store.value[key].server, STAGING_ORIGIN);
  assert.equal(h.store.value.pairing.token, 'staging-private');
  assert.equal(h.store.value.pendingPair.token, 'pending-private');
  assert.deepEqual(h.store.value.obsState, evidence);
  assert.equal(h.store.value.recovery.uploadUrl, recovery.uploadUrl);
});

test('legacy production credentials and invalid saved origins fail without overwriting evidence', async () => {
  for (const server of [PRODUCTION_ORIGIN, 'https://evil.example']) {
    const h = harness({ server, pairing: { token: 'legacy-private' }, recovery });
    const before = structuredClone(h.store.value);
    await assert.rejects(initializeEnvironment(h.store));
    assert.deepEqual(h.store.value, before);
    assert.equal(h.writes.length, 0);
  }
  const local = harness({ server: 'http://localhost:3000', pairing: { token: 'local-private' } });
  await assert.rejects(initializeEnvironment(local.store));
  await initializeEnvironment(local.store, true);
  assert.equal(local.store.value.pairing.server, 'http://localhost:3000');
});

test('switching creates a separate production workspace and restores staging evidence on return', async () => {
  const h = harness({ cameraId: 'usb-camera', obsPassword: 'local-obs-password', recordingDirectory: '/recordings',
    recovery, pendingPair: { code: 'ABCDEFGHJKLM', token: 'staging-pending' },
    pendingAck: { commandId: 'staging-ack' }, lastCommand: { commandId: 'staging-command' },
    lastStreamTest: '2026-01-01', lastLocalTest: '2026-01-01',
    obsState: { workspaceId: 'workspace-staging', recordings: [recovery], unresolvedRecordings: [{ reason: 'unconfirmed' }] } });
  await initializeEnvironment(h.store);
  const original = structuredClone(h.store.value);
  assert.equal(await h.switch(PRODUCTION_ORIGIN), true);
  const productionWorkspace = h.store.value.workspaceId;
  assert.notEqual(productionWorkspace, original.workspaceId);
  for (const key of ['pairing', 'pendingPair', 'pendingAck', 'lastCommand', 'lastStreamTest', 'lastLocalTest', 'recovery']) assert.equal(h.store.value[key], null);
  assert.deepEqual(h.store.value.obsState, { workspaceId: productionWorkspace });
  assert.equal(h.store.value.cameraId, 'usb-camera');
  assert.equal(h.store.value.obsPassword, 'local-obs-password');
  assert.equal(h.store.value.recordingDirectory, '/recordings');
  await h.store.update({ recordingDirectory: '/production-recordings', cameraId: 'production-camera', microphoneId: 'production-mic' });
  await saveEnvironmentObsState(h.store, PRODUCTION_ORIGIN, { workspaceId: productionWorkspace, recordings: [{ ...recovery, path: '/recordings/prod.mkv' }] });
  await h.switch(STAGING_ORIGIN);
  for (const key of ['workspaceId', 'obsState', 'pendingPair', 'pendingAck', 'lastCommand', 'lastStreamTest', 'lastLocalTest', 'recovery']) assert.deepEqual(h.store.value[key], original[key]);
  assert.equal(h.store.value.recordingDirectory, '/recordings');
  assert.equal(h.store.value.cameraId, 'usb-camera');
  assert.equal(h.store.value.microphoneId, null);
  await h.switch(PRODUCTION_ORIGIN);
  assert.equal(h.store.value.workspaceId, productionWorkspace);
  assert.equal(h.store.value.obsState.recordings[0].path, '/recordings/prod.mkv');
  assert.equal(h.store.value.recovery, null);
  assert.equal(h.store.value.recordingDirectory, '/production-recordings');
  assert.equal(h.store.value.cameraId, 'production-camera');
  assert.equal(h.store.value.microphoneId, 'production-mic');
});

test('late OBS events update only their original environment', async () => {
  const h = harness(); await initializeEnvironment(h.store);
  await h.switch(PRODUCTION_ORIGIN);
  const current = structuredClone(h.store.value.obsState);
  const late = { workspaceId: 'workspace-staging', unresolvedRecordings: [{ reason: 'late recording stop' }] };
  await saveEnvironmentObsState(h.store, STAGING_ORIGIN, late);
  assert.deepEqual(h.store.value.obsState, current);
  await h.switch(STAGING_ORIGIN);
  assert.deepEqual(h.store.value.obsState, late);
});

test('pairing, active output and unresolved ownership block switching without disconnecting', async () => {
  const cases = [
    [{ pairing: { server: STAGING_ORIGIN, token: 'private' } }, {}, {}],
    [{}, { streaming: true }, {}], [{}, { recording: true }, {}],
    ...['target', 'testStream', 'localTest', 'recordingOwned', 'streamingOwned', 'outputSessionId', 'recordIntent', 'streamIntent'].map(key => [{}, {}, { [key]: true }]),
  ];
  for (const [initial, status, owned] of cases) {
    for (const connected of [true, false]) {
      const h = harness(initial, { ...status, connected }, owned);
      await assert.rejects(h.switch(PRODUCTION_ORIGIN), /pairing|stop the video/);
      assert.equal(h.store.value.server, STAGING_ORIGIN);
      assert.deepEqual(h.calls, []); assert.deepEqual(h.writes, []);
    }
  }
  const h = harness(); h.agent.busy = true;
  await assert.rejects(h.switch(PRODUCTION_ORIGIN), /current camera operation/);
  assert.deepEqual(h.calls, []);
});

test('failed persistence leaves the original active environment and credentials intact', async () => {
  const h = harness({ recovery: { ...recovery, server: STAGING_ORIGIN }, environmentVersion: 1 });
  const before = structuredClone(h.store.value);
  h.store.update = async patch => { h.store.value = { ...h.store.value, ...patch }; throw new Error('Keychain locked'); };
  await assert.rejects(h.switch(PRODUCTION_ORIGIN), /Keychain locked/);
  assert.deepEqual(h.store.value, before);
});

test('profile recovery remains isolated across encrypted application restart', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fieldrush-environments-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const keychain = { isEncryptionAvailable: () => true, encryptString: value => Buffer.from(value).reverse(), decryptString: value => Buffer.from(value).reverse().toString() };
  const store = new DesktopState(dir, keychain);
  await store.update({ recovery, obsPassword: 'local-only' });
  await initializeEnvironment(store);
  const original = structuredClone(store.value);
  const h = harness();
  await switchEnvironment({ store, obs: h.obs, agent: h.agent, server: PRODUCTION_ORIGIN });
  const reloaded = new DesktopState(dir, keychain); await reloaded.load(); await initializeEnvironment(reloaded);
  assert.equal(reloaded.value.server, PRODUCTION_ORIGIN);
  assert.equal(reloaded.value.recovery, null);
  await switchEnvironment({ store: reloaded, obs: h.obs, agent: h.agent, server: STAGING_ORIGIN });
  assert.deepEqual(reloaded.value.recovery, original.recovery);
  assert.equal(reloaded.value.workspaceId, original.workspaceId);
});

test('recovery checks origin, device and match even when both environments use identical IDs', () => {
  const paired = { server: PRODUCTION_ORIGIN, deviceKey: recovery.deviceKey, matchKind: 'SOLO', matchId };
  assert.throws(() => assertRecoveryEnvironment({ ...recovery, server: STAGING_ORIGIN }, PRODUCTION_ORIGIN, paired), /different environment/);
  assert.throws(() => assertRecoveryEnvironment(recovery, PRODUCTION_ORIGIN, paired), /different environment/);
  const pending = { ...recovery, server: PRODUCTION_ORIGIN };
  assert.doesNotThrow(() => assertRecoveryEnvironment(pending, PRODUCTION_ORIGIN, paired));
  for (const patch of [{ server: STAGING_ORIGIN }, { deviceKey: 'other-camera' }, { matchId: 'other-match' }, { matchKind: 'CLAN' }]) {
    assert.throws(() => assertRecoveryEnvironment(pending, PRODUCTION_ORIGIN, { ...paired, ...patch }), /different paired match/);
  }
});

test('a pending recovery keeps its original pairing capability until completed or explicitly abandoned', () => {
  for (const uploaded of [false, true]) {
    const value = { pairing: { server: STAGING_ORIGIN, token: 'original-private-token' }, recovery: { ...recovery, uploaded } };
    assert.throws(() => assertCanForgetPairing(value), /Finish recording recovery/);
    assert.equal(value.pairing.token, 'original-private-token');
    assert.equal(value.recovery.uploadUrl, recovery.uploadUrl);
  }
  assert.doesNotThrow(() => assertCanForgetPairing({ pairing: {}, recovery: null }));
});
