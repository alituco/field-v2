export const SAFETY_RESERVE_BYTES = 256 * 1024 ** 2;
export function recordingDiskPolicy(server, development = false) {
  const staging = server === 'https://ops-staging.field.bh' ||
    (development && ['http://127.0.0.1:3000', 'http://localhost:3000'].includes(server));
  return { staging, minimumBytes: staging ? SAFETY_RESERVE_BYTES : 5 * 1024 ** 3,
    label: staging ? 'Staging test · 5 GB minimum waived · stops below 256 MB free' : 'at least 5 GB needed' };
}
export function requireRecordingSpace(bytes, policy) {
  if (!Number.isFinite(bytes) || bytes < policy.minimumBytes) throw new Error(policy.staging
    ? 'The disk needs at least 256 MB free to safely test recording.'
    : 'The backup disk needs at least 5 GB free before starting a match.');
}
