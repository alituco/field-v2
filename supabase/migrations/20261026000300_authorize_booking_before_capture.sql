-- Authorize new card payments, reserve capacity durably, then capture. Existing
-- automatic-capture attempts retain their original contract during rollout.
alter table public.payment_intents add column capture_method text not null default 'automatic'
  check(capture_method in ('automatic','manual'));
alter table public.payment_intents add column authorization_cancel_requested boolean not null default false;
create function fieldrush_private.protect_stripe_capture_method()
returns trigger language plpgsql set search_path=pg_catalog as $$
begin
  if tg_op='UPDATE' and new.capture_method is distinct from old.capture_method then
    raise exception 'A payment attempt capture method cannot change.' using errcode='22023';
  end if;
  if new.capture_method='manual' and (new.provider<>'STRIPE' or new.purpose<>'SOLO_BOOKING') then
    raise exception 'Authorization before capture is available for Stripe solo bookings only.' using errcode='22023';
  end if;
  return new;
end $$;
create trigger protect_stripe_capture_method before insert or update on public.payment_intents
for each row execute function fieldrush_private.protect_stripe_capture_method();

create table fieldrush_private.stripe_booking_reservations (
  intent_id uuid primary key references public.payment_intents(id) on delete restrict,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  game_id uuid not null references public.open_queue_games(id) on delete restrict,
  role text not null check(role in ('GK','DEF','MID','ATT')),
  status text not null check(status in ('ACTIVE','REQUIRES_CANCEL','CONSUMED','RELEASED')),
  cancel_requested boolean not null default false,
  failure_reason text,
  authorized_at timestamptz not null default clock_timestamp(),
  resolved_at timestamptz
);
create index stripe_booking_reservations_game_active on fieldrush_private.stripe_booking_reservations(game_id,role) where status='ACTIVE';
alter table fieldrush_private.stripe_booking_reservations enable row level security;
revoke all on fieldrush_private.stripe_booking_reservations from public,anon,authenticated,service_role;
comment on table fieldrush_private.stripe_booking_reservations is
  'Private provisional capacity reservations. They are never user-visible confirmed/paid bookings. Unknown provider outcomes retain capacity; wall-clock expiry alone never releases a reservation.';

