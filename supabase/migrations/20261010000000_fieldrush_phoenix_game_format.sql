-- Fieldrush launch rules are prospective. Existing games, MID bookings,
-- published policies, rating events and balances are never rewritten.
-- Deploy together with the currency-aware clients/payment service.
alter table public.open_queue_games
  add column format_version text not null default 'LEGACY_6V6',
  add column currency text not null default 'BHD';
alter table public.open_queue_games
  alter column format_version set default 'FIELDRUSH_7V7',
  alter column currency set default 'USD',
  alter column capacity set default 14,
  alter column defender_capacity set default 6,
  alter column midfielder_capacity set default 0,
  alter column attacker_capacity set default 6,
  alter column timezone set default 'America/Phoenix',
  alter column price_fils set default 13000;
alter table public.open_queue_games
  drop constraint open_queue_games_capacity_check,
  drop constraint open_queue_games_goalkeeper_capacity_check,
  drop constraint open_queue_games_defender_capacity_check,
  drop constraint open_queue_games_midfielder_capacity_check,
  drop constraint open_queue_games_attacker_capacity_check,
  drop constraint open_queue_games_permanent_timezone_check,
  drop constraint open_queue_games_permanent_schedule_check;
alter table public.open_queue_games add constraint open_queue_games_versioned_format_check check (
  (format_version = 'LEGACY_6V6' and capacity = 12 and goalkeeper_capacity = 2
    and defender_capacity = 4 and midfielder_capacity = 4 and attacker_capacity = 2
    and currency = 'BHD' and timezone = 'Asia/Bahrain')
  or
  (format_version = 'FIELDRUSH_7V7' and capacity = 14 and goalkeeper_capacity = 2
    and defender_capacity = 6 and midfielder_capacity = 0 and attacker_capacity = 6
    and currency = 'USD' and timezone = 'America/Phoenix' and price_fils % 10 = 0)
);
comment on column public.open_queue_games.price_fils is
  'Integer thousandths of game.currency: legacy BHD fils, USD mills (13000 = USD 13.00). USD prices must be whole cents.';
comment on column public.open_queue_games.format_version is
  'Immutable game format. LEGACY_6V6 remains readable/bookable without remapping historical MID roles.';

create function public.protect_open_queue_format_version()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if (new.format_version, new.currency, new.capacity, new.goalkeeper_capacity,
      new.defender_capacity, new.midfielder_capacity, new.attacker_capacity, new.timezone)
    is distinct from
    (old.format_version, old.currency, old.capacity, old.goalkeeper_capacity,
      old.defender_capacity, old.midfielder_capacity, old.attacker_capacity, old.timezone)
  then
    raise exception 'A game format, market and currency cannot change. Create a new game instead.';
  end if;
  return new;
end;
$$;
create trigger protect_open_queue_format_version before update on public.open_queue_games
  for each row execute function public.protect_open_queue_format_version();
revoke all on function public.protect_open_queue_format_version() from public, anon, authenticated;

create or replace function public.enforce_open_queue_permanent_schedule()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare local_start timestamp;
begin
  if new.timezone not in ('Asia/Bahrain', 'America/Phoenix') then
    raise exception 'Choose a supported game timezone.';
  end if;
  if new.starts_at is null or new.ends_at is null then
    raise exception 'Games need a start and end time.';
  end if;
  local_start := new.starts_at at time zone new.timezone;
  if extract(isodow from local_start) not in (2, 5)
    or local_start::time <> time '20:30:00'
    or new.ends_at <> new.starts_at + interval '1 hour'
  then
    raise exception 'Solo games run Tuesday or Friday, 8:30–9:30 PM in the game timezone.';
  end if;
  if new.status <> 'CANCELLED' then
    perform pg_advisory_xact_lock(hashtextextended(
      'open-queue-start|' || extract(epoch from new.starts_at)::text, 0));
    if exists (select 1 from public.open_queue_games g
      where g.starts_at = new.starts_at and g.status <> 'CANCELLED' and g.id <> new.id) then
      raise exception 'An Open Queue game already exists at that start time.';
    end if;
  end if;
  return new;
end;
$$;

