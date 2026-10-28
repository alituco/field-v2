-- Provider-neutral payment history. Applied migrations remain immutable, and
-- old transactions remain available for audit without an active legacy gateway.
alter table public.tap_payment_intents rename to payment_intents;
alter table public.payment_intents rename column tap_charge_id to provider_payment_id;
alter table public.payment_intents rename column tap_payment_method to payment_method;
alter table public.payment_intents rename column tap_status to provider_status;
alter table public.open_queue_bookings rename column tap_payment_intent_id to payment_intent_id;
alter table public.open_queue_bookings rename column tap_charge_id to provider_payment_id;
alter table public.fixtures rename column home_tap_payment_intent_id to home_payment_intent_id;
alter table public.fixtures rename column away_tap_payment_intent_id to away_payment_intent_id;
alter table public.fixtures rename column home_tap_charge_id to home_provider_payment_id;
alter table public.fixtures rename column away_tap_charge_id to away_provider_payment_id;
alter function public.finalize_tap_payment_intent(uuid) rename to finalize_payment_intent;

-- PostgreSQL updates dependency identities on rename, but quoted PL/pgSQL
-- function bodies must be updated explicitly (including account deletion).
do $migration$
declare f record; definition text; c record;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','fieldrush_private') and p.prokind='f'
      and p.prosrc ~ 'tap_(payment_intents|payment_intent_id|charge_id|payment_method|status|intent_to_use)'
  loop
    definition := pg_get_functiondef(f.oid);
    definition := replace(definition, 'tap_payment_intents', 'payment_intents');
    definition := replace(definition, 'tap_payment_intent_id', 'payment_intent_id');
    definition := replace(definition, 'tap_charge_id', 'provider_payment_id');
    definition := replace(definition, 'tap_payment_method', 'payment_method');
    definition := replace(definition, 'tap_status', 'provider_status');
    definition := replace(definition, 'tap_intent_to_use', 'payment_intent_to_use');
    definition := replace(definition, 'Tap', 'provider');
    execute definition;
  end loop;
  for c in select conrelid::regclass as relation, conname from pg_constraint
    where conrelid in ('public.payment_intents'::regclass,'public.open_queue_bookings'::regclass,'public.fixtures'::regclass)
      and conname like '%tap%'
  loop execute format('alter table %s rename constraint %I to %I', c.relation,c.conname,replace(c.conname,'tap_','')); end loop;
  for c in select n.nspname, idx.relname from pg_class idx join pg_namespace n on n.oid=idx.relnamespace
    join pg_index i on i.indexrelid=idx.oid
    where i.indrelid in ('public.payment_intents'::regclass,'public.open_queue_bookings'::regclass,'public.fixtures'::regclass)
      and idx.relname like '%tap%'
  loop execute format('alter index %I.%I rename to %I',c.nspname,c.relname,replace(c.relname,'tap_','')); end loop;
end;
$migration$;
alter trigger set_tap_payment_intents_updated_at on public.payment_intents rename to set_payment_intents_updated_at;

alter table public.payment_intents
  add column provider text not null default 'LEGACY' check(provider in ('LEGACY','STRIPE','STAGING_E2E')),
  add column provider_intent_id text unique,
  add column amount_minor integer generated always as
    (case when currency='USD' then amount_fils / 10 else amount_fils end) stored;
alter table public.payment_intents alter column provider set default 'STRIPE';
alter table public.payment_intents add constraint payment_intents_provider_amount_check
  check(provider<>'STRIPE' or amount_fils%10=0);
comment on table public.payment_intents is
  'Server-owned immutable checkout quotes and provider-confirmed payment history. LEGACY rows are retained for audit only.';
comment on column public.payment_intents.amount_fils is
  'Integer thousandths of currency; USD mills convert to Stripe cents by dividing by ten.';
comment on column public.payment_intents.provider_payment_id is 'Provider charge identifier; historical identifiers are retained unchanged.';

