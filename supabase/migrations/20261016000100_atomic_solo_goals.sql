-- A goal, its public timeline record and its score projection are one commit.
-- Request receipts survive live undo and finalization; retries never add a goal.
alter table public.open_queue_events add column goal_id uuid;
create index open_queue_events_goal_idx on public.open_queue_events(goal_id) where goal_id is not null;

create table fieldrush_rating_private.solo_goal_operations (
  request_id uuid primary key,
  game_id uuid not null references public.open_queue_games(id) on delete restrict,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  input jsonb not null,
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
revoke all on fieldrush_rating_private.solo_goal_operations from public,anon,authenticated,service_role;
create trigger protect_solo_goal_operations before update or delete on fieldrush_rating_private.solo_goal_operations
  for each row execute function fieldrush_rating_private.protect_season_zero_append_only();

create function public.referee_mutate_solo_goal(actor_referee_id uuid,game_id_to_use uuid,request_id_to_use uuid,goal_input jsonb)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype; c public.open_queue_clock_states%rowtype;
  prior fieldrush_rating_private.solo_goal_operations%rowtype; goal public.open_queue_goals%rowtype;
  mode text:=goal_input->>'action'; team_to_use text:=goal_input->>'team'; scorer uuid; assist uuid;
  note_to_use text:=trim(coalesce(goal_input->>'note','')); elapsed integer; event_id uuid;
  white_score_to_use integer; black_score_to_use integer; response_to_use jsonb; input_to_use jsonb;
begin
  if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then
    raise exception 'This match is not assigned to you.' using errcode='42501';
  end if;
  if request_id_to_use is null or jsonb_typeof(goal_input) is distinct from 'object' or mode is null or mode not in ('ADD','REMOVE') then
    raise exception 'A valid goal operation and request ID are required.' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_object_keys(goal_input) k where k not in ('action','team','profile_id','assist_profile_id','goal_id','note')) then
    raise exception 'Unexpected goal input.' using errcode='22023';
  end if;
  if char_length(note_to_use)>500 then raise exception 'Goal note is too long.' using errcode='22023'; end if;
  if mode='ADD' then
    scorer:=(goal_input->>'profile_id')::uuid; assist:=nullif(goal_input->>'assist_profile_id','')::uuid;
    if scorer is null or team_to_use not in ('WHITE','BLACK') or assist=scorer or goal_input ? 'goal_id' then
      raise exception 'Choose a valid team, scorer and optional different assist.' using errcode='22023'; end if;
    input_to_use:=jsonb_build_object('action',mode,'team',team_to_use,'profile_id',scorer,'assist_profile_id',assist,'note',note_to_use);
  else
    if nullif(goal_input->>'goal_id','') is null or char_length(note_to_use)<5
      or goal_input ?| array['team','profile_id','assist_profile_id'] then
      raise exception 'Choose the recorded goal and explain why it is being removed.' using errcode='22023'; end if;
    input_to_use:=jsonb_build_object('action',mode,'goal_id',(goal_input->>'goal_id')::uuid,'note',note_to_use);
  end if;
  -- Serialize the receipt key across games as well, rejecting key reuse rather
  -- than allowing a unique-conflict failure after a different mutation.
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-solo-goal-request:'||request_id_to_use::text,0));
  select * into prior from fieldrush_rating_private.solo_goal_operations where request_id=request_id_to_use;
  if found then
    if row(prior.game_id,prior.actor_id,prior.input) is distinct from row(game_id_to_use,actor_referee_id,input_to_use) then
      raise exception 'This request ID belongs to another goal operation.' using errcode='22023'; end if;
    return prior.response;
  end if;
  select * into g from public.open_queue_games where id=game_id_to_use;
  -- Legacy completion takes the game lock before its rating lock. Do not take
  -- the global rating lock here for legacy and introduce an inverse lock order.
  if g.rating_policy_id='field-sr-season0-v2' then perform fieldrush_rating_private.lock_season_zero_sr(); end if;
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  if g.id is null or g.status is distinct from 'LIVE' or g.operational_state is distinct from 'NORMAL' then
    raise exception 'Goals require an unlocked live match.' using errcode='22023'; end if;
  select * into c from public.open_queue_clock_states where game_id=game_id_to_use for update;
  if c.status is distinct from 'RUNNING' or c.started_at is null then
    raise exception 'Goals can only be recorded or removed while the match clock is running.' using errcode='22023'; end if;
  elapsed:=least(10800,greatest(0,c.accumulated_seconds+floor(extract(epoch from clock_timestamp()-c.started_at))::integer));
  if mode='ADD' then
    -- Existing table triggers enforce confirmed/played/team membership and,
    -- for v2, actual presence (including blue-card and permanent send-off state).
    insert into public.open_queue_goals(game_id,team,profile_id,assist_profile_id,minute)
      values(g.id,team_to_use,scorer,assist,greatest(1,least(240,elapsed/60))) returning * into goal;
    insert into public.open_queue_events(game_id,event_type,team,profile_id,assist_profile_id,minute,second,note,goal_id)
      values(g.id,'GOAL',goal.team,goal.profile_id,goal.assist_profile_id,elapsed/60,elapsed%60,note_to_use,goal.id)
      returning id into event_id;
  else
    select * into goal from public.open_queue_goals where id=(input_to_use->>'goal_id')::uuid and game_id=g.id for update;
    if goal.id is null then raise exception 'That goal is no longer recorded in this match.' using errcode='22023'; end if;
    delete from public.open_queue_goals where id=goal.id;
    -- Retain the original GOAL event as historical evidence; a linked audited
    -- correction states that it no longer contributes to the official score.
    insert into public.open_queue_events(game_id,event_type,team,profile_id,assist_profile_id,minute,second,note,goal_id)
      values(g.id,'CORRECTION',goal.team,goal.profile_id,goal.assist_profile_id,elapsed/60,elapsed%60,
        'Goal removed from the official score. '||note_to_use,goal.id) returning id into event_id;
  end if;
  select count(*) filter(where team='WHITE'),count(*) filter(where team='BLACK') into white_score_to_use,black_score_to_use
    from public.open_queue_goals where game_id=g.id;
  update public.open_queue_games set white_score=white_score_to_use,black_score=black_score_to_use where id=g.id;
  response_to_use:=jsonb_build_object('game_id',g.id,'request_id',request_id_to_use,'action',mode,'goal_id',goal.id,
    'event_id',event_id,'white_score',white_score_to_use,'black_score',black_score_to_use);
  insert into fieldrush_rating_private.solo_goal_operations(request_id,game_id,actor_id,input,response)
    values(request_id_to_use,g.id,actor_referee_id,input_to_use,response_to_use);
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_referee_id,case mode when 'ADD' then 'SOLO_GOAL_RECORDED' else 'SOLO_GOAL_REMOVED' end,'SOLO_MATCH',g.id,
      case mode when 'ADD' then 'Referee confirmed the scorer and optional assist.' else note_to_use end,
      jsonb_build_object('white_score',g.white_score,'black_score',g.black_score),response_to_use||jsonb_build_object('goal',to_jsonb(goal)));
  return response_to_use;
