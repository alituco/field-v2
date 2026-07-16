-- Follow-up to the deployed Open Queue party foundation. Booked players
-- remain discoverable across parties, switching is atomic, and invitations
-- create private recipient-owned notification/outbox rows.
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  type text not null check (char_length(trim(type)) between 2 and 64),
  title text not null check (char_length(trim(title)) between 2 and 120),
  body text not null check (char_length(trim(body)) between 2 and 300),
  related_entity_type text check (
    related_entity_type is null
    or char_length(trim(related_entity_type)) between 2 and 64
  ),
  related_entity_id uuid,
  data jsonb not null default '{}'::jsonb check (
    jsonb_typeof(data) = 'object'
  ),
  read_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (related_entity_type is null) = (related_entity_id is null)
  )
);

create index notifications_recipient_created_idx
on public.notifications (recipient_profile_id, created_at desc);

create index notifications_recipient_unread_idx
on public.notifications (recipient_profile_id, created_at desc)
where read_at is null and resolved_at is null;

create unique index notifications_active_party_invite_idx
on public.notifications (
  recipient_profile_id,
  type,
  related_entity_id
)
where type = 'OPEN_QUEUE_PARTY_INVITE' and resolved_at is null;

drop trigger if exists set_notifications_updated_at on public.notifications;
create trigger set_notifications_updated_at
before update on public.notifications
for each row execute function public.set_updated_at();

alter table public.notifications enable row level security;

revoke all on table public.notifications from public, anon, authenticated;
grant all on table public.notifications to service_role;

create policy notifications_recipient_select
on public.notifications
for select to authenticated
using (recipient_profile_id = auth.uid());

grant select on table public.notifications to authenticated;

-- Foreground clients receive invitation changes immediately; recipient RLS
-- still limits every Realtime row to its intended user.
do $$
begin
  if exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;

