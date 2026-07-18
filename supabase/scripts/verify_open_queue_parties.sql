\set ON_ERROR_STOP on

-- Run after 20260715000007_create_open_queue_parties.sql. The explicit
-- transaction makes this safe against a linked development database: every
-- verification row and state change is rolled back.
begin;

do $$
declare
  player_ids uuid[];
  game_starts timestamptz[];
  game_id_to_verify uuid;
  impossible_game_id uuid;
  party_a_id uuid;
  party_b_id uuid;
  post_full_party_id uuid;
  impossible_party_id uuid;
  impossible_existing_party_id uuid;
  invitation_a_id uuid;
  invitation_b_id uuid;
  impossible_invitation_id uuid;
  notification_id uuid;
  old_party_pending_id uuid;
  player_one_booking_id uuid;
  impossible_owner_booking_id uuid;
  payload jsonb;
  party_function_signature text;
  slot integer;
  rejection_seen boolean := false;
  max_size_rejection_seen boolean := false;
  live_rejection_seen boolean := false;
  unauthorized_notification_rejected boolean := false;
begin
  select array_agg(candidate.id order by candidate.created_at, candidate.id)
  into player_ids
  from (
    select profile.id, profile.created_at
    from public.profiles profile
    where not public.profile_has_active_play_restriction(profile.id)
      and not exists (
        select 1
        from public.open_queue_bookings booking
        join public.open_queue_games game on game.id = booking.game_id
        where booking.profile_id = profile.id
          and booking.status = 'CONFIRMED'
          and game.status in ('OPEN', 'FULL')
          and game.starts_at > now()
      )
    order by profile.created_at, profile.id
    limit 12
  ) candidate;

  if coalesce(cardinality(player_ids), 0) <> 12 then
    raise exception 'Party verification needs 12 unrestricted profiles without future solo bookings.';
  end if;

  select array_agg(candidate.starts_at order by candidate.starts_at)
  into game_starts
  from (
    select
      ((day_value::date + time '20:30') at time zone 'Asia/Bahrain') as starts_at
    from generate_series(
      current_date + interval '730 days',
      current_date + interval '800 days',
      interval '1 day'
    ) generated(day_value)
    where extract(isodow from day_value) in (2, 5)
      and not exists (
        select 1
        from public.open_queue_games existing
        where existing.starts_at =
          ((day_value::date + time '20:30') at time zone 'Asia/Bahrain')
          and existing.status <> 'CANCELLED'
      )
    order by day_value
    limit 2
  ) candidate;

  if coalesce(cardinality(game_starts), 0) <> 2 then
    raise exception 'Could not find two unused permanent solo schedule slots.';
  end if;

  insert into public.open_queue_games (
    venue, starts_at, ends_at, created_by
  ) values (
    'Party verification pitch A',
    game_starts[1],
    game_starts[1] + interval '1 hour',
    player_ids[1]
  ) returning id into game_id_to_verify;

  -- Book eight players first so party acceptance is validated against four
  -- future singleton placeholders, not only against a completed roster.
  for slot in 1..8 loop
    insert into public.open_queue_bookings (
      game_id,
      profile_id,
      role,
      player_rating_at_booking,
      amount_paid_fils,
      base_amount_fils,
      payment_method,
      payment_status
    ) values (
      game_id_to_verify,
      player_ids[slot],
      (array['GK', 'DEF', 'MID', 'ATT', 'GK', 'DEF', 'MID', 'ATT'])[slot],
      coalesce((
        select rating.skill_rating
        from public.player_ratings rating
        where rating.profile_id = player_ids[slot]
      ), 1200),
      3000,
      3000,
      'MOCK',
      'PAID'
    );
  end loop;

  perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
  party_a_id := public.create_open_queue_party(game_id_to_verify);

  perform set_config('request.jwt.claim.sub', player_ids[5]::text, true);
  party_b_id := public.create_open_queue_party(game_id_to_verify);
  invitation_b_id := public.invite_open_queue_party_member(
    party_b_id, player_ids[2]
  );

  perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
  invitation_a_id := public.invite_open_queue_party_member(
    party_a_id, player_ids[2]
  );
  perform set_config('request.jwt.claim.sub', player_ids[2]::text, true);
  payload := public.list_my_open_queue_party_invite_notifications();
  if jsonb_array_length(payload) <> 2 then
    raise exception 'Recipient did not receive both active party notifications.';
  end if;
  select (item ->> 'notification_id')::uuid into notification_id
  from jsonb_array_elements(payload) item
  where item ->> 'membership_id' = invitation_a_id::text;
  if notification_id is null
    or payload @> jsonb_build_array(jsonb_build_object(
      'notification_id', notification_id,
      'is_read', false
    )) is not true then
    raise exception 'Party notification payload or unread state is incomplete.';
  end if;

  perform set_config('request.jwt.claim.sub', player_ids[6]::text, true);
  begin
    perform public.mark_my_open_queue_party_invite_notification_read(
      notification_id
    );
  exception when others then
    if position('not found' in lower(sqlerrm)) > 0 then
      unauthorized_notification_rejected := true;
    else
      raise;
    end if;
  end;
  if not unauthorized_notification_rejected then
    raise exception 'Another player could mark a private notification read.';
  end if;

  perform set_config('request.jwt.claim.sub', player_ids[2]::text, true);
  payload := public.mark_my_open_queue_party_invite_notification_read(
    notification_id
  );
  if payload ->> 'is_read' <> 'true' then
    raise exception 'Recipient could not mark the invitation notification read.';
  end if;
  perform public.respond_open_queue_party_invitation(invitation_a_id, true);

  if not exists (
    select 1
    from public.open_queue_party_members member
    where member.id = invitation_b_id and member.status = 'CANCELLED'
  ) then
    raise exception 'Accepting one invitation did not cancel the other pending invitation.';
  end if;
  if exists (
    select 1 from public.notifications notification
    where notification.related_entity_id in (invitation_a_id, invitation_b_id)
      and notification.resolved_at is null
  ) or jsonb_array_length(
    public.list_my_open_queue_party_invite_notifications()
  ) <> 0 then
    raise exception 'Accepted/cancelled invitations left active notifications.';
  end if;

  perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
  invitation_a_id := public.invite_open_queue_party_member(
    party_a_id, player_ids[3]
  );
  perform set_config('request.jwt.claim.sub', player_ids[3]::text, true);
  perform public.respond_open_queue_party_invitation(invitation_a_id, true);
  perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
  invitation_a_id := public.invite_open_queue_party_member(
    party_a_id, player_ids[4]
  );
  perform set_config('request.jwt.claim.sub', player_ids[4]::text, true);
  perform public.respond_open_queue_party_invitation(invitation_a_id, true);

  begin
    perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
    perform public.invite_open_queue_party_member(party_a_id, player_ids[6]);
  exception when others then
    if position('at most 4 players' in sqlerrm) > 0 then
      max_size_rejection_seen := true;
    else
      raise;
    end if;
  end;
  if not max_size_rejection_seen then
    raise exception 'A fifth active party seat was not rejected.';
  end if;

  perform set_config('request.jwt.claim.sub', player_ids[5]::text, true);
  invitation_b_id := public.invite_open_queue_party_member(
    party_b_id, player_ids[6]
  );
  perform set_config('request.jwt.claim.sub', player_ids[6]::text, true);
  perform public.respond_open_queue_party_invitation(invitation_b_id, true);

  -- A booked player remains discoverable even while already in another party.
  perform set_config('request.jwt.claim.sub', player_ids[5]::text, true);
  payload := public.get_open_queue_party_context(game_id_to_verify);
  if not exists (
    select 1
    from jsonb_array_elements(payload -> 'eligible_players') candidate
    where candidate ->> 'profile_id' = player_ids[3]::text
      and candidate ->> 'is_in_party' = 'true'
      and candidate ->> 'current_party_id' = party_a_id::text
  ) then
    raise exception 'A player in another party was hidden from eligible invitees.';
  end if;

  invitation_b_id := public.invite_open_queue_party_member(
    party_b_id, player_ids[3]
  );
  perform set_config('request.jwt.claim.sub', player_ids[3]::text, true);
  payload := public.respond_open_queue_party_invitation(invitation_b_id, true);
  if payload ->> 'switched_from_party_id' <> party_a_id::text
    or payload ->> 'previous_party_disbanded' <> 'false'
    or not exists (
      select 1 from public.open_queue_party_members member
      where member.party_id = party_a_id
        and member.profile_id = player_ids[3]
        and member.status = 'LEFT'
    ) or not exists (
      select 1 from public.open_queue_party_members member
      where member.party_id = party_b_id
        and member.profile_id = player_ids[3]
        and member.status = 'ACCEPTED'
    ) or not exists (
      select 1 from public.open_queue_parties party
      where party.id = party_a_id and party.status = 'ACTIVE'
    ) then
    raise exception 'Non-owner party switching was not atomic and scoped.';
  end if;

  perform set_config('request.jwt.claim.sub', player_ids[5]::text, true);
  invitation_b_id := public.invite_open_queue_party_member(
    party_b_id, player_ids[8]
  );
  perform set_config('request.jwt.claim.sub', player_ids[8]::text, true);
  perform public.respond_open_queue_party_invitation(invitation_b_id, true);

  if not public.open_queue_party_assignment_is_possible(game_id_to_verify) then
    raise exception 'Valid partial-roster parties failed placeholder validation.';
  end if;

  -- Complete the exact 2 GK / 4 DEF / 4 MID / 2 ATT roster. This verification
  -- game is deliberately far in the future, so the final booking makes it FULL
  -- without revealing teams before the three-hour cutoff.
  for slot in 9..12 loop
    insert into public.open_queue_bookings (
      game_id,
      profile_id,
      role,
      player_rating_at_booking,
      amount_paid_fils,
      base_amount_fils,
      payment_method,
      payment_status
    ) values (
      game_id_to_verify,
      player_ids[slot],
      (array['DEF', 'DEF', 'MID', 'MID'])[slot - 8],
      coalesce((
        select rating.skill_rating
        from public.player_ratings rating
        where rating.profile_id = player_ids[slot]
      ), 1200),
      3000,
      3000,
      'MOCK',
      'PAID'
    );
  end loop;

  if not exists (
    select 1 from public.open_queue_games game
    where game.id = game_id_to_verify and game.status = 'FULL'
      and game.teams_assigned_at is null
  ) then
    raise exception 'A future full party game revealed teams before the cutoff.';
  end if;
  if not public.open_queue_party_assignment_is_possible(game_id_to_verify) then
    raise exception 'Accepted parties no longer fit the exact team roles.';
  end if;
  if exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_verify and booking.status = 'CONFIRMED'
      and (
        booking.team is not null
        or booking.rating_at_team_assignment is not null
      )
  ) then
    raise exception 'A player received a team or SR snapshot before cutoff.';
  end if;

  -- Compatible party changes remain available after FULL until T-3h. They are
  -- captured now and honored later when the finalizer assigns teams.
  perform set_config('request.jwt.claim.sub', player_ids[9]::text, true);
  post_full_party_id := public.create_open_queue_party(game_id_to_verify);
  invitation_a_id := public.invite_open_queue_party_member(
    post_full_party_id, player_ids[11]
  );
  perform set_config('request.jwt.claim.sub', player_ids[11]::text, true);
  perform public.respond_open_queue_party_invitation(invitation_a_id, true);

  if not exists (
    select 1
    from public.open_queue_party_members first_member
    join public.open_queue_party_members second_member
      on second_member.party_id = first_member.party_id
    where first_member.party_id = post_full_party_id
      and first_member.profile_id = player_ids[9]
      and first_member.status = 'ACCEPTED'
      and second_member.profile_id = player_ids[11]
      and second_member.status = 'ACCEPTED'
  ) then
    raise exception 'A compatible party could not be accepted after FULL.';
  end if;

  perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
  select booking.id into player_one_booking_id
  from public.open_queue_bookings booking
  where booking.game_id = game_id_to_verify
    and booking.profile_id = player_ids[1]
    and booking.status = 'CONFIRMED';
  perform public.cancel_open_queue_booking(player_one_booking_id);

  if not exists (
    select 1 from public.open_queue_parties party
    where party.id = party_a_id
      and party.status = 'ACTIVE'
      and party.owner_profile_id = player_ids[2]
  ) then
    raise exception 'Cancelling leader booking did not hand party to oldest member.';
  end if;

  -- Restore the roster, create an invitation, then make the game LIVE. Context
  -- must hide the now-locked invitation and every mutation must fail.
  insert into public.open_queue_bookings (
    game_id, profile_id, role, player_rating_at_booking,
    amount_paid_fils, base_amount_fils, payment_method, payment_status
  ) values (
    game_id_to_verify, player_ids[1], 'GK', 1200, 3000, 3000, 'MOCK', 'PAID'
  );

  -- Booking cancellation hands leadership to player 2. Choosing to switch
  -- from that owner role must instead disband the old party and release every
  -- remaining member/invite atomically.
  perform set_config('request.jwt.claim.sub', player_ids[2]::text, true);
  old_party_pending_id := public.invite_open_queue_party_member(
    party_a_id, player_ids[7]
  );
  perform set_config('request.jwt.claim.sub', player_ids[9]::text, true);
  payload := public.get_open_queue_party_context(game_id_to_verify);
  if not exists (
    select 1
    from jsonb_array_elements(payload -> 'eligible_players') candidate
    where candidate ->> 'profile_id' = player_ids[2]::text
      and candidate ->> 'is_current_party_owner' = 'true'
  ) then
    raise exception 'An owner in another party was not visible/invitable.';
  end if;
  invitation_a_id := public.invite_open_queue_party_member(
    post_full_party_id, player_ids[2]
  );
  perform set_config('request.jwt.claim.sub', player_ids[2]::text, true);
  payload := public.respond_open_queue_party_invitation(invitation_a_id, true);
  if payload ->> 'switched_from_party_id' <> party_a_id::text
    or payload ->> 'previous_party_disbanded' <> 'true'
    or not exists (
      select 1 from public.open_queue_parties party
      where party.id = party_a_id and party.status = 'DISBANDED'
    ) or exists (
      select 1 from public.open_queue_party_members member
      where member.party_id = party_a_id
        and member.status in ('INVITED', 'ACCEPTED')
    ) or not exists (
      select 1 from public.open_queue_party_members member
      where member.id = old_party_pending_id and member.status = 'CANCELLED'
    ) or exists (
      select 1 from public.notifications notification
      where notification.related_entity_id = old_party_pending_id
        and notification.resolved_at is null
    ) or not exists (
      select 1 from public.open_queue_party_members member
      where member.party_id = post_full_party_id
        and member.profile_id = player_ids[2]
        and member.status = 'ACCEPTED'
    ) then
    raise exception 'Owner party switching did not disband/release the old party.';
  end if;

  perform set_config('request.jwt.claim.sub', player_ids[9]::text, true);
  invitation_a_id := public.invite_open_queue_party_member(
    post_full_party_id, player_ids[10]
  );
  insert into public.open_queue_clock_states (
    game_id, status, started_at, accumulated_seconds, duration_seconds
  ) values (
    game_id_to_verify, 'RUNNING', now(), 0, 3600
  );
  update public.open_queue_games set status = 'LIVE' where id = game_id_to_verify;

  perform set_config('request.jwt.claim.sub', player_ids[10]::text, true);
  payload := public.get_open_queue_party_context(game_id_to_verify);
  if payload ->> 'can_use_parties' <> 'false'
    or jsonb_array_length(payload -> 'received_invites') <> 0 then
    raise exception 'LIVE party context exposed an actionable invitation.';
  end if;
  begin
    perform public.respond_open_queue_party_invitation(invitation_a_id, true);
  exception when others then
    if position('no longer active' in lower(sqlerrm)) > 0
      or position('only available before' in lower(sqlerrm)) > 0 then
      live_rejection_seen := true;
    else
      raise;
    end if;
  end;
  if not live_rejection_seen then
    raise exception 'A party mutation was allowed after the game became LIVE.';
  end if;
  if exists (
    select 1 from public.notifications notification
    where notification.related_entity_id = invitation_a_id
      and notification.resolved_at is null
  ) then
    raise exception 'Kickoff did not resolve its remaining invitation notification.';
  end if;

  -- A two-goalkeeper party can never fit one GK per side. Reject it at accept
  -- time even though ten roster positions are still future placeholders.
  insert into public.open_queue_games (
    venue, starts_at, ends_at, created_by
  ) values (
    'Party verification pitch B',
    game_starts[2],
    game_starts[2] + interval '1 hour',
    player_ids[1]
  ) returning id into impossible_game_id;

  insert into public.open_queue_bookings (
    game_id, profile_id, role, player_rating_at_booking,
    amount_paid_fils, base_amount_fils, payment_method, payment_status
  ) values
    (impossible_game_id, player_ids[1], 'GK', 1200, 3000, 3000, 'MOCK', 'PAID'),
    (impossible_game_id, player_ids[5], 'GK', 1200, 3000, 3000, 'MOCK', 'PAID');

  perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
  impossible_party_id := public.create_open_queue_party(impossible_game_id);
  perform set_config('request.jwt.claim.sub', player_ids[5]::text, true);
  impossible_existing_party_id := public.create_open_queue_party(
    impossible_game_id
  );
  perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
  impossible_invitation_id := public.invite_open_queue_party_member(
    impossible_party_id, player_ids[5]
  );
  perform set_config('request.jwt.claim.sub', player_ids[5]::text, true);
  begin
    perform public.respond_open_queue_party_invitation(
      impossible_invitation_id, true
    );
  exception when others then
    if position('would make the required' in lower(sqlerrm)) > 0 then
      rejection_seen := true;
    else
      raise;
    end if;
  end;
  if not rejection_seen then
    raise exception 'An impossible two-GK party was accepted.';
  end if;
  if not exists (
    select 1 from public.open_queue_party_members member
    where member.id = impossible_invitation_id and member.status = 'INVITED'
  ) or not exists (
    select 1 from public.open_queue_parties party
    where party.id = impossible_existing_party_id
      and party.status = 'ACTIVE'
      and party.owner_profile_id = player_ids[5]
  ) or not exists (
    select 1 from public.open_queue_party_members member
    where member.party_id = impossible_existing_party_id
      and member.profile_id = player_ids[5]
      and member.status = 'ACCEPTED'
  ) then
    raise exception 'Rejected party switch did not restore the existing party atomically.';
  end if;

  perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
  select booking.id into impossible_owner_booking_id
  from public.open_queue_bookings booking
  where booking.game_id = impossible_game_id
    and booking.profile_id = player_ids[1]
    and booking.status = 'CONFIRMED';
  perform public.cancel_open_queue_booking(impossible_owner_booking_id);

  if not exists (
    select 1 from public.open_queue_parties party
    where party.id = impossible_party_id and party.status = 'DISBANDED'
  ) or not exists (
    select 1 from public.open_queue_party_members member
    where member.id = impossible_invitation_id and member.status = 'CANCELLED'
  ) then
    raise exception 'Sole leader booking cancellation did not disband and expire invitations.';
  end if;

  if has_table_privilege('authenticated', 'public.open_queue_parties', 'SELECT')
    or has_table_privilege('authenticated', 'public.open_queue_party_members', 'SELECT') then
    raise exception 'Private party tables are directly readable by authenticated clients.';
  end if;
  if not has_table_privilege(
    'authenticated', 'public.notifications', 'SELECT'
  ) or has_table_privilege(
    'authenticated', 'public.notifications', 'INSERT'
  ) or has_table_privilege(
    'authenticated', 'public.notifications', 'DELETE'
  ) then
    raise exception 'Notification recipient grants are not read-only.';
  end if;
  if exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notifications'
  ) then
    raise exception 'Notifications were not added to the Realtime publication.';
  end if;

  foreach party_function_signature in array array[
    'public.create_open_queue_party(uuid)',
    'public.invite_open_queue_party_member(uuid,uuid)',
    'public.respond_open_queue_party_invitation(uuid,boolean)',
    'public.cancel_open_queue_party_invitation(uuid)',
    'public.leave_open_queue_party(uuid)',
    'public.disband_open_queue_party(uuid)',
    'public.get_open_queue_party_context(uuid)',
    'public.list_my_open_queue_party_invite_notifications()'
  ] loop
    if position(
      'interval ''3 hours'''
      in pg_get_functiondef(to_regprocedure(party_function_signature))
    ) = 0 then
      raise exception 'Three-hour cutoff is missing from %.',
        party_function_signature;
    end if;
  end loop;

  if position(
    'interval ''3 hours'''
    in pg_get_functiondef(
      'public.assign_open_queue_teams(uuid)'::regprocedure
    )
  ) = 0 then
    raise exception 'Three-hour team assignment gate is missing.';
  end if;

  if not exists (
    select 1
    from cron.job
    where jobname =
      'finalize-open-queue-teams-three-hours-before-kickoff'
  ) then
    raise exception 'The three-hour team finalizer cron job is missing.';
  end if;
end;
$$;

rollback;
