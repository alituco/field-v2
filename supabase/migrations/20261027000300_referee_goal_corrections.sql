-- Goal corrections use the same verified participation record as rating replay.
-- A private transaction-scoped capability lets this writer edit a finished game
-- without reopening it or relaxing ordinary live-goal permissions.
create table fieldrush_rating_private.referee_goal_correction_context (
  transaction_id bigint not null,
  game_id uuid not null references public.open_queue_games(id),
  actor_id uuid not null references public.profiles(id),
  primary key (transaction_id,game_id)
);
alter table fieldrush_rating_private.referee_goal_correction_context enable row level security;
revoke all on fieldrush_rating_private.referee_goal_correction_context from public,anon,authenticated,service_role;

create function fieldrush_rating_private.solo_goal_correction_authorized(game_to_use uuid)
returns boolean language sql volatile security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
  select exists(select 1 from fieldrush_rating_private.referee_goal_correction_context c
    where c.transaction_id=txid_current() and c.game_id=game_to_use);
$$;

-- Keep the existing trigger implementations, adding only the private writer's
-- capability. A service caller cannot manufacture it through a session GUC.
do $migration$
declare definition text; signature text; insertion text;
begin
  foreach signature in array array[
    'fieldrush_rating_private.guard_season_zero_goal()',
    'public.validate_open_queue_goal_participants()',
    'public.prevent_final_open_queue_goal_delete()'
  ] loop
    definition:=pg_get_functiondef(signature::regprocedure);
    if position(E'begin\n' in definition)=0 then raise exception 'Goal guard contract changed: %',signature; end if;
    insertion:=case signature
      when 'public.validate_open_queue_goal_participants()' then
        'if fieldrush_rating_private.solo_goal_correction_authorized(new.game_id) then return new; end if;'
      when 'public.prevent_final_open_queue_goal_delete()' then
        'if fieldrush_rating_private.solo_goal_correction_authorized(old.game_id) then return old; end if;'
      else 'if fieldrush_rating_private.solo_goal_correction_authorized(game_id_to_use) then return case when tg_op=''DELETE'' then old else new end; end if;'
    end;
    definition:=replace(definition,E'begin\n',E'begin\n  '||insertion||E'\n');
    execute definition;
  end loop;
end;
$migration$;

create function fieldrush_rating_private.solo_recorded_goals(game_to_use uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'team',g.team,
    'profile_id',g.profile_id,'assist_profile_id',g.assist_profile_id,
    'second',coalesce(e.match_second,g.minute*60)) order by coalesce(e.match_second,g.minute*60),g.id),'[]'::jsonb)
  from public.open_queue_goals g left join lateral (
    select ev.minute*60+ev.second match_second from public.open_queue_events ev
      where ev.game_id=g.game_id and ev.goal_id=g.id and ev.event_type='GOAL'
      order by ev.created_at desc,ev.id limit 1
  ) e on true where g.game_id=game_to_use;
$$;

create function fieldrush_rating_private.assert_corrected_solo_goal(
  game_to_use uuid,second_to_use integer,team_to_use text,scorer_to_use uuid,assist_to_use uuid,
  original_wall_hint timestamptz default null)
returns timestamptz language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
declare input jsonb; normalized jsonb; participant uuid; expected_team text;
  wall_time timestamptz; event jsonb; segment_wall timestamptz; segment_second integer:=0;
  kickoff timestamptz; finish_bound timestamptz;
