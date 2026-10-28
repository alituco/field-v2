import fs from 'node:fs/promises';
import { trustedUploadUrl } from './desktop-url.mjs';

// Cloudflare requires non-final chunks to be a multiple of 256 KiB, at least
// 5 MiB. Keep memory bounded even for a multi-hour recording.
const CHUNK = 8 * 1024 ** 2;
export async function uploadRecording({ filePath, uploadUrl, expectedSize, expectedMtime,
  fetcher = fetch, signal, onProgress = () => {}, wait = ms => new Promise(resolve => setTimeout(resolve, ms)) }) {
  const url = trustedUploadUrl(uploadUrl);
  const file = await fs.open(filePath, 'r');
  const request = (method, extra = {}) => fetcher(url, {
    method, redirect: 'error', signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(60_000)]) : AbortSignal.timeout(60_000),
    headers: { 'Tus-Resumable': '1.0.0', ...extra.headers }, ...(extra.body ? { body: extra.body } : {}),
  });
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size !== expectedSize || stat.mtimeMs !== expectedMtime) throw new Error('This recording changed after it was selected. Choose the original completed backup.');
    let failures = 0;
    while (true) {
      signal?.throwIfAborted();
      try {
        const head = await request('HEAD');
        if ([404, 410].includes(head.status)) throw Object.assign(new Error('This recording upload expired. Start recovery again.'), { terminal: true });
        if (!head.ok) throw new Error('The recording upload is unavailable.');
        const rawOffset = head.headers.get('upload-offset');
        let offset = rawOffset && /^\d+$/.test(rawOffset) ? Number(rawOffset) : NaN;
        if (!Number.isSafeInteger(offset) || offset < 0 || offset > stat.size ||
            (head.headers.has('upload-length') && Number(head.headers.get('upload-length')) !== stat.size)) {
          throw Object.assign(new Error('The recording upload size could not be verified.'), { terminal: true });
        }
        onProgress(offset, stat.size);
        while (offset < stat.size) {
          signal?.throwIfAborted();
          const current = await file.stat();
          if (current.size !== stat.size || current.mtimeMs !== stat.mtimeMs) throw Object.assign(new Error('The recording changed during upload. Recovery was stopped.'), { terminal: true });
          const chunk = Buffer.alloc(Math.min(CHUNK, stat.size - offset));
          const { bytesRead } = await file.read(chunk, 0, chunk.length, offset);
          if (bytesRead !== chunk.length) throw Object.assign(new Error('The complete recording could not be read.'), { terminal: true });
          const response = await request('PATCH', { headers: { 'Upload-Offset': String(offset), 'Content-Type': 'application/offset+octet-stream' }, body: chunk });
          if (!response.ok) throw new Error('The connection interrupted the recording upload.');
          const next = response.headers.get('upload-offset');
          if (next !== String(offset + bytesRead)) throw new Error('The upload acknowledgement was incomplete.');
          offset += bytesRead;
          failures = 0;
          onProgress(offset, stat.size);
        }
        return { uploaded: true, size: stat.size };
      } catch (error) {
        signal?.throwIfAborted();
        if (error.terminal || ++failures > 3) throw error;
        // HEAD resolves a lost PATCH acknowledgement; never guess/re-send at
        // the old offset or expose the device credential to the upload host.
        await wait(Math.min(1000 * 2 ** failures, 8000));
      }
    }
  } finally { await file.close(); }
}
