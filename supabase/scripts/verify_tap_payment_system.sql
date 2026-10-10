begin;

do $verify$
declare
  game_id_to_test uuid;
  profile_id_to_test uuid;
  role_to_test text;
  quote_to_test jsonb;
  intent_id_to_test uuid := gen_random_uuid();
  finalized jsonb;
  linked_booking public.open_queue_bookings%rowtype;
  forged_rejected boolean := false;
begin
  if not has_function_privilege(
    'authenticated',
    'public.book_open_queue_game(uuid,text,text,text)',
    'EXECUTE'
  ) then
    raise exception
      'Authenticated clients cannot submit a server-verified booking.';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.book_open_queue_game_server(uuid,text,text,text)',
    'EXECUTE'
  ) then
    raise exception
      'Authenticated clients can execute the internal booking mutation.';
  end if;

  select
    game.id,
    available.role
  into
    game_id_to_test,
    role_to_test
  from public.open_queue_games game
  cross join lateral (
    select capacity.role
    from (
      values
        ('GK', game.goalkeeper_capacity),
        ('DEF', game.defender_capacity),
        ('MID', game.midfielder_capacity),
        ('ATT', game.attacker_capacity)
    ) as capacity(role, maximum)
    where (
      select count(*)
      from public.open_queue_bookings booking
      where booking.game_id = game.id
        and booking.status = 'CONFIRMED'
        and booking.role = capacity.role
    ) < capacity.maximum
    order by capacity.role
    limit 1
  ) available
  where game.status = 'OPEN'
    and game.starts_at > clock_timestamp()
  order by game.starts_at, game.id
  limit 1;

  if game_id_to_test is null then
    raise exception
      'Tap verification needs one future Open Queue game with an available position.';
  end if;

  select profile.id into profile_id_to_test
  from public.profiles profile
  where not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_test
      and booking.profile_id = profile.id
      and booking.status = 'CONFIRMED'
  )
    and (
      select count(*)
      from public.open_queue_bookings booking
      join public.open_queue_games booked_game
        on booked_game.id = booking.game_id
      where booking.profile_id = profile.id
        and booking.status = 'CONFIRMED'
        and booked_game.status in ('OPEN', 'FULL', 'LIVE')
        and booked_game.starts_at > clock_timestamp()
    ) < 2
    and not exists (
      select 1
      from public.open_queue_bookings booking
      join public.open_queue_games booked_game
        on booked_game.id = booking.game_id
      join public.open_queue_games target_game
        on target_game.id = game_id_to_test
      where booking.profile_id = profile.id
        and booking.status = 'CONFIRMED'
        and booked_game.status in ('OPEN', 'FULL', 'LIVE')
        and tstzrange(
          booked_game.starts_at,
          booked_game.ends_at,
          '[)'
        ) && tstzrange(
          target_game.starts_at,
          target_game.ends_at,
          '[)'
        )
    )
    and not public.profile_has_active_reliability_booking_restriction(
      profile.id
    )
  order by profile.created_at desc, profile.id
  limit 1;

  if profile_id_to_test is null then
    raise exception 'Tap verification needs one unbooked seeded player.';
  end if;

  perform set_config(
    'request.jwt.claim.sub',
    profile_id_to_test::text,
    true
  );
  quote_to_test := public.preview_open_queue_booking_cost(
    game_id_to_test,
    role_to_test
  );

  perform set_config('request.jwt.claim.role', 'authenticated', true);
  begin
    perform public.book_open_queue_game(
      game_id_to_test,
      role_to_test,
      'MOCK',
      'field_ci_mock_payment'
    );
  exception
    when others then
      forged_rejected :=
        sqlerrm = 'Mock payments cannot create a booking.';
  end;
  if not forged_rejected then
    raise exception 'An authenticated client created a mock-paid booking.';
  end if;

  forged_rejected := false;
  begin
    perform public.book_open_queue_game(
      game_id_to_test,
      role_to_test,
      'VISA',
      'chg_forged_ci_reference'
    );
  exception
    when others then
      forged_rejected :=
        sqlerrm = 'The captured payment could not be verified for this booking.';
  end;
  if not forged_rejected then
    raise exception 'A client could forge a card payment reference.';
  end if;

  insert into public.tap_payment_intents (
    id,
    profile_id,
    purpose,
    status,
    currency,
    amount_fils,
    payload,
    quote_snapshot,
    transaction_reference,
    tap_charge_id,
    tap_payment_method,
    tap_status,
    captured_at
  ) values (
    intent_id_to_test,
    profile_id_to_test,
    'SOLO_BOOKING',
    'CAPTURED',
    'BHD',
    (quote_to_test ->> 'total_fils')::integer,
    jsonb_build_object(
      'game_id', game_id_to_test,
      'role', role_to_test
    ),
    quote_to_test,
    'field_ci_' || replace(intent_id_to_test::text, '-', ''),
    'chg_ci_' || replace(intent_id_to_test::text, '-', ''),
    'MASTERCARD',
    'CAPTURED',
    clock_timestamp()
  );

  perform set_config('request.jwt.claim.role', 'authenticated', true);
  begin
    perform public.finalize_tap_payment_intent(intent_id_to_test);
  exception
    when others then
      if sqlerrm <> 'Only the payment service can finalize a Tap payment.' then
        raise;
      end if;
  end;

  if (
    select status
    from public.tap_payment_intents
    where id = intent_id_to_test
  ) <> 'CAPTURED' then
    raise exception 'An authenticated client finalized a Tap payment.';
  end if;

  perform set_config('request.jwt.claim.role', 'service_role', true);
  finalized := public.finalize_tap_payment_intent(intent_id_to_test);

  if finalized ->> 'status' <> 'FINALIZED'
    or finalized ->> 'resource_type' <> 'OPEN_QUEUE_BOOKING'
    or finalized ->> 'resource_id' is null
  then
    raise exception 'Captured Tap payment did not return a finalized booking.';
  end if;

  select * into linked_booking
  from public.open_queue_bookings booking
  where booking.id = (finalized ->> 'resource_id')::uuid;

  if linked_booking.id is null
    or linked_booking.profile_id <> profile_id_to_test
    or linked_booking.game_id <> game_id_to_test
    or linked_booking.payment_method <> 'MASTERCARD'
    or linked_booking.tap_payment_intent_id <> intent_id_to_test
    or linked_booking.tap_charge_id <> (
      'chg_ci_' || replace(intent_id_to_test::text, '-', '')
    )
  then
    raise exception 'Finalized booking is missing its Tap audit linkage.';
  end if;

  finalized := public.finalize_tap_payment_intent(intent_id_to_test);
  if (finalized ->> 'resource_id')::uuid <> linked_booking.id then
    raise exception 'Duplicate Tap finalization was not idempotent.';
  end if;

  if (
    select count(*)
    from public.open_queue_bookings booking
    where booking.tap_payment_intent_id = intent_id_to_test
  ) <> 1 then
    raise exception 'Duplicate Tap finalization created multiple bookings.';
  end if;
end;
$verify$;

rollback;