create function public.reserve_stripe_booking_authorization(
  intent_id_to_reserve uuid,provider_intent_id_to_use text,amount_minor_to_use integer,
  currency_to_use text,payment_method_to_use text
) returns jsonb language plpgsql security definer set search_path=public,fieldrush_private,pg_temp as $$
declare i public.payment_intents%rowtype; h fieldrush_private.stripe_booking_reservations%rowtype;
  g public.open_queue_games%rowtype; prior_user text:=current_setting('request.jwt.claim.sub',true);
  current_quote jsonb; total integer; position_count integer; position_capacity integer; failure text;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can reserve an authorization.' using errcode='42501'; end if;
  perform 1 from fieldrush_private.accounts where user_id=(select profile_id from public.payment_intents where id=intent_id_to_reserve) for share;
  select * into i from public.payment_intents where id=intent_id_to_reserve for update;
  if i.id is null or i.provider<>'STRIPE' or i.purpose<>'SOLO_BOOKING' or i.capture_method<>'manual'
    or i.provider_intent_id is distinct from provider_intent_id_to_use or i.amount_minor is distinct from amount_minor_to_use
    or i.currency is distinct from upper(currency_to_use) or payment_method_to_use not in ('APPLE_PAY','GOOGLE_PAY','VISA','MASTERCARD','CARD') then
    raise exception 'The payment authorization does not match its checkout.' using errcode='22023';
  end if;
  if i.status<>'PENDING' then return jsonb_build_object('status',i.status,'intent_id',i.id); end if;
  if i.authorization_cancel_requested then
    return jsonb_build_object('status','CANCEL_AUTHORIZATION','intent_id',i.id,'failure_reason',i.failure_reason);
  end if;
  perform pg_advisory_xact_lock(hashtext(i.profile_id::text)::bigint);
  select * into g from public.open_queue_games where id=(i.payload->>'game_id')::uuid for update;
  select * into h from fieldrush_private.stripe_booking_reservations where intent_id=i.id for update;
  if h.intent_id is not null then
    if h.status='ACTIVE' and not h.cancel_requested and g.status in ('OPEN','FULL') and g.operational_state='NORMAL' then
      return jsonb_build_object('status','RESERVED','intent_id',i.id);
    end if;
    if h.status='ACTIVE' then
      update fieldrush_private.stripe_booking_reservations set cancel_requested=true,
        failure_reason=coalesce(failure_reason,'The booking was closed before payment completed.') where intent_id=i.id;
    end if;
    return jsonb_build_object('status','CANCEL_AUTHORIZATION','intent_id',i.id,'failure_reason',h.failure_reason);
  end if;
  begin
    if g.id is null or g.status not in ('OPEN','FULL') or clock_timestamp()>=g.starts_at or i.expires_at<=clock_timestamp() then
      raise exception 'This game checkout is no longer available.';
    end if;
    perform set_config('request.jwt.claim.sub',i.profile_id::text,true);
    current_quote:=public.preview_open_queue_booking_cost(g.id,upper(i.payload->>'role'));
    -- The saved price and deposit remain authoritative after admin repricing.
    if current_quote->>'currency' is distinct from i.currency
      or current_quote->>'policy_version_id' is distinct from i.quote_snapshot->>'policy_version_id'
      or (i.quote_snapshot->>'total_fils')::integer is distinct from i.amount_fils then
      raise exception 'Your booking terms changed. Review checkout again.';
    end if;
    select count(*) into total from public.open_queue_bookings where game_id=g.id and status='CONFIRMED';
    select total+count(*) into total from fieldrush_private.stripe_booking_reservations where game_id=g.id and status='ACTIVE';
    select count(*) into position_count from public.open_queue_bookings where game_id=g.id and status='CONFIRMED' and role=upper(i.payload->>'role');
    select position_count+count(*) into position_count from fieldrush_private.stripe_booking_reservations
      where game_id=g.id and status='ACTIVE' and role=upper(i.payload->>'role');
    position_capacity:=case upper(i.payload->>'role') when 'GK' then g.goalkeeper_capacity when 'DEF' then g.defender_capacity
      when 'MID' then g.midfielder_capacity when 'ATT' then g.attacker_capacity end;
    if total>=g.capacity then raise exception 'This game just filled. Your authorization will be released.'; end if;
    if position_count>=position_capacity then raise exception 'That position just filled. Your authorization will be released.'; end if;
    insert into fieldrush_private.stripe_booking_reservations(intent_id,profile_id,game_id,role,status,authorized_at)
      values(i.id,i.profile_id,g.id,upper(i.payload->>'role'),'ACTIVE',clock_timestamp());
    update public.payment_intents set provider_status='requires_capture',payment_method=payment_method_to_use where id=i.id;
  exception when raise_exception or insufficient_privilege or invalid_parameter_value or check_violation or unique_violation then
    failure:=left(sqlerrm,1000);
    if g.id is not null then
      insert into fieldrush_private.stripe_booking_reservations(intent_id,profile_id,game_id,role,status,cancel_requested,failure_reason)
        values(i.id,i.profile_id,g.id,upper(i.payload->>'role'),'REQUIRES_CANCEL',true,failure);
    end if;
    update public.payment_intents set failure_reason=failure,provider_status='requires_capture',authorization_cancel_requested=true where id=i.id;
  end;
  perform set_config('request.jwt.claim.sub',coalesce(prior_user,''),true);
  return jsonb_build_object('status',case when failure is null then 'RESERVED' else 'CANCEL_AUTHORIZATION' end,
    'intent_id',i.id,'failure_reason',failure);
end $$;

-- A spot secured before kickoff may finish its already-authorized payment a
-- few seconds later. This is conversion of its own verified hold, not a new
-- late booking or a client-provided payment bypass.
create function fieldrush_private.is_captured_stripe_booking_reservation(
  payer uuid,game uuid,position_to_use text,charge text
) returns boolean language sql stable security definer set search_path=public,fieldrush_private,pg_temp as $$
  select exists(select 1 from fieldrush_private.stripe_booking_reservations h
    join public.payment_intents i on i.id=h.intent_id join public.open_queue_games g on g.id=h.game_id
    where h.profile_id=payer and h.game_id=game and h.role=position_to_use and h.status='ACTIVE'
      and h.authorized_at<g.starts_at and i.provider='STRIPE' and i.capture_method='manual'
      and i.status='CAPTURED' and i.provider_status='SUCCEEDED' and i.provider_payment_id=charge
      and i.profile_id=h.profile_id and (i.payload->>'game_id')::uuid=h.game_id and upper(i.payload->>'role')=h.role);
$$;

create function public.request_stripe_booking_void(intent_id_to_cancel uuid)
returns void language plpgsql security definer set search_path=public,fieldrush_private,pg_temp as $$
declare i public.payment_intents%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can abandon an authorization.' using errcode='42501'; end if;
  select * into i from public.payment_intents where id=intent_id_to_cancel for update;
  if i.id is null then raise exception 'Payment attempt not found.'; end if;
  if i.capture_method<>'manual' or i.status<>'PENDING' then return; end if;
  update public.payment_intents set authorization_cancel_requested=true where id=i.id;
  update fieldrush_private.stripe_booking_reservations set cancel_requested=true where intent_id=i.id;
  -- An ACTIVE reservation stays ACTIVE during unknown cancel/capture outcomes.
