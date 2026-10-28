-- Local operator maintenance only: never deploy this as a migration or RPC.
-- The companion CLI validates the actual database host/user against Field Staging.
-- All guards, the ordinary finalizer and result verification share one transaction.
do $reconcile$
declare
  run_to_use text := current_setting('field.reconcile_run_id', true);
  intent_to_use uuid := nullif(current_setting('field.reconcile_intent_id', true), '')::uuid;
  player_to_use uuid := nullif(current_setting('field.reconcile_player_id', true), '')::uuid;
  game_to_use uuid := nullif(current_setting('field.reconcile_game_id', true), '')::uuid;
  creator_to_use uuid := nullif(current_setting('field.reconcile_creator_id', true), '')::uuid;
  player public.profiles%rowtype;
  player_auth auth.users%rowtype;
  creator public.referee_profiles%rowtype;
  creator_auth auth.users%rowtype;
  game public.open_queue_games%rowtype;
  attempt public.payment_intents%rowtype;
  refund public.payment_refunds%rowtype;
  metadata jsonb;
  compact_intent text;
  result jsonb;
begin
  if current_setting('field.reconcile_project_ref', true) is distinct from 'nfdkdhdevpstfspazbfn'
    or run_to_use is null or run_to_use !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    or intent_to_use is null or player_to_use is null or game_to_use is null or creator_to_use is null
    or current_setting('field.reconcile_confirmation', true)
      is distinct from 'RECONCILE_STAGING_E2E:' || run_to_use || ':' || intent_to_use::text then
    raise exception 'Exact staging target, run, checkout, player, game, creator and confirmation are required.';
  end if;

  -- Follow the finalizer's account lock; NOWAIT makes concurrent ownership
  -- changes a safe failure, never permission to act on a partially read fixture.
  perform 1 from fieldrush_private.accounts where user_id=player_to_use for share nowait;
  if not found then raise exception 'The synthetic player account is missing.'; end if;
  select * into player from public.profiles where id=player_to_use for share nowait;
  select * into player_auth from auth.users where id=player_to_use for share nowait;
  if player.id is null or player_auth.id is null
    or coalesce(player.auth_user_id,player.id) is distinct from player_auth.id
    or player.display_name is null or player.display_name not like '[E2E]%'
    or player.username is null or left(player.username,10)<>'field_e2e_'
    or player_auth.raw_app_meta_data->>'fieldrush_e2e' is distinct from 'true'
    or player_auth.raw_app_meta_data->>'fieldrush_e2e_role' is distinct from 'player'
    or player_auth.raw_app_meta_data->>'fieldrush_account_type'='staff' then
    raise exception 'The checkout owner is not a protected synthetic player.';
  end if;
  metadata:=player_auth.raw_app_meta_data;
  if ((metadata->>'fieldrush_e2e_run_id'=run_to_use
      and metadata->>'fieldrush_e2e_revoked_run_id' is null)
    or (metadata->>'fieldrush_e2e_run_id' is null
      and metadata->>'fieldrush_e2e_revoked_run_id'=run_to_use)) is not true then
    raise exception 'The synthetic player belongs to a different or unverified run.';
  end if;

  -- Retired synthetic staff may prove historical fixture ownership. This does
  -- not reactivate staff or claim that the creator initiated maintenance.
  select * into creator from public.referee_profiles where profile_id=creator_to_use for share nowait;
  select * into creator_auth from auth.users where id=creator.auth_user_id for share nowait;
  if creator.profile_id is null or creator_auth.id is null
    or creator.auth_user_id=creator.profile_id or creator.auth_user_id=player_to_use
    or creator.role is distinct from 'admin'
    or creator.display_name is null or creator.display_name not like '[E2E]%'
    or creator.email is distinct from 'field_e2e_staff@fieldrush-e2e.example'
    or creator_auth.email is distinct from creator.email
    or creator_auth.email_confirmed_at is null or nullif(creator_auth.phone,'') is not null
    or creator_auth.raw_app_meta_data->>'fieldrush_e2e' is distinct from 'true'
    or creator_auth.raw_app_meta_data->>'fieldrush_e2e_role' is distinct from 'admin'
    or creator_auth.raw_app_meta_data->>'fieldrush_account_type' is distinct from 'staff'
    or exists(select 1 from public.profiles where id=creator.auth_user_id or auth_user_id=creator.auth_user_id)
    or exists(select 1 from fieldrush_private.accounts where user_id=creator.auth_user_id)
    or exists(select 1 from auth.identities where user_id=creator.auth_user_id and provider<>'email') then
    raise exception 'The fixture creator is not the independent protected synthetic administrator.';
  end if;
  metadata:=creator_auth.raw_app_meta_data;
  if ((metadata->>'fieldrush_e2e_run_id'=run_to_use
      and metadata->>'fieldrush_e2e_revoked_run_id' is null)
    or (metadata->>'fieldrush_e2e_run_id' is null
      and metadata->>'fieldrush_e2e_revoked_run_id'=run_to_use)) is not true then
    raise exception 'The synthetic creator belongs to a different or unverified run.';
  end if;
  if not pg_try_advisory_xact_lock(hashtext(player_to_use::text)::bigint) then
    raise exception 'The synthetic player has a concurrent booking operation.';
  end if;
  select * into game from public.open_queue_games where id=game_to_use for update nowait;
  if game.id is null or game.status is distinct from 'CANCELLED'
    or game.venue is distinct from '[FIELD E2E ' || left(run_to_use,28) || '] Match'
    or game.created_by_staff_id is distinct from creator_to_use then
    raise exception 'Only the exact cancelled match owned by this E2E run can be reconciled.';
  end if;
  select * into attempt from public.payment_intents where id=intent_to_use for update nowait;
  compact_intent:=replace(intent_to_use::text,'-','');
  if attempt.id is null or attempt.profile_id is distinct from player_to_use
    or attempt.provider is distinct from 'STAGING_E2E' or attempt.purpose is distinct from 'SOLO_BOOKING'
    or attempt.status not in ('CAPTURED','REFUNDED')
    or attempt.provider_status is distinct from 'SUCCEEDED' or attempt.payment_method is distinct from 'CARD'
    or attempt.transaction_reference is distinct from 'field_e2e_' || run_to_use || '_' || compact_intent
    or attempt.provider_intent_id is distinct from 'field_e2e_intent_' || compact_intent
    or attempt.provider_payment_id is distinct from 'field_e2e_' || compact_intent
    or attempt.payload->>'game_id' is distinct from game_to_use::text
    or coalesce(attempt.payload->>'role','') not in ('GK','DEF','ATT')
    or attempt.payload is distinct from jsonb_build_object('game_id',game_to_use::text,'role',attempt.payload->>'role')
    or attempt.amount_fils<=0 or attempt.amount_fils%10<>0 or attempt.currency is distinct from 'USD'
    or attempt.amount_minor is distinct from attempt.amount_fils/10
    or attempt.quote_snapshot->>'currency' is distinct from attempt.currency
    or attempt.quote_snapshot->>'total_fils' is distinct from attempt.amount_fils::text
    or attempt.captured_at is null or attempt.finalized_at is not null
    or attempt.resource_id is not null or attempt.resource_type is not null
    or exists(select 1 from public.open_queue_bookings where payment_intent_id=attempt.id
      or (game_id=game_to_use and profile_id=player_to_use))
    or exists(select 1 from public.fixtures where home_payment_intent_id=attempt.id or away_payment_intent_id=attempt.id) then
    raise exception 'The exact unlinked captured synthetic checkout and its original quote could not be verified.';
  end if;

  if attempt.status='CAPTURED' then
    if attempt.failure_reason is not null or exists(select 1 from public.payment_refunds where intent_id=attempt.id) then
      raise exception 'A captured synthetic checkout with prior reconciliation evidence requires separate review.';
    end if;
    perform set_config('request.jwt.claim.role','service_role',true);
    result:=public.finalize_payment_intent(attempt.id);
    if result->>'intent_id' is distinct from attempt.id::text
      or coalesce(result->>'status','') not in ('REQUIRES_REFUND','REFUNDED') then
      raise exception 'The ordinary finalizer did not return the expected cancelled-fixture refund outcome.';
    end if;
  end if;

  select * into attempt from public.payment_intents where id=intent_to_use;
  select * into refund from public.payment_refunds where intent_id=intent_to_use;
  if attempt.status is distinct from 'REFUNDED' or attempt.failure_reason is null
    or attempt.resource_id is not null or attempt.resource_type is not null
    or (select count(*) from public.payment_refunds where intent_id=intent_to_use)<>1
    or refund.id is null or refund.status is distinct from 'SUCCEEDED'
    or refund.provider_status is distinct from 'staging_e2e' or refund.provider_refund_id is not null
    or refund.idempotency_key is distinct from 'finalize-failed:' || intent_to_use::text
    or refund.recipient_profile_id is distinct from player_to_use
    or refund.provider_intent_id is distinct from attempt.provider_intent_id
    or refund.amount_fils is distinct from attempt.amount_fils or refund.amount_minor is distinct from attempt.amount_minor
    or refund.currency is distinct from attempt.currency
    or refund.reason is distinct from 'The payment succeeded but its booking could not be completed.'
    or refund.metadata->>'failure_reason' is distinct from attempt.failure_reason
    or exists(select 1 from public.open_queue_bookings where payment_intent_id=attempt.id) then
    raise exception 'Full terminal synthetic refund verification failed; maintenance must roll back.';
  end if;
  -- The durable normal-finalizer refund is the audit evidence. Do not insert an
  -- admin action falsely attributed to the retired fixture creator.
  raise notice 'Verified synthetic reconciliation: run %, intent %, refund %, database operator %.',
    run_to_use,intent_to_use,refund.id,session_user;
end;
$reconcile$;
