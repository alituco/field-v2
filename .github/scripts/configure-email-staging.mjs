// Deliberate one-off staging Auth configuration, not an automatic deploy step.
// SMTP credentials are already stored in Supabase and are never patched here.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';

export const stagingProject = 'nfdkdhdevpstfspazbfn';
const expectedSender = 'no-reply@auth.fieldrush.gg';
const subject = 'Confirm your Fieldrush email';
export const ownedKeys = Object.freeze([
  'mailer_otp_length',
  'mailer_otp_exp',
  'mailer_autoconfirm',
  'mailer_secure_email_change_enabled',
  'mailer_subjects_email_change',
  'mailer_templates_email_change_content',
]);
const templateUrl = new URL('../../supabase/templates/fieldrush-email-change.html', import.meta.url);

export function validateConfiguration(env) {
  if (env.SUPABASE_PROJECT_REF !== stagingProject || !env.SUPABASE_ACCESS_TOKEN?.trim()) {
    throw new Error('A Supabase access token and the exact Fieldrush staging project ref are required.');
  }
}

export function emailPatch(template) {
  if (!template.includes('{{ .Token }}') || !template.includes('href="{{ .ConfirmationURL }}"') ||
      /<(?:script|iframe|form|input)\b/i.test(template)) {
    throw new Error('The reviewed email-change template must contain its code and secure confirmation link.');
  }
  return {
    mailer_otp_length: 6,
    mailer_otp_exp: 600,
    mailer_autoconfirm: false,
    // Require ownership of the new inbox only. Email autoconfirm stays disabled;
    // this does not mark an email verified without its six-digit code/link.
    mailer_secure_email_change_enabled: false,
    mailer_subjects_email_change: subject,
    mailer_templates_email_change_content: template,
  };
}

function validateSavedSmtp(config) {
  if (config.external_email_enabled !== true || config.smtp_host !== 'smtp.resend.com' ||
      !['465', '587'].includes(String(config.smtp_port)) || config.smtp_user !== 'resend' ||
      config.smtp_admin_email !== expectedSender) {
    throw new Error('Saved staging email/Resend SMTP settings do not match the reviewed sender configuration.');
  }
}

export function differentUnownedKeys(before, after) {
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
  return [...keys].filter((key) => !ownedKeys.includes(key) &&
    (Object.hasOwn(before, key) !== Object.hasOwn(after, key) ||
      !isDeepStrictEqual(before[key], after[key]))).sort();
}

// Preserve useful evidence without copying arbitrary configuration values or
// reversible/guessable hashes of secrets. Unknown and string values stay out.
const diagnosticFlagKeys = Object.freeze([
  'mailer_autoconfirm', 'mailer_allow_unverified_email_sign_ins',
  'mailer_secure_email_change_enabled', 'mailer_otp_length', 'mailer_otp_exp',
  'external_email_enabled', 'external_phone_enabled', 'external_google_enabled',
  'sms_autoconfirm', 'sms_otp_length', 'sms_otp_exp', 'sms_max_frequency',
  'smtp_max_frequency', 'rate_limit_email_sent',
]);
export function safeConfigurationSnapshot(config) {
  return Object.fromEntries(diagnosticFlagKeys.map((key) => {
    if (!Object.hasOwn(config, key)) return [key, { present: false }];
    const value = config[key];
    const safeValue = value === null || typeof value === 'boolean' ||
      (typeof value === 'number' && Number.isFinite(value));
    return [key, safeValue ? { present: true, value } : { present: true, valueType: typeof value }];
  }));
}

function safeKeyNames(keys) {
  return [...new Set(keys.map((key) => /^[a-z][a-z0-9_]{0,100}$/.test(key) ? key : '[unrecognized-key]'))].sort();
}

function verificationError(message, diagnostic) {
  const error = new Error(message);
  error.diagnostic = diagnostic;
  return error;
}

