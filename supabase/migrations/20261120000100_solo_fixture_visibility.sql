-- A missing row means visible. Keeping this separate from open_queue_games
-- also keeps a display change from advancing game timestamps or firing
-- match lifecycle, payment or player notification triggers.
create table public.solo_fixture_visibility (
  game_id uuid primary key references public.open_queue_games(id) on delete cascade,
  hidden_at timestamptz not null default now()
);
alter table public.solo_fixture_visibility enable row level security;
revoke all on public.solo_fixture_visibility from public, anon, authenticated, service_role;
grant select on public.solo_fixture_visibility to authenticated, service_role;
create policy "Read visibility for accessible solo games"
on public.solo_fixture_visibility for select to authenticated
using (exists (select 1 from public.open_queue_games g where g.id = game_id));

create function public.admin_set_solo_fixture_visibility(
  actor_admin_id uuid, game_id_to_use uuid, hidden_to_use boolean
) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare
  game public.open_queue_games%rowtype;
  previous_hidden_at timestamptz;
  new_hidden_at timestamptz;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.' using errcode = '42501';
  end if;
  if hidden_to_use is null then
    raise exception 'Choose whether to hide or show the game.' using errcode = '22023';
  end if;
  -- Serialize hide, restore and concurrent lifecycle changes on the same game.
  select * into game from public.open_queue_games where id = game_id_to_use for update;
  if not found then raise exception 'Solo game not found.' using errcode = 'P0002'; end if;
  select hidden_at into previous_hidden_at from public.solo_fixture_visibility where game_id = game.id;
  if hidden_to_use = (previous_hidden_at is not null) then
    return jsonb_build_object('fixtures_hidden_at', previous_hidden_at);
  end if;
  if hidden_to_use then
    if game.ends_at > now() or game.status = 'LIVE' then
      raise exception 'Only past games that are no longer live can be hidden from Fixtures.'
        using errcode = '22023';
    end if;
    insert into public.solo_fixture_visibility(game_id) values (game.id)
      returning hidden_at into new_hidden_at;
  else
    delete from public.solo_fixture_visibility where game_id = game.id;
  end if;
  insert into public.admin_audit_events(actor_referee_id, action, entity_type, entity_id, reason, before_state, after_state)
  values (actor_admin_id, case when hidden_to_use then 'SOLO_FIXTURE_HIDDEN' else 'SOLO_FIXTURE_RESTORED' end,
    'SOLO_MATCH', game.id, 'Administrator changed the game visibility on Fixtures.',
    jsonb_build_object('fixtures_hidden_at', previous_hidden_at), jsonb_build_object('fixtures_hidden_at', new_hidden_at));
  return jsonb_build_object('fixtures_hidden_at', new_hidden_at);
end;
$$;
revoke all on function public.admin_set_solo_fixture_visibility(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_solo_fixture_visibility(uuid, uuid, boolean) to service_role;

-- Apply the filter in the source of the fixture feed, beneath its existing
-- rating-privacy and arrival-time wrappers. Direct game/history reads still
-- resolve through their own APIs.
do $migration$
declare
  definition text := pg_get_functiondef('public.list_open_queue_fixture_games_before_sr_privacy()'::regprocedure);
  anchor text := E'  where true\n  order by game.starts_at, game.id;';
begin
  if position(anchor in definition) = 0 then
    raise exception 'The fixture feed definition has changed; review its visibility filter.';
  end if;
  execute replace(definition, anchor,
    E'  where not exists (select 1 from public.solo_fixture_visibility v where v.game_id = game.id)\n  order by game.starts_at, game.id;');
end;
$migration$;
notify pgrst, 'reload schema';
