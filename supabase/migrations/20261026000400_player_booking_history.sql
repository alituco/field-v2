-- Owner-only receipts and cancelled-game history. Existing public played-match
-- history, rating calculations, attendance and financial writers are unchanged.
create index player_payment_history_idx on public.payment_intents
  (profile_id,(coalesce(captured_at,created_at)) desc,id desc)
  where provider in ('STRIPE','LEGACY') and status in ('CAPTURED','FINALIZED','REQUIRES_REFUND','REFUNDED');
create index player_cancelled_game_history_idx on public.open_queue_games(starts_at desc,id desc) where status='CANCELLED';

create function fieldrush_private.player_history_refunds(
  intent_to_use uuid,booking_to_use uuid,owner_to_use uuid,currency_to_use text,paid_minor_to_use integer
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare provider_to_use text; review boolean:=false; settled bigint:=0; pending bigint:=0; failed bigint:=0;
  destination text:='ORIGINAL_PAYMENT_METHOD'; fixture_to_use text;
begin
  select i.provider,coalesce(i.external_refund_review_required,false),
    case when i.resource_type='FIXTURE' then i.resource_id::text else i.payload->>'fixture_id' end
  into provider_to_use,review,fixture_to_use from public.payment_intents i
  where i.id=intent_to_use and i.profile_id=owner_to_use;
  if provider_to_use in ('STRIPE','STAGING_E2E') then
    select coalesce(sum(amount) filter(where state='SUCCEEDED'),0),
      coalesce(sum(amount) filter(where state in ('PENDING','PROCESSING')),0),
      coalesce(sum(amount) filter(where state='FAILED'),0) into settled,pending,failed
    from (select distinct on (refund_key) amount,state from (
      select coalesce('provider:'||r.provider_refund_id,'policy:'||r.id::text) refund_key,
        r.amount_minor amount,r.status state,r.updated_at from public.payment_refunds r
      where r.intent_id=intent_to_use and r.recipient_profile_id=owner_to_use and r.currency=currency_to_use
      union all
      select 'provider:'||e.provider_refund_id,e.amount_minor,case e.provider_status when 'succeeded' then 'SUCCEEDED'
        when 'pending' then 'PENDING' when 'requires_action' then 'PENDING' else 'FAILED' end,e.updated_at
      from public.external_payment_refunds e where e.intent_id=intent_to_use and e.currency=currency_to_use
    ) movements order by refund_key,case state when 'SUCCEEDED' then 0 when 'PROCESSING' then 1 when 'PENDING' then 1 else 2 end,
      updated_at desc) refunds;
  else
    destination:='FIELD_WALLET';
    -- Historical wallet movements are settled ledger entries, not card refunds.
    -- Match the ORIGINAL booking identity, including superseded rebookings.
    select coalesce(sum(case when t.currency='USD' then t.amount_fils/10 else t.amount_fils end),0)
    into settled from public.field_wallet_transactions t
    where t.profile_id=owner_to_use and t.currency=currency_to_use and t.direction='CREDIT'
      and (t.booking_id=booking_to_use or (booking_to_use is null and fixture_to_use is not null
        and t.metadata->>'fixture_id'=fixture_to_use));
  end if;
  return jsonb_build_object('refunded_minor',least(settled,paid_minor_to_use),
    'pending_refund_minor',least(pending,greatest(0,paid_minor_to_use-settled)),
    'failed_refund_minor',least(failed,greatest(0,paid_minor_to_use-settled)),
    'refund_needs_review',coalesce(review,false),'refund_destination',destination);
end;
$$;

create function public.list_my_player_payments(
  before_at timestamptz default null,before_id uuid default null,page_size integer default 30
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare viewer uuid:=auth.uid(); item record; rows jsonb:='[]'; n integer:=0; more boolean:=false;
  last_at timestamptz; last_id uuid; result jsonb;
begin
  if viewer is null then raise exception 'Sign in to see your payment history.' using errcode='42501'; end if;
  if page_size is null or page_size not between 1 and 100 or (before_at is null)<>(before_id is null) then
    raise exception 'Choose a valid history page.' using errcode='22023'; end if;
  for item in
    select i.*,coalesce(i.captured_at,i.created_at) paid_at,b.id booking_id,
      coalesce(g.id,f.id) game_id,g.starts_at game_starts_at,
      coalesce(g.timezone,case when f.id is not null then 'Asia/Bahrain' end) timezone,
      coalesce(g.venue,f.venue) venue,coalesce(g.status,f.status)='CANCELLED' game_cancelled
    from public.payment_intents i
    left join public.open_queue_bookings b on b.payment_intent_id=i.id and b.profile_id=viewer
    left join public.open_queue_games g on i.purpose='SOLO_BOOKING' and g.id::text=i.payload->>'game_id'
    left join public.fixtures f on i.purpose in ('CLAN_CREATE','CLAN_JOIN')
      and f.id::text=case when i.resource_type='FIXTURE' then i.resource_id::text else i.payload->>'fixture_id' end
    where i.profile_id=viewer and i.provider in ('STRIPE','LEGACY') and i.amount_minor>0
      and i.status in ('CAPTURED','FINALIZED','REQUIRES_REFUND','REFUNDED')
      and upper(i.provider_status) in ('CAPTURED','SUCCEEDED') and i.provider_payment_id is not null
      and (before_at is null or (coalesce(i.captured_at,i.created_at),i.id)<(before_at,before_id))
    order by coalesce(i.captured_at,i.created_at) desc,i.id desc limit page_size+1
  loop
    n:=n+1; if n>page_size then more:=true; exit; end if;
    result:=jsonb_build_object('id',item.id,'paid_at',item.paid_at,'amount_minor',item.amount_minor,
      'currency',item.currency,'payment_method',coalesce(item.payment_method,'CARD'),'purpose',item.purpose,
      'game_id',item.game_id,'booking_id',item.booking_id,'game_starts_at',item.game_starts_at,
      'timezone',item.timezone,'venue',item.venue,'game_cancelled',coalesce(item.game_cancelled,false))
      ||fieldrush_private.player_history_refunds(item.id,item.booking_id,viewer,item.currency,item.amount_minor);
    rows:=rows||jsonb_build_array(result); last_at:=item.paid_at; last_id:=item.id;
  end loop;
  return jsonb_build_object('items',rows,'next_cursor',case when more then
    jsonb_build_object('created_at',last_at,'id',last_id) else null end);
end;
$$;

create function public.list_my_cancelled_games(
  before_at timestamptz default null,before_id uuid default null,page_size integer default 30
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare viewer uuid:=auth.uid(); item record; rows jsonb:='[]'; n integer:=0; more boolean:=false;
  last_at timestamptz; last_id uuid; result jsonb; paid integer; rating integer; strike integer;
  incident_count integer; rating_count integer; neutral boolean; preserve_rating boolean; hidden_rating boolean;
begin
  if viewer is null then raise exception 'Sign in to see your cancelled games.' using errcode='42501'; end if;
  if page_size is null or page_size not between 1 and 100 or (before_at is null)<>(before_id is null) then
    raise exception 'Choose a valid history page.' using errcode='22023'; end if;
  for item in
    select g.id game_id,g.starts_at,g.ends_at,g.timezone,g.venue,g.cancellation_reason reason,
      coalesce(g.cancelled_at,b.cancelled_at,g.updated_at) cancelled_at,g.actual_started_at,
      g.cancellation_context,g.cancellation_code,b.id booking_id,b.payment_intent_id,
      b.amount_paid_fils,b.payment_method,b.rating_change booking_rating_change,b.role,g.currency,
      a.id attendance_id,a.outcome,a.strike_delta,t.arrival_check_in_opens_at check_in_at
    from public.open_queue_games g
    left join public.match_resolution_revisions revision
      on revision.id::text=g.cancellation_context->>'match_resolution_revision_id'
    join lateral (
      select booking.* from public.open_queue_bookings booking
      left join public.match_attendance_records attendance on attendance.booking_id=booking.id
      where booking.game_id=g.id and booking.profile_id=viewer
        and case when g.cancellation_context->>'source'='ADMIN_MATCH_RESOLUTION' then
          coalesce(revision.consequence_snapshot->'administratively_cancelled_booking_ids','[]'::jsonb) ? booking.id::text
        else booking.status='CONFIRMED' or (booking.status='CANCELLED' and attendance.outcome='FIELD_CANCELLED') end
      order by booking.booked_at desc,booking.id desc limit 1
    ) b on true
    left join public.match_attendance_records a on a.booking_id=b.id
    left join public.match_reliability_terms t on t.open_queue_game_id=g.id and t.match_kind='SOLO'
    where g.status='CANCELLED' and (before_at is null or (g.starts_at,g.id)<(before_at,before_id))
    order by g.starts_at desc,g.id desc limit page_size+1
  loop
    n:=n+1; if n>page_size then more:=true; exit; end if;
    paid:=case when item.currency='USD' then item.amount_paid_fils/10 else item.amount_paid_fils end;
    preserve_rating:=coalesce(item.cancellation_context->>'player_sr_policy','')='PRESERVE_APPLIED_SR';
    neutral:=item.outcome='FIELD_CANCELLED' and coalesce(item.strike_delta,0)=0;
    select count(*),sum(e.rating_change)::integer into rating_count,rating from public.player_rating_events e
      where e.profile_id=viewer and e.source_type='OPEN_QUEUE' and e.source_id=item.game_id;
    if rating_count=0 then
      rating:=item.booking_rating_change;
      if rating is null and not preserve_rating and (neutral or item.actual_started_at is null) then rating:=0; end if;
    end if;
    hidden_rating:=coalesce(rating,0)<>0 and not coalesce(
      (fieldrush_rating_private.public_rating_state(viewer,public.fieldrush_rating_track(item.role))->>'rating_visible')::boolean,false);
    if hidden_rating then rating:=null; end if;
    select count(*),sum(r.strike_delta)::integer into incident_count,strike from public.reliability_incidents r
      where r.subject_type='PLAYER' and r.profile_id=viewer
        and (r.booking_id=item.booking_id or r.attendance_id=item.attendance_id);
    if incident_count=0 then strike:=item.strike_delta; end if;
    if strike is null and item.actual_started_at is null and not preserve_rating then strike:=0; end if;
    result:=jsonb_build_object('game_id',item.game_id,'booking_id',item.booking_id,
      'starts_at',item.starts_at,'ends_at',item.ends_at,'cancelled_at',item.cancelled_at,
      'check_in_at',item.check_in_at,'timezone',item.timezone,'venue',item.venue,'reason',item.reason,
      'amount_paid_minor',paid,'currency',item.currency,'payment_method',coalesce(item.payment_method,'FREE'),
      'rating_change',rating,'rating_hidden',hidden_rating,'strike_change',strike,'streak_kept',case when neutral and coalesce(strike,0)=0
        and coalesce(rating,0)=0 and not hidden_rating and not preserve_rating then true else null end)
      ||fieldrush_private.player_history_refunds(item.payment_intent_id,item.booking_id,viewer,item.currency,paid);
    rows:=rows||jsonb_build_array(result); last_at:=item.starts_at; last_id:=item.game_id;
  end loop;
  return jsonb_build_object('items',rows,'next_cursor',case when more then
    jsonb_build_object('created_at',last_at,'id',last_id) else null end);
end;
$$;

revoke all on function fieldrush_private.player_history_refunds(uuid,uuid,uuid,text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.list_my_player_payments(timestamptz,uuid,integer),
  public.list_my_cancelled_games(timestamptz,uuid,integer) from public,anon;
grant execute on function public.list_my_player_payments(timestamptz,uuid,integer),
  public.list_my_cancelled_games(timestamptz,uuid,integer) to authenticated;
notify pgrst,'reload schema';
