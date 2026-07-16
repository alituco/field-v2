-- A newly suspended or banned player may already hold future solo bookings.
-- Release those places immediately so the match can refill and so a restricted
-- participant cannot block kickoff. Platform-enforced removals receive a full
-- refund; completed/rated matches are never touched.
create or replace function public.release_restricted_player_bookings()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.subject_type <> 'PLAYER'
    or new.action_type not in ('SUSPENSION', 'BAN')
    or new.restriction_scope not in ('PLAY', 'ACCOUNT')
    or new.revoked_at is not null
    or new.starts_at > now()
  then
    return new;
  end if;

  update public.open_queue_bookings booking
  set
    status = 'CANCELLED',
    team = null,
    played = false,
    rating_at_team_assignment = null,
    rating_at_match_start = null,
    rating_change = null,
    cancelled_at = now(),
    refund_percent = 100,
    refund_amount_fils = booking.amount_paid_fils,
    refund_status = 'PROCESSED',
    payment_status = 'REFUNDED'
  where booking.profile_id = new.subject_profile_id
    and booking.status = 'CONFIRMED'
    and exists (
      select 1
      from public.open_queue_games game
      where game.id = booking.game_id
        and game.status in ('OPEN', 'FULL')
        and game.starts_at > now()
    );

  return new;
end;
$$;

drop trigger if exists release_restricted_player_bookings
on public.moderation_actions;
create trigger release_restricted_player_bookings
after insert on public.moderation_actions
for each row execute function public.release_restricted_player_bookings();

revoke all on function public.release_restricted_player_bookings()
from public, anon, authenticated;

comment on function public.release_restricted_player_bookings() is
'Releases and fully refunds future solo bookings when a player play/account restriction starts.';
