-- Current ratings are already settled in the canonical track row. Do not run
-- the historical Season 0 replay for every ranked player in an active season.
-- Keep the historical fallback (including initial seeds and legacy events).
create or replace function fieldrush_rating_private.track_rating_at(player_to_use uuid,track_to_use text,season_ends_on date)
returns table(skill_rating integer,last_change integer) language plpgsql stable security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
declare use_current boolean;
begin
  select coalesce((select s.lifecycle in ('ACTIVE','SCHEDULED')
    from public.fieldrush_seasons s where s.ends_on=season_ends_on and s.lifecycle<>'DRAFT'),
    season_ends_on>=(now() at time zone 'America/Phoenix')::date) into use_current;
  if use_current then
    return query select r.skill_rating,r.last_change from public.fieldrush_player_rating_tracks r
      where r.profile_id=player_to_use and r.rating_track=track_to_use;
    return;
  end if;
  return query
    select coalesce(replayed.skill_rating,e.rating_after,r.initial_seed_rating,1200),
      coalesce(replayed.last_change,e.rating_change,0)
    from public.fieldrush_player_rating_tracks r
    left join lateral fieldrush_rating_private.season_zero_track_rating_at(player_to_use,track_to_use,season_ends_on) replayed on true
    left join lateral (select event.rating_after,event.rating_change from public.player_rating_events event
      left join public.fieldrush_seasons original on original.id=event.season_id
      where event.profile_id=r.profile_id and event.rating_track=r.rating_track and event.played_at>=r.ratings_reset_at
        and event.applied_sequence>r.ratings_reset_sequence
        and coalesce(original.ends_on,(event.played_at at time zone event.played_timezone)::date)<=season_ends_on
      order by event.applied_sequence desc limit 1) e on true
    where r.profile_id=player_to_use and r.rating_track=track_to_use;
end;
$$;

-- Keep the existing payload/history/authorization and the outer privacy
-- wrapper. Only replace its redundant rank lookups. A city's ordering is the
-- global ordering restricted to that city, including every existing tiebreak.
-- Unqualified tracks cannot have a rank, so never build a leaderboard for them.
do $migration$
declare definition text;
begin
  definition:=pg_get_functiondef('public.get_fieldrush_player_ratings_before_sr_privacy(uuid,date,date)'::regprocedure);
  definition:=fieldrush_rating_private.replace_required(definition,
    'city_id text; city_name text; preferred_city text; selected_profile public.profiles%rowtype;',
    'city_id text; city_name text; preferred_city text; selected_profile public.profiles%rowtype;
     global_position bigint; city_position bigint; minimum_games integer;');
  definition:=fieldrush_rating_private.replace_required(definition,
    'foreach track in array array[''OUTFIELD'',''GOALKEEPER''] loop',
    'select coalesce((select minimum_rated_games from public.fieldrush_seasons
       where starts_on=season_starts_on and ends_on=season_ends_on and lifecycle<>''DRAFT''),2) into minimum_games;
     foreach track in array array[''OUTFIELD'',''GOALKEEPER''] loop');
  definition:=fieldrush_rating_private.replace_required(definition,
    '''global_rank'',(select rank from fieldrush_rating_private.track_rankings(''GLOBAL'',null,track,season_starts_on,season_ends_on) where profile_id=profile_id_to_use),
      ''city_rank'',(select rank from fieldrush_rating_private.track_rankings(''CITY'',city_id,track,season_starts_on,season_ends_on) where profile_id=profile_id_to_use),
      ''rank'',(select rank from fieldrush_rating_private.track_rankings(''CITY'',city_id,track,season_starts_on,season_ends_on) where profile_id=profile_id_to_use),',
    '''global_rank'',null,''city_rank'',null,''rank'',null,');
  definition:=fieldrush_rating_private.replace_required(definition,
    'select coalesce(jsonb_agg(h.payload order by h.sequence desc),''[]''::jsonb) into history from (',
    'if (item->>''matches_played'')::integer>=minimum_games then
       with rankings as materialized (
         select * from fieldrush_rating_private.track_rankings(''GLOBAL'',null,track,season_starts_on,season_ends_on)
       ), positions as (
         select profile_id,rank,primary_city_id,
           row_number() over(partition by primary_city_id order by rank) city_rank from rankings
       ) select rank,case when primary_city_id=city_id then city_rank end into global_position,city_position
         from positions where profile_id=profile_id_to_use;
       item:=item||jsonb_build_object(''global_rank'',global_position,''city_rank'',city_position,''rank'',city_position);
     end if;
     select coalesce(jsonb_agg(h.payload order by h.sequence desc),''[]''::jsonb) into history from (');
  execute definition;
end;
$migration$;

-- CREATE OR REPLACE preserves the existing private ACLs and public wrapper.
notify pgrst,'reload schema';
