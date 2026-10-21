// Operator-invoked staging Auth template setup. Never runs during deployment.
// Email-change verification, SMTP credentials and all phone/Google settings
// are unowned and must remain byte-for-byte unchanged.
import { readFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { pathToFileURL } from 'node:url';
const project = 'nfdkdhdevpstfspazbfn';
export const staffEmailOwnedKeys = Object.freeze([
  'mailer_otp_length', 'mailer_otp_exp', 'mailer_subjects_magic_link',
  'mailer_templates_magic_link_content', 'mailer_subjects_confirmation', 'mailer_templates_confirmation_content',
]);
export async function configureStaffEmailStaging(env, { apply = false, fetcher = fetch, template } = {}) {
  if (env.SUPABASE_PROJECT_REF !== project || !env.SUPABASE_ACCESS_TOKEN?.trim()) throw new Error('The exact staging project and Supabase access token are required.');
  if (typeof apply !== 'boolean') throw new Error('Apply must be explicit.');
  const content = template ?? await readFile(new URL('../../supabase/templates/fieldrush-sign-in-code.html', import.meta.url), 'utf8');
  if (!content.includes('{{ .Token }}') || /<(?:script|iframe|form|input)\b/i.test(content) || /https?:\/\//i.test(content)) throw new Error('Use the reviewed code-only sign-in template without external content.');
  const patch = { mailer_otp_length: 6, mailer_otp_exp: 600,
    mailer_subjects_magic_link: 'Your Fieldrush sign-in code', mailer_templates_magic_link_content: content,
    mailer_subjects_confirmation: 'Your Fieldrush sign-in code', mailer_templates_confirmation_content: content };
  const url = `https://api.supabase.com/v1/projects/${project}/config/auth`;
  const headers = { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type': 'application/json' };
  async function request(method, body) {
    let response;
    try { response = await fetcher(url, { method, headers, ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(30_000) }); }
    catch { throw new Error(`Staging Auth ${method} could not be completed.`); }
    if (!response.ok) throw new Error(`Staging Auth ${method} failed (HTTP ${response.status}).`);
    if (method === 'PATCH') return;
    let result;
    try { result = await response.json(); } catch { throw new Error('Staging Auth returned invalid JSON.'); }
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error('Staging Auth returned invalid settings.');
    return result;
  }
  const before = await request('GET');
  if (before.external_email_enabled !== true || before.smtp_host !== 'smtp.resend.com' || before.smtp_user !== 'resend' ||
      !['465', '587'].includes(String(before.smtp_port)) || before.smtp_admin_email !== 'no-reply@auth.fieldrush.gg' ||
      before.mailer_autoconfirm !== false) throw new Error('Saved verified email/SMTP settings do not match staging. No configuration was changed.');
  const changedKeys = staffEmailOwnedKeys.filter(key => before[key] !== patch[key]);
  if (!apply) return { project, mode: 'dry-run', changedKeys, otpLength: 6, expiresInSeconds: 600, verified: false };
  if (changedKeys.length) await request('PATCH', patch);
  const after = await request('GET');
  if (staffEmailOwnedKeys.some(key => after[key] !== patch[key])) throw new Error('Staff email settings did not verify after applying.');
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
  if ([...keys].some(key => !staffEmailOwnedKeys.includes(key) &&
      (Object.hasOwn(before, key) !== Object.hasOwn(after, key) || !isDeepStrictEqual(before[key], after[key])))) {
    throw new Error('An unowned Auth setting changed during verification. Inspect staging settings; unrelated configuration was not restored or logged.');
  }
  return { project, mode: 'apply', changedKeys, otpLength: 6, expiresInSeconds: 600, verified: true };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.slice(2).some(arg => arg !== '--apply')) throw new Error('Only --apply is supported; omission is a dry-run.');
    process.stdout.write(JSON.stringify(await configureStaffEmailStaging(process.env, { apply: process.argv.includes('--apply') })) + '\n');
  } catch (error) { process.stderr.write((error instanceof Error ? error.message : 'Staff email configuration failed.') + '\n'); process.exitCode = 1; }
}
