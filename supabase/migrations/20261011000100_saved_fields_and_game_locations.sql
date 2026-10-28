-- Saved pitches are the source of truth for new admin-created solo games.
-- Historical and service-generated test fixtures retain their original venue;
-- no unverified address/coordinates are invented or backfilled.
create table public.fields (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 80),
  address text not null check (char_length(trim(address)) between 5 and 240),
  city text not null default 'Phoenix' check (char_length(trim(city)) between 2 and 80),
  state text not null default 'AZ' check (char_length(trim(state)) between 1 and 80),
  country_code text not null default 'US' check (country_code ~ '^[A-Z]{2}$'),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  is_active boolean not null default true,
  created_by uuid references public.referee_profiles(profile_id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index fields_location_name_unique_idx
  on public.fields(lower(trim(name)), lower(trim(address)), lower(trim(city)), country_code);
create index fields_active_name_idx on public.fields(is_active, name);
create trigger set_fields_updated_at before update on public.fields
  for each row execute function public.set_updated_at();

alter table public.fields enable row level security;
-- Catalog writes and inactive records are private to the authenticated admin
-- server. Players read only a game's immutable public location snapshot.
revoke all on public.fields from public, anon, authenticated;
grant select, insert, update on public.fields to service_role;

alter table public.open_queue_games
  add column field_id uuid references public.fields(id) on delete restrict,
  add column location_address text,
  add column location_city text,
  add column location_state text,
  add column location_country_code text,
  add column location_latitude double precision,
  add column location_longitude double precision,
  add constraint open_queue_games_saved_location_check check (
    (field_id is null and location_address is null and location_city is null
      and location_state is null and location_country_code is null
      and location_latitude is null and location_longitude is null)
    or (field_id is not null and location_address is not null and location_city is not null
      and location_state is not null and location_country_code is not null
      and location_latitude is not null and location_longitude is not null
      and location_latitude between -90 and 90 and location_longitude between -180 and 180)
  );
create unique index open_queue_games_field_start_unique_idx
  on public.open_queue_games(field_id, starts_at)
  where field_id is not null and status <> 'CANCELLED';
grant select (field_id, location_address, location_city, location_state,
  location_country_code, location_latitude, location_longitude)
  on public.open_queue_games to authenticated;

create function public.bind_open_queue_game_field()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare saved_field public.fields%rowtype;
begin
  -- Once saved, changing a catalog entry cannot silently redirect booked players.
  -- Operational game updates preserve their original snapshot, even if archived.
  if tg_op = 'UPDATE' and old.field_id is not null then
    if row(new.field_id, new.venue, new.location_address, new.location_city,
        new.location_state, new.location_country_code, new.location_latitude, new.location_longitude)
      is distinct from row(old.field_id, old.venue, old.location_address, old.location_city,
        old.location_state, old.location_country_code, old.location_latitude, old.location_longitude) then
      raise exception 'A scheduled game location cannot be changed. Cancel and recreate the game at the correct field.';
    end if;
    return new;
  end if;
  if new.field_id is null then
    if new.location_address is not null or new.location_city is not null
      or new.location_state is not null or new.location_country_code is not null
      or new.location_latitude is not null or new.location_longitude is not null then
      raise exception 'Game location must come from a saved field.';
    end if;
    return new;
  end if;
  -- FOR SHARE serializes creation with edits/archive, not only deletion: the
  -- saved field must still be active when this game's snapshot is committed.
  select * into saved_field from public.fields where id = new.field_id for share;
  if saved_field.id is null or not saved_field.is_active then
    raise exception 'Choose an active saved field. This field was removed or archived.';
  end if;
  new.venue := saved_field.name;
  new.location_address := saved_field.address;
  new.location_city := saved_field.city;
  new.location_state := saved_field.state;
  new.location_country_code := saved_field.country_code;
  new.location_latitude := saved_field.latitude;
  new.location_longitude := saved_field.longitude;
  return new;
end;
$$;
create trigger bind_open_queue_game_field
before insert or update of field_id, venue, location_address, location_city,
  location_state, location_country_code, location_latitude, location_longitude
on public.open_queue_games for each row execute function public.bind_open_queue_game_field();
revoke all on function public.bind_open_queue_game_field() from public, anon, authenticated;

create function public.admin_save_field(actor_admin_id uuid, field_id_to_update uuid, values_to_use jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare before_field public.fields%rowtype; saved_field public.fields%rowtype; merged jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if values_to_use is null or jsonb_typeof(values_to_use) <> 'object' or values_to_use = '{}'::jsonb
    or exists(select 1 from jsonb_object_keys(values_to_use) key
      where key not in ('name','address','city','state','country_code','latitude','longitude','is_active')) then
    raise exception 'Invalid field details.';
  end if;
  if field_id_to_update is not null then
    select * into before_field from public.fields where id = field_id_to_update for update;
    if before_field.id is null then raise exception 'Field not found.'; end if;
    merged := to_jsonb(before_field) || values_to_use;
  else
    merged := jsonb_build_object('city','Phoenix','state','AZ','country_code','US','is_active',true) || values_to_use;
  end if;
  if jsonb_typeof(merged->'is_active') is distinct from 'boolean' then raise exception 'Active status must be true or false.'; end if;
  if field_id_to_update is null then
    insert into public.fields(name,address,city,state,country_code,latitude,longitude,is_active,created_by)
    values(trim(merged->>'name'),trim(merged->>'address'),trim(merged->>'city'),trim(merged->>'state'),upper(trim(merged->>'country_code')),
      (merged->>'latitude')::double precision,(merged->>'longitude')::double precision,(merged->>'is_active')::boolean,actor_admin_id)
    returning * into saved_field;
  else
    update public.fields set name=trim(merged->>'name'),address=trim(merged->>'address'),city=trim(merged->>'city'),
      state=trim(merged->>'state'),country_code=upper(trim(merged->>'country_code')),latitude=(merged->>'latitude')::double precision,
      longitude=(merged->>'longitude')::double precision,is_active=(merged->>'is_active')::boolean
    where id=field_id_to_update returning * into saved_field;
  end if;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,
    case when before_field.id is null then 'FIELD_CREATED'
      when before_field.is_active and not saved_field.is_active then 'FIELD_ARCHIVED'
      when not before_field.is_active and saved_field.is_active then 'FIELD_RESTORED' else 'FIELD_UPDATED' end,
    'ACTION',saved_field.id,'Admin maintained the saved field catalog.',
    case when before_field.id is null then '{}'::jsonb else to_jsonb(before_field) end,to_jsonb(saved_field));
  return to_jsonb(saved_field);
end;
$$;
revoke all on function public.admin_save_field(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.admin_save_field(uuid,uuid,jsonb) to service_role;

-- Leave a clear failure for stale callers rather than silently accepting a
-- free-text venue. Existing migration fixtures can still insert service-owned
-- synthetic games directly; application admins must use the saved-field RPC.
create or replace function public.admin_create_open_queue_game(
  actor_admin_id uuid, venue_to_use text, starts_at_to_use timestamptz,
  price_fils_to_use integer, age_label_to_use text
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  raise exception 'Choose a saved field before creating the game. Refresh the admin page.';
end;
$$;

create function public.admin_create_open_queue_game(
  actor_admin_id uuid, field_id_to_use uuid, starts_at_to_use timestamptz,
  price_fils_to_use integer, age_label_to_use text
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare created_game public.open_queue_games%rowtype; normalized_age_label text := trim(coalesce(age_label_to_use, ''));
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if field_id_to_use is null then raise exception 'Choose a saved field before creating the game.'; end if;
  if char_length(normalized_age_label) not between 2 and 40 then raise exception 'Age label must be between 2 and 40 characters.'; end if;
  if starts_at_to_use is null or starts_at_to_use <= now() then raise exception 'The solo game must be scheduled in the future.'; end if;
  if price_fils_to_use is null or price_fils_to_use not between 0 and 100000 or price_fils_to_use % 10 <> 0 then
    raise exception 'Price must be between 0 and 100 USD, in whole cents.';
  end if;
  insert into public.open_queue_games(status,field_id,venue,starts_at,ends_at,timezone,price_fils,age_label,created_by)
  values('OPEN',field_id_to_use,'Saved field',starts_at_to_use,starts_at_to_use + interval '1 hour',
    'America/Phoenix',price_fils_to_use,normalized_age_label,actor_admin_id)
  returning * into created_game;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,'SOLO_GAME_CREATED','SOLO_MATCH',created_game.id,
    'Admin created a scheduled solo queue game at a saved field.','{}'::jsonb,to_jsonb(created_game));
  return created_game.id;
end;
$$;
revoke all on function public.admin_create_open_queue_game(uuid,text,timestamptz,integer,text) from public, anon, authenticated;
revoke all on function public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text) from public, anon, authenticated;
grant execute on function public.admin_create_open_queue_game(uuid,text,timestamptz,integer,text) to service_role;
grant execute on function public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text) to service_role;
notify pgrst, 'reload schema';
