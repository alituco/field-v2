-- Formation is saved per game. Historical games and existing recurring rules
-- retain 1/3/3; only newly created games/rules default to 1/2/4 per side.
alter table public.open_queue_games
  alter column defender_capacity set default 4,
  alter column attacker_capacity set default 8,
  drop constraint open_queue_games_versioned_format_check;
alter table public.open_queue_games add constraint open_queue_games_versioned_format_check check (
  (format_version='LEGACY_6V6' and capacity=12 and goalkeeper_capacity=2 and defender_capacity=4
    and midfielder_capacity=4 and attacker_capacity=2 and currency='BHD' and timezone='Asia/Bahrain')
  or (format_version='FIELDRUSH_7V7' and capacity=14 and goalkeeper_capacity=2
    and defender_capacity between 0 and 12 and defender_capacity%2=0
    and attacker_capacity between 0 and 12 and attacker_capacity%2=0
    and defender_capacity+attacker_capacity=12 and midfielder_capacity=0
    and currency='USD' and market_city_id is not null and price_fils%10=0)
);
grant select(goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity)
  on public.open_queue_games to authenticated;

alter table public.game_schedules
  add column goalkeepers_per_side smallint not null default 1,
  add column defenders_per_side smallint not null default 3,
  add column attackers_per_side smallint not null default 3;
alter table public.game_schedules
  alter column defenders_per_side set default 2,
  alter column attackers_per_side set default 4,
  add constraint game_schedules_formation_check check (
    goalkeepers_per_side=1 and defenders_per_side between 0 and 6
    and attackers_per_side between 0 and 6 and defenders_per_side+attackers_per_side=6
  );

create function public.assert_fieldrush_solo_formation(
  goalkeepers_per_side integer, defenders_per_side integer, attackers_per_side integer
)
returns void language plpgsql immutable set search_path=public,pg_temp as $$
begin
  if goalkeepers_per_side is distinct from 1 or defenders_per_side is null or attackers_per_side is null
    or defenders_per_side not between 0 and 6 or attackers_per_side not between 0 and 6
    or defenders_per_side+attackers_per_side<>6 then
    raise exception 'Each team needs 1 keeper and 6 outfield players, with whole-number position counts.' using errcode='22023';
  end if;
end;
$$;
revoke all on function public.assert_fieldrush_solo_formation(integer,integer,integer)
  from public,anon,authenticated,service_role;

create or replace function public.protect_open_queue_format_version()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if (new.format_version,new.currency,new.capacity,new.timezone) is distinct from
    (old.format_version,old.currency,old.capacity,old.timezone) then
    raise exception 'A game format, market and currency cannot change. Create a new game instead.';
  end if;
  if (new.goalkeeper_capacity,new.defender_capacity,new.midfielder_capacity,new.attacker_capacity) is distinct from
    (old.goalkeeper_capacity,old.defender_capacity,old.midfielder_capacity,old.attacker_capacity) then
    if old.format_version<>'FIELDRUSH_7V7' or old.status<>'OPEN' or new.status<>'OPEN'
      or old.operational_state<>'NORMAL' or new.operational_state<>'NORMAL'
      or old.starts_at<=clock_timestamp() or new.starts_at<=clock_timestamp()
      or old.teams_assigned_at is not null or new.teams_assigned_at is not null
      or old.white_score is not null or old.black_score is not null
      or new.white_score is not null or new.black_score is not null
      or exists(select 1 from public.open_queue_bookings where game_id=old.id)
      or exists(select 1 from public.payment_intents where payload->>'game_id'=old.id::text)
      or exists(select 1 from public.open_queue_clock_states where game_id=old.id
        and (status<>'NOT_STARTED' or started_at is not null or accumulated_seconds<>0)) then
      raise exception 'Formation is locked after a booking, checkout or match activity. Create a new game instead.';
    end if;
    perform public.assert_fieldrush_solo_formation(new.goalkeeper_capacity/2,new.defender_capacity/2,new.attacker_capacity/2);
  end if;
  return new;
