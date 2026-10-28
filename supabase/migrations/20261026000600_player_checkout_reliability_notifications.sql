-- Player receipts follow committed payment and disciplinary decisions. A bank
-- authorization is not a charge, and a requested refund is not a paid refund.
create table fieldrush_private.checkout_notification_acknowledgements (
  payment_id uuid not null references public.payment_intents(id) on delete cascade,
  outcome text not null check(outcome in ('CONFIRMED','REFUND_PENDING','REFUNDED','AUTH_RELEASED')),
  acknowledged_at timestamptz not null default clock_timestamp(),
  primary key(payment_id,outcome)
);
alter table fieldrush_private.checkout_notification_acknowledgements enable row level security;
revoke all on fieldrush_private.checkout_notification_acknowledgements from public,anon,authenticated,service_role;

create function fieldrush_private.player_checkout_notification_state(payment_to_use uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare i public.payment_intents%rowtype; b public.open_queue_bookings%rowtype;
  g public.open_queue_games%rowtype; refunds jsonb; outcome text; filled boolean;
begin
  select * into i from public.payment_intents where id=payment_to_use and purpose='SOLO_BOOKING' and provider='STRIPE';
  if i.id is null then return null; end if;
  select * into g from public.open_queue_games where id::text=i.payload->>'game_id';
  if g.id is null then return null; end if;
  select * into b from public.open_queue_bookings where payment_intent_id=i.id and profile_id=i.profile_id;
  if i.status='FINALIZED' and i.resource_type='OPEN_QUEUE_BOOKING' and i.resource_id=b.id
    and b.status='CONFIRMED' and g.status in ('OPEN','FULL','LIVE')
    and i.provider_status='SUCCEEDED' and i.provider_payment_id is not null then outcome:='CONFIRMED';
  elsif b.id is null and i.resource_id is null and i.status in ('REQUIRES_REFUND','REFUNDED')
    and i.provider_status='SUCCEEDED' and i.provider_payment_id is not null and i.captured_at is not null then
    refunds:=fieldrush_private.player_history_refunds(i.id,null,i.profile_id,i.currency,i.amount_minor);
    outcome:=case when (refunds->>'refunded_minor')::bigint>=i.amount_minor then 'REFUNDED' else 'REFUND_PENDING' end;
  elsif b.id is null and i.resource_id is null and i.capture_method='manual'
    and i.status in ('CANCELLED','EXPIRED','FAILED') and i.provider_status='canceled'
    and i.provider_payment_id is null and i.captured_at is null
    and exists(select 1 from fieldrush_private.stripe_booking_reservations h where h.intent_id=i.id
      and h.status='RELEASED' and nullif(trim(h.failure_reason),'') is not null) then outcome:='AUTH_RELEASED';
  end if;
  if outcome is null then return null; end if;
  filled:=coalesce(i.failure_reason ~* '(just filled|spot filled|position.*full|game.*full|capacity)',false);
  return jsonb_build_object('outcome',outcome,'profile_id',i.profile_id,'game_id',g.id,
    'booking_id',b.id,'payment_id',i.id,'spot_filled',filled,
    'refund_needs_review',coalesce((refunds->>'refund_needs_review')::boolean,false)
      or coalesce((refunds->>'failed_refund_minor')::bigint,0)>0);
end $$;

create function fieldrush_private.emit_player_checkout_notification(payment_to_use uuid)
returns void language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare state jsonb:=fieldrush_private.player_checkout_notification_state(payment_to_use);
  outcome text:=state->>'outcome'; recipient uuid:=(state->>'profile_id')::uuid;
  kind text:='PLAYER_CHECKOUT_'||outcome; notice uuid; made boolean; headline text; message text;
begin
  if state is null then return; end if;
  -- Superseded pending/refunded/confirmed notices remain an Activity receipt,
  -- but they cannot be delivered as the current checkout outcome.
  update public.notifications set resolved_at=clock_timestamp()
    where recipient_profile_id=recipient and data->>'payment_id'=payment_to_use::text
      and type like 'PLAYER_CHECKOUT_%' and type<>kind and resolved_at is null;
  headline:=case outcome when 'CONFIRMED' then 'You’re in'
    when 'REFUNDED' then case when (state->>'spot_filled')::boolean then 'That spot filled. You’ve been fully refunded.' else 'Your booking couldn’t be completed. You’ve been fully refunded.' end
    when 'REFUND_PENDING' then 'Your booking couldn’t be completed'
    else 'Your payment authorization was released' end;
  message:=case outcome when 'CONFIRMED' then 'Your spot is confirmed. Open your game for your arrival time and team.'
    when 'REFUNDED' then 'Your full refund has been processed to your original payment method. Your bank may take time to show it.'
    when 'REFUND_PENDING' then 'This checkout did not secure a spot. '||case when (state->>'refund_needs_review')::boolean
      then 'Your refund needs review. Open payment history for its current status.'
      else 'Your full refund is being processed. Open payment history for its status.' end
    else 'This checkout did not secure a spot. You were not charged; your bank may take time to remove the temporary hold.' end;
  insert into fieldrush_private.notification_event_receipts(recipient_id,notification_type,event_key)
    values(recipient,kind,'checkout:'||payment_to_use||':'||outcome)
    on conflict do nothing returning true into made;
  if made is distinct from true then
    -- Reconciliation can move an uncompleted refund into manual review. Keep
    -- the one receipt accurate without creating an alert for every retry.
    if outcome='REFUND_PENDING' then
      update public.notifications set title=headline,body=message,data=data||(state-'profile_id')
        where recipient_profile_id=recipient and type=kind and data->>'payment_id'=payment_to_use::text;
    end if;
    return;
  end if;
  insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id,data,read_at)
    values(recipient,kind,headline,message,case when outcome='CONFIRMED' then 'OPEN_QUEUE_GAME' else 'PLAYER_PAYMENT' end,
      case when outcome='CONFIRMED' then (state->>'game_id')::uuid else payment_to_use end,
      (state-'profile_id')||jsonb_build_object('player_push_v1',true,'expires_at',clock_timestamp()+interval '24 hours'),
      (select acknowledged_at from fieldrush_private.checkout_notification_acknowledgements a where a.payment_id=payment_to_use and a.outcome=state->>'outcome'))
    returning id into notice;
  update fieldrush_private.notification_event_receipts set notification_id=notice
    where recipient_id=recipient and notification_type=kind and event_key='checkout:'||payment_to_use||':'||outcome;
  -- Let the foreground confirmation acknowledge the result before phone push.
  update fieldrush_private.push_deliveries set next_attempt_at=greatest(next_attempt_at,clock_timestamp()+interval '20 seconds') where notification_id=notice;
