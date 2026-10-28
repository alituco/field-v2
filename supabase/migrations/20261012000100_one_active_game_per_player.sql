-- One upcoming/active game TOTAL, not merely one game per time slot. Existing
-- paid registrations are preserved; only new registrations/reactivations are
-- checked. Provider-backed PENDING attempts remain a lease until the provider
-- confirms cancellation, even after expires_at (an old sheet can still pay).
create index if not exists fixture_roster_active_player_game_idx
on public.fixture_reliability_roster_history(profile_id,fixture_id) where status='CONFIRMED';
create index if not exists match_reserve_active_player_game_idx
on public.match_reserve_assignments(profile_id,match_kind,open_queue_game_id,fixture_id) where status='ACTIVE';

create or replace function public.player_game_blocks_registration(
  status_to_check text,
  scheduled_end_to_check timestamptz,
  operational_state_to_check text,
  at_time timestamptz default statement_timestamp()
)
returns boolean language sql immutable set search_path=public,pg_temp as $$
  select status_to_check='LIVE' or (
    status_to_check in ('OPEN','FULL','SCHEDULED')
    and scheduled_end_to_check>at_time
    and operational_state_to_check<>'NO_DATA'
  );
$$;

create or replace function public.assert_player_has_one_game(
  profile_id_to_check uuid,
  match_kind_to_ignore text,
  match_id_to_ignore uuid,
  include_checkouts boolean default false
)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if profile_id_to_check is null or match_id_to_ignore is null or match_kind_to_ignore not in ('SOLO','CLAN') then
    raise exception 'A player and game are required for registration.' using errcode='22023';
  end if;
  -- Same lock as paid/free solo booking and the capacity trigger. Serialize
  -- across games, not just within a single game's capacity lock.
  perform pg_advisory_xact_lock(hashtext(profile_id_to_check::text)::bigint);
  if exists (
    select 1 from public.open_queue_bookings b
    join public.open_queue_games g on g.id=b.game_id
    where b.profile_id=profile_id_to_check and b.status='CONFIRMED'
      and not (match_kind_to_ignore='SOLO' and g.id=match_id_to_ignore)
      and public.player_game_blocks_registration(g.status,g.ends_at,g.operational_state)
      and not exists(select 1 from public.match_attendance_records a
        where a.match_kind='SOLO' and a.open_queue_game_id=g.id and a.profile_id=b.profile_id
          and a.outcome in ('NO_SHOW','EXCUSED','FIELD_CANCELLED','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE'))
  ) or exists (
    select 1 from public.fixture_reliability_roster_history r
    join public.fixtures f on f.id=r.fixture_id
    where r.profile_id=profile_id_to_check and r.status='CONFIRMED'
      and not (match_kind_to_ignore='CLAN' and f.id=match_id_to_ignore)
      and public.player_game_blocks_registration(f.status,public.fixture_end_at(f.match_date,f.time_slot),f.operational_state)
      and not exists(select 1 from public.match_attendance_records a
        where a.match_kind='CLAN' and a.fixture_id=f.id and a.profile_id=r.profile_id
          and a.outcome in ('NO_SHOW','EXCUSED','FIELD_CANCELLED','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE'))
  ) or exists (
    select 1 from public.match_reserve_assignments r
    left join public.open_queue_games g on g.id=r.open_queue_game_id
    left join public.fixtures f on f.id=r.fixture_id
    where r.profile_id=profile_id_to_check and r.status='ACTIVE'
      and not (r.match_kind=match_kind_to_ignore and coalesce(r.open_queue_game_id,r.fixture_id)=match_id_to_ignore)
      and public.player_game_blocks_registration(coalesce(g.status,f.status),
        coalesce(g.ends_at,public.fixture_end_at(f.match_date,f.time_slot)),coalesce(g.operational_state,f.operational_state))
      and not exists(select 1 from public.match_attendance_records a
        where a.match_kind=r.match_kind and coalesce(a.open_queue_game_id,a.fixture_id)=coalesce(r.open_queue_game_id,r.fixture_id)
          and a.profile_id=r.profile_id and a.outcome in ('NO_SHOW','EXCUSED','FIELD_CANCELLED','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE'))
  ) then
    raise exception 'You can only be registered in one upcoming or active game. Finish or cancel your current game before booking another.';
  end if;
  if include_checkouts and exists (
    select 1 from public.payment_intents i
    where i.profile_id=profile_id_to_check and i.purpose='SOLO_BOOKING'
      and i.status in ('PENDING','CAPTURED')
      and not (match_kind_to_ignore='SOLO' and i.payload->>'game_id'=match_id_to_ignore::text)
  ) then
    raise exception 'Finish or cancel your earlier game checkout before booking another game.';
  end if;
