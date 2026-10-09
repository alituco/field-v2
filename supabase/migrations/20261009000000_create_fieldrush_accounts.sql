-- Fieldrush account foundation. This migration does not reset existing data.
-- Private identity fields never live in public player-search rows or JWT metadata.
create schema if not exists fieldrush_private;
revoke all on schema fieldrush_private from public, anon, authenticated;

create table fieldrush_private.accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  first_name text,
  last_name text,
  username text,
  date_of_birth date,
  email text,
  status text not null default 'onboarding'
    check (status in ('onboarding', 'active', 'deletion_pending')),
  onboarding_completed_at timestamptz,
  tour_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table fieldrush_private.legal_acceptances (
  user_id uuid not null references auth.users(id) on delete cascade,
  document text not null check (document in ('terms', 'privacy')),
  version text not null,
  accepted_at timestamptz not null default now(),
  primary key (user_id, document, version)
);
create table fieldrush_private.reserved_usernames (
  normalized_name text primary key,
  check (normalized_name ~ '^[a-z0-9]+$')
);
insert into fieldrush_private.reserved_usernames (normalized_name)
select unnest(array[
  'admin', 'admins', 'administrator', 'administrators', 'administration',
  'support', 'help', 'helpdesk', 'customerservice', 'customersupport',
  'dev', 'devs', 'developer', 'developers', 'development', 'engineering',
  'staff', 'team', 'official', 'moderator', 'moderators', 'mod', 'mods',
  'security', 'safety', 'trust', 'trustandsafety', 'abuse', 'report', 'reports',
  'billing', 'payments', 'payment', 'refund', 'refunds', 'finance',
  'system', 'root', 'superuser', 'sysadmin', 'operator', 'operations', 'ops',
  'owner', 'founder', 'ceo', 'service', 'services', 'bot', 'bots', 'api',
  'auth', 'oauth', 'login', 'logout', 'signin', 'signup', 'register',
  'account', 'accounts', 'profile', 'profiles', 'settings', 'null', 'undefined',
  'anonymous', 'deleted', 'deleteduser', 'me', 'you', 'everyone', 'all',
  'field', 'fieldrush', 'fieldrushapp', 'fieldrushteam', 'fieldrushsupport',
  'fieldrushadmin', 'fieldrushofficial', 'officialfieldrush', 'fieldrushdev',
  'contact', 'legal', 'privacy', 'terms', 'info', 'noreply', 'noresponse',
  'webmaster', 'postmaster', 'hostmaster', 'www', 'mail', 'email',
  'google', 'apple', 'supabase', 'twilio', 'test', 'testing', 'demo'
]);
revoke all on all tables in schema fieldrush_private
  from public, anon, authenticated;
alter table fieldrush_private.accounts enable row level security;
alter table fieldrush_private.legal_acceptances enable row level security;
alter table fieldrush_private.reserved_usernames enable row level security;

-- Historical match/payment rows retain their stable, anonymized profile FK
-- when an auth account is deleted. Deleting auth must not cascade a whole clan.
alter table public.profiles drop constraint profiles_id_fkey;
alter table public.profiles add column auth_user_id uuid unique
  references auth.users(id) on delete set null;
update public.profiles set auth_user_id = id;
alter table public.profiles add column account_deleted_at timestamptz;
alter table public.profiles drop constraint profiles_display_name_check;
alter table public.profiles add constraint profiles_display_name_check
  check (char_length(btrim(display_name)) between 2 and 54);
alter table public.profiles drop constraint profiles_username_format_check;
-- NOT VALID preserves pre-Fieldrush legacy rows; all new/changed values must
-- follow this rule. The account RPC applies the stricter separator rules too.
alter table public.profiles add constraint profiles_username_format_check
  check (username is null or username ~ '^[a-z0-9._]{3,20}$') not valid;

-- Identity and counters can only be changed by server-owned RPCs/triggers.
revoke insert, update, delete on public.profiles from anon, authenticated;
revoke select on public.profiles from public, anon, authenticated;
revoke select (phone) on public.profiles from authenticated;
grant select (id, display_name, created_at, updated_at, username, bio,
  avatar_url, following_count, fans_count) on public.profiles to authenticated;
