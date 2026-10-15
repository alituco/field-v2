-- Local/disposable database only, after migrations 010 and 011. Every fixture
-- and the temporary trigger toggle below is transaction-scoped and rolled back.
begin;
set local client_min_messages=warning;
create function pg_temp.seed_expect(ok boolean,message text)
returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Seed verification: %',message; end if; end;
$$;
create function pg_temp.seed_expect_error(statement text,expected_code text)
returns void language plpgsql as $$
begin
  begin execute statement;
  exception when others then
    if sqlstate<>expected_code then raise; end if;
    return;
  end;
  raise exception 'Expected SQLSTATE %: %',expected_code,statement;
end;
$$;

-- These two represent identities that existed before the enrollment trigger.
alter table auth.users disable trigger mark_season_zero_initialization_eligible;
insert into auth.users(id,phone,phone_confirmed_at)
values('fb011000-0000-4000-8000-000000000001','15550110001',now()),
  ('fb011000-0000-4000-8000-000000000002','15550110002',now());
alter table auth.users enable trigger mark_season_zero_initialization_eligible;
insert into public.profiles(id,auth_user_id,display_name)
values('fb011000-0000-4000-8000-000000000001','fb011000-0000-4000-8000-000000000001','Legacy Seed'),
  ('fb011000-0000-4000-8000-000000000002','fb011000-0000-4000-8000-000000000002','Legacy Incomplete')
on conflict(id) do nothing;
insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at,date_of_birth)
values('fb011000-0000-4000-8000-000000000001','active',now(),'2000-01-01'),
  ('fb011000-0000-4000-8000-000000000002','onboarding',null,null)
on conflict(user_id) do update set status=excluded.status,onboarding_completed_at=excluded.onboarding_completed_at,
  date_of_birth=excluded.date_of_birth;
update public.fieldrush_player_rating_tracks set skill_rating=1456,matches_played=12,wins=7,losses=3,draws=2,last_change=11
where profile_id='fb011000-0000-4000-8000-000000000001';
update public.fieldrush_player_rating_tracks set skill_rating=1299
where profile_id='fb011000-0000-4000-8000-000000000002';
select set_config('request.jwt.claim.sub','fb011000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select pg_temp.seed_expect(not (public.get_my_fieldrush_account()->>'skill_assessment_required')::boolean,
  'established account never becomes assessment-required');
select public.complete_fieldrush_onboarding(
  '{"first_name":"Legacy","last_name":"Player","username":"sr_legacy_one","date_of_birth":"2000-01-01","email":"legacy@example.test","skill_assessment":"beginner"}',
  'fieldrush-v1','fieldrush-v1');
reset role;
select pg_temp.seed_expect((select bool_and(skill_rating=1456 and matches_played=12 and wins=7 and losses=3 and draws=2 and last_change=11
  and initial_seed_rating is null) from public.fieldrush_player_rating_tracks where profile_id='fb011000-0000-4000-8000-000000000001'),
  'existing completed account SR, counts, stats and audit remain unchanged');
select set_config('request.jwt.claim.sub','fb011000-0000-4000-8000-000000000002',true);
set local role authenticated;
select pg_temp.seed_expect(not (public.get_my_fieldrush_account()->>'skill_assessment_required')::boolean,
  'pre-existing incomplete identity never becomes seed-eligible');
select public.complete_fieldrush_onboarding(
  '{"first_name":"Legacy","last_name":"Incomplete","username":"sr_legacy_two","date_of_birth":"2000-01-01","email":"legacy2@example.test"}',
  'fieldrush-v1','fieldrush-v1');
reset role;
select pg_temp.seed_expect((select bool_and(skill_rating=1299 and matches_played=0 and initial_seed_rating is null)
  from public.fieldrush_player_rating_tracks where profile_id='fb011000-0000-4000-8000-000000000002'),
  'existing unfinished signup completes without reseeding');