-- Candidate units are accepted parties or individual players. Empty future
-- slots are singleton units only when checking whether a party can be accepted.
-- At most 14 units => 8192 complementary-mask pairs; no heuristic can split a
-- party or sacrifice positional balance. Tie-breaking uses stable unit IDs.
create function public.find_open_queue_white_assignment(game_id_to_use uuid, include_future boolean)
returns uuid[] language plpgsql security definer set search_path = public, pg_temp as $$
declare g public.open_queue_games%rowtype; result uuid[];
begin
  select * into g from public.open_queue_games where id = game_id_to_use;
  if g.id is null then return null; end if;
  if exists (select 1 from public.open_queue_bookings b
    where b.game_id = g.id and b.status = 'CONFIRMED'
    group by b.role having count(*) > case b.role
      when 'GK' then g.goalkeeper_capacity when 'DEF' then g.defender_capacity
      when 'MID' then g.midfielder_capacity when 'ATT' then g.attacker_capacity end)
  then return null; end if;
  if not include_future and (select count(*) from public.open_queue_bookings
    where game_id = g.id and status = 'CONFIRMED') <> g.capacity then return null; end if;

  with participants as (
    select b.id, b.role, coalesce(r.skill_rating, 1200) as sr,
      coalesce('party:' || p.id::text, 'booking:' || b.id::text) as unit_key
    from public.open_queue_bookings b
    left join public.player_ratings r on r.profile_id = b.profile_id
    left join public.open_queue_party_members m on m.game_id = b.game_id
      and m.profile_id = b.profile_id and m.status = 'ACCEPTED'
    left join public.open_queue_parties p on p.id = m.party_id
      and p.game_id = b.game_id and p.status = 'ACTIVE'
    where b.game_id = g.id and b.status = 'CONFIRMED'
  ), booked_units as (
    select unit_key, array_agg(id order by id) as booking_ids, sum(sr) as sr,
      count(*) filter (where role = 'GK') as gk,
      count(*) filter (where role = 'DEF') as def,
      count(*) filter (where role = 'MID') as mid,
      count(*) filter (where role = 'ATT') as att
    from participants group by unit_key
  ), role_slots as (
    select v.role, v.capacity - (select count(*) from participants p where p.role = v.role) as remaining
    from (values ('GK', g.goalkeeper_capacity), ('DEF', g.defender_capacity),
      ('MID', g.midfielder_capacity), ('ATT', g.attacker_capacity)) v(role, capacity)
  ), future_units as (
    select 'future:' || s.role || ':' || n::text as unit_key,
      '{}'::uuid[] as booking_ids, 0::bigint as sr,
      (s.role = 'GK')::integer as gk, (s.role = 'DEF')::integer as def,
      (s.role = 'MID')::integer as mid, (s.role = 'ATT')::integer as att
    from role_slots s cross join lateral generate_series(1, s.remaining) n
    where include_future
  ), units as (
    select u.*, (row_number() over (order by unit_key) - 1)::integer as idx
    from (select * from booked_units union all select * from future_units) u
  ), totals as (
    select count(*)::integer as n, coalesce(sum(sr), 0) as sr from units
  ), candidates as (
    select mask, load.sr
    from totals cross join lateral generate_series(1::bigint, (1::bigint << totals.n) - 1, 2::bigint) mask
    cross join lateral (
      select sum(u.gk) as gk, sum(u.def) as def, sum(u.mid) as mid, sum(u.att) as att, sum(u.sr) as sr
      from units u where (mask & (1::bigint << u.idx)) <> 0
    ) load
    where load.gk = g.goalkeeper_capacity / 2 and load.def = g.defender_capacity / 2
      and load.mid = g.midfielder_capacity / 2 and load.att = g.attacker_capacity / 2
    order by abs(load.sr * 2 - totals.sr), mask limit 1
  )
  select array(select bid from units u cross join lateral unnest(u.booking_ids) bid
    where (c.mask & (1::bigint << u.idx)) <> 0 order by bid)
  into result from candidates c;
  return result;
end;
$$;
revoke all on function public.find_open_queue_white_assignment(uuid, boolean) from public, anon, authenticated;

