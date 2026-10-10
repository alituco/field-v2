-- Financial policy keeps its existing amount/strike logic. New provider-paid
-- bookings send every refund/deposit return to the original payment method;
-- balances and immutable wallet history from older bookings remain intact.
alter function public.credit_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb)
  rename to credit_legacy_field_wallet;

create function public.credit_field_wallet(
  profile_id_to_credit uuid,amount_fils_to_credit integer,transaction_type_to_use text,
  idempotency_key_to_use text,description_to_use text,policy_version_id_to_use uuid default null,
  booking_id_to_use uuid default null,incident_id_to_use uuid default null,metadata_to_use jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare intent_id uuid; fixture_id_to_use uuid; i public.payment_intents%rowtype;
begin
  if amount_fils_to_credit<=0 then return null; end if;
  perform 1 from fieldrush_private.accounts where user_id=profile_id_to_credit for share;
  if booking_id_to_use is not null then
    select b.payment_intent_id into intent_id from public.open_queue_bookings b
      where b.id=booking_id_to_use and b.profile_id=profile_id_to_credit;
    if not found then raise exception 'Refund booking and recipient do not match.'; end if;
  else
    fixture_id_to_use:=nullif(metadata_to_use->>'fixture_id','')::uuid;
    if fixture_id_to_use is null and metadata_to_use->>'match_resolution_case_id' is not null then
      select c.fixture_id into fixture_id_to_use from public.match_resolution_cases c
        where c.id=(metadata_to_use->>'match_resolution_case_id')::uuid;
    end if;
    if fixture_id_to_use is not null then
      select case when f.home_paid_by=profile_id_to_credit then f.home_payment_intent_id
        when f.away_paid_by=profile_id_to_credit then f.away_payment_intent_id end into intent_id
      from public.fixtures f where f.id=fixture_id_to_use;
      if not found then raise exception 'Refund fixture is missing.'; end if;
    end if;
  end if;
  if intent_id is not null then
    select * into i from public.payment_intents where id=intent_id;
    if i.profile_id is distinct from profile_id_to_credit then raise exception 'Refund payment and recipient do not match.'; end if;
    if i.provider in ('STRIPE','STAGING_E2E') then
      return public.request_payment_refund(i.id,amount_fils_to_credit,idempotency_key_to_use,
        replace(replace(description_to_use,'credited to Field Wallet','returned to the original payment method'),'Field Wallet refund','original-payment refund'),
        coalesce(metadata_to_use,'{}'::jsonb)||jsonb_build_object('transaction_type',transaction_type_to_use,
          'policy_version_id',policy_version_id_to_use,'booking_id',booking_id_to_use,'fixture_id',fixture_id_to_use,
          'incident_id',incident_id_to_use));
    end if;
  end if;
  return public.credit_legacy_field_wallet(profile_id_to_credit,amount_fils_to_credit,transaction_type_to_use,
    idempotency_key_to_use,description_to_use,policy_version_id_to_use,booking_id_to_use,incident_id_to_use,metadata_to_use);
end;
$$;
revoke all on function public.credit_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb),
  public.credit_legacy_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.credit_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb),
  public.credit_legacy_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb) to service_role;
comment on function public.credit_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb) is
  'Financial policy refund dispatcher: Stripe bookings refund their original payment method; historical bookings retain the original wallet contract.';

alter table public.match_resolution_refunds add column payment_refund_id uuid
  references public.payment_refunds(id) on delete restrict;
alter table public.match_resolution_refunds add column currency text not null default 'BHD' check(currency in ('BHD','USD'));
update public.match_resolution_refunds r set currency=g.currency
  from public.open_queue_bookings b join public.open_queue_games g on g.id=b.game_id where r.booking_id=b.id;
create index match_resolution_refunds_payment_idx on public.match_resolution_refunds(payment_refund_id) where payment_refund_id is not null;
alter table public.open_queue_bookings add column refund_destination text not null default 'FIELD_WALLET'
  check(refund_destination in ('FIELD_WALLET','ORIGINAL_PAYMENT_METHOD'));

