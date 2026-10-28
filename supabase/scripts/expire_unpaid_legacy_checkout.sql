-- One-record operator repair, not a migration or a player-accessible RPC.
-- Run in a transaction after setting these transaction-local inputs:
-- field.repair_intent_id, field.repair_profile_id, field.repair_game_id,
-- field.repair_admin_id, field.repair_reason.
-- Never supply credentials, card details or account contact data in the reason.
do $repair$
declare
  intent_id_to_use uuid := nullif(current_setting('field.repair_intent_id', true), '')::uuid;
  profile_id_to_use uuid := nullif(current_setting('field.repair_profile_id', true), '')::uuid;
  game_id_to_use uuid := nullif(current_setting('field.repair_game_id', true), '')::uuid;
  admin_id_to_use uuid := nullif(current_setting('field.repair_admin_id', true), '')::uuid;
  reason_to_use text := nullif(trim(current_setting('field.repair_reason', true)), '');
  game_status text;
  attempt public.payment_intents%rowtype;
  after_state jsonb;
begin
  if intent_id_to_use is null or profile_id_to_use is null
    or game_id_to_use is null or admin_id_to_use is null
    or reason_to_use is null or char_length(reason_to_use) not between 10 and 1000 then
    raise exception 'An exact checkout, owner, game, active admin and repair reason are required.';
  end if;

  perform 1 from public.referee_profiles
    where profile_id = admin_id_to_use and role = 'admin' and is_active
    for share nowait;
  if not found then
    raise exception 'The repair must be attributed to an active administrator.';
  end if;

  -- Serialize with the one-game guard. NOWAIT fails safely if a concurrent
  -- game reactivation or payment operation already owns the relevant row.
  perform pg_advisory_xact_lock(hashtext(profile_id_to_use::text)::bigint);
  select status into game_status from public.open_queue_games
    where id = game_id_to_use for share nowait;
  if game_status is distinct from 'CANCELLED' then
    raise exception 'Only a checkout for the exact cancelled game can be repaired.';
  end if;
  select * into attempt from public.payment_intents
    where id = intent_id_to_use for update nowait;
  if attempt.id is null
    or attempt.profile_id is distinct from profile_id_to_use
    or attempt.payload->>'game_id' is distinct from game_id_to_use::text
    or attempt.purpose is distinct from 'SOLO_BOOKING'
    or attempt.provider is distinct from 'LEGACY' then
    raise exception 'The checkout does not match the requested unpaid legacy solo attempt.';
  end if;

  -- A provider identifier/status, even an empty string, is evidence that
  -- requires separate reconciliation. Expiry alone never releases Stripe.
  if attempt.expires_at is null or attempt.expires_at > clock_timestamp()
    or attempt.provider_intent_id is not null or attempt.provider_payment_id is not null
    or attempt.provider_status is not null or attempt.payment_method is not null
    or attempt.captured_at is not null or attempt.finalized_at is not null
    or attempt.resource_id is not null or attempt.resource_type is not null
    or exists (select 1 from public.open_queue_bookings where payment_intent_id = attempt.id)
    or exists (select 1 from public.fixtures where home_payment_intent_id = attempt.id or away_payment_intent_id = attempt.id)
    or exists (select 1 from public.payment_refunds where intent_id = attempt.id) then
    raise exception 'This checkout is not an expired, unlinked attempt without payment evidence.';
  end if;

  if attempt.status = 'EXPIRED' and exists (
    select 1 from public.admin_audit_events a
    where a.action = 'UNPAID_LEGACY_CHECKOUT_EXPIRED' and a.entity_type = 'ACTION'
      and a.entity_id = attempt.id and a.actor_referee_id = admin_id_to_use
      and a.reason = reason_to_use
      and a.after_state->>'status' = 'EXPIRED'
      and a.after_state->>'profile_id' = profile_id_to_use::text
      and a.after_state #>> '{payload,game_id}' = game_id_to_use::text
  ) then
    return;
  end if;
  if attempt.status is distinct from 'PENDING' then
    raise exception 'Only an unpaid pending checkout can be expired.';
  end if;

  update public.payment_intents i
    set status = 'EXPIRED',
      failure_reason = 'Expired unpaid retired-provider checkout for a cancelled game. ' || reason_to_use
    where i.id = attempt.id
    returning to_jsonb(i) into after_state;
  insert into public.admin_audit_events (
    actor_referee_id, action, entity_type, entity_id, reason, before_state, after_state
  ) values (
    admin_id_to_use, 'UNPAID_LEGACY_CHECKOUT_EXPIRED', 'ACTION', attempt.id,
    reason_to_use, to_jsonb(attempt), after_state
  );
end;
$repair$;
