-- A discovery preference is separate from the city earned through match play.
create table public.fieldrush_cities (
  id text primary key check (id ~ '^[a-z][a-z0-9-]{1,63}$'),
  display_name text not null check (char_length(trim(display_name)) between 2 and 80),
  state text not null check (char_length(trim(state)) between 1 and 80),
  country_code text not null check (country_code ~ '^[A-Z]{2}$'),
  timezone text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
insert into public.fieldrush_cities(id,display_name,state,country_code,timezone)
values ('phoenix','Phoenix','AZ','US','America/Phoenix');
alter table public.fieldrush_cities enable row level security;
revoke all on public.fieldrush_cities from public,anon,authenticated;
grant select,insert,update on public.fieldrush_cities to service_role;
create trigger set_fieldrush_cities_updated_at before update on public.fieldrush_cities
  for each row execute function public.set_updated_at();

alter table fieldrush_private.accounts add column preferred_city_id text not null default 'phoenix'
  references public.fieldrush_cities(id) on delete restrict;
alter table public.fields add column market_city_id text not null default 'phoenix'
  references public.fieldrush_cities(id) on delete restrict;
alter table public.open_queue_games add column market_city_id text references public.fieldrush_cities(id) on delete restrict;
update public.open_queue_games set market_city_id='phoenix' where format_version='FIELDRUSH_7V7';
alter table public.game_schedules add column market_city_id text not null default 'phoenix'
  references public.fieldrush_cities(id) on delete restrict;
alter table public.game_schedules drop constraint game_schedules_timezone_check;
alter table public.open_queue_games drop constraint open_queue_games_versioned_format_check;
alter table public.open_queue_games add constraint open_queue_games_versioned_format_check check (
  (format_version='LEGACY_6V6' and capacity=12 and goalkeeper_capacity=2 and defender_capacity=4
    and midfielder_capacity=4 and attacker_capacity=2 and currency='BHD' and timezone='Asia/Bahrain')
  or (format_version='FIELDRUSH_7V7' and capacity=14 and goalkeeper_capacity=2 and defender_capacity=6
    and midfielder_capacity=0 and attacker_capacity=6 and currency='USD' and market_city_id is not null
    and price_fils%10=0)
);
grant select(market_city_id) on public.open_queue_games to authenticated;
create index open_queue_games_city_discovery_idx on public.open_queue_games(market_city_id,starts_at)
  where status in ('OPEN','FULL');

create function public.list_fieldrush_cities()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null then raise exception 'You need to sign in again.'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(c) order by c.display_name,c.id),'[]'::jsonb)
    from public.fieldrush_cities c);
end;
$$;
revoke all on function public.list_fieldrush_cities() from public,anon;
grant execute on function public.list_fieldrush_cities() to authenticated;

create function public.admin_save_fieldrush_city(actor_admin_id uuid,city_id_to_use text,values_to_use jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare previous public.fieldrush_cities%rowtype; saved public.fieldrush_cities%rowtype; merged jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if city_id_to_use is null or city_id_to_use !~ '^[a-z][a-z0-9-]{1,63}$' then raise exception 'Choose a lowercase city ID using letters, numbers and hyphens.'; end if;
  if values_to_use is null or jsonb_typeof(values_to_use)<>'object' or values_to_use='{}'::jsonb
    or exists(select 1 from jsonb_object_keys(values_to_use) k where k not in ('display_name','state','country_code','timezone','active')) then
    raise exception 'Invalid city details.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-city-catalog',0));
  select * into previous from public.fieldrush_cities where id=city_id_to_use for update;
  merged:=coalesce(to_jsonb(previous),'{}'::jsonb)||jsonb_build_object('active',coalesce(previous.active,true))||values_to_use;
  if jsonb_typeof(merged->'active') is distinct from 'boolean' then raise exception 'Active status must be true or false.'; end if;
  if not exists(select 1 from pg_timezone_names where name=merged->>'timezone') then raise exception 'Choose a valid IANA timezone.'; end if;
  if not (merged->>'active')::boolean and not exists(select 1 from public.fieldrush_cities where id<>city_id_to_use and active) then
    raise exception 'Keep at least one city active.';
  end if;
  insert into public.fieldrush_cities(id,display_name,state,country_code,timezone,active)
  values(city_id_to_use,trim(merged->>'display_name'),trim(merged->>'state'),upper(trim(merged->>'country_code')),
    merged->>'timezone',(merged->>'active')::boolean)
  on conflict(id) do update set display_name=excluded.display_name,state=excluded.state,
    country_code=excluded.country_code,timezone=excluded.timezone,active=excluded.active returning * into saved;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,'CITY_CATALOG_UPDATED','ACTION',gen_random_uuid(),'Admin maintained the city catalog.',
    coalesce(to_jsonb(previous),'{}'::jsonb),to_jsonb(saved));
  return to_jsonb(saved);