end $$;

create function fieldrush_private.notify_player_checkout_transition()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare payment uuid; outcome text;
begin
  if tg_table_name='payment_intents' then
    -- Audit text/timestamps and retry bookkeeping are not new financial events.
    -- In particular, they must not manufacture pre-rollout refund receipts.
    if (old.status,old.provider_status,old.provider_payment_id,old.resource_type,old.resource_id,
        old.captured_at is not null)
      is not distinct from
      (new.status,new.provider_status,new.provider_payment_id,new.resource_type,new.resource_id,
        new.captured_at is not null) then return new; end if;
    payment:=new.id;
    outcome:=fieldrush_private.player_checkout_notification_state(payment)->>'outcome';
    -- A later metadata edit or refund on a pre-rollout booking is not a new
    -- checkout confirmation. The authoritative finalized transition is required.
    if outcome='CONFIRMED' and not (old.status is distinct from 'FINALIZED' and new.status='FINALIZED') then return new; end if;
  else
    if tg_op='UPDATE' then
      if tg_table_name='payment_refunds' then
        if (old.status,old.provider_status,old.provider_refund_id,old.amount_minor,old.currency)
          is not distinct from (new.status,new.provider_status,new.provider_refund_id,new.amount_minor,new.currency) then return new; end if;
      else
        if (old.provider_status,old.provider_refund_id,old.amount_minor,old.currency)
          is not distinct from (new.provider_status,new.provider_refund_id,new.amount_minor,new.currency) then return new; end if;
      end if;
    end if;
    payment:=new.intent_id;
    outcome:=fieldrush_private.player_checkout_notification_state(payment)->>'outcome';
    if outcome not in ('REFUND_PENDING','REFUNDED') then return new; end if;
  end if;
  perform fieldrush_private.emit_player_checkout_notification(payment);
  return new;
end $$;
create constraint trigger notify_player_checkout_transition after update on public.payment_intents
  deferrable initially deferred for each row execute function fieldrush_private.notify_player_checkout_transition();
create constraint trigger notify_player_checkout_transition after insert or update on public.payment_refunds
  deferrable initially deferred for each row execute function fieldrush_private.notify_player_checkout_transition();
