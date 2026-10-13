-- Run ONLY against disposable local Postgres after migrations, with
-- ON_ERROR_STOP. All synthetic records and rate buckets are rolled back.
begin;

create function pg_temp.launch_assert(ok boolean, message text)
returns void language plpgsql as $$
begin
  if ok is not true then
    raise exception 'Launch-interest verification failed: %', message;
  end if;
end;
$$;
create function pg_temp.launch_expect_error(statement text, expected_code text)
returns void language plpgsql as $$
declare failed boolean := false;
begin
  begin execute statement;
  exception when others then
    if sqlstate <> expected_code then raise; end if;
    failed := true;
  end;
  if not failed then
    raise exception 'Expected SQLSTATE % from %', expected_code, statement;
  end if;
end;
$$;

select pg_temp.launch_assert(
  not has_function_privilege('anon', 'public.save_launch_update(text,text,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'public.save_launch_update(text,text,text,text)', 'execute')
  and has_function_privilege('service_role', 'public.save_launch_update(text,text,text,text)', 'execute'),
  'only the trusted server may invoke the signup RPC'
);
select pg_temp.launch_assert(
  not has_function_privilege('anon', 'public.save_waitlist_application(text,text,text,integer,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'public.save_waitlist_application(text,text,text,integer,text,text)', 'execute')
  and has_function_privilege('service_role', 'public.save_waitlist_application(text,text,text,integer,text,text)', 'execute'),
  'only the trusted server may invoke the application RPC'
);
select pg_temp.launch_assert(
  not has_table_privilege('anon', 'public.season_zero_waitlist', 'select')
  and not has_table_privilege('authenticated', 'public.season_zero_waitlist', 'select'),
  'public clients cannot read contact data'
);

insert into public.season_zero_waitlist (
  full_name, email, phone, age, preferred_position, interest, source, status
) values (
  'Legacy applicant', 'launch-legacy@example.test', '+15550001111', 23,
  'MIDFIELDER', 'CLAN_PLAYER', 'FIELD_BH', 'CONTACTED'
);

set local role service_role;
select pg_temp.launch_assert(
  public.save_launch_update(' Launch-New@Example.Test ', 'desktop-hero',
    'launch-updates-v1', repeat('1',64))->>'status' = 'saved',
  'email-only signup succeeds through the server role'
);
select pg_temp.launch_assert(
  public.save_launch_update('launch-legacy@example.test', 'mobile-footer',
    'launch-updates-v1', repeat('2',64))->>'status' = 'saved',
  'an existing application can explicitly consent without a second entry'
);
select pg_temp.launch_expect_error(
  'select * from fieldrush_private.launch_update_rate_limits', '42501'
);
reset role;

select pg_temp.launch_assert((select
  full_name is null and interest = 'LAUNCH_UPDATES' and source = 'FIELDRUSH_GG'
  and signup_placement = 'desktop-hero' and launch_updates_consented_at is not null
  and launch_updates_consent_version = 'launch-updates-v1'
  from public.season_zero_waitlist where email = 'launch-new@example.test'),
  'email normalization and launch consent are saved in the canonical list');
select pg_temp.launch_assert((select
  full_name = 'Legacy applicant' and phone = '+15550001111' and age = 23
  and preferred_position = 'MIDFIELDER' and interest = 'CLAN_PLAYER'
  and source = 'FIELD_BH' and status = 'CONTACTED'
  and signup_placement = 'mobile-footer' and launch_updates_consented_at is not null
  from public.season_zero_waitlist where email = 'launch-legacy@example.test'),
  'consenting preserves existing applicant data and status');

create temporary table initial_launch_consent as
select email, signup_placement, launch_updates_consented_at, updated_at
from public.season_zero_waitlist
where email in ('launch-new@example.test', 'launch-legacy@example.test');

set local role service_role;
select public.save_launch_update('LAUNCH-NEW@EXAMPLE.TEST', 'mobile-hero',
  'launch-updates-v1', repeat('1',64));
select public.save_launch_update('launch-legacy@example.test', 'desktop-footer',
  'launch-updates-v1', repeat('2',64));
reset role;
select pg_temp.launch_assert((select count(*) = 2 from public.season_zero_waitlist
  where email in ('launch-new@example.test', 'launch-legacy@example.test')),
  'duplicates do not create another subscriber');
select pg_temp.launch_assert(not exists (
  select 1 from initial_launch_consent before_signup
  join public.season_zero_waitlist after_signup using (email)
  where before_signup.signup_placement <> after_signup.signup_placement
    or before_signup.launch_updates_consented_at <> after_signup.launch_updates_consented_at
    or before_signup.updated_at <> after_signup.updated_at
), 'duplicates preserve the first consent, placement, and update timestamp');

-- Signup first, full application second: upgrade the same row, including when
-- staff have already changed its status. Source and consent history stay intact.
update public.season_zero_waitlist set status = 'SELECTED'
where email = 'launch-new@example.test';
create temporary table launch_before_application as
select id, email, source, status, created_at, signup_placement,
  launch_updates_consented_at, launch_updates_consent_version
from public.season_zero_waitlist where email = 'launch-new@example.test';
set local role service_role;
select pg_temp.launch_assert(public.save_waitlist_application(
  '  Launch   Applicant ', ' LAUNCH-NEW@EXAMPLE.TEST ', '+15550002222', 27,
  'ATTACKER', 'SOLO_PLAYER'
)->>'status' = 'saved', 'a launch subscriber can submit full player details');
reset role;
select pg_temp.launch_assert((select count(*) = 1 from public.season_zero_waitlist
  where email = 'launch-new@example.test'), 'upgrading retains one list entry');
select pg_temp.launch_assert((select
  full_name = 'Launch Applicant' and phone = '+15550002222' and age = 27
  and preferred_position = 'ATTACKER' and interest = 'SOLO_PLAYER'
  from public.season_zero_waitlist where email = 'launch-new@example.test'),
  'all full application details are saved');
select pg_temp.launch_assert(not exists (
  select 1 from launch_before_application before_application
  join public.season_zero_waitlist after_application using (email)
  where before_application.id <> after_application.id
    or before_application.source <> after_application.source
    or before_application.status <> after_application.status
    or before_application.created_at <> after_application.created_at
    or before_application.signup_placement <> after_application.signup_placement
    or before_application.launch_updates_consented_at <> after_application.launch_updates_consented_at
    or before_application.launch_updates_consent_version <> after_application.launch_updates_consent_version
), 'upgrading preserves the original identity, status, source, and consent');

-- Application first, signup second: add explicit consent without replacing the
-- already reviewed player application or creating another list entry.
set local role service_role;
select pg_temp.launch_assert(public.save_waitlist_application(
  'First Applicant', 'APPLICATION-FIRST@EXAMPLE.TEST', null, 19, null, 'CLAN_LEADER'
)->>'status' = 'saved', 'a full application can be the first interest record');
reset role;
create temporary table application_before_launch as
select id, email, full_name, phone, age, preferred_position, interest,
  source, status, created_at
from public.season_zero_waitlist where email = 'application-first@example.test';
set local role service_role;
select pg_temp.launch_assert(public.save_launch_update(
  'application-first@example.test', 'mobile-hero', 'launch-updates-v1', repeat('7',64)
)->>'status' = 'saved', 'a full applicant can later opt into launch updates');
select pg_temp.launch_assert(public.save_waitlist_application(
  'Replacement Name', 'application-first@example.test', '+15550003333', 31,
  'DEFENDER', 'SOLO_PLAYER'
)->>'status' = 'already_joined', 'repeat full applications report already joined');
reset role;
select pg_temp.launch_assert((select count(*) = 1 from public.season_zero_waitlist
  where email = 'application-first@example.test'), 'application then signup remains one entry');
select pg_temp.launch_assert(not exists (
  select 1 from application_before_launch before_launch
  join public.season_zero_waitlist after_launch using (email)
  where before_launch.id <> after_launch.id
    or before_launch.full_name <> after_launch.full_name
    or before_launch.phone is distinct from after_launch.phone
    or before_launch.age <> after_launch.age
    or before_launch.preferred_position is distinct from after_launch.preferred_position
    or before_launch.interest <> after_launch.interest
    or before_launch.source <> after_launch.source
    or before_launch.status <> after_launch.status
    or before_launch.created_at <> after_launch.created_at
), 'signup and repeated applications preserve existing player details');
select pg_temp.launch_assert((select signup_placement = 'mobile-hero'
  and launch_updates_consented_at is not null
  and launch_updates_consent_version = 'launch-updates-v1'
  from public.season_zero_waitlist where email = 'application-first@example.test'),
  'existing applications receive explicit launch consent');

select pg_temp.launch_expect_error($q$
  insert into public.season_zero_waitlist(email, interest)
  values ('nameless-applicant@example.test','SOLO_PLAYER')
$q$, '23514');
select pg_temp.launch_expect_error($q$
  insert into public.season_zero_waitlist(email, interest, source)
  values ('unconsented-launch@example.test','LAUNCH_UPDATES','FIELDRUSH_GG')
$q$, '23514');

set local role service_role;
select pg_temp.launch_expect_error($q$
  select public.save_launch_update('invalid','desktop-hero','launch-updates-v1',repeat('3',64))
$q$, '22023');
select pg_temp.launch_expect_error($q$
  select public.save_launch_update('invalid-placement@example.test','unknown','launch-updates-v1',repeat('3',64))
$q$, '22023');
select pg_temp.launch_expect_error($q$
  select public.save_launch_update('old-consent@example.test','desktop-hero','old-consent',repeat('3',64))
$q$, '22023');
select pg_temp.launch_expect_error($q$
  select public.save_launch_update('raw-ip@example.test','desktop-hero','launch-updates-v1','192.0.2.1')
$q$, '22023');
select pg_temp.launch_expect_error($q$
  select public.save_waitlist_application(null,'missing-name@example.test',null,20,null,'SOLO_PLAYER')
$q$, '22023');
select pg_temp.launch_expect_error($q$
  select public.save_waitlist_application('Too young','young@example.test',null,11,null,'SOLO_PLAYER')
$q$, '22023');
select pg_temp.launch_expect_error($q$
  select public.save_waitlist_application('Wrong interest','wrong-interest@example.test',null,20,null,'LAUNCH_UPDATES')
$q$, '22023');
select pg_temp.launch_expect_error($q$
  select public.save_waitlist_application('Wrong position','wrong-position@example.test',null,20,'UNKNOWN','SOLO_PLAYER')
$q$, '22023');
select pg_temp.launch_expect_error($q$
  select public.save_waitlist_application('Wrong phone','wrong-phone@example.test','not a number',20,null,'SOLO_PLAYER')
$q$, '22023');

do $$
declare signup_number integer; result jsonb;
begin
  for signup_number in 1..6 loop
    result := public.save_launch_update(
      'launch-rate-' || signup_number || '@example.test', 'desktop-footer',
      'launch-updates-v1', repeat('4',64)
    );
    if signup_number <= 5 then
      perform pg_temp.launch_assert(result->>'status' = 'saved', 'first five requests save');
    else
      perform pg_temp.launch_assert(
        result->>'status' = 'rate_limited'
        and (result->>'retry_after_seconds')::integer between 1 and 900,
        'sixth request is throttled with a retry interval'
      );
    end if;
  end loop;
end;
$$;
reset role;
select pg_temp.launch_assert((select count(*) = 5 from public.season_zero_waitlist
  where email like 'launch-rate-%@example.test'), 'rate-limited requests do not save');

update fieldrush_private.launch_update_rate_limits
set window_started_at = now() - interval '16 minutes'
where rate_identity = repeat('4',64);
insert into fieldrush_private.launch_update_rate_limits values
  (repeat('5',64), now() - interval '2 days', 1);
set local role service_role;
select pg_temp.launch_assert(public.save_launch_update(
  'launch-rate-reset@example.test', 'mobile-hero', 'launch-updates-v1', repeat('4',64)
)->>'status' = 'saved', 'expired windows allow new signups');
reset role;
select pg_temp.launch_assert(not exists(
  select 1 from fieldrush_private.launch_update_rate_limits where rate_identity = repeat('5',64)
), 'expired private hashes are cleaned up');

set local role anon;
select pg_temp.launch_expect_error($q$
  select public.save_launch_update('anon@example.test','desktop-hero','launch-updates-v1',repeat('6',64))
$q$, '42501');
select pg_temp.launch_expect_error('select * from public.season_zero_waitlist', '42501');
select pg_temp.launch_expect_error($q$
  select public.save_waitlist_application('Anon User','anon-application@example.test',null,20,null,'SOLO_PLAYER')
$q$, '42501');
reset role;
set local role authenticated;
select pg_temp.launch_expect_error($q$
  select public.save_launch_update('user@example.test','desktop-hero','launch-updates-v1',repeat('6',64))
$q$, '42501');
select pg_temp.launch_expect_error('select * from public.season_zero_waitlist', '42501');
select pg_temp.launch_expect_error($q$
  select public.save_waitlist_application('Auth User','auth-application@example.test',null,20,null,'SOLO_PLAYER')
$q$, '42501');
reset role;

select 'Launch interest verification passed.' as result;
rollback;
