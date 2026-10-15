-- Disposable full-schema database only; caller wraps this in BEGIN / ROLLBACK.
create temporary table wallet_deletion_checks(label text);
create function pg_temp.wallet_expect(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Wallet deletion: %',label; end if;
  insert into wallet_deletion_checks values(label);
end;
$$;
create function pg_temp.wallet_reject(statement text,code text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement;
  exception when others then if sqlstate<>code then raise; end if; rejected:=true; end;
  perform pg_temp.wallet_expect(rejected,'reject '||code||': '||statement);
end;
$$;
create sequence pg_temp.wallet_person;
create function pg_temp.wallet_player(phone_to_use text default null) returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.wallet_person');
begin
  insert into auth.users(id,phone,phone_confirmed_at)
    values(player,coalesce(phone_to_use,'1555777'||lpad(n::text,4,'0')),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',player,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','otp','timestamp',extract(epoch from now())::bigint)))::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Wallet','last_name','Test',
    'username','wallet_check_'||n,'date_of_birth','2000-01-01','email','wallet'||n||'@example.test',
    'skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  return player;
end;
$$;

create function pg_temp.wallet_fail_final_delete() returns trigger language plpgsql as $$
begin
  if nullif(current_setting('wallet.test_delete_failure',true),'')=old.id::text then
    raise exception 'Injected final Auth deletion failure.';
  end if;
  return old;
end;
$$;
create trigger zz_wallet_test_final_failure before delete on auth.users
  for each row execute function pg_temp.wallet_fail_final_delete();

do $$
declare player uuid:=pg_temp.wallet_player(); replacement uuid; big_player uuid; retry_player uuid;
  intent uuid; game uuid; refund uuid; result jsonb; before_credit_count integer;