-- Existing policy callers return a financial operation UUID. Route the new
-- refund UUID before the legacy wallet FK check, and expose honest transfer
-- status even when the administrative outcome itself has been resolved.
create function public.link_match_resolution_payment_refund()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.payment_refunds%rowtype; i public.payment_intents%rowtype;
begin
  if new.booking_id is not null then
    select p.* into i from public.payment_intents p join public.open_queue_bookings b on b.payment_intent_id=p.id where b.id=new.booking_id;
    select g.currency into new.currency from public.open_queue_games g join public.open_queue_bookings b on b.game_id=g.id where b.id=new.booking_id;
  else
    select p.* into i from public.payment_intents p join public.fixtures f
      on p.id=case when new.side='HOME' then f.home_payment_intent_id else f.away_payment_intent_id end
      join public.match_resolution_cases c on c.fixture_id=f.id where c.id=new.case_id;
  end if;
  if i.provider in ('STRIPE','STAGING_E2E') then new.destination:='ORIGINAL_PAYMENT_METHOD'; new.currency:=i.currency; end if;
  select * into r from public.payment_refunds where id=coalesce(new.payment_refund_id,new.wallet_transaction_id);
  if r.id is not null then
    if r.recipient_profile_id is distinct from new.recipient_profile_id then raise exception 'Refund recipient mismatch.'; end if;
    new.payment_refund_id:=r.id; new.wallet_transaction_id:=null; new.destination:='ORIGINAL_PAYMENT_METHOD';
    new.currency:=r.currency;
    new.status:=case when r.status='SUCCEEDED' then 'COMPLETED' when r.status='FAILED' then 'FAILED' else 'PENDING' end;
    new.failure_reason:=case when r.status='FAILED' then left(r.last_error,1000) else null end;
  end if;
  return new;
end;
$$;
create trigger link_match_resolution_payment_refund before insert or update on public.match_resolution_refunds
  for each row execute function public.link_match_resolution_payment_refund();

create function public.reflect_booking_payment_refund()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare paid integer; succeeded bigint; pending boolean; failed boolean;
begin
  if new.payment_intent_id is null then return new; end if;
  select i.amount_minor into paid from public.payment_intents i
    where i.id=new.payment_intent_id and i.provider in ('STRIPE','STAGING_E2E');
  if not found then return new; end if;
  new.refund_destination:='ORIGINAL_PAYMENT_METHOD';
  select coalesce(sum(r.amount_minor) filter(where r.status='SUCCEEDED'),0),
    coalesce(bool_or(r.status in ('PENDING','PROCESSING')),false),coalesce(bool_or(r.status='FAILED'),false)
  into succeeded,pending,failed from public.payment_refunds r where r.intent_id=new.payment_intent_id;
  if failed then new.refund_status:='FAILED';
  elsif pending then new.refund_status:='PROCESSING';
  elsif succeeded>0 then new.refund_status:='PROCESSED';
  end if;
  if succeeded>=paid then new.payment_status:='REFUNDED';
  elsif succeeded>0 then new.payment_status:='PARTIALLY_REFUNDED';
  elsif pending or failed then new.payment_status:='PAID';
  end if;
  return new;
end;
$$;
create trigger reflect_booking_payment_refund before insert or update on public.open_queue_bookings
  for each row execute function public.reflect_booking_payment_refund();

-- A queued refund commits the entitlement (including fractional-cent carry).
-- Future corrections subtract queued as well as completed amounts. The
-- transfer status remains PENDING and is never presented as paid prematurely.
do $migration$
declare definition text;
begin
  definition:=pg_get_functiondef('public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)'::regprocedure);
  if position('refund_status_to_use = ''COMPLETED''' in definition)=0 then raise exception 'Match resolution refund contract changed.'; end if;
  definition:=replace(definition, 'refund_status_to_use = ''COMPLETED''', 'refund_status_to_use in (''COMPLETED'',''PENDING'')');
  execute definition;
end;
$migration$;

