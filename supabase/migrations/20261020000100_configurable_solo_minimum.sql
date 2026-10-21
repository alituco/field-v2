-- New games can advertise a total-player minimum. Existing games, schedules
-- and kickoff evidence retain the original five-per-side rating rules.
alter table public.open_queue_games
  add column minimum_players integer not null default 10 check(minimum_players between 2 and capacity),
  add column participation_rules_version text not null default 's0-standard-v1'
    check(participation_rules_version in ('s0-standard-v1','s0-configurable-v1'));
alter table public.open_queue_games alter column participation_rules_version set default 's0-configurable-v1';
grant select(minimum_players,participation_rules_version) on public.open_queue_games to authenticated;
alter table public.game_schedules
  add column minimum_players integer not null default 10 check(minimum_players between 2 and 14),
  add column participation_rules_version text not null default 's0-standard-v1'
    check(participation_rules_version in ('s0-standard-v1','s0-configurable-v1'));
alter table public.game_schedules alter column participation_rules_version set default 's0-configurable-v1';
alter table fieldrush_rating_private.season_zero_matches
  add column minimum_players integer not null default 10 check(minimum_players between 2 and 14),
  add column participation_rules_version text not null default 's0-standard-v1'
    check(participation_rules_version in ('s0-standard-v1','s0-configurable-v1'));

create function fieldrush_rating_private.protect_solo_minimum()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' then
    if new.rating_policy_id<>'field-sr-season0-v2' then new.participation_rules_version:='s0-standard-v1'; end if;
  else
    if new.participation_rules_version is distinct from old.participation_rules_version then
      raise exception 'The advertised participation rules cannot change. Create a new game.';
    end if;
    if new.minimum_players is distinct from old.minimum_players and (
      old.participation_rules_version<>'s0-configurable-v1' or old.status<>'OPEN' or new.status<>'OPEN'
      or old.operational_state<>'NORMAL' or new.operational_state<>'NORMAL'
      or old.starts_at<=clock_timestamp() or new.starts_at<=clock_timestamp()
      or old.teams_assigned_at is not null or new.teams_assigned_at is not null
      or exists(select 1 from public.open_queue_bookings where game_id=old.id)
      or exists(select 1 from public.payment_intents where payload->>'game_id'=old.id::text)
      or exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=old.id)
      or exists(select 1 from public.open_queue_clock_states where game_id=old.id
        and (status<>'NOT_STARTED' or started_at is not null or accumulated_seconds<>0))
    ) then raise exception 'The minimum is locked after booking, checkout or match activity. Create a new game.'; end if;
  end if;
  return new;
end $$;
create trigger zz_protect_solo_minimum before insert or update on public.open_queue_games
  for each row execute function fieldrush_rating_private.protect_solo_minimum();

create function public.admin_create_open_queue_game_with_minimum(
  actor_admin_id uuid,field_id_to_use uuid,starts_at_to_use timestamptz,price_fils_to_use integer,
  age_label_to_use text,duration_minutes_to_use integer,highest_division_to_use integer,lowest_division_to_use integer,
  goalkeepers_per_side_to_use integer,defenders_per_side_to_use integer,attackers_per_side_to_use integer,
  minimum_players_to_use integer
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare game uuid; before_game jsonb; saved public.open_queue_games%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if minimum_players_to_use is null or minimum_players_to_use not between 2 and 14 then
    raise exception 'Minimum players must be a whole number from 2 to 14.' using errcode='22023'; end if;
  game:=public.admin_create_open_queue_game(actor_admin_id,field_id_to_use,starts_at_to_use,price_fils_to_use,
    age_label_to_use,duration_minutes_to_use,highest_division_to_use,lowest_division_to_use,
    goalkeepers_per_side_to_use,defenders_per_side_to_use,attackers_per_side_to_use);
  select to_jsonb(g) into before_game from public.open_queue_games g where id=game;
  if (before_game->>'rating_policy_id')<>'field-sr-season0-v2' then
    raise exception 'Enable the Season 0 rating policy before creating a configurable-minimum game.'; end if;
  update public.open_queue_games set minimum_players=minimum_players_to_use where id=game returning * into saved;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_admin_id,'SOLO_GAME_MINIMUM_SET','SOLO_MATCH',game,
      'Administrator set the advertised total-player minimum during creation.',before_game,to_jsonb(saved));
  return game;