create function public.protect_payment_intent()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if (new.id,new.profile_id,new.purpose,new.provider,new.currency,new.amount_fils,
      new.payload,new.quote_snapshot,new.transaction_reference)
    is distinct from
    (old.id,old.profile_id,old.purpose,old.provider,old.currency,old.amount_fils,
      old.payload,old.quote_snapshot,old.transaction_reference) then
    raise exception 'A checkout quote and its owner cannot change.' using errcode='22023';
  end if;
  if old.provider_intent_id is not null and new.provider_intent_id is distinct from old.provider_intent_id then
    raise exception 'The payment provider intent cannot change.' using errcode='22023';
  end if;
  if old.provider_payment_id is not null and new.provider_payment_id is distinct from old.provider_payment_id then
    raise exception 'The captured charge cannot change.' using errcode='22023';
  end if;
  if old.status='REFUNDED' and new.status<>'REFUNDED'
    or old.status='FINALIZED' and new.status not in ('FINALIZED','REFUNDED')
    or old.status='REQUIRES_REFUND' and new.status not in ('REQUIRES_REFUND','REFUNDED')
    or old.status in ('FAILED','CANCELLED','EXPIRED') and new.status not in (old.status,'REQUIRES_REFUND') then
    raise exception 'A completed payment state cannot regress.' using errcode='22023';
  end if;
  return new;
end;
$$;
create trigger protect_payment_intent before update on public.payment_intents
  for each row execute function public.protect_payment_intent();

