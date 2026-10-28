-- Atomic prospective settlement and chronological replay. Legacy matches keep
-- their original algorithm and fixed earned movements; they are never rerated.
-- Old-policy future matches can now encounter signed canonical SR. Extend
-- only the helper's input domain; retain its K, rounding, minima and cap (and
-- leave the legacy award writer's own zero-floor/margin rules untouched).
do $migration$
declare d text;
begin
  d:=pg_get_functiondef('public.calculate_player_sr_change(integer,numeric,text)'::regprocedure);
  if position('player_rating_to_use is null or player_rating_to_use < 0' in d)=0
    or position('opponent_average_to_use is null or opponent_average_to_use < 0' in d)=0 then
    raise exception 'Legacy SR helper domain contract changed.';
  end if;
  d:=replace(d,'player_rating_to_use is null or player_rating_to_use < 0','player_rating_to_use is null');
  d:=replace(d,'opponent_average_to_use is null or opponent_average_to_use < 0',
    'opponent_average_to_use is null or opponent_average_to_use::text in (''NaN'',''Infinity'',''-Infinity'')');
  -- Preserve the original expression exactly in its ordinary domain. Extreme
  -- differences saturate far below the helper's integer rounding precision.
  d:=replace(d,'  expected_score := 1 / (','  expected_score := case when opponent_average_to_use-player_rating_to_use > 100000 then 0::numeric when opponent_average_to_use-player_rating_to_use < -100000 then 1::numeric else 1 / (');
  d:=replace(d,E'  );\n  actual_score :=',E'  ) end;\n  actual_score :=');
  execute d;
end;
$migration$;

create table fieldrush_rating_private.season_zero_rating_baselines (
  profile_id uuid not null references public.profiles(id),
  rating_track text not null check(rating_track in ('OUTFIELD','GOALKEEPER')),
  baseline jsonb not null,
  captured_at timestamptz not null default clock_timestamp(),
  primary key(profile_id,rating_track)
);
create table fieldrush_rating_private.season_zero_legacy_movements (
  id bigint generated always as identity primary key,
  profile_id uuid not null,
  rating_track text not null,
  source_game_id uuid,
  ordering_at timestamptz not null,
  movement jsonb not null,
  context jsonb not null,
  recorded_at timestamptz not null default clock_timestamp(),
  foreign key(profile_id,rating_track) references fieldrush_rating_private.season_zero_rating_baselines
);
create table fieldrush_rating_private.season_zero_settlement_runs (
  id uuid primary key default gen_random_uuid(),
  requested_game_id uuid references public.open_queue_games(id),
  actor_id uuid references public.profiles(id),
  reason text not null,
  created_at timestamptz not null default clock_timestamp()
);
create table fieldrush_rating_private.season_zero_settlement_revisions (
  id bigint generated always as identity primary key,
  run_id uuid not null references fieldrush_rating_private.season_zero_settlement_runs(id),
  game_id uuid not null references fieldrush_rating_private.season_zero_matches(game_id),
  match_revision integer not null,
  status text not null check(status in ('RATED','NOT_RATED','HELD')),
  input_snapshot jsonb not null,
  normalization jsonb,
  calculation jsonb,
  supersedes_id bigint references fieldrush_rating_private.season_zero_settlement_revisions(id),
  created_at timestamptz not null default clock_timestamp()
);
create table fieldrush_rating_private.season_zero_active_settlements (
  game_id uuid primary key references fieldrush_rating_private.season_zero_matches(game_id),
  settlement_id bigint not null unique references fieldrush_rating_private.season_zero_settlement_revisions(id)
);
alter table fieldrush_rating_private.season_zero_matches add column settlement_status text not null default 'UNSETTLED'
  check(settlement_status in ('UNSETTLED','RATED','NOT_RATED','HELD'));
revoke all on fieldrush_rating_private.season_zero_rating_baselines,
  fieldrush_rating_private.season_zero_legacy_movements,fieldrush_rating_private.season_zero_settlement_runs,
  fieldrush_rating_private.season_zero_settlement_revisions,fieldrush_rating_private.season_zero_active_settlements
  from public,anon,authenticated,service_role;

create function fieldrush_rating_private.protect_season_zero_append_only()
returns trigger language plpgsql set search_path=pg_catalog as $$
begin raise exception 'Season 0 rating history is append-only.' using errcode='42501'; end;
$$;
create trigger protect_season_zero_baselines before update or delete on fieldrush_rating_private.season_zero_rating_baselines
  for each row execute function fieldrush_rating_private.protect_season_zero_append_only();
create trigger protect_season_zero_movements before update or delete on fieldrush_rating_private.season_zero_legacy_movements
  for each row execute function fieldrush_rating_private.protect_season_zero_append_only();
create trigger protect_season_zero_settlements before update or delete on fieldrush_rating_private.season_zero_settlement_revisions
  for each row execute function fieldrush_rating_private.protect_season_zero_append_only();

create function fieldrush_rating_private.capture_season_zero_baselines()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  insert into fieldrush_rating_private.season_zero_rating_baselines(profile_id,rating_track,baseline)
  select r.profile_id,r.rating_track,jsonb_build_object('sr',r.skill_rating,'games',r.matches_played,
    'wins',r.wins,'losses',r.losses,'draws',r.draws,'last_change',r.last_change)
  from jsonb_array_elements(new.observed_roster) p join public.fieldrush_player_rating_tracks r
    on r.profile_id=(p->>'id')::uuid and r.rating_track=p->>'rating_track'
  on conflict(profile_id,rating_track) do nothing;
  if exists(select 1 from jsonb_array_elements(new.observed_roster) p
    where not exists(select 1 from fieldrush_rating_private.season_zero_rating_baselines b
      where b.profile_id=(p->>'id')::uuid and b.rating_track=p->>'rating_track')) then
    raise exception 'Every participant needs an initialized rating-pool baseline.';
  end if;
  return new;
end;
$$;
create trigger capture_season_zero_baselines after insert on fieldrush_rating_private.season_zero_matches
  for each row execute function fieldrush_rating_private.capture_season_zero_baselines();

