-- Canonical SR has no product floor. Historical values are left intact; the
-- legacy calculator retains its own historical formula on legacy games.
-- Recreate the private SELECT-* view after widening the ledger numeric columns.
drop view fieldrush_rating_private.eligible_track_events;
alter table public.fieldrush_player_rating_tracks drop constraint fieldrush_player_rating_tracks_skill_rating_check;
alter table public.player_ratings drop constraint player_ratings_skill_rating_check;
-- Legacy games and appeals can snapshot a player's new signed canonical SR.
-- Their existing arithmetic stays unchanged; the evidence must accept it.
alter table public.fixture_player_appearances
  drop constraint fixture_player_appearances_rating_at_start_check;
-- PostgreSQL shortens generated names here. Match the exact single-column
-- nonnegative check, retaining the multi-column adjustment-balance constraints.
do $migration$
declare column_to_use text; constraint_to_drop text;
begin
  foreach column_to_use in array array['rating_before_adjustment','rating_after_adjustment'] loop
    select c.conname into strict constraint_to_drop from pg_constraint c
    join pg_attribute a on a.attrelid=c.conrelid and c.conkey=array[a.attnum]
    where c.conrelid='public.reliability_sr_appeal_adjustments'::regclass
      and c.contype='c' and a.attname=column_to_use
      and pg_get_constraintdef(c.oid)=format('CHECK ((%I >= 0))',column_to_use);
    execute format('alter table public.reliability_sr_appeal_adjustments drop constraint %I',constraint_to_drop);
  end loop;
end;
$migration$;
alter table public.player_rating_events
  drop constraint player_rating_events_rating_before_check,
  drop constraint player_rating_events_rating_after_check,
  drop constraint player_rating_events_rating_at_match_start_check,
  drop constraint player_rating_events_team_average_rating_check,
  drop constraint player_rating_events_opponent_average_rating_check;
alter table public.open_queue_bookings
  drop constraint open_queue_bookings_player_rating_at_booking_check,
  drop constraint open_queue_bookings_rating_at_team_assignment_check,
  drop constraint open_queue_bookings_rating_at_match_start_check;
alter table public.open_queue_games
  drop constraint open_queue_games_white_average_sr_check,
  drop constraint open_queue_games_black_average_sr_check,
  drop constraint open_queue_games_match_average_sr_check;
alter table public.player_rating_events
  alter column team_average_rating type numeric,
  alter column opponent_average_rating type numeric;
alter table public.open_queue_games
  alter column white_average_sr type numeric,
  alter column black_average_sr type numeric,
  alter column match_average_sr type numeric,
  alter column team_sr_spread type numeric;

-- Actual participation, not the legacy attendance/lateness classification,
-- decides counted appearances under the prospective policy. Conduct forfeits
-- may count too. Existing matches retain all of their historical filters.
create or replace view fieldrush_rating_private.eligible_track_events as
select e.* from public.player_rating_events e
join public.fieldrush_player_rating_tracks r on r.profile_id=e.profile_id and r.rating_track=e.rating_track
join public.open_queue_games g on e.source_type='OPEN_QUEUE' and g.id=e.source_id
left join fieldrush_rating_private.season_zero_matches state on state.game_id=g.id
left join lateral (select v.resolution_type from public.match_resolution_cases c
  join public.match_resolution_revisions v on v.case_id=c.id where c.open_queue_game_id=g.id order by v.revision desc limit 1) resolution on true
where e.rating_track is not null and e.counted_as_played and g.status='FINAL'
  and case when g.rating_policy_id='field-sr-season0-v2' then state.settlement_status='RATED'
    else coalesce(resolution.resolution_type,'RECORDED_RESULT')='RECORDED_RESULT'
      and not exists(select 1 from public.current_match_attendance_records a where a.match_kind='SOLO'
        and a.open_queue_game_id=g.id and a.profile_id=e.profile_id and a.outcome='NO_SHOW') end
  and e.played_at>=r.ratings_reset_at and e.applied_sequence>r.ratings_reset_sequence;
revoke all on fieldrush_rating_private.eligible_track_events from public,anon,authenticated,service_role;

