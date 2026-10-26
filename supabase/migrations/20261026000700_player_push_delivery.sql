-- Resolve taps and render approved phone previews from recipient-owned,
-- authoritative receipts. This migration does not activate provider delivery.
alter function fieldrush_private.notification_source_is_current(uuid)
  rename to notification_source_before_player_push;
revoke all on function fieldrush_private.notification_source_before_player_push(uuid)
  from public,anon,authenticated,service_role;

create function fieldrush_private.notification_source_is_current(notification_id_to_use uuid)
returns boolean language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare n public.notifications%rowtype;
begin
  select * into n from public.notifications where id=notification_id_to_use;
  if not found then return false; end if;
  if n.type='OPEN_QUEUE_PARTY_INVITE' or (n.data->>'player_push_v1'='true' and n.type in (
    'SOLO_TEAM_READY','SOLO_TEAM_CHANGED','SOLO_GAME_CHANGED','SOLO_GAME_CANCELLED',
    'SOLO_BOOKING_REMOVED','SOLO_MATCH_REVIEW','SOLO_MATCH_CORRECTED','GAME_REMINDER')) then
    return fieldrush_private.player_game_notification_source_is_current(n.id);
  elsif n.data->>'player_push_v1'='true' and n.type in (
    'PLAYER_CHECKOUT_CONFIRMED','PLAYER_CHECKOUT_REFUND_PENDING','PLAYER_CHECKOUT_REFUNDED',
    'PLAYER_CHECKOUT_AUTH_RELEASED') then
    return fieldrush_private.player_checkout_notification_source_is_current(n.id);
  elsif n.data->>'player_push_v1'='true' and n.type in (
    'RELIABILITY_OUTCOME','RELIABILITY_SANCTION','RELIABILITY_APPEAL_DECIDED',
    'PLAYER_RESTRICTION_LIFTED','PLAYER_ACCOUNT_RESTRICTED') then
    return fieldrush_private.player_discipline_notification_source_is_current(n.id);
  end if;
  return fieldrush_private.notification_source_before_player_push(n.id);
end;
$$;
revoke all on function fieldrush_private.notification_source_is_current(uuid)
  from public,anon,authenticated,service_role;

create function fieldrush_private.player_push_preview(notification_id_to_use uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare n public.notifications%rowtype; preview_title text; preview_body text;
begin
  select * into n from public.notifications where id=notification_id_to_use;
  if not found then return null; end if;
  if n.type='OPEN_QUEUE_PARTY_INVITE' then
    preview_title:='You have a party invite';
    preview_body:='Open Fieldrush to respond before parties lock.';
  elsif n.data->>'player_push_v1' is distinct from 'true' then
    return null;
  elsif n.type in ('GAME_REMINDER','SOLO_TEAM_READY','SOLO_TEAM_CHANGED','SOLO_GAME_CHANGED') then
    -- These event writers contain only the saved public game schedule and team,
    -- never player names, admin reasons, payment amounts or disciplinary notes.
    preview_title:=n.title; preview_body:=n.body;
  elsif n.type in ('PLAYER_CHECKOUT_CONFIRMED','PLAYER_CHECKOUT_REFUND_PENDING',
    'PLAYER_CHECKOUT_REFUNDED','PLAYER_CHECKOUT_AUTH_RELEASED') then
    -- Checkout writers use fixed outcome copy and no private payment details.
    preview_title:=n.title; preview_body:=n.body;
  elsif n.type='SOLO_GAME_CANCELLED' then
    preview_title:='Your game was cancelled';
    preview_body:='Open Fieldrush for your game and refund details.';
  elsif n.type='SOLO_BOOKING_REMOVED' then
    preview_title:='Your booking has changed';
    preview_body:='Open Fieldrush to review your booking and any refund.';
  elsif n.type='SOLO_MATCH_REVIEW' then
    preview_title:='Your game is under review';
    preview_body:='The result is pending. Open Fieldrush for the latest update.';
  elsif n.type='SOLO_MATCH_CORRECTED' then
    preview_title:='Your game result was updated';
    preview_body:='Open Fieldrush to see the decision and any rating changes.';
  elsif n.type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION','PLAYER_ACCOUNT_RESTRICTED') then
    preview_title:='Your account has an update';
    preview_body:='Open Fieldrush to review the decision and your options.';
  elsif n.type='RELIABILITY_APPEAL_DECIDED' then
    preview_title:='Your appeal has been reviewed';
    preview_body:='Open Fieldrush to see the decision.';
  elsif n.type='PLAYER_RESTRICTION_LIFTED' then
    preview_title:='Your booking restriction has ended';
    preview_body:='Open Fieldrush to view your current eligibility.';
  else return null;
  end if;
  return jsonb_build_object('preview_version',1,'notification_type',n.type,
    'title',left(regexp_replace(preview_title,'[[:cntrl:]]',' ','g'),120),
    'body',left(regexp_replace(preview_body,'[[:cntrl:]]',' ','g'),300));
end;
$$;
revoke all on function fieldrush_private.player_push_preview(uuid)
  from public,anon,authenticated,service_role;

create function fieldrush_private.player_push_recipient_is_eligible(recipient uuid,event_type text)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,auth,fieldrush_private,pg_temp as $$
  select public.is_fieldrush_account_active(recipient) or (
    event_type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION','RELIABILITY_APPEAL_DECIDED',
      'PLAYER_RESTRICTION_LIFTED','PLAYER_ACCOUNT_RESTRICTED')
    and exists(select 1 from fieldrush_private.accounts a join auth.users u on u.id=a.user_id
      where a.user_id=recipient and a.status='active' and a.onboarding_completed_at is not null
        and u.deleted_at is null and ((u.phone_confirmed_at is not null and nullif(u.phone,'') is not null)
          or (u.email_confirmed_at is not null and nullif(u.email,'') is not null))))
