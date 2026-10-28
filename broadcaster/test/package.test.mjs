import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
test('every relative desktop import is included in the distributable', async () => {
  const pkg = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
  const pending = [pkg.main], seen = new Set();
  while (pending.length) {
    const source = pending.pop(); if (seen.has(source)) continue; seen.add(source);
    assert.ok(pkg.build.files.includes(source) || (source.startsWith('src/desktop/') && pkg.build.files.includes('src/desktop/**/*')), `Missing packaged file: ${source}`);
    const text = await fs.readFile(path.join(root, source), 'utf8');
    for (const [, imported] of text.matchAll(/from\s+['"]([^'"]+)['"]/g)) {
      if (imported.startsWith('.')) pending.push(path.normalize(path.join(path.dirname(source), imported)));
    }
  }
  assert.equal(pkg.build.files.includes('src/index.mjs'), false);
  assert.equal(pkg.build.files.some(file => file.includes('.env')), false);
  assert.equal(pkg.build.mac.hardenedRuntime, true);
  assert.equal(pkg.build.mac.notarize, true);
});

test('bundled fonts retain their license notices', async () => {
  const pkg = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
  const fonts = pkg.build.extraResources.find(resource => resource.to === 'fonts');
  assert.ok(fonts);
  for (const font of ['Outfit', 'PlusJakartaSans']) {
    assert.ok(fonts.filter.includes(`${font}.ttf`));
    assert.ok(fonts.filter.includes(`${font}-LICENSE.txt`));
    assert.ok((await fs.readFile(path.resolve(root, fonts.from, `${font}-LICENSE.txt`), 'utf8')).trim());
  }
});