create table public.payment_refunds (
  id uuid primary key default gen_random_uuid(),
  intent_id uuid not null references public.payment_intents(id) on delete restrict,
  recipient_profile_id uuid not null references public.profiles(id) on delete restrict,
  idempotency_key text not null unique,
  provider_intent_id text not null,
  amount_fils integer not null check(amount_fils>0),
  amount_minor integer not null check(amount_minor>=0),
  currency text not null check(currency in ('USD','BHD')),
  reason text not null,
  metadata jsonb not null default '{}'::jsonb check(jsonb_typeof(metadata)='object'),
  status text not null default 'PENDING' check(status in ('PENDING','PROCESSING','SUCCEEDED','FAILED')),
  provider_refund_id text unique,
  provider_status text,
  attempts integer not null default 0,
  retry_generation integer not null default 0,
  next_attempt_at timestamptz not null default clock_timestamp(),
  locked_until timestamptz,
  last_error text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create index payment_refunds_due_idx on public.payment_refunds(next_attempt_at) where status<>'SUCCEEDED';
create index payment_refunds_intent_idx on public.payment_refunds(intent_id);
create trigger set_payment_refunds_updated_at before update on public.payment_refunds
  for each row execute function public.set_updated_at();
alter table public.payment_refunds enable row level security;
revoke all on public.payment_refunds from public,anon,authenticated;
grant all on public.payment_refunds to service_role;

-- The event contains routing information only, never a card/customer payload.
create table public.payment_webhook_events (
  provider text not null default 'STRIPE' check(provider='STRIPE'),
  event_id text not null,
  event_type text not null,
  provider_intent_id text,
  status text not null default 'PENDING' check(status in ('PENDING','PROCESSING','PROCESSED','FAILED')),
  attempts integer not null default 0,
  locked_until timestamptz,
  next_attempt_at timestamptz not null default clock_timestamp(),
  last_error text,
  processed_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  primary key(provider,event_id)
);
create index payment_webhook_events_retry_idx on public.payment_webhook_events(next_attempt_at) where status<>'PROCESSED';
create trigger set_payment_webhook_events_updated_at before update on public.payment_webhook_events
  for each row execute function public.set_updated_at();
alter table public.payment_webhook_events enable row level security;
revoke all on public.payment_webhook_events from public,anon,authenticated;
grant all on public.payment_webhook_events to service_role;

create function public.claim_payment_webhook(event_id_to_claim text,event_type_to_use text,provider_intent_id_to_use text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare e public.payment_webhook_events%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can claim payment events.' using errcode='42501'; end if;
  if nullif(trim(event_id_to_claim),'') is null or nullif(trim(event_type_to_use),'') is null then raise exception 'Payment event identity is required.'; end if;
  insert into public.payment_webhook_events(event_id,event_type,provider_intent_id)
    values(event_id_to_claim,event_type_to_use,provider_intent_id_to_use) on conflict do nothing;
  select * into e from public.payment_webhook_events where provider='STRIPE' and event_id=event_id_to_claim for update;
  if e.event_type<>event_type_to_use or e.provider_intent_id is distinct from provider_intent_id_to_use then raise exception 'Payment event identity conflict.'; end if;
  if e.status='PROCESSED' or e.locked_until>clock_timestamp() then return jsonb_build_object('claimed',false,'status',e.status); end if;
  update public.payment_webhook_events set status='PROCESSING',attempts=attempts+1,
    locked_until=clock_timestamp()+interval '5 minutes',last_error=null
    where provider='STRIPE' and event_id=e.event_id;
  return jsonb_build_object('claimed',true,'status','PROCESSING');
end;
$$;

create function public.request_payment_refund(
  intent_id_to_refund uuid,amount_fils_to_refund integer,idempotency_key_to_use text,
  reason_to_use text,metadata_to_use jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare i public.payment_intents%rowtype; r public.payment_refunds%rowtype;
  allocated bigint; allocated_minor bigint; minor_to_refund integer; refund_id uuid;
begin
  if amount_fils_to_refund<=0 then return null; end if;
  select * into i from public.payment_intents where id=intent_id_to_refund for update;
  if i.id is null or i.provider not in ('STRIPE','STAGING_E2E') or i.provider_status<>'SUCCEEDED'
    or i.status not in ('CAPTURED','FINALIZED','REQUIRES_REFUND','REFUNDED') or i.provider_intent_id is null then
    raise exception 'A verified payment is required for an original-method refund.';
  end if;
  select * into r from public.payment_refunds where idempotency_key=idempotency_key_to_use;
  if r.id is not null then
    if r.intent_id<>i.id or r.amount_fils<>amount_fils_to_refund then raise exception 'Refund idempotency conflict.'; end if;
    return r.id;
  end if;
  if nullif(trim(idempotency_key_to_use),'') is null or nullif(trim(reason_to_use),'') is null then raise exception 'A refund reference and reason are required.'; end if;
  select coalesce(sum(amount_fils),0),coalesce(sum(amount_minor),0) into allocated,allocated_minor
    from public.payment_refunds where intent_id=i.id;
  if allocated+amount_fils_to_refund>i.amount_fils then raise exception 'The refund would exceed the captured payment.'; end if;
  -- Aggregate before rounding: policy percentages may produce fractional cents.
  -- The final refund to 100% includes all remaining cents, without overpaying.
  minor_to_refund := (case when i.currency='USD' then (allocated+amount_fils_to_refund)/10
    else ((allocated+amount_fils_to_refund)/10)*10 end)-allocated_minor;
  insert into public.payment_refunds(intent_id,recipient_profile_id,idempotency_key,provider_intent_id,
    amount_fils,amount_minor,currency,reason,metadata,status,provider_status)
  values(i.id,i.profile_id,idempotency_key_to_use,i.provider_intent_id,amount_fils_to_refund,minor_to_refund,
    i.currency,left(trim(reason_to_use),1000),coalesce(metadata_to_use,'{}'::jsonb),
    case when minor_to_refund=0 or i.provider='STAGING_E2E' then 'SUCCEEDED' else 'PENDING' end,
    case when minor_to_refund=0 then 'rounding_carry' when i.provider='STAGING_E2E' then 'staging_e2e' else null end)
  returning id into refund_id;
  update public.open_queue_bookings set refund_status=refund_status where payment_intent_id=i.id;
  if i.provider='STAGING_E2E' and allocated+amount_fils_to_refund=i.amount_fils then
    update public.payment_intents set status='REFUNDED' where id=i.id;
  end if;
  return refund_id;
end;
$$;

-- Only the finalization service can enter the domain mutations. The old
-- authenticated wrappers allowed partial finalization outside the intent lock.
revoke all on function public.book_open_queue_game(uuid,text,text,text) from public,anon,authenticated;
revoke all on function public.create_fixture(uuid,text,date,text) from public,anon,authenticated;
revoke all on function public.join_fixture(uuid,uuid) from public,anon,authenticated;
grant execute on function public.create_fixture(uuid,text,date,text),public.join_fixture(uuid,uuid) to service_role;

alter table public.open_queue_bookings drop constraint open_queue_bookings_payment_method_check;
alter table public.open_queue_bookings add constraint open_queue_bookings_payment_method_check
  check(payment_method in ('APPLE_PAY','GOOGLE_PAY','BENEFITPAY','VISA','MASTERCARD','CARD','MOCK','FREE'));
do $migration$
declare definition text;
begin
  definition:=pg_get_functiondef('public.book_open_queue_game_server(uuid,text,text,text)'::regprocedure);
  if position('intent.provider_status = ''CAPTURED''' in definition)=0 then raise exception 'Verified booking payment contract changed.'; end if;
  definition:=replace(definition, 'intent.provider_status = ''CAPTURED''', 'intent.provider_status = ''SUCCEEDED'' and intent.provider in (''STRIPE'', ''STAGING_E2E'')');
  definition:=replace(definition, E'''APPLE_PAY'',\n    ''BENEFITPAY'',', E'''APPLE_PAY'',\n    ''GOOGLE_PAY'',');
  definition:=replace(definition, E'''CARD'',\n    ''MOCK''', E'''CARD'',\n    ''MOCK'',\n    ''FREE''');
  definition:=replace(definition, 'if payment_method_to_use <> ''MOCK'' then', E'if payment_method_to_use = ''FREE'' and total_amount_to_use <> 0 then\n    raise exception ''This game requires payment.'';\n  end if;\n  if payment_method_to_use not in (''MOCK'', ''FREE'') then');
  execute definition;
end;
$migration$;

create or replace function public.finalize_payment_intent(intent_id_to_finalize uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare i public.payment_intents%rowtype; f public.fixtures%rowtype; resource uuid; resource_kind text;
  current_quote jsonb; prior_user text:=current_setting('request.jwt.claim.sub',true); failure text;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can finalize a payment.' using errcode='42501'; end if;
  perform 1 from fieldrush_private.accounts a where a.user_id=(select profile_id from public.payment_intents where id=intent_id_to_finalize) for share;
  select * into i from public.payment_intents where id=intent_id_to_finalize for update;
  if i.id is null then raise exception 'Payment attempt not found.'; end if;
  if i.status not in ('FINALIZED','REFUNDED','REQUIRES_REFUND') then
    if i.provider not in ('STRIPE','STAGING_E2E') or i.status<>'CAPTURED' or i.provider_status<>'SUCCEEDED'
      or i.provider_intent_id is null or i.provider_payment_id is null
      or i.payment_method not in ('APPLE_PAY','GOOGLE_PAY','VISA','MASTERCARD','CARD') then
      raise exception 'Only a verified successful payment can be finalized.';
    end if;
    begin
      perform set_config('request.jwt.claim.sub',i.profile_id::text,true);
      if i.purpose='SOLO_BOOKING' then
        resource:=public.book_open_queue_game_server((i.payload->>'game_id')::uuid,upper(i.payload->>'role'),i.payment_method,i.provider_payment_id);
        resource_kind:='OPEN_QUEUE_BOOKING';
      elsif i.purpose='CLAN_CREATE' then
        -- create/join lock and validate the authoritative slot, roster and
        -- leadership. Any changed charge is rolled back before refund enqueue.
        f:=public.create_fixture((i.payload->>'clan_id')::uuid,i.payload->>'venue',(i.payload->>'match_date')::date,i.payload->>'time_slot');
        if i.currency<>'BHD' or f.home_amount_paid_fils is distinct from i.amount_fils then raise exception 'The clan checkout price changed.'; end if;
        resource:=f.id; resource_kind:='FIXTURE';
        update public.fixtures set home_payment_intent_id=i.id,home_provider_payment_id=i.provider_payment_id where id=f.id;
      elsif i.purpose='CLAN_JOIN' then
        f:=public.join_fixture((i.payload->>'fixture_id')::uuid,(i.payload->>'clan_id')::uuid);
        if i.currency<>'BHD' or f.away_amount_paid_fils is distinct from i.amount_fils then raise exception 'The clan checkout price changed.'; end if;
        resource:=f.id; resource_kind:='FIXTURE';
        update public.fixtures set away_payment_intent_id=i.id,away_provider_payment_id=i.provider_payment_id where id=f.id;
      else raise exception 'The payment purpose is unsupported.';
      end if;
      update public.payment_intents set status='FINALIZED',resource_type=resource_kind,resource_id=resource,
        finalized_at=clock_timestamp(),failure_reason=null where id=i.id returning * into i;
    exception when raise_exception or insufficient_privilege or invalid_parameter_value or check_violation or unique_violation then
      -- A paid-but-unbookable request receives a durable full refund. SQL
      -- transport/deadlock/cancellation errors escape for safe provider retries.
      failure:=left(sqlerrm,1000);
      update public.payment_intents set status='REQUIRES_REFUND',failure_reason=failure where id=i.id returning * into i;
      perform public.request_payment_refund(i.id,i.amount_fils,'finalize-failed:'||i.id,
        'The payment succeeded but its booking could not be completed.',jsonb_build_object('failure_reason',failure));
    end;
    perform set_config('request.jwt.claim.sub',coalesce(prior_user,''),true);
  end if;
  return jsonb_build_object('status',i.status,'intent_id',i.id,'charge_id',i.provider_payment_id,
    'payment_method',i.payment_method,'resource_type',i.resource_type,'resource_id',i.resource_id,'failure_reason',i.failure_reason);
end;
$$;

create function public.record_stripe_payment_capture(
  intent_id_to_capture uuid,provider_intent_id_to_use text,provider_payment_id_to_use text,
  amount_minor_to_use integer,currency_to_use text,payment_method_to_use text
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare i public.payment_intents%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can verify a capture.' using errcode='42501'; end if;
  perform 1 from fieldrush_private.accounts a where a.user_id=(select profile_id from public.payment_intents where id=intent_id_to_capture) for share;
  select * into i from public.payment_intents where id=intent_id_to_capture for update;
  if i.id is null or i.provider<>'STRIPE' then raise exception 'Stripe payment attempt not found.'; end if;
  if i.provider_intent_id is distinct from provider_intent_id_to_use
    or i.amount_minor is distinct from amount_minor_to_use or i.currency is distinct from upper(currency_to_use)
    or nullif(trim(provider_payment_id_to_use),'') is null
    or payment_method_to_use not in ('APPLE_PAY','GOOGLE_PAY','VISA','MASTERCARD','CARD') then
    raise exception 'The provider payment does not match the checkout quote.' using errcode='22023';
  end if;
  if i.status in ('FINALIZED','REFUNDED','REQUIRES_REFUND') then return public.finalize_payment_intent(i.id); end if;
  if i.status in ('CANCELLED','EXPIRED','FAILED') then
    update public.payment_intents set status='REQUIRES_REFUND',provider_status='SUCCEEDED',
      provider_payment_id=provider_payment_id_to_use,payment_method=payment_method_to_use,captured_at=clock_timestamp(),
      failure_reason='A payment completed after this checkout was closed.' where id=i.id;
    perform public.request_payment_refund(i.id,i.amount_fils,'finalize-failed:'||i.id,
      'A payment completed after this checkout was closed.');
  else
    update public.payment_intents set status='CAPTURED',provider_status='SUCCEEDED',
      provider_payment_id=provider_payment_id_to_use,payment_method=payment_method_to_use,captured_at=coalesce(captured_at,clock_timestamp()) where id=i.id;
  end if;
  return public.finalize_payment_intent(i.id);
end;
$$;

create function public.claim_payment_refunds(batch_size integer default 20,intent_id_to_claim uuid default null)
returns setof public.payment_refunds language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can process refunds.' using errcode='42501'; end if;
  return query with due as (
    select r.id from public.payment_refunds r join public.payment_intents i on i.id=r.intent_id
    where i.provider='STRIPE' and r.status<>'SUCCEEDED' and r.next_attempt_at<=clock_timestamp()
      and (r.locked_until is null or r.locked_until<=clock_timestamp())
      and (intent_id_to_claim is null or r.intent_id=intent_id_to_claim)
      and not (r.status='FAILED' and r.provider_refund_id is not null and r.provider_status in ('failed','canceled'))
    order by r.next_attempt_at,r.created_at,r.id for update of r skip locked limit greatest(1,least(coalesce(batch_size,20),100))
  ) update public.payment_refunds r set status='PROCESSING',attempts=r.attempts+1,
    locked_until=clock_timestamp()+interval '5 minutes' from due where r.id=due.id returning r.*;
end;
$$;

create function public.finalize_free_checkout(profile_id_to_use uuid,purpose_to_use text,payload_to_use jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare quote jsonb; resource uuid; prior_user text:=current_setting('request.jwt.claim.sub',true);
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can finalize a free booking.' using errcode='42501'; end if;
  if purpose_to_use<>'SOLO_BOOKING' then raise exception 'This checkout requires payment.'; end if;
  perform set_config('request.jwt.claim.sub',profile_id_to_use::text,true);
  perform pg_advisory_xact_lock(hashtext(profile_id_to_use::text)::bigint);
  select id into resource from public.open_queue_bookings where game_id=(payload_to_use->>'game_id')::uuid
    and profile_id=profile_id_to_use and status='CONFIRMED' and payment_method='FREE';
  if resource is not null then
    perform set_config('request.jwt.claim.sub',coalesce(prior_user,''),true);
    return jsonb_build_object('status','FINALIZED','intent_id',null,'payment_method','FREE','resource_type','OPEN_QUEUE_BOOKING','resource_id',resource);
  end if;
  quote:=public.preview_open_queue_booking_cost((payload_to_use->>'game_id')::uuid,upper(payload_to_use->>'role'));
  if (quote->>'total_fils')::integer is distinct from 0 then raise exception 'This game requires payment.'; end if;
  resource:=public.book_open_queue_game_server((payload_to_use->>'game_id')::uuid,upper(payload_to_use->>'role'),'FREE',null);
  perform set_config('request.jwt.claim.sub',coalesce(prior_user,''),true);
  return jsonb_build_object('status','FINALIZED','intent_id',null,'payment_method','FREE','resource_type','OPEN_QUEUE_BOOKING','resource_id',resource);
end;
$$;

revoke all on function public.claim_payment_webhook(text,text,text),public.request_payment_refund(uuid,integer,text,text,jsonb),
  public.finalize_payment_intent(uuid),public.record_stripe_payment_capture(uuid,text,text,integer,text,text),
  public.claim_payment_refunds(integer,uuid),public.finalize_free_checkout(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.claim_payment_webhook(text,text,text),public.request_payment_refund(uuid,integer,text,text,jsonb),
  public.finalize_payment_intent(uuid),public.record_stripe_payment_capture(uuid,text,text,integer,text,text),
  public.claim_payment_refunds(integer,uuid),public.finalize_free_checkout(uuid,text,jsonb) to service_role;
