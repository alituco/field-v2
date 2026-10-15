-- Prospective policy activation and private, revisioned match-clock evidence.
-- Applying this migration does not activate the policy or alter a past match.
create table fieldrush_rating_private.season_zero_activation (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false,
  changed_at timestamptz not null default clock_timestamp(),
  changed_by uuid references public.profiles(id)
);
insert into fieldrush_rating_private.season_zero_activation(singleton) values(true);

alter table public.open_queue_games add column rating_policy_id text not null default 'LEGACY';
alter table public.open_queue_games add constraint open_queue_rating_policy_check
  check(rating_policy_id in ('LEGACY','field-sr-season0-v2'));
grant select(rating_policy_id) on public.open_queue_games to authenticated;

create function fieldrush_rating_private.pin_solo_rating_policy()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  if tg_op='UPDATE' then
    if new.rating_policy_id is distinct from old.rating_policy_id then
      raise exception 'The advertised rating policy cannot change. Create a new game.';
    end if;
  else
    new.rating_policy_id:=case when new.format_version='FIELDRUSH_7V7'
      and (select enabled from fieldrush_rating_private.season_zero_activation where singleton)
      then 'field-sr-season0-v2' else 'LEGACY' end;
  end if;
  return new;
end;
$$;
create trigger pin_solo_rating_policy before insert or update of rating_policy_id on public.open_queue_games
  for each row execute function fieldrush_rating_private.pin_solo_rating_policy();

create table fieldrush_rating_private.season_zero_matches (
  game_id uuid primary key references public.open_queue_games(id) on delete restrict,
  policy_id text not null default 'field-sr-season0-v2' check(policy_id='field-sr-season0-v2'),
  started_at timestamptz not null,
  scheduled_seconds integer not null check(scheduled_seconds between 600 and 10800),
  played_seconds integer not null default 0 check(played_seconds between 0 and 10800),
  revision integer not null default 1 check(revision>0),
  lifecycle text not null default 'LIVE' check(lifecycle in ('LIVE','REVIEW','FINAL')),
  rating_status text not null default 'pending_review' check(rating_status in
    ('pending_review','completed','forfeit_confirmed','no_contest','cancelled','unranked')),
  winner text check(winner in ('A','B')),
  -- Observed kickoff snapshots never change during replay. Applied snapshots
  -- and explanations are separately retained in settlement revisions.
  observed_roster jsonb not null check(jsonb_typeof(observed_roster)='array'),
  events jsonb not null default '[]' check(jsonb_typeof(events)='array'),
  adjudicated_by uuid references public.profiles(id),
  adjudication_reason text,
  updated_at timestamptz not null default clock_timestamp()
);
create table fieldrush_rating_private.season_zero_match_revisions (
  game_id uuid not null references fieldrush_rating_private.season_zero_matches(game_id),
  revision integer not null,
  actor_id uuid not null references public.profiles(id),
  action text not null,
  reason text not null,
  evidence jsonb not null,
  recorded_at timestamptz not null default clock_timestamp(),
  primary key(game_id,revision)
);
create table fieldrush_rating_private.season_zero_action_requests (
  request_id uuid primary key,
  game_id uuid not null references public.open_queue_games(id),
  actor_id uuid not null references public.profiles(id),
  input jsonb not null,
  response jsonb not null,
  recorded_at timestamptz not null default clock_timestamp()
);
revoke all on fieldrush_rating_private.season_zero_activation,
  fieldrush_rating_private.season_zero_matches,fieldrush_rating_private.season_zero_match_revisions,
  fieldrush_rating_private.season_zero_action_requests from public,anon,authenticated,service_role;

create function fieldrush_rating_private.lock_season_zero_sr()
returns void language sql volatile set search_path=public,pg_temp as $$
  select pg_advisory_xact_lock(hashtextextended('fieldrush-season-zero-rating',0));
$$;

create function fieldrush_rating_private.season_zero_elapsed(game_to_use uuid)
returns integer language sql volatile set search_path=public,pg_temp as $$
  select least(10800,accumulated_seconds+case when status='RUNNING' then
    greatest(0,floor(extract(epoch from(clock_timestamp()-started_at)))::integer) else 0 end)
  from public.open_queue_clock_states where game_id=game_to_use;
$$;

create function fieldrush_rating_private.season_zero_input(game_to_use uuid,played_to_use integer default null)
returns jsonb language sql stable set search_path=public,fieldrush_rating_private,pg_temp as $$
  select jsonb_build_object('policy_id',policy_id,'status',rating_status,'winner',winner,
    'scheduled_seconds',scheduled_seconds,'played_seconds',coalesce(played_to_use,played_seconds),
    'roster',observed_roster,'events',events)
  from fieldrush_rating_private.season_zero_matches where game_id=game_to_use;
