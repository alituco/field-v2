-- Price changes are prospective. Paid bookings, their captured quote, refunds,
-- wallet entries and the recurring schedule template are never rewritten.
create function public.admin_update_open_queue_game_price(
  actor_admin_id uuid,
  game_id_to_use uuid,
  price_fils_to_use integer,
  expected_price_fils integer,
  reason_to_use text
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare game public.open_queue_games%rowtype; reason_text text := trim(coalesce(reason_to_use,''));
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if price_fils_to_use is null or price_fils_to_use not between 0 and 100000 or price_fils_to_use % 10 <> 0
    or price_fils_to_use between 1 and 499 then
    raise exception 'Price must be free or between 0.50 and 100 USD, in whole cents.';
  end if;
  if expected_price_fils is null then raise exception 'Reload the game before changing its price.'; end if;
  if char_length(reason_text) not between 8 and 1000 then raise exception 'Give a reason between 8 and 1000 characters.'; end if;
  select * into game from public.open_queue_games where id=game_id_to_use for update;
  if game.id is null then raise exception 'Solo game not found.'; end if;
  if game.currency is distinct from 'USD' or game.format_version is distinct from 'FIELDRUSH_7V7' then
    raise exception 'Only Fieldrush USD solo game prices can be changed.';
  end if;
  if game.status not in ('OPEN','FULL') or game.starts_at <= clock_timestamp()
    or game.operational_state is distinct from 'NORMAL'
    or exists(select 1 from public.open_queue_clock_states c where c.game_id=game.id
      and (c.status<>'NOT_STARTED' or c.started_at is not null or c.accumulated_seconds>0)) then
    raise exception 'Prices can only be changed for upcoming games that have not started or entered review.';
  end if;
  if game.price_fils is distinct from expected_price_fils then
    raise exception 'The game price changed. Reload it before saving again.' using errcode='40001';
  end if;
  if game.price_fils <> price_fils_to_use then
    update public.open_queue_games set price_fils=price_fils_to_use where id=game.id;
    insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_admin_id,'SOLO_GAME_PRICE_CHANGED','SOLO_MATCH',game.id,reason_text,
      jsonb_build_object('price_fils',game.price_fils,'currency',game.currency),
      jsonb_build_object('price_fils',price_fils_to_use,'currency',game.currency,
        'existing_payments_unchanged',true,'existing_checkout_quotes_honored',true));
  end if;
  return jsonb_build_object('game_id',game.id,'price_fils',price_fils_to_use,'currency',game.currency);
end;
$$;
revoke all on function public.admin_update_open_queue_game_price(uuid,uuid,integer,integer,text) from public,anon,authenticated;
grant execute on function public.admin_update_open_queue_game_price(uuid,uuid,integer,integer,text) to service_role;

-- The booking function used to compare a captured payment against the CURRENT
-- game price. Honor the immutable server-owned quote instead, so an admin edit
-- while PaymentSheet is open never reprices or unnecessarily refunds a payer.
-- Every other booking, capacity, identity and payment verification gate stays.
do $migration$
declare definition text; anchor text;
begin
  definition := pg_get_functiondef('public.book_open_queue_game_server(uuid,text,text,text)'::regprocedure);
  anchor := '      and intent.amount_fils = total_amount_to_use';
  if position(anchor in definition)=0 then raise exception 'Solo captured-payment amount guard changed.'; end if;
  definition := replace(definition,anchor,'      and intent.amount_fils > 0');
  anchor := E'    if payment_intent_to_use.id is null then\n      raise exception ''The captured payment could not be verified for this booking.'';\n    end if;';
  if position(anchor in definition)=0 then raise exception 'Solo captured-payment verification guard changed.'; end if;
  definition := replace(definition,anchor,anchor || $snapshot$

    if payment_intent_to_use.quote_snapshot->>'currency' is distinct from game_to_book.currency
      or payment_intent_to_use.quote_snapshot->>'policy_version_id' is distinct from terms_to_use.policy_version_id::text
      or coalesce(payment_intent_to_use.quote_snapshot->>'match_fee_fils','') !~ '^[0-9]{1,9}$'
      or coalesce(payment_intent_to_use.quote_snapshot->>'reliability_deposit_fils','') !~ '^[0-9]{1,9}$'
      or coalesce(payment_intent_to_use.quote_snapshot->>'replacement_discount_bps','') !~ '^[0-9]{1,9}$'
      or coalesce(payment_intent_to_use.quote_snapshot->>'total_fils','') !~ '^[0-9]{1,9}$' then
      raise exception 'The captured checkout quote is invalid.';
    end if;
    base_amount_to_use := (payment_intent_to_use.quote_snapshot->>'match_fee_fils')::integer;
    deposit_amount_to_use := (payment_intent_to_use.quote_snapshot->>'reliability_deposit_fils')::integer;
    discount_bps_to_use := (payment_intent_to_use.quote_snapshot->>'replacement_discount_bps')::integer;
    total_amount_to_use := payment_intent_to_use.amount_fils;
    if base_amount_to_use::bigint + deposit_amount_to_use <> total_amount_to_use
      or (payment_intent_to_use.quote_snapshot->>'total_fils')::integer <> total_amount_to_use
      or discount_bps_to_use not between 0 and 10000
      or (game_to_book.currency='USD' and (base_amount_to_use%10<>0 or deposit_amount_to_use%10<>0)) then
      raise exception 'The captured checkout quote does not match the payment.';
    end if;
$snapshot$);
  execute definition;
end;
$migration$;

notify pgrst,'reload schema';
