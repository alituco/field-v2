import { spawnSync } from 'node:child_process';

if (process.platform !== 'darwin') throw new Error('Build the Mac installer on macOS.');
const identity = process.env.CSC_NAME?.trim();
if (!identity?.startsWith('Developer ID Application:')) {
  throw new Error('Set CSC_NAME to your Developer ID Application certificate. App Store distribution certificates cannot sign this installer.');
}
if (!(process.env.APPLE_API_KEY && process.env.APPLE_API_KEY_ID && process.env.APPLE_API_ISSUER) &&
    !(process.env.APPLE_ID && process.env.APPLE_APP_SPECIFIC_PASSWORD && process.env.APPLE_TEAM_ID)) {
  throw new Error('Configure Apple notarization credentials before building a distributable installer.');
}
const result = spawnSync('node_modules/.bin/electron-builder', ['--mac', '--arm64', '--x64', '-c.forceCodeSigning=true'], { stdio: 'inherit', shell: false });
process.exit(result.status ?? 1);