end $$;
revoke all on function public.admin_create_open_queue_game_with_minimum(uuid,uuid,timestamptz,integer,text,integer,integer,integer,integer,integer,integer,integer) from public,anon,authenticated;
grant execute on function public.admin_create_open_queue_game_with_minimum(uuid,uuid,timestamptz,integer,text,integer,integer,integer,integer,integer,integer,integer) to service_role;

create function fieldrush_rating_private.season_zero_headcount_ready(version text,minimum integer,a integer,b integer)
returns boolean language sql immutable set search_path=pg_catalog as $$
  select coalesce(a between 1 and 7 and b between 1 and 7 and case version
    when 's0-configurable-v1' then minimum between 2 and 14 and a+b>=minimum
    when 's0-standard-v1' then a>=5 and b>=5 else false end,false);
$$;

-- Clone the exact installed standard implementations. Historical replay uses
-- these unchanged functions; only explicitly versioned inputs use the extension.
do $migration$
declare d text; anchor text;
begin
  d:=pg_get_functiondef('fieldrush_rating_private.calculate_season_zero_sr(jsonb)'::regprocedure);
  execute replace(d,'FUNCTION fieldrush_rating_private.calculate_season_zero_sr(',
    'FUNCTION fieldrush_rating_private.calculate_season_zero_sr_standard(');
  d:=replace(d,'FUNCTION fieldrush_rating_private.calculate_season_zero_sr(',
    'FUNCTION fieldrush_rating_private.calculate_season_zero_sr_configurable(');
  anchor:='if manpower < -2 or manpower > 2 then';
  if position(anchor in d)=0 then raise exception 'Standard manpower validation changed.'; end if;
  d:=replace(d,anchor,'if manpower < -6 or manpower > 6 then');
  d:=replace(d,'Normalized manpower must respect the 5-to-7 format','Normalized manpower must respect the one-to-seven format');
  execute d;

  d:=pg_get_functiondef('fieldrush_rating_private.season_zero_sr_interval(jsonb,integer,integer,boolean)'::regprocedure);
  d:=replace(d,'FUNCTION fieldrush_rating_private.season_zero_sr_interval(states jsonb, starts integer, ends integer, running boolean)',
    'FUNCTION fieldrush_rating_private.season_zero_sr_interval_configurable(states jsonb, starts integer, ends integer, running boolean, minimum integer)');
  if position('interval_configurable(' in d)=0 then raise exception 'Interval signature changed.'; end if;
  anchor:='if actual_a not between 5 and 7 or actual_b not between 5 and 7';
  if position(anchor in d)=0 then raise exception 'Standard active-player interval validation changed.'; end if;
  d:=replace(d,anchor,'if not fieldrush_rating_private.season_zero_headcount_ready(''s0-configurable-v1'',minimum,actual_a,actual_b)');
  d:=replace(d,'Running play requires five to seven actual players per side','Running play requires the saved total minimum and one to seven actual players per side');
  execute d;

  d:=pg_get_functiondef('fieldrush_rating_private.normalize_season_zero_sr(jsonb)'::regprocedure);
  execute replace(d,'FUNCTION fieldrush_rating_private.normalize_season_zero_sr(',
    'FUNCTION fieldrush_rating_private.normalize_season_zero_sr_standard(');
  d:=replace(d,'FUNCTION fieldrush_rating_private.normalize_season_zero_sr(',
    'FUNCTION fieldrush_rating_private.normalize_season_zero_sr_configurable(');
  anchor:='fieldrush_rating_private.season_zero_sr_interval(states, cursor_second, event_second, running)';
  if position(anchor in d)=0 then raise exception 'Standard interval invocation changed.'; end if;
  d:=replace(d,anchor,'fieldrush_rating_private.season_zero_sr_interval_configurable(states, cursor_second, event_second, running, (data->>''minimum_players'')::integer)');
  anchor:='''policy_id'', data->''policy_id'', ''status'', data->''status'', ''winner'', data->''winner'',';
  if position(anchor in d)=0 then raise exception 'Normalized core snapshot changed.'; end if;
  d:=replace(d,anchor,anchor||E'\n    ''participation_rules_version'',data->''participation_rules_version'',''minimum_players'',data->''minimum_players'',');
  execute d;
end $migration$;

create or replace function fieldrush_rating_private.calculate_season_zero_sr(data jsonb)
returns jsonb language plpgsql immutable parallel safe set search_path=pg_catalog as $$
declare version text:=coalesce(data->>'participation_rules_version','s0-standard-v1'); minimum integer;
begin
  if data ? 'participation_rules_version' and jsonb_typeof(data->'participation_rules_version') is distinct from 'string' then
    raise exception 'Participation rules version must be text' using errcode='22023'; end if;
  if version='s0-standard-v1' then return fieldrush_rating_private.calculate_season_zero_sr_standard(data); end if;
  if version<>'s0-configurable-v1' then raise exception 'Unknown participation rules version' using errcode='22023'; end if;
  minimum:=fieldrush_rating_private.season_zero_sr_integer(data->'minimum_players','minimum_players',2);
  if minimum>14 then raise exception 'Minimum players cannot exceed 14' using errcode='22023'; end if;
  return fieldrush_rating_private.calculate_season_zero_sr_configurable(data);
end $$;
create or replace function fieldrush_rating_private.normalize_season_zero_sr(data jsonb)
returns jsonb language plpgsql immutable parallel safe set search_path=pg_catalog as $$
declare version text:=coalesce(data->>'participation_rules_version','s0-standard-v1'); minimum integer;
begin
  if data ? 'participation_rules_version' and jsonb_typeof(data->'participation_rules_version') is distinct from 'string' then
    raise exception 'Participation rules version must be text' using errcode='22023'; end if;
  if version='s0-standard-v1' then return fieldrush_rating_private.normalize_season_zero_sr_standard(data); end if;
  if version<>'s0-configurable-v1' then raise exception 'Unknown participation rules version' using errcode='22023'; end if;
  minimum:=fieldrush_rating_private.season_zero_sr_integer(data->'minimum_players','minimum_players',2);
  if minimum>14 then raise exception 'Minimum players cannot exceed 14' using errcode='22023'; end if;
  return fieldrush_rating_private.normalize_season_zero_sr_configurable(data);
end $$;

-- All operational checks use either the advertised game rules or the immutable
-- kickoff snapshot. Pauses never turn an otherwise valid match into unranked.
do $migration$
declare d text; anchor text;
begin
  d:=pg_get_functiondef('fieldrush_rating_private.season_zero_input(uuid,integer)'::regprocedure);
  anchor:='''roster'',observed_roster,''events'',events)';
  if position(anchor in d)=0 then raise exception 'Match input snapshot changed.'; end if;
  execute replace(d,anchor,'''roster'',observed_roster,''events'',events) || case when participation_rules_version=''s0-configurable-v1'' then jsonb_build_object(''participation_rules_version'',participation_rules_version,''minimum_players'',minimum_players) else ''{}''::jsonb end');
  d:=pg_get_functiondef('fieldrush_rating_private.protect_season_zero_kickoff_snapshot()'::regprocedure);
  anchor:='row(new.game_id,new.policy_id,new.started_at,new.scheduled_seconds,new.observed_roster)';
  if position(anchor in d)=0 then raise exception 'Kickoff snapshot protection changed.'; end if;
  d:=replace(d,anchor,'row(new.game_id,new.policy_id,new.started_at,new.scheduled_seconds,new.observed_roster,new.participation_rules_version,new.minimum_players)');
  d:=replace(d,'row(old.game_id,old.policy_id,old.started_at,old.scheduled_seconds,old.observed_roster)',
    'row(old.game_id,old.policy_id,old.started_at,old.scheduled_seconds,old.observed_roster,old.participation_rules_version,old.minimum_players)');
  execute d;
  d:=pg_get_functiondef('public.referee_season_zero_action(uuid,uuid,uuid,integer,jsonb)'::regprocedure);
  anchor:='season_zero_matches(game_id,started_at,scheduled_seconds,observed_roster)';
  if position(anchor in d)=0 then raise exception 'START snapshot insertion changed.'; end if;
  d:=replace(d,anchor,'season_zero_matches(game_id,started_at,scheduled_seconds,observed_roster,participation_rules_version,minimum_players)');
  anchor:='values(g.id,recorded,extract(epoch from(g.ends_at-g.starts_at))::integer,coalesce(roster,''[]''))';
  if position(anchor in d)=0 then raise exception 'START snapshot values changed.'; end if;
  d:=replace(d,anchor,'values(g.id,recorded,extract(epoch from(g.ends_at-g.starts_at))::integer,coalesce(roster,''[]''),g.participation_rules_version,g.minimum_players)');
  d:=replace(d,'if active_a<5 or active_b<5 then raise exception ''At least five actual players per team are required to start.''; end if;',
    'if not fieldrush_rating_private.season_zero_headcount_ready(g.participation_rules_version,g.minimum_players,active_a,active_b) then raise exception ''%'',case when g.participation_rules_version=''s0-standard-v1'' then ''At least five actual players per team are required to start.'' else ''The saved minimum and at least one actual player per side are required to start.'' end; end if;');
  anchor:='if action_name=''RESUME'' and (active_a<5 or active_b<5)';
  if position(anchor in d)=0 then raise exception 'RESUME active-player guard changed.'; end if;
  d:=replace(d,anchor,'if action_name=''RESUME'' and not fieldrush_rating_private.season_zero_headcount_ready(state.participation_rules_version,state.minimum_players,active_a,active_b)');
  d:=replace(d,'raise exception ''At least five players per team must be back before resuming.'';',
    'raise exception ''%'',case when state.participation_rules_version=''s0-standard-v1'' then ''At least five players per team must be back before resuming.'' else ''The saved minimum and at least one player per side must be back before resuming.'' end;');
  d:=replace(d,'clock_status=''RUNNING'' and (active_a<5 or active_b<5)',
    'clock_status=''RUNNING'' and not fieldrush_rating_private.season_zero_headcount_ready(state.participation_rules_version,state.minimum_players,active_a,active_b)');
  d:=replace(d,'Automatic stop: fewer than five actual players on a side.','Automatic stop: active players are below the saved minimum or a side is empty.');
  execute d;

  d:=pg_get_functiondef('fieldrush_rating_private.season_zero_white_assignment(uuid)'::regprocedure);
  anchor:='where side.n between 5 and 7 and t.n-side.n between 5 and 7';
  if position(anchor in d)=0 then raise exception 'Assignment headcount guard changed.'; end if;
  execute replace(d,anchor,'where fieldrush_rating_private.season_zero_headcount_ready(g.participation_rules_version,g.minimum_players,side.n::integer,(t.n-side.n)::integer)');
  d:=pg_get_functiondef('public.referee_assign_season_zero_teams(uuid,uuid,uuid)'::regprocedure);
  anchor:='if booked not between 10 and 14 or exists';
  if position(anchor in d)=0 then raise exception 'Assignment booking count changed.'; end if;
  d:=replace(d,anchor,'if booked<(case when g.participation_rules_version=''s0-configurable-v1'' then g.minimum_players else 10 end) or booked>14 or exists');
  d:=replace(d,'raise exception ''Assignment needs ten to fourteen booked players with valid rating tracks.''',
    'raise exception ''%'',case when g.participation_rules_version=''s0-standard-v1'' then ''Assignment needs ten to fourteen booked players with valid rating tracks.'' else ''Assignment needs the saved minimum of booked players, no more than fourteen, and valid rating tracks.'' end');
  d:=replace(d,'raise exception ''The booked roles and accepted parties cannot form two sides of five to seven without moving an assigned player. Use consented rebalance.''',
    'raise exception ''%'',case when g.participation_rules_version=''s0-standard-v1'' then ''The booked roles and accepted parties cannot form two sides of five to seven without moving an assigned player. Use consented rebalance.'' else ''The booked roles and accepted parties cannot form two valid sides meeting the saved minimum without moving an assigned player. Use consented rebalance.'' end');
  execute d;
  d:=pg_get_functiondef('public.referee_rebalance_season_zero_match(uuid,uuid,uuid,jsonb,text)'::regprocedure);
  anchor:='if total_booked not between 10 and 14 or exists(';
  if position(anchor in d)=0 then raise exception 'Rebalance booking total changed.'; end if;
  d:=replace(d,anchor,'if total_booked<(case when g.participation_rules_version=''s0-configurable-v1'' then g.minimum_players else 10 end) or total_booked>14 or exists(');
  d:=replace(d,'raise exception ''Ten to fourteen original bookings need valid rating snapshots.''',
    'raise exception ''%'',case when g.participation_rules_version=''s0-standard-v1'' then ''Ten to fourteen original bookings need valid rating snapshots.'' else ''The saved minimum of original bookings need valid rating snapshots.'' end');
  anchor:='if actual_count<5 then raise exception ''Each final booked team needs at least five players.'' using errcode=''22023''; end if;';
  if position(anchor in d)=0 then raise exception 'Rebalance minimum guard changed.'; end if;
  execute replace(d,anchor,'if actual_count<(case when g.participation_rules_version=''s0-configurable-v1'' then 1 else 5 end) or total_booked<(case when g.participation_rules_version=''s0-configurable-v1'' then g.minimum_players else 10 end) then raise exception ''Final booked teams must meet the saved minimum and contain at least one player each.'' using errcode=''22023''; end if;');

  d:=pg_get_functiondef('public.admin_lock_open_queue_teams(uuid,uuid)'::regprocedure);
  anchor:='  select * into g from public.open_queue_games where id=game_id_to_use for update;';
  if position(anchor in d)=0 then raise exception 'Admin team-lock row lock changed.'; end if;
  d:=replace(d,anchor,E'  perform fieldrush_rating_private.lock_season_zero_sr();\n'||anchor);
  anchor:='  if g.status <> ''FULL'' or g.operational_state <> ''NORMAL'' then';
  if position(anchor in d)=0 then raise exception 'Admin team-lock status guard changed.'; end if;
  d:=replace(d,anchor,$branch$  if g.rating_policy_id='field-sr-season0-v2' and g.participation_rules_version='s0-configurable-v1' then
    if g.status not in ('OPEN','FULL') or g.operational_state<>'NORMAL' then raise exception 'Only an open game without active review can lock teams.'; end if;
    if g.teams_assigned_at is not null and not exists(select 1 from public.open_queue_bookings where game_id=g.id and status='CONFIRMED' and team is null) then
      return jsonb_build_object('teamsAssignedAt',g.teams_assigned_at,'alreadyLocked',true); end if;
    perform public.referee_assign_season_zero_teams(actor_admin_id,g.id,gen_random_uuid());
    select teams_assigned_at into assigned_at from public.open_queue_games where id=g.id;
    insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
      values(actor_admin_id,'OPEN_QUEUE_TEAMS_LOCKED','SOLO_MATCH',g.id,'Administrator locked teams after the saved minimum was reached.',
        jsonb_build_object('teams_assigned_at',g.teams_assigned_at),jsonb_build_object('teams_assigned_at',assigned_at,'minimum_players',g.minimum_players));
    return jsonb_build_object('teamsAssignedAt',assigned_at,'alreadyLocked',false);
  end if;
$branch$||anchor);
  execute d;
