-- Safety records keep their existing moderation/broadcast workflow. A stopped
-- v2 match is never automatically treated as a rated result or a cancellation.
create trigger protect_season_zero_match_revisions before update or delete on fieldrush_rating_private.season_zero_match_revisions
  for each row execute function fieldrush_rating_private.protect_season_zero_append_only();
create trigger protect_season_zero_action_requests before update or delete on fieldrush_rating_private.season_zero_action_requests
  for each row execute function fieldrush_rating_private.protect_season_zero_append_only();

create function fieldrush_rating_private.protect_season_zero_kickoff_snapshot()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
  if tg_op='DELETE' or row(new.game_id,new.policy_id,new.started_at,new.scheduled_seconds,new.observed_roster)
    is distinct from row(old.game_id,old.policy_id,old.started_at,old.scheduled_seconds,old.observed_roster) then
    raise exception 'The original Season 0 kickoff snapshot is immutable.';
  end if;
  return new;
end;
$$;
create trigger protect_season_zero_kickoff_snapshot before update or delete on fieldrush_rating_private.season_zero_matches
  for each row execute function fieldrush_rating_private.protect_season_zero_kickoff_snapshot();

-- Financial refund/payment columns remain writable by their existing audited
-- writers. They do not replace the original participant or their fixed pool.
create function fieldrush_rating_private.guard_season_zero_frozen_booking()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare game_id_to_use uuid:=case when tg_op='DELETE' then old.game_id else new.game_id end;
begin
  if tg_op='UPDATE' and row(new.id,new.game_id,new.profile_id,new.role,new.team,new.status)
    is not distinct from row(old.id,old.game_id,old.profile_id,old.role,old.team,old.status) then return new; end if;
  if not exists(select 1 from public.open_queue_games where rating_policy_id='field-sr-season0-v2'
    and (id=game_id_to_use or (tg_op='UPDATE' and id=old.game_id))) then
    return case when tg_op='DELETE' then old else new end;
  end if;
  -- Booking/payment callers can already hold a row lock before this trigger.
  -- Never wait in the reverse of START's global->game ordering: retry safely.
  if not pg_try_advisory_xact_lock(hashtextextended('fieldrush-season-zero-rating',0)) then
    raise exception 'Match participation changed concurrently. Retry the booking operation.' using errcode='40001';
  end if;
  if exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_use
    or (tg_op='UPDATE' and game_id=old.game_id)) then
    if tg_op in ('INSERT','DELETE') then raise exception 'The originally booked Season 0 roster is frozen after kickoff.'; end if;
    if row(new.id,new.game_id,new.profile_id,new.role,new.team,new.status)
      is distinct from row(old.id,old.game_id,old.profile_id,old.role,old.team,old.status) then
      if row(new.id,new.game_id,new.profile_id,new.role) is not distinct from row(old.id,old.game_id,old.profile_id,old.role)
        and (new.team is null or new.team is not distinct from old.team)
        and old.status='CONFIRMED' and new.status='CANCELLED'
        and nullif(current_setting('fieldrush.season_zero_finalizing',true),'')=new.game_id::text
        and exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=new.game_id and rating_status='cancelled') then
        -- Financial cancellation used to clear these operational snapshots.
        -- Keep v2's original team/pool evidence while retaining its exact
        -- refund, deposit, payment, cancellation and played-field effects.
        new.team:=old.team; new.rating_at_team_assignment:=old.rating_at_team_assignment;
        new.rating_at_match_start:=old.rating_at_match_start;
        return new;
      end if;
      raise exception 'After kickoff, record actual participation or request organizer review; do not replace or cancel the booked roster.';
    end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$$;
create trigger a_guard_season_zero_frozen_booking before insert or update or delete on public.open_queue_bookings
  for each row execute function fieldrush_rating_private.guard_season_zero_frozen_booking();

create function fieldrush_rating_private.guard_season_zero_started_game()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  if exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=old.id)
    and new.status not in ('LIVE','FINAL') then
    if new.status='CANCELLED' and nullif(current_setting('fieldrush.season_zero_finalizing',true),'')=new.id::text
      and exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=new.id and rating_status='cancelled') then return new; end if;
    raise exception 'A started Season 0 match needs organizer review, not legacy cancellation or reopening.';
  end if;
  return new;
end;
$$;
create trigger a_guard_season_zero_started_game before update of status on public.open_queue_games
  for each row execute function fieldrush_rating_private.guard_season_zero_started_game();