-- Replay order is match chronology, not the insertion sequence of a replacement
-- public projection. Frozen legacy deltas are included by the private helper.
create or replace function fieldrush_rating_private.track_rating_at(player_to_use uuid,track_to_use text,season_ends_on date)
returns table(skill_rating integer,last_change integer) language sql stable security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
  select case when coalesce(s.lifecycle in ('ACTIVE','SCHEDULED'),season_ends_on>=(now() at time zone 'America/Phoenix')::date)
      then r.skill_rating else coalesce(replayed.skill_rating,e.rating_after,r.initial_seed_rating,1200) end,
    case when coalesce(s.lifecycle in ('ACTIVE','SCHEDULED'),season_ends_on>=(now() at time zone 'America/Phoenix')::date)
      then r.last_change else coalesce(replayed.last_change,e.rating_change,0) end
  from public.fieldrush_player_rating_tracks r
  left join public.fieldrush_seasons s on s.ends_on=season_ends_on and s.lifecycle<>'DRAFT'
  left join lateral fieldrush_rating_private.season_zero_track_rating_at(player_to_use,track_to_use,season_ends_on) replayed on true
  left join lateral (select event.rating_after,event.rating_change from public.player_rating_events event
    left join public.fieldrush_seasons original on original.id=event.season_id
    where event.profile_id=r.profile_id and event.rating_track=r.rating_track and event.played_at>=r.ratings_reset_at
      and event.applied_sequence>r.ratings_reset_sequence
      and coalesce(original.ends_on,(event.played_at at time zone event.played_timezone)::date)<=season_ends_on
    order by event.applied_sequence desc limit 1) e on true
  where r.profile_id=player_to_use and r.rating_track=track_to_use;
$$;

-- Additive API state separates lifetime calibration from seasonal qualification.
create function fieldrush_rating_private.public_rating_state(player_to_use uuid,track_to_use text)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('lifetime_counted_matches',coalesce(r.matches_played,0),
    'rating_visible',coalesce(r.matches_played,0)>=2,'provisional',coalesce(r.matches_played,0) between 2 and 9,
    'placement_matches_remaining',greatest(0,2-coalesce(r.matches_played,0)))
  from (select 1) seed left join public.fieldrush_player_rating_tracks r on r.profile_id=player_to_use and r.rating_track=track_to_use;
$$;

-- The player can preview their own canonical placement rating. Keep this
-- separate from public ranking rows and match history: those remain masked
-- until two lifetime counted games in that pool. Never infer ownership from
-- a client payload or grant the service role a caller-less privacy exception.
create function fieldrush_rating_private.owner_placement_predictions(player_to_use uuid)
returns jsonb language sql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
  select case when auth.uid()=player_to_use then jsonb_build_object('placement_predictions',
    coalesce((select jsonb_object_agg(r.rating_track,jsonb_build_object(
      'skill_rating',r.skill_rating,'lifetime_counted_matches',r.matches_played,
      'last_change',case when r.matches_played=1 and latest.counted_as_played then latest.rating_change end))
      from public.fieldrush_player_rating_tracks r
      left join lateral (select e.rating_change,e.counted_as_played from public.player_rating_events e
        where e.profile_id=r.profile_id and e.rating_track=r.rating_track
          and e.played_at>=r.ratings_reset_at and e.applied_sequence>r.ratings_reset_sequence
        order by e.played_at desc,e.applied_sequence desc limit 1) latest on true
      where r.profile_id=player_to_use and r.matches_played between 0 and 1),'{}'::jsonb))
    else '{}'::jsonb end;
$$;
revoke all on function fieldrush_rating_private.owner_placement_predictions(uuid) from public,anon,authenticated,service_role;