begin
  if second_to_use is null or second_to_use<0 or second_to_use>10800
    or team_to_use is null or team_to_use not in ('WHITE','BLACK')
    or scorer_to_use is null or scorer_to_use=assist_to_use then
    raise exception 'Choose a valid goal time, scoring side, scorer and optional different assist.' using errcode='22023';
  end if;
  select started_at,coalesce(ended_at,clock_timestamp()) into kickoff,finish_bound from fieldrush_rating_private.season_zero_matches
    where game_id=game_to_use and played_seconds>=second_to_use;
  if not found then raise exception 'A goal must be within the recorded playing duration.' using errcode='22023'; end if;
  input:=fieldrush_rating_private.season_zero_input(game_to_use,second_to_use);
  segment_wall:=kickoff;
  -- A goal and a later pause/departure can share a whole clock second. Keep
  -- the original wall observation when it still maps to that second; otherwise
  -- derive the corrected moment from the latest running clock segment.
  for event in select value from jsonb_array_elements(input->'events') loop
    if event->>'type'='RESUME' and (event->>'second')::integer<=second_to_use then
      segment_wall:=(event->>'recorded_at')::timestamptz;
      segment_second:=(event->>'second')::integer;
    end if;
  end loop;
  wall_time:=segment_wall+make_interval(secs=>second_to_use-segment_second);
  if original_wall_hint between kickoff and finish_bound and
    fieldrush_rating_private.solo_arrival_playing_second(kickoff,input->'events',original_wall_hint,10800)=second_to_use then
    wall_time:=original_wall_hint;
  end if;
  if wall_time>finish_bound then raise exception 'A goal must occur before the actual final whistle.' using errcode='22023'; end if;
  input:=input||jsonb_build_object('status','pending_review','events',(
    select coalesce(jsonb_agg(e.value order by e.ordinality),'[]'::jsonb)
    from jsonb_array_elements(input->'events') with ordinality e
    where (e.value->>'second')::integer<second_to_use or
      ((e.value->>'second')::integer=second_to_use and (e.value->>'recorded_at')::timestamptz<=wall_time)));
  normalized:=fieldrush_rating_private.normalize_season_zero_sr(input);
  if normalized#>>'{audit,final_clock_state}' is distinct from 'RUNNING' then
    raise exception 'A corrected goal must occur while the playing clock was running.' using errcode='22023';
  end if;
  foreach participant in array array[scorer_to_use,assist_to_use] loop
    if participant is null then continue; end if;
    select case p->>'team' when 'A' then 'WHITE' when 'B' then 'BLACK' end into expected_team
      from jsonb_array_elements(input->'roster') p where p->>'id'=participant::text;
    if expected_team is distinct from team_to_use
      or normalized->'audit'->'players'->participant::text->>'final_state' is distinct from 'ACTIVE' then
      raise exception 'Scorer and assist must have been playing for the scoring side at that minute. Correct their arrival or the goal.' using errcode='22023';
    end if;
  end loop;
  return wall_time;
end;
$$;

create function fieldrush_rating_private.referee_correct_solo_goals(
  actor uuid,game uuid,goals_input jsonb,reason text)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype; goal public.open_queue_goals%rowtype;
  before_goals jsonb; selected jsonb; item jsonb; original jsonb; canonical jsonb:='[]';
  seen uuid[]:=array[]::uuid[]; keep_ids uuid[]:=array[]::uuid[];
  goal_id_to_use uuid; new_goal_id uuid; goal_second integer; scorer uuid; assist uuid;
  goal_team text; at_wall timestamptz; original_wall timestamptz; changed boolean:=false; existing_context boolean;
  correction_second integer;
  old_finalizing text:=current_setting('fieldrush.season_zero_finalizing',true);
