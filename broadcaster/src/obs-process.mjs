import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const execute = promisify(execFile);

// Read-only OS evidence, never a renderer-provided “I restarted” assertion.
// PID alone can be reused; include launch time and the exact installed binary.
export async function obsProcessIdentity(run = execute) {
  try {
    const { stdout } = await run('/usr/sbin/lsof', ['-nP', '-a', '-iTCP:4455', '-sTCP:LISTEN', '-Fp'], { timeout: 2000, maxBuffer: 65536, env: { ...process.env, LC_ALL: 'C' } });
    const pids = [...new Set(stdout.split('\n').filter(line => /^p\d+$/.test(line)).map(line => line.slice(1)))];
    if (pids.length !== 1) return null;
    const result = await run('/bin/ps', ['-p', pids[0], '-o', 'lstart=', '-o', 'comm='], { timeout: 2000, maxBuffer: 65536, env: { ...process.env, LC_ALL: 'C' } });
    const match = result.stdout.trim().match(/^([A-Za-z]{3}\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(\/Applications\/OBS\.app\/Contents\/MacOS\/OBS)$/);
    return match ? `${pids[0]}:${match[1].replace(/\s+/g, ' ')}:${match[2]}` : null;
  } catch { return null; }
}
