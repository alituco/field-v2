-- Sparse ladders show real current-season placement progress, not demo SR.
-- A public city membership is earned from play; private discovery preferences
-- must never be disclosed through another player's placement listing.
create function public.list_fieldrush_placement_page(
  scope_to_use text, city_id_to_use text, rating_track_to_use text,
  season_starts_on date, season_ends_on date,
  offset_to_use integer default 0, page_size_to_use integer default 4
)
returns jsonb language plpgsql stable security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result jsonb;
  safe_offset integer:=greatest(0,coalesce(offset_to_use,0));
  safe_size integer:=greatest(1,least(100,coalesce(page_size_to_use,4)));
begin
  perform fieldrush_rating_private.validate_ranking_request(
    season_starts_on,season_ends_on,rating_track_to_use);
  if scope_to_use is null or scope_to_use not in ('GLOBAL','CITY') then
    raise exception 'Choose a global or city leaderboard.';
  end if;
  if scope_to_use='CITY' and not exists(
    select 1 from public.fieldrush_cities where id=city_id_to_use
  ) then raise exception 'Choose an available city.'; end if;

  with progress as (
    select e.profile_id,count(*)::integer matches_played
    from fieldrush_rating_private.season_track_events(season_starts_on,season_ends_on) e
    where e.rating_track=rating_track_to_use
    group by e.profile_id having count(*)=1
  ), eligible as materialized (
    select p.id profile_id,p.display_name,p.username,p.avatar_url,s.matches_played
    from progress s
    join public.profiles p on p.id=s.profile_id and p.account_deleted_at is null
    join fieldrush_private.accounts a on a.user_id=p.id
      and a.status='active' and a.onboarding_completed_at is not null
    join fieldrush_rating_private.primary_season_cities(season_starts_on,season_ends_on) c
      on c.profile_id=p.id
    where (auth.uid() is null or p.id<>auth.uid())
      and (scope_to_use='GLOBAL' or c.market_city_id=city_id_to_use)
  ), page as (
    select * from eligible order by lower(display_name),profile_id
    offset safe_offset limit safe_size
  ), totals as (select count(*)::integer total_count from eligible)
  select jsonb_build_object(
    'players',coalesce((select jsonb_agg(to_jsonb(p) order by lower(display_name),profile_id) from page p),'[]'::jsonb),
    'total_count',totals.total_count,
    'next_offset',case when safe_offset::bigint+safe_size<totals.total_count then safe_offset+safe_size end
  ) into result from totals;
  return result;
end;
$$;
revoke all on function public.list_fieldrush_placement_page(text,text,text,date,date,integer,integer)
  from public,anon;
grant execute on function public.list_fieldrush_placement_page(text,text,text,date,date,integer,integer)
  to authenticated,service_role;
notify pgrst,'reload schema';
