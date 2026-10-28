-- Referees may stop their match before its planned duration and resume it
-- later. Early results keep the existing no-SR rule for shortened sessions.
-- Reopening is an audited lifecycle transition; replay removes the old award
-- and holds dependent results until the match is finalized again.
create function fieldrush_rating_private.season_zero_referee_can_reopen(game_to_use uuid)
returns boolean language sql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
  select exists(select 1 from fieldrush_rating_private.season_zero_matches s
    join public.open_queue_games g on g.id=s.game_id
    where g.id=game_to_use and g.rating_policy_id='field-sr-season0-v2'
      and g.status='FINAL' and g.operational_state='NORMAL'
      and s.lifecycle='FINAL' and s.rating_status in ('completed','unranked') and s.adjudicated_by is null);
$$;

create or replace function public.get_season_zero_match_state(actor_referee_id uuid,game_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare state fieldrush_rating_private.season_zero_matches%rowtype; normalized jsonb; elapsed integer;
begin
  if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then
    raise exception 'This match is not assigned to you.' using errcode='42501';
  end if;
  select * into state from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_use;
  if not found then return null; end if;
  elapsed:=case when state.lifecycle='LIVE' then fieldrush_rating_private.season_zero_elapsed(game_id_to_use) else state.played_seconds end;
  normalized:=fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(game_id_to_use,elapsed));
  return to_jsonb(state)||jsonb_build_object('elapsed_seconds',elapsed,'audit',normalized->'audit','server_now',clock_timestamp(),
    'referee_can_reopen',fieldrush_rating_private.season_zero_referee_can_reopen(game_id_to_use));
end;
$$;

create or replace function public.referee_finish_season_zero_match(actor_referee_id uuid,game_id_to_use uuid,
  request_id_to_use uuid,expected_revision integer)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare state fieldrush_rating_private.season_zero_matches%rowtype; g public.open_queue_games%rowtype;
  prior fieldrush_rating_private.season_zero_action_requests%rowtype; input_to_use jsonb:=jsonb_build_object('action','FINISH');
  elapsed integer; white_score_to_use integer; black_score_to_use integer; response jsonb; normalized jsonb; clock_status text; finish_reason text;
begin
  if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then raise exception 'This match is not assigned to you.' using errcode='42501'; end if;
  if request_id_to_use is null then raise exception 'A request ID is required.'; end if;
  perform fieldrush_rating_private.lock_season_zero_sr();
  select * into prior from fieldrush_rating_private.season_zero_action_requests where request_id=request_id_to_use;
  if found then
    if row(prior.game_id,prior.actor_id,prior.input) is distinct from row(game_id_to_use,actor_referee_id,input_to_use) then raise exception 'This request ID belongs to another action.'; end if;
    return prior.response;
  end if;
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  select * into state from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_use for update;
  if g.rating_policy_id is distinct from 'field-sr-season0-v2' or state.game_id is null then raise exception 'This game does not use Season 0 rating.'; end if;
  if g.status is distinct from 'LIVE' or state.lifecycle is distinct from 'LIVE' or g.operational_state is distinct from 'NORMAL' then raise exception 'Only an unlocked live match can finish normally.'; end if;
  if state.revision is distinct from expected_revision then raise exception 'Refresh the changed match before finishing.' using errcode='40001'; end if;
  select status into clock_status from public.open_queue_clock_states where game_id=game_id_to_use for update;
  if not found or clock_status not in ('RUNNING','PAUSED') then raise exception 'The live playing clock is missing.'; end if;
  elapsed:=fieldrush_rating_private.season_zero_elapsed(game_id_to_use);
  finish_reason:=case when elapsed<state.scheduled_seconds then
    'Referee ended the match early. Result saved without SR or a counted appearance.' else 'Referee confirmed the completed result.' end;
  select count(*) filter(where team='WHITE'),count(*) filter(where team='BLACK') into white_score_to_use,black_score_to_use
    from public.open_queue_goals where game_id=game_id_to_use;
  update fieldrush_rating_private.season_zero_matches set lifecycle='FINAL',
    rating_status=case when elapsed<scheduled_seconds then 'unranked' else 'completed' end,played_seconds=elapsed,
    -- Close the advancing segment explicitly, so reopening can remain paused
    -- without counting the time between finish and resume as participation.
    events=events||case when clock_status='RUNNING' then jsonb_build_array(jsonb_build_object(
      'id',request_id_to_use,'type','PAUSE','second',elapsed,'player_id',null,
      'recorded_at',clock_timestamp(),'actor_id',actor_referee_id,'note','Referee ended the match.')) else '[]'::jsonb end,
    winner=case when white_score_to_use>black_score_to_use then 'A' when black_score_to_use>white_score_to_use then 'B' end,
    revision=revision+1,updated_at=clock_timestamp() where game_id=game_id_to_use returning * into state;
  normalized:=fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(game_id_to_use));
  update public.open_queue_clock_states set status='ENDED',started_at=null,accumulated_seconds=elapsed where game_id=game_id_to_use;
  insert into public.open_queue_events(game_id,event_type,minute,second,note) values(game_id_to_use,'MATCH_ENDED',elapsed/60,elapsed%60,finish_reason);
  insert into fieldrush_rating_private.season_zero_match_revisions(game_id,revision,actor_id,action,reason,evidence)
    values(game_id_to_use,state.revision,actor_referee_id,'FINISH',finish_reason,to_jsonb(state));
  perform set_config('fieldrush.season_zero_finalizing',game_id_to_use::text,true);
  update public.open_queue_games set status='FINAL',white_score=white_score_to_use,black_score=black_score_to_use where id=game_id_to_use;
  perform set_config('fieldrush.season_zero_finalizing','',true);
  response:=fieldrush_rating_private.replay_season_zero_ratings(game_id_to_use,actor_referee_id,finish_reason);
  response:=public.get_season_zero_match_state(actor_referee_id,game_id_to_use)||response;
  insert into fieldrush_rating_private.season_zero_action_requests(request_id,game_id,actor_id,input,response)
    values(request_id_to_use,game_id_to_use,actor_referee_id,input_to_use,response);
  return response;