end;
$$;
revoke all on function public.referee_mutate_solo_goal(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.referee_mutate_solo_goal(uuid,uuid,uuid,jsonb) to service_role;

-- Historical legacy awards are fixed ledger movements, not replayable v2
-- evidence. Never publish a different result while silently retaining those
-- awards. Only corrections preserving both result and the legacy goal-margin
-- multiplier are rating-equivalent; those remain supported and audited.
create function fieldrush_rating_private.assert_legacy_score_correction_safe(match_kind_to_use text,match_id_to_use uuid,home_score_to_use integer,away_score_to_use integer)
returns void language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype;
begin
  if upper(trim(match_kind_to_use))<>'SOLO' then return; end if;
  select * into g from public.open_queue_games where id=match_id_to_use for update;
  if g.rating_policy_id='field-sr-season0-v2' then return; end if;
  if (sign(home_score_to_use-away_score_to_use) is distinct from sign(g.white_score-g.black_score)
      or public.calculate_open_queue_margin_multiplier(abs(home_score_to_use-away_score_to_use))
        is distinct from public.calculate_open_queue_margin_multiplier(abs(g.white_score-g.black_score)))
    and exists(select 1 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id=g.id) then
    raise exception 'This legacy match already has rating awards. Changing the winner, draw or rating margin requires a reviewed rating migration; no score or ratings were changed. Season 0 matches support audited result correction and rating replay.' using errcode='22023';
  end if;
end;
$$;
revoke all on function fieldrush_rating_private.assert_legacy_score_correction_safe(text,uuid,integer,integer) from public,anon,authenticated,service_role;
alter function public.admin_override_match_score(uuid,text,uuid,integer,integer,text) rename to admin_override_match_score_before_goal_safety;
create function public.admin_override_match_score(actor_admin_id uuid,match_kind_to_use text,match_id_to_update uuid,home_score_to_use integer,away_score_to_use integer,reason_to_use text)
returns uuid language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin access required.' using errcode='42501'; end if;
  perform fieldrush_rating_private.lock_season_zero_sr();
  perform fieldrush_rating_private.assert_legacy_score_correction_safe(match_kind_to_use,match_id_to_update,home_score_to_use,away_score_to_use);
  return public.admin_override_match_score_before_goal_safety(actor_admin_id,match_kind_to_use,match_id_to_update,home_score_to_use,away_score_to_use,reason_to_use);
end;
$$;
alter function public.preserve_player_sr_for_resolution_score(text,uuid,integer,integer) rename to preserve_player_sr_for_resolution_score_before_goal_safety;
create function public.preserve_player_sr_for_resolution_score(match_kind_to_use text,match_id_to_use uuid,home_score_to_use integer,away_score_to_use integer)
returns integer language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  perform fieldrush_rating_private.assert_legacy_score_correction_safe(match_kind_to_use,match_id_to_use,home_score_to_use,away_score_to_use);
  return public.preserve_player_sr_for_resolution_score_before_goal_safety(match_kind_to_use,match_id_to_use,home_score_to_use,away_score_to_use);
end;
$$;
revoke all on function public.admin_override_match_score_before_goal_safety(uuid,text,uuid,integer,integer,text),
  public.preserve_player_sr_for_resolution_score_before_goal_safety(text,uuid,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.admin_override_match_score(uuid,text,uuid,integer,integer,text),
  public.preserve_player_sr_for_resolution_score(text,uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.admin_override_match_score(uuid,text,uuid,integer,integer,text),
  public.preserve_player_sr_for_resolution_score(text,uuid,integer,integer) to service_role;
notify pgrst,'reload schema';
