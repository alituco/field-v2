-- Use the reliability policy snapshotted for each solo match as the only
-- authority for party locking, team/kit assignment, and party size. This
-- replaces the original fixed T-3h / four-player implementation while keeping
-- the optimizer and all existing party workflows intact.

create or replace function public.open_queue_team_assignment_at(
  game_id_to_use uuid
)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_to_use public.match_reliability_terms%rowtype;
begin
  terms_to_use := public.ensure_match_reliability_terms(
    'SOLO', game_id_to_use
  );
  if terms_to_use.team_assignment_at is null then
    raise exception 'This solo match does not have a team assignment policy.';
  end if;
  return terms_to_use.team_assignment_at;
end;
$$;

create or replace function public.open_queue_party_lock_at(
  game_id_to_use uuid
)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_to_use public.match_reliability_terms%rowtype;
begin
  terms_to_use := public.ensure_match_reliability_terms(
    'SOLO', game_id_to_use
  );
  if terms_to_use.party_lock_at is null then
    raise exception 'This solo match does not have a party lock policy.';
  end if;
  return terms_to_use.party_lock_at;
end;
$$;

create or replace function public.open_queue_max_party_size(
  game_id_to_use uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_to_use public.match_reliability_terms%rowtype;
  max_size integer;
begin
  terms_to_use := public.ensure_match_reliability_terms(
    'SOLO', game_id_to_use
  );
  max_size := (terms_to_use.policy_snapshot #>>
    '{replacement,maxPartySize}')::integer;
  if max_size not between 1 and 4 then
    raise exception 'This solo match has an invalid party size policy.';
  end if;
  return max_size;
end;
$$;

revoke all on function public.open_queue_team_assignment_at(uuid)
from public, anon, authenticated;
revoke all on function public.open_queue_party_lock_at(uuid)
from public, anon, authenticated;
revoke all on function public.open_queue_max_party_size(uuid)
from public, anon, authenticated;
grant execute on function public.open_queue_team_assignment_at(uuid)
to service_role;
grant execute on function public.open_queue_party_lock_at(uuid)
to service_role;
grant execute on function public.open_queue_max_party_size(uuid)
to service_role;

-- A party must lock no later than teams are revealed. Otherwise an accepted
-- party change could force a player's already-revealed kit to change.
create or replace function public.validate_reliability_solo_cutoff_order()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  team_lead integer;
  party_lead integer;
begin
  if new.state <> 'PUBLISHED' then
    return new;
  end if;
  team_lead := (new.config #>>
    '{solo,teamAssignmentLeadMinutes}')::integer;
  party_lead := (new.config #>>
    '{solo,partyLockLeadMinutes}')::integer;
  if party_lead < team_lead then
    raise exception using
      errcode = '23514',
      message = 'Party lock must be at or before team and kit assignment.';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_reliability_solo_cutoff_order
on public.reliability_policy_versions;
create trigger validate_reliability_solo_cutoff_order
before insert or update of state, config
on public.reliability_policy_versions
for each row execute function public.validate_reliability_solo_cutoff_order();

revoke all on function public.validate_reliability_solo_cutoff_order()
from public, anon, authenticated;

-- Publishing a future policy immediately rebinds unbooked, unpaid future
-- matches by scheduled kickoff. The first player booking or clan payment locks
-- the disclosed policy for that entire match; historical decisions are also
-- immutable. This prevents a later admin change from altering an accepted
-- charge, deposit, refund, deadline or attendance contract.
create or replace function public.refresh_future_reliability_terms_on_publish()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  candidate record;
begin
  if new.state <> 'PUBLISHED'
    or (tg_op = 'UPDATE' and old.state = 'PUBLISHED')
  then
    return new;
  end if;

  for candidate in
    select game.id
    from public.open_queue_games game
    where game.status in ('OPEN', 'FULL')
      and game.starts_at > clock_timestamp()
    order by game.starts_at, game.id
  loop
    perform public.ensure_match_reliability_terms('SOLO', candidate.id);
  end loop;

  for candidate in
    select fixture.id
    from public.fixtures fixture
    where fixture.status in ('OPEN', 'SCHEDULED')
      and public.fixture_start_at(fixture.match_date, fixture.time_slot)
        > clock_timestamp()
    order by fixture.match_date, fixture.time_slot, fixture.id
  loop
    perform public.ensure_match_reliability_terms('CLAN', candidate.id);
  end loop;

  return new;
end;
$$;

drop trigger if exists refresh_future_reliability_terms_on_publish
on public.reliability_policy_versions;
create trigger refresh_future_reliability_terms_on_publish
after insert or update of state
on public.reliability_policy_versions
for each row execute function public.refresh_future_reliability_terms_on_publish();

revoke all on function public.refresh_future_reliability_terms_on_publish()
from public, anon, authenticated;

-- Keep the party-aware optimizer, but replace its fixed cutoff with the
-- snapshotted per-match boundary. The guard remains inside the authoritative
-- assignment function so every caller observes it.
do $migration$
declare
  function_definition text;
  old_cutoff text :=
    'game_to_assign.starts_at - interval ''3 hours''';
  new_cutoff text :=
    'public.open_queue_team_assignment_at(game_id_to_assign)';
begin
  select pg_get_functiondef(
    'public.assign_open_queue_teams(uuid)'::regprocedure
  ) into function_definition;

  if position(new_cutoff in function_definition) = 0 then
    if position(old_cutoff in function_definition) = 0 then
      raise exception 'Could not locate the fixed Open Queue assignment cutoff.';
    end if;
    function_definition := replace(
      function_definition,
      old_cutoff,
      new_cutoff
    );
    execute function_definition;
  end if;
end;
$migration$;

-- Every party mutation locks the game row first. Resolve the snapshotted
-- cutoff while holding that lock, so a request racing the boundary either
-- commits before it or is rejected after it.
do $migration$
declare
  signature text;
  target_function regprocedure;
  function_definition text;
  old_cutoff text :=
    'clock_timestamp() >= game_to_use.starts_at - interval ''3 hours''';
  new_cutoff text :=
    'clock_timestamp() >= public.open_queue_party_lock_at(game_to_use.id)';
begin
  foreach signature in array array[
    'public.create_open_queue_party(uuid)',
    'public.invite_open_queue_party_member(uuid,uuid)',
    'public.respond_open_queue_party_invitation(uuid,boolean)',
    'public.cancel_open_queue_party_invitation(uuid)',
    'public.leave_open_queue_party(uuid)',
    'public.disband_open_queue_party(uuid)'
  ] loop
    target_function := to_regprocedure(signature);
    if target_function is null then
      raise exception 'Required party function % was not found.', signature;
    end if;

    select pg_get_functiondef(target_function) into function_definition;
    if position(new_cutoff in function_definition) = 0 then
      if position(old_cutoff in function_definition) = 0 then
        raise exception 'Could not locate the fixed party cutoff in %.', signature;
      end if;
      function_definition := replace(
        function_definition,
        old_cutoff,
        new_cutoff
      );
    end if;
    function_definition := replace(
      function_definition,
      'Party changes close 3 hours before kickoff so teams and kits can be finalized.',
      'Party changes are closed for this match. Check the lock time in booking details.'
    );
    execute function_definition;
  end loop;
end;
$migration$;

-- Apply the per-match party-size cap to both issuing and accepting an invite.
do $migration$
declare
  function_definition text;
  old_guard text := 'active_seat_count >= 4';
  new_guard text :=
    'active_seat_count >= public.open_queue_max_party_size(game_to_use.id)';
begin
  select pg_get_functiondef(
    'public.invite_open_queue_party_member(uuid,uuid)'::regprocedure
  ) into function_definition;
  if position(new_guard in function_definition) = 0 then
    if position(old_guard in function_definition) = 0 then
      raise exception 'Could not locate the party invite size guard.';
    end if;
    function_definition := replace(function_definition, old_guard, new_guard);
  end if;
  function_definition := replace(
    function_definition,
    'A party can have at most 4 players, including pending invitations.',
    'This party has reached its player limit, including pending invitations.'
  );
  execute function_definition;
end;
$migration$;

do $migration$
declare
  function_definition text;
  old_guard text := 'accepted_count_to_return >= 4';
  new_guard text :=
    'accepted_count_to_return >= public.open_queue_max_party_size(game_to_use.id)';
begin
  select pg_get_functiondef(
    'public.respond_open_queue_party_invitation(uuid,boolean)'::regprocedure
  ) into function_definition;
  if position(new_guard in function_definition) = 0 then
    if position(old_guard in function_definition) = 0 then
      raise exception 'Could not locate the party acceptance size guard.';
    end if;
    function_definition := replace(function_definition, old_guard, new_guard);
  end if;
  function_definition := replace(
    function_definition,
    'This party already has 4 players.',
    'This party has reached its player limit.'
  );
  execute function_definition;
end;
$migration$;

-- Expose the exact server boundary and policy values alongside party state.
-- The function becomes VOLATILE because it can bind a missing prospective
-- match snapshot before returning it.
do $migration$
declare
  function_definition text;
  declaration_anchor text := 'eligible_players_payload jsonb;';
  declaration_replacement text := $body$eligible_players_payload jsonb;
  policy_terms public.match_reliability_terms%rowtype;
  team_assignment_at_to_use timestamptz;
  party_lock_at_to_use timestamptz;
  team_assignment_lead_minutes_to_use integer;
  party_lock_lead_minutes_to_use integer;
  max_party_size_to_use integer;$body$;
  game_anchor text := $body$  if game_to_use.id is null then
    raise exception 'Open Queue game not found.';
  end if;$body$;
  game_replacement text := $body$  if game_to_use.id is null then
    raise exception 'Open Queue game not found.';
  end if;$body$;
  booking_anchor text := $body$  if not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = game_id_to_use
      and booking.profile_id = user_id
      and booking.status = 'CONFIRMED'
  ) then
    raise exception 'You need a confirmed booking in this solo game.';
  end if;$body$;
  booking_replacement text := $body$  if not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = game_id_to_use
      and booking.profile_id = user_id
      and booking.status = 'CONFIRMED'
  ) then
    raise exception 'You need a confirmed booking in this solo game.';
  end if;

  policy_terms := public.ensure_match_reliability_terms(
    'SOLO', game_id_to_use
  );
  team_assignment_at_to_use := policy_terms.team_assignment_at;
  party_lock_at_to_use := policy_terms.party_lock_at;
  team_assignment_lead_minutes_to_use := (policy_terms.policy_snapshot #>>
    '{solo,teamAssignmentLeadMinutes}')::integer;
  party_lock_lead_minutes_to_use := (policy_terms.policy_snapshot #>>
    '{solo,partyLockLeadMinutes}')::integer;
  max_party_size_to_use := (policy_terms.policy_snapshot #>>
    '{replacement,maxPartySize}')::integer;$body$;
  old_cutoff text :=
    'statement_timestamp() < game_to_use.starts_at - interval ''3 hours''';
  new_cutoff text :=
    'max_party_size_to_use > 1 and statement_timestamp() < party_lock_at_to_use';
  old_max text := '''max_party_size'', 4,';
  new_max text := $body$'policy_version_id', policy_terms.policy_version_id,
    'server_now', statement_timestamp(),
    'team_assignment_at', team_assignment_at_to_use,
    'party_lock_at', party_lock_at_to_use,
    'team_assignment_lead_minutes', team_assignment_lead_minutes_to_use,
    'party_lock_lead_minutes', party_lock_lead_minutes_to_use,
    'max_party_size', max_party_size_to_use,$body$;
begin
  select pg_get_functiondef(
    'public.get_open_queue_party_context(uuid)'::regprocedure
  ) into function_definition;

  if position('policy_terms public.match_reliability_terms%rowtype' in
      function_definition) = 0
  then
    if position(declaration_anchor in function_definition) = 0
      or position(game_anchor in function_definition) = 0
      or position(booking_anchor in function_definition) = 0
    then
      raise exception 'Could not add reliability terms to party context.';
    end if;
    function_definition := replace(
      function_definition, declaration_anchor, declaration_replacement
    );
    function_definition := replace(
      function_definition, game_anchor, game_replacement
    );
    function_definition := replace(
      function_definition, booking_anchor, booking_replacement
    );
  end if;

  if position(new_cutoff in function_definition) = 0 then
    if position(old_cutoff in function_definition) = 0 then
      raise exception 'Could not locate the party context cutoff.';
    end if;
    function_definition := replace(
      function_definition, old_cutoff, new_cutoff
    );
  end if;

  if position('''policy_version_id'', policy_terms.policy_version_id' in
      function_definition) = 0
  then
    if position(old_max in function_definition) = 0 then
      raise exception 'Could not locate the party context policy payload.';
    end if;
    function_definition := replace(function_definition, old_max, new_max);
  end if;
  execute function_definition;
  alter function public.get_open_queue_party_context(uuid) volatile;
