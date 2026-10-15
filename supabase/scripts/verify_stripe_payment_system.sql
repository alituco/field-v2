-- Runs in a transaction and leaves no users, charges, games or refund records.
-- Provider responses are supplied only through the service-only capture RPC;
-- the real domain booking, capacity, cancellation and refund functions run.
begin;

-- Test real PostgreSQL client roles, not only the JWT claims used by the
-- service-side payment scenarios below. LIMIT 0 still checks column ACLs and
-- avoids depending on existing fixtures or bypassing paused clan checkout.
set local role authenticated;
do $fixture_pricing_acl$
declare
  column_name text;
  rejected boolean;
begin
  if has_table_privilege(current_user,'public.fixtures','SELECT') then
    raise exception 'Authenticated clients have unrestricted fixture SELECT.';
  end if;
  foreach column_name in array array['currency','base_price_fils'] loop
    if not has_column_privilege(current_user,'public.fixtures',column_name,'SELECT') then
      raise exception 'Authenticated clients cannot read public fixture pricing column %.',column_name;
    end if;
  end loop;
  perform currency,base_price_fils from public.fixtures limit 0;

  foreach column_name in array array[
    'home_base_amount_fils','away_base_amount_fils',
    'home_reliability_deposit_fils','away_reliability_deposit_fils',
    'home_amount_paid_fils','away_amount_paid_fils',
    'home_charge_policy_version_id','away_charge_policy_version_id',
    'home_refund_bps','away_refund_bps',
    'home_refund_amount_fils','away_refund_amount_fils',
    'home_deposit_status','away_deposit_status',
    'home_payment_intent_id','away_payment_intent_id',
    'home_provider_payment_id','away_provider_payment_id'
  ] loop
    if has_column_privilege(current_user,'public.fixtures',column_name,'SELECT') then
      raise exception 'Authenticated clients can read private fixture finance column %.',column_name;
    end if;
    rejected:=false;
    begin
      execute format('select %I from public.fixtures limit 0',column_name);
    exception when insufficient_privilege then rejected:=true;
    end;
    if not rejected then
      raise exception 'Authenticated fixture finance query unexpectedly succeeded for %.',column_name;
    end if;
  end loop;

  rejected:=false;
  begin perform * from public.fixtures limit 0;
  exception when insufficient_privilege then rejected:=true;
  end;
  if not rejected then raise exception 'Authenticated clients can select all fixture columns.'; end if;
end;
$fixture_pricing_acl$;
reset role;

set local role anon;
do $anonymous_fixture_pricing_acl$
declare
  column_name text;
  rejected boolean;
begin
  if has_table_privilege(current_user,'public.fixtures','SELECT') then
    raise exception 'Anonymous clients have unrestricted fixture SELECT.';
  end if;
  foreach column_name in array array['currency','base_price_fils'] loop
    if has_column_privilege(current_user,'public.fixtures',column_name,'SELECT') then
      raise exception 'Anonymous clients can read fixture pricing column %.',column_name;
    end if;
    rejected:=false;
    begin
      execute format('select %I from public.fixtures limit 0',column_name);
    exception when insufficient_privilege then rejected:=true;
    end;
    if not rejected then
      raise exception 'Anonymous fixture pricing query unexpectedly succeeded for %.',column_name;
    end if;
  end loop;
end;
$anonymous_fixture_pricing_acl$;
reset role;

do $verify$
declare
  players uuid[]:=array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
  intents uuid[]:=array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
  game uuid:=gen_random_uuid(); free_game uuid:=gen_random_uuid(); overlap_game uuid:=gen_random_uuid(); quote jsonb; result jsonb;
  booking uuid; free_booking uuid; refund uuid; refund2 uuid; item integer; rejected boolean; prior_wallet bigint;
  start_at timestamptz; row_booking public.open_queue_bookings%rowtype; lease jsonb; first_refund uuid; settings jsonb;
