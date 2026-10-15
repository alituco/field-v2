-- Prospective, once-only self-assessment initialization. Existing identities,
-- including unfinished signups, receive no marker and retain their ratings.
-- This migration does not activate the Season 0 match-calculation policy.
create table fieldrush_rating_private.season_zero_initialization_eligibility (
  user_id uuid primary key references auth.users(id) on delete cascade,
  eligible_at timestamptz not null default clock_timestamp(),
  draft_assessment text check (draft_assessment in (
    'beginner','casual','intermediate','advanced','highly_competitive','not_sure'
  )),
  initialized_at timestamptz
);
revoke all on fieldrush_rating_private.season_zero_initialization_eligibility
  from public,anon,authenticated,service_role;

create function fieldrush_rating_private.mark_season_zero_initialization_eligible()
returns trigger language plpgsql security definer
set search_path=pg_catalog,fieldrush_rating_private,pg_temp as $$
begin
  insert into fieldrush_rating_private.season_zero_initialization_eligibility(user_id)
    values(new.id);
  return new;
end;
$$;
revoke all on function fieldrush_rating_private.mark_season_zero_initialization_eligible()
  from public,anon,authenticated,service_role;
create trigger mark_season_zero_initialization_eligible after insert on auth.users
  for each row execute function fieldrush_rating_private.mark_season_zero_initialization_eligible();

alter table public.fieldrush_player_rating_tracks
  add column initial_self_assessment text,
  add column initial_seed_rating integer,
  add column rating_initialized_at timestamptz,
  add column initialization_policy_id text,
  add constraint fieldrush_rating_tracks_seed_audit_check check (
    (initial_self_assessment is null and initial_seed_rating is null
      and rating_initialized_at is null and initialization_policy_id is null)
    or (initial_self_assessment is not null and initial_seed_rating is not null
      and rating_initialized_at is not null
      and initialization_policy_id is not null
      and initialization_policy_id='field-sr-season0-v2'
      and initial_self_assessment in (
        'beginner','casual','intermediate','advanced','highly_competitive','not_sure'
      )
      and initial_seed_rating=case initial_self_assessment
        when 'beginner' then 800 when 'casual' then 900
        when 'intermediate' then 1000 when 'advanced' then 1100
        when 'highly_competitive' then 1200 when 'not_sure' then 1000 end)
  );
comment on column public.fieldrush_player_rating_tracks.initial_seed_rating is
  'Original once-only self-assessment seed. Null means a preserved pre-existing rating; this is never a current/public SR accumulator.';

create function fieldrush_rating_private.protect_season_zero_seed_audit()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
begin
  if tg_op='UPDATE' and old.rating_initialized_at is not null
    and row(new.initial_self_assessment,new.initial_seed_rating,new.rating_initialized_at,new.initialization_policy_id)
      is distinct from row(old.initial_self_assessment,old.initial_seed_rating,old.rating_initialized_at,old.initialization_policy_id) then
    raise exception 'The original rating assessment and seed are immutable.' using errcode='42501';
  end if;
  if new.rating_initialized_at is not null
    and (tg_op='INSERT' or old.rating_initialized_at is null)
    and not exists (
      select 1 from fieldrush_rating_private.season_zero_initialization_eligibility e
      where e.user_id=new.profile_id and e.initialized_at is null
        and e.draft_assessment=new.initial_self_assessment
    ) then
    raise exception 'This rating is not eligible for self-assessment initialization.' using errcode='42501';
  end if;
  return new;
end;
$$;
revoke all on function fieldrush_rating_private.protect_season_zero_seed_audit()
  from public,anon,authenticated,service_role;
create trigger protect_season_zero_seed_audit before insert or update on public.fieldrush_player_rating_tracks
  for each row execute function fieldrush_rating_private.protect_season_zero_seed_audit();