create or replace function public.create_open_queue_party_invite_notification(
  membership_id_to_use uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  invite record;
  notification_id_to_return uuid;
begin
  select
    member.id as membership_id,
    member.profile_id as recipient_profile_id,
    member.invited_by as inviter_profile_id,
    member.party_id,
    member.game_id,
    inviter.display_name as inviter_display_name,
    game.venue,
    game.starts_at
  into invite
  from public.open_queue_party_members member
  join public.open_queue_parties party
    on party.id = member.party_id and party.status = 'ACTIVE'
  join public.profiles inviter on inviter.id = member.invited_by
  join public.open_queue_games game on game.id = member.game_id
  where member.id = membership_id_to_use
    and member.status = 'INVITED';

  if invite.membership_id is null then
    raise exception 'An active party invitation is required for its notification.';
  end if;

  insert into public.notifications (
    recipient_profile_id,
    type,
    title,
    body,
    related_entity_type,
    related_entity_id,
    data
  ) values (
    invite.recipient_profile_id,
    'OPEN_QUEUE_PARTY_INVITE',
    'Party invite from ' || invite.inviter_display_name,
    invite.inviter_display_name || ' wants to team up for your solo game at '
      || invite.venue || '.',
    'OPEN_QUEUE_PARTY_MEMBERSHIP',
    invite.membership_id,
    jsonb_build_object(
      'game_id', invite.game_id,
      'party_id', invite.party_id,
      'membership_id', invite.membership_id,
      'inviter_profile_id', invite.inviter_profile_id,
      'starts_at', invite.starts_at
    )
  )
  on conflict (recipient_profile_id, type, related_entity_id)
    where type = 'OPEN_QUEUE_PARTY_INVITE' and resolved_at is null
  do update set
    title = excluded.title,
    body = excluded.body,
    data = excluded.data,
    read_at = null,
    created_at = clock_timestamp()
  returning id into notification_id_to_return;

  return notification_id_to_return;
end;
$$;

create or replace function public.resolve_open_queue_party_invite_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  membership_id_to_resolve uuid;
begin
  membership_id_to_resolve := old.id;

  if tg_op = 'UPDATE' then
    if old.status <> 'INVITED' or new.status = 'INVITED' then
      return new;
    end if;
  elsif old.status <> 'INVITED' then
    return old;
  end if;

  update public.notifications notification
  set resolved_at = coalesce(notification.resolved_at, clock_timestamp())
  where notification.type = 'OPEN_QUEUE_PARTY_INVITE'
    and notification.related_entity_type = 'OPEN_QUEUE_PARTY_MEMBERSHIP'
    and notification.related_entity_id = membership_id_to_resolve
    and notification.resolved_at is null;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function public.invite_open_queue_party_member(
  party_id_to_use uuid,
  target_profile_id_to_use uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  party_to_use public.open_queue_parties%rowtype;
  game_to_use public.open_queue_games%rowtype;
  existing_member public.open_queue_party_members%rowtype;
  membership_id_to_return uuid;
  active_seat_count integer;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if target_profile_id_to_use is null or target_profile_id_to_use = user_id then
    raise exception 'Choose another booked player to invite.';
  end if;

  select party.* into party_to_use
  from public.open_queue_parties party
  where party.id = party_id_to_use;
  if party_to_use.id is null then
    raise exception 'Party not found.';
  end if;

  select * into game_to_use
  from public.open_queue_games game
  where game.id = party_to_use.game_id
  for update;
  select * into party_to_use
  from public.open_queue_parties party
  where party.id = party_id_to_use
  for update;

  if party_to_use.status <> 'ACTIVE' then
    raise exception 'This party is no longer active.';
  end if;
  if party_to_use.owner_profile_id <> user_id then
    raise exception 'Only the party leader can invite players.';
  end if;
  if game_to_use.status not in ('OPEN', 'FULL') or now() >= game_to_use.starts_at then
    raise exception 'Parties are only available before this solo game starts.';
  end if;
  if not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = party_to_use.game_id
      and booking.profile_id = target_profile_id_to_use
      and booking.status = 'CONFIRMED'
  ) then
    raise exception 'That player does not have a confirmed booking in this game.';
  end if;
  select * into existing_member
  from public.open_queue_party_members member
  where member.party_id = party_id_to_use
    and member.profile_id = target_profile_id_to_use
  for update;

  if existing_member.status in ('INVITED', 'ACCEPTED') then
    raise exception 'This player is already in or invited to this party.';
  end if;

  select count(*)::integer into active_seat_count
  from public.open_queue_party_members member
  where member.party_id = party_id_to_use
    and member.status in ('ACCEPTED', 'INVITED');
  if active_seat_count >= 4 then
    raise exception 'A party can have at most 4 players, including pending invitations.';
  end if;

  if existing_member.id is not null then
    update public.open_queue_party_members
    set
      status = 'INVITED',
      invited_by = user_id,
      invited_at = clock_timestamp(),
      responded_at = null,
      joined_at = null,
      ended_at = null
    where id = existing_member.id
    returning id into membership_id_to_return;
  else
    insert into public.open_queue_party_members (
      party_id, game_id, profile_id, status, invited_by
    ) values (
      party_id_to_use, party_to_use.game_id,
      target_profile_id_to_use, 'INVITED', user_id
    ) returning id into membership_id_to_return;
  end if;

  perform public.create_open_queue_party_invite_notification(
    membership_id_to_return
  );
  return membership_id_to_return;
end;
$$;

create or replace function public.respond_open_queue_party_invitation(
  membership_id_to_use uuid,
  accept_to_use boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  membership_to_use public.open_queue_party_members%rowtype;
  party_to_use public.open_queue_parties%rowtype;
  game_to_use public.open_queue_games%rowtype;
  accepted_count_to_return integer;
  previous_membership_id uuid;
  previous_party_id uuid;
  previous_party_owner_id uuid;
  previous_party_disbanded boolean := false;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if accept_to_use is null then
    raise exception 'Choose whether to accept or decline this invitation.';
  end if;

  select * into membership_to_use
  from public.open_queue_party_members member
  where member.id = membership_id_to_use;
  if membership_to_use.id is null or membership_to_use.profile_id <> user_id then
    raise exception 'Party invitation not found.';
  end if;

  select * into game_to_use
  from public.open_queue_games game
  where game.id = membership_to_use.game_id
  for update;
  select * into party_to_use
  from public.open_queue_parties party
  where party.id = membership_to_use.party_id
  for update;
  select * into membership_to_use
  from public.open_queue_party_members member
  where member.id = membership_id_to_use
  for update;

  if membership_to_use.status <> 'INVITED' or party_to_use.status <> 'ACTIVE' then
    raise exception 'This party invitation is no longer active.';
  end if;
  if game_to_use.status not in ('OPEN', 'FULL') or now() >= game_to_use.starts_at then
    raise exception 'Parties are only available before this solo game starts.';
  end if;
  if not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = membership_to_use.game_id
      and booking.profile_id = user_id
      and booking.status = 'CONFIRMED'
  ) then
    raise exception 'You need a confirmed booking in this solo game.';
  end if;

  if not accept_to_use then
    update public.open_queue_party_members
    set status = 'DECLINED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
    where id = membership_id_to_use;

    select count(*)::integer into accepted_count_to_return
    from public.open_queue_party_members member
    where member.party_id = membership_to_use.party_id
      and member.status = 'ACCEPTED';

    return jsonb_build_object(
      'membership_id', membership_id_to_use,
      'party_id', membership_to_use.party_id,
      'status', 'DECLINED',
      'accepted_count', accepted_count_to_return
    );
  end if;

  select count(*)::integer into accepted_count_to_return
  from public.open_queue_party_members member
  where member.party_id = membership_to_use.party_id
    and member.status = 'ACCEPTED';
  if accepted_count_to_return >= 4 then
    raise exception 'This party already has 4 players.';
  end if;

  -- Switching is atomic. Removing the old membership, accepting the new one,
  -- cancelling other invitations, feasibility validation, and any FULL-game
  -- reassignment all commit or roll back together.
  select
    member.id,
    party.id,
    party.owner_profile_id
  into
    previous_membership_id,
    previous_party_id,
    previous_party_owner_id
  from public.open_queue_party_members member
  join public.open_queue_parties party on party.id = member.party_id
  where member.game_id = membership_to_use.game_id
    and member.profile_id = user_id
    and member.status = 'ACCEPTED'
    and party.status = 'ACTIVE'
    and party.id <> membership_to_use.party_id
  for update of party, member;

  if previous_membership_id is not null then
    if previous_party_owner_id = user_id then
      -- An owner choosing another party explicitly cancels the old party. Do
      -- not silently transfer ownership in this opt-in switching workflow.
      update public.open_queue_parties
      set status = 'DISBANDED', ended_at = clock_timestamp()
      where id = previous_party_id;

      update public.open_queue_party_members
      set
        status = case when status = 'INVITED' then 'CANCELLED' else 'LEFT' end,
        responded_at = coalesce(responded_at, clock_timestamp()),
        ended_at = clock_timestamp()
      where party_id = previous_party_id
        and status in ('INVITED', 'ACCEPTED');

      previous_party_disbanded := true;
    else
      update public.open_queue_party_members
      set status = 'LEFT', ended_at = clock_timestamp()
      where id = previous_membership_id;
    end if;
  end if;

  update public.open_queue_party_members
  set status = 'ACCEPTED', responded_at = clock_timestamp(), joined_at = clock_timestamp()
  where id = membership_id_to_use;

  update public.open_queue_party_members member
  set status = 'CANCELLED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
  from public.open_queue_parties party
  where member.party_id = party.id
    and member.game_id = membership_to_use.game_id
    and member.profile_id = user_id
    and member.status = 'INVITED'
    and member.id <> membership_id_to_use
    and party.status = 'ACTIVE';

  if not public.open_queue_party_assignment_is_possible(membership_to_use.game_id) then
    raise exception 'Joining this party would make the required 1 GK, 2 DEF, 2 MID, and 1 ATT teams impossible.';
  end if;

  perform public.reassign_open_queue_teams_after_party_change(
    membership_to_use.game_id
  );

  select count(*)::integer into accepted_count_to_return
  from public.open_queue_party_members member
  where member.party_id = membership_to_use.party_id
    and member.status = 'ACCEPTED';

  return jsonb_build_object(
    'membership_id', membership_id_to_use,
    'party_id', membership_to_use.party_id,
    'status', 'ACCEPTED',
    'accepted_count', accepted_count_to_return,
    'switched_from_party_id', previous_party_id,
    'previous_party_disbanded', previous_party_disbanded
  );
end;
$$;

create or replace function public.close_cancelled_open_queue_parties()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('LIVE', 'FINAL', 'CANCELLED')
    and old.status in ('OPEN', 'FULL')
  then
    -- Pending invitations expire at kickoff; accepted party composition stays
    -- available as match history unless the match itself is cancelled.
    update public.open_queue_party_members member
    set
      status = 'CANCELLED',
      responded_at = clock_timestamp(),
      ended_at = clock_timestamp()
    from public.open_queue_parties party
    where member.party_id = party.id
      and party.game_id = new.id
      and party.status = 'ACTIVE'
      and member.status = 'INVITED';
  end if;

  if new.status = 'CANCELLED' and old.status <> 'CANCELLED' then
    update public.open_queue_party_members member
    set
      status = 'LEFT',
      responded_at = coalesce(member.responded_at, clock_timestamp()),
      ended_at = clock_timestamp()
    from public.open_queue_parties party
    where member.party_id = party.id
      and party.game_id = new.id
      and party.status = 'ACTIVE'
      and member.status = 'ACCEPTED';

    update public.open_queue_parties
    set status = 'DISBANDED', ended_at = clock_timestamp()
    where game_id = new.id
      and status = 'ACTIVE';
  end if;
  return new;
end;
$$;

create or replace function public.get_open_queue_party_context(
  game_id_to_use uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  game_to_use public.open_queue_games%rowtype;
  my_party_id uuid;
  my_party_payload jsonb;
  received_invites_payload jsonb;
  eligible_players_payload jsonb;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into game_to_use
  from public.open_queue_games game
  where game.id = game_id_to_use;
  if game_to_use.id is null then
    raise exception 'Open Queue game not found.';
  end if;
  if not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = game_id_to_use
      and booking.profile_id = user_id
      and booking.status = 'CONFIRMED'
  ) then
    raise exception 'You need a confirmed booking in this solo game.';
  end if;

  select party.id into my_party_id
  from public.open_queue_party_members member
  join public.open_queue_parties party on party.id = member.party_id
  where member.game_id = game_id_to_use
    and member.profile_id = user_id
    and member.status = 'ACCEPTED'
    and party.status = 'ACTIVE'
  limit 1;

  if my_party_id is not null then
    select jsonb_build_object(
      'id', party.id,
      'owner_profile_id', party.owner_profile_id,
      'is_owner', party.owner_profile_id = user_id,
      'accepted_count', (
        select count(*)::integer
        from public.open_queue_party_members accepted
        where accepted.party_id = party.id and accepted.status = 'ACCEPTED'
      ),
      'invited_count', (
        select count(*)::integer
        from public.open_queue_party_members invited
        where invited.party_id = party.id and invited.status = 'INVITED'
      ),
      'members', (
        select coalesce(jsonb_agg(
          jsonb_build_object(
            'membership_id', member.id,
            'profile_id', member.profile_id,
            'display_name', profile.display_name,
            'username', profile.username,
            'avatar_url', profile.avatar_url,
            'role', booking.role,
            'position', booking.role,
            'status', member.status,
            'is_owner', member.profile_id = party.owner_profile_id,
            'invited_at', member.invited_at,
            'joined_at', member.joined_at
          ) order by
            (member.profile_id = party.owner_profile_id) desc,
            member.joined_at nulls last,
            member.invited_at,
            member.id
        ), '[]'::jsonb)
        from public.open_queue_party_members member
        join public.profiles profile on profile.id = member.profile_id
        join public.open_queue_bookings booking
          on booking.game_id = member.game_id
          and booking.profile_id = member.profile_id
          and booking.status = 'CONFIRMED'
        where member.party_id = party.id
          and member.status in ('ACCEPTED', 'INVITED')
      )
    ) into my_party_payload
    from public.open_queue_parties party
    where party.id = my_party_id;
  end if;

  select coalesce(jsonb_agg(invitation.payload order by invitation.invited_at), '[]'::jsonb)
  into received_invites_payload
  from (
    select
      member.invited_at,
      jsonb_build_object(
        'membership_id', member.id,
        'party_id', party.id,
        'invited_at', member.invited_at,
        'accepted_count', (
          select count(*)::integer
          from public.open_queue_party_members accepted
          where accepted.party_id = party.id and accepted.status = 'ACCEPTED'
        ),
        'owner', jsonb_build_object(
          'profile_id', owner_profile.id,
          'display_name', owner_profile.display_name,
          'username', owner_profile.username,
          'avatar_url', owner_profile.avatar_url,
          'role', owner_booking.role,
          'position', owner_booking.role
        ),
        'members', (
          select coalesce(jsonb_agg(
            jsonb_build_object(
              'membership_id', accepted.id,
              'profile_id', accepted.profile_id,
              'display_name', accepted_profile.display_name,
              'username', accepted_profile.username,
              'avatar_url', accepted_profile.avatar_url,
              'role', accepted_booking.role,
              'position', accepted_booking.role,
              'status', accepted.status,
              'is_owner', accepted.profile_id = party.owner_profile_id,
              'invited_at', accepted.invited_at,
              'joined_at', accepted.joined_at
            ) order by
              (accepted.profile_id = party.owner_profile_id) desc,
              accepted.joined_at,
              accepted.id
          ), '[]'::jsonb)
          from public.open_queue_party_members accepted
          join public.profiles accepted_profile on accepted_profile.id = accepted.profile_id
          join public.open_queue_bookings accepted_booking
            on accepted_booking.game_id = accepted.game_id
            and accepted_booking.profile_id = accepted.profile_id
            and accepted_booking.status = 'CONFIRMED'
          where accepted.party_id = party.id
            and accepted.status = 'ACCEPTED'
        )
      ) as payload
    from public.open_queue_party_members member
    join public.open_queue_parties party
      on party.id = member.party_id and party.status = 'ACTIVE'
    join public.profiles owner_profile on owner_profile.id = party.owner_profile_id
    join public.open_queue_bookings owner_booking
      on owner_booking.game_id = party.game_id
      and owner_booking.profile_id = party.owner_profile_id
      and owner_booking.status = 'CONFIRMED'
    where member.game_id = game_id_to_use
      and member.profile_id = user_id
      and member.status = 'INVITED'
      and game_to_use.status in ('OPEN', 'FULL')
      and now() < game_to_use.starts_at
  ) invitation;

  if my_party_id is not null and exists (
    select 1 from public.open_queue_parties party
    where party.id = my_party_id and party.owner_profile_id = user_id
  ) and game_to_use.status in ('OPEN', 'FULL') and now() < game_to_use.starts_at then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'profile_id', profile.id,
        'display_name', profile.display_name,
        'username', profile.username,
        'avatar_url', profile.avatar_url,
        'role', booking.role,
        'position', booking.role,
        'is_in_party', current_party.party_id is not null,
        'current_party_id', current_party.party_id,
        'is_current_party_owner',
          current_party.owner_profile_id = booking.profile_id,
        'current_party_size', current_party.accepted_count
      ) order by lower(profile.display_name), profile.id
    ), '[]'::jsonb)
    into eligible_players_payload
    from public.open_queue_bookings booking
    join public.profiles profile on profile.id = booking.profile_id
    left join lateral (
      select
        party.id as party_id,
        party.owner_profile_id,
        count(*)::integer as accepted_count
      from public.open_queue_party_members accepted_member
      join public.open_queue_parties party
        on party.id = accepted_member.party_id
        and party.status = 'ACTIVE'
      join public.open_queue_party_members party_member
        on party_member.party_id = party.id
        and party_member.status = 'ACCEPTED'
      where accepted_member.game_id = game_id_to_use
        and accepted_member.profile_id = booking.profile_id
        and accepted_member.status = 'ACCEPTED'
      group by party.id, party.owner_profile_id
      limit 1
    ) current_party on true
    where booking.game_id = game_id_to_use
      and booking.status = 'CONFIRMED'
      and booking.profile_id <> user_id
      and not exists (
        select 1
        from public.open_queue_party_members same_party_member
        where same_party_member.party_id = my_party_id
          and same_party_member.profile_id = booking.profile_id
          and same_party_member.status in ('INVITED', 'ACCEPTED')
      );
  else
    eligible_players_payload := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'game_id', game_to_use.id,
    'game_status', game_to_use.status,
    'can_use_parties', game_to_use.status in ('OPEN', 'FULL')
      and now() < game_to_use.starts_at,
    'max_party_size', 4,
    'my_party', my_party_payload,
    'received_invites', coalesce(received_invites_payload, '[]'::jsonb),
    'eligible_players', coalesce(eligible_players_payload, '[]'::jsonb)
  );
