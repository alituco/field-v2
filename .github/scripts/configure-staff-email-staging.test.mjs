import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { configureStaffEmailStaging, staffEmailOwnedKeys } from './configure-staff-email-staging.mjs';
// Ephemeral values for the injected HTTP mock, never real service credentials.
const env = { SUPABASE_PROJECT_REF: 'nfdkdhdevpstfspazbfn', SUPABASE_ACCESS_TOKEN: randomUUID() };
const baseline = { external_email_enabled: true, smtp_host: 'smtp.resend.com', smtp_user: 'resend', smtp_port: '465', smtp_admin_email: 'no-reply@auth.fieldrush.gg', smtp_pass: randomUUID(), mailer_autoconfirm: false, mailer_secure_email_change_enabled: false, mailer_templates_email_change_content: 'player-verification', external_google_enabled: true, external_phone_enabled: true };
function harness(drift = false) {
  let config = structuredClone(baseline);
  const calls = [];
  return { calls, fetcher: async (_url, opts) => {
    calls.push(opts);
    if (opts.method === 'PATCH') { Object.assign(config, JSON.parse(opts.body)); if (drift) config.external_google_enabled = false; return Response.json({}); }
    return Response.json(config);
  } };
}
test('staff email setup is dry-run by default and never exposes SMTP credentials', async () => {
  const h = harness();
  const result = await configureStaffEmailStaging(env, h);
  assert.equal(result.mode, 'dry-run');
  assert.deepEqual(result.changedKeys.sort(), [...staffEmailOwnedKeys].sort());
  assert.equal(h.calls.length, 1);
  assert.ok(!JSON.stringify(result).includes(baseline.smtp_pass));
  assert.ok(!JSON.stringify(result).includes(env.SUPABASE_ACCESS_TOKEN));
});
test('only first-login and returning-login code templates plus six-digit expiry are patched', async () => {
  const h = harness();
  const result = await configureStaffEmailStaging(env, { ...h, apply: true });
  const patch = JSON.parse(h.calls.find(call => call.method === 'PATCH').body);
  assert.deepEqual(Object.keys(patch).sort(), [...staffEmailOwnedKeys].sort());
  assert.equal(patch.mailer_otp_length, 6);
  assert.equal(patch.mailer_otp_exp, 600);
  assert.match(patch.mailer_templates_confirmation_content, /\{\{ \.Token \}\}/);
  assert.equal(result.verified, true);
});
test('production and unsafe templates are refused before requests', async () => {
  const h = harness();
  await assert.rejects(configureStaffEmailStaging({ ...env, SUPABASE_PROJECT_REF: 'production' }, h), /exact staging/);
  await assert.rejects(configureStaffEmailStaging(env, { ...h, template: '<script>{{ .Token }}</script>' }), /reviewed/);
  assert.equal(h.calls.length, 0);
});
test('unowned Google/phone/player email verification drift fails instead of claiming success', async () => {
  const h = harness(true);
  await assert.rejects(configureStaffEmailStaging(env, { ...h, apply: true }), /unowned Auth setting/);
});