end $$;

create function fieldrush_private.sync_stripe_booking_reservation()
returns trigger language plpgsql security definer set search_path=public,fieldrush_private,pg_temp as $$
begin
  if new.capture_method='manual' then
    if new.status='FINALIZED' then
      update fieldrush_private.stripe_booking_reservations set status='CONSUMED',resolved_at=clock_timestamp() where intent_id=new.id;
    elsif new.status in ('REQUIRES_REFUND','REFUNDED') or new.status in ('CANCELLED','EXPIRED','FAILED') and new.provider_status='canceled' then
      update fieldrush_private.stripe_booking_reservations set status='RELEASED',resolved_at=clock_timestamp() where intent_id=new.id;
    end if;
  end if;
  return new;
end $$;
create trigger sync_stripe_booking_reservation after update of status,provider_status on public.payment_intents
for each row execute function fieldrush_private.sync_stripe_booking_reservation();

-- A free or legacy booking cannot take a seat promised to a verified manual
-- authorization. Conversion of that same reservation excludes only itself.
do $migration$
declare d text; anchor text;
begin
  d:=pg_get_functiondef('public.enforce_open_queue_booking_capacity()'::regprocedure);
  anchor:='if now() >= game_to_book.starts_at then';
  if position(anchor in d)=0 then raise exception 'Capacity kickoff guard changed.'; end if;
  d:=replace(d,anchor,'if now() >= game_to_book.starts_at and not fieldrush_private.is_captured_stripe_booking_reservation(new.profile_id,new.game_id,new.role,new.provider_payment_id) then');
  anchor:='  role_capacity := case new.role';
  if position(anchor in d)=0 then raise exception 'Capacity role guard changed.'; end if;
  d:=replace(d,anchor,$holds$
  select confirmed_count+count(*) into confirmed_count from fieldrush_private.stripe_booking_reservations h
    where h.game_id=new.game_id and h.status='ACTIVE' and h.intent_id is distinct from new.payment_intent_id;
  select role_count+count(*) into role_count from fieldrush_private.stripe_booking_reservations h
    where h.game_id=new.game_id and h.role=new.role and h.status='ACTIVE' and h.intent_id is distinct from new.payment_intent_id;
  role_capacity := case new.role$holds$);
  execute d;
  d:=pg_get_functiondef('public.book_open_queue_game_server(uuid,text,text,text)'::regprocedure);
  anchor:='if clock_timestamp() >= game_to_book.starts_at then';
  if position(anchor in d)=0 then raise exception 'Booking kickoff guard changed.'; end if;
  d:=replace(d,anchor,'if clock_timestamp() >= game_to_book.starts_at and not fieldrush_private.is_captured_stripe_booking_reservation(user_id,game_to_book.id,role_to_book,payment_reference_to_use) then');
  anchor:='if clock_timestamp() >= terms_to_use.check_in_deadline_at';
  if position(anchor in d)=0 then raise exception 'Booking check-in guard changed.'; end if;
  d:=replace(d,anchor,'if clock_timestamp() >= terms_to_use.check_in_deadline_at and not fieldrush_private.is_captured_stripe_booking_reservation(user_id,game_to_book.id,role_to_book,payment_reference_to_use)');
  anchor:='if game_to_book.status <> ''OPEN'' then';
  if position(anchor in d)=0 then raise exception 'Booking availability guard changed.'; end if;
  d:=replace(d,anchor,'if game_to_book.status <> ''OPEN'' and not (game_to_book.status=''FULL'' and fieldrush_private.is_captured_stripe_booking_reservation(user_id,game_to_book.id,role_to_book,payment_reference_to_use)) then');
  execute d;
  d:=pg_get_functiondef('fieldrush_private.stripe_recovery_evidence_valid(jsonb,public.payment_intents,boolean)'::regprocedure);
  anchor:='e->>''capture_method''=''automatic''';
  if position(anchor in d)=0 then raise exception 'Recovery capture contract changed.'; end if;
  execute replace(d,anchor,'e->>''capture_method''=i.capture_method');
end $migration$;

create function fieldrush_private.guard_kickoff_payment_reservations()
returns trigger language plpgsql security definer set search_path=public,fieldrush_private,pg_temp as $$
begin
  if new.status='LIVE' and old.status is distinct from 'LIVE'
    and exists(select 1 from fieldrush_private.stripe_booking_reservations where game_id=new.id and status='ACTIVE') then
    raise exception 'A booking payment is being confirmed. Retry kickoff shortly.';
  end if;
  return new;
