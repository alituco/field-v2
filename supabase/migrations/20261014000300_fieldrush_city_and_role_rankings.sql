-- One global skill rating per discipline; cities are memberships, not separate
-- ratings. Both disciplines share the city earned across all eligible play.
create function fieldrush_rating_private.track_rating_at(player_to_use uuid,track_to_use text,season_ends_on date)
returns table(skill_rating integer,last_change integer) language sql stable security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
  select case when season_ends_on>=(now() at time zone 'UTC')::date then r.skill_rating else coalesce(e.rating_after,1200) end,
    case when season_ends_on>=(now() at time zone 'UTC')::date then r.last_change else coalesce(e.rating_change,0) end
  from public.fieldrush_player_rating_tracks r
  left join lateral (select event.rating_after,event.rating_change from public.player_rating_events event
    where event.profile_id=r.profile_id and event.rating_track=r.rating_track
      and event.played_at>=r.ratings_reset_at and event.applied_sequence>r.ratings_reset_sequence
      and (event.played_at at time zone event.played_timezone)::date<=season_ends_on
    order by event.applied_sequence desc limit 1) e on true
  where r.profile_id=player_to_use and r.rating_track=track_to_use;
$$;
create function fieldrush_rating_private.season_track_events(season_starts_on date,season_ends_on date)
returns setof public.player_rating_events language sql stable security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
  select e.* from fieldrush_rating_private.eligible_track_events e
  where (e.played_at at time zone e.played_timezone)::date between season_starts_on and season_ends_on;
$$;
create function fieldrush_rating_private.primary_season_cities(season_starts_on date,season_ends_on date)
returns table(profile_id uuid,market_city_id text,games_played bigint,last_played_at timestamptz)
language sql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
  with city_counts as (
    select e.profile_id,e.market_city_id,count(distinct (e.source_type,e.source_id)) games_played,max(e.played_at) last_played_at
    from fieldrush_rating_private.season_track_events(season_starts_on,season_ends_on) e
    group by e.profile_id,e.market_city_id
  ) select distinct on(c.profile_id) c.profile_id,c.market_city_id,c.games_played,c.last_played_at
    from city_counts c order by c.profile_id,c.games_played desc,c.last_played_at desc,c.market_city_id;
$$;
create function fieldrush_rating_private.track_rankings(scope_to_use text,city_id_to_use text,rating_track_to_use text,season_starts_on date,season_ends_on date)
returns table(rank bigint,profile_id uuid,display_name text,username text,avatar_url text,skill_rating integer,
  matches_played integer,wins integer,losses integer,draws integer,last_change integer,region text,primary_city_id text,primary_city_name text)
language sql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
  with events as materialized (
    select * from fieldrush_rating_private.season_track_events(season_starts_on,season_ends_on) where rating_track=rating_track_to_use
  ), stats as (
    select e.profile_id,count(*)::integer matches_played,count(*) filter(where result='WIN')::integer wins,
      count(*) filter(where result='LOSS')::integer losses,count(*) filter(where result='DRAW')::integer draws
    from events e group by e.profile_id having count(*)>=2
  ), ranked as (
    select p.id profile_id,p.display_name,p.username,p.avatar_url,rating.skill_rating,
      s.matches_played,s.wins,s.losses,s.draws,rating.last_change,c.market_city_id,
      catalog.display_name city_name
    from stats s join public.profiles p on p.id=s.profile_id and p.account_deleted_at is null
    join fieldrush_rating_private.primary_season_cities(season_starts_on,season_ends_on) c on c.profile_id=p.id
    join public.fieldrush_cities catalog on catalog.id=c.market_city_id
    join fieldrush_rating_private.track_rating_at(p.id,rating_track_to_use,season_ends_on) rating on true
    where scope_to_use='GLOBAL' or c.market_city_id=city_id_to_use
  ) select row_number() over(order by r.skill_rating desc,r.matches_played desc,r.wins desc,lower(r.display_name),r.profile_id),
    r.profile_id,r.display_name,r.username,r.avatar_url,r.skill_rating,r.matches_played,r.wins,r.losses,r.draws,r.last_change,
    r.market_city_id,r.market_city_id,r.city_name from ranked r;