create function fieldrush_rating_private.public_match_ratings_visible(game_to_use uuid)
returns boolean language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare original_roster jsonb; settlement text;
begin
  if game_to_use is null or not exists(select 1 from public.open_queue_games where id=game_to_use) then return false; end if;
  select observed_roster,settlement_status into original_roster,settlement
    from fieldrush_rating_private.season_zero_matches where game_id=game_to_use;
  if settlement in ('HELD','NOT_RATED') then return false; end if;
  -- Cancellation changes booking statuses, but never makes original hidden
  -- participants disappear from the privacy check for retained team snapshots.
  if jsonb_array_length(original_roster)>0 then
    return not exists(select 1 from jsonb_array_elements(original_roster) p
      left join public.fieldrush_player_rating_tracks r on r.profile_id=(p->>'id')::uuid and r.rating_track=p->>'rating_track'
      where coalesce(r.matches_played,0)<2);
  end if;
  return exists(select 1 from public.open_queue_bookings where game_id=game_to_use and status='CONFIRMED')
    and not exists(select 1 from public.open_queue_bookings b left join public.fieldrush_player_rating_tracks r
      on r.profile_id=b.profile_id and r.rating_track=public.fieldrush_rating_track(b.role)
      where b.game_id=game_to_use and b.status='CONFIRMED' and coalesce(r.matches_played,0)<2);
end;
$$;

create function fieldrush_rating_private.public_match_rating_state(game_to_use uuid)
returns jsonb language sql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
  select coalesce((select jsonb_build_object('rating_policy_id','field-sr-season0-v2',
    'rating_status',s.settlement_status,'rating_explanation',case s.settlement_status
      when 'HELD' then 'Rating pending review. No rating has been applied for this match.'
      when 'UNSETTLED' then 'Rating pending match completion and verification.'
      when 'NOT_RATED' then 'This match is not rated. It does not change SR or counted appearances.'
      else 'Rating uses actual playing time, the result, and verified match events.' end)
    from fieldrush_rating_private.season_zero_matches s where s.game_id=game_to_use),'{}'::jsonb);
$$;

-- Public eligibility is derived from the active audited settlement, never from
-- a match-wide RATED flag or a zero-valued ledger row. Do not expose private
-- timelines, medical reasons, actors, or hidden numeric rating inputs.
create function fieldrush_rating_private.public_player_match_rating_state(game_to_use uuid,player_to_use uuid,track_to_use text)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare match_state jsonb; award jsonb; participation jsonb; snapshot jsonb; counted boolean; played integer; explanation text;
  visible boolean; numeric_state jsonb:=jsonb_build_object('rating_before',null,'rating_at_match_start',null,'rating_after',null,'rating_change',null);
begin
  match_state:=fieldrush_rating_private.public_match_rating_state(game_to_use);
  if match_state='{}'::jsonb or player_to_use is null then return '{}'::jsonb; end if;
  if match_state->>'rating_status'<>'RATED' then
    return numeric_state||jsonb_build_object('counted_as_played',case when match_state->>'rating_status'='NOT_RATED' then false else null end,
      'actual_played_seconds',null,'rating_explanation',match_state->>'rating_explanation');
  end if;
  select r.calculation->'players'->player_to_use::text,p.value,original.value into award,participation,snapshot
    from fieldrush_rating_private.season_zero_active_settlements a
    join fieldrush_rating_private.season_zero_settlement_revisions r on r.id=a.settlement_id and r.status='RATED'
    cross join lateral jsonb_array_elements(r.normalization->'core'->'players') p(value)
    cross join lateral jsonb_array_elements(r.input_snapshot->'roster') original(value)
    where a.game_id=game_to_use and p.value->>'id'=player_to_use::text
      and original.value->>'id'=player_to_use::text and original.value->>'rating_track'=track_to_use;
  if award is null or participation is null then
    return numeric_state||jsonb_build_object('counted_as_played',null,'actual_played_seconds',null,
      'rating_explanation','This match is rated. Individual participation eligibility applies.');
  end if;
  counted:=(award->>'counted')::boolean; played:=(participation->>'actual_seconds')::integer;
  -- Replayed results use their effective chronological snapshot, not the
  -- booking's immutable originally observed kickoff SR. Mask here too because
  -- this additive projection is attached after the recursive privacy pass.
  visible:=(fieldrush_rating_private.public_rating_state(player_to_use,track_to_use)->>'rating_visible')::boolean;
  if visible then
    numeric_state:=jsonb_build_object('rating_before',snapshot->'sr_before','rating_at_match_start',snapshot->'sr_before',
      'rating_after',award->'sr_after','rating_change',award->'delta');
  end if;
  explanation:=case
    when not counted and played=0 then 'No counted appearance: no playing time was recorded.'
    when not counted and participation->>'exit_reason' in ('QUIT','RED_CARD','BLUE_CARD')
      then 'Under 10 playing minutes: this appearance does not count. Only negative conduct adjustments can apply.'
    when not counted then format('No SR change: %s min %s sec played; 10 minutes are required. This appearance does not count.',played/60,played%60)
    when (award->>'raw_forgiveness')::numeric>0 then 'This appearance counts. Shorthanded loss protection applied.'
    else 'This appearance counts: at least 10 playing minutes were verified.' end;
  return numeric_state||jsonb_build_object('counted_as_played',counted,'actual_played_seconds',played,'rating_explanation',explanation);