$$;

create function public.get_season_zero_match_state(actor_referee_id uuid,game_id_to_use uuid)
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
  return to_jsonb(state)||jsonb_build_object('elapsed_seconds',elapsed,'audit',normalized->'audit','server_now',clock_timestamp());
end;
$$;

create function public.admin_set_season_zero_policy(actor_admin_id uuid,enabled_to_use boolean,reason_to_use text)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare previous jsonb; updated jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin access required.' using errcode='42501'; end if;
  if enabled_to_use is null or char_length(trim(coalesce(reason_to_use,'')))<10 then
    raise exception 'Give an activation or rollback reason of at least ten characters.';
  end if;
  perform fieldrush_rating_private.lock_season_zero_sr();
  select to_jsonb(a) into previous from fieldrush_rating_private.season_zero_activation a where singleton for update;
  update fieldrush_rating_private.season_zero_activation set enabled=enabled_to_use,changed_at=clock_timestamp(),changed_by=actor_admin_id where singleton;
  select to_jsonb(a) into updated from fieldrush_rating_private.season_zero_activation a where singleton;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,'SOLO_SR_POLICY_ACTIVATION','ACTION',actor_admin_id,trim(reason_to_use),previous,updated);
  return updated;
end;
$$;

-- Every operational action is a single server transaction. Neither the browser
-- clock nor a client-supplied SR/count is accepted as evidence.
create function public.referee_season_zero_action(actor_referee_id uuid,game_id_to_use uuid,
  request_id_to_use uuid,expected_revision integer,action_input jsonb)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype; state fieldrush_rating_private.season_zero_matches%rowtype;
  previous_request fieldrush_rating_private.season_zero_action_requests%rowtype;
  action_name text:=action_input->>'action'; player_id uuid; recorded timestamptz;
  elapsed integer; roster jsonb; event jsonb; normalized jsonb; response jsonb; clock_status text;
  active_a integer; active_b integer; initial_ids uuid[]; selected_count integer;