-- Preserve all established identity validation. The assessment is onboarding
-- data, not a profile-setting field or a client-supplied numeric rating.
create function fieldrush_rating_private.validate_season_zero_onboarding_draft(draft jsonb)
returns void language plpgsql security definer
set search_path=pg_catalog,fieldrush_private,fieldrush_rating_private,pg_temp as $$
begin
  if draft is null or jsonb_typeof(draft)<>'object' then
    raise exception 'Provide valid account details.' using errcode='22023';
  end if;
  perform fieldrush_private.validate_draft(draft-'skill_assessment');
  if draft ? 'skill_assessment' and jsonb_typeof(draft->'skill_assessment') not in ('string','null') then
    raise exception 'Choose a valid skill assessment.' using errcode='22023';
  end if;
  if draft->>'skill_assessment' is not null then
    perform fieldrush_rating_private.season_zero_sr_seed(draft->>'skill_assessment');
  end if;
end;
$$;
revoke all on function fieldrush_rating_private.validate_season_zero_onboarding_draft(jsonb)
  from public,anon,authenticated,service_role;

alter function public.save_fieldrush_onboarding_draft(jsonb)
  rename to save_fieldrush_onboarding_draft_before_season_zero_sr;
revoke all on function public.save_fieldrush_onboarding_draft_before_season_zero_sr(jsonb)
  from public,anon,authenticated,service_role;
create function public.save_fieldrush_onboarding_draft(draft jsonb)
returns void language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,fieldrush_rating_private,pg_temp as $$
declare caller uuid:=fieldrush_private.require_user();
begin
  perform fieldrush_rating_private.validate_season_zero_onboarding_draft(draft);
  -- Match completion's lock order: account, eligibility, then rating tracks.
  insert into fieldrush_private.accounts(user_id) values(caller) on conflict do nothing;
  perform 1 from fieldrush_private.accounts where user_id=caller for update;
  perform public.save_fieldrush_onboarding_draft_before_season_zero_sr(draft-'skill_assessment');
  if draft ? 'skill_assessment' then
    update fieldrush_rating_private.season_zero_initialization_eligibility
      set draft_assessment=draft->>'skill_assessment'
      where user_id=caller and initialized_at is null;
  end if;
end;
$$;
revoke all on function public.save_fieldrush_onboarding_draft(jsonb) from public,anon;
grant execute on function public.save_fieldrush_onboarding_draft(jsonb) to authenticated;

alter function fieldrush_private.write_account(jsonb,boolean)
  rename to write_account_before_season_zero_sr;
revoke all on function fieldrush_private.write_account_before_season_zero_sr(jsonb,boolean)
  from public,anon,authenticated,service_role;
create function fieldrush_private.write_account(draft jsonb,completing boolean)
returns void language plpgsql security definer
set search_path=pg_catalog,public,auth,fieldrush_private,fieldrush_rating_private,pg_temp as $$
declare
  caller uuid:=fieldrush_private.require_user();
  eligibility fieldrush_rating_private.season_zero_initialization_eligibility%rowtype;
  assessment text;
  seed integer;
  initialized_at_to_use timestamptz;
  changed_count integer;