begin
  if not public.referee_can_manage_reliability_match(actor,'SOLO',game) then
    raise exception 'This match is not assigned to you.' using errcode='42501';
  end if;
  perform fieldrush_rating_private.lock_season_zero_sr();
  select * into g from public.open_queue_games where id=game for update;
  if g.rating_policy_id is distinct from 'field-sr-season0-v2' or g.status not in ('LIVE','FINAL')
    or g.operational_state is distinct from 'NORMAL' then
    raise exception 'Goal corrections require an unlocked Season 0 match.' using errcode='22023';
  end if;
  before_goals:=fieldrush_rating_private.solo_recorded_goals(game);
  selected:=coalesce(goals_input,before_goals);
  if jsonb_typeof(selected) is distinct from 'array' or jsonb_array_length(selected)>500 then
    raise exception 'Provide the complete corrected goal list.' using errcode='22023'; end if;
  -- Validate the whole proposed list before changing a goal or invalidating media.
  for item in select value from jsonb_array_elements(selected) loop
    if jsonb_typeof(item) is distinct from 'object' or exists(select 1 from jsonb_object_keys(item) k
      where k not in ('id','team','profile_id','assist_profile_id','second')) then
      raise exception 'Unexpected corrected goal fields.' using errcode='22023'; end if;
    goal_id_to_use:=nullif(item->>'id','')::uuid;
    goal_second:=fieldrush_rating_private.season_zero_sr_integer(item->'second','goal.second',0);
    goal_team:=item->>'team'; scorer:=(item->>'profile_id')::uuid; assist:=nullif(item->>'assist_profile_id','')::uuid;
    if goal_id_to_use is not null then
      if goal_id_to_use=any(seen) then raise exception 'Each goal can appear only once.' using errcode='22023'; end if;
      select value into original from jsonb_array_elements(before_goals) where value->>'id'=goal_id_to_use::text;
      if not found then raise exception 'That goal does not belong to this match record. Refresh before correcting it.' using errcode='22023'; end if;
      seen:=array_append(seen,goal_id_to_use);
    else original:=null;
    end if;
    select occurred_at into original_wall from public.open_queue_events
      where game_id=game and goal_id=goal_id_to_use and event_type='GOAL'
      order by created_at desc,id limit 1;
    at_wall:=fieldrush_rating_private.assert_corrected_solo_goal(game,goal_second,goal_team,scorer,assist,
      case when (original->>'second')::integer=goal_second then original_wall end);
    item:=jsonb_build_object('id',goal_id_to_use,'team',goal_team,'profile_id',scorer,
      'assist_profile_id',assist,'second',goal_second);
    if original is not distinct from item and (goals_input is null or original_wall is null
      or abs(extract(epoch from original_wall-at_wall))<=1) then
      keep_ids:=array_append(keep_ids,goal_id_to_use);
    else changed:=true;
    end if;
    canonical:=canonical||jsonb_build_array(item||jsonb_build_object('occurred_at',at_wall));
  end loop;
  changed:=changed or exists(select 1 from public.open_queue_goals where game_id=game and not(id=any(keep_ids)));
  if changed and char_length(trim(coalesce(reason,'')))<10 then
    raise exception 'Explain the goal correction in at least ten characters.' using errcode='22023'; end if;
  if changed then
    existing_context:=fieldrush_rating_private.solo_goal_correction_authorized(game);
    if existing_context then raise exception 'A goal correction is already in progress.' using errcode='40001'; end if;
    insert into fieldrush_rating_private.referee_goal_correction_context values(txid_current(),game,actor);
    perform set_config('fieldrush.season_zero_finalizing',game::text,true);
    select played_seconds into correction_second from fieldrush_rating_private.season_zero_matches where game_id=game;
    for goal in select * from public.open_queue_goals where game_id=game and not(id=any(keep_ids)) order by id loop
      delete from public.open_queue_goals where id=goal.id;
      insert into public.open_queue_events(game_id,event_type,team,profile_id,assist_profile_id,minute,second,note,goal_id,occurred_at)
        values(game,'CORRECTION',goal.team,goal.profile_id,goal.assist_profile_id,correction_second/60,correction_second%60,
          'Goal replaced or removed from the official record. '||trim(reason),goal.id,clock_timestamp());
    end loop;
    for item in select value from jsonb_array_elements(canonical) loop
      if nullif(item->>'id','')::uuid=any(keep_ids) then continue; end if;
      goal_second:=(item->>'second')::integer;
      insert into public.open_queue_goals(game_id,team,profile_id,assist_profile_id,minute)
        values(game,item->>'team',(item->>'profile_id')::uuid,(item->>'assist_profile_id')::uuid,
          greatest(1,goal_second/60)) returning id into new_goal_id;
      insert into public.open_queue_events(game_id,event_type,team,profile_id,assist_profile_id,minute,second,note,goal_id,occurred_at)
        values(game,'GOAL',item->>'team',(item->>'profile_id')::uuid,(item->>'assist_profile_id')::uuid,
          goal_second/60,goal_second%60,'Referee corrected match record. '||trim(reason),new_goal_id,(item->>'occurred_at')::timestamptz);
    end loop;
    delete from fieldrush_rating_private.referee_goal_correction_context where transaction_id=txid_current() and game_id=game;
    perform set_config('fieldrush.season_zero_finalizing',coalesce(old_finalizing,''),true);
  end if;
  return jsonb_build_object('goals',fieldrush_rating_private.solo_recorded_goals(game),
    'white_score',(select count(*) from public.open_queue_goals where game_id=game and team='WHITE'),
    'black_score',(select count(*) from public.open_queue_goals where game_id=game and team='BLACK'));
end;
$$;

revoke all on function fieldrush_rating_private.solo_goal_correction_authorized(uuid),
  fieldrush_rating_private.solo_recorded_goals(uuid),
  fieldrush_rating_private.assert_corrected_solo_goal(uuid,integer,text,uuid,uuid,timestamptz),
  fieldrush_rating_private.referee_correct_solo_goals(uuid,uuid,jsonb,text) from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
