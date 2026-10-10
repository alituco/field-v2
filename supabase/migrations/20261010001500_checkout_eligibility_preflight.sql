-- Reject known ineligible checkouts BEFORE charging a card. Final booking
-- checks remain authoritative under locks for capacity/profile/rule races.
do $migration$
declare definition text;
begin
  definition:=pg_get_functiondef('public.preview_open_queue_booking_cost(uuid,text)'::regprocedure);
  definition:=replace(definition,'''reliability_deposit_return_destination'', ''FIELD_WALLET''',
    '''reliability_deposit_return_destination'', ''ORIGINAL_PAYMENT_METHOD'', ''refund_destination'', ''ORIGINAL_PAYMENT_METHOD''');
  definition:=replace(definition,'  if normalized_role not in', $guard$
  if not public.is_fieldrush_account_active(user_id) then
    raise exception 'Complete your account setup before booking a game.';
  end if;
  if public.profile_has_active_reliability_booking_restriction(user_id) then
    raise exception 'New bookings are unavailable while your reliability restriction is active.';
  end if;
  if normalized_role not in$guard$);
  definition:=replace(definition,'  terms_to_use := public.ensure_match_reliability_terms(', $guard$
  if exists(select 1 from public.open_queue_bookings existing where existing.game_id=game_to_book.id
    and existing.profile_id=user_id and existing.status='CONFIRMED') then
    raise exception 'You already booked this Open Queue game.';
  end if;
  if exists(select 1 from public.open_queue_bookings existing
    join public.open_queue_games other_game on other_game.id=existing.game_id
    where existing.profile_id=user_id and existing.status='CONFIRMED' and other_game.status in ('OPEN','FULL','LIVE')
      and tstzrange(other_game.starts_at,other_game.ends_at,'[)') && tstzrange(game_to_book.starts_at,game_to_book.ends_at,'[)')) then
    raise exception 'You already have another game at this time.';
  end if;
  if game_to_book.currency<>'USD' then
    raise exception 'This legacy game does not support new bookings. Please choose a USD game.';
  end if;
  terms_to_use := public.ensure_match_reliability_terms($guard$);
  execute definition;
end;
$migration$;
