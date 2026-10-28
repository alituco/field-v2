import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { uploadRecording } from '../src/recording-upload.mjs';

async function fixture(t) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fieldrush-upload-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const filePath = path.join(dir, 'backup.mkv');
  await fs.writeFile(filePath, Buffer.alloc(9 * 1024 ** 2));
  const stat = await fs.stat(filePath);
  return { filePath, expectedSize: stat.size, expectedMtime: stat.mtimeMs, uploadUrl: 'https://upload.videodelivery.net/tus/unit-test', wait: async () => {} };
}
test('bounded chunks resume a lost PATCH acknowledgement without credentials', async t => {
  const input = await fixture(t); let offset = 0, fail = true, patches = 0;
  await uploadRecording({ ...input, fetcher: async (url, options) => {
    assert.equal(new URL(url).hostname, 'upload.videodelivery.net');
    assert.equal(options.headers.Authorization, undefined); assert.equal(options.redirect, 'error');
    if (options.method === 'HEAD') return new Response(null, { headers: { 'upload-offset': String(offset), 'upload-length': String(input.expectedSize) } });
    assert.equal(Number(options.headers['Upload-Offset']), offset);
    assert.ok(options.body.length <= 8 * 1024 ** 2); patches++;
    offset += options.body.length;
    if (fail) { fail = false; throw new Error('lost response'); }
    return new Response(null, { status: 204, headers: { 'upload-offset': String(offset) } });
  } });
  assert.equal(patches, 2); assert.equal(offset, input.expectedSize);
});
test('changed files, expired upload URLs and malformed offsets fail closed', async t => {
  const input = await fixture(t);
  await assert.rejects(uploadRecording({ ...input, expectedSize: 1 }), /changed/);
  await assert.rejects(uploadRecording({ ...input, fetcher: async () => new Response(null, { status: 410 }) }), /expired/);
  await assert.rejects(uploadRecording({ ...input, fetcher: async () => new Response(null, { headers: { 'upload-offset': '-1' } }) }), /size/);
});
test('an explicit cancellation stops without uploading or publishing', async t => {
  const input = await fixture(t), controller = new AbortController(); controller.abort();
  await assert.rejects(uploadRecording({ ...input, signal: controller.signal, fetcher: () => assert.fail('must not upload') }), /abort/i);
});