-- All six valid choices initialize both independent pools exactly once.
do $$
declare item record; player uuid; draft jsonb; payload jsonb; original_timestamp timestamptz;
begin
  for item in select * from (values(1,'beginner',800),(2,'casual',900),(3,'intermediate',1000),
    (4,'advanced',1100),(5,'highly_competitive',1200),(6,'not_sure',1000)) choices(n,assessment,seed) loop
    player:=('fb011100-0000-4000-8000-'||lpad(item.n::text,12,'0'))::uuid;
    insert into auth.users(id,phone,phone_confirmed_at,raw_user_meta_data)
      values(player,'1555011010'||item.n,now(),'{"skill_assessment":"highly_competitive","skill_rating":9999,"rating_initialized":true}');
    perform set_config('request.jwt.claim.sub',player::text,true);
    draft:=jsonb_build_object('first_name','New','last_name','Player','username','sr_new_'||item.n,
      'date_of_birth','2000-01-01','email','seed'||item.n||'@example.test');
    perform pg_temp.seed_expect((public.get_my_fieldrush_account()->>'skill_assessment_required')::boolean,
      'new identity requires assessment, regardless of editable auth metadata');
    perform pg_temp.seed_expect(not public.is_fieldrush_account_active(player),'unseeded new identity cannot book');
    perform pg_temp.seed_expect_error(format('select public.complete_fieldrush_onboarding(%L::jsonb,''fieldrush-v1'',''fieldrush-v1'')',draft),'22023');
    perform pg_temp.seed_expect(not exists(select 1 from fieldrush_private.accounts where user_id=player and status='active'),
      'failed seed completion rolls back activation');
    perform public.save_fieldrush_onboarding_draft(draft||jsonb_build_object('skill_assessment',item.assessment));
    perform pg_temp.seed_expect(public.get_my_fieldrush_account()->>'skill_assessment'=item.assessment,'saved choice round-trips');
    -- Completion may reuse the saved server-side choice after an app restart.
    payload:=public.complete_fieldrush_onboarding(draft,'fieldrush-v1','fieldrush-v1');
    perform pg_temp.seed_expect((payload->>'rating_initialized')::boolean and not (payload->>'skill_assessment_required')::boolean,
      'completed account reports initialized');
    perform pg_temp.seed_expect(public.is_fieldrush_account_active(player),'initialized account can participate');
    perform pg_temp.seed_expect((select count(*)=2 and bool_and(skill_rating=item.seed and matches_played=0
      and initial_seed_rating=item.seed and initial_self_assessment=item.assessment
      and initialization_policy_id='field-sr-season0-v2' and rating_initialized_at is not null)
      from public.fieldrush_player_rating_tracks where profile_id=player),'both role pools receive selected seed with immutable audit');
    select min(rating_initialized_at) into original_timestamp from public.fieldrush_player_rating_tracks where profile_id=player;
    update public.fieldrush_player_rating_tracks set skill_rating=skill_rating+51,matches_played=2,wins=2,last_change=25 where profile_id=player;
    payload:=public.complete_fieldrush_onboarding(draft||'{"skill_assessment":"highly_competitive"}', 'fieldrush-v1','fieldrush-v1');
    perform pg_temp.seed_expect(payload->>'skill_assessment'=item.assessment,'retry retains original assessment');
    perform pg_temp.seed_expect((select bool_and(skill_rating=item.seed+51 and matches_played=2 and wins=2 and last_change=25
      and initial_seed_rating=item.seed and rating_initialized_at=original_timestamp)
      from public.fieldrush_player_rating_tracks where profile_id=player),'retry preserves earned SR, count, stats and audit');
    perform public.update_my_fieldrush_account(draft||'{"first_name":"Edited"}');
    perform pg_temp.seed_expect_error(format('select public.update_my_fieldrush_account(%L::jsonb)',draft||'{"skill_assessment":"beginner"}'),'22023');
    perform pg_temp.seed_expect_error(format('update public.fieldrush_player_rating_tracks set initial_seed_rating=700 where profile_id=%L',player),'42501');
  end loop;
end;
$$;