end;
$$;

-- Apply server-side masking to nested public profiles, histories and lineups.
-- Unknown identities fail closed. Referee/balancing services use private data.
create function fieldrush_rating_private.mask_public_rating_payload(payload jsonb,player_to_use uuid default null,track_to_use text default 'OUTFIELD',qualification_minimum integer default null,game_to_use uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result jsonb; item record; player uuid:=player_to_use; track text:=track_to_use; state jsonb;
  id_text text; rating_keys text[]:=array['skill_rating','last_change','rating_before','rating_after','rating_change',
    'original_rating_change','original_rating_after','appeal_rating_adjustment','rating_at_match_start','rating_at_team_assignment',
    'player_rating_at_booking','team_average_rating','opponent_average_rating','base_rating_change','margin_bonus_applied','margin_bonus_before_clamp',
    'expected_score','actual_score'];
  has_rating boolean; game_id uuid:=game_to_use; game_text text; match_state jsonb; unsettled boolean:=false;
begin
  if payload is null or payload='null'::jsonb then return payload; end if;
  if jsonb_typeof(payload)='array' then
    select coalesce(jsonb_agg(fieldrush_rating_private.mask_public_rating_payload(value,player,track,qualification_minimum,game_to_use) order by ordinal),'[]'::jsonb)
      into result from jsonb_array_elements(payload) with ordinality e(value,ordinal);
    return result;
  end if;
  if jsonb_typeof(payload)<>'object' then return payload; end if;
  id_text:=payload->>'profile_id';
  if id_text is null and (payload ? 'display_name' or payload ? 'username') then id_text:=payload->>'id'; end if;
  if id_text ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then player:=id_text::uuid; end if;
  if payload->>'rating_track' in ('OUTFIELD','GOALKEEPER') then track:=payload->>'rating_track';
  elsif payload->>'role' in ('GK','DEF','MID','ATT') then track:=public.fieldrush_rating_track(payload->>'role'); end if;
  state:=fieldrush_rating_private.public_rating_state(player,track);
  has_rating:=payload ?| rating_keys or (payload ? 'profile_id' and payload ? 'matches_played');
  result:=payload;
  game_text:=coalesce(payload->>'game_id',payload->>'open_queue_game_id',
    case when payload->>'source_type'='OPEN_QUEUE' then payload->>'source_id' end,
    case when payload ? 'venue' and payload ? 'status' then payload->>'id' end);
  if game_text ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then game_id:=game_text::uuid; end if;
  match_state:=fieldrush_rating_private.public_match_rating_state(game_id);
  unsettled:=coalesce(match_state->>'rating_status' in ('UNSETTLED','HELD','NOT_RATED'),false);
  for item in select key,value from jsonb_each(payload) loop
    -- A revealed player's history must not reveal an unplaced participant by
    -- exposing the exact team mean or the expectation derived from those means.
    if item.key in ('white_average_sr','black_average_sr','match_average_sr','team_sr_spread',
      'team_average_rating','opponent_average_rating','expected_score')
      and not fieldrush_rating_private.public_match_ratings_visible(game_id) then
      result:=jsonb_set(result,array[item.key],'null'::jsonb);
    elsif item.key=any(rating_keys) and (not (state->>'rating_visible')::boolean or unsettled) then
      result:=jsonb_set(result,array[item.key],'null'::jsonb);
    elsif jsonb_typeof(item.value) in ('object','array') then
      result:=jsonb_set(result,array[item.key],fieldrush_rating_private.mask_public_rating_payload(item.value,player,
        case when item.key in ('OUTFIELD','GOALKEEPER') then item.key else track end,qualification_minimum,game_id));
    end if;
  end loop;
  result:=result||match_state;
  if has_rating then
    result:=result||fieldrush_rating_private.public_player_match_rating_state(game_id,player,track);
    result:=result||state||jsonb_build_object('minimum_rated_games',coalesce(qualification_minimum,
      (select minimum_rated_games from public.fieldrush_seasons where lifecycle='ACTIVE'),2));
    if payload ? 'matches_played' then result:=result||jsonb_build_object('season_counted_matches',payload->'matches_played'); end if;
  end if;
  return result;
end;
$$;
revoke all on function fieldrush_rating_private.public_rating_state(uuid,text),
  fieldrush_rating_private.public_match_ratings_visible(uuid),
  fieldrush_rating_private.public_match_rating_state(uuid),
  fieldrush_rating_private.public_player_match_rating_state(uuid,uuid,text),
  fieldrush_rating_private.mask_public_rating_payload(jsonb,uuid,text,integer,uuid) from public,anon,authenticated,service_role;
revoke all on function fieldrush_rating_private.replace_required(text,text,text) from public,anon,authenticated,service_role;

-- Existing discovery APIs retain their filtering/authorization/season checks;
-- change only the reveal predicate from season-local to lifetime participation.
do $migration$
declare d text;
begin
  d:=pg_get_functiondef('public.search_fieldrush_players(text)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'case when coalesce(s.played,0)>=2 then r.skill_rating end skill_rating',
    'case when coalesce(r.matches_played,0)>=2 then r.skill_rating end skill_rating');
  execute d;
  d:=pg_get_functiondef('fieldrush_rating_private.track_rankings(text,text,text,date,date)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'having count(*)>=2',
    'having count(*)>=coalesce((select minimum_rated_games from public.fieldrush_seasons where starts_on=season_starts_on and ends_on=season_ends_on and lifecycle<>''DRAFT''),2)');
  execute d;
  d:=pg_get_functiondef('public.list_fieldrush_placement_page(text,text,text,date,date,integer,integer)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'where (auth.uid() is null or p.id<>auth.uid())',
    'where exists(select 1 from public.fieldrush_player_rating_tracks lifetime where lifetime.profile_id=p.id and lifetime.rating_track=rating_track_to_use and lifetime.matches_played<2) and (auth.uid() is null or p.id<>auth.uid())');
  execute d;
  d:=pg_get_functiondef('public.get_player_rating_history(uuid,integer)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'''source_id'', event.source_id,',
    '''source_id'', event.source_id, ''rating_track'', event.rating_track, ''counted_as_played'', event.counted_as_played,');
  execute d;
  d:=pg_get_functiondef('public.list_fieldrush_clan_members(uuid)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'case when stats.played>=2 then r.skill_rating end',
    'case when coalesce(r.matches_played,0)>=2 then r.skill_rating end');
  execute d;
end;
$migration$;

-- Table-returning fixture feeds retain their exact return signatures. Aggregate
-- strength is withheld while it could reveal an unplaced player's hidden SR.
do $migration$
declare signature text; original regprocedure; name_to_use text; alias_name text;
  arguments text; identities text; result_type text; calls text; columns text; id_column text; n integer;
begin
  foreach signature in array array['public.list_open_queue_games()','public.list_open_queue_fixture_games()',
    'public.list_open_queue_games_for_market(text)','public.list_open_queue_games_for_city(text)'] loop
    original:=signature::regprocedure;
    select proname,pronargs into name_to_use,n from pg_proc where oid=original;
    arguments:=pg_get_function_arguments(original); identities:=pg_get_function_identity_arguments(original);
    result_type:=pg_get_function_result(original); alias_name:=name_to_use||'_before_sr_privacy';
    select coalesce(string_agg('$'||i,',' order by i),'') into calls from generate_series(1,n) i;
    select case when 'id'=any(proargnames) then 'id' else 'game_id' end into id_column from pg_proc where oid=original;
    select string_agg(case when a.name in ('white_average_sr','black_average_sr','match_average_sr','team_sr_spread')
      then format('case when fieldrush_rating_private.public_match_ratings_visible(row.%I) then row.%I else null::%s end',id_column,a.name,format_type(a.type,null))
      else format('row.%I',a.name) end,',' order by a.ordinal) into columns
      from pg_proc p,unnest(p.proallargtypes,p.proargmodes,p.proargnames) with ordinality a(type,mode,name,ordinal)
      where p.oid=original and a.mode in ('o','b','t');
    if columns is null then raise exception 'Fixture feed return contract changed: %',signature; end if;
    execute format('alter function %s rename to %I',signature,alias_name);
    execute format('revoke all on function public.%I(%s) from public,anon,authenticated,service_role',alias_name,identities);
    execute format('create function public.%I(%s) returns %s language sql stable security definer set search_path=public,pg_temp as $body$
      select %s from public.%I(%s) row $body$',name_to_use,arguments,result_type,columns,alias_name,calls);
    execute format('revoke all on function public.%I(%s) from public,anon',name_to_use,identities);
    execute format('grant execute on function public.%I(%s) to authenticated,service_role',name_to_use,identities);
  end loop;
end;
$migration$;

-- Wrap JSON APIs with one privacy boundary. The original implementations lose
-- all caller grants, including service role, so their aliases are not backdoors.
do $migration$
declare signature text; oid_to_use regprocedure; arguments text; identity_arguments text;
  name_to_use text; alias_name text; calls text; player_expression text; track_expression text; qualification_expression text; game_expression text; prediction_expression text; n integer;
begin
  foreach signature in array array[
    'public.get_fieldrush_player_ratings(uuid,date,date)',
    'public.get_player_rating_history(uuid,integer)',
    'public.list_fieldrush_rating_page(text,text,text,date,date,integer,integer)',
    'public.list_fieldrush_placement_page(text,text,text,date,date,integer,integer)',
    'public.search_fieldrush_players(text)',
    'public.list_fieldrush_clan_members(uuid)',
    'public.get_open_queue_match_detail(uuid)',
    'public.get_fieldrush_season_rewards(text,text,text)',
    'public.get_open_queue_party_context(uuid)'
  ] loop
    oid_to_use:=signature::regprocedure;
    select proname,pronargs into name_to_use,n from pg_proc where oid=oid_to_use;
    if (select prorettype from pg_proc where oid=oid_to_use)<>'jsonb'::regtype then raise exception 'Privacy API return contract changed: %',signature; end if;
    arguments:=pg_get_function_arguments(oid_to_use); identity_arguments:=pg_get_function_identity_arguments(oid_to_use);
    alias_name:=name_to_use||'_before_sr_privacy';
    select string_agg('$'||i,',' order by i) into calls from generate_series(1,n) i;
    execute format('alter function %s rename to %I',signature,alias_name);
    execute format('revoke all on function public.%I(%s) from public,anon,authenticated,service_role',alias_name,identity_arguments);
    player_expression:=case when name_to_use in ('get_fieldrush_player_ratings','get_player_rating_history') then '$1' else 'null::uuid' end;
    track_expression:=case when name_to_use in ('list_fieldrush_rating_page','list_fieldrush_placement_page','get_fieldrush_season_rewards') then '$3' else quote_literal('OUTFIELD') end;
    qualification_expression:=case
      when name_to_use='get_fieldrush_player_ratings' then '(select minimum_rated_games from public.fieldrush_seasons where starts_on=$2 and ends_on=$3 and lifecycle<>''DRAFT'')'
      when name_to_use in ('list_fieldrush_rating_page','list_fieldrush_placement_page') then '(select minimum_rated_games from public.fieldrush_seasons where starts_on=$4 and ends_on=$5 and lifecycle<>''DRAFT'')'
      when name_to_use='get_fieldrush_season_rewards' then '(select minimum_rated_games from public.fieldrush_seasons where id=$1)'
      else 'null::integer' end;
    game_expression:=case when name_to_use in ('get_open_queue_match_detail','get_open_queue_party_context') then '$1' else 'null::uuid' end;
    prediction_expression:=case when name_to_use='get_fieldrush_player_ratings' then 'fieldrush_rating_private.owner_placement_predictions($1)' else quote_literal('{}')||'::jsonb' end;
    execute format('create function public.%I(%s) returns jsonb language sql stable security definer set search_path=public,pg_temp as $body$
      select fieldrush_rating_private.mask_public_rating_payload(public.%I(%s),%s,%s,%s,%s)||%s $body$',
      name_to_use,arguments,alias_name,calls,player_expression,track_expression,qualification_expression,game_expression,prediction_expression);
    execute format('revoke all on function public.%I(%s) from public,anon',name_to_use,identity_arguments);
    execute format('grant execute on function public.%I(%s) to authenticated,service_role',name_to_use,identity_arguments);
  end loop;
end;
$migration$;

do $migration$
declare col record; previously_readable text[];
begin
  select array_agg(attname) into previously_readable from pg_attribute
    where attrelid='public.open_queue_games'::regclass and attnum>0 and not attisdropped
      and has_column_privilege('authenticated','public.open_queue_games',attname,'SELECT');
  revoke select on public.open_queue_games from public,anon,authenticated;
  for col in select attname from pg_attribute where attrelid='public.open_queue_games'::regclass and attnum>0 and not attisdropped loop
    execute format('revoke select(%I) on public.open_queue_games from public,anon,authenticated',col.attname);
    if col.attname=any(previously_readable) and col.attname not in ('white_average_sr','black_average_sr','match_average_sr','team_sr_spread') then
      execute format('grant select(%I) on public.open_queue_games to authenticated',col.attname);
    end if;
  end loop;
end;
$migration$;

-- The old public single-pool APIs are unused by the current app and cannot
-- remain hidden-SR escape hatches. The role-aware APIs above replace them.
do $migration$
declare fn record;
begin
  for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('get_my_player_rating','get_my_season_player_rating',
      'list_player_rating_leaderboard','list_season_player_rating_leaderboard','season_player_rating_rankings','list_fieldrush_player_rating_page') loop
    execute format('revoke execute on function %s from public,anon,authenticated',fn.signature);
  end loop;
end;
$migration$;

-- Revoke both table-level and prior column grants for internal numeric fields.
-- Explicitly preserve every previously readable non-rating column.
do $migration$
declare tab text; col record; previously_readable text[];
begin
  foreach tab in array array['player_ratings','player_rating_events','open_queue_bookings','fixture_player_appearances'] loop
    select array_agg(attname) into previously_readable from pg_attribute
      where attrelid=format('public.%I',tab)::regclass and attnum>0 and not attisdropped
        and has_column_privilege('authenticated',format('public.%I',tab),attname,'SELECT');
    execute format('revoke select on public.%I from public,anon,authenticated',tab);
    for col in select attname from pg_attribute where attrelid=format('public.%I',tab)::regclass and attnum>0 and not attisdropped loop
      execute format('revoke select(%I) on public.%I from public,anon,authenticated',col.attname,tab);
      if tab in ('open_queue_bookings','fixture_player_appearances') and col.attname=any(previously_readable)
        and col.attname not in ('player_rating_at_booking','rating_at_team_assignment','rating_at_match_start','rating_at_start','rating_change') then
        execute format('grant select(%I) on public.%I to authenticated',col.attname,tab);
      end if;
    end loop;
  end loop;
end;
$migration$;

create or replace function public.assert_open_queue_division_eligibility(player_id_to_check uuid,game_id_to_check uuid,role_to_use text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare game public.open_queue_games%rowtype; rating integer; counted integer; division integer; track text:=public.fieldrush_rating_track(role_to_use);
begin
  select * into game from public.open_queue_games where id=game_id_to_check for share;
  if game.id is null then raise exception 'Game not found.'; end if;
  if game.status not in ('OPEN','FULL','LIVE') then return; end if;
  select skill_rating,matches_played into rating,counted from public.fieldrush_player_rating_tracks
    where profile_id=player_id_to_check and rating_track=track;
  if coalesce(counted,0)<2 then
    if game.highest_division<>1 or game.lowest_division<>5 then
      raise exception 'Placement players can only join DIV 1–5 games until their % division is revealed.',lower(track);
    end if;
    return;
  end if;
  division:=public.fieldrush_division_for_rating(rating);
  if division<game.highest_division or division>game.lowest_division then
    raise exception 'This game is for DIV %–%. Your % division is %.',game.highest_division,game.lowest_division,lower(track),division;
  end if;
end;
$$;
notify pgrst,'reload schema';
