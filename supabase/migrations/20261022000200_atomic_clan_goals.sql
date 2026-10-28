-- Commit the scorer, timeline event, official score and retry receipt together.
-- Receipts are checked before live-state validation so a response lost just
-- before finalization can still be acknowledged without adding a second goal.
alter table public.fixture_events add column goal_id uuid;
create index fixture_events_goal_idx on public.fixture_events(goal_id) where goal_id is not null;

create table fieldrush_rating_private.clan_goal_operations (
  request_id uuid primary key,
  fixture_id uuid not null references public.fixtures(id) on delete restrict,
  actor_id uuid not null references public.referee_profiles(profile_id) on delete restrict,
  input jsonb not null,
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
revoke all on fieldrush_rating_private.clan_goal_operations from public,anon,authenticated,service_role;
create trigger protect_clan_goal_operations before update or delete on fieldrush_rating_private.clan_goal_operations
  for each row execute function fieldrush_rating_private.protect_season_zero_append_only();

create function public.referee_record_fixture_goal_atomic(
  actor_referee_id uuid, fixture_id_to_use uuid, request_id_to_use uuid, goal_input jsonb
)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
declare
  fixture public.fixtures%rowtype;
  clock public.fixture_clock_states%rowtype;
  prior fieldrush_rating_private.clan_goal_operations%rowtype;
  goal public.fixture_scorers%rowtype;
  clan uuid; scorer uuid; assist uuid; elapsed integer; event_id uuid;
  home_score_to_use integer; away_score_to_use integer;
  input_to_use jsonb; response_to_use jsonb; occurred_at_to_use timestamptz;
begin
  if auth.role() is distinct from 'service_role'
    or public.referee_can_manage_reliability_match(actor_referee_id,'CLAN',fixture_id_to_use) is distinct from true then
    raise exception 'This match is not assigned to you.' using errcode='42501';
  end if;
  if request_id_to_use is null or jsonb_typeof(goal_input) is distinct from 'object'
    or goal_input->>'action' is distinct from 'ADD' then
    raise exception 'A valid goal operation and request ID are required.' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_object_keys(goal_input) k where k not in ('action','clan_id','profile_id','assist_profile_id')) then
    raise exception 'Unexpected goal input.' using errcode='22023';
  end if;
  clan:=nullif(goal_input->>'clan_id','')::uuid;
  scorer:=nullif(goal_input->>'profile_id','')::uuid;
  assist:=nullif(goal_input->>'assist_profile_id','')::uuid;
  if clan is null or scorer is null then
    raise exception 'Choose a valid team, scorer and optional assist.' using errcode='22023';
  end if;
  input_to_use:=jsonb_build_object('action','ADD','clan_id',clan,'profile_id',scorer,'assist_profile_id',assist);

  -- A global receipt lock rejects reuse across fixtures as well as concurrent
  -- retries of one operation. The fixture lock serializes scores and finish.
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-clan-goal-request:'||request_id_to_use::text,0));
  select * into prior from fieldrush_rating_private.clan_goal_operations where request_id=request_id_to_use;
  if found then
    if row(prior.fixture_id,prior.actor_id,prior.input) is distinct from row(fixture_id_to_use,actor_referee_id,input_to_use) then
      raise exception 'This request ID belongs to another goal operation.' using errcode='22023';
    end if;
    return prior.response;
  end if;
  select * into fixture from public.fixtures where id=fixture_id_to_use for update;
  if fixture.id is null or fixture.status is distinct from 'LIVE' or fixture.operational_state is distinct from 'NORMAL' then
    raise exception 'Goals require an unlocked live match.' using errcode='22023';
  end if;
  if clan is distinct from fixture.home_clan_id and clan is distinct from fixture.away_clan_id then
    raise exception 'Selected team is not playing this match.' using errcode='22023';
  end if;
  if not exists(select 1 from public.clan_members where clan_id=clan and profile_id=scorer and left_at is null)
    or (assist is not null and not exists(select 1 from public.clan_members where clan_id=clan and profile_id=assist and left_at is null)) then
    raise exception 'That player is not in the selected clan.' using errcode='22023';
  end if;
  select * into clock from public.fixture_clock_states where fixture_id=fixture.id for update;
  if clock.status is null or clock.status not in ('RUNNING','PAUSED') then
    raise exception 'The match clock has not been started.' using errcode='22023';
  end if;
  occurred_at_to_use:=clock_timestamp();
  elapsed:=least(10800,greatest(0,clock.accumulated_seconds + case
    when clock.status='RUNNING' and clock.started_at is not null
      then greatest(0,floor(extract(epoch from occurred_at_to_use-clock.started_at))::integer)
    else 0 end));
  insert into public.fixture_scorers(fixture_id,clan_id,profile_id,assist_profile_id,minute)
    values(fixture.id,clan,scorer,assist,greatest(1,elapsed/60)) returning * into goal;
  insert into public.fixture_events(fixture_id,event_type,clan_id,profile_id,assist_profile_id,minute,second,occurred_at,goal_id)
    values(fixture.id,'GOAL',clan,scorer,assist,greatest(1,elapsed/60),elapsed%60,occurred_at_to_use,goal.id)
    returning id into event_id;
  select count(*) filter(where clan_id=fixture.home_clan_id),count(*) filter(where clan_id=fixture.away_clan_id)
    into home_score_to_use,away_score_to_use from public.fixture_scorers where fixture_id=fixture.id;
  update public.fixtures set home_score=home_score_to_use,away_score=away_score_to_use,
    winner_clan_id=case when home_score_to_use>away_score_to_use then fixture.home_clan_id
      when away_score_to_use>home_score_to_use then fixture.away_clan_id else null end
    where id=fixture.id;
  response_to_use:=jsonb_build_object('fixture_id',fixture.id,'request_id',request_id_to_use,'action','ADD',
    'goal_id',goal.id,'event_id',event_id,'home_score',home_score_to_use,'away_score',away_score_to_use);
  insert into fieldrush_rating_private.clan_goal_operations(request_id,fixture_id,actor_id,input,response)
    values(request_id_to_use,fixture.id,actor_referee_id,input_to_use,response_to_use);
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_referee_id,'CLAN_GOAL_RECORDED','CLAN_MATCH',fixture.id,'Referee confirmed the scorer and optional assist.',
      jsonb_build_object('home_score',fixture.home_score,'away_score',fixture.away_score),
      response_to_use||jsonb_build_object('goal',to_jsonb(goal)));
  return response_to_use;
end;
$$;
revoke all on function public.referee_record_fixture_goal_atomic(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.referee_record_fixture_goal_atomic(uuid,uuid,uuid,jsonb) to service_role;
notify pgrst,'reload schema';
