import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  configureEmailStaging, differentUnownedKeys, emailPatch, ownedKeys,
  safeConfigurationSnapshot, stagingProject,
} from './configure-email-staging.mjs';

const template = readFileSync(new URL('../../supabase/templates/fieldrush-email-change.html', import.meta.url), 'utf8');
// Ephemeral sentinels for the in-memory fake transport, not service credentials.
// Checking their actual values below keeps redaction tests sensitive to leaks.
const fixtureCredentials = Object.freeze({
  management: randomUUID(),
  smtp: randomUUID(),
  changedSmtp: randomUUID(),
  google: randomUUID(),
});
const env = { SUPABASE_PROJECT_REF: stagingProject, SUPABASE_ACCESS_TOKEN: fixtureCredentials.management };
const before = {
  external_email_enabled: true,
  smtp_host: 'smtp.resend.com', smtp_port: '465', smtp_user: 'resend',
  smtp_admin_email: 'no-reply@auth.fieldrush.gg', smtp_sender_name: 'Fieldrush Staging',
  smtp_pass: fixtureCredentials.smtp, smtp_max_frequency: 60,
  mailer_otp_length: 8, mailer_otp_exp: 3600,
  mailer_autoconfirm: true, mailer_secure_email_change_enabled: true,
  mailer_allow_unverified_email_sign_ins: null,
  mailer_subjects_email_change: 'Confirm Email Change',
  mailer_templates_email_change_content: '<a href="{{ .ConfirmationURL }}">Confirm</a>',
  sms_autoconfirm: false, sms_otp_length: 6, sms_otp_exp: 60, sms_provider: 'twilio',
  external_google_enabled: true, external_google_secret: fixtureCredentials.google,
  site_url: 'https://ops-staging.field.bh',
};

function assertNoFixtureCredentials(value) {
  const serialized = JSON.stringify(value);
  for (const credential of Object.values(fixtureCredentials)) {
    assert.equal(serialized.includes(credential), false, 'Fixture credential must not be exposed.');
  }
}

test('redaction assertions reject every generated fixture credential', () => {
  for (const credential of Object.values(fixtureCredentials)) {
    assert.throws(() => assertNoFixtureCredentials({ leaked: credential }), /Fixture credential must not be exposed/);
  }
});

function mockServer({ initial = before, alterAfter = (config) => config, patchStatus = 200 } = {}) {
  let saved = structuredClone(initial);
  let reads = 0;
  const calls = [];
  return {
    calls,
    fetcher: async (url, options) => {
      calls.push({ url, ...options });
      assert.equal(url, `https://api.supabase.com/v1/projects/${stagingProject}/config/auth`);
      if (options.method === 'PATCH') {
        if (patchStatus !== 200) return new Response('private server diagnostics', { status: patchStatus });
        saved = { ...saved, ...JSON.parse(options.body) };
        return Response.json(saved);
      }
      assert.equal(options.method, 'GET');
      reads++;
      return Response.json(reads > 1 ? alterAfter(saved) : saved);
    },
  };
}

test('defaults to dry-run, reads SMTP first, and prints only a credential-free summary', async () => {
  const server = mockServer();
  const summary = await configureEmailStaging(env, { fetcher: server.fetcher });
  assert.equal(summary.mode, 'dry-run');
  assert.equal(summary.verified, false);
  assert.equal(summary.otpLength, 6);
  assert.equal(summary.expiresInSeconds, 600);
  assert.match(summary.templateSha256, /^[a-f0-9]{64}$/);
  assert.deepEqual(server.calls.map(({ method }) => method), ['GET']);
  assert.doesNotMatch(JSON.stringify(summary), /ConfirmationURL|Bearer|<html/);
  assertNoFixtureCredentials(summary);
});

test('refuses a production or missing project ref and missing token before any request', async () => {
  for (const invalid of [
    { ...env, SUPABASE_PROJECT_REF: 'zjsjuuhborxrlmdcpvlj' },
    { ...env, SUPABASE_PROJECT_REF: '' },
    { ...env, SUPABASE_ACCESS_TOKEN: '' },
  ]) {
    let requests = 0;
    await assert.rejects(configureEmailStaging(invalid, { fetcher: async () => { requests++; } }));
    assert.equal(requests, 0);
  }
});

test('requires an explicit boolean to authorize application', async () => {
  await assert.rejects(configureEmailStaging(env, { apply: 'true' }), /explicit boolean/);
});

test('only patches the six reviewed email keys, then verifies all settings with another GET', async () => {
  const server = mockServer();
  const summary = await configureEmailStaging(env, { apply: true, fetcher: server.fetcher });
  assert.deepEqual(server.calls.map(({ method }) => method), ['GET', 'PATCH', 'GET']);
  const patch = JSON.parse(server.calls[1].body);
  assert.deepEqual(Object.keys(patch), ownedKeys);
  assert.deepEqual(patch, emailPatch(template));
  assert.equal(patch.mailer_otp_length, 6);
  assert.equal(patch.mailer_otp_exp, 600);
  assert.equal(patch.mailer_autoconfirm, false);
  assert.equal(patch.mailer_secure_email_change_enabled, false);
  assert.doesNotMatch(JSON.stringify(patch), /smtp_|sms_|external_|site_url/);
  assertNoFixtureCredentials(patch);
  assert.equal(summary.verified, true);
});