-- Point-in-time SR is reconstructed from the same active movements as replay,
-- never from applied_sequence (a corrected old award may be inserted last) or
-- an immutable legacy rating_after (its preceding v2 history may change).
-- No row before this pool's first v2 season means the legacy reader is used.
create function fieldrush_rating_private.season_zero_track_rating_at(player_to_use uuid,track_to_use text,season_ends_on date)
returns table(skill_rating integer,last_change integer)
language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare baseline_to_use jsonb; first_season_end date; item record;
begin
  select baseline into baseline_to_use from fieldrush_rating_private.season_zero_rating_baselines
    where profile_id=player_to_use and rating_track=track_to_use;
  if baseline_to_use is null then return; end if;
  select min(coalesce(s.ends_on,(m.started_at at time zone g.timezone)::date)) into first_season_end
    from fieldrush_rating_private.season_zero_matches m join public.open_queue_games g on g.id=m.game_id
    left join public.fieldrush_seasons s on s.id=g.season_id
    where exists(select 1 from jsonb_array_elements(m.observed_roster) p
      where p->>'id'=player_to_use::text and p->>'rating_track'=track_to_use);
  if first_season_end is null or first_season_end>season_ends_on then return; end if;
  skill_rating:=(baseline_to_use->>'sr')::integer; last_change:=(baseline_to_use->>'last_change')::integer;
  for item in
    select m.ordering_at,coalesce(m.source_game_id::text,m.id::text) ordering_key,'LEGACY' kind,m.id movement_id,
      (m.movement->>'sr')::integer delta,(m.movement->>'last_change')::integer change,true changes_last
    from fieldrush_rating_private.season_zero_legacy_movements m
    left join public.open_queue_games g on g.id=m.source_game_id left join public.fieldrush_seasons s on s.id=g.season_id
    where m.profile_id=player_to_use and m.rating_track=track_to_use
      and coalesce(s.ends_on,(m.ordering_at at time zone coalesce(g.timezone,'America/Phoenix'))::date)<=season_ends_on
    union all
    select m.started_at,m.game_id::text,'MATCH',null::bigint,
      (r.calculation->'players'->player_to_use::text->>'delta')::integer,
      (r.calculation->'players'->player_to_use::text->>'delta')::integer,
      (r.calculation->'players'->player_to_use::text->>'counted')::boolean
        or (r.calculation->'players'->player_to_use::text->>'delta')::integer<>0
    from fieldrush_rating_private.season_zero_matches m
    join fieldrush_rating_private.season_zero_active_settlements a on a.game_id=m.game_id
    join fieldrush_rating_private.season_zero_settlement_revisions r on r.id=a.settlement_id and r.status='RATED'
    join public.open_queue_games g on g.id=m.game_id left join public.fieldrush_seasons s on s.id=g.season_id
    where exists(select 1 from jsonb_array_elements(m.observed_roster) p
      where p->>'id'=player_to_use::text and p->>'rating_track'=track_to_use)
      and coalesce(s.ends_on,(m.started_at at time zone g.timezone)::date)<=season_ends_on
    order by ordering_at,ordering_key,kind,movement_id
  loop
    skill_rating:=skill_rating+item.delta;
    if item.changes_last then last_change:=item.change; end if;
  end loop;
  return next;
end;
$$;

-- A baseline-enrolled track may change through replay or the existing audited
-- legacy writers. Unknown direct edits/reset operations fail rather than erase
-- the replay boundary. The initialization migration acts before enrollment.
create function fieldrush_rating_private.capture_legacy_rating_movement()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare context_to_use jsonb; game_id uuid; ordering_at_to_use timestamptz;
begin
  if row(new.skill_rating,new.matches_played,new.wins,new.losses,new.draws,new.last_change)
      is not distinct from row(old.skill_rating,old.matches_played,old.wins,old.losses,old.draws,old.last_change)
    or coalesce(current_setting('fieldrush.season_zero_replay',true),'')='on'
    or not exists(select 1 from fieldrush_rating_private.season_zero_rating_baselines
      where profile_id=new.profile_id and rating_track=new.rating_track) then return new; end if;
  context_to_use:=nullif(current_setting('fieldrush.season_zero_legacy_context',true),'')::jsonb;
  if context_to_use is null then
    raise exception 'This rating has a replay baseline. Use the audited match correction workflow; resets/direct edits are not allowed.' using errcode='42501';
  end if;
  perform fieldrush_rating_private.lock_season_zero_sr();
  game_id:=(context_to_use->>'game_id')::uuid;
  if game_id is not null then
    if exists(select 1 from public.open_queue_games where id=game_id and rating_policy_id='field-sr-season0-v2') then
      raise exception 'The legacy rating path cannot alter a Season 0 result.';
    end if;
    select coalesce((select min(e.occurred_at) from public.open_queue_events e where e.game_id=g.id and e.event_type='MATCH_STARTED'),g.starts_at)
      into ordering_at_to_use from public.open_queue_games g where g.id=game_id;
  end if;
  insert into fieldrush_rating_private.season_zero_legacy_movements(profile_id,rating_track,source_game_id,ordering_at,movement,context)
  values(new.profile_id,new.rating_track,game_id,coalesce(ordering_at_to_use,clock_timestamp()),jsonb_build_object(
    'sr',new.skill_rating-old.skill_rating,'games',new.matches_played-old.matches_played,
    'wins',new.wins-old.wins,'losses',new.losses-old.losses,'draws',new.draws-old.draws,
    'last_change',new.last_change),context_to_use);
  return new;
end;
$$;
create trigger capture_season_zero_legacy_movement before update on public.fieldrush_player_rating_tracks
  for each row execute function fieldrush_rating_private.capture_legacy_rating_movement();