-- Old no-show classifications must not veto an actually checked-in original
-- late entrant. The normalizer alone decides its >=600s counted appearance.
do $migration$
declare d text;
begin
  d:=pg_get_functiondef('public.require_checked_in_match_participant()'::regprocedure);
  if position(E'begin\n' in d)=0 then raise exception 'Checked-in participation guard contract changed.'; end if;
  d:=replace(d,E'begin\n',$new$begin
  if tg_table_name='open_queue_bookings' then
    if exists(select 1 from public.open_queue_games where id=new.game_id and rating_policy_id='field-sr-season0-v2') then
      if coalesce(new.played,false) and not exists(select 1 from public.match_attendance_records
        where booking_id=new.id and checked_in_at is not null) then
        raise exception 'Check in the original booked participant before recording actual play.';
      end if;
      return new;
    end if;
  end if;
$new$);
  execute d;
end;
$migration$;

-- Clone the installed safety recorder, removing only its SOLO cancellation
-- branch. Input validation, stoppage records, MATCH_STOPPED and moderation
-- reports remain the installed implementation, with guarded source boundaries.
do $migration$
declare d text; first_at integer; last_at integer;
begin
  d:=pg_get_functiondef('public.referee_record_match_stoppage(uuid,text,uuid,text,text,text)'::regprocedure);
  d:=replace(d,'public.referee_record_match_stoppage(','fieldrush_rating_private.record_season_zero_safety_evidence(');
  first_at:=position(E'      update public.open_queue_games\n' in d);
  last_at:=first_at-1+position(E'    end if;\n' in substring(d from first_at));
  if first_at=0 or last_at<=first_at or position('cancellation_code' in substring(d from first_at for last_at-first_at))=0 then
    raise exception 'Safety evidence recorder cancellation branch changed.';
  end if;
  d:=substring(d from 1 for first_at-1)||E'      null; -- V2 outcome belongs to audited organizer adjudication.\n'||substring(d from last_at);
  execute d;
end;
$migration$;

alter function public.referee_record_match_stoppage(uuid,text,uuid,text,text,text) rename to referee_record_match_stoppage_before_season_zero;
create function public.referee_record_match_stoppage(actor_referee_id uuid,match_kind_to_use text,match_id_to_stop uuid,
  mode_to_use text,reason_code_to_use text,note_to_use text default null)
returns uuid language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  if upper(trim(match_kind_to_use))='SOLO' and exists(select 1 from public.open_queue_games
    where id=match_id_to_stop and rating_policy_id='field-sr-season0-v2') then
    raise exception 'Use the revisioned Season 0 safety stoppage workflow.';
  end if;
  return public.referee_record_match_stoppage_before_season_zero(actor_referee_id,match_kind_to_use,match_id_to_stop,mode_to_use,reason_code_to_use,note_to_use);
end;
$$;

create function public.referee_stop_season_zero_match(actor_referee_id uuid,game_id_to_use uuid,
  request_id_to_use uuid,expected_revision integer,mode_to_use text,reason_code_to_use text,note_to_use text default null)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype; state fieldrush_rating_private.season_zero_matches%rowtype;
  prior fieldrush_rating_private.season_zero_action_requests%rowtype; elapsed integer; stoppage uuid; response jsonb;
  mode text:=upper(trim(coalesce(mode_to_use,''))); input_to_use jsonb; prior_clock_status text;