begin
  if not completing then
    -- Existing strict draft validation rejects skill_assessment in settings.
    perform fieldrush_private.write_account_before_season_zero_sr(draft,false);
    return;
  end if;
  perform fieldrush_rating_private.validate_season_zero_onboarding_draft(draft);
  insert into fieldrush_private.accounts(user_id) values(caller) on conflict do nothing;
  perform 1 from fieldrush_private.accounts where user_id=caller for update;
  select * into eligibility from fieldrush_rating_private.season_zero_initialization_eligibility
    where user_id=caller for update;
  if eligibility.user_id is not null and eligibility.initialized_at is null then
    assessment:=coalesce(draft->>'skill_assessment',eligibility.draft_assessment);
    if assessment is null then
      raise exception 'Choose your current skill level before completing signup.' using errcode='22023';
    end if;
    seed:=fieldrush_rating_private.season_zero_sr_seed(assessment);
  end if;
  perform fieldrush_private.write_account_before_season_zero_sr(draft-'skill_assessment',true);
  -- All legacy identities and already-initialized retries stop here. Neither
  -- an assessment edit nor reinstalling can reset a number or calibration.
  if eligibility.user_id is null or eligibility.initialized_at is not null then return; end if;

  perform 1 from public.fieldrush_player_rating_tracks where profile_id=caller
    order by rating_track for update;
  if (select count(*) from public.fieldrush_player_rating_tracks where profile_id=caller)<>2
    or exists(select 1 from public.fieldrush_player_rating_tracks where profile_id=caller
      and (matches_played<>0 or wins<>0 or losses<>0 or draws<>0 or last_change<>0
        or skill_rating<>1200 or rating_initialized_at is not null))
    or exists(select 1 from public.player_rating_events where profile_id=caller) then
    raise exception 'Existing rating activity requires organizer review; it cannot be reseeded.' using errcode='22023';
  end if;
  initialized_at_to_use:=clock_timestamp();
  update fieldrush_rating_private.season_zero_initialization_eligibility
    set draft_assessment=assessment where user_id=caller;
  update public.fieldrush_player_rating_tracks set skill_rating=seed,
    initial_self_assessment=assessment,initial_seed_rating=seed,
    rating_initialized_at=initialized_at_to_use,initialization_policy_id='field-sr-season0-v2'
    where profile_id=caller;
  get diagnostics changed_count=row_count;
  if changed_count<>2 then raise exception 'Both rating pools must be initialized together.'; end if;
  update fieldrush_rating_private.season_zero_initialization_eligibility
    set initialized_at=initialized_at_to_use where user_id=caller;
end;
$$;
revoke all on function fieldrush_private.write_account(jsonb,boolean)
  from public,anon,authenticated,service_role;

-- Reuse the existing account gate, including its Auth/phone requirements.
-- A service-side accidental activation cannot admit an unseeded new player.
create or replace function public.is_fieldrush_account_active(profile_id uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,auth,fieldrush_private,fieldrush_rating_private,pg_temp as $$
  select exists(select 1 from fieldrush_private.accounts a join auth.users u on u.id=a.user_id
    where a.user_id=profile_id and a.status='active' and a.onboarding_completed_at is not null
      and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now())
      and u.phone_confirmed_at is not null and nullif(u.phone,'') is not null
      and not exists(select 1 from fieldrush_rating_private.season_zero_initialization_eligibility e
        where e.user_id=a.user_id and e.initialized_at is null));
$$;

alter function public.get_my_fieldrush_account() rename to get_my_fieldrush_account_before_season_zero_sr;
revoke all on function public.get_my_fieldrush_account_before_season_zero_sr()
  from public,anon,authenticated,service_role;
create function public.get_my_fieldrush_account()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,fieldrush_rating_private,pg_temp as $$
declare caller uuid:=fieldrush_private.require_user(); result jsonb;
  eligibility fieldrush_rating_private.season_zero_initialization_eligibility%rowtype;
begin
  result:=public.get_my_fieldrush_account_before_season_zero_sr();
  select * into eligibility from fieldrush_rating_private.season_zero_initialization_eligibility where user_id=caller;
  return result||jsonb_build_object(
    'skill_assessment',eligibility.draft_assessment,
    'skill_assessment_required',eligibility.user_id is not null and eligibility.initialized_at is null,
    'rating_initialized',eligibility.user_id is null or eligibility.initialized_at is not null,
    'onboarding_completed',coalesce((result->>'onboarding_completed')::boolean,false)
      and (eligibility.user_id is null or eligibility.initialized_at is not null)
  );
end;
$$;
revoke all on function public.get_my_fieldrush_account() from public,anon;
grant execute on function public.get_my_fieldrush_account() to authenticated;
notify pgrst,'reload schema';