create function fieldrush_rating_private.replay_season_zero_ratings(requested_game uuid,actor uuid,reason_to_use text)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare
  working jsonb:='{}'; blocked jsonb:='{}'; item record; p jsonb; player_key text; player_state jsonb;
  state fieldrush_rating_private.season_zero_matches%rowtype; applied_roster jsonb; input_to_use jsonb;
  normalized jsonb; calculated jsonb; result jsonb; status_to_use text; result_name text; counted boolean;
  previous fieldrush_rating_private.season_zero_settlement_revisions%rowtype;
  run_id_to_use uuid; settlement_id_to_use bigint; changed integer:=0; held boolean; prior_replay text; projection_changed boolean; independently_not_rated boolean;
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  perform 1 from public.fieldrush_player_rating_tracks r join fieldrush_rating_private.season_zero_rating_baselines b
    on b.profile_id=r.profile_id and b.rating_track=r.rating_track order by r.profile_id,r.rating_track for update of r;
  if exists(select 1 from fieldrush_rating_private.season_zero_rating_baselines b where not exists(
    select 1 from public.fieldrush_player_rating_tracks r where r.profile_id=b.profile_id and r.rating_track=b.rating_track)) then
    raise exception 'An enrolled lifetime rating pool is missing; replay cannot discard it.';
  end if;
  select coalesce(jsonb_object_agg(profile_id::text||':'||rating_track,baseline),'{}') into working
    from fieldrush_rating_private.season_zero_rating_baselines;
  insert into fieldrush_rating_private.season_zero_settlement_runs(requested_game_id,actor_id,reason)
    values(requested_game,actor,reason_to_use) returning id into run_id_to_use;
  prior_replay:=current_setting('fieldrush.season_zero_replay',true);
  perform set_config('fieldrush.season_zero_replay','on',true);
  for item in
    select 'MATCH' kind,started_at ordering_at,game_id::text ordering_key,game_id,null::bigint movement_id
      from fieldrush_rating_private.season_zero_matches
    union all
    select 'LEGACY',ordering_at,coalesce(source_game_id::text,id::text),null,id
      from fieldrush_rating_private.season_zero_legacy_movements
    order by ordering_at,ordering_key,kind,movement_id
  loop
    if item.kind='LEGACY' then
      select profile_id::text||':'||rating_track,movement into player_key,result
        from fieldrush_rating_private.season_zero_legacy_movements where id=item.movement_id;
      player_state:=working->player_key;
      if player_state is null then raise exception 'A legacy movement has no rating baseline.'; end if;
      player_state:=jsonb_build_object('sr',(player_state->>'sr')::integer+(result->>'sr')::integer,
        'games',(player_state->>'games')::integer+(result->>'games')::integer,
        'wins',(player_state->>'wins')::integer+(result->>'wins')::integer,
        'losses',(player_state->>'losses')::integer+(result->>'losses')::integer,
        'draws',(player_state->>'draws')::integer+(result->>'draws')::integer,'last_change',result->'last_change');
      if (player_state->>'games')::integer<0 then raise exception 'Legacy movement would make the lifetime appearance count negative.'; end if;
      working:=jsonb_set(working,array[player_key],player_state); continue;
    end if;
    select * into state from fieldrush_rating_private.season_zero_matches where game_id=item.game_id;
    applied_roster:='[]'; held:=state.lifecycle<>'FINAL' or state.rating_status='pending_review';
    -- An independently unrated final match is not a rating dependency edge.
    -- It cannot carry an unrelated earlier player's hold into another pool.
    independently_not_rated:=state.lifecycle='FINAL' and (state.rating_status in ('cancelled','no_contest','unranked')
      or (state.rating_status='forfeit_confirmed' and state.played_seconds<600));
    for p in select value from jsonb_array_elements(state.observed_roster) loop
      player_key:=(p->>'id')||':'||(p->>'rating_track'); player_state:=working->player_key;
      if player_state is null then raise exception 'A participant is missing its rating-pool baseline.'; end if;
      held:=held or (not independently_not_rated and blocked ? player_key);
      applied_roster:=applied_roster||jsonb_build_array(p||jsonb_build_object('sr_before',(player_state->>'sr')::integer,'games_before',(player_state->>'games')::integer));
    end loop;
    input_to_use:=fieldrush_rating_private.season_zero_input(state.game_id)||jsonb_build_object('roster',applied_roster);
    if held then
      for p in select value from jsonb_array_elements(state.observed_roster) loop
        blocked:=jsonb_set(blocked,array[(p->>'id')||':'||(p->>'rating_track')],to_jsonb(state.game_id));
      end loop;
      status_to_use:='HELD'; normalized:=null; calculated:=null;
    else
      normalized:=fieldrush_rating_private.normalize_season_zero_sr(input_to_use);
      calculated:=fieldrush_rating_private.calculate_season_zero_sr(normalized->'core');
      status_to_use:=calculated->>'settlement';
      if status_to_use='HELD' then raise exception 'Unresolved match cannot enter final settlement.'; end if;
      if status_to_use='RATED' then
        for p in select value from jsonb_array_elements(applied_roster) loop
          player_key:=(p->>'id')||':'||(p->>'rating_track'); player_state:=working->player_key;
          result:=calculated->'players'->(p->>'id'); counted:=(result->>'counted')::boolean;
          result_name:=case when state.winner is null then 'DRAW' when state.winner=p->>'team' then 'WIN' else 'LOSS' end;
          working:=jsonb_set(working,array[player_key],jsonb_build_object('sr',(result->>'sr_after')::integer,
            'games',(result->>'games_after')::integer,'wins',(player_state->>'wins')::integer+(counted and result_name='WIN')::integer,
            'losses',(player_state->>'losses')::integer+(counted and result_name='LOSS')::integer,
            'draws',(player_state->>'draws')::integer+(counted and result_name='DRAW')::integer,
            'last_change',case when counted or (result->>'delta')::integer<>0 then (result->>'delta')::integer else (player_state->>'last_change')::integer end));
        end loop;
      end if;
    end if;
    select r.* into previous from fieldrush_rating_private.season_zero_active_settlements a
      join fieldrush_rating_private.season_zero_settlement_revisions r on r.id=a.settlement_id where a.game_id=state.game_id;
    projection_changed:=false;
    if previous.id is null or row(previous.match_revision,previous.status,previous.input_snapshot,previous.normalization,previous.calculation)
        is distinct from row(state.revision,status_to_use,input_to_use,normalized,calculated) then
      insert into fieldrush_rating_private.season_zero_settlement_revisions(run_id,game_id,match_revision,status,input_snapshot,normalization,calculation,supersedes_id)
        values(run_id_to_use,state.game_id,state.revision,status_to_use,input_to_use,normalized,calculated,previous.id)
        returning id into settlement_id_to_use;
      insert into fieldrush_rating_private.season_zero_active_settlements(game_id,settlement_id) values(state.game_id,settlement_id_to_use)
        on conflict(game_id) do update set settlement_id=excluded.settlement_id;
      changed:=changed+1;
      projection_changed:=true;
    end if;
    update fieldrush_rating_private.season_zero_matches set settlement_status=status_to_use
      where game_id=state.game_id and settlement_status is distinct from status_to_use;
    -- This public ledger is the ACTIVE projection. Every superseded input and
    -- calculation above remains append-only; a held/unrated result has no
    -- active award, rather than a fabricated zero-point rated appearance.
    if not projection_changed then continue; end if;
    if status_to_use<>'RATED' then
      delete from public.player_rating_events where source_type='OPEN_QUEUE' and source_id=state.game_id and calculation_version='field-sr-season0-v2';
      update public.open_queue_bookings set rating_change=null where game_id=state.game_id and rating_change is not null;
    else
      for p in select value from jsonb_array_elements(applied_roster) loop
        result:=calculated->'players'->(p->>'id');
        result_name:=case when state.winner is null then 'DRAW' when state.winner=p->>'team' then 'WIN' else 'LOSS' end;
        insert into public.player_rating_events(profile_id,source_type,source_id,side,result,rating_before,rating_change,rating_after,
          effective_at,rating_at_match_start,team_average_rating,opponent_average_rating,expected_score,actual_score,calculation_version,
          rating_track,played_at,counted_as_played)
        values((p->>'id')::uuid,'OPEN_QUEUE',state.game_id,case p->>'team' when 'A' then 'WHITE' else 'BLACK' end,result_name,
          (p->>'sr_before')::integer,(result->>'delta')::integer,(result->>'sr_after')::integer,state.started_at,(p->>'sr_before')::integer,
          (normalized->'core'->'team_strengths'->>(p->>'team'))::numeric,
          (normalized->'core'->'team_strengths'->>case p->>'team' when 'A' then 'B' else 'A' end)::numeric,
          (result->>'expected')::numeric,(result->>'actual_result')::numeric,'field-sr-season0-v2',p->>'rating_track',state.started_at,(result->>'counted')::boolean)
        on conflict(source_type,source_id,profile_id) do update set
          result=excluded.result,rating_before=excluded.rating_before,rating_change=excluded.rating_change,rating_after=excluded.rating_after,
          rating_at_match_start=excluded.rating_at_match_start,team_average_rating=excluded.team_average_rating,
          opponent_average_rating=excluded.opponent_average_rating,expected_score=excluded.expected_score,actual_score=excluded.actual_score,
          counted_as_played=excluded.counted_as_played
        where player_rating_events.calculation_version='field-sr-season0-v2';
        if not found then raise exception 'A legacy rating award already exists for this policy-pinned match.'; end if;
        update public.open_queue_bookings set rating_change=(result->>'delta')::integer where id=(p->>'booking_id')::uuid
          and rating_change is distinct from (result->>'delta')::integer;
      end loop;
    end if;
  end loop;
  update public.fieldrush_player_rating_tracks r set skill_rating=(s.value->>'sr')::integer,matches_played=(s.value->>'games')::integer,
    wins=(s.value->>'wins')::integer,losses=(s.value->>'losses')::integer,draws=(s.value->>'draws')::integer,last_change=(s.value->>'last_change')::integer
    from jsonb_each(working) s where s.key=r.profile_id::text||':'||r.rating_track
      and row(r.skill_rating,r.matches_played,r.wins,r.losses,r.draws,r.last_change) is distinct from
        row((s.value->>'sr')::integer,(s.value->>'games')::integer,(s.value->>'wins')::integer,
          (s.value->>'losses')::integer,(s.value->>'draws')::integer,(s.value->>'last_change')::integer);
  perform set_config('fieldrush.season_zero_replay',coalesce(prior_replay,''),true);
  return jsonb_build_object('run_id',run_id_to_use,'revised_matches',changed,'settlement_status',
    (select settlement_status from fieldrush_rating_private.season_zero_matches where game_id=requested_game));