-- Actual authenticated role cannot mutate private eligibility, tracks, or
-- invoke renamed internals. Spoofed IDs / numeric seeds are unknown fields.
select set_config('request.jwt.claim.sub','fb011100-0000-4000-8000-000000000001',true);
set local role authenticated;
select pg_temp.seed_expect_error('select * from fieldrush_rating_private.season_zero_initialization_eligibility','42501');
select pg_temp.seed_expect_error('update public.fieldrush_player_rating_tracks set skill_rating=9000','42501');
select pg_temp.seed_expect_error('select public.get_my_fieldrush_account_before_season_zero_sr()','42501');
select pg_temp.seed_expect_error($q$select public.save_fieldrush_onboarding_draft_before_season_zero_sr('{}')$q$,'42501');
select pg_temp.seed_expect_error($q$select fieldrush_private.write_account_before_season_zero_sr('{}',true)$q$,'42501');
select pg_temp.seed_expect_error($q$select public.complete_fieldrush_onboarding('{"user_id":"fb011000-0000-4000-8000-000000000001","skill_assessment":"beginner"}','fieldrush-v1','fieldrush-v1')$q$,'22023');
select pg_temp.seed_expect_error($q$select public.complete_fieldrush_onboarding('{"skill_rating":9000,"skill_assessment":"beginner"}','fieldrush-v1','fieldrush-v1')$q$,'22023');
select pg_temp.seed_expect_error($q$select public.complete_fieldrush_onboarding('{"skill_assessment":"expert"}','fieldrush-v1','fieldrush-v1')$q$,'22023');
select pg_temp.seed_expect_error($q$select public.complete_fieldrush_onboarding('{"skill_assessment":800}','fieldrush-v1','fieldrush-v1')$q$,'22023');
select pg_temp.seed_expect_error($q$select public.complete_fieldrush_onboarding('{"skill_assessment":{"seed":800}}','fieldrush-v1','fieldrush-v1')$q$,'22023');
reset role;

-- No status bypass: new accounts still need seeding if accidentally activated
-- by a service operation. Existing non-default activity is held, not reset.
insert into auth.users(id,phone,phone_confirmed_at)
values('fb011200-0000-4000-8000-000000000001','15550110201',now());
insert into public.profiles(id,auth_user_id,display_name)
values('fb011200-0000-4000-8000-000000000001','fb011200-0000-4000-8000-000000000001','Unseeded Active')
on conflict(id) do nothing;
insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at,date_of_birth)
values('fb011200-0000-4000-8000-000000000001','active',now(),'2000-01-01')
on conflict(user_id) do update set status='active',onboarding_completed_at=now(),date_of_birth='2000-01-01';
select pg_temp.seed_expect(not public.is_fieldrush_account_active('fb011200-0000-4000-8000-000000000001'),
  'service-side activation alone cannot bypass seed gate');
update public.fieldrush_player_rating_tracks set skill_rating=1210 where profile_id='fb011200-0000-4000-8000-000000000001';
select set_config('request.jwt.claim.sub','fb011200-0000-4000-8000-000000000001',true);
set local role authenticated;
select pg_temp.seed_expect_error($q$select public.complete_fieldrush_onboarding(
  '{"first_name":"Pending","last_name":"Review","username":"sr_pending_review","date_of_birth":"2000-01-01","email":"review@example.test","skill_assessment":"beginner"}',
  'fieldrush-v1','fieldrush-v1')$q$,'22023');
select pg_temp.seed_expect(not (public.get_my_fieldrush_account()->>'onboarding_completed')::boolean,
  'unseeded active account is not falsely presented as completed');
reset role;
select pg_temp.seed_expect((select bool_and(skill_rating=1210 and initial_seed_rating is null)
  from public.fieldrush_player_rating_tracks where profile_id='fb011200-0000-4000-8000-000000000001'),
  'unexpected prior activity is preserved for review');
select set_config('request.jwt.claim.sub','',true);
set local role authenticated;
select pg_temp.seed_expect_error('select public.get_my_fieldrush_account()','42501');
reset role;
select 'Season 0 once-only initialization verification passed.' as result;
rollback;