$$;
revoke all on function fieldrush_rating_private.track_rating_at(uuid,text,date),fieldrush_rating_private.season_track_events(date,date),
  fieldrush_rating_private.primary_season_cities(date,date),fieldrush_rating_private.track_rankings(text,text,text,date,date)
  from public,anon,authenticated;

create function fieldrush_rating_private.validate_ranking_request(season_starts_on date,season_ends_on date,rating_track_to_use text)
returns void language plpgsql stable set search_path=public,pg_temp as $$
begin
  if auth.uid() is null and coalesce(auth.role(),'')<>'service_role' then raise exception 'You need to sign in again.'; end if;
  if rating_track_to_use not in ('OUTFIELD','GOALKEEPER') or rating_track_to_use is null then raise exception 'Choose Outfield or Keeper.'; end if;
  if season_starts_on is null or season_ends_on is null or season_ends_on<season_starts_on
    or season_ends_on-season_starts_on>370 then raise exception 'Choose a valid leaderboard season.'; end if;
end;
$$;
revoke all on function fieldrush_rating_private.validate_ranking_request(date,date,text) from public,anon,authenticated;

create function public.list_fieldrush_rating_page(scope_to_use text,city_id_to_use text,rating_track_to_use text,
  season_starts_on date,season_ends_on date,offset_to_use integer default 0,page_size_to_use integer default 23)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result jsonb; safe_offset integer:=greatest(0,coalesce(offset_to_use,0)); safe_size integer:=greatest(1,least(100,coalesce(page_size_to_use,23)));
begin
  perform fieldrush_rating_private.validate_ranking_request(season_starts_on,season_ends_on,rating_track_to_use);
  if scope_to_use is null or scope_to_use not in ('GLOBAL','CITY') then raise exception 'Choose a global or city leaderboard.'; end if;
  if scope_to_use='CITY' and not exists(select 1 from public.fieldrush_cities where id=city_id_to_use) then raise exception 'Choose an available city.'; end if;
  with rankings as materialized (
    select * from fieldrush_rating_private.track_rankings(scope_to_use,city_id_to_use,rating_track_to_use,season_starts_on,season_ends_on)
  ), page as (select * from rankings order by rank offset safe_offset limit safe_size),
  own_rank as (select rank from rankings where profile_id=auth.uid()),
  neighbors as (select r.* from rankings r cross join own_rank me where r.rank between me.rank-2 and me.rank+2),
  totals as (select count(*)::integer total_count from rankings)
  select jsonb_build_object('players',coalesce((select jsonb_agg(to_jsonb(p) order by rank) from page p),'[]'::jsonb),
    'around_me',coalesce((select jsonb_agg(to_jsonb(n) order by rank) from neighbors n),'[]'::jsonb),
    'total_count',totals.total_count,'next_offset',case when safe_offset::bigint+safe_size<totals.total_count then safe_offset+safe_size end,
    'scope',scope_to_use,'city_id',city_id_to_use,'rating_track',rating_track_to_use) into result from totals;
  return result;
end;
$$;
revoke all on function public.list_fieldrush_rating_page(text,text,text,date,date,integer,integer) from public,anon;
grant execute on function public.list_fieldrush_rating_page(text,text,text,date,date,integer,integer) to authenticated,service_role;

create function public.get_fieldrush_player_ratings(profile_id_to_use uuid,season_starts_on date,season_ends_on date)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare tracks jsonb:='{}'::jsonb; track text; item jsonb; history jsonb;
  city_id text; city_name text; preferred_city text; selected_profile public.profiles%rowtype;
