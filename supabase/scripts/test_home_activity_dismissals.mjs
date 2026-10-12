// Isolated notification receipt checks: never connects to a hosted project.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_home_activity_dismissals.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const recipient = '10000000-0000-0000-0000-000000000001';
const other = '10000000-0000-0000-0000-000000000002';
const notice = '20000000-0000-0000-0000-000000000001';
const foreignNotice = '20000000-0000-0000-0000-000000000002';
const readNotice = '20000000-0000-0000-0000-000000000003';

await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema auth;
create function auth.uid() returns uuid language sql as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to authenticated;
create table public.notifications (
  id uuid primary key,
  recipient_profile_id uuid not null,
  title text not null,
  body text not null,
  read_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.notifications enable row level security;
grant select on public.notifications to authenticated;
create policy notifications_recipient_select on public.notifications
  for select to authenticated using (recipient_profile_id = auth.uid());
insert into public.notifications (id,recipient_profile_id,title,body,read_at)
values
  ('${notice}','${recipient}','Refund update','Refund is pending',null),
  ('${foreignNotice}','${other}','Private update','Other player receipt',null),
  ('${readNotice}','${recipient}','Party invitation','Invitation still active','2026-01-01Z');
create table public.operational_outcomes (kind text primary key, state text);
insert into public.operational_outcomes values
  ('REFUND','PENDING'),('PARTY_INVITE','INVITED'),('SUPPORT_TICKET','OPEN');
`);
const migration = await readFile(
  new URL('../migrations/20261012000200_home_activity_dismissals.sql', import.meta.url),
  'utf8',
);
await db.exec(migration);
await db.exec(migration); // Safe to re-run without changing existing receipts.

let checks = 0;
async function check(sql, expected = true) {
  const { rows } = await db.query(sql);
  assert.equal(Object.values(rows[0])[0], expected, sql);
  checks++;
}
async function rejects(sql, message) {
  await assert.rejects(db.exec(sql), message);
  checks++;
}

await rejects(`select public.dismiss_my_home_notification('${notice}')`, /Authentication required/);
await db.exec(`set role authenticated; set request.jwt.claim.sub = '${recipient}';`);
await check(`select count(*)::integer from public.notifications`, 2);
await rejects(`update public.notifications set dismissed_at = now() where id = '${notice}'`, /permission denied/);
await rejects(`select public.dismiss_my_home_notification('${foreignNotice}')`, /Notification not found/);
await rejects(`select public.dismiss_my_home_notification('20000000-0000-0000-0000-000000000099')`, /Notification not found/);
await db.exec(`select public.dismiss_my_home_notification('${notice}')`);
await check(`select dismissed_at is not null and read_at is not null and resolved_at is null
  and title = 'Refund update' and body = 'Refund is pending'
  from public.notifications where id = '${notice}'`);
const before = (await db.query(`select dismissed_at::text, read_at::text from public.notifications where id = '${notice}'`)).rows[0];
await db.exec(`select public.dismiss_my_home_notification('${notice}')`);
const after = (await db.query(`select dismissed_at::text, read_at::text from public.notifications where id = '${notice}'`)).rows[0];
assert.deepEqual(after, before);
checks++;
await db.exec(`select public.dismiss_my_home_notification('${readNotice}')`);
await check(`select read_at = '2026-01-01Z' and resolved_at is null and dismissed_at is not null
  from public.notifications where id = '${readNotice}'`);
await check(`select count(*)::integer from public.notifications
  where recipient_profile_id = auth.uid() and resolved_at is null and dismissed_at is null`, 0);

await db.exec('reset role;');
await check(`select dismissed_at is null and read_at is null and resolved_at is null
  from public.notifications where id = '${foreignNotice}'`);
await check(`select count(*)::integer from public.operational_outcomes
  where (kind,state) in (('REFUND','PENDING'),('PARTY_INVITE','INVITED'),('SUPPORT_TICKET','OPEN'))`, 3);
await check(`select relrowsecurity from pg_class where oid = 'public.notifications'::regclass`);
await check(`select has_function_privilege('authenticated','public.dismiss_my_home_notification(uuid)','EXECUTE')`);
await check(`select not has_function_privilege('anon','public.dismiss_my_home_notification(uuid)','EXECUTE')`);
await check(`select not has_table_privilege('authenticated','public.notifications','UPDATE')`);
console.log(`${checks} isolated home-activity dismissal checks passed.`);
await db.close();
