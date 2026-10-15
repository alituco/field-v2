-- Local/development only, after all migrations. The caller must wrap this script
-- in BEGIN / ROLLBACK; no real identity is read, changed, or unlinked.
create or replace function pg_temp.google_email_assert(ok boolean,message text)
returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'Google email verification failed: %',message; end if;
end;
$$;
create or replace function pg_temp.google_email_expect_error(statement text,expected_code text)
returns void language plpgsql as $$
declare failed boolean:=false;
begin
  begin execute statement;
  exception when others then
    if sqlstate<>expected_code then raise; end if;
    failed:=true;
  end;
  if not failed then raise exception 'Expected SQLSTATE % from %',expected_code,statement; end if;
end;
$$;

insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,phone,phone_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
  ('fe150000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000',
    'authenticated','authenticated','old.contact@example.test',now(),'15551500001',now(),'{}','{}',now(),now()),
  ('fe150000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000',
    'authenticated','authenticated',null,null,'15551500002',now(),'{}','{}',now(),now()),
  ('fe150000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000',
    'authenticated','authenticated',null,null,'15551500003',now(),'{}','{}',now(),now()),
  ('fe150000-0000-4000-8000-000000000004','00000000-0000-0000-0000-000000000000',
    'authenticated','authenticated',null,null,'15551500004',now(),'{}',
    '{"email":"forged@example.test","email_verified":true,"provider":"google"}',now(),now()),
  ('fe150000-0000-4000-8000-000000000005','00000000-0000-0000-0000-000000000000',
    'authenticated','authenticated',null,null,'15551500005',now(),'{}','{}',now(),now());

-- Start as an ordinary completed phone account. The existing onboarding, rating,
-- city, and public-name rules still run through their original wrapper chain.
select set_config('request.jwt.claims',
  '{"sub":"fe150000-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select public.complete_fieldrush_onboarding(
  '{"first_name":"Google","last_name":"Fixture","username":"google_email_fixture","date_of_birth":"2000-01-01","email":"old.contact@example.test","skill_assessment":"not_sure"}',
  'fieldrush-v1','fieldrush-v1');
select pg_temp.google_email_assert(
  public.get_my_fieldrush_account()->>'email'='old.contact@example.test'
    and (public.get_my_fieldrush_account()->>'email_verified')::boolean
    and public.get_my_fieldrush_account()->'google_email'='null'::jsonb,
  'unlinked accounts keep the existing canonical verification rule');
reset role;

insert into auth.identities(id,provider_id,user_id,provider,identity_data,created_at,updated_at)
values
  ('fe151000-0000-4000-8000-000000000001','google-email-fixture-1',
    'fe150000-0000-4000-8000-000000000001','google',
    '{"email":"Google.Contact@Example.Test","email_verified":true}',now(),now()),
  ('fe151000-0000-4000-8000-000000000002','google-email-fixture-2',
    'fe150000-0000-4000-8000-000000000002','google',
    '{"email":"string-verified@example.test","email_verified":"true"}',now(),now()),
  ('fe151000-0000-4000-8000-000000000003','google-email-fixture-3',
    'fe150000-0000-4000-8000-000000000003','google',
    '{"email":"unverified@example.test","email_verified":false}',now(),now()),
  ('fe151000-0000-4000-8000-000000000005','other-email-fixture-5',
    'fe150000-0000-4000-8000-000000000005','github',
    '{"email":"other-provider@example.test","email_verified":true}',now(),now());

set local role authenticated;
select pg_temp.google_email_assert(
  public.get_my_fieldrush_account()->>'email'='google.contact@example.test'
    and public.get_my_fieldrush_account()->>'google_email'='google.contact@example.test'
    and (public.get_my_fieldrush_account()->>'email_verified')::boolean
    and (public.get_my_fieldrush_account()->>'google_linked')::boolean,
  'a verified Google identity supplies its normalized contact email without an OTP');
select pg_temp.google_email_assert(
  public.get_my_fieldrush_account() ?& array['preferred_city_id','home_city','skill_assessment',
    'skill_assessment_required','rating_initialized','onboarding_completed']
    and (public.get_my_fieldrush_account()->>'onboarding_completed')::boolean,
  'the projection preserves city, onboarding and rating fields');
select pg_temp.google_email_expect_error($q$select public.update_my_fieldrush_account(
  '{"first_name":"Google","last_name":"Fixture","username":"google_email_fixture","date_of_birth":"2000-01-01","email":"new.contact@example.test"}')$q$,'22023');
select public.update_my_fieldrush_account(
  '{"first_name":"Updated","last_name":"Fixture","username":"google_email_fixture","date_of_birth":"2000-01-01","email":"GOOGLE.CONTACT@EXAMPLE.TEST"}');
select pg_temp.google_email_assert(
  public.get_my_fieldrush_account()->>'first_name'='Updated',
  'case-only email normalization and unrelated account edits remain allowed');
select pg_temp.google_email_expect_error($q$select public.update_my_fieldrush_account(
  '{"first_name":"Updated","last_name":"Fixture","username":"google_email_fixture","date_of_birth":"2001-01-01","email":"google.contact@example.test"}')$q$,'22023');
select pg_temp.google_email_expect_error($q$select public.update_my_fieldrush_account(
  '{"first_name":"Updated","last_name":"Fixture","username":"google_email_fixture","date_of_birth":"2000-01-01","email":"google.contact@example.test","skill_assessment":"advanced"}')$q$,'22023');
select pg_temp.google_email_expect_error(
  'select public.get_my_fieldrush_account_before_google_contact()','42501');
select pg_temp.google_email_expect_error(
  $q$select fieldrush_private.linked_google_email('fe150000-0000-4000-8000-000000000002')$q$,'42501');