end;
$$;
revoke all on function public.admin_save_fieldrush_city(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.admin_save_fieldrush_city(uuid,text,jsonb) to service_role;

-- All city values are selected from the server-owned catalog. A postal address
-- in Tempe can belong to the Phoenix playing market without losing its address.
create function public.validate_field_market_city()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' or new.market_city_id is distinct from old.market_city_id
    or (new.is_active and not old.is_active) then
    perform 1 from public.fieldrush_cities where id=new.market_city_id and active for share;
    if not found then raise exception 'Choose an active city for this field.'; end if;
  end if;
  return new;
end;
$$;
create trigger validate_field_market_city before insert or update on public.fields
  for each row execute function public.validate_field_market_city();
revoke all on function public.validate_field_market_city() from public,anon,authenticated;

create function public.bind_game_market_city()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare market public.fieldrush_cities%rowtype;
begin
  if new.format_version<>'FIELDRUSH_7V7' then return new; end if;
  if tg_op='UPDATE' then
    if row(new.market_city_id,new.timezone) is distinct from row(old.market_city_id,old.timezone) then
      raise exception 'A scheduled game city cannot change. Create a new game instead.';
    end if;
    return new;
  end if;
  if new.field_id is not null then
    select c.* into market from public.fields f join public.fieldrush_cities c on c.id=f.market_city_id
      where f.id=new.field_id and f.is_active for share of f,c;
  else
    -- Service-owned synthetic games retain their existing Phoenix default.
    select * into market from public.fieldrush_cities where id=coalesce(new.market_city_id,'phoenix') for share;
  end if;
  if market.id is null or not market.active then raise exception 'Choose an active city and field for this game.'; end if;
  new.market_city_id:=market.id;
  new.timezone:=market.timezone;
  return new;
end;
$$;
create trigger a_bind_game_market_city before insert or update on public.open_queue_games
  for each row execute function public.bind_game_market_city();
revoke all on function public.bind_game_market_city() from public,anon,authenticated;

create function public.bind_schedule_market_city()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare market public.fieldrush_cities%rowtype;
begin
  if tg_op='UPDATE' and new.field_id=old.field_id
    and coalesce(current_setting('fieldrush.reconfirm_schedule_city',true),'')<>'on' then
    -- Catalog edits do not move an existing recurring schedule to another city.
    new.market_city_id:=old.market_city_id; new.timezone:=old.timezone;
    if not new.is_active or old.is_active then return new; end if;
  end if;
  select c.* into market from public.fields f join public.fieldrush_cities c on c.id=f.market_city_id
    where f.id=new.field_id and (f.is_active or not new.is_active) for share of f,c;
  if market.id is null or (new.is_active and not market.active) then raise exception 'Choose an active city and field before enabling this schedule.'; end if;
  new.market_city_id:=market.id; new.timezone:=market.timezone;
  return new;
end;
$$;
create trigger bind_schedule_market_city before insert or update on public.game_schedules
  for each row execute function public.bind_schedule_market_city();
revoke all on function public.bind_schedule_market_city() from public,anon,authenticated;

create function fieldrush_private.schedule_kickoff_is_unambiguous(local_kickoff timestamp,city_timezone text)
returns boolean language sql stable set search_path=pg_catalog as $$
  select (local_kickoff at time zone city_timezone) at time zone city_timezone=local_kickoff
    and not exists(select 1 from generate_series(
      (local_kickoff at time zone city_timezone)-interval '3 hours',
      (local_kickoff at time zone city_timezone)+interval '3 hours',interval '15 minutes') candidate
      where candidate<>local_kickoff at time zone city_timezone and candidate at time zone city_timezone=local_kickoff);
$$;
revoke all on function fieldrush_private.schedule_kickoff_is_unambiguous(timestamp,text) from public,anon,authenticated,service_role;

do $migration$
declare d text; old_text text;
begin
  d:=pg_get_functiondef('public.admin_save_field(uuid,uuid,jsonb)'::regprocedure);
  d:=replace(d,'''longitude'',''is_active''','''longitude'',''is_active'',''market_city_id''');
  d:=replace(d,'''is_active'',true) || values_to_use','''is_active'',true,''market_city_id'',''phoenix'') || values_to_use');
  d:=replace(d,'latitude,longitude,is_active,created_by)','latitude,longitude,is_active,created_by,market_city_id)');
  d:=replace(d,'(merged->>''is_active'')::boolean,actor_admin_id)','(merged->>''is_active'')::boolean,actor_admin_id,merged->>''market_city_id'')');
  old_text:='longitude=(merged->>''longitude'')::double precision,is_active=(merged->>''is_active'')::boolean';
  if position(old_text in d)=0 then raise exception 'Saved field writer changed.'; end if;
  d:=replace(d,old_text,old_text||',market_city_id=merged->>''market_city_id'''); execute d;
  d:=pg_get_functiondef('public.enforce_open_queue_permanent_schedule()'::regprocedure);
  old_text:='if new.timezone is distinct from ''America/Phoenix'' then raise exception ''Fieldrush games must use America/Phoenix time.''; end if;';
  if position(old_text in d)=0 then raise exception 'Game timezone contract changed.'; end if;
  d:=replace(d,old_text,'if not exists(select 1 from pg_timezone_names where name=new.timezone) then raise exception ''Choose a valid game timezone.''; end if;'); execute d;

  d:=pg_get_functiondef('fieldrush_private.generate_game_schedule(uuid)'::regprocedure);
  old_text:='    begin'||E'\n      -- The existing field-binding trigger snapshots';
  if position(old_text in d)=0 then raise exception 'Recurring schedule occurrence contract changed.'; end if;
  d:=replace(d,old_text,$dst$    begin
      if not exists(select 1 from public.fields f join public.fieldrush_cities c on c.id=f.market_city_id
        where f.id=s.field_id and f.market_city_id=s.market_city_id and c.timezone=s.timezone and f.is_active and c.active) then
        raise exception 'The field city or timezone changed. Review the kickoff and save the selected field again before generating games.';
      end if;
      if not fieldrush_private.schedule_kickoff_is_unambiguous(day_to_use+s.kickoff_time,s.timezone) then
        raise exception 'This local kickoff is missing or repeated due to daylight saving time. Choose a different kickoff.';
      end if;
      -- The existing field-binding trigger snapshots$dst$); execute d;

  d:=pg_get_functiondef('public.admin_save_game_schedule(uuid,uuid,jsonb)'::regprocedure);
  old_text:='  if schedule_id_to_update is null then'||E'\n    insert into public.game_schedules';
  if position(old_text in d)=0 then raise exception 'Schedule save contract changed.'; end if;
  d:=replace(d,old_text,E'  perform set_config(''fieldrush.reconfirm_schedule_city'',case when values_to_use ? ''field_id'' then ''on'' else ''off'' end,true);\n'||old_text);
  d:=replace(d,'  insert into public.admin_audit_events(',E'  perform set_config(''fieldrush.reconfirm_schedule_city'',''off'',true);\n  insert into public.admin_audit_events('); execute d;

  -- Filter before the existing feed LIMIT; cities sharing a timezone stay apart.
  d:=pg_get_functiondef('public.list_open_queue_games_for_market(text)'::regprocedure);
  d:=replace(d,'public.list_open_queue_games_for_market(timezone_to_use text)','public.list_open_queue_games_for_city(city_id_to_use text)');
  old_text:='game.timezone = timezone_to_use';
  if position(old_text in d)=0 then raise exception 'Market feed filter changed.'; end if;
  d:=replace(d,old_text,'game.market_city_id = city_id_to_use');
  d:=replace(d,'timezone_to_use is null or timezone_to_use not in (''America/Phoenix'', ''Asia/Bahrain'')',
    'city_id_to_use is null or not exists(select 1 from public.fieldrush_cities catalog where catalog.id=city_id_to_use and catalog.active)');
  execute d;
end;
$migration$;
revoke all on function public.list_open_queue_games_for_city(text) from public,anon;
grant execute on function public.list_open_queue_games_for_city(text) to authenticated,service_role;

-- Retain account privacy/authentication rules from the existing implementation.
alter function public.get_my_fieldrush_account() rename to get_my_fieldrush_account_before_cities;
revoke all on function public.get_my_fieldrush_account_before_cities() from public,anon,authenticated;
create function public.get_my_fieldrush_account()
returns jsonb language plpgsql security definer set search_path=public,fieldrush_private,pg_temp as $$
declare result jsonb; city public.fieldrush_cities%rowtype; caller uuid:=fieldrush_private.require_user();
begin
  result:=public.get_my_fieldrush_account_before_cities();
  select c.* into city from fieldrush_private.accounts a join public.fieldrush_cities c on c.id=a.preferred_city_id where a.user_id=caller;
  if city.id is null then select * into city from public.fieldrush_cities where id='phoenix'; end if;
  return result||jsonb_build_object('preferred_city_id',city.id,'home_city',city.display_name||', '||city.state,
    'home_city_locked',false,'market_timezone',city.timezone,'preferred_city_active',city.active);
end;
$$;
create function public.set_my_fieldrush_city(city_id_to_use text)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_private,pg_temp as $$
declare caller uuid:=fieldrush_private.require_user();
begin
  perform 1 from public.fieldrush_cities where id=city_id_to_use and active for share;
  if not found then raise exception 'Choose an available city.'; end if;
  update fieldrush_private.accounts set preferred_city_id=city_id_to_use where user_id=caller and status='active';
  if not found then raise exception 'Finish creating your account first.'; end if;
  return public.get_my_fieldrush_account();
end;
$$;
revoke all on function public.get_my_fieldrush_account(),public.set_my_fieldrush_city(text) from public,anon;
grant execute on function public.get_my_fieldrush_account(),public.set_my_fieldrush_city(text) to authenticated;
notify pgrst,'reload schema';