begin
  perform pg_temp.wallet_expect(not has_function_privilege('authenticated',
    'fieldrush_private.forfeit_deleted_account_wallets(uuid)','execute'),'no client wallet-debit helper');
  perform pg_temp.wallet_expect(not has_function_privilege('service_role',
    'fieldrush_private.forfeit_deleted_account_wallets(uuid)','execute'),'no service RPC wallet-debit helper');
  perform pg_temp.wallet_expect(not has_function_privilege('authenticated',
    'public.prepare_fieldrush_account_deletion_before_wallet_forfeiture()','execute'),'old preparation cannot bypass consent');
  perform pg_temp.wallet_expect(not has_function_privilege('anon',
    'public.prepare_fieldrush_account_deletion(boolean)','execute'),'anonymous preparation denied');
  perform pg_temp.wallet_reject(format('select fieldrush_private.forfeit_deleted_account_wallets(%L)',player),'42501');
  insert into public.field_wallet_accounts(profile_id,balance_fils) values(player,53200);
  insert into public.field_wallet_usd_accounts(profile_id,balance_fils) values(player,9600);
  insert into public.field_wallet_transactions(profile_id,direction,amount_fils,transaction_type,
    balance_after_fils,idempotency_key,description,currency) values
    (player,'CREDIT',53200,'BOOKING_REFUND',53200,'wallet-fixture-bhd-'||player,'Rollback-only BHD credit.','BHD'),
    (player,'CREDIT',9600,'BOOKING_REFUND',9600,'wallet-fixture-usd-'||player,'Rollback-only USD credit.','USD');
  perform pg_temp.wallet_reject('select public.prepare_fieldrush_account_deletion()','22023');
  perform pg_temp.wallet_reject('select public.prepare_fieldrush_account_deletion(false)','22023');
  perform pg_temp.wallet_reject('select public.prepare_fieldrush_account_deletion(null)','22023');
  perform pg_temp.wallet_reject(format('delete from auth.users where id=%L',player),'22023');
  perform pg_temp.wallet_expect((select balance_fils=53200 from public.field_wallet_accounts where profile_id=player),
    'no consent leaves wallet untouched');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',player,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','otp','timestamp',extract(epoch from now()-interval '1 day')::bigint)))::text,true);
  perform pg_temp.wallet_reject('select public.prepare_fieldrush_account_deletion(true)','42501');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',player,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','otp','timestamp',extract(epoch from now())::bigint)))::text,true);
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,currency)
    values('OPEN','Rollback wallet verification',date_trunc('minute',now())+interval '30 days',
      date_trunc('minute',now())+interval '30 days 1 hour',8000,'USD')
    returning id into game;
  insert into public.payment_intents(profile_id,purpose,status,currency,amount_fils,payload,
    quote_snapshot,transaction_reference,provider)
    values(player,'SOLO_BOOKING','PENDING','USD',9600,jsonb_build_object('game_id',game,'role','ATT'),
      '{}','wallet-intent-'||player,'STRIPE') returning id into intent;
  perform pg_temp.wallet_reject('select public.prepare_fieldrush_account_deletion(true)','22023');
  perform pg_temp.wallet_expect((select balance_fils=53200 from public.field_wallet_accounts where profile_id=player),
    'unsettled payment blocks preparation without touching wallet');
  update public.payment_intents set status='FAILED' where id=intent;
  insert into public.payment_intents(profile_id,purpose,status,currency,amount_fils,payload,
    quote_snapshot,transaction_reference,provider,provider_intent_id,provider_payment_id)
    values(player,'SOLO_BOOKING','FINALIZED','USD',9600,jsonb_build_object('game_id',game,'role','ATT'),
      '{}','wallet-refund-'||player,'STRIPE','pi_wallet_'||player,'ch_wallet_'||player) returning id into intent;
  perform public.prepare_fieldrush_account_deletion(true);
  perform pg_temp.wallet_expect((select status='deletion_pending' and wallet_forfeiture_confirmed_at is not null
    from fieldrush_private.accounts where user_id=player),'prepare records explicit consent');
  perform pg_temp.wallet_expect((select balance_fils=53200 from public.field_wallet_accounts where profile_id=player),
    'prepare does not spend or forfeit credit');
  perform pg_temp.wallet_expect(not exists(select 1 from public.field_wallet_transactions where profile_id=player
    and direction='DEBIT'),'no debit before final Auth deletion');
  perform public.credit_field_wallet(player,700,'BOOKING_REFUND','wallet-late-credit-'||player,
    'A settled credit received while deletion was pending.');
  insert into public.payment_refunds(intent_id,recipient_profile_id,idempotency_key,provider_intent_id,
    amount_fils,amount_minor,currency,reason,status)
    values(intent,player,'wallet-refund-'||player,'pi_wallet_'||player,9600,960,'USD',
      'Rollback-only pending provider refund.','PENDING') returning id into refund;
  perform pg_temp.wallet_reject(format('delete from auth.users where id=%L',player),'22023');
  perform pg_temp.wallet_expect(not exists(select 1 from public.field_wallet_transactions where profile_id=player
    and direction='DEBIT'),'pending provider refund cannot be forfeited');
  perform set_config('request.jwt.claim.role','service_role',true);
  perform public.finish_payment_refund(refund,'re_wallet_'||player,'succeeded',960,'USD',null,0);
  update public.payment_intents set external_refund_review_required=true where id=intent;
  perform pg_temp.wallet_reject(format('delete from auth.users where id=%L',player),'22023');
  update public.payment_intents set external_refund_review_required=false where id=intent;
  select count(*) into before_credit_count from public.field_wallet_transactions where profile_id=player and direction='CREDIT';
  delete from auth.users where id=player;
  perform pg_temp.wallet_expect(not exists(select 1 from auth.users where id=player),'Auth identity deleted');
  perform pg_temp.wallet_expect(not exists(select 1 from fieldrush_private.accounts where user_id=player),'private identity removed');
  perform pg_temp.wallet_expect((select balance_fils=0 from public.field_wallet_accounts where profile_id=player),'BHD balance zero');
  perform pg_temp.wallet_expect((select balance_fils=0 from public.field_wallet_usd_accounts where profile_id=player),'USD balance zero');
  perform pg_temp.wallet_expect((select count(*)=2 and sum(amount_fils) filter(where currency='BHD')=53900
    and sum(amount_fils) filter(where currency='USD')=9600 and bool_and(direction='DEBIT'
      and balance_after_fils=0 and metadata->>'policy'='ACCOUNT_DELETION_V1' and metadata->>'consent_at' is not null)
    from public.field_wallet_transactions where profile_id=player and transaction_type='ACCOUNT_DELETION_FORFEITURE'),
    'exact independent-currency forfeitures are audited, including late settled credit');
  perform pg_temp.wallet_expect((select count(*)=before_credit_count from public.field_wallet_transactions
    where profile_id=player and direction='CREDIT'),'historical credits retained');
  perform pg_temp.wallet_expect((select status='SUCCEEDED' from public.payment_refunds where id=refund),
    'completed original-method refund retained, not converted into forfeiture');
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform pg_temp.wallet_reject('select public.get_my_fieldrush_wallet()','42501');
  perform pg_temp.wallet_reject(format('select public.credit_field_wallet(%L,100,''BOOKING_REFUND'',%L,''Late credit after deletion.'')',
    player,'wallet-after-deletion-'||player),'22023');
  perform pg_temp.wallet_reject(format('update public.field_wallet_transactions set description=''changed'' where profile_id=%L',player),'P0001');
  replacement:=pg_temp.wallet_player('15557770001');
  perform pg_temp.wallet_expect(replacement<>player,'same phone gets a new identity');
  result:=public.get_my_fieldrush_wallet();
  perform pg_temp.wallet_expect(result#>>'{balances,0,balance_fils}'='0' and result#>>'{balances,1,balance_fils}'='0',
    'recreated account cannot inherit forfeited credit');

  big_player:=pg_temp.wallet_player();
  insert into public.field_wallet_accounts(profile_id,balance_fils) values(big_player,2147483648);
  perform public.prepare_fieldrush_account_deletion(true);
  delete from auth.users where id=big_player;
  perform pg_temp.wallet_expect((select count(*)=2 and sum(amount_fils::bigint)=2147483648
    from public.field_wallet_transactions where profile_id=big_player and transaction_type='ACCOUNT_DELETION_FORFEITURE'),
    'bigint balance is debited without integer overflow');

  retry_player:=pg_temp.wallet_player();
  insert into public.field_wallet_accounts(profile_id,balance_fils) values(retry_player,1234);
  perform public.prepare_fieldrush_account_deletion(true);
  perform set_config('wallet.test_delete_failure',retry_player::text,true);
  -- Added below; alphabetic order makes this fail after the real anonymizer.
  perform pg_temp.wallet_reject(format('delete from auth.users where id=%L',retry_player),'P0001');
  perform pg_temp.wallet_expect((select balance_fils=1234 from public.field_wallet_accounts where profile_id=retry_player),
    'later Auth failure rolls back the wallet debit');
  perform pg_temp.wallet_expect(not exists(select 1 from public.field_wallet_transactions where profile_id=retry_player
    and transaction_type='ACCOUNT_DELETION_FORFEITURE'),'later Auth failure rolls back the audit debit');
  perform pg_temp.wallet_expect(exists(select 1 from auth.users where id=retry_player)
    and (select account_deleted_at is null from public.profiles where id=retry_player),'failed deletion retains identity');
  perform set_config('wallet.test_delete_failure','',true);
  delete from auth.users where id=retry_player;
  delete from auth.users where id=retry_player;
  perform pg_temp.wallet_expect((select count(*)=1 and sum(amount_fils)=1234 from public.field_wallet_transactions
    where profile_id=retry_player and transaction_type='ACCOUNT_DELETION_FORFEITURE'),'retry forfeits exactly once');
end;
$$;

select count(*) as wallet_deletion_checks_passed from wallet_deletion_checks;