end;
$$;

create or replace function public.list_my_open_queue_party_invite_notifications()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  result jsonb;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'notification_id', notification.id,
      'type', notification.type,
      'game_id', member.game_id,
      'party_id', member.party_id,
      'membership_id', member.id,
      'created_at', notification.created_at,
      'read_at', notification.read_at,
      'is_read', notification.read_at is not null,
      'inviter', jsonb_build_object(
        'profile_id', inviter.id,
        'display_name', inviter.display_name,
        'username', inviter.username,
        'avatar_url', inviter.avatar_url
      ),
      'game', jsonb_build_object(
        'starts_at', game.starts_at,
        'venue', game.venue,
        'status', game.status
      )
    ) order by notification.created_at desc, notification.id desc
  ), '[]'::jsonb)
  into result
  from public.notifications notification
  join public.open_queue_party_members member
    on member.id = notification.related_entity_id
    and member.status = 'INVITED'
  join public.open_queue_parties party
    on party.id = member.party_id
    and party.status = 'ACTIVE'
  join public.open_queue_games game
    on game.id = member.game_id
    and game.status in ('OPEN', 'FULL')
    and now() < game.starts_at
  join public.profiles inviter on inviter.id = member.invited_by
  where notification.recipient_profile_id = user_id
    and notification.type = 'OPEN_QUEUE_PARTY_INVITE'
    and notification.related_entity_type = 'OPEN_QUEUE_PARTY_MEMBERSHIP'
    and notification.resolved_at is null;

  return result;