end;
$$;

-- Atomically reserve the player's checkout before Stripe creates an intent.
-- Same-game concurrent preparation uses the existing idempotent retry path.
create or replace function public.enforce_one_player_game_checkout()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.purpose<>'SOLO_BOOKING' or new.status not in ('PENDING','CAPTURED') then return new; end if;
  perform public.assert_player_has_one_game(new.profile_id,'SOLO',(new.payload->>'game_id')::uuid,true);
  if exists(select 1 from public.payment_intents i where i.profile_id=new.profile_id
    and i.purpose='SOLO_BOOKING' and i.status in ('PENDING','CAPTURED')
    and i.payload->>'game_id'=new.payload->>'game_id') then
    raise exception 'This game checkout is already being prepared.' using errcode='23505';
  end if;
  return new;
end;
$$;
create trigger enforce_one_player_game_checkout before insert on public.payment_intents
for each row execute function public.enforce_one_player_game_checkout();

-- Add the limit without replacing payment verification, eligibility, pricing,
-- reliability-policy, overlap or positional-capacity guards.
do $migration$
declare definition text; anchor text;
begin
  definition:=pg_get_functiondef('public.preview_open_queue_booking_cost(uuid,text)'::regprocedure);
  anchor:='other_game.status in (''OPEN'',''FULL'',''LIVE'')';
  if position(anchor in definition)=0 then raise exception 'Solo quote overlap contract changed.'; end if;
  definition:=replace(definition,anchor,$active$
      public.player_game_blocks_registration(other_game.status,other_game.ends_at,other_game.operational_state)
      and not exists(select 1 from public.match_attendance_records a
        where a.match_kind='SOLO' and a.open_queue_game_id=other_game.id and a.profile_id=existing.profile_id
          and a.outcome in ('NO_SHOW','EXCUSED','FIELD_CANCELLED','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE'))
$active$);
  anchor:='  terms_to_use := public.ensure_match_reliability_terms(';
  if position(anchor in definition)=0 then raise exception 'Solo quote contract changed.'; end if;
  execute replace(definition,anchor,
    E'  perform public.assert_player_has_one_game(user_id,''SOLO'',game_to_book.id,true);\n' || anchor);

  definition:=pg_get_functiondef('public.book_open_queue_game_server(uuid,text,text,text)'::regprocedure);
  anchor:='other_game.status in (''OPEN'', ''FULL'', ''LIVE'')';
  if position(anchor in definition)=0 then raise exception 'Solo booking overlap contract changed.'; end if;
  definition:=replace(definition,anchor,$active$
      public.player_game_blocks_registration(other_game.status,other_game.ends_at,other_game.operational_state)
      and not exists(select 1 from public.match_attendance_records a
        where a.match_kind='SOLO' and a.open_queue_game_id=other_game.id and a.profile_id=existing.profile_id
          and a.outcome in ('NO_SHOW','EXCUSED','FIELD_CANCELLED','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE'))
$active$);
  anchor:='  perform pg_advisory_xact_lock(hashtext(user_id::text)::bigint);';
  if position(anchor in definition)=0 then raise exception 'Solo booking locking contract changed.'; end if;
  execute replace(definition,anchor,anchor ||
    E'\n  perform public.assert_player_has_one_game(user_id,''SOLO'',game_id_to_book,payment_method_to_use=''FREE'');');

  definition:=pg_get_functiondef('public.enforce_open_queue_booking_capacity()'::regprocedure);
  anchor:=$old$
  select count(*)::integer into scheduled_count
  from public.open_queue_bookings booking
  join public.open_queue_games game on game.id = booking.game_id
  where booking.profile_id = new.profile_id
    and booking.status = 'CONFIRMED'
    and booking.id <> new.id
    and game.status in ('OPEN', 'FULL')
    and game.starts_at > now();

  if scheduled_count >= 2 then
    raise exception 'You can have a maximum of 2 upcoming solo games. Cancel one before booking another.';
  end if;
$old$;
  if position(anchor in definition)=0 then raise exception 'Solo capacity scheduling contract changed.'; end if;
  execute replace(definition,anchor,$guard$
  if tg_op='INSERT' or (new.game_id,new.profile_id,new.status) is distinct from (old.game_id,old.profile_id,old.status) then
    perform public.assert_player_has_one_game(new.profile_id,'SOLO',new.game_id,new.payment_intent_id is null);
  end if;
$guard$);
end;
$migration$;

