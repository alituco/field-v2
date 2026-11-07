import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';

const advisory = 'An earlier OBS session has an unconfirmed backup. Check its saved recovery details and original recording folder.';
const source = await fs.readFile(new URL('../src/desktop/app.js', import.meta.url), 'utf8');

async function renderer() {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      textContent: '', value: '', hidden: true, disabled: false, style: {},
      classList: { toggle() {} }, addEventListener() {},
      querySelector: selector => element(`${id} ${selector}`),
    });
    return elements.get(id);
  };
  let onState;
  const initial = { status: {}, busy: false, outputUncertain: false, outputHeld: false,
    server: 'https://ops-staging.field.bh' };
  const context = vm.createContext({
    document: { getElementById: element, querySelectorAll: () => [] },
    window: { fieldrush: {
      invoke: async () => ({ ok: true, value: initial }),
      onState(callback) { onState = callback; },
    } },
    setInterval() {}, setTimeout() {}, clearTimeout() {},
  });
  vm.runInContext(source, context);
  // Let the normal initial state request settle before emitting new snapshots.
  await new Promise(resolve => setImmediate(resolve));
  return { element, render: state => onState({ ...initial, ...state }) };
}

test('historical recovery notice remains visible without a fatal error banner', async () => {
  const ui = await renderer();
  ui.render({
    pairing: { matchKind: 'SOLO', matchLabel: 'White vs Black' }, reachable: true,
    status: { connected: true, configured: true, cameraAvailable: true,
      microphoneAvailable: true, streaming: false, recording: false,
      warnings: [], advisories: [advisory] },
  });
  assert.equal(ui.element('warning').hidden, false);
  assert.equal(ui.element('warning').textContent, advisory);
  assert.equal(ui.element('error').hidden, true);
  assert.equal(ui.element('connection').textContent, 'Camera connected');
  assert.equal(ui.element('stream-test').disabled, false);
});

test('current warnings and historical recovery notices are both displayed', async () => {
  const ui = await renderer();
  ui.render({ status: { warnings: ['The selected camera is disconnected or unavailable.'], advisories: [advisory] } });
  assert.equal(ui.element('warning').textContent,
    `The selected camera is disconnected or unavailable. ${advisory}`);
});

test('uncertain current output retains its urgent warning and recovery notice', async () => {
  const ui = await renderer();
  ui.render({ outputUncertain: true, status: { advisories: [advisory] } });
  assert.equal(ui.element('warning').textContent,
    `OBS disconnected while video may still be running. Reconnect OBS before changing the match or closing Fieldrush. ${advisory}`);
  assert.equal(ui.element('forget').disabled, true);
  assert.equal(ui.element('recover-recording').disabled, true);
  assert.equal(ui.element('pair-form button').disabled, true);
});

test('legacy status without advisories still renders and a later empty notice hides', async () => {
  const ui = await renderer();
  ui.render({ status: { warnings: ['Current fault'] } });
  assert.equal(ui.element('warning').textContent, 'Current fault');
  ui.render({ status: { warnings: [] } });
  assert.equal(ui.element('warning').hidden, true);
  assert.equal(ui.element('warning').textContent, '');
});

test('packaged production and staging stay visibly distinct and local development stays unavailable', async () => {
  const ui = await renderer();
  ui.render({ server: 'https://field-ops-production.vercel.app', development: false });
  assert.equal(ui.element('environment-label').textContent, 'PRODUCTION');
  assert.match(ui.element('environment-help').textContent, /reach real players/);
  assert.equal(ui.element('server').value, 'https://field-ops-production.vercel.app');
  assert.equal(ui.element('server').disabled, false);
  assert.equal(ui.element('local-server').hidden, true);
  assert.equal(ui.element('local-server').disabled, true);
  ui.element('pair-code').value = 'PROD-CODE';
  ui.render({ server: 'https://ops-staging.field.bh', development: false });
  assert.equal(ui.element('environment-label').textContent, 'STAGING');
  assert.match(ui.element('environment-help').textContent, /rehearsals/);
  assert.equal(ui.element('pair-code').value, '');
  assert.equal(ui.element('preview').hidden, true);
});

test('environment choice is blocked during pairing, output, cleanup and upload operations', async () => {
  const ui = await renderer();
  for (const state of [
    { pairing: { matchKind: 'SOLO' } }, { status: { streaming: true } },
    { status: { recording: true } }, { outputUncertain: true }, { outputHeld: true }, { busy: true },
  ]) {
    ui.render(state);
    assert.equal(ui.element('server').disabled, true);
  }
  ui.render({});
  assert.equal(ui.element('server').disabled, false);
});

test('unpackaged local development is labeled and selectable separately', async () => {
  const ui = await renderer();
  ui.render({ server: 'http://localhost:3000', development: true });
  assert.equal(ui.element('environment-label').textContent, 'LOCAL');
  assert.equal(ui.element('local-server').hidden, false);
  assert.equal(ui.element('local-server').disabled, false);
});

test('switching restores camera and audio choices instead of retaining the other profile selection', async () => {
  const ui = await renderer();
  ui.element('camera').value = 'staging-camera';
  ui.element('microphone').value = 'staging-mic';
  ui.render({ server: 'https://field-ops-production.vercel.app', cameraId: 'production-camera', microphoneId: 'production-mic' });
  assert.equal(ui.element('camera').value, 'production-camera');
  assert.equal(ui.element('microphone').value, 'production-mic');
  ui.render({ server: 'https://ops-staging.field.bh', cameraId: 'staging-camera', microphoneId: null });
  assert.equal(ui.element('camera').value, 'staging-camera');
  assert.equal(ui.element('microphone').value, '');
});