test('new-address-only confirmation keeps six digits, ten-minute expiry and real ownership checks', async () => {
  const patch = emailPatch(template);
  const localConfig = readFileSync(new URL('../../supabase/config.toml', import.meta.url), 'utf8');
  const localEmail = localConfig.split('[auth.email]')[1].split('\n[')[0];
  assert.match(localEmail, /^double_confirm_changes = false$/m);
  assert.deepEqual({
    otpLength: patch.mailer_otp_length,
    expiresInSeconds: patch.mailer_otp_exp,
    autoConfirm: patch.mailer_autoconfirm,
    confirmPreviousInbox: patch.mailer_secure_email_change_enabled,
  }, {
    otpLength: 6,
    expiresInSeconds: 600,
    autoConfirm: false,
    confirmPreviousInbox: false,
  });
  const server = mockServer({ initial: { ...before, ...patch, mailer_secure_email_change_enabled: true } });
  const summary = await configureEmailStaging(env, { fetcher: server.fetcher });
  assert.deepEqual(summary.changedKeys, ['mailer_secure_email_change_enabled']);
  assert.deepEqual(server.calls.map(({ method }) => method), ['GET']);
});

test('idempotent apply still reads before and after without rewriting unchanged settings', async () => {
  const server = mockServer({ initial: { ...before, ...emailPatch(template) } });
  const summary = await configureEmailStaging(env, { apply: true, fetcher: server.fetcher });
  assert.deepEqual(server.calls.map(({ method }) => method), ['GET', 'GET']);
  assert.deepEqual(summary.changedKeys, []);
  assert.equal(summary.verified, true);
});

test('refuses incomplete or unexpected SMTP without overwriting credentials or provider settings', async () => {
  for (const changed of [
    { external_email_enabled: false }, { smtp_host: '' }, { smtp_user: 'other' },
    { smtp_port: '25' }, { smtp_admin_email: 'other@example.com' },
  ]) {
    const server = mockServer({ initial: { ...before, ...changed } });
    await assert.rejects(configureEmailStaging(env, { apply: true, fetcher: server.fetcher }), /Saved staging email/);
    assert.deepEqual(server.calls.map(({ method }) => method), ['GET']);
  }
});

test('read-after-write detects unapplied settings and never claims success', async () => {
  const server = mockServer({ alterAfter: (config) => ({ ...config, mailer_otp_length: 8 }) });
  await assert.rejects(configureEmailStaging(env, { apply: true, fetcher: server.fetcher }), /did not match after applying: mailer_otp_length/);
  assert.equal(server.calls.length, 3);
});

test('detects unrelated SMS, Google or SMTP drift without restoring or printing their values', async () => {
  for (const changed of [
    { sms_otp_length: 8 }, { external_google_enabled: false }, { smtp_pass: fixtureCredentials.changedSmtp },
  ]) {
    const server = mockServer({ alterAfter: (config) => ({ ...config, ...changed }) });
    await assert.rejects(configureEmailStaging(env, { apply: true, fetcher: server.fetcher }), (error) => {
      assert.equal(error.message, `Unrelated staging Auth settings changed during configuration: ${Object.keys(changed)[0]}. Inspect before retrying; no rollback was attempted.`);
      assert.deepEqual(error.diagnostic.unrelatedChangedKeys, Object.keys(changed));
      assertNoFixtureCredentials(error.diagnostic);
      return true;
    });
    assert.equal(server.calls.length, 3);
  }
});

test('deep comparison ignores object-key ordering but never silently treats null, absent or false as equivalent', () => {
  assert.deepEqual(differentUnownedKeys({ nested: { a: 1, b: 2 } }, { nested: { b: 2, a: 1 } }), []);
  for (const [left, right] of [[null, false], [1, '1'], [[], {}]]) {
    assert.deepEqual(differentUnownedKeys({ example: left }, { example: right }), ['example']);
  }
  assert.deepEqual(differentUnownedKeys({}, { example: null }), ['example']);
});

test('default normalization remains drift, with safe before/after evidence and exact key name', async () => {
  const events = [];
  const server = mockServer({ alterAfter: (config) => ({ ...config, mailer_allow_unverified_email_sign_ins: false }) });
  await assert.rejects(configureEmailStaging(env, { apply: true, fetcher: server.fetcher, onDiagnostic: (event) => events.push(event) }), (error) => {
    assert.match(error.message, /configuration: mailer_allow_unverified_email_sign_ins/);
    assert.deepEqual(error.diagnostic.before.mailer_allow_unverified_email_sign_ins, { present: true, value: null });
    assert.deepEqual(error.diagnostic.after.mailer_allow_unverified_email_sign_ins, { present: true, value: false });
    return true;
  });
  assert.equal(events.length, 1);
  assert.equal(events[0].phase, 'before-apply');
  assert.match(events[0].recordedAt, /^\d{4}-\d{2}-\d{2}T/);
  assert.deepEqual(events[0].flags.mailer_allow_unverified_email_sign_ins, { present: true, value: null });
  assertNoFixtureCredentials(events);
  assert.equal(server.calls.length, 3);
});