end $$;
create trigger a_guard_kickoff_payment_reservations before update of status on public.open_queue_games
for each row execute function fieldrush_private.guard_kickoff_payment_reservations();

-- Organizer cancellation/review must remain available during a provider outage.
-- Atomically stop future capture claims, retaining capacity until Stripe has
-- confirmed cancellation or an already-in-flight capture has been reconciled.
create function fieldrush_private.abandon_closed_game_authorizations()
returns trigger language plpgsql security definer set search_path=public,fieldrush_private,pg_temp as $$
begin
  if (new.status not in ('OPEN','FULL') and new.status is distinct from old.status)
    or (new.operational_state<>'NORMAL' and new.operational_state is distinct from old.operational_state) then
    update fieldrush_private.stripe_booking_reservations set cancel_requested=true,
      failure_reason=coalesce(failure_reason,'The organizer closed this game while payment was being confirmed.')
      where game_id=new.id and status='ACTIVE';
  end if;
  return new;
end $$;
create trigger abandon_closed_game_authorizations after update of status,operational_state on public.open_queue_games
for each row execute function fieldrush_private.abandon_closed_game_authorizations();

-- A provider/Dashboard capture without a valid reserved spot is still real
-- money: persist it and enqueue the existing full refund rather than losing it.
alter function public.record_stripe_payment_capture(uuid,text,text,integer,text,text) rename to record_stripe_payment_capture_before_authorization;
create function public.record_stripe_payment_capture(intent_id_to_capture uuid,provider_intent_id_to_use text,
  provider_payment_id_to_use text,amount_minor_to_use integer,currency_to_use text,payment_method_to_use text)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_private,pg_temp as $$
declare i public.payment_intents%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can verify a capture.' using errcode='42501'; end if;
  perform 1 from fieldrush_private.accounts where user_id=(select profile_id from public.payment_intents where id=intent_id_to_capture) for share;
  select * into i from public.payment_intents where id=intent_id_to_capture for update;
  if i.capture_method='manual' and i.status in ('PENDING','CAPTURED')
    and not exists(select 1 from fieldrush_private.stripe_booking_reservations where intent_id=i.id and status='ACTIVE') then
    if i.provider<>'STRIPE' or i.provider_intent_id is distinct from provider_intent_id_to_use
      or i.amount_minor is distinct from amount_minor_to_use or i.currency is distinct from upper(currency_to_use)
      or nullif(trim(provider_payment_id_to_use),'') is null
      or payment_method_to_use not in ('APPLE_PAY','GOOGLE_PAY','VISA','MASTERCARD','CARD') then
      raise exception 'The provider payment does not match the checkout quote.' using errcode='22023';
    end if;
    update public.payment_intents set status='REQUIRES_REFUND',provider_status='SUCCEEDED',provider_payment_id=provider_payment_id_to_use,
      payment_method=payment_method_to_use,captured_at=coalesce(captured_at,clock_timestamp()),
      failure_reason='Payment was captured without a reserved spot.' where id=i.id;
    perform public.request_payment_refund(i.id,i.amount_fils,'finalize-failed:'||i.id,'Payment was captured without a reserved spot.');
    return public.finalize_payment_intent(i.id);
  end if;
  return public.record_stripe_payment_capture_before_authorization(intent_id_to_capture,provider_intent_id_to_use,
    provider_payment_id_to_use,amount_minor_to_use,currency_to_use,payment_method_to_use);
end $$;
revoke all on function public.record_stripe_payment_capture_before_authorization(uuid,text,text,integer,text,text)
  from public,anon,authenticated,service_role;
revoke all on function public.reserve_stripe_booking_authorization(uuid,text,integer,text,text),public.request_stripe_booking_void(uuid),
  public.record_stripe_payment_capture(uuid,text,text,integer,text,text) from public,anon,authenticated;
grant execute on function public.reserve_stripe_booking_authorization(uuid,text,integer,text,text),public.request_stripe_booking_void(uuid),
  public.record_stripe_payment_capture(uuid,text,text,integer,text,text) to service_role;
revoke all on function fieldrush_private.protect_stripe_capture_method(),fieldrush_private.sync_stripe_booking_reservation(),
  fieldrush_private.guard_kickoff_payment_reservations(),fieldrush_private.is_captured_stripe_booking_reservation(uuid,uuid,text,text)
  ,fieldrush_private.abandon_closed_game_authorizations()
  from public,anon,authenticated,service_role;