create constraint trigger notify_player_checkout_transition after insert or update on public.external_payment_refunds
  deferrable initially deferred for each row execute function fieldrush_private.notify_player_checkout_transition();

create function public.acknowledge_my_checkout_notification(payment_id_to_use uuid,outcome_to_use text)
returns void language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare state jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.payment_intents where id=payment_id_to_use and profile_id=auth.uid()) then
    raise exception 'Payment receipt is unavailable.' using errcode='42501'; end if;
  if outcome_to_use is null or outcome_to_use not in ('CONFIRMED','REFUND_PENDING','REFUNDED','AUTH_RELEASED') then
    raise exception 'Choose a valid checkout outcome.' using errcode='22023'; end if;
  state:=fieldrush_private.player_checkout_notification_state(payment_id_to_use);
  if state->>'outcome' is distinct from outcome_to_use then return; end if;
  insert into fieldrush_private.checkout_notification_acknowledgements(payment_id,outcome)
    values(payment_id_to_use,outcome_to_use) on conflict do nothing;
  update public.notifications set read_at=coalesce(read_at,clock_timestamp())
    where recipient_profile_id=auth.uid() and type='PLAYER_CHECKOUT_'||outcome_to_use
      and data->>'payment_id'=payment_id_to_use::text;
end $$;
revoke all on function public.acknowledge_my_checkout_notification(uuid,text) from public,anon;
grant execute on function public.acknowledge_my_checkout_notification(uuid,text) to authenticated;