grant update (bio, avatar_url) on public.profiles to authenticated;
drop policy if exists "Users can insert their own profile" on public.profiles;
revoke all on function public.save_my_onboarding_profile(text, date)
  from public, anon, authenticated;
-- The earlier account-settings API writes public identity and DOB directly.
-- Fieldrush account RPCs are now the only player-facing identity writers.
revoke all on function public.save_my_account_details(text, text, text, text, text, date)
  from public, anon, authenticated;

create function fieldrush_private.require_user()
returns uuid language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private
as $$
declare caller uuid := auth.uid();
begin
  if caller is null or not exists (
    select 1 from auth.users where id = caller and deleted_at is null
      and (banned_until is null or banned_until <= now())
  ) then
    raise exception 'Your session has expired. Sign in again.' using errcode = '42501';
  end if;
  return caller;
end;
$$;

create function fieldrush_private.validate_draft(draft jsonb)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_private
as $$
declare
  normalized jsonb;
  value text;
  birthday date;
begin
  if draft is null or jsonb_typeof(draft) <> 'object' then
    raise exception 'Provide valid account details.' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(draft) k
    where k not in ('first_name', 'last_name', 'username', 'date_of_birth', 'email')) then
    raise exception 'Unknown account field.' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_each(draft) e
    where jsonb_typeof(e.value) not in ('string', 'null')) then
    raise exception 'Account fields must be text.' using errcode = '22023';
  end if;
  normalized := jsonb_build_object(
    'first_name', nullif(btrim(draft->>'first_name'), ''),
    'last_name', nullif(btrim(draft->>'last_name'), ''),
    'username', nullif(lower(btrim(draft->>'username')), ''),
    'email', nullif(lower(btrim(draft->>'email')), ''),
    'date_of_birth', nullif(draft->>'date_of_birth', '')
  );
  foreach value in array array[normalized->>'first_name', normalized->>'last_name'] loop
    if value is not null and (char_length(value) > 50 or value ~ '[[:cntrl:]]') then
      raise exception 'Names must contain 1–50 characters without control characters.' using errcode = '22023';
    end if;
  end loop;
  value := normalized->>'username';
  if value is not null and (value !~ '^[a-z0-9._]{3,20}$'
    or value ~ '^[._]|[._]$|[._]{2}') then
    raise exception 'Use 3–20 letters, numbers, dots or underscores; no leading, trailing or repeated separators.' using errcode = '22023';
  end if;
  if value is not null and exists (
    select 1 from fieldrush_private.reserved_usernames
    where normalized_name = regexp_replace(value, '[._]', '', 'g')
      or normalized_name = regexp_replace(regexp_replace(value, '[._]', '', 'g'), '[0-9]+$', '')
  ) then
    raise exception 'That username is reserved. Choose another.' using errcode = '22023';
  end if;
  value := normalized->>'email';
  if value is not null and (char_length(value) > 254
    or value !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception 'Enter a valid email address.' using errcode = '22023';
  end if;
  value := normalized->>'date_of_birth';
  if value is not null then
    if value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      raise exception 'Enter a valid birthday.' using errcode = '22023';
    end if;
    begin birthday := value::date;
    exception when datetime_field_overflow or invalid_datetime_format then
      raise exception 'Enter a valid birthday.' using errcode = '22023';
    end;
    if birthday < date '1900-01-01' or birthday > current_date then
      raise exception 'Enter a valid birthday.' using errcode = '22023';
    end if;
    if birthday > (current_date - interval '18 years')::date then
      raise exception 'You must be at least 18 years old to use Fieldrush.' using errcode = '22023';
    end if;
  end if;
  return normalized;
end;
$$;

create function public.get_my_fieldrush_account()
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private
as $$
declare
  caller uuid := fieldrush_private.require_user();
  account fieldrush_private.accounts%rowtype;
  identity auth.users%rowtype;
  contact_email text;
begin
  select * into identity from auth.users where id = caller;
  select * into account from fieldrush_private.accounts where user_id = caller;
  contact_email := coalesce(account.email, nullif(identity.email, ''));
  return jsonb_build_object(
    'first_name', coalesce(account.first_name, ''),
    'last_name', coalesce(account.last_name, ''),
    'username', coalesce(account.username, ''),
    'date_of_birth', account.date_of_birth,
    'email', coalesce(contact_email, ''),
    'phone', case when nullif(identity.phone, '') is null then ''
      else '+' || ltrim(identity.phone, '+') end,
    'phone_verified', identity.phone_confirmed_at is not null and nullif(identity.phone, '') is not null,
    'email_verified', identity.email_confirmed_at is not null
      and lower(coalesce(identity.email, '')) = lower(coalesce(contact_email, ''))
      and nullif(contact_email, '') is not null,
    'google_linked', exists (select 1 from auth.identities where user_id = caller and provider = 'google'),
    'onboarding_completed', account.onboarding_completed_at is not null and account.status = 'active',
    'tour_completed', account.tour_completed_at is not null,
    'status', coalesce(account.status, 'onboarding')
  );
end;
$$;

create function public.save_fieldrush_onboarding_draft(draft jsonb)
returns void language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private
as $$
declare caller uuid := fieldrush_private.require_user(); normalized jsonb;
begin
  normalized := fieldrush_private.validate_draft(draft);
  insert into fieldrush_private.accounts (user_id) values (caller) on conflict do nothing;
  perform 1 from fieldrush_private.accounts where user_id = caller for update;
  if exists (select 1 from fieldrush_private.accounts where user_id = caller and status <> 'onboarding') then
    raise exception 'Use account settings to update this account.' using errcode = '42501';
  end if;
  update fieldrush_private.accounts set
    first_name = normalized->>'first_name', last_name = normalized->>'last_name',
    username = normalized->>'username', date_of_birth = (normalized->>'date_of_birth')::date,
    email = normalized->>'email', updated_at = now()
  where user_id = caller;
end;
$$;

create function public.check_fieldrush_username(candidate text)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_private
as $$
declare caller uuid := fieldrush_private.require_user(); normalized text;
begin
  begin
    normalized := fieldrush_private.validate_draft(jsonb_build_object('username', candidate))->>'username';
  exception when sqlstate '22023' then
    return jsonb_build_object('available', false, 'message', sqlerrm);
  end;
  if normalized is null then
    return jsonb_build_object('available', false, 'message', 'Enter a username.');
  end if;
  if exists (select 1 from public.profiles where lower(username) = normalized and id <> caller) then
    return jsonb_build_object('available', false, 'message', 'That username is taken.');
  end if;
  return jsonb_build_object('available', true, 'message', 'Username available.');
end;
$$;

create function fieldrush_private.write_account(draft jsonb, completing boolean)
returns void language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private
as $$
declare
  caller uuid := fieldrush_private.require_user();
  normalized jsonb := fieldrush_private.validate_draft(draft);
  identity auth.users%rowtype;
  previous fieldrush_private.accounts%rowtype;
begin
  insert into fieldrush_private.accounts (user_id) values (caller) on conflict do nothing;
  select * into previous from fieldrush_private.accounts where user_id = caller for update;
  if previous.status = 'deletion_pending' then
    raise exception 'Account deletion is in progress. Retry deletion or contact support.' using errcode = '42501';
  end if;
  if not completing and previous.onboarding_completed_at is null then
    raise exception 'Complete signup first.' using errcode = '42501';
  end if;
  if exists (select 1 from jsonb_each(normalized) where value = 'null'::jsonb) then
    raise exception 'Complete your name, username, birthday and email.' using errcode = '22023';
  end if;
  select * into identity from auth.users where id = caller for update;
  if identity.phone_confirmed_at is null or nullif(identity.phone, '') is null then
    raise exception 'Verify your phone number before continuing.' using errcode = '42501';
  end if;
  -- Birthday is an eligibility attribute, not a freely editable profile setting.
  if previous.onboarding_completed_at is not null
    and previous.date_of_birth is distinct from (normalized->>'date_of_birth')::date then
    raise exception 'Contact support to correct your birthday.' using errcode = '22023';
  end if;
  insert into public.profiles (id, auth_user_id, display_name, username, phone, date_of_birth)
  values (caller, caller, (normalized->>'first_name') || ' ' || upper(left(normalized->>'last_name', 1)) || '.',
    normalized->>'username', '+' || ltrim(identity.phone, '+'), null)
  on conflict (id) do update set
    auth_user_id = excluded.auth_user_id, display_name = excluded.display_name,
    username = excluded.username, phone = excluded.phone, date_of_birth = null;
  update fieldrush_private.accounts set
    first_name = normalized->>'first_name', last_name = normalized->>'last_name',
    username = normalized->>'username', date_of_birth = (normalized->>'date_of_birth')::date,
    email = normalized->>'email', status = 'active',
    onboarding_completed_at = coalesce(onboarding_completed_at, now()), updated_at = now()
  where user_id = caller;
exception when unique_violation then
  raise exception 'That username is taken. Choose another.' using errcode = '23505';
end;
$$;

create function public.complete_fieldrush_onboarding(draft jsonb, terms_version text, privacy_version text)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_private
as $$
declare caller uuid := fieldrush_private.require_user();
begin
  if terms_version is distinct from 'fieldrush-v1' or privacy_version is distinct from 'fieldrush-v1' then
    raise exception 'Read and accept the current Terms and Privacy Policy.' using errcode = '22023';
  end if;
  perform fieldrush_private.write_account(draft, true);
  insert into fieldrush_private.legal_acceptances (user_id, document, version)
    values (caller, 'terms', terms_version), (caller, 'privacy', privacy_version)
    on conflict do nothing;
  return public.get_my_fieldrush_account();
end;
$$;

create function public.update_my_fieldrush_account(draft jsonb)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_private
as $$
begin
  perform fieldrush_private.write_account(draft, false);
  return public.get_my_fieldrush_account();
end;
$$;

create function public.complete_fieldrush_tour()
returns void language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_private
as $$
declare caller uuid := fieldrush_private.require_user();
begin
  update fieldrush_private.accounts set tour_completed_at = coalesce(tour_completed_at, now()), updated_at = now()
  where user_id = caller and status = 'active' and onboarding_completed_at is not null;
  if not found then raise exception 'Complete signup first.' using errcode = '42501'; end if;
end;
$$;

create function public.is_fieldrush_account_active(profile_id uuid)
returns boolean language sql stable security definer
set search_path = pg_catalog, auth, fieldrush_private
as $$
  select exists (select 1 from fieldrush_private.accounts a join auth.users u on u.id = a.user_id
    where a.user_id = profile_id and a.status = 'active' and a.onboarding_completed_at is not null
      and u.deleted_at is null and (u.banned_until is null or u.banned_until <= now())
      and u.phone_confirmed_at is not null and nullif(u.phone, '') is not null);
$$;

-- Table triggers cover SECURITY DEFINER RPCs as well as direct REST writes.
-- No client metadata/role flag can satisfy this gate.
create function fieldrush_private.require_completed_participant()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private
as $$
declare participant uuid := (to_jsonb(new)->>tg_argv[0])::uuid;
begin
  -- Serialize new participation against deletion's account lock.
  perform 1 from fieldrush_private.accounts where user_id = participant for share;
  if not public.is_fieldrush_account_active(participant) then
    raise exception 'Complete Fieldrush signup before joining games or players.' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger fieldrush_booking_account before insert on public.open_queue_bookings
  for each row execute function fieldrush_private.require_completed_participant('profile_id');
create trigger fieldrush_booking_account_reactivation before update of status, profile_id on public.open_queue_bookings
  for each row when (new.status = 'CONFIRMED' and (old.status <> 'CONFIRMED' or old.profile_id <> new.profile_id))
  execute function fieldrush_private.require_completed_participant('profile_id');
create trigger fieldrush_clan_account before insert on public.clans
  for each row execute function fieldrush_private.require_completed_participant('created_by');
create trigger fieldrush_member_account before insert on public.clan_members
  for each row execute function fieldrush_private.require_completed_participant('profile_id');
create trigger fieldrush_member_account_reactivation before update of left_at, profile_id on public.clan_members
  for each row when (new.left_at is null and (old.left_at is not null or old.profile_id <> new.profile_id))
  execute function fieldrush_private.require_completed_participant('profile_id');
create trigger fieldrush_join_request_account before insert on public.clan_join_requests
  for each row execute function fieldrush_private.require_completed_participant('profile_id');
create trigger fieldrush_follow_account before insert on public.profile_follows
  for each row execute function fieldrush_private.require_completed_participant('follower_id');
create trigger fieldrush_checkout_account before insert on public.tap_payment_intents
  for each row execute function fieldrush_private.require_completed_participant('profile_id');

create policy "Fieldrush avatar writes require an active account" on storage.objects
  as restrictive for all to authenticated
  using (bucket_id <> 'profile-avatars' or public.is_fieldrush_account_active(auth.uid()))
  with check (bucket_id <> 'profile-avatars' or public.is_fieldrush_account_active(auth.uid()));

-- Public profiles are discoverable only after completion. Owners can still see
-- their own legacy row while moving through the new onboarding requirements.
drop policy "Profiles are readable by authenticated users" on public.profiles;
create policy "Completed Fieldrush profiles are readable" on public.profiles
  for select to authenticated using (account_deleted_at is null
    and (id = auth.uid() or public.is_fieldrush_account_active(id)));

create function fieldrush_private.assert_deletion_ready(caller uuid)
returns void language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private
as $$
begin
  -- Called again inside Auth's final deletion transaction, not just prepare.
  -- Participation inserts share this account lock. Wallet mutations also share
  -- it below, closing the prepare -> Storage -> Auth credit race.
  perform 1 from fieldrush_private.accounts where user_id = caller for update;
  perform 1 from public.field_wallet_accounts where profile_id = caller for update;
  perform 1 from public.tap_payment_intents where profile_id = caller for update;
  perform 1 from public.match_resolution_refunds where recipient_profile_id = caller for update;
  if exists (select 1 from public.referee_profiles where profile_id = caller) then
    raise exception 'Contact support to remove your staff access before deleting your account.' using errcode = '22023';
  end if;
  if exists (select 1 from public.clan_members cm join public.clans c on c.id = cm.clan_id
    where cm.profile_id = caller and cm.role in ('owner', 'captain') and cm.left_at is null and c.archived_at is null) then
    raise exception 'Transfer clan ownership or archive your clan before deleting your account.' using errcode = '22023';
  end if;
  if exists (select 1 from public.open_queue_bookings b join public.open_queue_games g on g.id = b.game_id
    where b.profile_id = caller and b.status = 'CONFIRMED' and g.status not in ('FINAL', 'CANCELLED'))
    or exists (select 1 from public.clan_members cm join public.fixtures f
      on cm.clan_id in (f.home_clan_id, f.away_clan_id)
      where cm.profile_id = caller and cm.left_at is null and f.status not in ('FINAL', 'CANCELLED')) then
    raise exception 'Resolve your active games before deleting your account. Contact support if a past game is still open.' using errcode = '22023';
  end if;
  if exists (select 1 from public.field_wallet_accounts where profile_id = caller and balance_fils <> 0)
    or exists (select 1 from public.tap_payment_intents where profile_id = caller and status in ('PENDING', 'CAPTURED', 'REQUIRES_REFUND'))
    or exists (select 1 from public.match_resolution_refunds where recipient_profile_id = caller and status in ('PENDING', 'FAILED')) then
    raise exception 'Contact support to settle your wallet, payment or refund before deleting your account.' using errcode = '22023';
  end if;
end;
$$;

create function public.prepare_fieldrush_account_deletion()
returns void language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private
as $$
declare caller uuid := fieldrush_private.require_user(); recent_auth boolean;
begin
  -- iat is refreshed automatically; AMR records actual authentication instead.
  select exists (select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr', '[]'::jsonb)) amr
    where amr->>'method' in ('otp', 'oauth')
      and (amr->>'timestamp') ~ '^[0-9]+$'
      and to_timestamp((amr->>'timestamp')::bigint) between now() - interval '10 minutes' and now() + interval '1 minute')
    into recent_auth;
  if not recent_auth then
    raise exception 'Verify a new login code before deleting your account.' using errcode = '42501';
  end if;
  insert into fieldrush_private.accounts (user_id) values (caller) on conflict do nothing;
  perform fieldrush_private.assert_deletion_ready(caller);
  update fieldrush_private.accounts set status = 'deletion_pending', updated_at = now() where user_id = caller;
end;
$$;

-- Refunds are allowed while deletion is pending; the final check then refuses
-- deletion until they are settled. Once deleted, credit must fail for manual
-- resolution instead of silently leaving inaccessible money on a tombstone.
create function fieldrush_private.serialize_wallet_with_deletion()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_private
as $$
begin
  perform 1 from fieldrush_private.accounts where user_id = new.profile_id for share;
  if exists (select 1 from public.profiles where id = new.profile_id and account_deleted_at is not null) then
    raise exception 'This account was deleted. Resolve the payment directly with support.' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger fieldrush_wallet_deletion_guard before insert or update on public.field_wallet_accounts
  for each row execute function fieldrush_private.serialize_wallet_with_deletion();

-- This trigger runs in the Auth deletion transaction. Match/payment history
-- keeps only the anonymous profile key; direct identifiers are removed.
create function fieldrush_private.anonymize_deleted_user()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private
as $$
begin
  perform fieldrush_private.assert_deletion_ready(old.id);
  update public.profiles set auth_user_id = null, phone = null, display_name = 'Deleted player',
    username = null, bio = '', avatar_url = null, date_of_birth = null,
    account_deleted_at = now() where id = old.id;
  delete from public.profile_follows where follower_id = old.id or following_id = old.id;
  delete from public.profile_highlights where profile_id = old.id;
  update public.clan_members set left_at = coalesce(left_at, now()), removal_reason = coalesce(removal_reason, 'LEFT')
    where profile_id = old.id;
  delete from public.profile_career_entries where profile_id = old.id;
  delete from public.profile_settings where profile_id = old.id;
  update public.referee_profiles set is_active = false where profile_id = old.id;
  return old;
end;
$$;
create trigger fieldrush_anonymize_deleted_user before delete on auth.users
  for each row execute function fieldrush_private.anonymize_deleted_user();

-- Keep operational phone contact synchronized only after Auth confirms it.
-- The value remains excluded from authenticated public-profile SELECT grants.
create function fieldrush_private.sync_verified_phone()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public
as $$
begin
  if new.phone_confirmed_at is not null and nullif(new.phone, '') is not null then
    update public.profiles set phone = '+' || ltrim(new.phone, '+') where id = new.id;
  end if;
  return new;
end;
$$;
create trigger fieldrush_sync_verified_phone after update of phone, phone_confirmed_at on auth.users
  for each row execute function fieldrush_private.sync_verified_phone();

-- Reject otherwise-unexpired JWTs once Auth has deleted the account. This
-- hook applies to REST/RPC calls (Storage validates ownership separately).
create function public.fieldrush_check_active_user()
returns void language plpgsql security definer
set search_path = pg_catalog, public, auth, fieldrush_private
as $$
begin
  if auth.uid() is not null and auth.role() = 'authenticated' then
    perform fieldrush_private.require_user();
  end if;
end;
$$;
do $$
begin
  if exists (select 1 from pg_roles r, unnest(r.rolconfig) setting
    where r.rolname = 'authenticator' and setting like 'pgrst.db_pre_request=%'
      and setting not in ('pgrst.db_pre_request=', 'pgrst.db_pre_request=public.fieldrush_check_active_user')) then
    raise exception 'An existing REST pre-request hook must be composed with fieldrush_check_active_user before applying this migration.';
  end if;
  alter role authenticator set pgrst.db_pre_request = 'public.fieldrush_check_active_user';
end;
$$;

-- No default PUBLIC execution on any privileged function, including helpers.
revoke all on all functions in schema fieldrush_private from public, anon, authenticated;
revoke all on function public.get_my_fieldrush_account(), public.save_fieldrush_onboarding_draft(jsonb),
  public.complete_fieldrush_onboarding(jsonb,text,text), public.check_fieldrush_username(text),
  public.update_my_fieldrush_account(jsonb), public.complete_fieldrush_tour(),
  public.is_fieldrush_account_active(uuid), public.prepare_fieldrush_account_deletion(),
  public.fieldrush_check_active_user() from public, anon, authenticated;
grant execute on function public.get_my_fieldrush_account(), public.save_fieldrush_onboarding_draft(jsonb),
  public.complete_fieldrush_onboarding(jsonb,text,text), public.check_fieldrush_username(text),
  public.update_my_fieldrush_account(jsonb), public.complete_fieldrush_tour(),
  public.is_fieldrush_account_active(uuid), public.prepare_fieldrush_account_deletion(),
  public.fieldrush_check_active_user() to authenticated;
grant execute on function public.fieldrush_check_active_user() to anon, service_role;
notify pgrst, 'reload config';
notify pgrst, 'reload schema';
