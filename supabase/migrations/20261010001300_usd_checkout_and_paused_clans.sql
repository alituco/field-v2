-- New sales are USD. Historical money and immutable policy snapshots are not
-- converted or relabelled. Clan checkout is paused; its future price is $80.
create table public.game_payment_settings (
  singleton boolean primary key default true check(singleton),
  clan_enabled boolean not null default false,
  clan_price_fils integer not null default 80000 check(clan_price_fils between 500 and 1000000 and clan_price_fils%10=0),
  currency text not null default 'USD' check(currency='USD'),
  updated_at timestamptz not null default clock_timestamp()
);
insert into public.game_payment_settings(singleton) values(true);
alter table public.game_payment_settings enable row level security;
revoke all on public.game_payment_settings from public,anon,authenticated;
grant select,update on public.game_payment_settings to service_role;

create function public.get_game_payment_settings()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('clan_enabled',clan_enabled,'clan_price_fils',clan_price_fils,
    'currency',currency,'updated_at',updated_at) from public.game_payment_settings where singleton;
$$;
create function public.admin_set_game_payment_settings(actor_admin_id uuid,clan_price_fils_to_use integer,
  reason_to_use text,expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare old_settings public.game_payment_settings%rowtype; result jsonb;
begin
  if auth.role() is distinct from 'service_role' or not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Only an active administrator can change game pricing.' using errcode='42501'; end if;
  if clan_price_fils_to_use is null or clan_price_fils_to_use not between 500 and 1000000
    or clan_price_fils_to_use%10<>0 or char_length(trim(coalesce(reason_to_use,''))) not between 10 and 1000 then
    raise exception 'Provide a valid USD price in whole cents and a reason.' using errcode='22023'; end if;
  select * into old_settings from public.game_payment_settings where singleton for update;
  if expected_updated_at is distinct from old_settings.updated_at then
    raise exception 'Game pricing changed. Refresh before saving.' using errcode='40001'; end if;
  -- Price editing cannot turn on a product that has intentionally been paused.
  update public.game_payment_settings set clan_price_fils=clan_price_fils_to_use,updated_at=clock_timestamp() where singleton;
  result:=public.get_game_payment_settings();
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_admin_id,'GAME_PAYMENT_SETTINGS_UPDATED','POLICY',actor_admin_id,trim(reason_to_use),to_jsonb(old_settings)-'singleton',result);
  return result;