reset role;

-- Reading the projection never writes private contact information.
update fieldrush_private.accounts set email='saved.draft@example.test'
  where user_id='fe150000-0000-4000-8000-000000000001';
set local role authenticated;
select public.get_my_fieldrush_account();
reset role;
select pg_temp.google_email_assert((select email='saved.draft@example.test'
  from fieldrush_private.accounts where user_id='fe150000-0000-4000-8000-000000000001'),
  'account reads must remain read-only');

-- Strings, unverified provider claims, editable user metadata, and another
-- provider must never masquerade as a verified linked Google email.
select set_config('request.jwt.claims',
  '{"sub":"fe150000-0000-4000-8000-000000000002","role":"authenticated"}',true);
set local role authenticated;
select pg_temp.google_email_assert(public.get_my_fieldrush_account()->'google_email'='null'::jsonb
    and public.get_my_fieldrush_account()->>'email'=''
    and not (public.get_my_fieldrush_account()->>'email_verified')::boolean,
  'a string true is not a boolean verified claim and cannot disclose another user email');
reset role;
select set_config('request.jwt.claims',
  '{"sub":"fe150000-0000-4000-8000-000000000003","role":"authenticated"}',true);
set local role authenticated;
select pg_temp.google_email_assert(public.get_my_fieldrush_account()->'google_email'='null'::jsonb
    and not (public.get_my_fieldrush_account()->>'email_verified')::boolean,
  'an unverified Google email supplies no verification proof');
reset role;
select set_config('request.jwt.claims',
  '{"sub":"fe150000-0000-4000-8000-000000000004","role":"authenticated"}',true);
set local role authenticated;
select pg_temp.google_email_assert(public.get_my_fieldrush_account()->'google_email'='null'::jsonb
    and public.get_my_fieldrush_account()->>'email'=''
    and not (public.get_my_fieldrush_account()->>'google_linked')::boolean,
  'editable user metadata cannot create a linked or verified Google email');
reset role;
select set_config('request.jwt.claims',
  '{"sub":"fe150000-0000-4000-8000-000000000005","role":"authenticated"}',true);
set local role authenticated;
select pg_temp.google_email_assert(public.get_my_fieldrush_account()->'google_email'='null'::jsonb
    and not (public.get_my_fieldrush_account()->>'email_verified')::boolean,
  'other providers are not Google');
reset role;

-- Malformed identity values remain untrusted even with a true verified flag.
update auth.identities set identity_data='{"email":"invalid-email","email_verified":true}'
  where id='fe151000-0000-4000-8000-000000000003';
select pg_temp.google_email_assert(fieldrush_private.linked_google_email(
  'fe150000-0000-4000-8000-000000000003') is null,'malformed emails are not adopted');
update auth.identities set identity_data='{"email":123,"email_verified":true}'
  where id='fe151000-0000-4000-8000-000000000003';
select pg_temp.google_email_assert(fieldrush_private.linked_google_email(
  'fe150000-0000-4000-8000-000000000003') is null,'non-string emails are not adopted');

-- A Google link can complete while an older client still has a different email
-- in its signup draft. Keep that signup valid, but show Google's verified address.
update auth.identities set identity_data='{"email":"signup.google@example.test","email_verified":true}'
  where id='fe151000-0000-4000-8000-000000000003';
select set_config('request.jwt.claims',
  '{"sub":"fe150000-0000-4000-8000-000000000003","role":"authenticated"}',true);
set local role authenticated;
select public.save_fieldrush_onboarding_draft(
  '{"first_name":"Signup","last_name":"Fixture","username":"google_signup_test","date_of_birth":"2000-01-01","email":"older.draft@example.test"}');
select public.complete_fieldrush_onboarding(
  '{"first_name":"Signup","last_name":"Fixture","username":"google_signup_test","date_of_birth":"2000-01-01","email":"older.draft@example.test","skill_assessment":"not_sure"}',
  'fieldrush-v1','fieldrush-v1');
select pg_temp.google_email_assert(public.get_my_fieldrush_account()->>'email'='signup.google@example.test'
    and (public.get_my_fieldrush_account()->>'email_verified')::boolean
    and (public.get_my_fieldrush_account()->>'onboarding_completed')::boolean,
  'older signup drafts remain compatible without overriding verified Google contact');
reset role;

-- This fixture-only delete models the SQL state after Auth unlinks Google; the
-- app must use Auth's API rather than deleting an identity through SQL.
delete from auth.identities where id='fe151000-0000-4000-8000-000000000001';
select set_config('request.jwt.claims',
  '{"sub":"fe150000-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select public.update_my_fieldrush_account(
  '{"first_name":"Updated","last_name":"Fixture","username":"google_email_fixture","date_of_birth":"2000-01-01","email":"new.contact@example.test"}');
select pg_temp.google_email_assert(public.get_my_fieldrush_account()->>'email'='new.contact@example.test'
    and public.get_my_fieldrush_account()->'google_email'='null'::jsonb
    and not (public.get_my_fieldrush_account()->>'google_linked')::boolean
    and not (public.get_my_fieldrush_account()->>'email_verified')::boolean,
  'after unlinking, a new contact address remains unverified until Auth confirms it');
reset role;
select pg_temp.google_email_assert(
  not has_function_privilege('anon','public.get_my_fieldrush_account()','EXECUTE')
    and not has_function_privilege('anon','public.update_my_fieldrush_account(jsonb)','EXECUTE')
    and not has_function_privilege('authenticated','public.get_my_fieldrush_account_before_google_contact()','EXECUTE'),
  'private wrappers and account endpoints retain their execution grants');
select 'Fieldrush Google contact email verification passed.' as result;
