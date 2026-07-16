create or replace function public.preview_open_queue_cancellation(
  booking_id_to_preview uuid
)
returns table (
  can_cancel boolean,
  refund_percent integer,
  refund_amount_fils integer,
  refund_cutoff_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  booking_to_preview public.open_queue_bookings%rowtype;
  game_to_preview public.open_queue_games%rowtype;
  cutoff_at timestamptz;
  percent_to_refund integer;
  has_rating_events boolean;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into booking_to_preview
  from public.open_queue_bookings
  where id = booking_id_to_preview
    and profile_id = user_id;

  if booking_to_preview.id is null then
    raise exception 'Booking not found.';
  end if;

  select * into game_to_preview
  from public.open_queue_games
  where id = booking_to_preview.game_id;

  select exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game_to_preview.id
  ) into has_rating_events;

  cutoff_at := (
    (game_to_preview.starts_at at time zone game_to_preview.timezone)::date::timestamp
    at time zone game_to_preview.timezone
  );
  percent_to_refund := case when now() < cutoff_at then 50 else 0 end;

  return query select
    booking_to_preview.status = 'CONFIRMED'
      and game_to_preview.status in ('OPEN', 'FULL')
      and game_to_preview.white_score is null
      and game_to_preview.black_score is null
      and not has_rating_events
      and now() < game_to_preview.starts_at,
    percent_to_refund,
    (booking_to_preview.amount_paid_fils * percent_to_refund / 100),
    cutoff_at;
end;
$$;

create or replace function public.cancel_open_queue_booking(
  booking_id_to_cancel uuid
)
returns public.open_queue_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  booking_to_cancel public.open_queue_bookings%rowtype;
  game_to_reopen public.open_queue_games%rowtype;
  cutoff_at timestamptz;
  percent_to_refund integer;
  cancelled_booking public.open_queue_bookings%rowtype;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select game.* into game_to_reopen
  from public.open_queue_bookings booking
  join public.open_queue_games game on game.id = booking.game_id
  where booking.id = booking_id_to_cancel
    and booking.profile_id = user_id
  for update of game;

  if game_to_reopen.id is null then
    raise exception 'Booking not found.';
  end if;

  select * into booking_to_cancel
  from public.open_queue_bookings
  where id = booking_id_to_cancel
    and profile_id = user_id
  for update;

  if booking_to_cancel.status <> 'CONFIRMED' then
    raise exception 'This booking is already cancelled.';
  end if;

  if game_to_reopen.status not in ('OPEN', 'FULL')
    or game_to_reopen.white_score is not null
    or game_to_reopen.black_score is not null
    or exists (
      select 1
      from public.player_rating_events event
      where event.source_type = 'OPEN_QUEUE'
        and event.source_id = game_to_reopen.id
    )
  then
    raise exception 'This match has already been played and can no longer be cancelled.';
  end if;

  if now() >= game_to_reopen.starts_at then
    raise exception 'This game has already started.';
  end if;

  cutoff_at := (
    (game_to_reopen.starts_at at time zone game_to_reopen.timezone)::date::timestamp
    at time zone game_to_reopen.timezone
  );
  percent_to_refund := case when now() < cutoff_at then 50 else 0 end;

  update public.open_queue_bookings
  set
    status = 'CANCELLED',
    team = null,
    cancelled_at = now(),
    refund_percent = percent_to_refund,
    refund_amount_fils = amount_paid_fils * percent_to_refund / 100,
    refund_status = case when percent_to_refund > 0 then 'DUE' else 'NOT_DUE' end,
    payment_status = case
      when percent_to_refund > 0 then 'PARTIALLY_REFUNDED'
      else 'NO_REFUND'
    end
  where id = booking_to_cancel.id
  returning * into cancelled_booking;

  update public.open_queue_bookings
  set team = null
  where game_id = game_to_reopen.id
    and status = 'CONFIRMED';

  return cancelled_booking;
end;
$$;

comment on function public.preview_open_queue_cancellation(uuid) is
  'Previews refunds only for unplayed OPEN or FULL solo bookings.';

comment on function public.cancel_open_queue_booking(uuid) is
  'Cancels only unplayed OPEN or FULL solo bookings and preserves completed rated lineups.';