begin
  if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then
    raise exception 'This match is not assigned to you.' using errcode='42501';
  end if;
  if request_id_to_use is null or jsonb_typeof(action_input) is distinct from 'object' then raise exception 'An action request is required.'; end if;
  if exists(select 1 from jsonb_object_keys(action_input) k where k not in ('action','profile_id','participant_ids','note')) then
    raise exception 'Unsupported match evidence input.';
  end if;
  if action_name is null or action_name not in ('START','PAUSE','RESUME','JOIN','EXCUSED_LEAVE','RETURN','QUIT','RED_CARD','BLUE_CARD','BLUE_RETURN') then
    raise exception 'Unknown participation action.';
  end if;
  -- Match the existing SOLO/CLAN kickoff order before acquiring game or rating
  -- rows. The clock/season triggers below re-enter this same transaction lock.
  -- Other live actions already have a frozen season and need no calendar lock.
  if action_name='START' then
    perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
  end if;
  perform fieldrush_rating_private.lock_season_zero_sr();
  select * into previous_request from fieldrush_rating_private.season_zero_action_requests where request_id=request_id_to_use;
  if found then
    if (previous_request.game_id,previous_request.actor_id,previous_request.input) is distinct from
      (game_id_to_use,actor_referee_id,action_input) then raise exception 'This request ID belongs to another action.'; end if;
    return previous_request.response;
  end if;
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  if g.rating_policy_id is distinct from 'field-sr-season0-v2' then raise exception 'This game uses the earlier rating policy.'; end if;
  if g.operational_state is distinct from 'NORMAL' then raise exception 'This match is locked for organizer review.'; end if;
  select * into state from fieldrush_rating_private.season_zero_matches where game_id=g.id for update;
  -- Lock waits must not backdate the blue-card wall timer or observed kickoff.
  recorded:=clock_timestamp();
  if action_name='START' then
    if state.game_id is not null or expected_revision is distinct from 0 then raise exception 'The match already started. Refresh its state.'; end if;
    if g.status not in ('OPEN','FULL') or g.starts_at>recorded then raise exception 'Wait until the scheduled kickoff to start this match.'; end if;
    if g.teams_assigned_at is null then raise exception 'Assign the booked teams before kickoff.'; end if;
    if jsonb_typeof(action_input->'participant_ids') is distinct from 'array' then raise exception 'Confirm the actual starting players.'; end if;
    select array_agg(value::uuid),count(*) into initial_ids,selected_count from jsonb_array_elements_text(action_input->'participant_ids');
    if selected_count<> (select count(distinct x) from unnest(initial_ids) x) then raise exception 'Duplicate starting player.'; end if;
    if selected_count<> (select count(*) from public.open_queue_bookings where game_id=g.id and status='CONFIRMED' and profile_id=any(initial_ids)) then
      raise exception 'Only originally booked players may take part.';
    end if;
    if exists(select 1 from unnest(initial_ids) p where not exists(select 1 from public.match_attendance_records a
      join public.open_queue_bookings b on b.id=a.booking_id and b.status='CONFIRMED'
      where b.game_id=g.id and b.profile_id=p and a.checked_in_at is not null)) then
      raise exception 'Check in each actual starting player before kickoff.';
    end if;
    perform 1 from public.fieldrush_player_rating_tracks r join public.open_queue_bookings b on b.profile_id=r.profile_id
      and r.rating_track=public.fieldrush_rating_track(b.role) where b.game_id=g.id and b.status='CONFIRMED' order by r.profile_id,r.rating_track for update of r;
    select jsonb_agg(jsonb_build_object('id',b.profile_id,'booking_id',b.id,'team',case b.team when 'WHITE' then 'A' when 'BLACK' then 'B' else null end,
      'rating_track',r.rating_track,'booked_role',b.role,'sr_before',r.skill_rating,'games_before',r.matches_played,
      'initial_active',b.profile_id=any(initial_ids)) order by b.profile_id) into roster
    from public.open_queue_bookings b left join public.fieldrush_player_rating_tracks r
      on r.profile_id=b.profile_id and r.rating_track=public.fieldrush_rating_track(b.role)
    where b.game_id=g.id and b.status='CONFIRMED';
    insert into fieldrush_rating_private.season_zero_matches(game_id,started_at,scheduled_seconds,observed_roster)
    values(g.id,recorded,extract(epoch from(g.ends_at-g.starts_at))::integer,coalesce(roster,'[]'));
    normalized:=fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(g.id,0));
    select count(*) filter(where p->>'team'='A' and (p->>'initial_active')::boolean),
      count(*) filter(where p->>'team'='B' and (p->>'initial_active')::boolean) into active_a,active_b from jsonb_array_elements(roster) p;
    if active_a<5 or active_b<5 then raise exception 'At least five actual players per team are required to start.'; end if;
    update public.open_queue_bookings b set played=b.profile_id=any(initial_ids),rating_at_match_start=(p->>'sr_before')::integer,rating_change=null
      from jsonb_array_elements(roster) p where b.id=(p->>'booking_id')::uuid;
    insert into public.open_queue_clock_states(game_id,status,started_at,accumulated_seconds,duration_seconds)
    values(g.id,'RUNNING',recorded,0,extract(epoch from(g.ends_at-g.starts_at))::integer)
    on conflict(game_id) do update set status='RUNNING',started_at=excluded.started_at,accumulated_seconds=0,duration_seconds=excluded.duration_seconds;
    update public.open_queue_games set status='LIVE' where id=g.id;
    insert into public.open_queue_events(game_id,event_type,occurred_at) values(g.id,'MATCH_STARTED',recorded);
  else
    if g.status<>'LIVE' or state.lifecycle is distinct from 'LIVE' then raise exception 'Participation can only change during a live match.'; end if;
    if state.revision is distinct from expected_revision then raise exception 'The match changed. Refresh before recording this action.' using errcode='40001'; end if;
    elapsed:=fieldrush_rating_private.season_zero_elapsed(g.id);
    select status into clock_status from public.open_queue_clock_states where game_id=g.id for update;
    if action_name='PAUSE' and clock_status<>'RUNNING' then raise exception 'The match is already paused.'; end if;
    if action_name='RESUME' and clock_status<>'PAUSED' then raise exception 'The match is not paused.'; end if;
    if action_name not in ('PAUSE','RESUME') then
      player_id:=(action_input->>'profile_id')::uuid;
      if player_id is null then raise exception 'Choose a player.'; end if;
    end if;
    if action_name='JOIN' and not exists(select 1 from public.match_attendance_records a
      join public.open_queue_bookings b on b.id=a.booking_id and b.status='CONFIRMED'
      where b.game_id=g.id and b.profile_id=player_id and a.checked_in_at is not null) then
      raise exception 'Check in the booked player before recording their actual entry.';
    end if;
    if action_name in ('EXCUSED_LEAVE','QUIT','RED_CARD') and char_length(trim(coalesce(action_input->>'note','')))<3 then
      raise exception 'Record the reason for this departure.';
    end if;
    event:=jsonb_build_object('id',request_id_to_use,'type',action_name,'second',elapsed,'player_id',player_id,
      'recorded_at',recorded,'actor_id',actor_referee_id,'note',coalesce(action_input->>'note',''));
    update fieldrush_rating_private.season_zero_matches set events=events||jsonb_build_array(event),
      played_seconds=elapsed,revision=revision+1,updated_at=recorded where game_id=g.id;
    normalized:=fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(g.id,elapsed));
    select count(*) filter(where r->>'team'='A' and normalized->'audit'->'players'->(r->>'id')->>'final_state'='ACTIVE'),
      count(*) filter(where r->>'team'='B' and normalized->'audit'->'players'->(r->>'id')->>'final_state'='ACTIVE') into active_a,active_b
    from jsonb_array_elements(state.observed_roster) r;
    if action_name='RESUME' and (active_a<5 or active_b<5) then raise exception 'At least five players per team must be back before resuming.'; end if;
    if action_name='PAUSE' or (clock_status='RUNNING' and (active_a<5 or active_b<5)) then
      if action_name<>'PAUSE' then
        update fieldrush_rating_private.season_zero_matches set events=events||jsonb_build_array(jsonb_build_object(
          'id',gen_random_uuid(),'type','PAUSE','second',elapsed,'player_id',null,'recorded_at',recorded,'actor_id',actor_referee_id,
          'note','Automatic stop: fewer than five actual players on a side.')) where game_id=g.id;
      end if;
      update public.open_queue_clock_states set status='PAUSED',started_at=null,accumulated_seconds=elapsed where game_id=g.id;
    elsif action_name='RESUME' then
      update public.open_queue_clock_states set status='RUNNING',started_at=recorded where game_id=g.id;
    end if;
    if action_name in ('JOIN','RETURN','BLUE_RETURN') then update public.open_queue_bookings set played=true where game_id=g.id and profile_id=player_id and status='CONFIRMED'; end if;
  end if;
  select * into state from fieldrush_rating_private.season_zero_matches where game_id=g.id;
  insert into fieldrush_rating_private.season_zero_match_revisions(game_id,revision,actor_id,action,reason,evidence)
  values(g.id,state.revision,actor_referee_id,action_name,coalesce(action_input->>'note',''),to_jsonb(state));
  response:=public.get_season_zero_match_state(actor_referee_id,g.id);
  insert into fieldrush_rating_private.season_zero_action_requests(request_id,game_id,actor_id,input,response)
  values(request_id_to_use,g.id,actor_referee_id,action_input,response);
  return response;