end;
$$;

create function public.referee_reopen_season_zero_match(actor_referee_id uuid,game_id_to_use uuid,
  request_id_to_use uuid,expected_revision integer)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare state fieldrush_rating_private.season_zero_matches%rowtype; g public.open_queue_games%rowtype;
  prior fieldrush_rating_private.season_zero_action_requests%rowtype; input_to_use jsonb:=jsonb_build_object('action','REOPEN');
  before_state jsonb; normalized jsonb; response jsonb; clock_status text;
begin
  if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then
    raise exception 'This match is not assigned to you.' using errcode='42501';
  end if;
  if request_id_to_use is null then raise exception 'A request ID is required.'; end if;
  perform fieldrush_rating_private.lock_season_zero_sr();
  select * into prior from fieldrush_rating_private.season_zero_action_requests where request_id=request_id_to_use;
  if found then
    if row(prior.game_id,prior.actor_id,prior.input) is distinct from row(game_id_to_use,actor_referee_id,input_to_use) then
      raise exception 'This request ID belongs to another action.';
    end if;
    return prior.response;
  end if;
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  select * into state from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_use for update;
  if g.rating_policy_id is distinct from 'field-sr-season0-v2' or state.game_id is null then
    raise exception 'This game does not use Season 0 rating.';
  end if;
  if not fieldrush_rating_private.season_zero_referee_can_reopen(game_id_to_use) then
    raise exception 'Only a referee-ended match can reopen. Cancelled or organizer-reviewed matches need organizer review.';
  end if;
  if state.revision is distinct from expected_revision then
    raise exception 'Refresh the changed match before reopening.' using errcode='40001';
  end if;
  select status into clock_status from public.open_queue_clock_states where game_id=game_id_to_use for update;
  if not found or clock_status<>'ENDED' then raise exception 'The ended playing clock is missing.'; end if;
  before_state:=to_jsonb(state);
  normalized:=fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(game_id_to_use));
  update fieldrush_rating_private.season_zero_matches set lifecycle='LIVE',rating_status='pending_review',winner=null,
    -- Old completed games predate the explicit PAUSE at finish. Add their
    -- missing boundary while preserving every original event and snapshot.
    events=events||case when normalized->'audit'->>'final_clock_state'='RUNNING' then jsonb_build_array(jsonb_build_object(
      'id',request_id_to_use,'type','PAUSE','second',played_seconds,'player_id',null,
      'recorded_at',clock_timestamp(),'actor_id',actor_referee_id,'note','Reopened match; waiting for referee to resume.')) else '[]'::jsonb end,
    revision=revision+1,updated_at=clock_timestamp() where game_id=game_id_to_use returning * into state;
  perform fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(game_id_to_use));
  update public.open_queue_clock_states set status='PAUSED',started_at=null,accumulated_seconds=state.played_seconds
    where game_id=game_id_to_use;
  perform set_config('fieldrush.season_zero_finalizing',game_id_to_use::text,true);
  begin
    update public.open_queue_games set status='LIVE' where id=game_id_to_use;
  exception when raise_exception then
    -- Reactivation still obeys the one-active-game rule, including a pending
    -- paid checkout. Translate only its player-facing messages for the referee;
    -- every other error and every existing booking remains untouched.
    if sqlerrm in (
      'You can only be registered in one upcoming or active game. Finish or cancel your current game before booking another.',
      'Finish or cancel your earlier game checkout before booking another game.'
    ) then
      raise exception 'A player has another active game or checkout. Resolve that booking before reopening.';
    end if;
    raise;
  end;
  perform set_config('fieldrush.season_zero_finalizing','',true);
  insert into public.open_queue_events(game_id,event_type,minute,second,note)
    values(game_id_to_use,'CORRECTION',state.played_seconds/60,state.played_seconds%60,'Referee reopened the match. Clock paused; score and playing evidence retained.');
  insert into fieldrush_rating_private.season_zero_match_revisions(game_id,revision,actor_id,action,reason,evidence)
    values(game_id_to_use,state.revision,actor_referee_id,'REOPEN','Referee reopened the result to continue the match.',
      jsonb_build_object('before',before_state,'after',to_jsonb(state)));
  response:=fieldrush_rating_private.replay_season_zero_ratings(game_id_to_use,actor_referee_id,'Referee reopened the match; withdraw its award and recalculate dependent results.');
  response:=public.get_season_zero_match_state(actor_referee_id,game_id_to_use)||response;
  insert into fieldrush_rating_private.season_zero_action_requests(request_id,game_id,actor_id,input,response)
    values(request_id_to_use,game_id_to_use,actor_referee_id,input_to_use,response);
  return response;
end;
$$;

revoke all on function fieldrush_rating_private.season_zero_referee_can_reopen(uuid) from public,anon,authenticated,service_role;
revoke all on function public.referee_reopen_season_zero_match(uuid,uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.referee_reopen_season_zero_match(uuid,uuid,uuid,integer) to service_role;
notify pgrst,'reload schema';
