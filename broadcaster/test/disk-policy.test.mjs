import test from 'node:test';
import assert from 'node:assert/strict';
import { recordingDiskPolicy, requireRecordingSpace, SAFETY_RESERVE_BYTES } from '../src/desktop/disk-policy.mjs';
test('staging permits 2 GB but retains a small safety reserve', () => {
  const policy = recordingDiskPolicy('https://ops-staging.field.bh');
  assert.doesNotThrow(() => requireRecordingSpace(2 * 1024 ** 3, policy));
  assert.throws(() => requireRecordingSpace(SAFETY_RESERVE_BYTES - 1, policy));
});
test('production and lookalike hosts retain 5 GB minimum', () => {
  for (const server of ['https://ops.field.bh', 'https://ops-staging.field.bh.evil.com', 'http://localhost:3000', '']) {
    assert.throws(() => requireRecordingSpace(2 * 1024 ** 3, recordingDiskPolicy(server)));
  }
});
test('local development testing allows the staging-sized reserve', () => {
  assert.doesNotThrow(() => requireRecordingSpace(2 * 1024 ** 3, recordingDiskPolicy('http://127.0.0.1:3000', true)));
  assert.throws(() => requireRecordingSpace(NaN, recordingDiskPolicy('https://ops-staging.field.bh')));
});