create function fieldrush_private.player_checkout_notification_source_is_current(notification_to_use uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  select coalesce((select n.type='PLAYER_CHECKOUT_'||(s.state->>'outcome')
    and n.recipient_profile_id::text=s.state->>'profile_id'
    and n.data->>'game_id'=s.state->>'game_id'
    and n.data->>'booking_id' is not distinct from s.state->>'booking_id'
    and (n.type<>'PLAYER_CHECKOUT_REFUND_PENDING' or n.data->>'refund_needs_review'=s.state->>'refund_needs_review')
    from public.notifications n join public.payment_intents i on i.id::text=n.data->>'payment_id'
    cross join lateral (select fieldrush_private.player_checkout_notification_state(i.id) state) s
    where n.id=notification_to_use),false);
$$;

-- Existing discipline writers keep their authoritative incident/appeal records.
-- Normalize their receipts after the entire transaction: an incident and the
-- sanction it causes become one alert, rather than two competing phone pushes.
create function fieldrush_private.coalesce_player_discipline_notification()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare n public.notifications%rowtype; incident public.reliability_incidents%rowtype;
  attendance public.match_attendance_records%rowtype; appeal public.reliability_appeals%rowtype;
  survivor uuid; severity text; restriction_end timestamptz; restricted boolean; message text;
begin
  select * into n from public.notifications where id=new.id;
  if n.type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION') then
    if n.related_entity_type='MATCH_ATTENDANCE' then
      select * into incident from public.reliability_incidents where attendance_id=n.related_entity_id and subject_type='PLAYER' and reversal_of is null;
    elsif n.related_entity_type='RELIABILITY_SANCTION' then
      select i.* into incident from public.reliability_incidents i join public.reliability_sanctions s on s.incident_id=i.id where s.id=n.related_entity_id;
    end if;
    if incident.id is null or incident.profile_id is distinct from n.recipient_profile_id or incident.strike_delta<=0 then return new; end if;
    select * into attendance from public.match_attendance_records where id=incident.attendance_id and match_kind='SOLO';
    if attendance.id is null or attendance.finalized_at is null then return new; end if;
    select notice.id into survivor from public.notifications notice
      where notice.recipient_profile_id=incident.profile_id and notice.type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION')
        and (notice.related_entity_type='MATCH_ATTENDANCE' and notice.related_entity_id=incident.attendance_id
          or notice.related_entity_type='RELIABILITY_SANCTION' and exists(select 1 from public.reliability_sanctions s where s.id=notice.related_entity_id and s.incident_id=incident.id))
      order by case notice.type when 'RELIABILITY_OUTCOME' then 0 else 1 end,notice.created_at,notice.id limit 1;
    select s.sanction_kind,s.ends_at into severity,restriction_end from public.reliability_sanctions s
      where s.incident_id=incident.id and s.revoked_at is null and s.starts_at<=clock_timestamp() and (s.ends_at is null or s.ends_at>clock_timestamp())
      order by case s.sanction_kind when 'INDEFINITE_SUSPENSION' then 0 when 'PARTICIPATION_SUSPENSION' then 1 when 'BOOKING_RESTRICTION' then 2 else 3 end limit 1;
    message:=format('%s %s added. You now have %s active %s.',incident.strike_delta,
      case when incident.strike_delta=1 then 'strike was' else 'strikes were' end,
      public.active_reliability_strikes(incident.profile_id,clock_timestamp()),
      case when public.active_reliability_strikes(incident.profile_id,clock_timestamp())=1 then 'strike' else 'strikes' end)
      ||case severity when 'BOOKING_RESTRICTION' then ' New bookings are temporarily restricted.'
        when 'PARTICIPATION_SUSPENSION' then ' Participation is temporarily suspended.'
        when 'INDEFINITE_SUSPENSION' then ' Your account requires a reliability review.' else '' end
      ||' Open reliability history for the decision and appeal deadline.';
    update public.notifications set title=case incident.outcome when 'LATE' then 'Late arrival recorded' when 'NO_SHOW' then 'No-show recorded' else 'Attendance decision recorded' end,
      body=left(message,300),data=data||jsonb_build_object('player_push_v1',true,'incident_id',incident.id,'attendance_id',attendance.id,
        'game_id',attendance.open_queue_game_id,'booking_id',attendance.booking_id,'active_strikes',public.active_reliability_strikes(incident.profile_id,clock_timestamp()),
        'sanction_kind',severity,'restriction_ends_at',restriction_end,'appeal_due_at',attendance.appeal_due_at,
        'expires_at',clock_timestamp()+interval '7 days') where id=survivor;
    update public.notifications notice set resolved_at=coalesce(notice.resolved_at,clock_timestamp()),data=notice.data||jsonb_build_object('coalesced_into',survivor)
      where notice.id<>survivor and notice.recipient_profile_id=incident.profile_id and notice.type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION')
        and (notice.related_entity_type='MATCH_ATTENDANCE' and notice.related_entity_id=incident.attendance_id
          or notice.related_entity_type='RELIABILITY_SANCTION' and exists(select 1 from public.reliability_sanctions s where s.id=notice.related_entity_id and s.incident_id=incident.id));
  elsif n.type='RELIABILITY_APPEAL_DECIDED' then
    select * into appeal from public.reliability_appeals where id=n.related_entity_id and appellant_profile_id=n.recipient_profile_id and status in ('UPHELD','OVERTURNED');
    if appeal.id is null then return new; end if;
    select * into attendance from public.match_attendance_records where id=appeal.attendance_id and match_kind='SOLO';
    if attendance.id is null then return new; end if;
    restricted:=public.profile_has_active_play_restriction(n.recipient_profile_id) or public.profile_has_active_reliability_booking_restriction(n.recipient_profile_id);
    update public.notifications set body=case appeal.status when 'UPHELD' then 'The attendance decision remains in place. Open reliability history for the review outcome.'
        else 'Your appeal was approved and your attendance record was corrected.'||case
          when not restricted and exists(select 1 from public.reliability_sanctions s where s.incident_id=appeal.incident_id
            and s.sanction_kind<>'WARNING' and s.revoked_at=appeal.reviewed_at) then ' You can book games again.'
          when restricted then ' Another restriction remains active. Open reliability history for details.' else '' end end,
      data=data||jsonb_build_object('player_push_v1',true,'appeal_id',appeal.id,'status',appeal.status,
        'attendance_id',attendance.id,'game_id',attendance.open_queue_game_id,'can_book',not restricted,'expires_at',clock_timestamp()+interval '7 days') where id=n.id;
  end if;
  return new;
end $$;
create constraint trigger coalesce_player_discipline_notification after insert on public.notifications
  deferrable initially deferred for each row execute function fieldrush_private.coalesce_player_discipline_notification();

-- Observe restriction transitions (including time-only expiry) without replaying
-- past disciplinary history when this migration is installed.
create table fieldrush_private.player_restriction_notification_state (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  restricted boolean not null,
  fingerprint text not null,
  route_hint text not null default 'reliability' check(route_hint in ('reliability','account')),
  revision bigint not null default 0,
  observed_at timestamptz not null,
  next_check_at timestamptz
);
alter table fieldrush_private.player_restriction_notification_state enable row level security;
revoke all on fieldrush_private.player_restriction_notification_state from public,anon,authenticated,service_role;
create index player_restriction_notification_due on fieldrush_private.player_restriction_notification_state(next_check_at) where next_check_at is not null;

create function fieldrush_private.player_restriction_notification_snapshot(profile_to_use uuid,at_time timestamptz)
returns jsonb language sql stable security definer set search_path=pg_catalog,public,pg_temp as $$
  with restrictions as (
    select s.id,s.starts_at,s.ends_at,s.sanction_kind kind,'reliability'::text source from public.reliability_sanctions s
      where s.subject_type='PLAYER' and s.profile_id=profile_to_use and s.revoked_at is null
        and s.sanction_kind in ('BOOKING_RESTRICTION','PARTICIPATION_SUSPENSION','INDEFINITE_SUSPENSION')
    union all
    select a.id,a.starts_at,a.ends_at,a.action_type||':'||a.restriction_scope,'account' from public.moderation_actions a
      where a.subject_type='PLAYER' and a.subject_profile_id=profile_to_use and a.revoked_at is null
        and a.action_type in ('SUSPENSION','BAN') and a.restriction_scope in ('PLAY','ACCOUNT')
  ), active as (select * from restrictions where starts_at<=at_time and (ends_at is null or ends_at>at_time))
  select jsonb_build_object('restricted',exists(select 1 from active),'fingerprint',coalesce((select md5(string_agg(id::text||':'||kind||':'||coalesce(extract(epoch from ends_at)::text,''),',' order by id)) from active),''),
    'route_hint',case when exists(select 1 from active where source='account') then 'account' else 'reliability' end,
    'next_check_at',(select min(boundary) from (select starts_at boundary from restrictions where starts_at>at_time union all select ends_at from restrictions where ends_at>at_time) upcoming));
$$;
insert into fieldrush_private.player_restriction_notification_state(profile_id,restricted,fingerprint,route_hint,observed_at,next_check_at)
select p.profile_id,(s.state->>'restricted')::boolean,s.state->>'fingerprint',s.state->>'route_hint',clock_timestamp(),(s.state->>'next_check_at')::timestamptz
from (select profile_id from public.reliability_sanctions where subject_type='PLAYER'
  union select subject_profile_id from public.moderation_actions where subject_type='PLAYER') p
cross join lateral(select fieldrush_private.player_restriction_notification_snapshot(p.profile_id,clock_timestamp()) state) s;

create function fieldrush_private.observe_player_restriction_notification(profile_to_use uuid,at_time timestamptz default clock_timestamp())
returns boolean language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare prior fieldrush_private.player_restriction_notification_state%rowtype;
  state jsonb; is_restricted boolean; changed boolean; next_revision bigint; kind text; receipt uuid; existing uuid;
begin
  insert into fieldrush_private.player_restriction_notification_state(profile_id,restricted,fingerprint,observed_at)
    values(profile_to_use,false,'',at_time) on conflict do nothing;
  select * into prior from fieldrush_private.player_restriction_notification_state where profile_id=profile_to_use for update;
  state:=fieldrush_private.player_restriction_notification_snapshot(profile_to_use,at_time);
  is_restricted:=(state->>'restricted')::boolean; changed:=prior.fingerprint is distinct from state->>'fingerprint';
  next_revision:=prior.revision+case when changed then 1 else 0 end;
  update fieldrush_private.player_restriction_notification_state set restricted=is_restricted,fingerprint=state->>'fingerprint',
    route_hint=case when is_restricted then state->>'route_hint' else prior.route_hint end,
    revision=next_revision,observed_at=at_time,next_check_at=(state->>'next_check_at')::timestamptz where profile_id=profile_to_use;
  if not changed or not prior.restricted and not is_restricted then return false; end if;
  -- A just-recorded incident/appeal explains this exact transition already.
  select n.id into existing from public.notifications n where n.recipient_profile_id=profile_to_use
    and n.created_at>=transaction_timestamp() and n.resolved_at is null
    and (is_restricted and n.type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION')
      or not is_restricted and n.type='RELIABILITY_APPEAL_DECIDED')
    order by case n.type when 'RELIABILITY_OUTCOME' then 0 else 1 end,n.created_at desc limit 1;
  if existing is not null then
    update public.notifications set data=data||jsonb_build_object('restriction_revision',next_revision,'can_book',not is_restricted) where id=existing;
    return false;
  end if;
  kind:=case when is_restricted then 'PLAYER_ACCOUNT_RESTRICTED' else 'PLAYER_RESTRICTION_LIFTED' end;
  insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id,data)
    values(profile_to_use,kind,case when is_restricted then 'Your playing access has changed' else 'You can book games again' end,
      left(case when is_restricted then coalesce((select a.user_message from public.moderation_actions a where a.subject_profile_id=profile_to_use
        and a.action_type in ('SUSPENSION','BAN') and a.restriction_scope in ('PLAY','ACCOUNT') and a.revoked_at is null
        and a.starts_at<=at_time and (a.ends_at is null or a.ends_at>at_time) order by a.starts_at desc,a.id limit 1),
        'A restriction is now active on your account. Open reliability history to review the decision.')
        else 'Your booking restrictions have ended. You can choose another game.' end,300),
      'PLAYER_ACCOUNT',profile_to_use,jsonb_build_object('player_push_v1',true,'route_hint',case when is_restricted then state->>'route_hint' else prior.route_hint end,
        'restriction_revision',next_revision,'expires_at',at_time+interval '7 days')) returning id into receipt;
  return receipt is not null;
