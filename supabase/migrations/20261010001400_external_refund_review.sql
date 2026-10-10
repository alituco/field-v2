-- A refund issued in Stripe Dashboard must never cause our worker to refund
-- the same money again. Preserve it separately from policy entitlements and
-- stop unissued transfers until an operator has reconciled the difference.
alter table public.payment_intents add column external_refund_review_required boolean not null default false;
create table public.external_payment_refunds (
  provider_refund_id text primary key,
  intent_id uuid not null references public.payment_intents(id) on delete restrict,
  amount_minor integer not null check(amount_minor>0),
  currency text not null check(currency='USD'),
  provider_status text not null check(provider_status in ('pending','requires_action','succeeded','failed','canceled')),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.external_payment_refunds enable row level security;
revoke all on public.external_payment_refunds from public,anon,authenticated;
grant select,insert,update on public.external_payment_refunds to service_role;

create function public.record_external_stripe_refund(intent_id_to_use uuid,provider_refund_id_to_use text,
  amount_minor_to_use integer,currency_to_use text,provider_status_to_use text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare i public.payment_intents%rowtype; prior public.external_payment_refunds%rowtype; total bigint;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can record provider refunds.' using errcode='42501'; end if;
  select * into i from public.payment_intents where id=intent_id_to_use for update;
  if i.id is null or i.provider<>'STRIPE' or i.currency is distinct from upper(currency_to_use)
    or amount_minor_to_use is null or amount_minor_to_use<=0 or amount_minor_to_use>i.amount_minor
    or provider_refund_id_to_use is null or provider_refund_id_to_use not like 're_%'
    or provider_status_to_use not in ('pending','requires_action','succeeded','failed','canceled') then
    raise exception 'The external refund does not match the captured payment.' using errcode='22023'; end if;
  if exists(select 1 from public.payment_refunds where provider_refund_id=provider_refund_id_to_use) then
    raise exception 'This refund already belongs to a policy refund.' using errcode='22023'; end if;
  select * into prior from public.external_payment_refunds where provider_refund_id=provider_refund_id_to_use for update;
  if prior.provider_refund_id is not null and (prior.intent_id,prior.amount_minor,prior.currency)
    is distinct from (i.id,amount_minor_to_use,i.currency) then
    raise exception 'The external refund identity is immutable.' using errcode='22023'; end if;
  if prior.provider_status='succeeded' and provider_status_to_use<>'succeeded' then
    return to_jsonb(prior); end if;
  select coalesce(sum(amount_minor),0) into total from public.external_payment_refunds
    where intent_id=i.id and provider_refund_id<>provider_refund_id_to_use and provider_status in ('pending','requires_action','succeeded');
  if provider_status_to_use in ('pending','requires_action','succeeded') and total+amount_minor_to_use>i.amount_minor then
    raise exception 'External refunds exceed the captured payment.' using errcode='22023'; end if;
  insert into public.external_payment_refunds(provider_refund_id,intent_id,amount_minor,currency,provider_status)
    values(provider_refund_id_to_use,i.id,amount_minor_to_use,i.currency,provider_status_to_use)
    on conflict(provider_refund_id) do update set provider_status=excluded.provider_status,updated_at=clock_timestamp()
    returning * into prior;
  if provider_status_to_use in ('pending','requires_action','succeeded') then
    update public.payment_intents set external_refund_review_required=true where id=i.id;
    update public.payment_refunds set status='FAILED',provider_status='external_refund_review',locked_until=null,
      last_error='An external Stripe refund requires reconciliation before another refund can be sent.'
      where intent_id=i.id and provider_refund_id is null and status<>'SUCCEEDED';
    update public.match_resolution_refunds mr set status='FAILED',failure_reason=pr.last_error
      from public.payment_refunds pr where mr.payment_refund_id=pr.id and pr.intent_id=i.id and pr.provider_status='external_refund_review';
    update public.open_queue_bookings set refund_status=refund_status where payment_intent_id=i.id;
  end if;
  return to_jsonb(prior)||jsonb_build_object('external_refund_review_required',
    (select external_refund_review_required from public.payment_intents where id=i.id));
end;
$$;
revoke all on function public.record_external_stripe_refund(uuid,text,integer,text,text) from public,anon,authenticated;
grant execute on function public.record_external_stripe_refund(uuid,text,integer,text,text) to service_role;

do $migration$
declare definition text;
begin
  definition:=pg_get_functiondef('public.request_payment_refund(uuid,integer,text,text,jsonb)'::regprocedure);
  -- A review hold stops provider transfers, not cancellation or the durable
  -- record of money owed. Keep the entitlement visible as FAILED/needs review.
  definition:=replace(definition,'case when minor_to_refund=0 or i.provider=''STAGING_E2E'' then ''SUCCEEDED''',
    'case when i.external_refund_review_required then ''FAILED'' when minor_to_refund=0 or i.provider=''STAGING_E2E'' then ''SUCCEEDED''');
  definition:=replace(definition,'case when minor_to_refund=0 then ''rounding_carry''',
    'case when i.external_refund_review_required then ''external_refund_review'' when minor_to_refund=0 then ''rounding_carry''');
  definition:=replace(definition,'  returning id into refund_id;',
    E'  returning id into refund_id;\n  if i.external_refund_review_required then\n    update public.payment_refunds set last_error=''An external Stripe refund requires reconciliation before another refund can be sent.'' where id=refund_id;\n  end if;');
  execute definition;
  definition:=pg_get_functiondef('public.claim_payment_refunds(integer,uuid)'::regprocedure);
  definition:=replace(definition,'i.provider=''STRIPE''',
    'i.provider=''STRIPE'' and (not i.external_refund_review_required or r.provider_refund_id is not null)');
  execute definition;
  definition:=pg_get_functiondef('public.admin_retry_payment_refund(uuid,uuid,text)'::regprocedure);
  definition:=replace(definition,'  before_state:=to_jsonb(r);',
    E'  if exists(select 1 from public.payment_intents where id=r.intent_id and external_refund_review_required) then\n    raise exception ''Reconcile the external Stripe refund before retrying this payment refund.''; end if;\n  before_state:=to_jsonb(r);');
  execute definition;
  definition:=pg_get_functiondef('fieldrush_private.assert_deletion_ready(uuid)'::regprocedure);
  definition:=replace(definition,'  if exists (select 1 from public.payment_refunds',
    E'  if exists(select 1 from public.payment_intents where profile_id=caller and external_refund_review_required) then\n    raise exception ''Contact support to reconcile your payment refund before deleting your account.'' using errcode=''22023''; end if;\n  if exists (select 1 from public.payment_refunds');
  execute definition;
end;
$migration$;