end;
$$;

create or replace function public.mark_my_open_queue_party_invite_notification_read(
  notification_id_to_use uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  notification_to_return public.notifications%rowtype;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  update public.notifications notification
  set read_at = coalesce(notification.read_at, clock_timestamp())
  where notification.id = notification_id_to_use
    and notification.recipient_profile_id = user_id
    and notification.type = 'OPEN_QUEUE_PARTY_INVITE'
  returning notification.* into notification_to_return;

  if notification_to_return.id is null then
    raise exception 'Party invitation notification not found.';
  end if;

  return jsonb_build_object(
    'notification_id', notification_to_return.id,
    'read_at', notification_to_return.read_at,
    'is_read', true,
    'resolved_at', notification_to_return.resolved_at
  );
end;
$$;

drop trigger if exists resolve_open_queue_party_invite_notification
on public.open_queue_party_members;
create trigger resolve_open_queue_party_invite_notification
after update of status or delete on public.open_queue_party_members
for each row execute function public.resolve_open_queue_party_invite_notification();

revoke all on function public.create_open_queue_party_invite_notification(uuid)
from public, anon, authenticated;
revoke all on function public.resolve_open_queue_party_invite_notification()
from public, anon, authenticated;

revoke all on function public.list_my_open_queue_party_invite_notifications()
from public, anon, authenticated;
grant execute on function public.list_my_open_queue_party_invite_notifications()
to authenticated;

revoke all on function public.mark_my_open_queue_party_invite_notification_read(uuid)
from public, anon, authenticated;
grant execute on function public.mark_my_open_queue_party_invite_notification_read(uuid)
to authenticated;

comment on table public.notifications is
'Recipient-owned in-app notification rows retained for read state and a future push delivery outbox.';
