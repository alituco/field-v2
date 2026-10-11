-- Reuse the authoritative season/reset-period ranking function. No rating,
-- market or eligibility state is written by this read-only endpoint.
-- SECURITY DEFINER ranking reads bypass profile RLS. Remove deleted accounts
-- before row_number() so every consumer retains contiguous, matching ranks.
do $migration$
declare
  definition text;
  old_clause text := 'join public.profiles profile on profile.id = stats.profile_id';
begin
  definition := pg_get_functiondef('public.season_player_rating_rankings(text,date,date)'::regprocedure);
  if (length(definition) - length(replace(definition, old_clause, ''))) / length(old_clause) <> 1 then
    raise exception 'Leaderboard profile eligibility contract changed.';
  end if;
  execute replace(definition, old_clause, old_clause || ' and profile.account_deleted_at is null');
end;
$migration$;

create or replace function public.list_fieldrush_player_rating_page(
  region_to_use text,
  season_starts_on date,
  season_ends_on date,
  offset_to_use integer default 0,
  page_size_to_use integer default 23
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result jsonb;
  safe_offset integer := greatest(0, coalesce(offset_to_use, 0));
  safe_page_size integer := greatest(1, least(100, coalesce(page_size_to_use, 23)));
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;
  if lower(trim(coalesce(region_to_use, ''))) <> 'phoenix' then
    raise exception 'Only the Phoenix ladder is available.';
  end if;
  if season_starts_on is null or season_ends_on is null
    or season_ends_on < season_starts_on
    or season_ends_on - season_starts_on > 370 then
    raise exception 'Choose a valid leaderboard season.';
  end if;

  with rankings as materialized (
    select * from public.season_player_rating_rankings(
      'phoenix', season_starts_on, season_ends_on
    )
  ), page as (
    select * from rankings order by rank
    offset safe_offset limit safe_page_size
  ), own_rank as (
    select rank from rankings where profile_id = auth.uid()
  ), neighbors as (
    select r.* from rankings r cross join own_rank me
    where r.rank between me.rank - 2 and me.rank + 2
  ), totals as (
    select count(*)::integer as total_count from rankings
  )
  select jsonb_build_object(
    'players', coalesce((select jsonb_agg(to_jsonb(p) order by p.rank) from page p), '[]'::jsonb),
    'around_me', coalesce((select jsonb_agg(to_jsonb(n) order by n.rank) from neighbors n), '[]'::jsonb),
    'total_count', totals.total_count,
    'next_offset', case when safe_offset::bigint + safe_page_size < totals.total_count
      then safe_offset + safe_page_size else null end
  ) into result from totals;
  return result;
end;
$$;

revoke all on function public.list_fieldrush_player_rating_page(text,date,date,integer,integer)
  from public, anon;
grant execute on function public.list_fieldrush_player_rating_page(text,date,date,integer,integer)
  to authenticated;
