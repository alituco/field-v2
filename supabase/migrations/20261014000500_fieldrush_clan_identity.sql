-- Clan identity follows the creator's discovery city, while older financial
-- and competitive records retain their existing region values.
alter table public.clans add column market_city_id text not null default 'phoenix'
  references public.fieldrush_cities(id) on delete restrict;
alter table public.clans alter column region set default 'phoenix';
alter table public.clans drop constraint clans_region_check;
alter table public.clans add constraint clans_region_check check(region='bahrain' or region=market_city_id);

create function public.snapshot_fieldrush_clan_city()
returns trigger language plpgsql security definer set search_path=public,fieldrush_private,pg_temp as $$
begin
  if tg_op='UPDATE' then
    if new.market_city_id is distinct from old.market_city_id or new.region is distinct from old.region then
      raise exception 'A clan’s home city cannot be changed through its identity settings.';
    end if;
    return new;
  end if;
  select a.preferred_city_id into new.market_city_id from fieldrush_private.accounts a where a.user_id=new.created_by;
  if new.market_city_id is null or not exists(select 1 from public.fieldrush_cities c where c.id=new.market_city_id and c.active) then
    raise exception 'Choose an available home city before creating a clan.';
  end if;
  new.region:=new.market_city_id;
  return new;
end;
$$;
create trigger snapshot_fieldrush_clan_city before insert or update of market_city_id,region on public.clans
for each row execute function public.snapshot_fieldrush_clan_city();
revoke all on function public.snapshot_fieldrush_clan_city() from public,anon,authenticated;

create function public.list_fieldrush_clans()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if auth.uid() is null and coalesce(auth.role(),'')<>'service_role' then raise exception 'You need to sign in again.'; end if;
  select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('market_city_id',stored.market_city_id,'city_name',city.display_name)
    order by lower(c.name),c.id),'[]'::jsonb) into result
  from public.list_clans() c join public.clans stored on stored.id=c.id join public.fieldrush_cities city on city.id=stored.market_city_id;
  return result;
end;
$$;
create function public.list_fieldrush_clan_members(clan_id_to_use uuid)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result jsonb; starts date; ends date;
begin
  if auth.uid() is null and coalesce(auth.role(),'')<>'service_role' then raise exception 'You need to sign in again.'; end if;
  if not exists(select 1 from public.clans c where c.id=clan_id_to_use and c.archived_at is null) then raise exception 'Clan not found.'; end if;
  select starts_on,ends_on into starts,ends from fieldrush_rating_private.current_season_bounds((now() at time zone 'America/Phoenix')::date);
  select coalesce(jsonb_agg(jsonb_build_object('profile_id',m.profile_id,'role',m.role,'created_at',m.created_at,
    'profiles',jsonb_build_object('display_name',p.display_name,'username',p.username,'avatar_url',p.avatar_url),
    'matches_played',stats.played,'skill_rating',case when stats.played>=2 then r.skill_rating end)
    order by case m.role when 'owner' then 0 when 'leader' then 1 else 2 end,m.created_at,m.profile_id),'[]'::jsonb) into result
  from public.clan_members m join public.profiles p on p.id=m.profile_id and p.account_deleted_at is null
  left join public.fieldrush_player_rating_tracks r on r.profile_id=p.id and r.rating_track='OUTFIELD'
  left join lateral (select count(*)::integer played from fieldrush_rating_private.season_track_events(starts,ends) e
    where e.profile_id=p.id and e.rating_track='OUTFIELD') stats on true
  where m.clan_id=clan_id_to_use and m.left_at is null;
  return result;
end;
$$;
revoke all on function public.list_fieldrush_clans(),public.list_fieldrush_clan_members(uuid) from public,anon;
grant execute on function public.list_fieldrush_clans(),public.list_fieldrush_clan_members(uuid) to authenticated,service_role;
notify pgrst,'reload schema';
