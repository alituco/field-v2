-- Resume is a state transition, not a clock reset. Serialize against pause,
-- finish and other resume calls; retries of an already-running clock are reads.
create function public.referee_resume_legacy_solo_game(actor_referee_id uuid,game_id_to_use uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare game public.open_queue_games%rowtype; before_clock public.open_queue_clock_states%rowtype;
  saved public.open_queue_clock_states%rowtype; resumed_at timestamptz;
begin
  if auth.role() is distinct from 'service_role' or actor_referee_id is null or game_id_to_use is null
    or public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) is distinct from true then
    raise exception 'This match is not assigned to you.' using errcode='42501';
  end if;
  select * into game from public.open_queue_games where id=game_id_to_use for update;
  if game.rating_policy_id='field-sr-season0-v2' then
    raise exception 'Use the Season 0 participation action to resume this match.' using errcode='22023';
  end if;
  if game.id is null or game.status is distinct from 'LIVE' or game.operational_state is distinct from 'NORMAL' then
    raise exception 'Only an unlocked live match can resume.' using errcode='22023';
  end if;
  select * into before_clock from public.open_queue_clock_states where game_id=game.id for update;
  if before_clock.status='RUNNING' and before_clock.started_at is not null then
    return jsonb_build_object('game_id',game.id,'status','RUNNING','already_running',true,
      'started_at',before_clock.started_at,'accumulated_seconds',before_clock.accumulated_seconds);
  end if;
  if before_clock.status is distinct from 'PAUSED' or before_clock.started_at is not null then
    raise exception 'The match clock is not paused.' using errcode='22023';
  end if;
  resumed_at:=clock_timestamp();
  update public.open_queue_clock_states set status='RUNNING',started_at=resumed_at
    where game_id=game.id returning * into saved;
  insert into public.open_queue_events(game_id,event_type,minute,second,occurred_at)
    values(game.id,'MATCH_RESUMED',before_clock.accumulated_seconds/60,before_clock.accumulated_seconds%60,resumed_at);
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_referee_id,'SOLO_CLOCK_RESUMED','SOLO_MATCH',game.id,'Referee resumed the paused match clock.',
      to_jsonb(before_clock),to_jsonb(saved));
  return jsonb_build_object('game_id',game.id,'status','RUNNING','already_running',false,
    'started_at',saved.started_at,'accumulated_seconds',saved.accumulated_seconds);
end;
$$;
revoke all on function public.referee_resume_legacy_solo_game(uuid,uuid) from public,anon,authenticated;
grant execute on function public.referee_resume_legacy_solo_game(uuid,uuid) to service_role;
notify pgrst,'reload schema';
