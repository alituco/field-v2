import test from 'node:test';
import assert from 'node:assert/strict';
import { isDesktopDocument, trustedUploadUrl, recoveryPreviewUrl } from '../src/desktop-url.mjs';

test('custom scheme documents are checked explicitly, not by opaque URL origin', () => {
  assert.equal(new URL('fieldrush://desktop/').origin, 'null');
  assert.equal(isDesktopDocument('fieldrush://desktop/'), true);
  assert.equal(isDesktopDocument('fieldrush://desktop/app.html'), true);
  for (const url of ['https://desktop/', 'fieldrush://evil/', 'fieldrush://user@desktop/', 'fieldrush://desktop:80/', 'fieldrush://desktop/app.js', 'fieldrush://desktop/?next=evil', 'not url']) assert.equal(isDesktopDocument(url), false);
});

test('uploads and browser previews only use exact provider destinations', () => {
  assert.equal(trustedUploadUrl('https://upload.videodelivery.net/tus/abc'), 'https://upload.videodelivery.net/tus/abc');
  assert.equal(recoveryPreviewUrl('https://customer-abc.cloudflarestream.com/token/manifest/video.m3u8'), 'https://customer-abc.cloudflarestream.com/token/iframe');
  for (const url of ['http://upload.videodelivery.net/tus/abc', 'https://upload.videodelivery.net.evil.test/tus/abc', 'https://user@upload.videodelivery.net/tus/abc']) assert.throws(() => trustedUploadUrl(url));
  assert.throws(() => recoveryPreviewUrl('https://evil.test/video'));
});