end;
$$;

-- The old snapshot trigger remains authoritative for legacy rows. V2 active
-- projections must retain the calculator's counted flag, including corrections.
alter function public.snapshot_fieldrush_rating_event() rename to snapshot_fieldrush_rating_event_before_season_zero;
create function public.snapshot_fieldrush_rating_event()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare b public.open_queue_bookings%rowtype; g public.open_queue_games%rowtype; actual_start timestamptz; original_participant jsonb;
begin
  if new.calculation_version='field-sr-season0-v2' then
    if coalesce(current_setting('fieldrush.season_zero_replay',true),'')<>'on' then raise exception 'Season 0 ledger writes require atomic replay.'; end if;
    select * into g from public.open_queue_games where id=new.source_id and rating_policy_id='field-sr-season0-v2';
    select p into original_participant from fieldrush_rating_private.season_zero_matches s,
      jsonb_array_elements(s.observed_roster) p where s.game_id=g.id and p->>'id'=new.profile_id::text;
    select * into b from public.open_queue_bookings where id=(original_participant->>'booking_id')::uuid and game_id=g.id and profile_id=new.profile_id;
    if g.id is null or b.id is null or new.source_type<>'OPEN_QUEUE'
      or new.rating_track is distinct from original_participant->>'rating_track' then raise exception 'Invalid Season 0 booked rating projection.'; end if;
    if tg_op='UPDATE' and row(new.profile_id,new.source_type,new.source_id,new.rating_track,new.played_at)
      is distinct from row(old.profile_id,old.source_type,old.source_id,old.rating_track,old.played_at) then
      raise exception 'The original rating pool and match identity cannot change.';
    end if;
    new.rating_track:=original_participant->>'rating_track'; new.market_city_id:=g.market_city_id; new.played_timezone:=g.timezone;
    return new;
  end if;
  -- Preserve the installed legacy logic verbatim below via migration patch.
  raise exception 'Legacy snapshot body was not installed.';
end;
$$;
do $migration$
declare current_def text; old_def text; legacy_body text; start_at integer; end_at integer;
begin
  old_def:=pg_get_functiondef('public.snapshot_fieldrush_rating_event_before_season_zero()'::regprocedure);
  start_at:=position(E'begin\n' in old_def)+length(E'begin\n');
  end_at:=position(E'\nend;\n' in old_def);
  if start_at<=length(E'begin\n') or end_at<start_at then raise exception 'Legacy rating snapshot contract changed.'; end if;
  legacy_body:=substring(old_def from start_at for end_at-start_at);
  current_def:=pg_get_functiondef('public.snapshot_fieldrush_rating_event()'::regprocedure);
  current_def:=replace(current_def, E'  raise exception ''Legacy snapshot body was not installed.'';',legacy_body);
  execute current_def;
end;
$migration$;
drop trigger a_snapshot_fieldrush_rating_event on public.player_rating_events;
create trigger a_snapshot_fieldrush_rating_event before insert or update on public.player_rating_events
  for each row execute function public.snapshot_fieldrush_rating_event();