export async function configureEmailStaging(env, {
  apply = false,
  fetcher = fetch,
  template,
  onDiagnostic = () => {},
} = {}) {
  validateConfiguration(env);
  if (typeof apply !== 'boolean') throw new Error('Apply must be an explicit boolean.');
  if (typeof onDiagnostic !== 'function') throw new Error('Diagnostic reporting must be a function.');
  const content = template ?? await readFile(templateUrl, 'utf8');
  const patch = emailPatch(content);
  const url = `https://api.supabase.com/v1/projects/${stagingProject}/config/auth`;
  const headers = { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type': 'application/json' };
  async function request(method, body) {
    let response;
    try {
      response = await fetcher(url, {
        method, headers, ...(body ? { body: JSON.stringify(body) } : {}),
        signal: AbortSignal.timeout(30_000),
      });
    } catch {
      // Network/provider diagnostics can contain credentials or a request body.
      throw new Error(`Staging Auth ${method} request could not be completed.`);
    }
    if (!response.ok) throw new Error(`Staging Auth ${method} failed (HTTP ${response.status}).`);
    if (method === 'PATCH') return;
    let config;
    try { config = await response.json(); } catch { throw new Error('Staging Auth returned invalid JSON.'); }
    if (!config || typeof config !== 'object' || Array.isArray(config)) {
      throw new Error('Staging Auth returned an invalid configuration.');
    }
    return config;
  }

  const before = await request('GET');
  validateSavedSmtp(before);
  const changedKeys = ownedKeys.filter((key) => before[key] !== patch[key]);
  const summary = {
    project: stagingProject,
    mode: apply ? 'apply' : 'dry-run',
    changedKeys,
    otpLength: patch.mailer_otp_length,
    expiresInSeconds: patch.mailer_otp_exp,
    templateSha256: createHash('sha256').update(content).digest('hex'),
    verified: false,
  };
  if (!apply) return summary;
  // In CLI runs this safe preimage is emitted before any write, so a failed
  // PATCH/read-back cannot erase the before-state evidence at process exit.
  onDiagnostic({
    phase: 'before-apply', recordedAt: new Date().toISOString(), project: stagingProject, changedKeys,
    flags: safeConfigurationSnapshot(before),
  });
  if (changedKeys.length) await request('PATCH', patch);
  const after = await request('GET');
  const ownedMismatchKeys = ownedKeys.filter((key) => after[key] !== patch[key]);
  const unrelatedChangedKeys = safeKeyNames(differentUnownedKeys(before, after));
  const diagnostic = {
    phase: 'after-apply', recordedAt: new Date().toISOString(), project: stagingProject,
    ownedMismatchKeys, unrelatedChangedKeys,
    before: safeConfigurationSnapshot(before), after: safeConfigurationSnapshot(after),
  };
  if (ownedMismatchKeys.length) {
    throw verificationError(`Staging Auth email settings did not match after applying: ${ownedMismatchKeys.join(', ')}. Inspect before retrying.`, diagnostic);
  }
  if (unrelatedChangedKeys.length) {
    throw verificationError(`Unrelated staging Auth settings changed during configuration: ${unrelatedChangedKeys.join(', ')}. Inspect before retrying; no rollback was attempted.`, diagnostic);
  }
  validateSavedSmtp(after);
  return { ...summary, verified: true };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = process.argv.slice(2);
    if (args.length > 1 || args.some((arg) => !['--dry-run', '--apply'].includes(arg))) {
      throw new Error('Usage: node .github/scripts/configure-email-staging.mjs [--dry-run|--apply]');
    }
    const summary = await configureEmailStaging(process.env, {
      apply: args[0] === '--apply',
      onDiagnostic: (diagnostic) => console.log(JSON.stringify(diagnostic, null, 2)),
    });
    // This safe summary never includes unrelated config values, SMTP credentials or Auth response bodies.
    console.log(JSON.stringify(summary, null, 2));
  } catch (error) {
    console.error(error.message);
    if (error.diagnostic) console.error(JSON.stringify(error.diagnostic, null, 2));
    process.exitCode = 1;
  }
}