begin
  if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then
    raise exception 'This match is not assigned to you.' using errcode='42501';
  end if;
  if request_id_to_use is null or mode not in ('TEMPORARY','ABANDON') then raise exception 'Provide a safety action and unique request ID.'; end if;
  input_to_use:=jsonb_build_object('action','SAFETY_STOP','mode',mode,'reason',reason_code_to_use,'note',note_to_use);
  perform fieldrush_rating_private.lock_season_zero_sr();
  select * into prior from fieldrush_rating_private.season_zero_action_requests where request_id=request_id_to_use;
  if found then
    if row(prior.game_id,prior.actor_id,prior.input) is distinct from row(game_id_to_use,actor_referee_id,input_to_use) then raise exception 'This request ID belongs to another action.'; end if;
    return prior.response;
  end if;
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  select * into state from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_use for update;
  if g.rating_policy_id is distinct from 'field-sr-season0-v2' or g.status is distinct from 'LIVE'
    or g.operational_state is distinct from 'NORMAL' or state.lifecycle is distinct from 'LIVE' then
    raise exception 'Only an unlocked live Season 0 match can be stopped.';
  end if;
  if state.revision is distinct from expected_revision then raise exception 'Refresh the changed match before stopping it.' using errcode='40001'; end if;
  select status into prior_clock_status from public.open_queue_clock_states where game_id=game_id_to_use and status in ('RUNNING','PAUSED') for update;
  if not found then raise exception 'The live playing clock is missing.'; end if;
  elapsed:=fieldrush_rating_private.season_zero_elapsed(game_id_to_use);
  -- Freeze the authoritative timestamp once, after all locks. The retained
  -- legacy recorder then observes precisely this time, not transaction now().
  update public.open_queue_clock_states set started_at=null,accumulated_seconds=elapsed where game_id=game_id_to_use;
  stoppage:=fieldrush_rating_private.record_season_zero_safety_evidence(actor_referee_id,'SOLO',game_id_to_use,mode,reason_code_to_use,note_to_use);
  update fieldrush_rating_private.season_zero_matches set played_seconds=elapsed,
    lifecycle=case when mode='ABANDON' then 'REVIEW' else 'LIVE' end,rating_status='pending_review',
    events=events||case when prior_clock_status='RUNNING' then jsonb_build_array(jsonb_build_object('id',request_id_to_use,
      'type','PAUSE','second',elapsed,'player_id',null,'recorded_at',clock_timestamp(),'actor_id',actor_referee_id,'note','Safety stop: '||reason_code_to_use)) else '[]'::jsonb end,
    revision=revision+1,updated_at=clock_timestamp() where game_id=game_id_to_use returning * into state;
  if mode='ABANDON' then
    update public.open_queue_games set operational_state='UNDER_REVIEW',operational_state_updated_at=clock_timestamp(),
      operational_reason_code='SEASON_ZERO_SAFETY_REVIEW' where id=game_id_to_use;
  end if;
  insert into fieldrush_rating_private.season_zero_match_revisions(game_id,revision,actor_id,action,reason,evidence)
    values(game_id_to_use,state.revision,actor_referee_id,case when mode='ABANDON' then 'SAFETY_REVIEW' else 'SAFETY_PAUSE' end,
      coalesce(reason_code_to_use,'')||': '||coalesce(note_to_use,''),jsonb_build_object('state',to_jsonb(state),'stoppage_id',stoppage));
  response:=fieldrush_rating_private.replay_season_zero_ratings(game_id_to_use,actor_referee_id,'Verified safety stoppage: '||mode);
  response:=public.get_season_zero_match_state(actor_referee_id,game_id_to_use)||response||jsonb_build_object('stoppage_id',stoppage,'mode',mode);
  insert into fieldrush_rating_private.season_zero_action_requests(request_id,game_id,actor_id,input,response)
    values(request_id_to_use,game_id_to_use,actor_referee_id,input_to_use,response);
  return response;
end;
$$;

-- Goal creation must agree with actual presence, not merely a confirmed booking
-- or a legacy blue-card record. Serialize it with participation/finish actions.
create function fieldrush_rating_private.guard_season_zero_goal()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare game_id_to_use uuid:=case when tg_op='DELETE' then old.game_id else new.game_id end;
  g public.open_queue_games%rowtype; state fieldrush_rating_private.season_zero_matches%rowtype;
  normalized jsonb; participant uuid; expected_team text;
begin
  if tg_op='UPDATE' and new.game_id is distinct from old.game_id and exists(select 1 from public.open_queue_games
    where id in (old.game_id,new.game_id) and rating_policy_id='field-sr-season0-v2') then raise exception 'A goal cannot move between matches.'; end if;
  if not exists(select 1 from public.open_queue_games where id=game_id_to_use and rating_policy_id='field-sr-season0-v2') then
    return case when tg_op='DELETE' then old else new end;
  end if;
  perform fieldrush_rating_private.lock_season_zero_sr();
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  select * into state from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_use for update;
  if g.status is distinct from 'LIVE' or g.operational_state is distinct from 'NORMAL' or state.lifecycle is distinct from 'LIVE'
    or not exists(select 1 from public.open_queue_clock_states where game_id=game_id_to_use and status='RUNNING' and started_at is not null) then
    raise exception 'Goals require an unlocked running Season 0 match.';
  end if;
  if tg_op='DELETE' then return old; end if;
  if tg_op='UPDATE' and new.game_id is distinct from old.game_id then raise exception 'A goal cannot move between matches.'; end if;
  normalized:=fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(game_id_to_use,
    fieldrush_rating_private.season_zero_elapsed(game_id_to_use))||jsonb_build_object('status','pending_review'));
  foreach participant in array array[new.profile_id,new.assist_profile_id] loop
    if participant is null then
      if new.profile_id is null then raise exception 'A goal needs an active scorer.'; end if;
      continue;
    end if;
    select case p->>'team' when 'A' then 'WHITE' when 'B' then 'BLACK' end into expected_team
      from jsonb_array_elements(state.observed_roster) p where p->>'id'=participant::text;
    if expected_team is distinct from new.team or normalized->'audit'->'players'->participant::text->>'final_state' is distinct from 'ACTIVE' then
      raise exception 'Scorer and assist must actually be active on the scoring side.';
    end if;
  end loop;
  return new;
end;
$$;