create function public.referee_finish_season_zero_match(actor_referee_id uuid,game_id_to_use uuid,
  request_id_to_use uuid,expected_revision integer)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare state fieldrush_rating_private.season_zero_matches%rowtype; g public.open_queue_games%rowtype;
  prior fieldrush_rating_private.season_zero_action_requests%rowtype; input_to_use jsonb:=jsonb_build_object('action','FINISH');
  elapsed integer; white_score_to_use integer; black_score_to_use integer; response jsonb; normalized jsonb;
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
  elapsed:=fieldrush_rating_private.season_zero_elapsed(game_id_to_use);
  if elapsed<state.scheduled_seconds then raise exception 'Complete the agreed playing duration, or request organizer adjudication.'; end if;
  select count(*) filter(where team='WHITE'),count(*) filter(where team='BLACK') into white_score_to_use,black_score_to_use
    from public.open_queue_goals where game_id=game_id_to_use;
  update fieldrush_rating_private.season_zero_matches set lifecycle='FINAL',rating_status='completed',played_seconds=elapsed,
    winner=case when white_score_to_use>black_score_to_use then 'A' when black_score_to_use>white_score_to_use then 'B' end,
    revision=revision+1,updated_at=clock_timestamp() where game_id=game_id_to_use returning * into state;
  normalized:=fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(game_id_to_use));
  update public.open_queue_clock_states set status='ENDED',started_at=null,accumulated_seconds=elapsed where game_id=game_id_to_use;
  insert into public.open_queue_events(game_id,event_type,minute,second,note) values(game_id_to_use,'MATCH_ENDED',elapsed/60,elapsed%60,'Verified Season 0 full-duration finish.');
  insert into fieldrush_rating_private.season_zero_match_revisions(game_id,revision,actor_id,action,reason,evidence)
    values(game_id_to_use,state.revision,actor_referee_id,'FINISH','Completed agreed duration.',to_jsonb(state));
  perform set_config('fieldrush.season_zero_finalizing',game_id_to_use::text,true);
  update public.open_queue_games set status='FINAL',white_score=white_score_to_use,black_score=black_score_to_use where id=game_id_to_use;
  perform set_config('fieldrush.season_zero_finalizing','',true);
  response:=fieldrush_rating_private.replay_season_zero_ratings(game_id_to_use,actor_referee_id,'Referee confirmed full-duration result.');
  response:=public.get_season_zero_match_state(actor_referee_id,game_id_to_use)||response;
  insert into fieldrush_rating_private.season_zero_action_requests(request_id,game_id,actor_id,input,response)
    values(request_id_to_use,game_id_to_use,actor_referee_id,input_to_use,response);
  return response;
end;
$$;

create function public.admin_resolve_season_zero_match(actor_admin_id uuid,game_id_to_use uuid,
  request_id_to_use uuid,expected_revision integer,resolution_input jsonb)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare state fieldrush_rating_private.season_zero_matches%rowtype; before_state jsonb;
  prior fieldrush_rating_private.season_zero_action_requests%rowtype; input_to_use jsonb;
  status_to_use text:=resolution_input->>'status'; winner_to_use text:=resolution_input->>'winner';
  reason_to_use text:=trim(coalesce(resolution_input->>'reason','')); played integer; corrected_events jsonb;
  white_score_to_use integer; black_score_to_use integer; response jsonb; game_status text;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Active organizer access required.' using errcode='42501'; end if;
  if request_id_to_use is null or jsonb_typeof(resolution_input) is distinct from 'object'
    or exists(select 1 from jsonb_object_keys(resolution_input) k where k not in ('status','winner','reason','played_seconds','events','white_score','black_score')) then
    raise exception 'Provide a valid adjudication or correction request.';
  end if;
  if status_to_use is null or status_to_use not in ('completed','forfeit_confirmed','no_contest','cancelled','unranked','pending_review')
    or char_length(reason_to_use)<10 then raise exception 'Choose a resolution and explain it in at least ten characters.'; end if;
  if winner_to_use is not null and winner_to_use not in ('A','B') then raise exception 'Winner must be A, B, or null.'; end if;
  if status_to_use='forfeit_confirmed' and winner_to_use is null then raise exception 'A confirmed conduct forfeit requires its actual winning side.'; end if;
  input_to_use:=jsonb_build_object('action','ADJUDICATE','resolution',resolution_input);
  perform fieldrush_rating_private.lock_season_zero_sr();
  select * into prior from fieldrush_rating_private.season_zero_action_requests where request_id=request_id_to_use;
  if found then
    if row(prior.game_id,prior.actor_id,prior.input) is distinct from row(game_id_to_use,actor_admin_id,input_to_use) then raise exception 'This request ID belongs to another action.'; end if;
    return prior.response;
  end if;
  perform 1 from public.open_queue_games where id=game_id_to_use and rating_policy_id='field-sr-season0-v2' for update;
  if not found then raise exception 'Only a prospectively pinned Season 0 game can use this correction.'; end if;
  select * into state from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_use for update;
  if not found then raise exception 'The match never started; cancel it through the ordinary organizer workflow.'; end if;
  select status into game_status from public.open_queue_games where id=game_id_to_use;
  if status_to_use='cancelled' and game_status in ('FINAL','CANCELLED') then
    raise exception 'Final or already-cancelled matches cannot be cancelled again. Use a rating-only correction and the existing payment review workflow.';
  end if;
  if game_status='CANCELLED' and status_to_use<>'cancelled' then
    raise exception 'A financially cancelled match cannot be reopened through a rating-only correction.';
  end if;
  if state.revision is distinct from expected_revision then raise exception 'Refresh the changed match before adjudicating.' using errcode='40001'; end if;
  before_state:=to_jsonb(state);
  played:=case when resolution_input ? 'played_seconds' then fieldrush_rating_private.season_zero_sr_integer(resolution_input->'played_seconds','played_seconds',0)
    when state.lifecycle='LIVE' then fieldrush_rating_private.season_zero_elapsed(game_id_to_use) else state.played_seconds end;
  corrected_events:=case when resolution_input ? 'events' then resolution_input->'events' else state.events end;
  if jsonb_typeof(corrected_events) is distinct from 'array' then raise exception 'Corrected timeline must be an array.'; end if;
  -- Scores are explicit recorded corrections, never fabricated forfeit goals.
  select white_score,black_score into white_score_to_use,black_score_to_use from public.open_queue_games where id=game_id_to_use;
  if resolution_input ? 'white_score' then white_score_to_use:=fieldrush_rating_private.season_zero_sr_integer(resolution_input->'white_score','white_score',0); end if;
  if resolution_input ? 'black_score' then black_score_to_use:=fieldrush_rating_private.season_zero_sr_integer(resolution_input->'black_score','black_score',0); end if;
  if status_to_use='completed' then
    if white_score_to_use is null or black_score_to_use is null then raise exception 'A completed result requires the recorded score.'; end if;
    if winner_to_use is distinct from (case when white_score_to_use>black_score_to_use then 'A' when black_score_to_use>white_score_to_use then 'B' end) then
      raise exception 'The completed winner must match the recorded score.';
    end if;
  end if;
  update fieldrush_rating_private.season_zero_matches set lifecycle=case when status_to_use='pending_review' then 'REVIEW' else 'FINAL' end,
    rating_status=status_to_use,winner=winner_to_use,played_seconds=played,events=corrected_events,
    adjudicated_by=actor_admin_id,adjudication_reason=reason_to_use,revision=revision+1,updated_at=clock_timestamp()
    where game_id=game_id_to_use returning * into state;
  perform fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(game_id_to_use));
  update public.open_queue_clock_states set status='ENDED',started_at=null,accumulated_seconds=played where game_id=game_id_to_use;
  insert into fieldrush_rating_private.season_zero_match_revisions(game_id,revision,actor_id,action,reason,evidence)
    values(game_id_to_use,state.revision,actor_admin_id,'ADJUDICATE_OR_CORRECT',reason_to_use,jsonb_build_object('before',before_state,'after',to_jsonb(state)));
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_admin_id,'SEASON_ZERO_MATCH_CORRECTION','SOLO_MATCH',game_id_to_use,reason_to_use,before_state,to_jsonb(state));
  if status_to_use<>'pending_review' then
    perform set_config('fieldrush.season_zero_finalizing',game_id_to_use::text,true);
    if status_to_use='cancelled' then
      -- Reuse the established refund/deposit/cancellation policy verbatim.
      -- It is deliberately not available for an already-FINAL result.
      perform public.admin_cancel_match(actor_admin_id,'SOLO',game_id_to_use,'ADMIN_DECISION',reason_to_use);
      update public.open_queue_games set operational_state='RESOLVED',operational_state_updated_at=clock_timestamp(),
        operational_reason_code=null where id=game_id_to_use;
    else
      update public.open_queue_games set status='FINAL',white_score=coalesce(white_score_to_use,0),black_score=coalesce(black_score_to_use,0),
        operational_state='RESOLVED',operational_state_updated_at=clock_timestamp(),operational_reason_code=null where id=game_id_to_use;
    end if;
    perform set_config('fieldrush.season_zero_finalizing','',true);
  else
    update public.open_queue_games set operational_state='UNDER_REVIEW',operational_state_updated_at=clock_timestamp(),
      operational_reason_code='SEASON_ZERO_REVIEW' where id=game_id_to_use;
  end if;
  response:=fieldrush_rating_private.replay_season_zero_ratings(game_id_to_use,actor_admin_id,reason_to_use);
  response:=public.get_season_zero_match_state(actor_admin_id,game_id_to_use)||response;
  insert into fieldrush_rating_private.season_zero_action_requests(request_id,game_id,actor_id,input,response)
    values(request_id_to_use,game_id_to_use,actor_admin_id,input_to_use,response);
  return response;
