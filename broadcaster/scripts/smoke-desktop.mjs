import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(path.join(root, '../referee/package.json'));
const { _electron } = require('playwright');
const userData = await fs.mkdtemp(path.join(os.tmpdir(), 'fieldrush-desktop-smoke-'));
let desktop;
try {
  desktop = await _electron.launch({ executablePath: path.join(root, 'dist/mac-arm64/Fieldrush Broadcaster.app/Contents/MacOS/Fieldrush Broadcaster'), args: [`--user-data-dir=${userData}`], timeout: 30_000 });
  const page = await desktop.firstWindow();
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await page.getByRole('heading', { name: 'Bring the game closer.' }).waitFor();
  const state = await page.evaluate(() => window.fieldrush.invoke('state'));
  assert.equal(state.ok, true);
  assert.equal(state.value.development, false);
  assert.equal(state.value.pairing, null);
  assert.equal(state.value.status.connected, false);
  assert.equal(await page.evaluate(() => typeof window.require), 'undefined');
  assert.equal((await page.evaluate(() => window.fieldrush.invoke('not-allowed'))).ok, false);
  await page.screenshot({ path: path.join(root, 'dist/desktop-smoke.png'), fullPage: true });
  assert.deepEqual(errors, []);
  console.log('Packaged Mac app launched: secure IPC, isolated renderer, no automatic OBS connection, screenshot saved.');
} finally {
  await desktop?.close();
  await fs.rm(userData, { recursive: true, force: true });
}