end;
$$;
revoke all on function public.protect_open_queue_format_version() from public,anon,authenticated,service_role;

-- The checkout insert and formation edit serialize on the same game row.
-- Alphabetical trigger order keeps the existing player lock before this game
-- lock, matching the paid/free booking path. A stale quoted formation fails
-- before any provider intent is created; old quote payloads remain readable.
create function public.lock_solo_checkout_formation()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare game public.open_queue_games%rowtype; formation jsonb;
begin
  if new.purpose<>'SOLO_BOOKING' then return new; end if;
  select * into game from public.open_queue_games where id=(new.payload->>'game_id')::uuid for share;
  if game.id is null then raise exception 'Solo game not found.'; end if;
  formation:=jsonb_build_object('goalkeeper_capacity',game.goalkeeper_capacity,
    'defender_capacity',game.defender_capacity,'midfielder_capacity',game.midfielder_capacity,
    'attacker_capacity',game.attacker_capacity);
  if new.quote_snapshot ? 'formation' and new.quote_snapshot->'formation' is distinct from formation then
    raise exception 'The game formation changed. Reopen checkout to review its positions.';
  end if;
  return new;
end;
$$;
create trigger lock_solo_checkout_formation before insert on public.payment_intents
  for each row execute function public.lock_solo_checkout_formation();
revoke all on function public.lock_solo_checkout_formation() from public,anon,authenticated,service_role;

create function public.admin_create_open_queue_game(
  actor_admin_id uuid, field_id_to_use uuid, starts_at_to_use timestamptz,
  price_fils_to_use integer, age_label_to_use text, duration_minutes_to_use integer,
  highest_division_to_use integer, lowest_division_to_use integer,
  goalkeepers_per_side_to_use integer, defenders_per_side_to_use integer, attackers_per_side_to_use integer
)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare created_game public.open_queue_games%rowtype; age_text text:=trim(coalesce(age_label_to_use,''));
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  perform public.assert_fieldrush_solo_formation(goalkeepers_per_side_to_use,defenders_per_side_to_use,attackers_per_side_to_use);
  if field_id_to_use is null then raise exception 'Choose a saved field before creating the game.'; end if;
  if char_length(age_text) not between 2 and 40 then raise exception 'Age label must be between 2 and 40 characters.'; end if;
  if starts_at_to_use is null or starts_at_to_use<=now() then raise exception 'The solo game must be scheduled in the future.'; end if;
  if duration_minutes_to_use is null or duration_minutes_to_use not between 30 and 180 then
    raise exception 'Duration must be between 30 and 180 whole minutes.';
  end if;
  if price_fils_to_use is null or price_fils_to_use not between 0 and 100000 or price_fils_to_use%10<>0 then
    raise exception 'Price must be between 0 and 100 USD, in whole cents.';
  end if;
  if highest_division_to_use is null or lowest_division_to_use is null
    or highest_division_to_use not between 1 and 5 or lowest_division_to_use not between highest_division_to_use and 5 then
    raise exception 'Choose a division range from 1 to 5, strongest division first.';
  end if;
  insert into public.open_queue_games(status,field_id,venue,starts_at,ends_at,timezone,price_fils,age_label,created_by,
    highest_division,lowest_division,goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity)
  values('OPEN',field_id_to_use,'Saved field',starts_at_to_use,starts_at_to_use+make_interval(mins=>duration_minutes_to_use),
    'America/Phoenix',price_fils_to_use,age_text,actor_admin_id,highest_division_to_use,lowest_division_to_use,
    goalkeepers_per_side_to_use*2,defenders_per_side_to_use*2,0,attackers_per_side_to_use*2) returning * into created_game;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,'SOLO_GAME_CREATED','SOLO_MATCH',created_game.id,
    'Admin created a one-off solo game at a saved field.','{}',to_jsonb(created_game));
  return created_game.id;