end $migration$;

-- Recurring rules keep their saved version. Only new rules default to the new
-- minimum, and editing a rule never rewrites already materialized games.
do $migration$
declare d text; anchor text;
begin
  d:=pg_get_functiondef('public.admin_save_game_schedule(uuid,uuid,jsonb)'::regprocedure);
  anchor:='''goalkeepers_per_side'',''defenders_per_side'',''attackers_per_side''';
  if position(anchor in d)=0 then raise exception 'Schedule minimum allowlist changed.'; end if;
  d:=replace(d,anchor,anchor||',''minimum_players''');
  anchor:='''attackers_per_side'',4,''is_active'',true';
  if position(anchor in d)=0 then raise exception 'Schedule minimum defaults changed.'; end if;
  d:=replace(d,anchor,'''attackers_per_side'',4,''minimum_players'',10,''is_active'',true');
  anchor:='goalkeepers_per_side,defenders_per_side,attackers_per_side)';
  if position(anchor in d)=0 then raise exception 'Schedule minimum insertion changed.'; end if;
  d:=replace(d,anchor,'goalkeepers_per_side,defenders_per_side,attackers_per_side,minimum_players)');
  anchor:='(merged->>''attackers_per_side'')::smallint)';
  if position(anchor in d)=0 then raise exception 'Schedule minimum values changed.'; end if;
  d:=replace(d,anchor,'(merged->>''attackers_per_side'')::smallint,(merged->>''minimum_players'')::integer)');
  anchor:='attackers_per_side=(merged->>''attackers_per_side'')::smallint';
  if position(anchor in d)=0 then raise exception 'Schedule minimum update changed.'; end if;
  d:=replace(d,anchor,anchor||',minimum_players=(merged->>''minimum_players'')::integer');
  anchor:='  if jsonb_typeof(merged->''is_active'')';
  if position(anchor in d)=0 then raise exception 'Schedule minimum validation changed.'; end if;
  d:=replace(d,anchor,E'  if (merged->>''minimum_players'')::integer not between 2 and 14 then raise exception ''Minimum players must be between 2 and 14.''; end if;\n  if before_schedule.id is not null and before_schedule.participation_rules_version=''s0-standard-v1'' and (merged->>''minimum_players'')::integer<>before_schedule.minimum_players then raise exception ''Create a new schedule to use configurable minimum players; existing schedules retain their saved rating rules.''; end if;\n'||anchor);
  execute d;
  d:=pg_get_functiondef('fieldrush_private.generate_game_schedule(uuid)'::regprocedure);
  anchor:='goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity)';
  if position(anchor in d)=0 then raise exception 'Generated minimum columns changed.'; end if;
  d:=replace(d,anchor,'goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity,minimum_players,participation_rules_version)');
  anchor:='s.goalkeepers_per_side*2,s.defenders_per_side*2,0,s.attackers_per_side*2)';
  if position(anchor in d)=0 then raise exception 'Generated minimum values changed.'; end if;
  d:=replace(d,anchor,'s.goalkeepers_per_side*2,s.defenders_per_side*2,0,s.attackers_per_side*2,s.minimum_players,s.participation_rules_version)');
  anchor:='insert into public.open_queue_games(status,field_id,venue,starts_at,ends_at,timezone,price_fils,age_label,created_by,highest_division,lowest_division,goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity,minimum_players,participation_rules_version)';
  if position(anchor in d)=0 then raise exception 'Generated game activation guard changed.'; end if;
  d:=replace(d,anchor,E'if s.participation_rules_version=''s0-configurable-v1'' and not (select enabled from fieldrush_rating_private.season_zero_activation where singleton) then raise exception ''Enable Season 0 before generating games with configurable minimum players.''; end if;\n      '||anchor);
  -- Policy pinning locks the activation row at INSERT. Recheck the pinned
  -- result as well: activation can change after the optimistic preflight.
  anchor:='s.minimum_players,s.participation_rules_version) returning * into game;';
  if position(anchor in d)=0 then raise exception 'Generated game pinned-policy check changed.'; end if;
  d:=replace(d,anchor,anchor||E'\n      if s.participation_rules_version=''s0-configurable-v1'' and game.rating_policy_id<>''field-sr-season0-v2'' then raise exception ''Enable Season 0 before generating games with configurable minimum players.''; end if;');
  execute d;
end $migration$;

revoke all on function fieldrush_rating_private.protect_solo_minimum(),
  fieldrush_rating_private.season_zero_headcount_ready(text,integer,integer,integer),
  fieldrush_rating_private.calculate_season_zero_sr_standard(jsonb),fieldrush_rating_private.calculate_season_zero_sr_configurable(jsonb),
  fieldrush_rating_private.normalize_season_zero_sr_standard(jsonb),fieldrush_rating_private.normalize_season_zero_sr_configurable(jsonb),
  fieldrush_rating_private.season_zero_sr_interval_configurable(jsonb,integer,integer,boolean,integer)
from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
