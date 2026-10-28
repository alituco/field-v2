-- Retired-provider test history can contain an expired unpaid lease that the
-- Stripe worker cannot reconcile. Close only provably isolated legacy E2E
-- attempts; never relax the one-game guard or close provider-backed payments.
create function public.expire_staging_e2e_legacy_checkouts(
  actor_admin_id uuid,
  player_ids_to_check uuid[]
)
returns uuid[]
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  player_id uuid;
  attempt public.payment_intents%rowtype;
  after_state jsonb;
  expired_ids uuid[] := '{}'::uuid[];
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the staging test service can close legacy E2E checkouts.' using errcode = '42501';
  end if;
  if not exists (
    select 1 from auth.users u
    join public.profiles p on p.id = u.id
    join public.referee_profiles r on r.profile_id = u.id
    where u.id = actor_admin_id
      and u.raw_app_meta_data @> '{"fieldrush_e2e":true,"fieldrush_e2e_role":"admin"}'::jsonb
      and p.username = 'field_e2e_admin'
      and r.role = 'admin' and r.is_active
  ) then
    raise exception 'A protected active E2E administrator is required.' using errcode = '42501';
  end if;
  if coalesce(cardinality(player_ids_to_check), 0) not between 1 and 15
    or array_position(player_ids_to_check, null) is not null
    or (select count(distinct id) from unnest(player_ids_to_check) id) <> cardinality(player_ids_to_check)
  then
    raise exception 'Provide the nonempty, distinct isolated E2E account pool.' using errcode = '22023';
  end if;
  -- Server-owned Auth markers are authoritative; editable display names and
  -- user metadata are deliberately insufficient. The fresh onboarding actor
  -- may not have a public profile until it completes signup.
  if exists (
    select 1 from unnest(player_ids_to_check) requested(id)
    left join auth.users u on u.id = requested.id
    left join public.profiles p on p.id = requested.id
    where not coalesce(
      u.raw_app_meta_data @> '{"fieldrush_e2e":true}'::jsonb and (
        (u.raw_app_meta_data->>'fieldrush_e2e_role' = 'player'
          and p.username ~ '^field_e2e_(0[1-9]|1[0-4])$')
        or (u.raw_app_meta_data->>'fieldrush_e2e_role' = 'onboarding'
          and (p.id is null or p.username = 'field_e2e_onboarding'
            or p.username = 'e2e_' || left(replace(u.id::text, '-', ''), 12)))
      ), false
    )
  ) then
    raise exception 'Refusing to close checkouts for an unprotected E2E account.' using errcode = '42501';
  end if;

  -- Match checkout/booking serialization. Keep the cancelled game locked too,
  -- so a concurrent reactivation cannot invalidate the cleanup evidence.
  for player_id in select id from unnest(player_ids_to_check) id order by id loop
    perform pg_advisory_xact_lock(hashtext(player_id::text)::bigint);
  end loop;
  for attempt in
    select i.* from public.payment_intents i
    join public.open_queue_games g on i.payload->>'game_id' = g.id::text
    where i.profile_id = any(player_ids_to_check)
      and i.purpose = 'SOLO_BOOKING' and i.provider = 'LEGACY'
      and i.status = 'PENDING' and i.expires_at <= clock_timestamp()
      and i.provider_intent_id is null and i.provider_payment_id is null
      and i.provider_status is null and i.captured_at is null and i.finalized_at is null
      and i.resource_id is null and i.resource_type is null and i.payment_method is null
      and g.status = 'CANCELLED' and g.created_by = actor_admin_id
      and g.venue like '[FIELD E2E %'
      and not exists (select 1 from public.open_queue_bookings b where b.payment_intent_id = i.id)
      and not exists (select 1 from public.fixtures f where f.home_payment_intent_id = i.id or f.away_payment_intent_id = i.id)
      and not exists (select 1 from public.payment_refunds r where r.intent_id = i.id)
    order by i.id for update of i for share of g
  loop
    update public.payment_intents i
    set status = 'EXPIRED',
      failure_reason = 'Expired unpaid retired-provider E2E checkout for a cancelled test game; actor ' || actor_admin_id::text || '.'
    where i.id = attempt.id and i.status = 'PENDING' and i.provider = 'LEGACY'
      and i.provider_intent_id is null and i.provider_payment_id is null
      and i.provider_status is null and i.captured_at is null and i.finalized_at is null
      and i.resource_id is null and i.resource_type is null and i.payment_method is null
      and not exists (select 1 from public.open_queue_bookings b where b.payment_intent_id = i.id)
      and not exists (select 1 from public.fixtures f where f.home_payment_intent_id = i.id or f.away_payment_intent_id = i.id)
      and not exists (select 1 from public.payment_refunds r where r.intent_id = i.id)
    returning to_jsonb(i) into after_state;
    if found then
      insert into public.admin_audit_events (
        actor_referee_id, action, entity_type, entity_id, reason, before_state, after_state
      ) values (
        actor_admin_id, 'E2E_LEGACY_CHECKOUT_EXPIRED', 'ACTION', attempt.id,
        'Close an expired, uncaptured legacy E2E checkout on its cancelled isolated test game.',
        to_jsonb(attempt), after_state
      );
      expired_ids := array_append(expired_ids, attempt.id);
    end if;
  end loop;
  return expired_ids;
end;
$$;
revoke all on function public.expire_staging_e2e_legacy_checkouts(uuid, uuid[]) from public, anon, authenticated;
grant execute on function public.expire_staging_e2e_legacy_checkouts(uuid, uuid[]) to service_role;
comment on function public.expire_staging_e2e_legacy_checkouts(uuid, uuid[]) is
  'Service-only isolated E2E cleanup. Expires unpaid retired-provider leases on cancelled tagged games, preserves payment history, and never changes Stripe/captured/foreign attempts.';
notify pgrst, 'reload schema';
