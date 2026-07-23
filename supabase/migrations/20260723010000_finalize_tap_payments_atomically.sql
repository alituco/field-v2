-- Finalize verified Tap charges and their Field resource in one database
-- transaction. This prevents a captured payment from being separated from its
-- booking when the client closes or a network request is interrupted.

create or replace function public.book_open_queue_game(
  game_id_to_book uuid,
  role_to_book text,
  payment_method_to_use text,
  payment_reference_to_use text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  game_to_book public.open_queue_games%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  tap_intent_to_use public.tap_payment_intents%rowtype;
  rating_to_use integer;
  booking_id uuid;
  confirmed_count integer;
  active_strikes integer;
  deposit_threshold integer;
  deposit_bps_to_use integer;
  discount_bps_to_use integer := 0;
  base_amount_to_use integer;
  deposit_amount_to_use integer := 0;
  total_amount_to_use integer;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if role_to_book not in ('GK', 'DEF', 'MID', 'ATT') then
    raise exception 'Choose a valid position.';
  end if;
  if payment_method_to_use not in (
    'APPLE_PAY',
    'BENEFITPAY',
    'VISA',
    'MASTERCARD',
    'CARD',
    'MOCK'
  ) then
    raise exception 'Choose a valid payment method.';
  end if;

  perform pg_advisory_xact_lock(hashtext(user_id::text)::bigint);

  if public.profile_has_active_reliability_booking_restriction(user_id) then
    raise exception 'New bookings are unavailable while your reliability restriction is active.';
  end if;

  select * into game_to_book
  from public.open_queue_games game
  where game.id = game_id_to_book
  for update;

  if game_to_book.id is null then
    raise exception 'Open Queue game not found.';
  end if;
  if game_to_book.status <> 'OPEN' then
    raise exception 'This Open Queue game is full.';
  end if;
  if clock_timestamp() >= game_to_book.starts_at then
    raise exception 'This Open Queue game has already started.';
  end if;

  if exists (
    select 1
    from public.open_queue_bookings existing
    where existing.game_id = game_to_book.id
      and existing.profile_id = user_id
      and existing.status = 'CONFIRMED'
  ) then
    raise exception 'You already booked this Open Queue game.';
  end if;

  if exists (
    select 1
    from public.open_queue_bookings existing
    join public.open_queue_games other_game on other_game.id = existing.game_id
    where existing.profile_id = user_id
      and existing.status = 'CONFIRMED'
      and other_game.status in ('OPEN', 'FULL', 'LIVE')
      and tstzrange(other_game.starts_at, other_game.ends_at, '[)') &&
          tstzrange(game_to_book.starts_at, game_to_book.ends_at, '[)')
  ) then
    raise exception 'You already have another game at this time.';
  end if;

  terms_to_use := public.ensure_match_reliability_terms(
    'SOLO',
    game_to_book.id
  );
  if clock_timestamp() >= terms_to_use.check_in_deadline_at
    and not coalesce(
      (terms_to_use.policy_snapshot #>>
        '{replacement,postCheckInDeadlineMarketplaceEnabled}')::boolean,
      false
    )
  then
    raise exception 'Registration closed at the match check-in deadline.';
  end if;

  active_strikes := public.active_reliability_strikes(user_id);
  deposit_threshold := (terms_to_use.policy_snapshot #>>
    '{solo,reliabilityDeposit,activeStrikeThreshold}')::integer;
  deposit_bps_to_use := (terms_to_use.policy_snapshot #>>
    '{solo,reliabilityDeposit,depositBps}')::integer;

  if game_to_book.replacement_offer_expires_at > clock_timestamp()
    and game_to_book.replacement_discount_role = role_to_book
  then
    discount_bps_to_use := game_to_book.replacement_discount_bps;
  end if;

  base_amount_to_use := (
    game_to_book.price_fils::bigint * (10000 - discount_bps_to_use) / 10000
  )::integer;
  if active_strikes >= deposit_threshold then
    deposit_amount_to_use := ceiling(
      base_amount_to_use::numeric * deposit_bps_to_use / 10000
    )::integer;
  end if;
  total_amount_to_use := base_amount_to_use + deposit_amount_to_use;

  -- A mobile client cannot claim that a Tap payment happened by supplying a
  -- card brand and arbitrary reference. Every non-mock payment must match the
  -- captured, server-owned intent for this exact player, game, position, and
  -- authoritative total.
  if payment_method_to_use <> 'MOCK' then
    select * into tap_intent_to_use
    from public.tap_payment_intents intent
    where intent.profile_id = user_id
      and intent.purpose = 'SOLO_BOOKING'
      and intent.status = 'CAPTURED'
      and intent.tap_status = 'CAPTURED'
      and intent.tap_charge_id = nullif(trim(payment_reference_to_use), '')
      and intent.tap_payment_method = payment_method_to_use
      and intent.currency = 'BHD'
      and intent.amount_fils = total_amount_to_use
      and intent.payload ->> 'game_id' = game_to_book.id::text
      and upper(intent.payload ->> 'role') = role_to_book
    for update;

    if tap_intent_to_use.id is null then
      raise exception 'The captured payment could not be verified for this booking.';
    end if;
  end if;

  insert into public.player_ratings (profile_id)
  values (user_id)
  on conflict (profile_id) do nothing;

  select skill_rating into rating_to_use
  from public.player_ratings
  where profile_id = user_id
  for update;

  insert into public.open_queue_bookings (
    game_id,
    profile_id,
    role,
    player_rating_at_booking,
    amount_paid_fils,
    base_amount_fils,
    discount_bps,
    reliability_deposit_fils,
    reliability_deposit_status,
    reliability_policy_version_id,
    payment_method,
    payment_reference,
    tap_payment_intent_id,
    tap_charge_id
  ) values (
    game_to_book.id,
    user_id,
    role_to_book,
    rating_to_use,
    total_amount_to_use,
    base_amount_to_use,
    discount_bps_to_use,
    deposit_amount_to_use,
    case when deposit_amount_to_use > 0 then 'HELD' else 'NOT_REQUIRED' end,
    terms_to_use.policy_version_id,
    payment_method_to_use,
    nullif(trim(payment_reference_to_use), ''),
    tap_intent_to_use.id,
    tap_intent_to_use.tap_charge_id
  ) returning id into booking_id;

  if discount_bps_to_use > 0 then
    update public.open_queue_games
    set
      replacement_discount_bps = 0,
      replacement_discount_role = null,
      replacement_source_booking_id = null,
      replacement_offer_expires_at = null
    where id = game_to_book.id;
  end if;

  select count(*)::integer into confirmed_count
  from public.open_queue_bookings
  where game_id = game_to_book.id
    and status = 'CONFIRMED';

  if confirmed_count = game_to_book.capacity then
    perform public.assign_open_queue_teams(game_to_book.id);
  end if;

  return booking_id;
end;
$$;

create or replace function public.finalize_tap_payment_intent(
  intent_id_to_finalize uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  intent_to_finalize public.tap_payment_intents%rowtype;
  fixture_to_finalize public.fixtures%rowtype;
  resource_id_to_use uuid;
  resource_type_to_use text;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Only the payment service can finalize a Tap payment.';
  end if;

  select * into intent_to_finalize
  from public.tap_payment_intents intent
  where intent.id = intent_id_to_finalize
  for update;

  if intent_to_finalize.id is null then
    raise exception 'Payment attempt not found.';
  end if;

  if intent_to_finalize.status = 'FINALIZED' then
    return jsonb_build_object(
      'status', intent_to_finalize.status,
      'intent_id', intent_to_finalize.id,
      'charge_id', intent_to_finalize.tap_charge_id,
      'payment_method', intent_to_finalize.tap_payment_method,
      'resource_type', intent_to_finalize.resource_type,
      'resource_id', intent_to_finalize.resource_id
    );
  end if;

  if intent_to_finalize.status <> 'CAPTURED'
    or intent_to_finalize.tap_status <> 'CAPTURED'
    or intent_to_finalize.tap_charge_id is null
    or intent_to_finalize.tap_payment_method is null
  then
    raise exception 'Only a verified captured Tap payment can be finalized.';
  end if;

  if intent_to_finalize.tap_payment_method not in (
    'APPLE_PAY',
    'BENEFITPAY',
    'VISA',
    'MASTERCARD',
    'CARD'
  ) then
    raise exception 'The captured Tap payment method is unsupported.';
  end if;

  -- The existing domain functions contain the authoritative capacity,
  -- scheduling, sanctions, party, and clan-leadership rules. Impersonating the
  -- already-verified payer within this transaction lets us reuse those rules
  -- from both the client confirmation and the server-to-server webhook.
  perform set_config(
    'request.jwt.claim.sub',
    intent_to_finalize.profile_id::text,
    true
  );

  if intent_to_finalize.purpose = 'SOLO_BOOKING' then
    resource_id_to_use := public.book_open_queue_game(
      (intent_to_finalize.payload ->> 'game_id')::uuid,
      upper(intent_to_finalize.payload ->> 'role'),
      intent_to_finalize.tap_payment_method,
      intent_to_finalize.tap_charge_id
    );
    resource_type_to_use := 'OPEN_QUEUE_BOOKING';
  elsif intent_to_finalize.purpose = 'CLAN_CREATE' then
    fixture_to_finalize := public.create_fixture(
      (intent_to_finalize.payload ->> 'clan_id')::uuid,
      intent_to_finalize.payload ->> 'venue',
      (intent_to_finalize.payload ->> 'match_date')::date,
      intent_to_finalize.payload ->> 'time_slot'
    );
    resource_id_to_use := fixture_to_finalize.id;
    resource_type_to_use := 'FIXTURE';

    update public.fixtures
    set
      home_tap_payment_intent_id = intent_to_finalize.id,
      home_tap_charge_id = intent_to_finalize.tap_charge_id
    where id = resource_id_to_use;
  elsif intent_to_finalize.purpose = 'CLAN_JOIN' then
    fixture_to_finalize := public.join_fixture(
      (intent_to_finalize.payload ->> 'fixture_id')::uuid,
      (intent_to_finalize.payload ->> 'clan_id')::uuid
    );
    resource_id_to_use := fixture_to_finalize.id;
    resource_type_to_use := 'FIXTURE';

    update public.fixtures
    set
      away_tap_payment_intent_id = intent_to_finalize.id,
      away_tap_charge_id = intent_to_finalize.tap_charge_id
    where id = resource_id_to_use;
  else
    raise exception 'The payment purpose is unsupported.';
  end if;

  update public.tap_payment_intents
  set
    status = 'FINALIZED',
    resource_type = resource_type_to_use,
    resource_id = resource_id_to_use,
    finalized_at = clock_timestamp(),
    failure_reason = null
  where id = intent_to_finalize.id
  returning * into intent_to_finalize;

  return jsonb_build_object(
    'status', intent_to_finalize.status,
    'intent_id', intent_to_finalize.id,
    'charge_id', intent_to_finalize.tap_charge_id,
    'payment_method', intent_to_finalize.tap_payment_method,
    'resource_type', intent_to_finalize.resource_type,
    'resource_id', intent_to_finalize.resource_id
  );
end;
$$;

revoke all on function public.finalize_tap_payment_intent(uuid)
from public, anon, authenticated;
grant execute on function public.finalize_tap_payment_intent(uuid)
to service_role;

comment on function public.finalize_tap_payment_intent(uuid) is
'Atomically creates the paid Field resource and finalizes its verified captured Tap intent. Callable only by the service role.';