end;
$$;
create or replace function public.admin_create_open_queue_game(
  actor_admin_id uuid, field_id_to_use uuid, starts_at_to_use timestamptz,
  price_fils_to_use integer, age_label_to_use text, duration_minutes_to_use integer,
  highest_division_to_use integer, lowest_division_to_use integer
)
returns uuid language sql security definer set search_path=public,pg_temp as $$
  select public.admin_create_open_queue_game(actor_admin_id,field_id_to_use,starts_at_to_use,
    price_fils_to_use,age_label_to_use,duration_minutes_to_use,highest_division_to_use,lowest_division_to_use,1,2,4);
$$;
revoke all on function public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer,integer,integer,integer,integer,integer)
  from public,anon,authenticated;
grant execute on function public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer,integer,integer,integer,integer,integer)
  to service_role;

create function public.admin_update_open_queue_game_formation(
  actor_admin_id uuid, game_id_to_use uuid,
  goalkeepers_per_side_to_use integer, defenders_per_side_to_use integer, attackers_per_side_to_use integer,
  reason_to_use text
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare before_game public.open_queue_games%rowtype; saved public.open_queue_games%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  perform public.assert_fieldrush_solo_formation(goalkeepers_per_side_to_use,defenders_per_side_to_use,attackers_per_side_to_use);
  if char_length(trim(coalesce(reason_to_use,''))) not between 8 and 1000 then
    raise exception 'Provide a formation change reason between 8 and 1000 characters.';
  end if;
  select * into before_game from public.open_queue_games where id=game_id_to_use for update;
  if before_game.id is null then raise exception 'Solo game not found.'; end if;
  if before_game.format_version<>'FIELDRUSH_7V7' or before_game.status<>'OPEN' or before_game.starts_at<=clock_timestamp()
    or before_game.operational_state<>'NORMAL'
    or before_game.teams_assigned_at is not null or before_game.white_score is not null or before_game.black_score is not null
    or exists(select 1 from public.open_queue_bookings where game_id=before_game.id)
    or exists(select 1 from public.payment_intents where payload->>'game_id'=before_game.id::text)
    or exists(select 1 from public.open_queue_clock_states where game_id=before_game.id
      and (status<>'NOT_STARTED' or started_at is not null or accumulated_seconds<>0)) then
    raise exception 'Formation is locked after a booking, checkout or match activity. Create a new game instead.';
  end if;
  update public.open_queue_games set goalkeeper_capacity=goalkeepers_per_side_to_use*2,
    defender_capacity=defenders_per_side_to_use*2,attacker_capacity=attackers_per_side_to_use*2
    where id=before_game.id returning * into saved;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,'SOLO_GAME_FORMATION_UPDATED','SOLO_MATCH',saved.id,trim(reason_to_use),to_jsonb(before_game),to_jsonb(saved));
  return to_jsonb(saved);
end;
$$;
revoke all on function public.admin_update_open_queue_game_formation(uuid,uuid,integer,integer,integer,text) from public,anon,authenticated;
grant execute on function public.admin_update_open_queue_game_formation(uuid,uuid,integer,integer,integer,text) to service_role;

