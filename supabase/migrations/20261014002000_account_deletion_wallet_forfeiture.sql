-- Self-deletion forfeits wallet credit, never unresolved payment/refund claims.
-- Preserve the append-only ledger; debit only inside the final Auth transaction.
alter table fieldrush_private.accounts
  add column wallet_forfeiture_confirmed_at timestamptz;

alter table public.field_wallet_transactions
  drop constraint field_wallet_transactions_transaction_type_check;
alter table public.field_wallet_transactions
  add constraint field_wallet_transactions_transaction_type_check check (
    transaction_type in ('BOOKING_REFUND','FIELD_CANCELLATION_REFUND',
      'RELIABILITY_DEPOSIT_RETURN','SUSPENSION_BOOKING_RELEASE','APPEAL_ADJUSTMENT',
      'ACCOUNT_DELETION_FORFEITURE')
  ),
  add constraint wallet_deletion_forfeiture_is_debit check (
    transaction_type <> 'ACCOUNT_DELETION_FORFEITURE' or direction = 'DEBIT'
  );

create function fieldrush_private.forfeit_deleted_account_wallets(player uuid)
returns void language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_private
as $$
declare
  wallet record; remaining bigint; debit integer; part integer;
  consent_at timestamptz; account_status text;
begin
  if pg_trigger_depth() = 0 then
    raise exception 'Wallet forfeiture is only available during account deletion.' using errcode='42501';
  end if;
  select status,wallet_forfeiture_confirmed_at into account_status,consent_at
    from fieldrush_private.accounts where user_id=player for update;
  perform 1 from public.field_wallet_accounts where profile_id=player for update;
  perform 1 from public.field_wallet_usd_accounts where profile_id=player for update;
  for wallet in
    select currency,balance_fils from public.field_wallet_accounts where profile_id=player
    union all
    select currency,balance_fils from public.field_wallet_usd_accounts where profile_id=player
  loop
    if wallet.balance_fils=0 then continue; end if;
    if account_status is distinct from 'deletion_pending' or consent_at is null then
      raise exception 'Confirm permanent wallet forfeiture before deleting your account.' using errcode='22023';
    end if;
    remaining:=wallet.balance_fils;
    part:=0;
    -- Wallet totals are bigint, while existing ledger amounts are integer.
    -- Split very large totals without rounding, conversion or overflow.
    while remaining>0 loop
      part:=part+1;
      debit:=least(remaining,2147483647)::integer;
      remaining:=remaining-debit;
      if wallet.currency='USD' then
        update public.field_wallet_usd_accounts set balance_fils=remaining where profile_id=player;
      else
        update public.field_wallet_accounts set balance_fils=remaining where profile_id=player;
      end if;
      insert into public.field_wallet_transactions(profile_id,direction,amount_fils,
        transaction_type,balance_after_fils,idempotency_key,description,metadata,currency)
      values(player,'DEBIT',debit,'ACCOUNT_DELETION_FORFEITURE',remaining,
        'account-deletion-forfeiture:'||player::text||':'||wallet.currency||':'||part,
        'Remaining wallet balance forfeited on confirmed account deletion.',
        jsonb_build_object('policy','ACCOUNT_DELETION_V1','consent_at',consent_at,
          'wallet_balance_before_fils',wallet.balance_fils,'part',part),wallet.currency);
    end loop;
  end loop;
end;
$$;
revoke all on function fieldrush_private.forfeit_deleted_account_wallets(uuid)
  from public,anon,authenticated,service_role;

do $migration$
declare definition text; old_clause text;
begin
  definition:=pg_get_functiondef('fieldrush_private.assert_deletion_ready(uuid)'::regprocedure);
  old_clause:=E'  if exists (select 1 from public.field_wallet_accounts where profile_id = caller and balance_fils <> 0)\n    or exists (select 1 from public.field_wallet_usd_accounts where profile_id = caller and balance_fils <> 0)\n    or exists (select 1 from public.payment_intents';
  if position(old_clause in definition)=0 then raise exception 'Wallet deletion readiness contract changed.'; end if;
  definition:=replace(definition,old_clause,'  if exists (select 1 from public.payment_intents');
  definition:=replace(definition,'settle your wallet, payment or refund','settle your payment or refund');
  execute definition;

  definition:=pg_get_functiondef('fieldrush_private.anonymize_deleted_user()'::regprocedure);
  old_clause:='  perform fieldrush_private.assert_deletion_ready(old.id);';
  if position(old_clause in definition)=0 then raise exception 'Auth deletion transaction contract changed.'; end if;
  execute replace(definition,old_clause,old_clause||E'\n  perform fieldrush_private.forfeit_deleted_account_wallets(old.id);');

  definition:=pg_get_functiondef('public.get_my_fieldrush_wallet()'::regprocedure);
  old_clause:='caller uuid := auth.uid();';
  if position(old_clause in definition)=0 then raise exception 'Wallet identity contract changed.'; end if;
  execute replace(definition,old_clause,'caller uuid := fieldrush_private.require_user();');
end;
$migration$;

alter function public.prepare_fieldrush_account_deletion()
  rename to prepare_fieldrush_account_deletion_before_wallet_forfeiture;
revoke all on function public.prepare_fieldrush_account_deletion_before_wallet_forfeiture()
  from public,anon,authenticated,service_role;

create function public.prepare_fieldrush_account_deletion(wallet_forfeiture_confirmed boolean default false)
returns void language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_private
as $$
begin
  if wallet_forfeiture_confirmed is distinct from true then
    raise exception 'Confirm that deletion permanently removes wallet access and forfeits the remaining balance.' using errcode='22023';
  end if;
  -- Preserve the real recent-OTP/OAuth check and every non-wallet obligation.
  perform public.prepare_fieldrush_account_deletion_before_wallet_forfeiture();
  update fieldrush_private.accounts set wallet_forfeiture_confirmed_at=clock_timestamp()
    where user_id=auth.uid();
end;
$$;
revoke all on function public.prepare_fieldrush_account_deletion(boolean) from public,anon;
grant execute on function public.prepare_fieldrush_account_deletion(boolean) to authenticated,service_role;
notify pgrst,'reload schema';