begin
  perform fieldrush_rating_private.validate_ranking_request(season_starts_on,season_ends_on,'OUTFIELD');
  select * into selected_profile from public.profiles where id=profile_id_to_use and account_deleted_at is null;
  if selected_profile.id is null then raise exception 'Player profile not found.'; end if;
  select c.market_city_id,catalog.display_name into city_id,city_name
    from fieldrush_rating_private.primary_season_cities(season_starts_on,season_ends_on) c
    join public.fieldrush_cities catalog on catalog.id=c.market_city_id where c.profile_id=profile_id_to_use;
  -- Discovery preference is private and is only returned for the signed-in owner.
  if profile_id_to_use=auth.uid() then
    select preferred_city_id into preferred_city from fieldrush_private.accounts where user_id=profile_id_to_use;
  end if;
  foreach track in array array['OUTFIELD','GOALKEEPER'] loop
    with events as materialized (
      select * from fieldrush_rating_private.season_track_events(season_starts_on,season_ends_on)
      where profile_id=profile_id_to_use and rating_track=track
    ), stats as (select count(*)::integer played,count(*) filter(where result='WIN')::integer wins,
      count(*) filter(where result='LOSS')::integer losses,count(*) filter(where result='DRAW')::integer draws from events),
    current_rating as (select * from fieldrush_rating_private.track_rating_at(profile_id_to_use,track,season_ends_on))
    select jsonb_build_object('profile_id',profile_id_to_use,'display_name',selected_profile.display_name,'username',selected_profile.username,
      'avatar_url',selected_profile.avatar_url,'rating_track',track,'skill_rating',coalesce((select skill_rating from current_rating),1200),
      'matches_played',stats.played,'wins',stats.wins,'losses',stats.losses,'draws',stats.draws,
      'last_change',coalesce((select last_change from current_rating),0),
      'global_rank',(select rank from fieldrush_rating_private.track_rankings('GLOBAL',null,track,season_starts_on,season_ends_on) where profile_id=profile_id_to_use),
      'city_rank',(select rank from fieldrush_rating_private.track_rankings('CITY',city_id,track,season_starts_on,season_ends_on) where profile_id=profile_id_to_use),
      'rank',(select rank from fieldrush_rating_private.track_rankings('CITY',city_id,track,season_starts_on,season_ends_on) where profile_id=profile_id_to_use),
      'primary_city_id',city_id,'primary_city_name',city_name,'region',coalesce(city_id,'')) into item from stats;
    select coalesce(jsonb_agg(h.payload order by h.sequence desc),'[]'::jsonb) into history from (
      select e.applied_sequence sequence,jsonb_build_object('id',e.id,'event_id',e.id,'source_type',e.source_type,'source_id',e.source_id,
        'open_queue_game_id',e.source_id,'fixture_id',null,'rating_track',e.rating_track,'market_city_id',e.market_city_id,
        'played_at',e.played_at,'counted_as_played',true,'rating_before',e.rating_before,
        'rating_after',e.rating_after+coalesce(appeal.rating_adjustment,0),
        'rating_change',e.rating_change+coalesce(appeal.rating_adjustment,0),
        'original_rating_change',e.rating_change,'original_rating_after',e.rating_after,
        'appeal_rating_adjustment',coalesce(appeal.rating_adjustment,0),'appeal_adjustment_id',appeal.id,
        'result',e.result,'match_outcome',e.result,'venue',g.venue,
        'side',e.side,'team_name',case e.side when 'WHITE' then 'White Team' else 'Black Team' end,
        'opponent_name',case e.side when 'WHITE' then 'Black Team' else 'White Team' end,
        'opponent_label',case e.side when 'WHITE' then 'Black Team' else 'White Team' end,
        'score_for',case e.side when 'WHITE' then g.white_score else g.black_score end,
        'score_against',case e.side when 'WHITE' then g.black_score else g.white_score end) payload
      from fieldrush_rating_private.season_track_events(season_starts_on,season_ends_on) e
      join public.open_queue_games g on g.id=e.source_id
      left join public.reliability_sr_appeal_adjustments appeal on appeal.rating_event_id=e.id
      where e.profile_id=profile_id_to_use and e.rating_track=track order by e.applied_sequence desc limit 50
    ) h;
    tracks:=tracks||jsonb_build_object(track,item||jsonb_build_object('events',history,'recent_events',history));
  end loop;
  return jsonb_build_object('profile_id',profile_id_to_use,'primary_city_id',city_id,'primary_city_name',city_name,
    'preferred_city_id',preferred_city,'ratings',tracks);
end;
$$;
revoke all on function public.get_fieldrush_player_ratings(uuid,date,date) from public,anon;
grant execute on function public.get_fieldrush_player_ratings(uuid,date,date) to authenticated,service_role;
notify pgrst,'reload schema';