-- Extend the current audited schedule implementation in place. Existing
-- materialized games remain tombstones; only future occurrences use edits.
do $migration$
declare definition text; anchor text;
begin
  definition:=pg_get_functiondef('public.admin_save_game_schedule(uuid,uuid,jsonb)'::regprocedure);
  anchor:='''highest_division'',''lowest_division''';
  if position(anchor in definition)=0 then raise exception 'Schedule formation allowlist contract changed.'; end if;
  definition:=replace(definition,anchor,anchor||',''goalkeepers_per_side'',''defenders_per_side'',''attackers_per_side''');
  anchor:='''lowest_division'',5,''is_active'',true';
  if position(anchor in definition)=0 then raise exception 'Schedule formation defaults contract changed.'; end if;
  definition:=replace(definition,anchor,'''lowest_division'',5,''goalkeepers_per_side'',1,''defenders_per_side'',2,''attackers_per_side'',4,''is_active'',true');
  anchor:='booking_window_days,price_fils,age_label,is_active,created_by,highest_division,lowest_division)';
  if position(anchor in definition)=0 then raise exception 'Schedule formation insertion contract changed.'; end if;
  definition:=replace(definition,anchor,'booking_window_days,price_fils,age_label,is_active,created_by,highest_division,lowest_division,goalkeepers_per_side,defenders_per_side,attackers_per_side)');
  anchor:='(merged->>''lowest_division'')::smallint)';
  if position(anchor in definition)=0 then raise exception 'Schedule formation values contract changed.'; end if;
  definition:=replace(definition,anchor,'(merged->>''lowest_division'')::smallint,(merged->>''goalkeepers_per_side'')::smallint,(merged->>''defenders_per_side'')::smallint,(merged->>''attackers_per_side'')::smallint)');
  anchor:='lowest_division=(merged->>''lowest_division'')::smallint';
  if position(anchor in definition)=0 then raise exception 'Schedule formation update contract changed.'; end if;
  definition:=replace(definition,anchor,anchor||',goalkeepers_per_side=(merged->>''goalkeepers_per_side'')::smallint,defenders_per_side=(merged->>''defenders_per_side'')::smallint,attackers_per_side=(merged->>''attackers_per_side'')::smallint');
  -- Number validation above now covers the added keys through the shared
  -- highest/lowest allowlist replacement. Enforce the exact total as well.
  anchor:='  if jsonb_typeof(merged->''is_active'')';
  if position(anchor in definition)=0 then raise exception 'Schedule formation validation contract changed.'; end if;
  definition:=replace(definition,anchor,E'  perform public.assert_fieldrush_solo_formation((merged->>''goalkeepers_per_side'')::integer,(merged->>''defenders_per_side'')::integer,(merged->>''attackers_per_side'')::integer);\n'||anchor);
  execute definition;

  definition:=pg_get_functiondef('fieldrush_private.generate_game_schedule(uuid)'::regprocedure);
  anchor:='created_by,highest_division,lowest_division)';
  if position(anchor in definition)=0 then raise exception 'Generated game formation columns changed.'; end if;
  definition:=replace(definition,anchor,'created_by,highest_division,lowest_division,goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity)');
  anchor:='s.created_by,s.highest_division,s.lowest_division)';
  if position(anchor in definition)=0 then raise exception 'Generated game formation values changed.'; end if;
  execute replace(definition,anchor,'s.created_by,s.highest_division,s.lowest_division,s.goalkeepers_per_side*2,s.defenders_per_side*2,0,s.attackers_per_side*2)');

  definition:=pg_get_functiondef('public.preview_open_queue_booking_cost(uuid,text)'::regprocedure);
  anchor:='  return jsonb_build_object(';
  if position(anchor in definition)=0 then raise exception 'Solo formation quote contract changed.'; end if;
  execute replace(definition,anchor,$quote$  return jsonb_build_object(
    'formation',jsonb_build_object('goalkeeper_capacity',game_to_book.goalkeeper_capacity,
      'defender_capacity',game_to_book.defender_capacity,'midfielder_capacity',game_to_book.midfielder_capacity,
      'attacker_capacity',game_to_book.attacker_capacity),$quote$);

  definition:=pg_get_functiondef('public.respond_open_queue_party_invitation(uuid,boolean)'::regprocedure);
  anchor:='Joining this party would make the required 1 GK, 2 DEF, 2 MID, and 1 ATT teams impossible.';
  if position(anchor in definition)=0 then raise exception 'Party formation rejection contract changed.'; end if;
  execute replace(definition,anchor,'Joining this party would make the configured team formation impossible.');
end;
$migration$;
notify pgrst, 'reload schema';