$$;
revoke all on function fieldrush_private.player_push_recipient_is_eligible(uuid,text)
  from public,anon,authenticated,service_role;

create or replace function fieldrush_private.push_priority_for_type(notification_type text)
returns smallint language sql immutable set search_path=pg_catalog as $$
  select case when notification_type='NEWS_AND_OFFERS' then 2
    when notification_type in ('CLAN_CALLUP','LADDER_MOVE','REPLAY_READY') then 1
    -- Invitations have an actual party-lock deadline, just like arrival alerts.
    else 0 end::smallint;
$$;
revoke all on function fieldrush_private.push_priority_for_type(text)
  from public,anon,authenticated,service_role;
update fieldrush_private.push_deliveries d set priority=0 from public.notifications n
  where n.id=d.notification_id and n.type='OPEN_QUEUE_PARTY_INVITE' and d.status='PENDING';

-- Within the urgent lane, a near check-in/party deadline takes precedence over
-- older notices that can safely wait. Retain bounded claims and fair lanes.
do $$
declare definition text; reserved_order text:='order by d.next_attempt_at,d.id limit band.slots';
  fill_order text:='order by d.priority,d.next_attempt_at,d.id';
begin
  definition:=pg_get_functiondef('public.claim_push_deliveries(integer,uuid)'::regprocedure);
  if position(reserved_order in definition)=0 or position(fill_order in definition)=0 then
    raise exception 'Push claim ordering changed; review deadline ordering.';
  end if;
  definition:=replace(definition,reserved_order,
    'order by case when d.priority=0 then d.expires_at end,d.next_attempt_at,d.id limit band.slots');
  definition:=replace(definition,fill_order,
    'order by d.priority,case when d.priority=0 then d.expires_at end,d.next_attempt_at,d.id');
  execute definition;
end;
$$;

create or replace function public.get_push_delivery_payload(delivery_id_to_use uuid,claim_id_to_use uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,auth,fieldrush_private,pg_temp as $$
declare delivery fieldrush_private.push_deliveries%rowtype; result jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the push worker can read delivery payloads.' using errcode='42501'; end if;
  select * into delivery from fieldrush_private.push_deliveries where id=delivery_id_to_use
    and status='PROCESSING' and claim_id=claim_id_to_use and locked_until>clock_timestamp() for update;
  if not found then return null; end if;
  select jsonb_build_object('delivery_id',delivery.id,'notification_id',n.id,'token',d.registration_token,
    'firebase_project_id',d.firebase_project_id,'platform',d.platform,
    'expires_at',fieldrush_private.push_source_deadline(n.data,delivery.expires_at))||preview.value into result
  from public.notifications n join fieldrush_private.push_devices d on d.installation_id=delivery.installation_id
  join fieldrush_private.push_configuration c on c.singleton and c.enabled and c.firebase_project_id=d.firebase_project_id
  cross join lateral (select fieldrush_private.player_push_preview(n.id) value) preview
  where n.id=delivery.notification_id and n.recipient_profile_id=delivery.recipient_id
    and d.user_id=delivery.recipient_id and d.active and d.binding_version=delivery.binding_version
    and fieldrush_private.push_source_deadline(n.data,delivery.expires_at)>clock_timestamp() and delivery.attempts<=8
    and n.dismissed_at is null and n.resolved_at is null and n.read_at is null
    and preview.value is not null
    and fieldrush_private.player_push_recipient_is_eligible(delivery.recipient_id,n.type)
    and fieldrush_private.notification_source_is_current(n.id)
    and fieldrush_private.notification_preference_allows(n.recipient_profile_id,n.type);
  if result is null then update fieldrush_private.push_deliveries set status='SKIPPED',locked_until=null,
    error_code='NOT_ELIGIBLE',updated_at=clock_timestamp() where id=delivery.id; end if;
  return result;
end;
$$;
revoke all on function public.get_push_delivery_payload(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_push_delivery_payload(uuid,uuid) to service_role;

create function public.get_my_player_notification(notification_id_to_use uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,auth,fieldrush_private,pg_temp as $$
declare result jsonb;
begin
  if auth.uid() is null then raise exception 'You need to sign in again.' using errcode='42501'; end if;
  select jsonb_build_object('id',n.id,'type',n.type,'title',n.title,'body',n.body,
    'created_at',n.created_at,'read_at',n.read_at,'related_entity_type',n.related_entity_type,
    'related_entity_id',n.related_entity_id,'data',n.data) into result
  from public.notifications n where n.id=notification_id_to_use and n.recipient_profile_id=auth.uid()
    and n.dismissed_at is null and n.resolved_at is null
    and fieldrush_private.notification_source_is_current(n.id)
    and fieldrush_private.notification_preference_allows(n.recipient_profile_id,n.type);
  return result;
end;
$$;
revoke all on function public.get_my_player_notification(uuid) from public,anon;
grant execute on function public.get_my_player_notification(uuid) to authenticated;

alter function fieldrush_private.process_notification_events()
  rename to process_notification_events_before_player_restrictions;
revoke all on function fieldrush_private.process_notification_events_before_player_restrictions()
  from public,anon,authenticated,service_role;
create function fieldrush_private.process_notification_events()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare result jsonb; changed integer;
begin
  result:=fieldrush_private.process_notification_events_before_player_restrictions();
  if result->>'skipped'='true' then return result; end if;
  changed:=fieldrush_private.process_player_restriction_notifications();
  return result||jsonb_build_object('player_restrictions',changed);
end;
$$;
revoke all on function fieldrush_private.process_notification_events()
  from public,anon,authenticated,service_role;

notify pgrst,'reload schema';