create or replace function public.open_queue_party_assignment_is_possible(game_id_to_check uuid)
returns boolean language sql security definer set search_path = public, pg_temp as $$
  select public.find_open_queue_white_assignment(game_id_to_check, true) is not null;
$$;
revoke all on function public.open_queue_party_assignment_is_possible(uuid) from public, anon, authenticated;

create or replace function public.assign_open_queue_teams(game_id_to_assign uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare g public.open_queue_games%rowtype; white_ids uuid[];
  white_average numeric; black_average numeric; overall_average numeric;
begin
  select * into g from public.open_queue_games where id = game_id_to_assign for update;
  if g.id is null then raise exception 'Open Queue game not found.'; end if;
  if g.status <> 'FULL' then raise exception 'Teams can only be assigned when an Open Queue game is full.'; end if;
  if clock_timestamp() < public.open_queue_team_assignment_at(game_id_to_assign)
    and nullif(current_setting('field.force_open_queue_team_assignment', true), '')
      is distinct from game_id_to_assign::text then return; end if;

  update public.open_queue_party_members m set status = 'CANCELLED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
  from public.open_queue_parties p where m.party_id = p.id and m.game_id = g.id
    and m.status = 'INVITED' and p.status = 'ACTIVE';

  -- Never rewrite a released/started valid lineup on subsequent detail reads.
  if g.teams_assigned_at is not null and g.white_average_sr is not null
    and g.black_average_sr is not null and g.match_average_sr is not null
    and g.team_sr_spread is not null
    and (select count(*) from public.open_queue_bookings where game_id = g.id and status = 'CONFIRMED') = g.capacity
    and not exists (select 1 from public.open_queue_bookings b where b.game_id = g.id and b.status = 'CONFIRMED'
      and (b.team is null or b.rating_at_team_assignment is null))
    and not exists (
      select 1 from (values ('GK', g.goalkeeper_capacity / 2), ('DEF', g.defender_capacity / 2),
        ('MID', g.midfielder_capacity / 2), ('ATT', g.attacker_capacity / 2)) v(role, n)
      cross join (values ('WHITE'), ('BLACK')) side(team)
      where (select count(*) from public.open_queue_bookings b
        where b.game_id = g.id and b.status = 'CONFIRMED' and b.role = v.role and b.team = side.team) <> v.n
    ) and not exists (
      select 1 from public.open_queue_parties p join public.open_queue_party_members m on m.party_id = p.id
      join public.open_queue_bookings b on b.game_id = m.game_id and b.profile_id = m.profile_id and b.status = 'CONFIRMED'
      where p.game_id = g.id and p.status = 'ACTIVE' and m.status = 'ACCEPTED'
      group by p.id having count(distinct b.team) > 1
    ) then return; end if;

  insert into public.player_ratings (profile_id)
    select profile_id from public.open_queue_bookings where game_id = g.id and status = 'CONFIRMED'
    on conflict (profile_id) do nothing;
  perform r.profile_id from public.player_ratings r join public.open_queue_bookings b on b.profile_id = r.profile_id
    where b.game_id = g.id and b.status = 'CONFIRMED' order by r.profile_id for update of r;
  white_ids := public.find_open_queue_white_assignment(g.id, false);
  if white_ids is null or cardinality(white_ids) <> g.capacity / 2 then
    raise exception 'The booked positions and parties cannot form two complete balanced teams.';
  end if;
  update public.open_queue_bookings b set team = case when b.id = any(white_ids) then 'WHITE' else 'BLACK' end,
    rating_at_team_assignment = r.skill_rating, rating_at_match_start = null, rating_change = null
  from public.player_ratings r where b.game_id = g.id and b.status = 'CONFIRMED' and r.profile_id = b.profile_id;
  select avg(rating_at_team_assignment) filter (where team = 'WHITE'),
    avg(rating_at_team_assignment) filter (where team = 'BLACK'), avg(rating_at_team_assignment)
  into white_average, black_average, overall_average
  from public.open_queue_bookings where game_id = g.id and status = 'CONFIRMED';
  update public.open_queue_games set white_average_sr = round(white_average, 2), black_average_sr = round(black_average, 2),
    match_average_sr = round(overall_average, 2), team_sr_spread = round(abs(white_average - black_average), 2),
    teams_assigned_at = clock_timestamp() where id = g.id;
end;
$$;
revoke all on function public.assign_open_queue_teams(uuid) from public, anon, authenticated;
grant execute on function public.assign_open_queue_teams(uuid) to service_role;

-- Scope market changes to newly-created ratings; all historical rows remain.
alter table public.player_ratings alter column region set default 'phoenix';

create or replace function public.get_my_fieldrush_account()
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private as $$
declare caller uuid := fieldrush_private.require_user(); account fieldrush_private.accounts%rowtype;
  identity auth.users%rowtype; contact_email text; market text;
begin
  select * into identity from auth.users where id = caller;
  select * into account from fieldrush_private.accounts where user_id = caller;
  select region into market from public.player_ratings where profile_id = caller;
  market := coalesce(market, 'phoenix');
  contact_email := coalesce(account.email, nullif(identity.email, ''));
  return jsonb_build_object(
    'first_name', coalesce(account.first_name, ''), 'last_name', coalesce(account.last_name, ''),
    'username', coalesce(account.username, ''), 'date_of_birth', account.date_of_birth,
    'email', coalesce(contact_email, ''),
    'phone', case when nullif(identity.phone, '') is null then '' else '+' || ltrim(identity.phone, '+') end,
    'phone_verified', identity.phone_confirmed_at is not null and nullif(identity.phone, '') is not null,
    'email_verified', identity.email_confirmed_at is not null
      and lower(coalesce(identity.email, '')) = lower(coalesce(contact_email, '')) and nullif(contact_email, '') is not null,
    'google_linked', exists (select 1 from auth.identities where user_id = caller and provider = 'google'),
    'onboarding_completed', account.onboarding_completed_at is not null and account.status = 'active',
    'tour_completed', account.tour_completed_at is not null, 'status', coalesce(account.status, 'onboarding'),
    'ranking_region', market, 'home_city', case market when 'phoenix' then 'Phoenix, AZ' when 'bahrain' then 'Bahrain' else market end,
    'home_city_locked', true
  );
end;
$$;

-- Existing security-definer implementations contain payment/rating safeguards
-- added by later migrations. Only these exact, asserted market literals change.
do $migration$
declare definition text; signature text;
begin
  definition := pg_get_functiondef('public.admin_create_open_queue_game(uuid,text,timestamptz,integer,text)'::regprocedure);
  if position('''Asia/Bahrain''' in definition) = 0 then raise exception 'Admin game timezone contract changed.'; end if;
  definition := replace(definition, '''Asia/Bahrain''', '''America/Phoenix''');
  definition := replace(definition, 'Price must be between 0 and 100 BHD.', 'Price must be between 0 and 100 USD, in whole cents.');
  definition := replace(definition, 'price_fils_to_use not between 0 and 100000',
    '(price_fils_to_use not between 0 and 100000 or price_fils_to_use % 10 <> 0)');
  execute definition;
  foreach signature in array array['public.season_player_rating_rankings(text,date,date)', 'public.get_my_season_player_rating(text,date,date)'] loop
    definition := pg_get_functiondef(signature::regprocedure);
    if position('event.effective_at at time zone ''Asia/Bahrain''' in definition) = 0 then
      raise exception 'Season timezone contract changed: %', signature;
    end if;
    definition := replace(definition, 'event.effective_at at time zone ''Asia/Bahrain''',
      'event.effective_at at time zone (case lower(trim(region_to_use)) when ''phoenix'' then ''America/Phoenix'' else ''Asia/Bahrain'' end)');
    execute definition;
  end loop;
end;
$migration$;

-- Terms capture the actual versioned game format and currency. Financial rules
-- remain the effective published policy; no historical snapshot is touched.
create function public.bind_fieldrush_solo_format_terms()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare g public.open_queue_games%rowtype;
begin
  if new.match_kind = 'SOLO' then
    select * into g from public.open_queue_games where id = new.open_queue_game_id;
    new.policy_snapshot := jsonb_set(new.policy_snapshot, '{timezone}', to_jsonb(g.timezone), true);
    new.policy_snapshot := jsonb_set(new.policy_snapshot, '{solo,playersPerSide}', to_jsonb(g.capacity / 2), false);
    new.policy_snapshot := jsonb_set(new.policy_snapshot, '{wallet,currency}', to_jsonb(g.currency), false);
  end if;
  return new;
end;
$$;
create trigger bind_fieldrush_solo_format_terms before insert or update of policy_snapshot on public.match_reliability_terms
  for each row execute function public.bind_fieldrush_solo_format_terms();
revoke all on function public.bind_fieldrush_solo_format_terms() from public, anon, authenticated;

-- Editable future policy drafts use 7v7 Solo. Clan is intentionally unchanged:
-- its booking/referee format is outside this Home + account release.
create or replace function public.normalize_reliability_draft_format()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.state = 'DRAFT' then
    new.config := jsonb_set(new.config, '{solo,playersPerSide}', '7'::jsonb, false);
    new.config := jsonb_set(new.config, '{clan,playersPerSide}', '6'::jsonb, false);
    new.config := jsonb_set(new.config, '{clan,minimumOnTimeWithoutClanStrike}',
      to_jsonb(least(coalesce((new.config #>> '{clan,minimumOnTimeWithoutClanStrike}')::integer, 6), 6)), false);
    new.config := jsonb_set(new.config, '{clan,minimumAtKickoffWithoutForfeit}',
      to_jsonb(least(coalesce((new.config #>> '{clan,minimumAtKickoffWithoutForfeit}')::integer, 6), 6)), false);
  end if;
  return new;
end;
$$;
create or replace function public.reliability_policy_release_controls_are_valid(config_to_check jsonb)
returns boolean language plpgsql immutable set search_path = public, pg_temp as $$
begin
  return (config_to_check #>> '{solo,playersPerSide}')::integer = 7
    and (config_to_check #>> '{clan,playersPerSide}')::integer = 6
    and (config_to_check #>> '{solo,outcomes,fieldCancelled,strikes}')::integer = 0
    and (config_to_check #>> '{injury,strikeDelta}')::integer = 0
    and (config_to_check #>> '{injury,requiresRefereeVerification}')::boolean is true
    and not (config_to_check #>> '{appeals,routineTrafficAutomaticallyExcused}')::boolean;
exception when others then return false;
end;
$$;
update public.reliability_policy_versions set config = config where state = 'DRAFT';

-- Preserve the legacy all-market RPC and its complete operational-state return
-- contract. Market discovery must filter before LIMIT, otherwise 40 earlier
-- Bahrain games can hide every Phoenix game from the new Home feed.
do $migration$
declare definition text; old_where text := '  where game.status in (''OPEN'', ''FULL'')';
begin
  definition := pg_get_functiondef('public.list_open_queue_games()'::regprocedure);
  if position('CREATE OR REPLACE FUNCTION public.list_open_queue_games()' in definition) = 0
    or position(old_where in definition) = 0
    or position('  limit 40;' in definition) = 0
    or position('if auth.uid() is null then' in definition) = 0
    or position('operational_state text' in definition) = 0
    or position('  return query' in definition) = 0
  then raise exception 'Solo discovery contract changed; review the market feed clone.'; end if;
  definition := replace(definition,
    'CREATE OR REPLACE FUNCTION public.list_open_queue_games()',
    'CREATE OR REPLACE FUNCTION public.list_open_queue_games_for_market(timezone_to_use text)');
  definition := replace(definition, '  return query', $guard$
  if timezone_to_use is null or timezone_to_use not in ('America/Phoenix', 'Asia/Bahrain') then
    raise exception 'Choose a supported game market.' using errcode = '22023';
  end if;
  return query$guard$);
  definition := replace(definition, old_where,
    old_where || E'\n    and game.timezone = timezone_to_use');
  execute definition;
end;
$migration$;
revoke all on function public.list_open_queue_games_for_market(text) from public, anon, authenticated;
grant execute on function public.list_open_queue_games_for_market(text) to authenticated, service_role;
