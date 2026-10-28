-- Preserve the integer-thousandths contract; add explicit currency everywhere
-- money crosses the new-market boundary. No existing BHD balance is converted.
alter table public.tap_payment_intents drop constraint tap_payment_intents_currency_check;
alter table public.tap_payment_intents add constraint tap_payment_intents_currency_check
  check (currency in ('BHD', 'USD') and (currency <> 'USD' or amount_fils % 10 = 0));

create table public.field_wallet_usd_accounts (
  profile_id uuid primary key references public.profiles(id) on delete restrict,
  balance_fils bigint not null default 0 check (balance_fils >= 0),
  currency text not null default 'USD' check (currency = 'USD'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
comment on table public.field_wallet_usd_accounts is
  'USD-only balances in integer thousandths; isolated from the historical BHD wallet. No FX or mixed-currency tender.';
alter table public.field_wallet_usd_accounts enable row level security;
revoke all on public.field_wallet_usd_accounts from public, anon, authenticated;
grant all on public.field_wallet_usd_accounts to service_role;
create trigger set_field_wallet_usd_accounts_updated_at before update on public.field_wallet_usd_accounts
  for each row execute function public.set_updated_at();
create trigger fieldrush_usd_wallet_deletion_guard before insert or update on public.field_wallet_usd_accounts
  for each row execute function fieldrush_private.serialize_wallet_with_deletion();
alter table public.field_wallet_transactions add column currency text not null default 'BHD'
  check (currency in ('BHD', 'USD'));

create or replace function public.credit_field_wallet(
  profile_id_to_credit uuid, amount_fils_to_credit integer, transaction_type_to_use text,
  idempotency_key_to_use text, description_to_use text, policy_version_id_to_use uuid default null,
  booking_id_to_use uuid default null, incident_id_to_use uuid default null, metadata_to_use jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare existing public.field_wallet_transactions%rowtype; next_balance bigint; transaction_id uuid;
  currency_to_use text := 'BHD';
begin
  if amount_fils_to_credit <= 0 then return null; end if;
  -- Every solo refund/deposit-return caller supplies its booking. Clan credits
  -- retain BHD. Currency never comes from client-controlled metadata.
  if booking_id_to_use is not null then
    select g.currency into currency_to_use from public.open_queue_bookings b
      join public.open_queue_games g on g.id = b.game_id
      where b.id = booking_id_to_use and b.profile_id = profile_id_to_credit;
    if currency_to_use is null then raise exception 'Refund booking and recipient do not match.'; end if;
  end if;
  select * into existing from public.field_wallet_transactions where idempotency_key = idempotency_key_to_use;
  if existing.id is not null then
    if existing.profile_id <> profile_id_to_credit or existing.currency <> currency_to_use
      or existing.amount_fils <> amount_fils_to_credit then raise exception 'Refund idempotency conflict.'; end if;
    return existing.id;
  end if;
  if currency_to_use = 'USD' then
    insert into public.field_wallet_usd_accounts (profile_id) values (profile_id_to_credit) on conflict do nothing;
    select balance_fils into next_balance from public.field_wallet_usd_accounts where profile_id = profile_id_to_credit for update;
  else
    insert into public.field_wallet_accounts (profile_id) values (profile_id_to_credit) on conflict do nothing;
    select balance_fils into next_balance from public.field_wallet_accounts where profile_id = profile_id_to_credit for update;
  end if;
  select * into existing from public.field_wallet_transactions where idempotency_key = idempotency_key_to_use;
  if existing.id is not null then
    if existing.profile_id <> profile_id_to_credit or existing.currency <> currency_to_use
      or existing.amount_fils <> amount_fils_to_credit then raise exception 'Refund idempotency conflict.'; end if;
    return existing.id;
  end if;
  next_balance := next_balance + amount_fils_to_credit;
  if currency_to_use = 'USD' then
    update public.field_wallet_usd_accounts set balance_fils = next_balance where profile_id = profile_id_to_credit;
  else
    update public.field_wallet_accounts set balance_fils = next_balance where profile_id = profile_id_to_credit;
  end if;
  insert into public.field_wallet_transactions (
    profile_id, direction, amount_fils, transaction_type, balance_after_fils, idempotency_key,
    policy_version_id, booking_id, incident_id, description, metadata, currency
  ) values (
    profile_id_to_credit, 'CREDIT', amount_fils_to_credit, transaction_type_to_use, next_balance, idempotency_key_to_use,
    policy_version_id_to_use, booking_id_to_use, incident_id_to_use, trim(description_to_use),
    coalesce(metadata_to_use, '{}'::jsonb), currency_to_use
  ) returning id into transaction_id;
  return transaction_id;
end;
$$;
revoke all on function public.credit_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.credit_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb) to service_role;

create function public.get_my_fieldrush_wallet()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare caller uuid := auth.uid(); market text; usd bigint; bhd bigint;
begin
  if caller is null then raise exception 'Sign in to view your wallet.' using errcode = '42501'; end if;
  select region into market from public.player_ratings where profile_id = caller;
  select balance_fils into usd from public.field_wallet_usd_accounts where profile_id = caller;
  select balance_fils into bhd from public.field_wallet_accounts where profile_id = caller;
  return jsonb_build_object(
    'currency', case when coalesce(market, 'phoenix') = 'phoenix' then 'USD' else 'BHD' end,
    'balance_fils', case when coalesce(market, 'phoenix') = 'phoenix' then coalesce(usd, 0) else coalesce(bhd, 0) end,
    'balances', jsonb_build_array(jsonb_build_object('currency', 'USD', 'balance_fils', coalesce(usd, 0)),
      jsonb_build_object('currency', 'BHD', 'balance_fils', coalesce(bhd, 0)))
  );
end;
$$;
revoke all on function public.get_my_fieldrush_wallet() from public, anon, authenticated;
grant execute on function public.get_my_fieldrush_wallet() to authenticated;

-- Exact assertions ensure upstream financial/security logic is not silently
-- overwritten. Both quote and booking round USD amounts to actual cents.
do $migration$
declare definition text; old_text text;
begin
  definition := pg_get_functiondef('public.preview_open_queue_booking_cost(uuid,text)'::regprocedure);
  if position('''currency'', ''BHD''' in definition) = 0 then raise exception 'Solo quote currency contract changed.'; end if;
  definition := replace(definition, '''currency'', ''BHD''', '''currency'', game_to_book.currency');
  old_text := E'  terms_to_use := public.ensure_match_reliability_terms(\n    ''SOLO'',\n    game_to_book.id\n  );';
  if position(old_text in definition) = 0 then raise exception 'Solo quote availability contract changed.'; end if;
  definition := replace(definition, old_text, $guard$
  if game_to_book.status <> 'OPEN' or
    (select count(*) from public.open_queue_bookings b where b.game_id = game_to_book.id and b.status = 'CONFIRMED' and b.role = normalized_role)
      >= (case normalized_role when 'GK' then game_to_book.goalkeeper_capacity when 'DEF' then game_to_book.defender_capacity
        when 'MID' then game_to_book.midfielder_capacity when 'ATT' then game_to_book.attacker_capacity end)
  then
    raise exception 'That position is not available in this game.';
  end if;
$guard$ || old_text);
  old_text := E'  if active_strikes >= deposit_threshold then';
  if position(old_text in definition) = 0 then raise exception 'Solo quote deposit contract changed.'; end if;
  definition := replace(definition, old_text, E'  if game_to_book.currency = ''USD'' then\n    match_fee_fils := round(match_fee_fils::numeric / 10)::integer * 10;\n  end if;\n' || old_text);
  old_text := E'  return jsonb_build_object(\n    ''server_now''';
  if position(old_text in definition) = 0 then raise exception 'Solo quote result contract changed.'; end if;
  definition := replace(definition, old_text, E'  if game_to_book.currency = ''USD'' then\n    deposit_amount_fils := ceiling(deposit_amount_fils::numeric / 10)::integer * 10;\n  end if;\n' || old_text);
  execute definition;

  definition := pg_get_functiondef('public.book_open_queue_game_server(uuid,text,text,text)'::regprocedure);
  if position('intent.currency = ''BHD''' in definition) = 0 then raise exception 'Captured intent currency guard changed.'; end if;
  definition := replace(definition, 'intent.currency = ''BHD''', 'intent.currency = game_to_book.currency');
  old_text := E'  if active_strikes >= deposit_threshold then';
  if position(old_text in definition) = 0 then raise exception 'Booking deposit contract changed.'; end if;
  definition := replace(definition, old_text, E'  if game_to_book.currency = ''USD'' then\n    base_amount_to_use := round(base_amount_to_use::numeric / 10)::integer * 10;\n  end if;\n' || old_text);
  old_text := '  total_amount_to_use := base_amount_to_use + deposit_amount_to_use;';
  if position(old_text in definition) = 0 then raise exception 'Booking total contract changed.'; end if;
  definition := replace(definition, old_text, E'  if game_to_book.currency = ''USD'' then\n    deposit_amount_to_use := ceiling(deposit_amount_to_use::numeric / 10)::integer * 10;\n  end if;\n' || old_text);
  execute definition;

  definition := pg_get_functiondef('fieldrush_private.assert_deletion_ready(uuid)'::regprocedure);
  old_text := '  perform 1 from public.field_wallet_accounts where profile_id = caller for update;';
  if position(old_text in definition) = 0 then raise exception 'Deletion wallet locking contract changed.'; end if;
  definition := replace(definition, old_text, old_text || E'\n  perform 1 from public.field_wallet_usd_accounts where profile_id = caller for update;');
  old_text := '  if exists (select 1 from public.field_wallet_accounts where profile_id = caller and balance_fils <> 0)';
  if position(old_text in definition) = 0 then raise exception 'Deletion wallet balance contract changed.'; end if;
  definition := replace(definition, old_text, old_text || E'\n    or exists (select 1 from public.field_wallet_usd_accounts where profile_id = caller and balance_fils <> 0)');
  execute definition;

  definition := pg_get_functiondef('public.get_my_reliability_status()'::regprocedure);
  old_text := E'    ''wallet'', jsonb_build_object(\n      ''currency'', ''BHD'',\n      ''balance_fils'', coalesce(wallet_balance_to_use, 0)\n    )';
  if position(old_text in definition) = 0 then raise exception 'Reliability wallet contract changed.'; end if;
  execute replace(definition, old_text, '    ''wallet'', public.get_my_fieldrush_wallet()');
end;
$migration$;
