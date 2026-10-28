-- Public search presentation uses the current Outfield ladder. Private account
-- details are never part of a result, and placement players have no revealed SR.
create or replace function public.search_fieldrush_players(query_to_use text)
returns jsonb language plpgsql stable security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
declare input text:=lower(left(trim(regexp_replace(coalesce(query_to_use,''),'^@+','','g')),60));
  season_start date; season_end date; payload jsonb;
begin
  if auth.uid() is null and coalesce(auth.role(),'')<>'service_role' then
    raise exception 'You need to sign in again.';
  end if;
  if length(input)<2 then return '[]'::jsonb; end if;
  select starts_on,ends_on into season_start,season_end
    from fieldrush_rating_private.current_season_bounds((now() at time zone 'America/Phoenix')::date);
  with matches as materialized (
    select p.id,p.display_name,p.username,p.avatar_url,
      case when strpos(lower(p.username),input)=1 then 0
        when strpos(lower(p.username),input)>0 then 1 else 2 end score
    from public.profiles p
    join fieldrush_private.accounts a on a.user_id=p.id and a.status='active' and a.onboarding_completed_at is not null
    where p.account_deleted_at is null and
      (strpos(lower(p.username),input)>0 or strpos(lower(p.display_name),input)>0)
    order by score,lower(p.display_name),p.id limit 30
  ), stats as (
    select e.profile_id,count(*)::integer played
    from fieldrush_rating_private.season_track_events(season_start,season_end) e
    join matches m on m.id=e.profile_id where e.rating_track='OUTFIELD'
    group by e.profile_id
  ), results as (
    select m.*,coalesce(s.played,0) matches_played,
      case when coalesce(s.played,0)>=2 then r.skill_rating end skill_rating,
      catalog.display_name city_name,m.id=auth.uid() is_self
    from matches m left join stats s on s.profile_id=m.id
    left join public.fieldrush_player_rating_tracks r on r.profile_id=m.id and r.rating_track='OUTFIELD'
    left join fieldrush_rating_private.primary_season_cities(season_start,season_end) c on c.profile_id=m.id
    left join public.fieldrush_cities catalog on catalog.id=c.market_city_id
  ) select coalesce(jsonb_agg(to_jsonb(r)-'score' order by r.score,r.skill_rating desc nulls last,lower(r.display_name),r.id),'[]'::jsonb)
    into payload from results r;
  return payload;
end;
$$;
revoke all on function public.search_fieldrush_players(text) from public,anon;
grant execute on function public.search_fieldrush_players(text) to authenticated,service_role;
notify pgrst,'reload schema';
