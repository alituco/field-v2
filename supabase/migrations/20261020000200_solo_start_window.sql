-- A referee may start an unlocked Season 0 solo match within 24 hours either
-- side of its advertised kickoff. The saved commercial schedule, reliability
-- policy, season and historical match evidence are never rewritten.
-- The installed S0 safety writers already emit these two distinct reasons;
-- admit them so an actual-clock stop can commit its review state atomically.
alter table public.open_queue_games drop constraint open_queue_games_operational_reason_code_check;
alter table public.open_queue_games add constraint open_queue_games_operational_reason_code_check check(
  operational_reason_code is null or operational_reason_code in (
    'NO_ACTIVITY','RESULT_MISSING','REFEREE_REPORT_MISSING','DISPUTED','REFUND_FAILED',
    'SEASON_ZERO_CLOCK_REVIEW','SEASON_ZERO_SAFETY_REVIEW'
  )
);

create function fieldrush_rating_private.solo_start_window_allows(
  starts_at_to_use timestamptz, at_time_to_use timestamptz
)
returns boolean language sql immutable strict set search_path=public,pg_temp as $$
  select at_time_to_use >= starts_at_to_use - interval '24 hours'
     and at_time_to_use <= starts_at_to_use + interval '24 hours';
$$;

-- This operational cutoff is derived, not persisted over the advertised terms.
-- Until actual kickoff a delayed match must not classify its waiting players
-- as no-shows. Once started, the saved grace period runs from actual kickoff.
create function fieldrush_rating_private.solo_attendance_cutoff(
  game_id_to_use uuid, scheduled_cutoff_to_use timestamptz
)
returns timestamptz language sql volatile security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
  select case
    when g.rating_policy_id <> 'field-sr-season0-v2' then scheduled_cutoff_to_use
    when s.game_id is not null then s.started_at + make_interval(mins =>
      coalesce((t.policy_snapshot #>> '{attendance,noShowGraceMinutes}')::integer,10))
    when g.status in ('OPEN','FULL') then g.starts_at + interval '24 hours 1 microsecond'
    else scheduled_cutoff_to_use end
  from public.open_queue_games g
  left join fieldrush_rating_private.season_zero_matches s on s.game_id=g.id
  left join public.match_reliability_terms t on t.open_queue_game_id=g.id and t.match_kind='SOLO'
  where g.id=game_id_to_use;
$$;

create function fieldrush_rating_private.assert_solo_checkin_window(
  game_id_to_use uuid, at_time_to_use timestamptz
)
returns void language plpgsql security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype;
begin
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  if g.rating_policy_id is distinct from 'field-sr-season0-v2' then return; end if;
  if g.operational_state is distinct from 'NORMAL' then
    raise exception 'This match is locked for organizer review.';
  end if;
  if g.status in ('OPEN','FULL') and not fieldrush_rating_private.solo_start_window_allows(g.starts_at,at_time_to_use) then
    raise exception 'Check in players within 24 hours before or after the scheduled kickoff.';
  end if;
end;
$$;

-- Missing-result discovery must respect the last permitted actual kickoff.
-- For live matches only actual playing time advances the missing-result clock;
-- a pause does not turn an otherwise valid game into a missing-result case.
-- Existing review states remain authoritative and are never cleared here.
create function fieldrush_rating_private.solo_resolution_is_due(
  game_id_to_use uuid, at_time_to_use timestamptz
)
returns boolean language plpgsql volatile security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype; s fieldrush_rating_private.season_zero_matches%rowtype;
  c public.open_queue_clock_states%rowtype; elapsed numeric; finished_at timestamptz;
begin
  select * into g from public.open_queue_games where id=game_id_to_use;
  if g.id is null then return false; end if;
  if g.rating_policy_id <> 'field-sr-season0-v2' then
    return g.ends_at + interval '30 minutes' <= at_time_to_use;
  end if;
  if g.operational_state is distinct from 'NORMAL' then return false; end if;
  select * into s from fieldrush_rating_private.season_zero_matches where game_id=g.id;
  if g.status in ('OPEN','FULL') and s.game_id is null then
    return at_time_to_use > g.starts_at + interval '24 hours';
  end if;
  if g.status='LIVE' and s.lifecycle='LIVE' then
    select * into c from public.open_queue_clock_states where game_id=g.id;
    if c.game_id is null or c.status not in ('RUNNING','PAUSED') then return false; end if;
    elapsed:=c.accumulated_seconds + case when c.status='RUNNING' and c.started_at is not null
      then greatest(0,extract(epoch from(at_time_to_use-c.started_at))) else 0 end;
    return elapsed >= s.scheduled_seconds + 1800;
  end if;
  if g.status='FINAL' then
    select max(occurred_at) into finished_at from public.open_queue_events
      where game_id=g.id and event_type='MATCH_ENDED';
    return coalesce(finished_at,g.ends_at) + interval '30 minutes' <= at_time_to_use;
  end if;
  return false;
end;
$$;

do $migration$
declare definition text; anchor text;
begin
  definition:=pg_get_functiondef('public.referee_season_zero_action(uuid,uuid,uuid,integer,jsonb)'::regprocedure);
  anchor:=$old$    if g.status not in ('OPEN','FULL') or g.starts_at>recorded then raise exception 'Wait until the scheduled kickoff to start this match.'; end if;$old$;
  if position(anchor in definition)=0 then raise exception 'Season 0 start-time guard changed.'; end if;
  definition:=replace(definition,anchor,$new$    if g.status not in ('OPEN','FULL') then raise exception 'Only an open, unstarted match can start.'; end if;
    if not fieldrush_rating_private.solo_start_window_allows(g.starts_at,recorded) then
      raise exception 'Start this match within 24 hours before or after its scheduled kickoff.';
    end if;$new$);
  execute definition;

  definition:=pg_get_functiondef('public.referee_assign_season_zero_teams(uuid,uuid,uuid)'::regprocedure);
  anchor:=$old$  if clock_timestamp()<least(g.starts_at,public.open_queue_team_assignment_at(g.id)) then
    raise exception 'Wait until the scheduled team-reveal time.' using errcode='22023'; end if;$old$;
  if position(anchor in definition)=0 then raise exception 'Season 0 assignment-time guard changed.'; end if;
  definition:=replace(definition,anchor,$new$  if not fieldrush_rating_private.solo_start_window_allows(g.starts_at,clock_timestamp()) then
    raise exception 'Assign teams within 24 hours before or after the scheduled kickoff.' using errcode='22023'; end if;$new$);
  execute definition;

  definition:=pg_get_functiondef('public.referee_check_in_player(uuid,text,uuid,uuid)'::regprocedure);
  anchor:=$old$  if checked_in_at_to_use >= terms_to_use.no_show_cutoff_at then$old$;
  if position(anchor in definition)=0 then raise exception 'Referee attendance cutoff guard changed.'; end if;
  definition:=replace(definition,anchor,$new$  if normalized_kind='SOLO' then
    perform fieldrush_rating_private.assert_solo_checkin_window(match_id_to_use,clock_timestamp());
    terms_to_use.no_show_cutoff_at:=fieldrush_rating_private.solo_attendance_cutoff(match_id_to_use,terms_to_use.no_show_cutoff_at);
    checked_in_at_to_use:=clock_timestamp();
  end if;
  if checked_in_at_to_use >= terms_to_use.no_show_cutoff_at then$new$);
  execute definition;

  -- Match detail exposes the effective operational cutoff so its buttons agree
  -- with the RPC. Its kickoff, refunds, reserves and saved policy stay scheduled.
  definition:=pg_get_functiondef('public.get_match_reliability_context(text,uuid)'::regprocedure);
  anchor:=$old$  reserve_activation_minutes := (terms_to_use.policy_snapshot #>>$old$;
  if position(anchor in definition)=0 then raise exception 'Match context terms initialization changed.'; end if;
  definition:=replace(definition,anchor,$new$
  if normalized_kind='SOLO' then
    terms_to_use.no_show_cutoff_at:=fieldrush_rating_private.solo_attendance_cutoff(match_id_to_use,terms_to_use.no_show_cutoff_at);
  end if;
  reserve_activation_minutes := (terms_to_use.policy_snapshot #>>$new$);
  anchor:=$old$    'can_check_in',
      can_view_roster
      and server_now_to_use < terms_to_use.no_show_cutoff_at,$old$;
  if position(anchor in definition)=0 then raise exception 'Match context check-in availability changed.'; end if;
  definition:=replace(definition,anchor,$new$    'can_check_in',
      can_view_roster
      and server_now_to_use < terms_to_use.no_show_cutoff_at
      and (normalized_kind<>'SOLO'
        or not exists(select 1 from public.open_queue_games where id=match_id_to_use and rating_policy_id='field-sr-season0-v2')
        or exists(select 1 from public.open_queue_games where id=match_id_to_use and operational_state='NORMAL'
          and (status='LIVE' or (status in ('OPEN','FULL')
            and fieldrush_rating_private.solo_start_window_allows(starts_at,server_now_to_use))))),$new$);
  execute definition;

  definition:=pg_get_functiondef('public.referee_remove_player_check_in(uuid,text,uuid,uuid,integer,text,text)'::regprocedure);
  anchor:=$old$  if correction_at_to_use >= terms_to_use.no_show_cutoff_at then$old$;
  if position(anchor in definition)=0 then raise exception 'Attendance correction cutoff guard changed.'; end if;
  definition:=replace(definition,anchor,$new$  if normalized_kind='SOLO' then
    perform fieldrush_rating_private.assert_solo_checkin_window(match_id_to_use,clock_timestamp());
    terms_to_use.no_show_cutoff_at:=fieldrush_rating_private.solo_attendance_cutoff(match_id_to_use,terms_to_use.no_show_cutoff_at);
    correction_at_to_use:=clock_timestamp();
  end if;
  if correction_at_to_use >= terms_to_use.no_show_cutoff_at then$new$);
  execute definition;

  definition:=pg_get_functiondef('public.finalize_match_attendance_internal(text,uuid,uuid)'::regprocedure);
  anchor:=$old$  if finalized_at_to_use < terms_to_use.no_show_cutoff_at$old$;
  if position(anchor in definition)=0 then raise exception 'Attendance finalization cutoff guard changed.'; end if;
  definition:=replace(definition,anchor,$new$  if normalized_kind='SOLO' then
    terms_to_use.no_show_cutoff_at:=fieldrush_rating_private.solo_attendance_cutoff(match_id_to_use,terms_to_use.no_show_cutoff_at);
  end if;
  if finalized_at_to_use < terms_to_use.no_show_cutoff_at$new$);
  execute definition;

  definition:=pg_get_functiondef('public.detect_due_match_resolution_cases()'::regprocedure);
  anchor:=$old$        and game.ends_at + interval '30 minutes' <= clock_timestamp()$old$;
  if position(anchor in definition)=0 then raise exception 'Scheduled solo result-discovery guard changed.'; end if;
  definition:=replace(definition,anchor,$new$        and fieldrush_rating_private.solo_resolution_is_due(game.id,clock_timestamp())$new$);
  anchor:=$old$  loop
    case_id_to_use := null;$old$;
  if position(anchor in definition)=0 then raise exception 'Solo result-discovery loop changed.'; end if;
  definition:=replace(definition,anchor,$new$  loop
    if candidate.match_kind='SOLO' and exists(select 1 from public.open_queue_games
      where id=candidate.match_id and rating_policy_id='field-sr-season0-v2') then
      -- START may have committed after discovery selected this candidate.
      -- Serialize and recheck before creating a case or changing review state.
      perform 1 from public.open_queue_games where id=candidate.match_id for update;
      if not fieldrush_rating_private.solo_resolution_is_due(candidate.match_id,clock_timestamp()) then continue; end if;
    end if;
    case_id_to_use := null;$new$);
  execute definition;

  -- Injury/refund evidence is distinct from the participation timeline, but it
  -- must recognize the very same verified actual kickoff before schedule.
  -- Keep the complete existing audited legacy exception and every other guard.
  definition:=pg_get_functiondef('public.referee_start_shorthanded_period(uuid,text,uuid,text,text,uuid,text)'::regprocedure);
  anchor:=$old$  if clock_timestamp() < terms_to_use.kickoff_at
    and not ($old$;
  if position(anchor in definition)=0 then raise exception 'Audited shorthanded kickoff guard changed.'; end if;
  definition:=replace(definition,anchor,$new$  if clock_timestamp() < terms_to_use.kickoff_at
    and not (
      normalized_kind='SOLO' and exists (
        select 1 from public.open_queue_games game
        join fieldrush_rating_private.season_zero_matches actual_match on actual_match.game_id=game.id
        join public.open_queue_clock_states actual_clock on actual_clock.game_id=game.id
        where game.id=match_id_to_use and game.rating_policy_id='field-sr-season0-v2'
          and game.status='LIVE' and game.operational_state='NORMAL' and game.teams_assigned_at is not null
          and actual_match.lifecycle='LIVE' and actual_match.started_at<=clock_timestamp()
          and fieldrush_rating_private.solo_start_window_allows(game.starts_at,actual_match.started_at)
          and actual_clock.status in ('RUNNING','PAUSED')
          and exists(select 1 from public.open_queue_events actual_event where actual_event.game_id=game.id
            and actual_event.event_type='MATCH_STARTED' and actual_event.occurred_at=actual_match.started_at)
      )
    )
    and not ($new$);
  execute definition;
end;
$migration$;

revoke all on function fieldrush_rating_private.solo_start_window_allows(timestamptz,timestamptz),
  fieldrush_rating_private.solo_attendance_cutoff(uuid,timestamptz),
  fieldrush_rating_private.assert_solo_checkin_window(uuid,timestamptz),
  fieldrush_rating_private.solo_resolution_is_due(uuid,timestamptz)
  from public,anon,authenticated,service_role;