-- Legacy clan rosters and admin reserves cannot bypass the solo rule. Closed
-- history and unchanged roster facts do not revalidate existing paid games.
create or replace function public.enforce_one_player_registered_game()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare kind text; match_id uuid; game_status text; game_end timestamptz; operational text;
begin
  if tg_table_name='fixture_reliability_roster_history' then
    if new.status<>'CONFIRMED' then return new; end if;
    if tg_op='UPDATE' and (new.fixture_id,new.profile_id,new.status) is not distinct from (old.fixture_id,old.profile_id,old.status) then return new; end if;
    kind:='CLAN'; match_id:=new.fixture_id;
  else
    if new.status<>'ACTIVE' then return new; end if;
    if tg_op='UPDATE' and (new.match_kind,new.fixture_id,new.open_queue_game_id,new.profile_id,new.status)
      is not distinct from (old.match_kind,old.fixture_id,old.open_queue_game_id,old.profile_id,old.status) then return new; end if;
    kind:=new.match_kind; match_id:=coalesce(new.open_queue_game_id,new.fixture_id);
  end if;
  -- Keep the target locked even for historical/NO_DATA inserts. Otherwise a
  -- reactivation could enumerate its participants before this insert commits.
  -- SHARE conflicts with status updates; KEY SHARE would not be sufficient.
  -- Existing roster/reserve RPCs already lock this target before the player.
  if kind='SOLO' then
    select status,ends_at,operational_state into game_status,game_end,operational from public.open_queue_games where id=match_id for share;
  else
    select status,public.fixture_end_at(match_date,time_slot),operational_state into game_status,game_end,operational from public.fixtures where id=match_id for share;
  end if;
  if public.player_game_blocks_registration(game_status,game_end,operational) then
    perform public.assert_player_has_one_game(new.profile_id,kind,match_id,true);
  end if;
  return new;
end;
$$;
create trigger enforce_one_player_registered_game before insert or update of fixture_id,profile_id,status
on public.fixture_reliability_roster_history for each row execute function public.enforce_one_player_registered_game();
create trigger enforce_one_player_registered_game before insert or update of match_kind,fixture_id,open_queue_game_id,profile_id,status
on public.match_reserve_assignments for each row execute function public.enforce_one_player_registered_game();

-- Rescheduling/reactivating a historical game is also a new commitment for its
-- participants. Prevent a past game from being moved forward around the rule.
create or replace function public.enforce_reactivated_player_game_limit()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare kind text; profile_to_check uuid; old_end timestamptz; new_end timestamptz;
begin
  if tg_table_name='open_queue_games' then kind:='SOLO'; old_end:=old.ends_at; new_end:=new.ends_at;
  else kind:='CLAN'; old_end:=public.fixture_end_at(old.match_date,old.time_slot); new_end:=public.fixture_end_at(new.match_date,new.time_slot); end if;
  if not public.player_game_blocks_registration(new.status,new_end,new.operational_state)
    or public.player_game_blocks_registration(old.status,old_end,old.operational_state) then return new; end if;
  for profile_to_check in
    select participant.profile_id from (
      select profile_id from public.open_queue_bookings where kind='SOLO' and game_id=new.id and status='CONFIRMED'
      union select profile_id from public.fixture_reliability_roster_history where kind='CLAN' and fixture_id=new.id and status='CONFIRMED'
      union select profile_id from public.match_reserve_assignments where match_kind=kind
        and coalesce(open_queue_game_id,fixture_id)=new.id and status='ACTIVE'
    ) participant
    where not exists(select 1 from public.match_attendance_records a
      where a.match_kind=kind and coalesce(a.open_queue_game_id,a.fixture_id)=new.id and a.profile_id=participant.profile_id
        and a.outcome in ('NO_SHOW','EXCUSED','FIELD_CANCELLED','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE'))
    order by participant.profile_id
  loop
    perform public.assert_player_has_one_game(profile_to_check,kind,new.id,true);
  end loop;
  return new;
end;
$$;
create trigger enforce_reactivated_player_game_limit before update of status,ends_at,operational_state
on public.open_queue_games for each row execute function public.enforce_reactivated_player_game_limit();
create trigger enforce_reactivated_player_game_limit before update of status,match_date,time_slot,operational_state
on public.fixtures for each row execute function public.enforce_reactivated_player_game_limit();

revoke all on function public.player_game_blocks_registration(text,timestamptz,text,timestamptz),
  public.assert_player_has_one_game(uuid,text,uuid,boolean),public.enforce_one_player_game_checkout(),
  public.enforce_one_player_registered_game(),public.enforce_reactivated_player_game_limit()
from public,anon,authenticated;
notify pgrst,'reload schema';