end;
$migration$;

-- Notification visibility uses the same stored lock timestamp without
-- recomputing it from the game clock.
do $migration$
declare
  function_definition text;
  old_cutoff text :=
    'statement_timestamp() < game.starts_at - interval ''3 hours''';
  new_cutoff text := 'statement_timestamp() < terms.party_lock_at';
  game_join text := $body$  join public.open_queue_games game
    on game.id = member.game_id
    and game.status in ('OPEN', 'FULL')$body$;
  game_join_with_terms text := $body$  join public.open_queue_games game
    on game.id = member.game_id
    and game.status in ('OPEN', 'FULL')
  join public.match_reliability_terms terms
    on terms.match_kind = 'SOLO'
    and terms.open_queue_game_id = game.id
    and (terms.policy_snapshot #>>
      '{replacement,maxPartySize}')::integer > 1$body$;
begin
  select pg_get_functiondef(
    'public.list_my_open_queue_party_invite_notifications()'::regprocedure
  ) into function_definition;

  if position('join public.match_reliability_terms terms' in
      function_definition) = 0
  then
    if position(game_join in function_definition) = 0 then
      raise exception 'Could not attach policy terms to party notifications.';
    end if;
    function_definition := replace(
      function_definition, game_join, game_join_with_terms
    );
  end if;
  if position(new_cutoff in function_definition) = 0 then
    if position(old_cutoff in function_definition) = 0 then
      raise exception 'Could not locate the party notification cutoff.';
    end if;
    function_definition := replace(
      function_definition, old_cutoff, new_cutoff
    );
  end if;
  function_definition := replace(
    function_definition,
    '''status'', game.status',
    $body$'status', game.status,
        'party_lock_at', terms.party_lock_at,
        'policy_version_id', terms.policy_version_id$body$
  );
  execute function_definition;
end;
$migration$;

-- Replace the fixed-cutoff scheduler with a policy-aware finalizer. Rows are
-- selected using stored terms, then locked and checked again before mutation.
create or replace function public.finalize_due_open_queue_teams()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  candidate record;
  game_to_finalize public.open_queue_games%rowtype;
  assignment_at_to_use timestamptz;
  party_lock_at_to_use timestamptz;
  finalized_count integer := 0;
  was_assigned boolean;
begin
  for candidate in
    select game.id
    from public.open_queue_games game
    join public.match_reliability_terms terms
      on terms.match_kind = 'SOLO'
      and terms.open_queue_game_id = game.id
    where game.status in ('OPEN', 'FULL')
      and game.white_score is null
      and game.black_score is null
      and least(terms.team_assignment_at, terms.party_lock_at)
        <= statement_timestamp()
      and (
        (
          game.status = 'FULL'
          and (
            game.teams_assigned_at is null
            or game.white_average_sr is null
            or game.black_average_sr is null
            or game.match_average_sr is null
            or game.team_sr_spread is null
            or exists (
              select 1
              from public.open_queue_bookings booking
              where booking.game_id = game.id
                and booking.status = 'CONFIRMED'
                and (
                  booking.team is null
                  or booking.rating_at_team_assignment is null
                )
            )
          )
        )
        or exists (
          select 1
          from public.open_queue_party_members member
          join public.open_queue_parties party on party.id = member.party_id
          where member.game_id = game.id
            and member.status = 'INVITED'
            and party.status = 'ACTIVE'
        )
      )
    order by least(terms.team_assignment_at, terms.party_lock_at),
      game.starts_at,
      game.id
  loop
    begin
      select * into game_to_finalize
      from public.open_queue_games game
      where game.id = candidate.id
      for update;

      if game_to_finalize.id is null
        or game_to_finalize.status not in ('OPEN', 'FULL')
      then
        continue;
      end if;

      assignment_at_to_use := public.open_queue_team_assignment_at(
        game_to_finalize.id
      );
      party_lock_at_to_use := public.open_queue_party_lock_at(
        game_to_finalize.id
      );
      if clock_timestamp() < least(
          assignment_at_to_use,
          party_lock_at_to_use
        )
      then
        continue;
      end if;

      -- Only party invitations whose own lock has passed are expired. This
      -- also supports policies where parties lock earlier than assignment.
      if clock_timestamp() >= party_lock_at_to_use then
        update public.open_queue_party_members member
        set
          status = 'CANCELLED',
          responded_at = clock_timestamp(),
          ended_at = clock_timestamp()
        from public.open_queue_parties party
        where member.party_id = party.id
          and member.game_id = game_to_finalize.id
          and member.status = 'INVITED'
          and party.status = 'ACTIVE';
      end if;

      if clock_timestamp() < assignment_at_to_use then
        continue;
      end if;

      if game_to_finalize.status = 'FULL' then
        was_assigned := game_to_finalize.teams_assigned_at is not null;
        perform public.assign_open_queue_teams(game_to_finalize.id);

        if not was_assigned and exists (
          select 1
          from public.open_queue_games game
          where game.id = game_to_finalize.id
            and game.teams_assigned_at is not null
        ) then
          finalized_count := finalized_count + 1;
        end if;
      end if;
    exception
      when others then
        raise warning 'Could not finalize Open Queue teams for %: %',
          candidate.id,
          sqlerrm;
    end;
  end loop;

  return finalized_count;
end;
$$;

revoke all on function public.finalize_due_open_queue_teams()
from public, anon, authenticated;
grant execute on function public.finalize_due_open_queue_teams()
to service_role;

do $$
declare
  existing_job_id bigint;
begin
  for existing_job_id in
    select jobid
    from cron.job
    where jobname in (
      'finalize-open-queue-teams-three-hours-before-kickoff',
      'finalize-open-queue-teams-at-policy-cutoff'
    )
  loop
    perform cron.unschedule(existing_job_id);
  end loop;
end;
$$;

select cron.schedule(
  'finalize-open-queue-teams-at-policy-cutoff',
  '* * * * *',
  'select public.finalize_due_open_queue_teams()'
);

-- Return policy timing with every game so booking, review, fixtures, and Home
-- render server-provided values instead of maintaining a client-side cutoff.
drop function if exists public.list_open_queue_games();
create function public.list_open_queue_games()
returns table (
  id uuid,
  status text,
  venue text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  price_fils integer,
  age_label text,
  capacity integer,
  confirmed_count integer,
  goalkeeper_spots integer,
  defender_spots integer,
  midfielder_spots integer,
  attacker_spots integer,
  white_average_sr numeric,
  black_average_sr numeric,
  match_average_sr numeric,
  team_sr_spread numeric,
  teams_assigned_at timestamptz,
  policy_version_id uuid,
  team_assignment_at timestamptz,
  party_lock_at timestamptz,
  team_assignment_lead_minutes integer,
  party_lock_lead_minutes integer,
  max_party_size integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  return query
  select
    game.id,
    game.status,
    game.venue,
    game.starts_at,
    game.ends_at,
    game.timezone,
    game.price_fils,
    game.age_label,
    game.capacity,
    count(booking.id)::integer,
    greatest(0, game.goalkeeper_capacity -
      (count(booking.id) filter (where booking.role = 'GK'))::integer),
    greatest(0, game.defender_capacity -
      (count(booking.id) filter (where booking.role = 'DEF'))::integer),
    greatest(0, game.midfielder_capacity -
      (count(booking.id) filter (where booking.role = 'MID'))::integer),
    greatest(0, game.attacker_capacity -
      (count(booking.id) filter (where booking.role = 'ATT'))::integer),
    game.white_average_sr,
    game.black_average_sr,
    game.match_average_sr,
    game.team_sr_spread,
    game.teams_assigned_at,
    terms.policy_version_id,
    terms.team_assignment_at,
    terms.party_lock_at,
    (terms.policy_snapshot #>>
      '{solo,teamAssignmentLeadMinutes}')::integer,
    (terms.policy_snapshot #>>
      '{solo,partyLockLeadMinutes}')::integer,
    (terms.policy_snapshot #>>
      '{replacement,maxPartySize}')::integer
  from public.open_queue_games game
  left join public.open_queue_bookings booking
    on booking.game_id = game.id
    and booking.status = 'CONFIRMED'
  left join public.match_reliability_terms terms
    on terms.match_kind = 'SOLO'
    and terms.open_queue_game_id = game.id
  where game.status in ('OPEN', 'FULL')
    and game.starts_at > statement_timestamp()
    and (
      game.status <> 'OPEN'
      or terms.id is null
      or statement_timestamp() < terms.check_in_deadline_at
      or coalesce(
        (terms.policy_snapshot #>>
          '{replacement,postCheckInDeadlineMarketplaceEnabled}')::boolean,
        false
      )
    )
  group by game.id, terms.id
  order by game.starts_at
  limit 40;
end;
$$;

revoke all on function public.list_open_queue_games()
from public, anon, authenticated;
grant execute on function public.list_open_queue_games()
to authenticated;

drop function if exists public.list_open_queue_fixture_games();
create function public.list_open_queue_fixture_games()
returns table (
  id uuid,
  status text,
  venue text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  price_fils integer,
  age_label text,
  capacity integer,
  confirmed_count integer,
  goalkeeper_spots integer,
  defender_spots integer,
  midfielder_spots integer,
  attacker_spots integer,
  white_score integer,
  black_score integer,
  white_average_sr numeric,
  black_average_sr numeric,
  match_average_sr numeric,
  team_sr_spread numeric,
  teams_assigned_at timestamptz,
  my_booking_id uuid,
  my_booking_role text,
  my_booking_team text,
  policy_version_id uuid,
  team_assignment_at timestamptz,
  party_lock_at timestamptz,
  team_assignment_lead_minutes integer,
  party_lock_lead_minutes integer,
  max_party_size integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  return query
  select
    game.id,
    game.status,
    game.venue,
    game.starts_at,
    game.ends_at,
    game.timezone,
    game.price_fils,
    game.age_label,
    game.capacity,
    booking_counts.confirmed_count,
    greatest(0, game.goalkeeper_capacity - booking_counts.goalkeeper_count),
    greatest(0, game.defender_capacity - booking_counts.defender_count),
    greatest(0, game.midfielder_capacity - booking_counts.midfielder_count),
    greatest(0, game.attacker_capacity - booking_counts.attacker_count),
    game.white_score,
    game.black_score,
    game.white_average_sr,
    game.black_average_sr,
    game.match_average_sr,
    game.team_sr_spread,
    game.teams_assigned_at,
    my_booking.id,
    my_booking.role,
    my_booking.team,
    terms.policy_version_id,
    terms.team_assignment_at,
    terms.party_lock_at,
    (terms.policy_snapshot #>>
      '{solo,teamAssignmentLeadMinutes}')::integer,
    (terms.policy_snapshot #>>
      '{solo,partyLockLeadMinutes}')::integer,
    (terms.policy_snapshot #>>
      '{replacement,maxPartySize}')::integer
  from public.open_queue_games game
  cross join lateral (
    select
      count(*)::integer as confirmed_count,
      (count(*) filter (where booking.role = 'GK'))::integer
        as goalkeeper_count,
      (count(*) filter (where booking.role = 'DEF'))::integer
        as defender_count,
      (count(*) filter (where booking.role = 'MID'))::integer
        as midfielder_count,
      (count(*) filter (where booking.role = 'ATT'))::integer
        as attacker_count
    from public.open_queue_bookings booking
    where booking.game_id = game.id
      and booking.status = 'CONFIRMED'
  ) booking_counts
  left join lateral (
    select booking.id, booking.role, booking.team
    from public.open_queue_bookings booking
    where booking.game_id = game.id
      and booking.profile_id = auth.uid()
      and booking.status = 'CONFIRMED'
    order by booking.booked_at desc
    limit 1
  ) my_booking on true
  left join public.match_reliability_terms terms
    on terms.match_kind = 'SOLO'
    and terms.open_queue_game_id = game.id
  where game.status <> 'CANCELLED'
  order by game.starts_at, game.id;
end;
$$;

revoke all on function public.list_open_queue_fixture_games()
from public, anon, authenticated;
grant execute on function public.list_open_queue_fixture_games()
to authenticated;

-- Re-run once at deployment so a newly-effective policy boundary is observed
-- immediately rather than waiting for the next cron minute.
select public.finalize_due_open_queue_teams();

comment on function public.assign_open_queue_teams(uuid) is
'Assigns balanced party-aware Open Queue teams no earlier than the assignment boundary snapshotted from the reliability policy for that match.';
comment on function public.finalize_due_open_queue_teams() is
'Every-minute finalizer that uses each solo match policy snapshot to expire invitations and assign balanced teams and kits.';
comment on function public.get_open_queue_party_context(uuid) is
'Returns the caller party workflow plus the authoritative policy version, lock time, assignment time, and maximum party size for the solo match.';

-- Fail deployment rather than silently leaving one mutation on a stale local
-- constant if an earlier function changes shape in a future branch.
do $verification$
declare
  signature text;
  function_definition text;
begin
  select pg_get_functiondef(
    'public.assign_open_queue_teams(uuid)'::regprocedure
  ) into function_definition;
  if position(
    'public.open_queue_team_assignment_at(game_id_to_assign)'
    in function_definition
  ) = 0 then
    raise exception 'Team assignment is not using its policy snapshot.';
  end if;

  foreach signature in array array[
    'public.create_open_queue_party(uuid)',
    'public.invite_open_queue_party_member(uuid,uuid)',
    'public.respond_open_queue_party_invitation(uuid,boolean)',
    'public.cancel_open_queue_party_invitation(uuid)',
    'public.leave_open_queue_party(uuid)',
    'public.disband_open_queue_party(uuid)'
  ] loop
    select pg_get_functiondef(signature::regprocedure)
    into function_definition;
    if position(
      'public.open_queue_party_lock_at(game_to_use.id)'
      in function_definition
    ) = 0 then
      raise exception '% is not using its policy party lock.', signature;
    end if;
  end loop;

  select pg_get_functiondef(
    'public.invite_open_queue_party_member(uuid,uuid)'::regprocedure
  ) into function_definition;
  if position(
    'public.open_queue_max_party_size(game_to_use.id)'
    in function_definition
  ) = 0 then
    raise exception 'Party invitations are not using the policy size limit.';
  end if;

  select pg_get_functiondef(
    'public.respond_open_queue_party_invitation(uuid,boolean)'::regprocedure
  ) into function_definition;
  if position(
    'public.open_queue_max_party_size(game_to_use.id)'
    in function_definition
  ) = 0 then
    raise exception 'Party acceptance is not using the policy size limit.';
  end if;
end;
$verification$;
