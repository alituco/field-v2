import test from 'node:test';
import assert from 'node:assert/strict';
import { AgentClient, serverOrigin, safeMessage } from '../src/agent-client.mjs';

const matchId = '00000000-0000-4000-8000-000000000001';
const session = { deviceKey: 'camera-1', matchKind: 'SOLO', matchId, expiresAt: '2099-01-01T00:00:00Z', displayName: 'Field Mac' };
function harness({ failures = {}, command = null, initial = {}, status = {} } = {}) {
  const calls = [], writes = [], obsCalls = [];
  const store = { value: { server: 'https://ops-staging.field.bh', pairing: { ...session, token: 'x'.repeat(43) }, ...initial }, async update(patch) { writes.push(structuredClone(patch)); this.value = { ...this.value, ...patch }; } };
  const obs = {
    async status() { return { connected: true, configured: true, cameraAvailable: true, microphoneAvailable: true, streaming: false, recording: false, ...status }; },
    async start(c) { obsCalls.push(['start', c]); }, async stop(c) { obsCalls.push(['stop', c]); }, async stopCurrent() { obsCalls.push(['stopCurrent']); },
  };
  const fetcher = async (url, options) => {
    const pathname = new URL(url).pathname;
    calls.push({ pathname, ...options, body: options.body ? JSON.parse(options.body) : null });
    if (failures[pathname]) return new Response(JSON.stringify({ error: 'Temporarily unavailable' }), { status: failures[pathname] });
    const value = pathname.endsWith('/session') || pathname.endsWith('/pair') ? session : pathname.endsWith('/commands') && options.method === 'GET' ? { command } : { ok: true };
    return new Response(JSON.stringify(value));
  };
  const client = new AgentClient({ store, obs, fetcher });
  return { client, calls, store, obsCalls, writes, failures, obs };
}
test('origin allowlist prevents credential exfiltration and redirect following', async () => {
  for (const value of ['https://evil.example', 'https://ops-staging.field.bh.evil.example', 'https://ops-staging.field.bh/path', 'https://user@ops-staging.field.bh', 'http://127.0.0.1:3000']) assert.throws(() => serverOrigin(value));
  assert.equal(serverOrigin('http://127.0.0.1:3000', true), 'http://127.0.0.1:3000');
  const h = harness(); await h.client.tick();
  assert.ok(h.calls.every(call => call.redirect === 'error' && call.signal instanceof AbortSignal));
});
test('missing broadcaster routes explain the selected server deployment mismatch without exposing HTML', async () => {
  const h = harness();
  h.client.fetcher = async () => new Response('<html><title>404</title>private-response-value https://private.example/secret</html>', { status: 404 });
  for (const pathname of ['/api/broadcast-agent/pair', '/api/broadcast-agent/session', '/api/broadcast-agent/commands?deviceKey=camera-1']) {
    await assert.rejects(h.client.request(pathname), error => {
      assert.equal(error.status, 404);
      assert.match(error.message, /Broadcaster support is not deployed on the selected server/);
      assert.match(error.message, /Update the referee server or use Local development/);
      assert.doesNotMatch(error.message, /private-response-value|private\.example|secret|<html>/);
      return true;
    });
  }
});
test('other malformed responses retain their HTTP status without exposing their body', async () => {
  const h = harness();
  for (const status of [200, 401, 403, 404, 503]) {
    h.client.fetcher = async () => new Response('private-response-value', { status });
    await assert.rejects(h.client.request('/api/other'), error => {
      assert.equal(error.status, status);
      assert.equal(error.message, 'Fieldrush is unavailable. Try again shortly.');
      return true;
    });
  }
  h.client.fetcher = async () => new Response('private-response-value'.repeat(5_000), { status: 502 });
  await assert.rejects(h.client.request('/api/broadcast-agent/pair'), error => {
    assert.equal(error.status, 502);
    assert.equal(error.message, 'Fieldrush returned an invalid response.');
    return true;
  });
});
test('JSON API errors keep their existing message and HTTP status', async () => {
  const h = harness();
  h.client.fetcher = async () => new Response(JSON.stringify({ error: 'Pairing code is invalid or expired.' }), { status: 404 });
  await assert.rejects(h.client.request('/api/broadcast-agent/pair'), error => {
    assert.equal(error.status, 404);
    assert.equal(error.message, 'Pairing code is invalid or expired.');
    return true;
  });
});
test('wrong match commands never touch OBS', async () => {
  const h = harness({ command: { id: '1', action: 'START_STREAM', fixtureId: matchId, openQueueGameId: null } });
  await h.client.tick(); assert.equal(h.obsCalls.length, 0); assert.match(h.client.error, /different match/);
});
test('lost acknowledgment retries saved outcome without executing the command twice', async () => {
  const command = { id: 'c1', action: 'START_STREAM', openQueueGameId: matchId, fixtureId: null };
  const h = harness({ command });
  const request = h.client.request.bind(h.client);
  let dropped = true;
  h.client.request = async (url, init) => { if (url.endsWith('/commands') && init?.method === 'POST' && dropped) { dropped = false; throw new Error('Network offline'); } return request(url, init); };
  await h.client.tick();
  assert.equal(h.obsCalls.length, 1); assert.equal(h.store.value.pendingAck.commandId, 'c1');
  await h.client.tick();
  assert.equal(h.obsCalls.length, 1); assert.equal(h.store.value.pendingAck, null);
  assert.ok(h.writes.some(write => write.pendingAck?.commandId === 'c1' && write.lastCommand?.commandId === 'c1'));
});
test('revocation stops only the owned output and discards the capability', async () => {
  const h = harness({ failures: { '/api/broadcast-agent/session': 401 } });
  await h.client.tick(); assert.deepEqual(h.obsCalls, [['stopCurrent']]); assert.equal(h.store.value.pairing, null);
});
test('network/server failure retains pairing and does not interrupt local backup', async () => {
  const h = harness({ failures: { '/api/broadcast-agent/session': 503 } });
  await h.client.tick(); assert.equal(h.obsCalls.length, 0); assert.ok(h.store.value.pairing); assert.equal(h.client.reachable, false);
});
test('expired pairing stops transmitting before contacting server', async () => {
  const h = harness({ initial: { pairing: { ...session, token: 'x'.repeat(43), expiresAt: '2020-01-01' } } });
  await h.client.tick(); assert.equal(h.calls.length, 0); assert.deepEqual(h.obsCalls, [['stopCurrent']]);
});
test('lost pairing response uses the same pre-saved random credential on retry', async () => {
  const h = harness({ initial: { pairing: null } });
  const request = h.client.request.bind(h.client); let firstToken;
  h.client.request = async (url, init) => { firstToken = init.body.deviceToken; assert.equal(h.store.value.pendingPair.token, firstToken); throw new Error('Network lost'); };
  await assert.rejects(h.client.pair('ABCD-EFGH-JKLM', 'Camera Mac'), /Network lost/);
  h.client.request = request;
  const result = await h.client.pair('ABCD-EFGH-JKLM', 'Camera Mac');
  assert.equal(h.calls[0].body.deviceToken, firstToken); assert.equal(h.store.value.pairing.token, firstToken);
  assert.equal('token' in result, false); assert.equal('token' in h.client.publicSession(), false);
});
test('camera disconnected is reported not ready', async () => {
  const h = harness({ status: { cameraAvailable: false, warnings: ['Camera disconnected'] } }); await h.client.tick();
  const heartbeat = h.calls.find(call => call.pathname.endsWith('/heartbeat'));
  assert.equal(heartbeat.body.obsConnected, false); assert.equal(heartbeat.body.errorMessage, 'Camera disconnected');
});
test('failed OBS operation is acknowledged as failed and no secret reaches diagnostics', async () => {
  const h = harness({ command: { id: 'bad', action: 'START_STREAM', openQueueGameId: matchId } });
  h.obs.start = async () => { throw new Error('rtmps://live.example/SECRET ' + 'x'.repeat(43)); };
  await h.client.tick();
  const ack = h.calls.find(call => call.pathname.endsWith('/commands') && call.method === 'POST');
  assert.equal(ack.body.ok, false); assert.doesNotMatch(ack.body.errorMessage, /SECRET|x{43}/);
  assert.doesNotMatch(safeMessage('https://host/#token=abc'), /abc/);
});
test('concurrent ticks cannot claim two commands', async () => {
  const h = harness(); await Promise.all([h.client.tick(), h.client.tick()]);
  assert.equal(h.calls.filter(call => call.pathname.endsWith('/session')).length, 1);
});
test('disconnected OBS with an owned output cannot be paired away', async () => {
  const h = harness({ status: { connected: false } });
  h.obs.getState = () => ({ recordingOwned: true, target: { openQueueGameId: matchId } });
  await assert.rejects(h.client.pair('ABCD-EFGH-JKLM', 'New laptop'), /Reconnect OBS/);
  assert.equal(h.calls.length, 0); assert.equal(h.writes.length, 0);
});
test('a failing backup disk preflight prevents stream start and is acknowledged', async () => {
  const h = harness({ command: { id: 'low-disk', action: 'START_STREAM', openQueueGameId: matchId } });
  h.client.beforeStart = async () => { throw new Error('Not enough recording disk space.'); };
  await h.client.tick();
  assert.equal(h.obsCalls.length, 0);
  assert.equal(h.calls.find(call => call.pathname.endsWith('/commands') && call.method === 'POST').body.ok, false);
});