end;
$$;
revoke all on function public.get_game_payment_settings(),public.admin_set_game_payment_settings(uuid,integer,text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.get_game_payment_settings() to authenticated,service_role;
grant execute on function public.admin_set_game_payment_settings(uuid,integer,text,timestamptz) to service_role;

-- Existing fixtures retain the exact currency/fee that was actually charged.
alter table public.fixtures add column currency text not null default 'BHD' check(currency in ('BHD','USD'));
alter table public.fixtures add column base_price_fils integer;
update public.fixtures set base_price_fils=coalesce(home_base_amount_fils,away_base_amount_fils,20000);
alter table public.fixtures alter column currency set default 'USD';
alter table public.fixtures alter column base_price_fils set not null;
alter table public.fixtures add constraint fixtures_base_price_check check(base_price_fils>=0);

create function public.require_clan_checkout_enabled()
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not coalesce((select clan_enabled from public.game_payment_settings where singleton),false) then
    raise exception 'Clan games are currently paused. Please book a solo game instead.' using errcode='P0001'; end if;
end;
$$;
create function public.protect_fixture_checkout_snapshot()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' then
    perform public.require_clan_checkout_enabled();
    new.currency:='USD';
    select clan_price_fils into new.base_price_fils from public.game_payment_settings where singleton;
  else
    if (new.currency,new.base_price_fils) is distinct from (old.currency,old.base_price_fils) then
      raise exception 'The fixture currency and quoted team fee are immutable.' using errcode='22023'; end if;
    if new.home_clan_id is distinct from old.home_clan_id or new.away_clan_id is distinct from old.away_clan_id then
      -- Administrative cancellation/removal is still allowed; adding a clan is not.
      if new.home_clan_id is not null and new.home_clan_id is distinct from old.home_clan_id
        or new.away_clan_id is not null and new.away_clan_id is distinct from old.away_clan_id then
        perform public.require_clan_checkout_enabled();
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger aa_fixture_checkout_snapshot before insert or update on public.fixtures
  for each row execute function public.protect_fixture_checkout_snapshot();
revoke all on function public.require_clan_checkout_enabled(),public.protect_fixture_checkout_snapshot() from public,anon,authenticated;
grant execute on function public.require_clan_checkout_enabled() to service_role;

alter table public.payment_intents drop constraint payment_intents_provider_amount_check;
alter table public.payment_intents add constraint payment_intents_provider_amount_check
  check(provider<>'STRIPE' or (currency='USD' and amount_fils%10=0));

-- Reuse the validated deposit rules, supplying a frozen price and currency.
do $migration$
declare definition text; signature text;
begin
  definition:=pg_get_functiondef('public.clan_fixture_charge_quote_from_snapshot(uuid,uuid,jsonb,timestamptz)'::regprocedure);
  definition:=replace(definition,'clan_fixture_charge_quote_from_snapshot(', 'clan_fixture_charge_quote_for_price(');
  definition:=replace(definition,'server_now_to_use timestamp with time zone DEFAULT',
    'base_price_fils_to_use integer, currency_to_use text, server_now_to_use timestamp with time zone DEFAULT');
  definition:=replace(definition,'base_amount_fils constant integer := 20000;', 'base_amount_fils integer := base_price_fils_to_use;');
  definition:=replace(definition,'''currency'', ''BHD''','''currency'', currency_to_use');
  definition:=replace(definition,E'begin\n',E'begin\n  if currency_to_use not in (''USD'',''BHD'') or base_price_fils_to_use<0 then raise exception ''Invalid fixture price.''; end if;\n');
  execute definition;
  -- Old four-argument entry points are for NEW quotes only, now using settings.
  definition:=pg_get_functiondef('public.clan_fixture_charge_quote_from_snapshot(uuid,uuid,jsonb,timestamptz)'::regprocedure);
  definition:=replace(definition,'base_amount_fils constant integer := 20000;',
    'base_amount_fils integer := (select clan_price_fils from public.game_payment_settings where singleton);');
  definition:=replace(definition,'''currency'', ''BHD''','''currency'', ''USD''');
  definition:=replace(definition,E'begin\n',E'begin\n  perform public.require_clan_checkout_enabled();\n');
  execute definition;
  foreach signature in array array['public.preview_create_clan_fixture_charge(uuid,date,text)',
    'public.preview_join_clan_fixture_charge(uuid,uuid)','public.clan_fixture_charge_quote(uuid,timestamptz,timestamptz)',
    'public.create_fixture(uuid,text,date,text)','public.join_fixture(uuid,uuid)'] loop
    definition:=pg_get_functiondef(signature::regprocedure);
    if position(E'begin\n' in definition)=0 then raise exception 'Clan entry point changed: %',signature; end if;
    definition:=replace(definition,E'begin\n',E'begin\n  perform public.require_clan_checkout_enabled();\n');
    if signature='public.preview_join_clan_fixture_charge(uuid,uuid)' then
      definition:=replace(definition,'public.clan_fixture_charge_quote_from_snapshot(', 'public.clan_fixture_charge_quote_for_price(');
      definition:=replace(definition,E'terms_to_use.policy_snapshot\n  );',
        E'terms_to_use.policy_snapshot, fixture_to_use.base_price_fils, fixture_to_use.currency\n  );');
    end if;
    execute definition;
  end loop;
  definition:=pg_get_functiondef('public.snapshot_clan_fixture_charge()'::regprocedure);
  definition:=replace(definition,'public.clan_fixture_charge_quote_from_snapshot(', 'public.clan_fixture_charge_quote_for_price(');
  definition:=replace(definition,E'policy_to_use.config\n      );',E'policy_to_use.config, new.base_price_fils, new.currency\n      );');
  definition:=replace(definition,E'terms_to_use.policy_snapshot\n      );',E'terms_to_use.policy_snapshot, new.base_price_fils, new.currency\n      );');
  execute definition;
  definition:=pg_get_functiondef('public.finalize_payment_intent(uuid)'::regprocedure);
  definition:=replace(definition,'i.currency<>''BHD''','i.currency is distinct from f.currency');
  execute definition;
  definition:=pg_get_functiondef('public.clan_fixture_cancellation_quote(uuid,uuid,timestamptz)'::regprocedure);
  definition:=replace(definition,'''currency'', ''BHD''','''currency'', fixture_to_use.currency');
  execute definition;
  definition:=pg_get_functiondef('public.reliability_policy_config_is_valid(jsonb)'::regprocedure);
  definition:=replace(definition,'config_to_check #>> ''{wallet,currency}'' <> ''BHD''',
    'config_to_check #>> ''{wallet,currency}'' not in (''USD'',''BHD'')');
  definition:=replace(definition,'config_to_check #>> ''{solo,reliabilityDeposit,onTimeReturnDestination}'' <> ''FIELD_WALLET''',
    'config_to_check #>> ''{solo,reliabilityDeposit,onTimeReturnDestination}'' not in (''FIELD_WALLET'',''ORIGINAL_PAYMENT_METHOD'')');
  execute definition;
  definition:=pg_get_functiondef('fieldrush_private.assert_deletion_ready(uuid)'::regprocedure);
  definition:=replace(definition,'  if exists (select 1 from public.field_wallet_accounts',
    E'  if exists (select 1 from public.payment_refunds where recipient_profile_id=caller and status in (''PENDING'',''PROCESSING'',''FAILED'')) then\n    raise exception ''Contact support to settle your pending payment refund before deleting your account.'' using errcode=''22023'';\n  end if;\n  if exists (select 1 from public.field_wallet_accounts');
  execute definition;
end;
$migration$;
revoke all on function public.clan_fixture_charge_quote_for_price(uuid,uuid,jsonb,integer,text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.clan_fixture_charge_quote_for_price(uuid,uuid,jsonb,integer,text,timestamptz) to service_role;