end;
$$;

-- Install dispatch/writer wrappers below after all private functions exist.
-- Separate the existing financial injury logic from its superseded SR loop.
-- Guard the source markers so an unrelated future change fails the migration
-- instead of silently removing attendance or refund safeguards.
do $migration$
declare d text; body_start integer; terms_start integer; loop_start integer; loop_end integer; protection_start integer; return_start integer;
begin
  d:=pg_get_functiondef('public.apply_open_queue_reliability_rating_adjustments(uuid)'::regprocedure);
  d:=replace(d,'public.apply_open_queue_reliability_rating_adjustments(', 'fieldrush_rating_private.apply_season_zero_financial_effects(');
  body_start:=position(E'begin\n' in d)+length(E'begin\n');
  terms_start:=position('  terms_to_use := public.ensure_match_reliability_terms(' in d);
  loop_start:=position('  for event_to_adjust in' in d);
  if body_start<=length(E'begin\n') or terms_start<=body_start or loop_start<=terms_start then
    raise exception 'Legacy reliability financial extraction contract changed.';
  end if;
  d:=substring(d from 1 for body_start-1)||$new$
  select * into game_to_apply from public.open_queue_games where id=game_id_to_apply for update;
  if game_to_apply.id is null or game_to_apply.rating_policy_id<>'field-sr-season0-v2' or game_to_apply.status<>'FINAL' then
    raise exception 'Financial effects require a final Season 0 match.';
  end if;
  if not exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_apply
    and lifecycle='FINAL' and rating_status in ('completed','forfeit_confirmed')) then
    return 0; -- Rating-only void/unranked decisions never implicitly settle fees.
  end if;
$new$||substring(d from terms_start);
  loop_start:=position('  for event_to_adjust in' in d);
  loop_end:=loop_start-1+position(E'  end loop;\n' in substring(d from loop_start))+length(E'  end loop;\n');
  if loop_end<=loop_start then raise exception 'Legacy SR loop boundary changed.'; end if;
  d:=substring(d from 1 for loop_start-1)||substring(d from loop_end);
  protection_start:=position(E'  if (\n    injury_affects_result' in d);
  return_start:=position('  return adjusted_count;' in d);
  if protection_start=0 or return_start<=protection_start then raise exception 'Legacy protection notification contract changed.'; end if;
  d:=substring(d from 1 for protection_start-1)||substring(d from return_start);
  execute d;
end;
$migration$;

alter function public.apply_open_queue_player_ratings(uuid) rename to apply_open_queue_player_ratings_before_season_zero;
create function public.apply_open_queue_player_ratings(game_id_to_apply uuid)
returns integer language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result integer; previous_context text;
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  if exists(select 1 from public.open_queue_games where id=game_id_to_apply and rating_policy_id='field-sr-season0-v2') then
    raise exception 'Use the authenticated Season 0 finish/adjudication workflow.';
  end if;
  previous_context:=current_setting('fieldrush.season_zero_legacy_context',true);
  perform set_config('fieldrush.season_zero_legacy_context',jsonb_build_object('game_id',game_id_to_apply,'action','LEGACY_MATCH_AWARD')::text,true);
  result:=public.apply_open_queue_player_ratings_before_season_zero(game_id_to_apply);
  perform set_config('fieldrush.season_zero_legacy_context',coalesce(previous_context,''),true);
  return result;