end;
$$;

revoke all on function fieldrush_rating_private.pin_solo_rating_policy(),fieldrush_rating_private.lock_season_zero_sr(),
  fieldrush_rating_private.season_zero_elapsed(uuid),fieldrush_rating_private.season_zero_input(uuid,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.get_season_zero_match_state(uuid,uuid),public.admin_set_season_zero_policy(uuid,boolean,text),
  public.referee_season_zero_action(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.get_season_zero_match_state(uuid,uuid),public.admin_set_season_zero_policy(uuid,boolean,text),
  public.referee_season_zero_action(uuid,uuid,uuid,integer,jsonb) to service_role;

-- Legacy service entry points cannot accidentally start the new policy without
-- its authoritative roster/clock evidence. Old games keep their existing path.
alter function public.referee_start_open_queue_game(uuid,uuid[],integer) rename to referee_start_open_queue_game_before_season_zero;
create function public.referee_start_open_queue_game(game_id_to_start uuid,participant_ids_to_use uuid[],duration_seconds_to_use integer)
returns public.open_queue_games language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if exists(select 1 from public.open_queue_games where id=game_id_to_start and rating_policy_id='field-sr-season0-v2') then
    raise exception 'Start this game through the Season 0 participation controls.';
  end if;
  return public.referee_start_open_queue_game_before_season_zero(game_id_to_start,participant_ids_to_use,duration_seconds_to_use);
end;
$$;
revoke all on function public.referee_start_open_queue_game_before_season_zero(uuid,uuid[],integer) from public,anon,authenticated,service_role;
revoke all on function public.referee_start_open_queue_game(uuid,uuid[],integer) from public,anon,authenticated;
grant execute on function public.referee_start_open_queue_game(uuid,uuid[],integer) to service_role;

create function fieldrush_rating_private.reject_season_zero_reserve()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.status='ACTIVE' and new.match_kind='SOLO' and exists(select 1 from public.open_queue_games
    where id=new.open_queue_game_id and rating_policy_id='field-sr-season0-v2') then
    raise exception 'This rating policy allows originally booked players only, without external replacements.';
  end if;
  return new;
end;
$$;
create trigger reject_season_zero_reserve before insert or update on public.match_reserve_assignments
  for each row execute function fieldrush_rating_private.reject_season_zero_reserve();
revoke all on function fieldrush_rating_private.reject_season_zero_reserve() from public,anon,authenticated,service_role;
