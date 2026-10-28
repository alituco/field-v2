-- A missing local Stripe ID is ambiguous, not proof that no payment exists.
-- Provider listing can recover positive matches; only an explicitly audited
-- active-admin review may release a historical no-match/multiple-cancelled case.
create table fieldrush_private.stripe_checkout_recovery_cases (
  id uuid primary key default gen_random_uuid(),
  intent_id uuid not null unique references public.payment_intents(id) on delete restrict,
  state text not null default 'OPEN' check(state in ('OPEN','REVIEW_REQUIRED','LINKED','RESOLVED')),
  outcome text,
  livemode boolean not null,
  scan_from bigint not null,
  scan_until bigint not null,
  scan_cursor text,
  scan_complete boolean not null default false,
  provider_evidence jsonb not null default '[]' check(jsonb_typeof(provider_evidence)='array'),
  pages_scanned integer not null default 0 check(pages_scanned>=0),
  claim_id uuid,
  locked_until timestamptz,
  next_check_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create table fieldrush_private.stripe_checkout_recovery_events (
  id bigint generated always as identity primary key,
  case_id uuid not null references fieldrush_private.stripe_checkout_recovery_cases(id) on delete restrict,
  actor_admin_id uuid references public.referee_profiles(profile_id) on delete restrict,
  outcome text not null,
  evidence_reference text,
  reason text,
  detail jsonb not null default '{}',
  created_at timestamptz not null default clock_timestamp()
);
alter table fieldrush_private.stripe_checkout_recovery_cases enable row level security;
alter table fieldrush_private.stripe_checkout_recovery_events enable row level security;
revoke all on fieldrush_private.stripe_checkout_recovery_cases,fieldrush_private.stripe_checkout_recovery_events from public,anon,authenticated,service_role;

create function fieldrush_private.stripe_recovery_evidence_valid(e jsonb,i public.payment_intents,expected_live boolean)
returns boolean language sql immutable set search_path=pg_catalog,public,pg_temp as $$
  select coalesce(jsonb_typeof(e)='object' and e->>'object'='payment_intent'
    and e->>'id' ~ '^pi_[A-Za-z0-9]+$' and e->'livemode'=to_jsonb(expected_live)
    and e->'amount'=to_jsonb(i.amount_minor) and lower(e->>'currency')=lower(i.currency)
    and e->>'capture_method'='automatic' and e->'payment_method_types'='["card"]'::jsonb
    and e->'metadata' @> jsonb_build_object('field_payment_intent_id',i.id::text,
      'field_profile_id',i.profile_id::text,'field_purpose',i.purpose,
      'field_transaction_reference',i.transaction_reference),false);
$$;
revoke all on function fieldrush_private.stripe_recovery_evidence_valid(jsonb,public.payment_intents,boolean) from public,anon,authenticated,service_role;

create function public.claim_stripe_checkout_recovery(intent_id_to_use uuid,claim_id_to_use uuid,livemode_to_use boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare i public.payment_intents%rowtype;c fieldrush_private.stripe_checkout_recovery_cases%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can recover checkout.' using errcode='42501';end if;
  if claim_id_to_use is null or livemode_to_use is null then raise exception 'A recovery claim and payment mode are required.' using errcode='22023';end if;
  select * into i from public.payment_intents where id=intent_id_to_use for update;
  if not found or i.provider<>'STRIPE' then raise exception 'Stripe checkout not found.' using errcode='22023';end if;
  if i.provider_intent_id is not null or i.status<>'PENDING' then
    return jsonb_build_object('claimed',false,'provider_intent_id',i.provider_intent_id,'status',i.status);
  end if;
  if i.created_at>clock_timestamp()-interval '23 hours' then raise exception 'This checkout can still use its original idempotent create.' using errcode='22023';end if;
  insert into fieldrush_private.stripe_checkout_recovery_cases(intent_id,livemode,scan_from,scan_until)
    values(i.id,livemode_to_use,floor(extract(epoch from i.created_at))::bigint-300,
      least(floor(extract(epoch from clock_timestamp()))::bigint,floor(extract(epoch from i.created_at))::bigint+86400))
    on conflict(intent_id) do nothing;
  select * into c from fieldrush_private.stripe_checkout_recovery_cases where intent_id=i.id for update;
  if c.livemode is distinct from livemode_to_use then raise exception 'The recovery payment environment does not match.' using errcode='22023';end if;
  if c.locked_until>clock_timestamp() or c.next_check_at>clock_timestamp() or c.state in ('LINKED','RESOLVED') then
    return jsonb_build_object('claimed',false,'case_id',c.id,'status',i.status);
  end if;
  -- An incomplete scan resumes its exact fixed range/cursor. A completed review
  -- recheck starts afresh, never treating an old empty result as current proof.
  if c.scan_complete then
    c.scan_cursor:=null;c.scan_complete:=false;c.provider_evidence:='[]';c.pages_scanned:=0;
  end if;
  update fieldrush_private.stripe_checkout_recovery_cases set claim_id=claim_id_to_use,
    locked_until=clock_timestamp()+interval '2 minutes',scan_cursor=c.scan_cursor,
    scan_complete=c.scan_complete,provider_evidence=c.provider_evidence,pages_scanned=c.pages_scanned,
    updated_at=clock_timestamp() where id=c.id returning * into c;
  return jsonb_build_object('claimed',true,'case_id',c.id,'scan_from',c.scan_from,'scan_until',c.scan_until,
    'scan_cursor',c.scan_cursor,'provider_evidence',c.provider_evidence,'pages_scanned',c.pages_scanned);
end;$$;

create function public.complete_stripe_checkout_recovery(intent_id_to_use uuid,claim_id_to_use uuid,
  outcome_to_use text,evidence_to_use jsonb,scan_complete_to_use boolean,scan_cursor_to_use text,pages_scanned_to_use integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare i public.payment_intents%rowtype;c fieldrush_private.stripe_checkout_recovery_cases%rowtype;e jsonb;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can finish recovery.' using errcode='42501';end if;
  select * into i from public.payment_intents where id=intent_id_to_use for update;
  select * into c from fieldrush_private.stripe_checkout_recovery_cases where intent_id=i.id for update;
  if c.id is null or claim_id_to_use is null or c.claim_id is null
    or c.claim_id is distinct from claim_id_to_use or c.locked_until is null or c.locked_until<=clock_timestamp() then
    raise exception 'The checkout recovery claim expired.' using errcode='40001';end if;
  if outcome_to_use not in ('RECOVERED','NO_MATCH','MULTIPLE_MATCHES','MISMATCH','INCOMPLETE','PROVIDER_UNAVAILABLE')
    or outcome_to_use is null or jsonb_typeof(evidence_to_use) is distinct from 'array'
    or jsonb_array_length(evidence_to_use)>1000 or pages_scanned_to_use<c.pages_scanned
    or scan_complete_to_use is null or (not scan_complete_to_use and scan_cursor_to_use is not null and scan_cursor_to_use !~ '^pi_[A-Za-z0-9]+$') then
    raise exception 'Invalid checkout recovery evidence.' using errcode='22023';end if;
  if i.status<>'PENDING' or i.provider_intent_id is not null then
    return jsonb_build_object('case_id',c.id,'provider_intent_id',i.provider_intent_id,'status',i.status);
  end if;
  if outcome_to_use='RECOVERED' then
    if not scan_complete_to_use or jsonb_array_length(evidence_to_use)<>1 then raise exception 'A complete unique provider match is required.' using errcode='22023';end if;
    e:=evidence_to_use->0;
    if not fieldrush_private.stripe_recovery_evidence_valid(e,i,c.livemode) then raise exception 'Recovered provider payment does not match checkout.' using errcode='22023';end if;
    update public.payment_intents set provider_intent_id=e->>'id',provider_status=e->>'status' where id=i.id returning * into i;
  elsif outcome_to_use='NO_MATCH' and (not scan_complete_to_use or jsonb_array_length(evidence_to_use)<>0) then
    raise exception 'A no-match report requires a completed empty listing.' using errcode='22023';
  end if;
  update fieldrush_private.stripe_checkout_recovery_cases set state=case when outcome_to_use='RECOVERED' then 'LINKED'
    when outcome_to_use='INCOMPLETE' then 'OPEN' else 'REVIEW_REQUIRED' end,outcome=outcome_to_use,
    scan_complete=scan_complete_to_use,scan_cursor=scan_cursor_to_use,provider_evidence=evidence_to_use,pages_scanned=pages_scanned_to_use,
    claim_id=null,locked_until=null,next_check_at=clock_timestamp()+case when outcome_to_use='INCOMPLETE' then interval '1 minute' else interval '15 minutes' end,
    updated_at=clock_timestamp() where id=c.id returning * into c;
  insert into fieldrush_private.stripe_checkout_recovery_events(case_id,outcome,detail)
    values(c.id,outcome_to_use,jsonb_build_object('candidate_ids',(select coalesce(jsonb_agg(v->>'id'),'[]') from jsonb_array_elements(evidence_to_use) v),
      'scan_complete',c.scan_complete,'pages_scanned',c.pages_scanned,'scan_from',c.scan_from,'scan_until',c.scan_until));
  return jsonb_build_object('case_id',c.id,'provider_intent_id',i.provider_intent_id,'status',i.status);
end;$$;

create function public.admin_list_stripe_checkout_recovery(actor_admin_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
begin
  if auth.role() is distinct from 'service_role' or not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Only an active administrator can review checkout recovery.' using errcode='42501';end if;
  return (select coalesce(jsonb_agg(x),'[]') from (select c.id,c.intent_id,c.state,c.outcome,c.scan_complete,c.pages_scanned,c.updated_at,
    i.profile_id,i.amount_minor,i.currency,i.created_at,c.provider_evidence from fieldrush_private.stripe_checkout_recovery_cases c
    join public.payment_intents i on i.id=c.intent_id where c.state in ('OPEN','REVIEW_REQUIRED') order by c.created_at limit 100) x);
end;$$;

create function public.admin_resolve_stripe_checkout_recovery(actor_admin_id uuid,case_id_to_use uuid,resolution_to_use text,
  evidence_reference_to_use text,reason_to_use text,expected_updated_at timestamptz,provider_evidence_to_use jsonb default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare i public.payment_intents%rowtype;c fieldrush_private.stripe_checkout_recovery_cases%rowtype;intent_key uuid;e jsonb;before_state jsonb;
begin
  if auth.role() is distinct from 'service_role' or not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Only an active administrator can resolve checkout recovery.' using errcode='42501';end if;
  if char_length(trim(coalesce(evidence_reference_to_use,''))) not between 10 and 1000
    or char_length(trim(coalesce(reason_to_use,''))) not between 10 and 1000 then raise exception 'Record a provider evidence reference and review reason.' using errcode='22023';end if;
  select intent_id into intent_key from fieldrush_private.stripe_checkout_recovery_cases where id=case_id_to_use;
  select * into i from public.payment_intents where id=intent_key for update;
  select * into c from fieldrush_private.stripe_checkout_recovery_cases where id=case_id_to_use for update;
  if c.id is null or c.state not in ('OPEN','REVIEW_REQUIRED') or c.updated_at is distinct from expected_updated_at
    or c.locked_until>clock_timestamp() then raise exception 'Recovery changed or is still running. Refresh before reviewing.' using errcode='40001';end if;
  if i.provider<>'STRIPE' or i.status<>'PENDING' or i.provider_intent_id is not null or i.provider_payment_id is not null
    or i.captured_at is not null or i.finalized_at is not null or i.resource_id is not null or i.external_refund_review_required
    or i.created_at>clock_timestamp()-interval '23 hours' or not c.scan_complete
    or exists(select 1 from public.open_queue_bookings where payment_intent_id=i.id)
    or exists(select 1 from public.payment_refunds where intent_id=i.id)
    or exists(select 1 from public.external_payment_refunds where intent_id=i.id)
    or exists(select 1 from public.fixtures where home_payment_intent_id=i.id or away_payment_intent_id=i.id) then
    raise exception 'Unresolved or captured payment evidence prevents releasing this checkout.' using errcode='22023';end if;
  if resolution_to_use='NO_PAYMENT_EXISTS' then
    if c.outcome<>'NO_MATCH' or jsonb_array_length(c.provider_evidence)<>0 then raise exception 'Only a completed no-match review can use no-payment attestation.' using errcode='22023';end if;
  elsif resolution_to_use='ALL_PROVIDER_PAYMENTS_CANCELLED' then
    if jsonb_typeof(provider_evidence_to_use) is distinct from 'array' or jsonb_array_length(c.provider_evidence)=0
      or jsonb_array_length(provider_evidence_to_use)<>jsonb_array_length(c.provider_evidence)
      or (select array_agg(v->>'id' order by v->>'id') from jsonb_array_elements(provider_evidence_to_use) v)
        is distinct from (select array_agg(v->>'id' order by v->>'id') from jsonb_array_elements(c.provider_evidence) v) then
      raise exception 'Fresh cancellation evidence must cover every provider candidate.' using errcode='22023';end if;
    for e in select value from jsonb_array_elements(provider_evidence_to_use) loop
      if not fieldrush_private.stripe_recovery_evidence_valid(e,i,c.livemode) or e->>'status' is distinct from 'canceled' or e->'amount_received' is distinct from '0'::jsonb then
        raise exception 'Every candidate must be provider-confirmed cancelled with no money received.' using errcode='22023';end if;
    end loop;
  else raise exception 'Choose an explicit provider review outcome.' using errcode='22023';end if;
  before_state:=to_jsonb(i);
  update public.payment_intents set status='CANCELLED',failure_reason='Audited Stripe recovery: '||resolution_to_use||'. '||trim(reason_to_use) where id=i.id returning * into i;
  update fieldrush_private.stripe_checkout_recovery_cases set state='RESOLVED',outcome=resolution_to_use,claim_id=null,locked_until=null,updated_at=clock_timestamp() where id=c.id;
  insert into fieldrush_private.stripe_checkout_recovery_events(case_id,actor_admin_id,outcome,evidence_reference,reason,detail)
    values(c.id,actor_admin_id,resolution_to_use,trim(evidence_reference_to_use),trim(reason_to_use),jsonb_build_object('provider_evidence',provider_evidence_to_use));
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_admin_id,'STRIPE_CHECKOUT_RECOVERY_RESOLVED','ACTION',i.id,trim(reason_to_use),before_state,
      to_jsonb(i)||jsonb_build_object('recovery_case_id',c.id,'evidence_reference',trim(evidence_reference_to_use)));
  return jsonb_build_object('case_id',c.id,'intent_id',i.id,'status',i.status);
end;$$;

revoke all on function public.claim_stripe_checkout_recovery(uuid,uuid,boolean),
  public.complete_stripe_checkout_recovery(uuid,uuid,text,jsonb,boolean,text,integer),
  public.admin_list_stripe_checkout_recovery(uuid),
  public.admin_resolve_stripe_checkout_recovery(uuid,uuid,text,text,text,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.claim_stripe_checkout_recovery(uuid,uuid,boolean),
  public.complete_stripe_checkout_recovery(uuid,uuid,text,jsonb,boolean,text,integer),
  public.admin_list_stripe_checkout_recovery(uuid),
  public.admin_resolve_stripe_checkout_recovery(uuid,uuid,text,text,text,timestamptz,jsonb) to service_role;
notify pgrst,'reload schema';