end $$;

create function fieldrush_private.notify_player_restriction_transition()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
begin
  if new.subject_type<>'PLAYER' then return new; end if;
  if tg_table_name='reliability_sanctions' then perform fieldrush_private.observe_player_restriction_notification(new.profile_id);
  else perform fieldrush_private.observe_player_restriction_notification(new.subject_profile_id); end if;
  return new;
end $$;
create constraint trigger notify_player_restriction_transition after insert or update on public.reliability_sanctions
  deferrable initially deferred for each row execute function fieldrush_private.notify_player_restriction_transition();
create constraint trigger notify_player_restriction_transition after insert or update on public.moderation_actions
  deferrable initially deferred for each row execute function fieldrush_private.notify_player_restriction_transition();

create function fieldrush_private.process_player_restriction_notifications()
returns integer language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare p record; sent integer:=0;
begin
  for p in select profile_id from fieldrush_private.player_restriction_notification_state
    where next_check_at<=clock_timestamp() order by next_check_at,profile_id limit 200 for update skip locked
  loop if fieldrush_private.observe_player_restriction_notification(p.profile_id) then sent:=sent+1; end if; end loop;
  return sent;
end $$;

create function fieldrush_private.player_discipline_notification_source_is_current(notification_to_use uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  select coalesce((select case
    when n.type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION') then exists(select 1 from public.reliability_incidents i
      join public.match_attendance_records a on a.id=i.attendance_id and a.match_kind='SOLO' and a.finalized_at is not null
      where i.id::text=n.data->>'incident_id' and i.profile_id=n.recipient_profile_id and i.strike_delta>0
        and not exists(select 1 from public.reliability_incidents reversal where reversal.reversal_of=i.id)
        and (i.expires_at is null or i.expires_at>clock_timestamp()))
    when n.type='RELIABILITY_APPEAL_DECIDED' then exists(select 1 from public.reliability_appeals a
      where a.id=n.related_entity_id and a.appellant_profile_id=n.recipient_profile_id and a.status=n.data->>'status')
    when n.type in ('PLAYER_ACCOUNT_RESTRICTED','PLAYER_RESTRICTION_LIFTED') then exists(select 1 from fieldrush_private.player_restriction_notification_state s
      where s.profile_id=n.recipient_profile_id and s.revision::text=n.data->>'restriction_revision'
        and (fieldrush_private.player_restriction_notification_snapshot(s.profile_id,clock_timestamp())->>'restricted')::boolean=(n.type='PLAYER_ACCOUNT_RESTRICTED'))
    else false end from public.notifications n where n.id=notification_to_use),false);
$$;

revoke all on function fieldrush_private.player_checkout_notification_state(uuid),
  fieldrush_private.emit_player_checkout_notification(uuid),fieldrush_private.notify_player_checkout_transition(),
  fieldrush_private.player_checkout_notification_source_is_current(uuid),fieldrush_private.coalesce_player_discipline_notification(),
  fieldrush_private.player_restriction_notification_snapshot(uuid,timestamptz),
  fieldrush_private.observe_player_restriction_notification(uuid,timestamptz),fieldrush_private.notify_player_restriction_transition(),
  fieldrush_private.process_player_restriction_notifications(),fieldrush_private.player_discipline_notification_source_is_current(uuid)
  from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