create function public.finish_payment_refund(
  refund_id_to_finish uuid,provider_refund_id_to_use text,provider_status_to_use text,
  amount_minor_to_use integer,currency_to_use text,failure_reason_to_use text default null,retry_generation_to_use integer default 0
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.payment_refunds%rowtype; i public.payment_intents%rowtype; total_succeeded bigint; next_status text;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can confirm refunds.' using errcode='42501'; end if;
  select p.* into i from public.payment_intents p join public.payment_refunds refund on refund.intent_id=p.id where refund.id=refund_id_to_finish for update of p;
  select * into r from public.payment_refunds where id=refund_id_to_finish for update;
  if r.id is null then raise exception 'Refund not found.'; end if;
  if r.retry_generation is distinct from retry_generation_to_use then return to_jsonb(r)||jsonb_build_object('stale',true); end if;
  if r.amount_minor is distinct from amount_minor_to_use or r.currency is distinct from upper(currency_to_use)
    or (r.provider_refund_id is not null and provider_refund_id_to_use is distinct from r.provider_refund_id)
    or (provider_status_to_use='succeeded' and nullif(trim(provider_refund_id_to_use),'') is null) then
    raise exception 'The provider refund does not match its approved amount and currency.' using errcode='22023';
  end if;
  if r.status='SUCCEEDED' then return to_jsonb(r); end if;
  next_status:=case when provider_status_to_use='succeeded' then 'SUCCEEDED'
    when provider_status_to_use in ('pending','requires_action') then 'PENDING' else 'FAILED' end;
  update public.payment_refunds set provider_refund_id=coalesce(provider_refund_id_to_use,provider_refund_id),
    provider_status=provider_status_to_use,status=next_status,locked_until=null,
    next_attempt_at=clock_timestamp()+case when next_status='FAILED' then interval '5 minutes' else interval '1 minute' end,
    last_error=case when next_status='FAILED' then left(coalesce(failure_reason_to_use,'The provider refund needs review.'),1000) else null end
    where id=r.id returning * into r;
  select coalesce(sum(amount_minor),0) into total_succeeded from public.payment_refunds where intent_id=i.id and status='SUCCEEDED';
  if total_succeeded>=i.amount_minor then update public.payment_intents set status='REFUNDED' where id=i.id; end if;
  update public.match_resolution_refunds set
    status=case when r.status='SUCCEEDED' then 'COMPLETED' when r.status='FAILED' then 'FAILED' else 'PENDING' end,
    failure_reason=r.last_error where payment_refund_id=r.id;
  -- Cause the shared BEFORE trigger to recalculate the live transfer state.
  update public.open_queue_bookings set refund_status=refund_status where payment_intent_id=i.id;
  return to_jsonb(r);
end;
$$;

create function public.admin_retry_payment_refund(actor_admin_id uuid,refund_id_to_retry uuid,reason_to_use text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.payment_refunds%rowtype; before_state jsonb;
begin
  if auth.role() is distinct from 'service_role' or not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Only an administrator can retry a payment refund.' using errcode='42501'; end if;
  if char_length(trim(coalesce(reason_to_use,'')))<5 then raise exception 'Provide a reason for retrying this refund.'; end if;
  select * into r from public.payment_refunds where id=refund_id_to_retry for update;
  if r.id is null then raise exception 'Refund not found.'; end if;
  if r.status='SUCCEEDED' then return to_jsonb(r); end if;
  if r.locked_until>clock_timestamp() then raise exception 'This refund is already being processed.'; end if;
  before_state:=to_jsonb(r);
  update public.payment_refunds set status='PENDING',next_attempt_at=clock_timestamp(),locked_until=null,last_error=null,
    retry_generation=retry_generation+case when provider_refund_id is not null and provider_status in ('failed','canceled') then 1 else 0 end,
    provider_refund_id=case when provider_status in ('failed','canceled') then null else provider_refund_id end,
    provider_status=case when provider_status in ('failed','canceled') then null else provider_status end
    where id=r.id returning * into r;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_admin_id,'PAYMENT_REFUND_RETRY','ACTION',r.id,left(trim(reason_to_use),1000),before_state,to_jsonb(r));
  update public.match_resolution_refunds set status='PENDING',failure_reason=null where payment_refund_id=r.id;
  return to_jsonb(r);
end;
$$;

-- Backend-only helpers are called by the public cancellation quote functions,
-- which already enforce ownership. They do not expose another player's money.
create function public.payment_refund_summary(intent_id_to_use uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare provider_to_use text; summary_status text;
begin
  select provider into provider_to_use from public.payment_intents where id=intent_id_to_use;
  if provider_to_use not in ('STRIPE','STAGING_E2E') or provider_to_use is null then
    return jsonb_build_object('refund_destination','FIELD_WALLET','refund_status','NOT_DUE');
  end if;
  select case when count(*)=0 then 'NOT_DUE' when bool_or(status='FAILED') then 'FAILED'
    when bool_or(status='PROCESSING') then 'PROCESSING' when bool_or(status='PENDING') then 'PENDING'
    else 'SUCCEEDED' end into summary_status from public.payment_refunds where intent_id=intent_id_to_use;
  return jsonb_build_object('refund_destination','ORIGINAL_PAYMENT_METHOD','refund_status',summary_status);
end;
$$;

alter function public.admin_retry_match_resolution_refund(uuid,uuid,text) rename to admin_retry_match_resolution_refund_legacy;
create function public.admin_retry_match_resolution_refund(actor_admin_id uuid,refund_id_to_retry uuid,reason_to_use text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare payment_refund uuid; result jsonb;
begin
  select payment_refund_id into payment_refund from public.match_resolution_refunds where id=refund_id_to_retry;
  if payment_refund is not null then
    result:=public.admin_retry_payment_refund(actor_admin_id,payment_refund,reason_to_use);
    return result||jsonb_build_object('refund_id',refund_id_to_retry,'payment_refund_id',payment_refund,
      'destination','ORIGINAL_PAYMENT_METHOD');
  end if;
  return public.admin_retry_match_resolution_refund_legacy(actor_admin_id,refund_id_to_retry,reason_to_use);
end;
$$;

-- Extend the return JSON at the public boundary, preserving the proven quote
-- and cancellation mutation implementations verbatim under internal names.
alter function public.preview_open_queue_cancellation(uuid) rename to preview_open_queue_cancellation_policy;
create function public.preview_open_queue_cancellation(booking_id_to_preview uuid)
returns table(can_cancel boolean,refund_percent integer,refund_amount_fils integer,refund_cutoff_at timestamptz,
  server_now timestamptz,policy_version_id uuid,outcome_code text,strike_delta integer,refund_bps integer,
  refund_destination text,deposit_forfeited boolean,explanation text,check_in_deadline_at timestamptz,no_show_cutoff_at timestamptz,refund_status text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare intent_id uuid; summary jsonb;
begin
  select payment_intent_id into intent_id from public.open_queue_bookings where id=booking_id_to_preview;
  summary:=public.payment_refund_summary(intent_id);
  return query select q.can_cancel,q.refund_percent,q.refund_amount_fils,q.refund_cutoff_at,q.server_now,
    q.policy_version_id,q.outcome_code,q.strike_delta,q.refund_bps,summary->>'refund_destination',q.deposit_forfeited,
    q.explanation,q.check_in_deadline_at,q.no_show_cutoff_at,summary->>'refund_status'
    from public.preview_open_queue_cancellation_policy(booking_id_to_preview) q;
end;
$$;
alter function public.cancel_open_queue_booking(uuid) rename to cancel_open_queue_booking_policy;
create function public.cancel_open_queue_booking(booking_id_to_cancel uuid)
returns public.open_queue_bookings language plpgsql security definer set search_path=public,pg_temp as $$
declare result public.open_queue_bookings%rowtype;
begin
  perform public.cancel_open_queue_booking_policy(booking_id_to_cancel);
  select * into result from public.open_queue_bookings where id=booking_id_to_cancel;
  return result;
end;
$$;
alter function public.preview_clan_fixture_cancellation(uuid) rename to preview_clan_fixture_cancellation_policy;
create function public.preview_clan_fixture_cancellation(fixture_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare quote jsonb; intent_id uuid;
begin
  quote:=public.preview_clan_fixture_cancellation_policy(fixture_id_to_use);
  select case when quote->>'cancelling_side'='HOME' then f.home_payment_intent_id else f.away_payment_intent_id end into intent_id
    from public.fixtures f where id=fixture_id_to_use;
  return quote||public.payment_refund_summary(intent_id);
end;
$$;
alter function public.cancel_clan_fixture_booking(uuid,text) rename to cancel_clan_fixture_booking_policy;
create function public.cancel_clan_fixture_booking(fixture_id_to_cancel uuid,reason_to_use text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare result jsonb; intent_id uuid;
begin
  result:=public.cancel_clan_fixture_booking_policy(fixture_id_to_cancel,reason_to_use);
  select case when result->>'cancelling_side'='HOME' then f.home_payment_intent_id else f.away_payment_intent_id end into intent_id
    from public.fixtures f where id=fixture_id_to_cancel;
  return result||public.payment_refund_summary(intent_id);
end;
$$;

-- Current policies can be read and new policies can state original-method
-- refunds. Immutable historical policy versions are never rewritten.
do $migration$
declare definition text;
begin
  definition:=pg_get_functiondef('public.reliability_policy_config_is_valid(jsonb)'::regprocedure);
  if position('config_to_check #>> ''{wallet,refundDestination}'' <> ''FIELD_WALLET''' in definition)=0 then
    raise exception 'Reliability refund destination validator changed.';
  end if;
  definition:=replace(definition, 'config_to_check #>> ''{wallet,refundDestination}'' <> ''FIELD_WALLET''',
    'config_to_check #>> ''{wallet,refundDestination}'' not in (''FIELD_WALLET'',''ORIGINAL_PAYMENT_METHOD'')');
  execute definition;
  definition:=pg_get_functiondef('public.preview_open_queue_booking_cost(uuid,text)'::regprocedure);
  definition:=replace(definition, '''deposit_return_destination'', ''FIELD_WALLET''','''deposit_return_destination'', ''ORIGINAL_PAYMENT_METHOD'', ''refund_destination'', ''ORIGINAL_PAYMENT_METHOD''');
  execute definition;
  definition:=pg_get_functiondef('public.clan_fixture_charge_quote_from_snapshot(uuid,uuid,jsonb,timestamp with time zone)'::regprocedure);
  definition:=replace(definition, '''deposit_return_destination'', ''FIELD_WALLET''','''deposit_return_destination'', ''ORIGINAL_PAYMENT_METHOD'', ''refund_destination'', ''ORIGINAL_PAYMENT_METHOD''');
  execute definition;
  definition:=pg_get_functiondef('public.clan_fixture_cancellation_quote(uuid,uuid,timestamp with time zone)'::regprocedure);
  if position('''can_cancel'', fixture_to_use.status' in definition)=0 then raise exception 'Clan cancellation quote identity changed.'; end if;
  definition:=replace(definition, '''can_cancel'', fixture_to_use.status', '''fixture_id'', fixture_to_use.id, ''can_cancel'', fixture_to_use.status');
  execute definition;
  definition:=pg_get_functiondef('public.get_match_resolution_case(text,uuid)'::regprocedure);
  if position('''amount_fils'', refund.amount_fils' in definition)=0 then raise exception 'Participant refund summary contract changed.'; end if;
  definition:=replace(definition, '''amount_fils'', refund.amount_fils', '''currency'', refund.currency, ''amount_fils'', refund.amount_fils');
  execute definition;
end;
$migration$;

revoke all on function public.finish_payment_refund(uuid,text,text,integer,text,text,integer),public.admin_retry_payment_refund(uuid,uuid,text),
  public.payment_refund_summary(uuid),public.preview_open_queue_cancellation_policy(uuid),public.cancel_open_queue_booking_policy(uuid),
  public.preview_clan_fixture_cancellation_policy(uuid),public.cancel_clan_fixture_booking_policy(uuid,text)
  ,public.admin_retry_match_resolution_refund_legacy(uuid,uuid,text),public.admin_retry_match_resolution_refund(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.finish_payment_refund(uuid,text,text,integer,text,text,integer),public.admin_retry_payment_refund(uuid,uuid,text),
  public.payment_refund_summary(uuid),public.admin_retry_match_resolution_refund(uuid,uuid,text) to service_role;
revoke all on function public.preview_open_queue_cancellation(uuid),public.cancel_open_queue_booking(uuid),
  public.preview_clan_fixture_cancellation(uuid),public.cancel_clan_fixture_booking(uuid,text) from public,anon,authenticated;
grant execute on function public.preview_open_queue_cancellation(uuid),public.cancel_open_queue_booking(uuid),
  public.preview_clan_fixture_cancellation(uuid),public.cancel_clan_fixture_booking(uuid,text) to authenticated,service_role;