test('safe snapshots include only fixed public numeric/boolean flags and report unexpected types without values', () => {
  const snapshot = safeConfigurationSnapshot({
    ...before,
    sms_otp_exp: 'private-unexpected-value',
    attacker_controlled: 'private-extra-value',
  });
  assert.deepEqual(snapshot.sms_otp_exp, { present: true, valueType: 'string' });
  assert.deepEqual(snapshot.external_phone_enabled, { present: false });
  assert.deepEqual(snapshot.mailer_autoconfirm, { present: true, value: true });
  assert.doesNotMatch(JSON.stringify(snapshot), /private-|smtp_pass|google_secret|site_url|attacker_controlled/);
  assertNoFixtureCredentials(snapshot);
});

test('drift key names cannot inject arbitrary provider text into diagnostics', async () => {
  const server = mockServer({ alterAfter: (config) => ({ ...config, 'Bearer private-provider-token': true }) });
  await assert.rejects(configureEmailStaging(env, { apply: true, fetcher: server.fetcher }), (error) => {
    assert.match(error.message, /\[unrecognized-key\]/);
    assert.doesNotMatch(error.message + JSON.stringify(error.diagnostic), /private-provider-token/);
    return true;
  });
});

test('safe before-apply evidence is reported before a failed PATCH or failed read-after', async () => {
  const events = [];
  const server = mockServer({ patchStatus: 400 });
  await assert.rejects(configureEmailStaging(env, { apply: true, fetcher: server.fetcher, onDiagnostic: (event) => events.push(event) }));
  assert.equal(events.length, 1);
  assert.equal(events[0].phase, 'before-apply');
  const methodsAtReport = [];
  const failAfter = mockServer();
  let calls = 0;
  await assert.rejects(configureEmailStaging(env, {
    apply: true,
    onDiagnostic: () => methodsAtReport.push(failAfter.calls.map(({ method }) => method)),
    fetcher: async (...args) => {
      if (++calls === 3) throw new Error('private read-after diagnostics');
      return failAfter.fetcher(...args);
    },
  }), /GET request could not be completed/);
  assert.deepEqual(methodsAtReport, [['GET']]);
});

test('provider and network errors never surface private request or response diagnostics', async () => {
  const server = mockServer({ patchStatus: 400 });
  await assert.rejects(configureEmailStaging(env, { apply: true, fetcher: server.fetcher }), {
    message: 'Staging Auth PATCH failed (HTTP 400).',
  });
  await assert.rejects(configureEmailStaging(env, { fetcher: async () => { throw new Error('Bearer private token'); } }), {
    message: 'Staging Auth GET request could not be completed.',
  });
});

test('email template includes both OTP and secure confirmation without third-party trackers', () => {
  const patch = emailPatch(template);
  assert.match(patch.mailer_templates_email_change_content, /{{ \.Token }}/);
  assert.match(patch.mailer_templates_email_change_content, /href="{{ \.ConfirmationURL }}"/);
  assert.match(template, /six-digit code/);
  assert.match(template, /10 minutes/);
  assert.doesNotMatch(template, /current and new inboxes|previous inbox|old inbox|both inboxes/i);
  assert.doesNotMatch(template, /https?:|<(?:script|iframe|form|input|img)\b/i);
  for (const invalid of [template.replace('{{ .Token }}', ''), template.replace('{{ .ConfirmationURL }}', ''), template + '<script>bad</script>']) {
    assert.throws(() => emailPatch(invalid));
  }
});

test('staging native CI flavors enable email while production flavors explicitly leave it disabled', () => {
  const workflow = readFileSync(new URL('../workflows/ci.yml', import.meta.url), 'utf8');
  for (const platform of ['Android', 'iOS']) {
    const section = workflow.match(new RegExp(`- name: Build ${platform} staging[^]*?(?=\\n      - name: Build ${platform} production)`))?.[0];
    assert.ok(section, platform);
    assert.match(section, /--dart-define=EMAIL_DELIVERY_ENABLED=true/);
    assert.doesNotMatch(section, /--dart-define=EMAIL_DELIVERY_ENABLED=false/);
    const production = workflow.match(new RegExp(`- name: Build ${platform} production[^]*?(?=\\n  [a-z]|$)`))?.[0];
    assert.match(production, /--dart-define=EMAIL_DELIVERY_ENABLED=false/);
    assert.doesNotMatch(production, /--dart-define=EMAIL_DELIVERY_ENABLED=true/);
  }
  const testflight = readFileSync(new URL('./upload-staging-testflight.sh', import.meta.url), 'utf8');
  assert.match(testflight, /--dart-define=EMAIL_DELIVERY_ENABLED=true/);
  assert.match(testflight, /expected_ref="refs\/heads\/staging"/);
  const example = readFileSync(new URL('../../mobile/.env.example', import.meta.url), 'utf8');
  assert.match(example, /^EMAIL_DELIVERY_ENABLED=false$/m);
});
