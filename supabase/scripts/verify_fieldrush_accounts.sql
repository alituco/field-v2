-- Run ONLY against local/development Postgres with ON_ERROR_STOP, after the
-- migration. Wrap migration + this script in a transaction and ROLLBACK to
-- validate without retaining test data. The script does not commit or reset.
-- Example: psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -c BEGIN \
--   -f supabase/migrations/20261009000000_create_fieldrush_accounts.sql \
--   -f supabase/scripts/verify_fieldrush_accounts.sql -c ROLLBACK

create function pg_temp.check_assert(ok boolean, message text)
returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'Fieldrush verification failed: %', message; end if;
end;
$$;
create function pg_temp.expect_error(statement text, expected_code text)
returns void language plpgsql as $$
declare failed boolean := false;
begin
  begin execute statement;
  exception when others then
    if sqlstate <> expected_code then raise; end if;
    failed := true;
  end;
  if not failed then raise exception 'Expected SQLSTATE % from %', expected_code, statement; end if;
end;
$$;

-- Synthetic IDs are transaction-local and rolled back by the caller.
insert into auth.users (id, instance_id, aud, role, email, phone, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('fd000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', null, '15550001001', now(), '{}',
   '{"onboarding_completed":true,"role":"admin","date_of_birth":"2000-01-01"}', now(), now()),
  ('fd000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', null, '15550001002', now(), '{}', '{}', now(), now()),
  ('fd000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'unverified@example.test', '15550001003', null, '{}', '{}', now(), now());

select set_config('request.jwt.claims', jsonb_build_object(
  'sub', 'fd000000-0000-4000-8000-000000000001', 'role', 'authenticated',
  'amr', jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select pg_temp.check_assert(not (public.get_my_fieldrush_account()->>'onboarding_completed')::boolean,
  'editable Auth metadata must not complete onboarding');
select pg_temp.check_assert(not public.is_fieldrush_account_active('fd000000-0000-4000-8000-000000000001'),
  'incomplete account must not be active');
select pg_temp.expect_error($q$insert into public.profiles (id,display_name)
  values ('fd000000-0000-4000-8000-000000000001','Fake name')$q$, '42501');
select pg_temp.expect_error($q$select public.save_my_onboarding_profile('Fake name','2000-01-01')$q$, '42501');
select pg_temp.expect_error($q$select public.save_my_account_details(
  'Fake name', 'administrator', '', null, 'Phoenix', '2000-01-01')$q$, '42501');
select pg_temp.expect_error($q$select * from fieldrush_private.accounts$q$, '42501');
select pg_temp.expect_error($q$select phone from public.profiles$q$, '42501');
select pg_temp.expect_error($q$select date_of_birth from public.profiles$q$, '42501');
select pg_temp.expect_error($q$select auth_user_id from public.profiles$q$, '42501');

select pg_temp.check_assert(not (public.check_fieldrush_username('a.d_m.i.n')->>'available')::boolean,
  'separator impersonation must be reserved');
select pg_temp.check_assert(not (public.check_fieldrush_username('developer')->>'available')::boolean,
  'developer must be reserved');
select pg_temp.check_assert((public.check_fieldrush_username('devin')->>'available')::boolean,
  'ordinary names containing dev must remain valid');
select pg_temp.check_assert(not (public.check_fieldrush_username('ab')->>'available')::boolean,
  'username must have three characters');
select pg_temp.check_assert(not (public.check_fieldrush_username('.player')->>'available')::boolean,
  'leading separator must be rejected');
select pg_temp.check_assert(not (public.check_fieldrush_username('player..one')->>'available')::boolean,
  'repeated separator must be rejected');
select pg_temp.expect_error($q$select public.save_fieldrush_onboarding_draft('{"first_name":"Alice","status":"active"}')$q$, '22023');
select pg_temp.expect_error($q$select public.save_fieldrush_onboarding_draft('{"first_name":123}')$q$, '22023');
select pg_temp.expect_error($q$select public.save_fieldrush_onboarding_draft('{"date_of_birth":"2000-02-30"}')$q$, '22023');
select pg_temp.expect_error(format('select public.save_fieldrush_onboarding_draft(%L::jsonb)',
  jsonb_build_object('date_of_birth', (current_date - interval '18 years' + interval '1 day')::date)), '22023');
select public.save_fieldrush_onboarding_draft(jsonb_build_object('first_name','Alex', 'last_name','Morgan',
  'username','fieldrush_test_alex', 'date_of_birth',(current_date - interval '18 years')::date,
  'email','alex@example.test','skill_assessment','not_sure'));
select pg_temp.check_assert(public.get_my_fieldrush_account()->>'first_name' = 'Alex', 'draft must persist');
select pg_temp.check_assert(not exists(select 1 from public.profiles where id = 'fd000000-0000-4000-8000-000000000001'),
  'draft must not create a publicly discoverable profile');
select pg_temp.expect_error($q$select public.complete_fieldrush_onboarding(
  '{"first_name":"Alex","last_name":"Morgan","username":"fieldrush_test_alex","date_of_birth":"2000-01-01","email":"alex@example.test"}',
  'old-terms','fieldrush-v1')$q$, '22023');
select pg_temp.expect_error($q$select public.complete_fieldrush_onboarding(
  '{"first_name":"Alex","last_name":"Morgan"}', 'fieldrush-v1','fieldrush-v1')$q$, '22023');
select public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Alex','last_name','Morgan',
  'username','fieldrush_test_alex','date_of_birth',(current_date - interval '18 years')::date,
  'email','alex@example.test'), 'fieldrush-v1', 'fieldrush-v1');
select pg_temp.check_assert(public.get_my_fieldrush_account()->>'status' = 'active', 'completion must activate account');
select pg_temp.check_assert((public.get_my_fieldrush_account()->>'phone_verified')::boolean, 'phone proof comes from Auth');
select pg_temp.check_assert(not (public.get_my_fieldrush_account()->>'email_verified')::boolean,
  'manually supplied email must not become verified');
select pg_temp.check_assert((select display_name = 'Alex M.' from public.profiles
  where id = 'fd000000-0000-4000-8000-000000000001'), 'public identity uses last initial only');
select pg_temp.expect_error($q$update public.profiles set display_name = 'Administrator'
  where id = 'fd000000-0000-4000-8000-000000000001'$q$, '42501');
select public.complete_fieldrush_tour();
select pg_temp.check_assert((public.get_my_fieldrush_account()->>'tour_completed')::boolean, 'tour completion persists');
reset role;
select pg_temp.check_assert((select count(*) = 2 from fieldrush_private.legal_acceptances
  where user_id = 'fd000000-0000-4000-8000-000000000001'), 'both legal acceptances recorded');
select pg_temp.check_assert((select date_of_birth is null from public.profiles
  where id = 'fd000000-0000-4000-8000-000000000001'), 'DOB stays out of public profiles');
insert into public.profile_settings (profile_id, home_city)
  values ('fd000000-0000-4000-8000-000000000001', 'Phoenix');

select set_config('request.jwt.claims', '{"sub":"fd000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.expect_error($q$select public.complete_fieldrush_onboarding(
  '{"first_name":"Sam","last_name":"Smith","username":"fieldrush_test_sam","date_of_birth":"2000-01-01","email":"sam@example.test","skill_assessment":"not_sure"}',
  'fieldrush-v1','fieldrush-v1')$q$, '42501');
reset role;

-- Another caller cannot read Alex's private details or take the username.
select set_config('request.jwt.claims', '{"sub":"fd000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.check_assert(public.get_my_fieldrush_account()->>'first_name' = '', 'account RPC scopes reads to caller');
select pg_temp.check_assert(not (public.check_fieldrush_username('FIELDRUSH_TEST_ALEX')->>'available')::boolean,
  'username collision is case-insensitive');
select pg_temp.expect_error($q$select public.complete_fieldrush_onboarding(
  '{"first_name":"Sam","last_name":"Smith","username":"fieldrush_test_alex","date_of_birth":"2000-01-01","email":"sam@example.test","skill_assessment":"not_sure"}',
  'fieldrush-v1','fieldrush-v1')$q$, '23505');
reset role;

-- Trigger guards also run for service-owned booking operations; incomplete
-- players cannot create clans even through SECURITY DEFINER routes.
select pg_temp.expect_error($q$insert into public.clans(name,tag,created_by)
  values ('Fieldrush Test','FRTST','fd000000-0000-4000-8000-000000000002')$q$, '42501');

-- Refreshing a JWT must not count as recent OTP authentication for deletion.
select set_config('request.jwt.claims', jsonb_build_object('sub','fd000000-0000-4000-8000-000000000001',
  'role','authenticated','iat',extract(epoch from now())::bigint,
  'amr',jsonb_build_array(jsonb_build_object('method','otp','timestamp',extract(epoch from now()-interval '1 day')::bigint)))::text,true);
set local role authenticated;
select pg_temp.expect_error('select public.prepare_fieldrush_account_deletion(true)', '42501');
reset role;
select set_config('request.jwt.claims', jsonb_build_object('sub','fd000000-0000-4000-8000-000000000001',
  'role','authenticated','amr',jsonb_build_array(jsonb_build_object('method','otp','timestamp',extract(epoch from now())::bigint)))::text,true);
insert into public.field_wallet_accounts(profile_id,balance_fils)
  values ('fd000000-0000-4000-8000-000000000001',100);
set local role authenticated;
select pg_temp.expect_error('select public.prepare_fieldrush_account_deletion()', '22023');
reset role;
set local role authenticated;
select public.prepare_fieldrush_account_deletion(true);
select pg_temp.check_assert(public.get_my_fieldrush_account()->>'status' = 'deletion_pending', 'deletion must pause the account');
select pg_temp.check_assert(not public.is_fieldrush_account_active('fd000000-0000-4000-8000-000000000001'),
  'pending deletion cannot participate');
reset role;
-- Final deletion forfeits the remaining balance, including settled credits
-- arriving after prepare. Unsettled payment/refund claims still block deletion
-- (covered by verify_account_deletion_wallet_forfeiture.sql).
update public.field_wallet_accounts set balance_fils = 200 where profile_id = 'fd000000-0000-4000-8000-000000000001';
delete from auth.users where id = 'fd000000-0000-4000-8000-000000000001';
select pg_temp.check_assert((select balance_fils=0 from public.field_wallet_accounts
  where profile_id='fd000000-0000-4000-8000-000000000001'), 'deleted wallet must have zero remaining balance');
select pg_temp.check_assert((select sum(amount_fils)=200 from public.field_wallet_transactions
  where profile_id='fd000000-0000-4000-8000-000000000001' and transaction_type='ACCOUNT_DELETION_FORFEITURE'
    and direction='DEBIT'), 'wallet forfeiture must retain an audit debit');
select pg_temp.check_assert((select display_name = 'Deleted player' and phone is null and username is null
  and auth_user_id is null and account_deleted_at is not null from public.profiles
  where id = 'fd000000-0000-4000-8000-000000000001'), 'deleted profile must be anonymized, retaining its historical key');
select pg_temp.check_assert(not exists(select 1 from fieldrush_private.accounts
  where user_id = 'fd000000-0000-4000-8000-000000000001'), 'private identity must be deleted');
select pg_temp.check_assert(not exists(select 1 from fieldrush_private.legal_acceptances
  where user_id = 'fd000000-0000-4000-8000-000000000001'), 'private legal identity must be deleted');
select pg_temp.check_assert(not exists(select 1 from public.profile_settings
  where profile_id = 'fd000000-0000-4000-8000-000000000001'), 'private profile settings must be deleted');
select pg_temp.expect_error($q$update public.field_wallet_accounts set balance_fils = 100
  where profile_id = 'fd000000-0000-4000-8000-000000000001'$q$, '22023');
set local role authenticated;
select pg_temp.expect_error('select public.fieldrush_check_active_user()', '42501');
select pg_temp.expect_error('select public.get_my_fieldrush_account()', '42501');
reset role;
select 'Fieldrush account verification passed.' as result;
