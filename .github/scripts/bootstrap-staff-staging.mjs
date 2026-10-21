// Explicit operator-only recovery of the first independent staging admin.
// Dry-run by default. Never called by CI deployment or a public HTTP route.
import { pathToFileURL } from 'node:url';

export const stagingStaffProject = 'nfdkdhdevpstfspazbfn';
const origin = `https://${stagingStaffProject}.supabase.co`;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function bootstrapStaffStaging(env, input, { fetcher = fetch } = {}) {
  if (env.SUPABASE_URL !== origin || !env.SUPABASE_SERVICE_ROLE_KEY?.trim()) {
    throw new Error('The exact staging Supabase URL and service-role credential are required.');
  }
  if (!uuid.test(input.staffId ?? '') || typeof input.email !== 'string' ||
      !emailPattern.test(input.email) || input.email.length > 254 ||
      typeof input.apply !== 'boolean' || typeof input.sendCode !== 'boolean' ||
      (input.sendCode && !input.apply)) {
    throw new Error('Provide an exact staff ID and dedicated email. Sending a code requires explicit apply.');
  }
  const email = input.email.trim().toLowerCase();
  const headers = { apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' };
  async function request(path, method = 'GET', body) {
    let response;
    try {
      response = await fetcher(`${origin}${path}`, { method, headers,
        ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(30_000) });
    } catch { throw new Error('Staging staff request could not be completed; no provider details are logged.'); }
    if (!response.ok) throw new Error(`Staging staff operation failed (HTTP ${response.status}); inspect the exact account before retrying.`);
    try { return await response.json(); } catch { throw new Error('Staging staff returned an invalid response.'); }
  }
  const rows = await request(`/rest/v1/referee_profiles?profile_id=eq.${input.staffId}&select=profile_id,role,is_active,auth_user_id,email`);
  const staff = Array.isArray(rows) && rows.length === 1 ? rows[0] : null;
  if (!staff || staff.profile_id !== input.staffId || staff.role !== 'admin' || staff.is_active !== true) {
    throw new Error('The exact existing active administrator must be selected. No account was changed.');
  }
  if (staff.auth_user_id && staff.email?.toLowerCase() !== email) {
    throw new Error('This staff account is already bound to another email. Use the audited staff administration flow.');
  }
  const otherAdmins = await request(`/rest/v1/referee_profiles?role=eq.admin&is_active=eq.true&auth_user_id=not.is.null&profile_id=neq.${input.staffId}&select=profile_id`);
  if (!Array.isArray(otherAdmins) || otherAdmins.length) {
    throw new Error('An independent administrator already exists. Sign in there and use normal staff administration; bootstrap is only for the first admin.');
  }
  let target = null;
  let complete = false;
  for (let page = 1; page <= 20; page++) {
    const result = await request(`/auth/v1/admin/users?page=${page}&per_page=1000`);
    if (!Array.isArray(result.users)) throw new Error('The Auth directory response was invalid.');
    const found = result.users.filter(user => user.email?.toLowerCase() === email);
    if (found.length > 1 || (target && found.length)) throw new Error('Ambiguous email identity. No account was changed.');
    if (found.length) target = found[0];
    if (result.users.length < 1000) { complete = true; break; }
  }
  if (!complete) throw new Error('The Auth directory could not be inspected completely. No account was changed.');
  if (target && (target.app_metadata?.fieldrush_account_type !== 'staff' || target.phone || target.deleted_at ||
      (target.banned_until && Date.parse(target.banned_until) > Date.now()))) {
    throw new Error('That email belongs to an existing or unavailable account. Use a different staff-only email; player identities are never reused.');
  }
  if (target) {
    const profiles = await request(`/rest/v1/profiles?id=eq.${target.id}&select=id`);
    if (!Array.isArray(profiles) || profiles.length) throw new Error('This identity has player data and cannot become a staff account.');
    if (staff.auth_user_id && staff.auth_user_id !== target.id) throw new Error('The existing staff binding does not match this identity.');
  } else if (staff.auth_user_id) {
    throw new Error('The existing staff identity could not be confirmed. No account was changed.');
  }
  const summary = { project: stagingStaffProject, staffId: input.staffId,
    mode: input.apply ? 'apply' : 'dry-run', wouldCreateIdentity: !target,
    bound: false, loginCodeSent: false };
  if (!input.apply) return summary;
  if (!target) {
    const created = await request('/auth/v1/admin/users', 'POST', {
      email, email_confirm: false, app_metadata: { fieldrush_account_type: 'staff' },
    });
    target = created.user ?? created;
    if (!uuid.test(target?.id ?? '') || target.email?.toLowerCase() !== email ||
        target.app_metadata?.fieldrush_account_type !== 'staff' || target.phone || target.email_confirmed_at) {
      throw new Error('The independent identity was not confirmed. Inspect this staff email before retrying; no player account was modified.');
    }
  }
  // Do not delete a new Auth user on a lost response or binding failure. A
  // repeated invocation can safely recover the same staff-only email identity.
  const result = await request('/rest/v1/rpc/bootstrap_independent_staff_admin', 'POST', {
    target_staff_profile_id: input.staffId, target_auth_user_id: target.id, expected_email: email,
  });
  const bound = result?.staff ?? result;
  if (bound?.profile_id !== input.staffId || bound.auth_user_id !== target.id || bound.email !== email) {
    throw new Error('The staff binding was not acknowledged. Inspect the staff directory before retrying.');
  }
  summary.bound = true;
  if (input.sendCode) {
    await request('/auth/v1/otp', 'POST', { email, create_user: false });
    summary.loginCodeSent = true;
  }
  return summary;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = process.argv.slice(2);
    const take = flag => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };
    const known = new Set(['--staff-id', '--email', '--apply', '--send-code']);
    for (let i = 0; i < args.length; i++) {
      if (!known.has(args[i])) throw new Error('Unknown option. Use --staff-id UUID --email STAFF_EMAIL [--apply] [--send-code].');
      if (['--staff-id', '--email'].includes(args[i])) { if (!args[++i] || args[i].startsWith('--')) throw new Error('A required option value is missing.'); }
    }
    const result = await bootstrapStaffStaging(process.env, { staffId: take('--staff-id'), email: take('--email'), apply: args.includes('--apply'), sendCode: args.includes('--send-code') });
    process.stdout.write(JSON.stringify(result) + '\n');
  } catch (error) { process.stderr.write((error instanceof Error ? error.message : 'Staff bootstrap failed.') + '\n'); process.exitCode = 1; }
}
