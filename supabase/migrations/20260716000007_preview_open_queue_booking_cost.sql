-- Quote the exact authoritative amount that book_open_queue_game will charge.
-- The quote deliberately repeats the booking function's calculation against
-- the same per-match policy snapshot so the client never presents price_fils
-- while a reliability deposit or replacement discount changes the total.

create or replace function public.preview_open_queue_booking_cost(
  game_id_to_book uuid,
  role_to_book text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  normalized_role text := upper(trim(coalesce(role_to_book, '')));
  game_to_book public.open_queue_games%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  server_now_to_use timestamptz := clock_timestamp();
  active_strikes integer;
  deposit_threshold integer;
  deposit_bps_to_use integer;
  discount_bps_to_use integer := 0;
  match_fee_fils integer;
  deposit_amount_fils integer := 0;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if normalized_role not in ('GK', 'DEF', 'MID', 'ATT') then
    raise exception 'Choose a valid position.';
  end if;

  select * into game_to_book
  from public.open_queue_games game
  where game.id = game_id_to_book;
  if game_to_book.id is null then
    raise exception 'Open Queue game not found.';
  end if;
  if game_to_book.status not in ('OPEN', 'FULL')
    or server_now_to_use >= game_to_book.starts_at
  then
    raise exception 'This Open Queue game is no longer available.';
  end if;

  terms_to_use := public.ensure_match_reliability_terms(
    'SOLO',
    game_to_book.id
  );
  if server_now_to_use >= terms_to_use.check_in_deadline_at
    and not (terms_to_use.policy_snapshot #>>
      '{replacement,postCheckInDeadlineMarketplaceEnabled}')::boolean
  then
    raise exception 'Registration closed at the match check-in deadline.';
  end if;
  active_strikes := public.active_reliability_strikes(
    user_id,
    server_now_to_use
  );
  deposit_threshold := (terms_to_use.policy_snapshot #>>
    '{solo,reliabilityDeposit,activeStrikeThreshold}')::integer;
  deposit_bps_to_use := (terms_to_use.policy_snapshot #>>
    '{solo,reliabilityDeposit,depositBps}')::integer;

  if game_to_book.replacement_offer_expires_at > server_now_to_use
    and game_to_book.replacement_discount_role = normalized_role
  then
    discount_bps_to_use := game_to_book.replacement_discount_bps;
  end if;

  match_fee_fils := (
    game_to_book.price_fils::bigint
      * (10000 - discount_bps_to_use)
      / 10000
  )::integer;
  if active_strikes >= deposit_threshold then
    deposit_amount_fils := ceiling(
      match_fee_fils::numeric * deposit_bps_to_use / 10000
    )::integer;
  end if;

  return jsonb_build_object(
    'server_now', server_now_to_use,
    'policy_version_id', terms_to_use.policy_version_id,
    'currency', 'BHD',
    'standard_match_fee_fils', game_to_book.price_fils,
    'replacement_discount_bps', discount_bps_to_use,
    'discount_amount_fils', game_to_book.price_fils - match_fee_fils,
    'match_fee_fils', match_fee_fils,
    'active_strikes', active_strikes,
    'deposit_threshold', deposit_threshold,
    'reliability_deposit_required', active_strikes >= deposit_threshold,
    'reliability_deposit_bps', deposit_bps_to_use,
    'reliability_deposit_fils', deposit_amount_fils,
    'reliability_deposit_return_destination', 'FIELD_WALLET',
    'total_fils', match_fee_fils + deposit_amount_fils,
    'replacement_offer_expires_at', case
      when discount_bps_to_use > 0
        then game_to_book.replacement_offer_expires_at
      else null
    end
  );
end;
$$;

revoke all on function public.preview_open_queue_booking_cost(uuid, text)
from public, anon, authenticated;
grant execute on function public.preview_open_queue_booking_cost(uuid, text)
to authenticated;

comment on function public.preview_open_queue_booking_cost(uuid, text) is
'Returns the policy-snapshotted match fee, replacement discount, refundable reliability deposit, and exact total immediately before solo checkout.';