end;
$$;
alter function public.apply_open_queue_reliability_rating_adjustments(uuid) rename to apply_open_queue_reliability_rating_adjustments_before_season_zero;
create function public.apply_open_queue_reliability_rating_adjustments(game_id_to_apply uuid)
returns integer language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result integer; previous_context text;
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  if exists(select 1 from public.open_queue_games where id=game_id_to_apply and rating_policy_id='field-sr-season0-v2') then
    return fieldrush_rating_private.apply_season_zero_financial_effects(game_id_to_apply);
  end if;
  previous_context:=current_setting('fieldrush.season_zero_legacy_context',true);
  perform set_config('fieldrush.season_zero_legacy_context',jsonb_build_object('game_id',game_id_to_apply,'action','LEGACY_RELIABILITY_ADJUSTMENT')::text,true);
  result:=public.apply_open_queue_reliability_rating_adjustments_before_season_zero(game_id_to_apply);
  perform set_config('fieldrush.season_zero_legacy_context',coalesce(previous_context,''),true);
  if exists(select 1 from fieldrush_rating_private.season_zero_rating_baselines) then
    perform fieldrush_rating_private.replay_season_zero_ratings(null,null,'Preserve fixed legacy rating movements after attendance settlement.');
  end if;
  return result;
end;
$$;

-- Preserve the old trigger's complete legacy branch, including audited test
-- cutoff behavior. No such shortcut is admitted for the new policy branch.
do $migration$
declare d text; legacy_overlay text := $old$    if policy_id_to_use is not null then
      perform public.apply_open_queue_reliability_rating_adjustments(new.id);
    end if;$old$;
begin
  d:=pg_get_functiondef('public.apply_open_queue_player_ratings_on_final()'::regprocedure);
  if position(E'begin\n' in d)=0 then raise exception 'Final-result trigger contract changed.'; end if;
  if position(legacy_overlay in d)=0 then raise exception 'Legacy attendance-settlement dispatch changed.'; end if;
  -- Old games predating the reliability policy have no overlay callback. They
  -- still advance later v2 inputs using their fixed award, exactly once after
  -- their complete legacy settlement (never between base and overlay writes).
  d:=replace(d,legacy_overlay,$new$    if policy_id_to_use is not null then
      perform public.apply_open_queue_reliability_rating_adjustments(new.id);
    elsif exists(select 1 from fieldrush_rating_private.season_zero_rating_baselines) then
      perform fieldrush_rating_private.replay_season_zero_ratings(null,null,'Preserve fixed pre-reliability legacy award after finalization.');
    end if;$new$);
  d:=replace(d,E'begin\n',$new$begin
  if new.rating_policy_id='field-sr-season0-v2' then
    if new.status='FINAL' and old.status is distinct from 'FINAL' then
      if nullif(current_setting('fieldrush.season_zero_finalizing',true),'') is distinct from new.id::text then
        raise exception 'Season 0 finalization requires verified evidence and atomic settlement.';
      end if;
      if exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=new.id
        and rating_status in ('completed','forfeit_confirmed')) then
        perform public.ensure_match_attendance_records('SOLO',new.id);
        perform public.finalize_match_attendance_internal('SOLO',new.id,null);
        perform fieldrush_rating_private.apply_season_zero_financial_effects(new.id);
      end if;
    end if;
    return new;
  end if;
$new$);
  execute d;
end;
$migration$;

create function fieldrush_rating_private.guard_season_zero_final_result()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  if new.rating_policy_id='field-sr-season0-v2'
    and (new.status='FINAL' or old.status='FINAL')
    and row(new.status,new.white_score,new.black_score) is distinct from row(old.status,old.white_score,old.black_score)
    and nullif(current_setting('fieldrush.season_zero_finalizing',true),'') is distinct from new.id::text then
    raise exception 'Use the audited Season 0 finish or correction workflow.';
  end if;
  return new;
end;
$$;
create trigger guard_season_zero_final_result before update of status,white_score,black_score on public.open_queue_games
  for each row execute function fieldrush_rating_private.guard_season_zero_final_result();

-- The pre-existing immutability trigger still protects schedule/team snapshots.
-- Permit only the score/status part of the new audited correction transaction.
do $migration$
declare d text;
begin
  d:=pg_get_functiondef('public.protect_rated_open_queue_game_inputs()'::regprocedure);
  if position(E'begin\n' in d)=0 then raise exception 'Rated-game immutability guard contract changed.'; end if;
  d:=replace(d,E'begin\n',$new$begin
  if tg_op='UPDATE' and new.rating_policy_id='field-sr-season0-v2'
    and nullif(current_setting('fieldrush.season_zero_finalizing',true),'')=new.id::text
    and (to_jsonb(new)-array['status','white_score','black_score','operational_state','operational_state_updated_at','operational_reason_code','updated_at'])
      is not distinct from (to_jsonb(old)-array['status','white_score','black_score','operational_state','operational_state_updated_at','operational_reason_code','updated_at']) then
    return new;
  end if;
$new$);
  execute d;
end;
$migration$;

alter function public.preserve_player_sr_for_resolution_score(text,uuid,integer,integer) rename to preserve_player_sr_for_resolution_score_before_season_zero;
create function public.preserve_player_sr_for_resolution_score(match_kind_to_use text,match_id_to_use uuid,home_score_to_use integer,away_score_to_use integer)
returns integer language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result integer; previous_context text;
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  if upper(match_kind_to_use)='SOLO' and exists(select 1 from public.open_queue_games where id=match_id_to_use and rating_policy_id='field-sr-season0-v2') then
    raise exception 'Season 0 corrections must replay dependent ratings.';
  end if;
  previous_context:=current_setting('fieldrush.season_zero_legacy_context',true);
  perform set_config('fieldrush.season_zero_legacy_context',jsonb_build_object('game_id',case when upper(match_kind_to_use)='SOLO' then match_id_to_use end,
    'action','LEGACY_RESULT_STATS_CORRECTION','match_id',match_id_to_use,'match_kind',match_kind_to_use)::text,true);
  result:=public.preserve_player_sr_for_resolution_score_before_season_zero(match_kind_to_use,match_id_to_use,home_score_to_use,away_score_to_use);
  perform set_config('fieldrush.season_zero_legacy_context',coalesce(previous_context,''),true);
  if exists(select 1 from fieldrush_rating_private.season_zero_rating_baselines) then
    perform fieldrush_rating_private.replay_season_zero_ratings(null,null,'Preserve audited legacy result-stat correction.');
  end if;
  return result;