create function public.admin_get_season_zero_policy(actor_admin_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Active organizer access required.' using errcode='42501'; end if;
  return (select jsonb_build_object('enabled',enabled,'changed_at',changed_at,'changed_by',changed_by)
    from fieldrush_rating_private.season_zero_activation where singleton);
end;
$$;
create trigger a_guard_season_zero_goal before insert or update or delete on public.open_queue_goals
  for each row execute function fieldrush_rating_private.guard_season_zero_goal();

-- Keep the old watchdog untouched for legacy matches; new matches stop safely
-- into review. A watchdog cannot infer an organizer-confirmed result/forfeit.
do $migration$
declare d text;
begin
  d:=pg_get_functiondef('public.auto_stop_overdue_open_queue_clocks()'::regprocedure);
  if position('where game.status = ''LIVE''' in d)=0 then raise exception 'Legacy watchdog selection changed.'; end if;
  d:=replace(d,'where game.status = ''LIVE''','where game.status = ''LIVE'' and game.rating_policy_id<>''field-sr-season0-v2''');
  execute d;
end;
$migration$;
alter function public.auto_stop_overdue_open_queue_clocks() rename to auto_stop_overdue_open_queue_clocks_before_season_zero;
alter table fieldrush_rating_private.season_zero_match_revisions alter column actor_id drop not null;
alter table fieldrush_rating_private.season_zero_match_revisions add constraint season_zero_revision_actor_check
  check(actor_id is not null or action='SYSTEM_CLOCK_REVIEW');
create function public.auto_stop_overdue_open_queue_clocks()
returns integer language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare g record; state fieldrush_rating_private.season_zero_matches%rowtype; stopped integer;
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  stopped:=public.auto_stop_overdue_open_queue_clocks_before_season_zero();
  for g in select game.id from public.open_queue_games game join fieldrush_rating_private.season_zero_matches m on m.game_id=game.id
    join public.open_queue_clock_states c on c.game_id=game.id
    where game.status='LIVE' and game.rating_policy_id='field-sr-season0-v2' and m.lifecycle='LIVE'
      and c.status in ('RUNNING','PAUSED') and fieldrush_rating_private.season_zero_elapsed(game.id)>=10800
    order by game.id for update of game,c
  loop
    update public.open_queue_clock_states set status='ENDED',started_at=null,accumulated_seconds=10800 where game_id=g.id;
    update fieldrush_rating_private.season_zero_matches set lifecycle='REVIEW',rating_status='pending_review',played_seconds=10800,
      revision=revision+1,updated_at=clock_timestamp() where game_id=g.id returning * into state;
    update public.open_queue_games set operational_state='UNDER_REVIEW',operational_state_updated_at=clock_timestamp(),
      operational_reason_code='SEASON_ZERO_CLOCK_REVIEW' where id=g.id;
    insert into public.open_queue_events(game_id,event_type,minute,second,note)
      values(g.id,'MATCH_STOPPED',180,0,'Safety watchdog stopped the clock; organizer review required. No result inferred.');
    insert into fieldrush_rating_private.season_zero_match_revisions(game_id,revision,actor_id,action,reason,evidence)
      values(g.id,state.revision,null,'SYSTEM_CLOCK_REVIEW','Three-hour safety limit reached; outcome unresolved.',to_jsonb(state));
    perform fieldrush_rating_private.replay_season_zero_ratings(g.id,null,'Safety watchdog holds unresolved match and dependent ratings.');
    stopped:=stopped+1;
  end loop;
  return stopped;
end;
$$;

revoke all on function fieldrush_rating_private.record_season_zero_safety_evidence(uuid,text,uuid,text,text,text),
  fieldrush_rating_private.protect_season_zero_kickoff_snapshot(),fieldrush_rating_private.guard_season_zero_frozen_booking(),
  fieldrush_rating_private.guard_season_zero_started_game(),
  fieldrush_rating_private.guard_season_zero_goal(),public.referee_record_match_stoppage_before_season_zero(uuid,text,uuid,text,text,text),
  public.auto_stop_overdue_open_queue_clocks_before_season_zero() from public,anon,authenticated,service_role;
revoke all on function public.referee_stop_season_zero_match(uuid,uuid,uuid,integer,text,text,text),
  public.admin_get_season_zero_policy(uuid),
  public.referee_record_match_stoppage(uuid,text,uuid,text,text,text),public.auto_stop_overdue_open_queue_clocks() from public,anon,authenticated;
grant execute on function public.referee_stop_season_zero_match(uuid,uuid,uuid,integer,text,text,text),
  public.admin_get_season_zero_policy(uuid),
  public.referee_record_match_stoppage(uuid,text,uuid,text,text,text),public.auto_stop_overdue_open_queue_clocks() to service_role;
notify pgrst,'reload schema';
