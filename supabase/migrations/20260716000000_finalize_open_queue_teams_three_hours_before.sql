-- Freeze Open Queue parties and reveal White/Black kits at the same boundary:
-- three hours before kickoff. The assignment optimizer remains unchanged; this
-- migration adds the time gate to its authoritative function and schedules a
-- lightweight finalizer so a full game is assigned without requiring a client
-- request at exactly the cutoff.

create extension if not exists pg_cron;

-- Keep the latest party-aware optimizer in place and insert the cutoff into
-- the function itself. Updating the existing function (rather than wrapping
-- only its callers) ensures every trigger, booking RPC, referee fallback, and
-- service-role call observes the same rule.
do $migration$
declare
  function_definition text;
  status_guard text := $guard$
  if game_to_assign.status <> 'FULL' then
    raise exception 'Teams can only be assigned when an Open Queue game is full.';
  end if;
$guard$;
  timed_guard text := $guard$
  if game_to_assign.status <> 'FULL' then
    raise exception 'Teams can only be assigned when an Open Queue game is full.';
  end if;

  if clock_timestamp() < game_to_assign.starts_at - interval '3 hours' then
    return;
  end if;

  -- Invitations that were not accepted before the cutoff cannot affect the
  -- finalized lineup. Cancelling them also resolves their notifications via
  -- the existing notification trigger.
  update public.open_queue_party_members member
  set
    status = 'CANCELLED',
    responded_at = clock_timestamp(),
    ended_at = clock_timestamp()
  from public.open_queue_parties party
  where member.party_id = party.id
    and member.game_id = game_id_to_assign
    and member.status = 'INVITED'
    and party.status = 'ACTIVE';
$guard$;
begin
  select pg_get_functiondef(
    'public.assign_open_queue_teams(uuid)'::regprocedure
  ) into function_definition;

  if position(
    'game_to_assign.starts_at - interval ''3 hours'''
    in function_definition
  ) = 0 then
    if position(status_guard in function_definition) = 0 then
      raise exception 'Could not locate the Open Queue assignment guard.';
    end if;
    function_definition := replace(
      function_definition,
      status_guard,
      timed_guard
    );
    execute function_definition;
  end if;
end;
$migration$;

-- Every user-driven party mutation already locks its game row before checking
-- availability. Replace the kickoff check in-place so a mutation racing the
-- cutoff either completes before T-3h or waits and is rejected afterward.
do $migration$
declare
  signature text;
  target_function regprocedure;
  function_definition text;
  old_cutoff text := 'now() >= game_to_use.starts_at';
  new_cutoff text :=
    'clock_timestamp() >= game_to_use.starts_at - interval ''3 hours''';
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
        raise exception 'Could not locate the party cutoff in %.', signature;
      end if;
      function_definition := replace(
        function_definition,
        old_cutoff,
        new_cutoff
      );
    end if;

    function_definition := replace(
      function_definition,
      'Parties are only available before this solo game starts.',
      'Party changes close 3 hours before kickoff so teams and kits can be finalized.'
    );
    function_definition := replace(
      function_definition,
      'Parties cannot be changed after this solo game starts.',
      'Party changes close 3 hours before kickoff so teams and kits can be finalized.'
    );
    execute function_definition;
  end loop;
end;
$migration$;

-- Hide actionable invites and invite candidates at the same cutoff. Existing
-- accepted parties remain visible so players can still see who they are paired
-- with after the lineup is frozen.
do $migration$
declare
  function_definition text;
  old_cutoff text := 'now() < game_to_use.starts_at';
  new_cutoff text :=
    'statement_timestamp() < game_to_use.starts_at - interval ''3 hours''';
begin
  select pg_get_functiondef(
    'public.get_open_queue_party_context(uuid)'::regprocedure
  ) into function_definition;

  if position(new_cutoff in function_definition) = 0 then
    if position(old_cutoff in function_definition) = 0 then
      raise exception 'Could not locate the party context cutoff.';
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

do $migration$
declare
  function_definition text;
  old_cutoff text := 'now() < game.starts_at';
  new_cutoff text :=
    'statement_timestamp() < game.starts_at - interval ''3 hours''';
begin
  select pg_get_functiondef(
    'public.list_my_open_queue_party_invite_notifications()'::regprocedure
  ) into function_definition;

  if position(new_cutoff in function_definition) = 0 then
    if position(old_cutoff in function_definition) = 0 then
      raise exception 'Could not locate the party notification cutoff.';
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

-- Existing FULL future games were assigned under the previous fill-time rule.
-- Remove only unrated, unplayed snapshots that are still more than three hours
-- away so those players adopt the new reveal timing. Rated history is never
-- touched.
update public.open_queue_bookings booking
set
  team = null,
  rating_at_team_assignment = null,
  rating_at_match_start = null,
  rating_change = null
from public.open_queue_games game
where game.id = booking.game_id
  and game.status = 'FULL'
  and game.white_score is null
  and game.black_score is null
  and game.starts_at - interval '3 hours' > clock_timestamp()
  and booking.status = 'CONFIRMED'
  and not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game.id
  );

update public.open_queue_games game
set
  white_average_sr = null,
  black_average_sr = null,
  match_average_sr = null,
  team_sr_spread = null,
  teams_assigned_at = null
where game.status = 'FULL'
  and game.white_score is null
  and game.black_score is null
  and game.starts_at - interval '3 hours' > clock_timestamp()
  and not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game.id
  );

create or replace function public.finalize_due_open_queue_teams()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  candidate record;
  game_to_finalize public.open_queue_games%rowtype;
  finalized_count integer := 0;
  was_assigned boolean;
begin
  for candidate in
    select game.id
    from public.open_queue_games game
    where game.status in ('OPEN', 'FULL')
      and game.white_score is null
      and game.black_score is null
      and game.starts_at - interval '3 hours' <= statement_timestamp()
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
    order by game.starts_at, game.id
  loop
    begin
      select * into game_to_finalize
      from public.open_queue_games game
      where game.id = candidate.id
      for update;

      if game_to_finalize.id is null
        or game_to_finalize.status not in ('OPEN', 'FULL')
        or clock_timestamp() <
          game_to_finalize.starts_at - interval '3 hours'
      then
        continue;
      end if;

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

-- Process anything already inside its cutoff as part of the deployment, then
-- keep the boundary accurate to within one minute.
select public.finalize_due_open_queue_teams();

do $$
declare
  existing_job_id bigint;
begin
  for existing_job_id in
    select jobid
    from cron.job
    where jobname = 'finalize-open-queue-teams-three-hours-before-kickoff'
  loop
    perform cron.unschedule(existing_job_id);
  end loop;
end;
$$;

select cron.schedule(
  'finalize-open-queue-teams-three-hours-before-kickoff',
  '* * * * *',
  'select public.finalize_due_open_queue_teams()'
);

comment on function public.assign_open_queue_teams(uuid) is
'Assigns balanced party-aware Open Queue teams no earlier than three hours before kickoff. White/Black is also the player kit instruction.';

comment on function public.finalize_due_open_queue_teams() is
'Every-minute finalizer that expires pending party invitations and assigns balanced Open Queue teams at the three-hour pre-kickoff cutoff.';