end;
$$;
alter function public.admin_override_match_score(uuid,text,uuid,integer,integer,text) rename to admin_override_match_score_before_season_zero;
create function public.admin_override_match_score(actor_admin_id uuid,match_kind_to_use text,match_id_to_update uuid,home_score_to_use integer,away_score_to_use integer,reason_to_use text)
returns uuid language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result uuid; previous_context text;
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  if upper(match_kind_to_use)='SOLO' and exists(select 1 from public.open_queue_games where id=match_id_to_update and rating_policy_id='field-sr-season0-v2') then
    raise exception 'Use the Season 0 organizer correction workflow.';
  end if;
  previous_context:=current_setting('fieldrush.season_zero_legacy_context',true);
  perform set_config('fieldrush.season_zero_legacy_context',jsonb_build_object('game_id',case when upper(match_kind_to_use)='SOLO' then match_id_to_update end,
    'action','LEGACY_ADMIN_SCORE_CORRECTION','actor_id',actor_admin_id,'reason',reason_to_use)::text,true);
  result:=public.admin_override_match_score_before_season_zero(actor_admin_id,match_kind_to_use,match_id_to_update,home_score_to_use,away_score_to_use,reason_to_use);
  perform set_config('fieldrush.season_zero_legacy_context',coalesce(previous_context,''),true);
  if exists(select 1 from fieldrush_rating_private.season_zero_rating_baselines) then
    perform fieldrush_rating_private.replay_season_zero_ratings(null,actor_admin_id,'Preserve audited legacy score correction.');
  end if;
  return result;
end;
$$;
alter function public.apply_late_appeal_sr_correction(uuid,uuid,uuid) rename to apply_late_appeal_sr_correction_before_season_zero;
create function public.apply_late_appeal_sr_correction(actor_admin_id uuid,appeal_id_to_correct uuid,attendance_id_to_correct uuid)
returns uuid language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result uuid; previous_context text; game_id_to_use uuid;
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  select open_queue_game_id into game_id_to_use from public.match_attendance_records where id=attendance_id_to_correct and match_kind='SOLO';
  if exists(select 1 from public.open_queue_games where id=game_id_to_use and rating_policy_id='field-sr-season0-v2') then
    -- Attendance appeals still apply through their existing service; there is
    -- no lateness SR multiplier to undo in this policy.
    return null;
  end if;
  previous_context:=current_setting('fieldrush.season_zero_legacy_context',true);
  perform set_config('fieldrush.season_zero_legacy_context',jsonb_build_object('game_id',game_id_to_use,
    'action','LEGACY_ATTENDANCE_APPEAL','actor_id',actor_admin_id,'appeal_id',appeal_id_to_correct)::text,true);
  result:=public.apply_late_appeal_sr_correction_before_season_zero(actor_admin_id,appeal_id_to_correct,attendance_id_to_correct);
  perform set_config('fieldrush.season_zero_legacy_context',coalesce(previous_context,''),true);
  if exists(select 1 from fieldrush_rating_private.season_zero_rating_baselines) then
    perform fieldrush_rating_private.replay_season_zero_ratings(null,actor_admin_id,'Preserve fixed audited legacy attendance appeal.');
  end if;
  return result;
end;
$$;
alter function public.reset_player_rankings(uuid,text) rename to reset_player_rankings_before_season_zero;
create function public.reset_player_rankings(request_id_to_use uuid,reason_to_use text)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  perform fieldrush_rating_private.lock_season_zero_sr();
  if exists(select 1 from fieldrush_rating_private.season_zero_rating_baselines)
    or exists(select 1 from public.fieldrush_player_rating_tracks where rating_initialized_at is not null) then
    raise exception 'Lifetime Season 0 skill/counts cannot be reset. A new rating pool requires a separately authorized migration.';
  end if;
  return public.reset_player_rankings_before_season_zero(request_id_to_use,reason_to_use);
end;
$$;

revoke all on function fieldrush_rating_private.protect_season_zero_append_only(),fieldrush_rating_private.capture_season_zero_baselines(),
  fieldrush_rating_private.season_zero_track_rating_at(uuid,text,date),
  fieldrush_rating_private.capture_legacy_rating_movement(),fieldrush_rating_private.replay_season_zero_ratings(uuid,uuid,text),
  fieldrush_rating_private.apply_season_zero_financial_effects(uuid),fieldrush_rating_private.guard_season_zero_final_result(),
  public.snapshot_fieldrush_rating_event_before_season_zero(),public.snapshot_fieldrush_rating_event(),
  public.apply_open_queue_player_ratings_before_season_zero(uuid),public.apply_open_queue_reliability_rating_adjustments_before_season_zero(uuid),
  public.preserve_player_sr_for_resolution_score_before_season_zero(text,uuid,integer,integer),
  public.admin_override_match_score_before_season_zero(uuid,text,uuid,integer,integer,text),
  public.apply_late_appeal_sr_correction_before_season_zero(uuid,uuid,uuid),public.reset_player_rankings_before_season_zero(uuid,text)
  from public,anon,authenticated,service_role;
revoke all on function public.referee_finish_season_zero_match(uuid,uuid,uuid,integer),
  public.admin_resolve_season_zero_match(uuid,uuid,uuid,integer,jsonb),public.apply_open_queue_player_ratings(uuid),
  public.apply_open_queue_reliability_rating_adjustments(uuid),public.preserve_player_sr_for_resolution_score(text,uuid,integer,integer),
  public.admin_override_match_score(uuid,text,uuid,integer,integer,text),public.apply_late_appeal_sr_correction(uuid,uuid,uuid),public.reset_player_rankings(uuid,text)
  from public,anon,authenticated;
grant execute on function public.referee_finish_season_zero_match(uuid,uuid,uuid,integer),
  public.admin_resolve_season_zero_match(uuid,uuid,uuid,integer,jsonb),public.apply_open_queue_player_ratings(uuid),
  public.apply_open_queue_reliability_rating_adjustments(uuid),public.preserve_player_sr_for_resolution_score(text,uuid,integer,integer),
  public.admin_override_match_score(uuid,text,uuid,integer,integer,text),public.apply_late_appeal_sr_correction(uuid,uuid,uuid),public.reset_player_rankings(uuid,text)
  to service_role;
notify pgrst,'reload schema';