begin
  if to_regclass('public.tap_payment_intents') is not null or to_regprocedure('public.finalize_tap_payment_intent(uuid)') is not null then
    raise exception 'Legacy provider APIs remain active.'; end if;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','fieldrush_private') and p.prokind='f' and p.prosrc ~ 'tap_(payment_intents|charge_id|payment_method|status)') then
    raise exception 'An active function still references the retired payment schema.'; end if;
  if has_table_privilege('authenticated','public.payment_intents','INSERT')
    or has_table_privilege('authenticated','public.payment_refunds','INSERT')
    or has_table_privilege('authenticated','public.payment_webhook_events','SELECT')
    or has_function_privilege('authenticated','public.finalize_payment_intent(uuid)','EXECUTE')
    or has_function_privilege('authenticated','public.record_stripe_payment_capture(uuid,text,text,integer,text,text)','EXECUTE')
    or has_function_privilege('authenticated','public.book_open_queue_game(uuid,text,text,text)','EXECUTE')
    or has_function_privilege('authenticated','public.book_open_queue_game_server(uuid,text,text,text)','EXECUTE')
    or has_function_privilege('authenticated','public.admin_set_game_payment_settings(uuid,integer,text,timestamptz)','EXECUTE')
    or has_function_privilege('authenticated','public.record_external_stripe_refund(uuid,text,integer,text,text)','EXECUTE')
    or has_function_privilege('authenticated','public.create_fixture(uuid,text,date,text)','EXECUTE')
    or has_function_privilege('authenticated','public.join_fixture(uuid,uuid)','EXECUTE') then
    raise exception 'A client can bypass payment verification.'; end if;

  for item in 1..array_length(players,1) loop
    insert into auth.users(id,phone,phone_confirmed_at,raw_user_meta_data)
      values(players[item],'1555'||lpad((floor(random()*10000000))::text,7,'0'),now(),jsonb_build_object('display_name','Payment verification'));
    -- Rollback-only payment fixtures model already-onboarded, pre-policy users;
    -- this does not bypass account status, payment, or booking protections.
    delete from fieldrush_rating_private.season_zero_initialization_eligibility where user_id=players[item];
    insert into public.profiles(id,display_name) values(players[item],'Payment verification') on conflict(id) do nothing;
    insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at)
      values(players[item],'active',now()) on conflict(user_id) do update set status='active',onboarding_completed_at=now();
  end loop;
  start_at:=(date_trunc('week',now() at time zone 'America/Phoenix')+interval '30 years 1 day 20 hours 30 minutes');
  -- date_trunc after shifting maintains Tuesday even across leap years.
  start_at:=(date_trunc('week',(now() at time zone 'America/Phoenix')+interval '30 years')+interval '1 day 20 hours 30 minutes') at time zone 'America/Phoenix';
  insert into public.open_queue_games(id,venue,starts_at,ends_at,price_fils,age_label)
    values(game,'Stripe verification',start_at,start_at+interval '1 hour',13000,'18+'),
      (free_game,'Free verification',start_at+interval '7 days',start_at+interval '7 days 1 hour',0,'18+');
  -- Construct a historical off-schedule overlap only for the eligibility test.
  -- No payment, participation, capacity or account protection is bypassed.
  alter table public.open_queue_games disable trigger enforce_open_queue_permanent_schedule;
  insert into public.open_queue_games(id,venue,starts_at,ends_at,price_fils,age_label)
    values(overlap_game,'Overlap verification',start_at+interval '30 minutes',start_at+interval '90 minutes',13000,'18+');
  alter table public.open_queue_games enable trigger enforce_open_queue_permanent_schedule;
  perform set_config('request.jwt.claim.role','service_role',true);
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    select players[5],'Payment admin','+'||phone,'admin',true from auth.users where id=players[5];
  settings:=public.get_game_payment_settings();
  if settings->>'clan_enabled'<>'false' or settings->>'clan_price_fils'<>'80000' or settings->>'currency'<>'USD' then
    raise exception 'Clan checkout is not paused with its USD 80 default.'; end if;
  rejected:=false;
  begin perform public.admin_set_game_payment_settings(players[1],90000,'Update future clan pricing',(settings->>'updated_at')::timestamptz);
    exception when insufficient_privilege then rejected:=true; end;
  if not rejected then raise exception 'A non-admin changed game pricing.'; end if;
  result:=public.admin_set_game_payment_settings(players[5],90000,'Update future clan pricing',(settings->>'updated_at')::timestamptz);
  if result->>'clan_enabled'<>'false' or result->>'clan_price_fils'<>'90000' then raise exception 'Price editing enabled paused clan checkout.'; end if;
  rejected:=false;
  begin perform public.admin_set_game_payment_settings(players[5],80000,'Use stale pricing revision',(settings->>'updated_at')::timestamptz);
    exception when serialization_failure then rejected:=true; end;
  if not rejected then raise exception 'A stale game pricing update was accepted.'; end if;
  perform public.admin_set_game_payment_settings(players[5],80000,'Restore configured clan price',(result->>'updated_at')::timestamptz);
  for item in 1..4 loop
    rejected:=false;
    begin
      case item
        when 1 then perform public.preview_create_clan_fixture_charge(gen_random_uuid(),current_date,'20:30');
        when 2 then perform public.preview_join_clan_fixture_charge(gen_random_uuid(),gen_random_uuid());
        when 3 then perform public.create_fixture(gen_random_uuid(),'Paused checkout',current_date,'20:30');
        when 4 then perform public.join_fixture(gen_random_uuid(),gen_random_uuid());
      end case;
    exception when raise_exception then rejected:=position('currently paused' in sqlerrm)>0; end;
    if not rejected then raise exception 'Clan entry point % was not paused server-side.',item; end if;
  end loop;
  perform set_config('request.jwt.claim.sub',players[3]::text,true);
  update fieldrush_private.accounts set status='onboarding' where user_id=players[3];
  rejected:=false;
  begin perform public.preview_open_queue_booking_cost(game,'DEF'); exception when raise_exception then rejected:=position('account setup' in sqlerrm)>0; end;
  if not rejected then raise exception 'An incomplete account could begin paid checkout.'; end if;
  update fieldrush_private.accounts set status='active' where user_id=players[3];

  for item in 1..3 loop
    perform set_config('request.jwt.claim.sub',players[item]::text,true);
    quote:=public.preview_open_queue_booking_cost(game,'GK');
    if quote->>'currency'<>'USD' or (quote->>'total_fils')::integer<>13000
      or quote->>'reliability_deposit_return_destination'<>'ORIGINAL_PAYMENT_METHOD' then raise exception 'Server quote did not preserve USD 13 and original-method refunds.'; end if;
    insert into public.payment_intents(id,profile_id,purpose,currency,amount_fils,payload,quote_snapshot,transaction_reference,provider_intent_id)
      values(intents[item],players[item],'SOLO_BOOKING','USD',13000,jsonb_build_object('game_id',game,'role','GK'),quote,
        'verify_'||intents[item],'pi_verify_'||intents[item]);
  end loop;
  -- Checkout leases span different days, not just the same game's unique key.
  -- Provider confirmation, not elapsed time alone, is required to release one.
  perform set_config('request.jwt.claim.sub',players[1]::text,true);
  rejected:=false;
  begin perform public.preview_open_queue_booking_cost(free_game,'DEF');
    exception when raise_exception then rejected:=position('earlier game checkout' in sqlerrm)>0; end;
  if not rejected then raise exception 'A pending checkout allowed a second game preflight.'; end if;
  rejected:=false;
  begin
    insert into public.payment_intents(profile_id,purpose,currency,amount_fils,payload,quote_snapshot,transaction_reference)
    values(players[1],'SOLO_BOOKING','USD',13000,jsonb_build_object('game_id',free_game,'role','DEF'),quote,'verify_second_lease_'||gen_random_uuid());
  exception when raise_exception then rejected:=position('earlier game checkout' in sqlerrm)>0; end;
  if not rejected then raise exception 'A stale quote created a second game checkout lease.'; end if;
  rejected:=false;
  begin
    insert into public.payment_intents(profile_id,purpose,currency,amount_fils,payload,quote_snapshot,transaction_reference)
    values(players[1],'SOLO_BOOKING','USD',13000,jsonb_build_object('game_id',game,'role','DEF'),quote,'verify_same_lease_'||gen_random_uuid());
  exception when unique_violation then rejected:=true; end;
  if not rejected then raise exception 'A same-game checkout retry created a second lease.'; end if;
  update public.payment_intents set expires_at=clock_timestamp()-interval '1 minute' where id=intents[1];
  rejected:=false;
  begin perform public.preview_open_queue_booking_cost(free_game,'DEF');
    exception when raise_exception then rejected:=position('earlier game checkout' in sqlerrm)>0; end;
  if not rejected then raise exception 'Elapsed expiry silently released an unconfirmed provider checkout.'; end if;
  update public.payment_intents set expires_at=clock_timestamp()+interval '20 minutes' where id=intents[1];
  rejected:=false;
  begin update public.payment_intents set amount_fils=14000 where id=intents[1]; exception when invalid_parameter_value then rejected:=true; end;
  if not rejected then raise exception 'A payment quote could be changed.'; end if;
  rejected:=false;
  begin perform public.record_stripe_payment_capture(intents[1],'pi_verify_'||intents[1],'ch_verify_'||intents[1],1299,'USD','VISA');
    exception when invalid_parameter_value then rejected:=true; end;
  if not rejected then raise exception 'A mismatched provider amount was accepted.'; end if;
  perform set_config('request.jwt.claim.role','authenticated',true); rejected:=false;
  begin perform public.record_stripe_payment_capture(intents[1],'pi_verify_'||intents[1],'ch_verify_'||intents[1],1300,'USD','VISA');
    exception when insufficient_privilege then rejected:=true; end;
  if not rejected then raise exception 'A client could assert a successful provider payment.'; end if;
  perform set_config('request.jwt.claim.role','service_role',true);

  result:=public.record_stripe_payment_capture(intents[1],'pi_verify_'||intents[1],'ch_verify_'||intents[1],1300,'usd','VISA');
  if result->>'status'<>'FINALIZED' then raise exception 'Verified payment did not finalize: %',result; end if;
  booking:=(result->>'resource_id')::uuid;
  perform set_config('request.jwt.claim.sub',players[1]::text,true);
  rejected:=false;
  begin perform public.preview_open_queue_booking_cost(game,'DEF'); exception when raise_exception then rejected:=position('already booked' in sqlerrm)>0; end;
  if not rejected then raise exception 'A duplicate booking could begin paid checkout.'; end if;
  rejected:=false;
  begin perform public.preview_open_queue_booking_cost(overlap_game,'DEF'); exception when raise_exception then rejected:=position('another game at this time' in sqlerrm)>0; end;
  if not rejected then raise exception 'An overlapping booking could begin paid checkout.'; end if;
  rejected:=false;
  begin perform public.preview_open_queue_booking_cost(free_game,'DEF');
    exception when raise_exception then rejected:=position('one upcoming or active game' in sqlerrm)>0; end;
  if not rejected then raise exception 'A non-overlapping second game could begin checkout.'; end if;
  if (public.record_stripe_payment_capture(intents[1],'pi_verify_'||intents[1],'ch_verify_'||intents[1],1300,'USD','VISA')->>'resource_id')::uuid<>booking
    or (select count(*) from public.open_queue_bookings where payment_intent_id=intents[1])<>1 then
    raise exception 'Repeated capture created a duplicate booking.'; end if;
  result:=public.record_stripe_payment_capture(intents[2],'pi_verify_'||intents[2],'ch_verify_'||intents[2],1300,'USD','APPLE_PAY');
  if result->>'status'<>'FINALIZED' then raise exception 'Second goalkeeper failed.'; end if;
  result:=public.record_stripe_payment_capture(intents[3],'pi_verify_'||intents[3],'ch_verify_'||intents[3],1300,'USD','CARD');
  if result->>'status'<>'REQUIRES_REFUND' or (select count(*) from public.open_queue_bookings where game_id=game and status='CONFIRMED')<>2 then
    raise exception 'Capacity loss was not converted into a durable full refund: %',result; end if;
  if not exists(select 1 from public.payment_refunds where intent_id=intents[3] and amount_minor=1300 and status='PENDING') then
    raise exception 'Failed booking payment has no full refund task.'; end if;

  -- Real player cancellation uses the policy's amount, with external status.
  perform set_config('request.jwt.claim.sub',players[1]::text,true);
  select coalesce(balance_fils,0) into prior_wallet from public.field_wallet_usd_accounts where profile_id=players[1];
  row_booking:=public.cancel_open_queue_booking(booking);
  if row_booking.refund_destination<>'ORIGINAL_PAYMENT_METHOD' or row_booking.refund_status<>'PROCESSING' then
    raise exception 'Cancellation did not expose the original-method pending refund.'; end if;
  if coalesce((select balance_fils from public.field_wallet_usd_accounts where profile_id=players[1]),0)<>coalesce(prior_wallet,0) then
    raise exception 'A Stripe cancellation credited a wallet.'; end if;
  select id into refund from public.payment_refunds where intent_id=intents[1];
  rejected:=false;
  begin perform fieldrush_private.assert_deletion_ready(players[1]); exception when invalid_parameter_value then rejected:=true; end;
  if not rejected then raise exception 'An account with a pending external refund could be deleted.'; end if;
  rejected:=false;
  begin perform public.finish_payment_refund(refund,'re_verify_'||refund,'succeeded',1200,'USD'); exception when invalid_parameter_value then rejected:=true; end;
  if not rejected then raise exception 'An incorrect refund amount was accepted.'; end if;
  perform public.finish_payment_refund(refund,'re_verify_'||refund,'succeeded',1300,'USD');
  perform public.finish_payment_refund(refund,'re_verify_'||refund,'succeeded',1300,'USD');
  if (select status from public.payment_intents where id=intents[1])<>'REFUNDED'
    or (select refund_status from public.open_queue_bookings where id=booking)<>'PROCESSED' then
    raise exception 'Confirmed full refund did not update the payment and booking.'; end if;

  -- Partial policy amounts carry sub-cent remainders across installments.
  first_refund:=public.request_payment_refund(intents[2],5,'verify-carry-a:'||intents[2],'Partial refund');
  refund:=public.request_payment_refund(intents[2],5,'verify-carry-b:'||intents[2],'Partial refund');
  refund2:=public.request_payment_refund(intents[2],12990,'verify-carry-c:'||intents[2],'Remaining refund');
  if (select amount_minor from public.payment_refunds where id=first_refund)<>0
    or (select status from public.payment_refunds where id=first_refund)<>'SUCCEEDED'
    or (select amount_minor from public.payment_refunds where id=refund)<>1
    or (select amount_minor from public.payment_refunds where id=refund2)<>1299 then
    raise exception 'Refund rounding lost or created currency.'; end if;
  if public.request_payment_refund(intents[2],5,'verify-carry-b:'||intents[2],'Retry')<>refund then raise exception 'Refund retry was not idempotent.'; end if;
  rejected:=false; begin perform public.request_payment_refund(intents[2],1,'verify-overflow:'||intents[2],'Excess refund'); exception when raise_exception then rejected:=true; end;
  if not rejected then raise exception 'Cumulative refunds exceeded captured amount.'; end if;
  perform public.finish_payment_refund(refund,'re_verify_'||refund,'succeeded',1,'USD');
  if (select status from public.payment_intents where id=intents[2])<>'FINALIZED' then raise exception 'A partial refund incorrectly closed the payment.'; end if;
  perform public.finish_payment_refund(refund2,'re_verify_'||refund2,'succeeded',1299,'USD');

  -- Closed checkout captures can never create a late booking.
  perform set_config('request.jwt.claim.sub',players[4]::text,true);
  quote:=public.preview_open_queue_booking_cost(game,'DEF');
  insert into public.payment_intents(id,profile_id,purpose,currency,amount_fils,payload,quote_snapshot,transaction_reference,provider_intent_id,status)
    values(intents[4],players[4],'SOLO_BOOKING','USD',13000,jsonb_build_object('game_id',game,'role','DEF'),quote,
      'verify_'||intents[4],'pi_verify_'||intents[4],'CANCELLED');
  result:=public.record_stripe_payment_capture(intents[4],'pi_verify_'||intents[4],'ch_verify_'||intents[4],1300,'USD','CARD');
  if result->>'status'<>'REQUIRES_REFUND' or exists(select 1 from public.open_queue_bookings where payment_intent_id=intents[4]) then
    raise exception 'A closed checkout produced a booking.'; end if;

  result:=public.finalize_free_checkout(players[5],'SOLO_BOOKING',jsonb_build_object('game_id',free_game,'role','DEF'));
  if result->>'status'<>'FINALIZED' or result->>'payment_method'<>'FREE' then raise exception 'Free booking required a provider charge.'; end if;
  free_booking:=(result->>'resource_id')::uuid;
  rejected:=false;
  begin perform public.finalize_free_checkout(players[5],'SOLO_BOOKING',jsonb_build_object('game_id',game,'role','DEF'));
    exception when raise_exception then rejected:=position('one upcoming or active game' in sqlerrm)>0; end;
  if not rejected then raise exception 'Free checkout bypassed the one-game limit.'; end if;
  if (public.finalize_free_checkout(players[5],'SOLO_BOOKING',jsonb_build_object('game_id',free_game,'role','DEF'))->>'resource_id')::uuid<>free_booking then
    raise exception 'Free checkout retry was not idempotent under the one-game limit.'; end if;
  -- Release the sole commitment before the independent synthetic paid case.
  perform set_config('request.jwt.claim.sub',players[5]::text,true);
  row_booking:=public.cancel_open_queue_booking(free_booking);
  if row_booking.status<>'CANCELLED' then raise exception 'Free booking cancellation did not release the player.'; end if;
  rejected:=false;
  begin perform public.finalize_free_checkout(players[5],'SOLO_BOOKING',jsonb_build_object('game_id',game,'role','DEF'));
    exception when raise_exception then rejected:=position('requires payment' in sqlerrm)>0; end;
  if not rejected then raise exception 'Free checkout bypassed a paid game.'; end if;

  -- Hosted staging's synthetic provider uses the SAME domain finalization and
  -- cancellation RPCs, without contacting a real payment processor.
  perform set_config('request.jwt.claim.sub',players[5]::text,true);
  quote:=public.preview_open_queue_booking_cost(game,'DEF');
  insert into public.payment_intents(id,profile_id,purpose,provider,currency,amount_fils,payload,quote_snapshot,
    transaction_reference,provider_intent_id,provider_payment_id,payment_method,provider_status,status)
    values(intents[5],players[5],'SOLO_BOOKING','STAGING_E2E','USD',13000,jsonb_build_object('game_id',game,'role','DEF'),quote,
      'verify_'||intents[5],'field_e2e_intent_'||replace(intents[5]::text,'-',''),
      'field_e2e_'||replace(intents[5]::text,'-',''),'CARD','SUCCEEDED','CAPTURED');
  result:=public.finalize_payment_intent(intents[5]);
  if result->>'status'<>'FINALIZED' then raise exception 'Synthetic staging capture failed: %',result; end if;
  row_booking:=public.cancel_open_queue_booking((result->>'resource_id')::uuid);
  if row_booking.refund_status<>'PROCESSED' or row_booking.refund_destination<>'ORIGINAL_PAYMENT_METHOD'
    or not exists(select 1 from public.payment_refunds where intent_id=intents[5] and status='SUCCEEDED') then
    raise exception 'Synthetic staging cancellation did not exercise original-method refunds.'; end if;

  -- Explicit provider failure requires an audited admin retry. Old in-flight
  -- responses cannot mutate a later retry generation.
  select id into refund from public.payment_refunds where intent_id=intents[3];
  perform public.finish_payment_refund(refund,'re_failed_'||refund,'failed',1300,'USD','Provider rejected refund',0);
  result:=public.admin_retry_payment_refund(players[5],refund,'Retry after resolving Stripe balance');
  if result->>'retry_generation'<>'1' or result->>'status'<>'PENDING' or result->>'provider_refund_id' is not null then
    raise exception 'Admin retry failed to create a safe new attempt.'; end if;
  result:=public.finish_payment_refund(refund,'re_failed_'||refund,'succeeded',1300,'USD',null,0);
  if result->>'stale'<>'true' or (select status from public.payment_refunds where id=refund)<>'PENDING' then
    raise exception 'A stale refund response changed the current attempt.'; end if;
  perform public.record_external_stripe_refund(intents[3],'re_external_'||intents[3],100,'USD','succeeded');
  if (select status from public.payment_refunds where id=refund)<>'FAILED' then
    raise exception 'An existing unissued refund was not held for external review.'; end if;

  -- Dashboard refunds are recorded separately; they must stop another outgoing
  -- refund while keeping the customer's booking and immutable quote intact.
  perform set_config('request.jwt.claim.sub',players[4]::text,true);
  insert into public.payment_intents(id,profile_id,purpose,currency,amount_fils,payload,quote_snapshot,transaction_reference,provider_intent_id)
    values(intents[6],players[4],'SOLO_BOOKING','USD',13000,jsonb_build_object('game_id',game,'role','DEF'),quote,
      'verify_'||intents[6],'pi_verify_'||intents[6]);
  result:=public.record_stripe_payment_capture(intents[6],'pi_verify_'||intents[6],'ch_verify_'||intents[6],1300,'USD','CARD');
  if result->>'status'<>'FINALIZED' then raise exception 'External refund fixture did not finalize.'; end if;
  booking:=(result->>'resource_id')::uuid;
  result:=public.record_external_stripe_refund(intents[6],'re_external_'||intents[6],100,'USD','succeeded');
  perform public.record_external_stripe_refund(intents[6],'re_external_'||intents[6],100,'USD','succeeded');
  if result->>'external_refund_review_required'<>'true' or (select status from public.open_queue_bookings where id=booking)<>'CONFIRMED'
    or (select count(*) from public.external_payment_refunds where intent_id=intents[6])<>1 then
    raise exception 'External refunds were not preserved and blocked for review.'; end if;
  if exists(select 1 from public.claim_payment_refunds(20,intents[6])) then raise exception 'External review payment was claimed for another refund.'; end if;
  row_booking:=public.cancel_open_queue_booking(booking);
  if row_booking.status<>'CANCELLED' or row_booking.refund_status<>'FAILED'
    or not exists(select 1 from public.payment_refunds where intent_id=intents[6] and amount_minor=1300
      and status='FAILED' and provider_status='external_refund_review') then
    raise exception 'External review blocked cancellation or lost the refund entitlement.'; end if;

  lease:=public.claim_payment_webhook('evt_verify_'||game,'payment_intent.succeeded','pi_verify_'||intents[1]);
  if lease->>'claimed'<>'true' then raise exception 'First webhook claim failed.'; end if;
  lease:=public.claim_payment_webhook('evt_verify_'||game,'payment_intent.succeeded','pi_verify_'||intents[1]);
  if lease->>'claimed'<>'false' then raise exception 'Concurrent webhook delivery acquired the same lease.'; end if;
  update public.payment_webhook_events set status='PROCESSED',processed_at=now(),locked_until=null where event_id='evt_verify_'||game;
  lease:=public.claim_payment_webhook('evt_verify_'||game,'payment_intent.succeeded','pi_verify_'||intents[1]);
  if lease->>'claimed'<>'false' or lease->>'status'<>'PROCESSED' then raise exception 'Processed webhook was replayed.'; end if;
  raise notice 'Stripe SQL verified: fixture pricing column ACLs, permissions, paused clans, admin pricing, immutable USD quotes, one-game preflight and checkout leases, idempotency, capacity, cancellation, refund rounding, retry generations, external-refund review, account deletion guard, staging E2E, free checkout and webhook lease.';
end;
$verify$;
rollback;
