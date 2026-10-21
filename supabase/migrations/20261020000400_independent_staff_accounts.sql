-- Staff identities are independent email sign-ins. Preserve every stable
-- operational staff key and historical assignment; no player is moved, renamed,
-- reset, deleted, or silently converted into a staff-only Auth account.
alter table public.referee_profiles drop constraint referee_profiles_profile_id_fkey;
alter table public.referee_profiles drop constraint referee_profiles_active_phone_required;
alter table public.referee_profiles
  add column auth_user_id uuid unique references auth.users(id) on delete set null,
  add column email text unique check(email is null or (email=lower(btrim(email)) and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')),
  add constraint referee_profiles_independent_binding check((auth_user_id is null)=(email is null));
comment on column public.referee_profiles.auth_user_id is
  'Independent staff-only email identity. NULL means a retained staff record awaiting explicit operator binding; profile_id is an operational staff key, never a player login.';

create function fieldrush_private.is_staff_auth_user(user_id_to_check uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from auth.users where id=user_id_to_check
    and raw_app_meta_data->>'fieldrush_account_type'='staff')
    or exists(select 1 from public.referee_profiles where auth_user_id=user_id_to_check);
$$;
create function fieldrush_private.staff_identity_is_active(staff_id_to_check uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from public.referee_profiles s join auth.users u on u.id=s.auth_user_id
    where s.profile_id=staff_id_to_check and s.is_active and s.email=lower(u.email)
      and u.raw_app_meta_data->>'fieldrush_account_type'='staff' and u.email_confirmed_at is not null
      and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now())
      and not exists(select 1 from auth.identities where user_id=u.id and provider<>'email'));
$$;
create function public.current_fieldrush_staff_id()
returns uuid language sql stable security definer set search_path=pg_catalog,public,auth,fieldrush_private as $$
  select profile_id from public.referee_profiles where auth_user_id=auth.uid()
    and fieldrush_private.staff_identity_is_active(profile_id);
$$;
revoke all on function public.current_fieldrush_staff_id() from public,anon;
grant execute on function public.current_fieldrush_staff_id() to authenticated,service_role;
create or replace function public.is_active_moderation_admin(profile_id_to_check uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,fieldrush_private as $$
  select exists(select 1 from public.referee_profiles where profile_id=profile_id_to_check and role='admin'
    and fieldrush_private.staff_identity_is_active(profile_id)
    and (auth.role()='service_role' or public.current_fieldrush_staff_id()=profile_id_to_check));
$$;
create or replace function public.referee_can_manage_reliability_match(actor_referee_id uuid,match_kind_to_use text,match_id_to_use uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,fieldrush_private as $$
  select exists(select 1 from public.referee_profiles r where r.profile_id=actor_referee_id
    and fieldrush_private.staff_identity_is_active(r.profile_id)
    and (auth.role()='service_role' or public.current_fieldrush_staff_id()=actor_referee_id)
    and (r.role='admin'
      or (upper(match_kind_to_use)='SOLO' and exists(select 1 from public.open_queue_referee_assignments where game_id=match_id_to_use and referee_id=r.profile_id))
      or (upper(match_kind_to_use)='CLAN' and exists(select 1 from public.fixture_referee_assignments where fixture_id=match_id_to_use and referee_id=r.profile_id))));
$$;

-- Old player JWTs whose subject happens to equal a retained staff key have no
-- staff permissions. RLS resolves only the independent bound email identity.
drop policy "Referees can read active referee profiles" on public.referee_profiles;
create policy "Referees can read active referee profiles" on public.referee_profiles for select to authenticated
  using(is_active and public.current_fieldrush_staff_id() is not null);
drop policy "Referees can read their own assignments" on public.fixture_referee_assignments;
create policy "Referees can read their own assignments" on public.fixture_referee_assignments for select to authenticated
  using(referee_id=public.current_fieldrush_staff_id() or exists(select 1 from public.referee_profiles
    where profile_id=public.current_fieldrush_staff_id() and role='admin' and is_active));
drop policy "Referees can read their own Open Queue assignments" on public.open_queue_referee_assignments;
create policy "Referees can read their own Open Queue assignments" on public.open_queue_referee_assignments for select to authenticated
  using(referee_id=public.current_fieldrush_staff_id() or exists(select 1 from public.referee_profiles
    where profile_id=public.current_fieldrush_staff_id() and role='admin' and is_active));

-- The discriminator is server-owned app metadata, never user metadata. Staff
-- cannot acquire a player profile, wallet, onboarding account or rating seed.
create function fieldrush_private.guard_staff_auth_identity()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth,fieldrush_private as $$
begin
  if tg_op='UPDATE' and old.raw_app_meta_data->>'fieldrush_account_type' is distinct from 'staff'
    and new.raw_app_meta_data->>'fieldrush_account_type'='staff' then
    raise exception 'Create a new independent staff email sign-in; do not convert a player identity.' using errcode='22023';
  end if;
  if tg_op='UPDATE' and old.raw_app_meta_data->>'fieldrush_account_type'='staff'
    and new.raw_app_meta_data->>'fieldrush_account_type' is distinct from 'staff' then
    raise exception 'A staff sign-in cannot be converted into a player sign-in.' using errcode='22023';
  end if;
  if tg_op='UPDATE' and old.raw_app_meta_data->>'fieldrush_account_type'='staff'
    and lower(new.email) is distinct from lower(old.email)
    and exists(select 1 from public.referee_profiles where auth_user_id=old.id) then
    raise exception 'Bound staff email changes require audited staff administration.' using errcode='22023';
  end if;
  if new.raw_app_meta_data->>'fieldrush_account_type'='staff' then
    if new.email is null or nullif(new.phone,'') is not null or exists(select 1 from public.profiles where id=new.id or auth_user_id=new.id)
      or exists(select 1 from fieldrush_private.accounts where user_id=new.id) then
      raise exception 'Staff email sign-ins must be independent of player accounts.' using errcode='22023';
    end if;
  end if;
  return new;
end $$;
create trigger fieldrush_guard_staff_auth_identity before insert or update on auth.users
  for each row execute function fieldrush_private.guard_staff_auth_identity();
create function fieldrush_private.guard_staff_linked_identity()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth,fieldrush_private as $$
begin
  if fieldrush_private.is_staff_auth_user(new.user_id) and new.provider<>'email' then
    raise exception 'Staff sign-ins support email codes only; player identity providers cannot be linked.' using errcode='22023';
  end if;
  if new.provider='email' and exists(select 1 from public.referee_profiles s
    where s.email=lower(new.identity_data->>'email') and s.auth_user_id is distinct from new.user_id) then
    raise exception 'This email belongs to an independent staff sign-in.' using errcode='22023';
  end if;
  return new;
end $$;
create trigger fieldrush_guard_staff_linked_identity before insert or update on auth.identities
  for each row execute function fieldrush_private.guard_staff_linked_identity();
create function fieldrush_private.reject_staff_player_record()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private as $$
declare user_id_to_check uuid;
begin
  if tg_table_name='accounts' then user_id_to_check:=new.user_id;
  else user_id_to_check:=coalesce(new.auth_user_id,new.id); end if;
  if fieldrush_private.is_staff_auth_user(user_id_to_check) then
    raise exception 'Use a separate player sign-in for the Fieldrush app.' using errcode='42501';
  end if;
  return new;
end $$;
create trigger fieldrush_no_staff_player_profile before insert or update on public.profiles
  for each row execute function fieldrush_private.reject_staff_player_record();
create trigger fieldrush_no_staff_player_account before insert or update on fieldrush_private.accounts
  for each row execute function fieldrush_private.reject_staff_player_record();

do $migration$
declare d text; anchor text; item record;
begin
  d:=pg_get_functiondef('fieldrush_private.require_user()'::regprocedure);
  anchor:='  return caller;';
  if position(anchor in d)=0 then raise exception 'Player identity guard changed.'; end if;
  execute replace(d,anchor,E'  if fieldrush_private.is_staff_auth_user(caller) then raise exception ''Use a separate player sign-in for the Fieldrush app.'' using errcode=''42501''; end if;\n'||anchor);
  d:=pg_get_functiondef('fieldrush_rating_private.mark_season_zero_initialization_eligible()'::regprocedure);
  anchor:='  insert into fieldrush_rating_private.season_zero_initialization_eligibility(user_id)';
  if position(anchor in d)=0 then raise exception 'Auth rating initialization trigger changed.'; end if;
  execute replace(d,anchor,E'  if new.raw_app_meta_data->>''fieldrush_account_type''=''staff'' then return new; end if;\n'||anchor);

  d:=pg_get_functiondef('fieldrush_private.assert_deletion_ready(uuid)'::regprocedure);
  anchor:=$old$  perform 1 from public.referee_profiles where profile_id = caller for update;
  if exists (select 1 from public.referee_profiles where profile_id = caller and is_active) then
    raise exception 'Contact support to remove your staff access before deleting your account.' using errcode = '22023';
  end if;$old$;
  if position(anchor in d)=0 then raise exception 'Shared staff deletion guard changed.'; end if;
  d:=replace(d,anchor,E'  if fieldrush_private.is_staff_auth_user(caller) then raise exception ''Staff sign-ins use the staff offboarding flow.'' using errcode=''42501''; end if;');
  execute d;
  d:=pg_get_functiondef('fieldrush_private.anonymize_deleted_user()'::regprocedure);
  anchor:=$old$  update public.referee_profiles set is_active = false, display_name = 'Deleted staff', phone = null
    where profile_id = old.id;$old$;
  if position(anchor in d)=0 then raise exception 'Shared staff anonymization changed.'; end if;
  d:=replace(d,anchor,'  -- Player deletion never changes independent staff access.');
  anchor:='  perform fieldrush_private.assert_deletion_ready(old.id);';
  if position(anchor in d)=0 then raise exception 'Auth deletion guard changed.'; end if;
  d:=replace(d,anchor,$new$  if old.raw_app_meta_data->>'fieldrush_account_type'='staff' then
    perform pg_advisory_xact_lock(hashtextextended('fieldrush-staff-offboarding',0));
    perform 1 from public.referee_profiles where auth_user_id=old.id for update;
    if exists(select 1 from public.referee_profiles where auth_user_id=old.id and is_active) then
      raise exception 'Remove staff access before deleting this staff sign-in.' using errcode='22023';
    end if;
    update public.referee_profiles set auth_user_id=null,email=null,phone=null,display_name='Deleted staff'
      where auth_user_id=old.id;
    return old;
  end if;
  perform fieldrush_private.assert_deletion_ready(old.id);$new$);
  execute d;
end $migration$;

alter table public.fixtures add column cancelled_by_staff_id uuid references public.referee_profiles(profile_id) on delete restrict;
alter table public.open_queue_games add column cancelled_by_staff_id uuid references public.referee_profiles(profile_id) on delete restrict;
-- Captain cancellations and referee-attributed forfeits share this append-only
-- ledger. Keep historical/player actors intact and separate new staff actors.
alter table public.clan_fixture_cancellations alter column cancelled_by drop not null;
alter table public.clan_fixture_cancellations add column cancelled_by_staff_id uuid references public.referee_profiles(profile_id) on delete restrict;
alter table public.clan_fixture_cancellations add constraint clan_fixture_cancellation_actor_required check (
  (cancelled_by is not null)::integer+(cancelled_by_staff_id is not null)::integer=1
);
do $migration$
declare d text; anchor text:='      cancelled_by,';
begin
  d:=pg_get_functiondef('public.settle_reviewed_clan_forfeit_reliability(uuid,uuid,boolean,text)'::regprocedure);
  if position(anchor in d)=0 or position('decision_to_settle.created_by,' in d)=0 then
    raise exception 'Reviewed clan forfeit cancellation actor changed.'; end if;
  execute replace(d,anchor,'      cancelled_by_staff_id,');
end $migration$;
do $migration$
declare item record; d text;
begin
  -- These assignments occur only in installed staff/admin cancellation and
  -- correction writers. Captain/player cancellation writers retain their FK.
  for item in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','fieldrush_rating_private') and p.prokind='f'
      and (p.prosrc like '%public.fixtures%' or p.prosrc like '%public.open_queue_games%')
      and (p.prosrc like '%cancelled_by = actor_admin_id%' or p.prosrc like '%cancelled_by = actor_referee_id%'
        or p.prosrc like '%cancelled_by = null,%')
  loop
    d:=pg_get_functiondef(item.oid);
    d:=replace(d,'cancelled_by = null,','cancelled_by = null, cancelled_by_staff_id = null,');
    d:=replace(d,'cancelled_by = actor_admin_id,','cancelled_by = null, cancelled_by_staff_id = actor_admin_id,');
    d:=replace(d,'cancelled_by = actor_referee_id,','cancelled_by = null, cancelled_by_staff_id = actor_referee_id,');
    execute d;
  end loop;
end $migration$;

-- Explicit staff actor references can stand alone without a dummy player row.
do $migration$
declare item record; existing_constraint text;
begin
  for item in select * from (values
    ('fieldrush_rating_private.season_zero_activation','changed_by'),
    ('fieldrush_rating_private.season_zero_matches','adjudicated_by'),
    ('fieldrush_rating_private.season_zero_match_revisions','actor_id'),
    ('fieldrush_rating_private.season_zero_action_requests','actor_id'),
    ('fieldrush_rating_private.season_zero_settlement_runs','actor_id'),
    ('fieldrush_rating_private.solo_goal_operations','actor_id'),
    ('public.broadcast_device_credentials','owner_profile_id'),
    ('public.broadcast_pairing_codes','owner_profile_id'),
    ('public.fixture_broadcasts','created_by'),
    ('public.open_queue_broadcasts','created_by'),
    ('public.broadcast_commands','requested_by')
  ) v(relation,column_name) loop
    select c.conname into existing_constraint from pg_constraint c join pg_attribute a
      on a.attrelid=c.conrelid and a.attnum=any(c.conkey)
      where c.contype='f' and c.conrelid=item.relation::regclass and c.confrelid='public.profiles'::regclass and a.attname=item.column_name;
    if existing_constraint is null then raise exception 'Staff actor FK changed: %.%',item.relation,item.column_name; end if;
    execute format('alter table %s drop constraint %I',item.relation,existing_constraint);
    execute format('alter table %s add constraint %I foreign key(%I) references public.referee_profiles(profile_id) on delete restrict',
      item.relation,existing_constraint,item.column_name);
  end loop;
end $migration$;

-- Administrative alerts belong to staff, never a same-ID player inbox.
create table public.staff_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_profile_id uuid not null references public.referee_profiles(profile_id) on delete restrict,
  type text not null, title text not null, body text not null,
  related_entity_type text, related_entity_id uuid, data jsonb not null default '{}',
  read_at timestamptz, created_at timestamptz not null default now()
);
alter table public.staff_notifications enable row level security;
revoke all on public.staff_notifications from public,anon,authenticated;
grant all on public.staff_notifications to service_role;
do $migration$
declare d text; anchor text;
begin
  d:=pg_get_functiondef('public.submit_match_resolution_dispute(uuid,text)'::regprocedure);
  anchor:='  insert into public.notifications (';
  if position(anchor in d)=0 or position('from public.referee_profiles admin' in d)=0 then
    raise exception 'Staff dispute notification writer changed.'; end if;
  execute replace(d,anchor,'  insert into public.staff_notifications (');
end $migration$;

-- Game creation has a historically mixed player actor column. Preserve it and
-- write new staff-created games to a distinct staff FK instead of rewriting it.
alter table public.open_queue_games add column created_by_staff_id uuid references public.referee_profiles(profile_id) on delete restrict;
do $migration$
declare d text; anchor text; signature text;
begin
  foreach signature in array array[
    'public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer,integer,integer,integer,integer,integer)',
    'fieldrush_private.generate_game_schedule(uuid)'
  ] loop
    d:=pg_get_functiondef(signature::regprocedure);
    anchor:='age_label,created_by,';
    if position(anchor in d)=0 then raise exception 'Staff game creation actor changed: %',signature; end if;
    execute replace(d,anchor,'age_label,created_by_staff_id,');
  end loop;
  d:=pg_get_functiondef('public.get_match_reliability_context(text,uuid)'::regprocedure);
  anchor:=$old$        caller_id,
        normalized_kind,$old$;
  if position(anchor in d)=0 then raise exception 'Authenticated match roster authority changed.'; end if;
  execute replace(d,anchor,$new$        public.current_fieldrush_staff_id(),
        normalized_kind,$new$);
  d:=pg_get_functiondef('public.broadcast_match_context(uuid,text,uuid,boolean)'::regprocedure);
  anchor:='where profile_id=actor_id and is_active';
  if position(anchor in d)=0 then raise exception 'Broadcast staff authority changed.'; end if;
  execute replace(d,anchor,anchor||' and fieldrush_private.staff_identity_is_active(profile_id)');
end $migration$;

create function fieldrush_private.validate_independent_staff_auth(target_auth_user_id uuid,expected_email text)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth,fieldrush_private as $$
declare identity auth.users%rowtype;
begin
  if expected_email is null or expected_email<>lower(btrim(expected_email)) or expected_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Use an exact normalized staff email.' using errcode='22023'; end if;
  select * into identity from auth.users where id=target_auth_user_id for share;
  if identity.id is null or identity.deleted_at is not null or (identity.banned_until is not null and identity.banned_until>now())
    or lower(identity.email) is distinct from expected_email or identity.raw_app_meta_data->>'fieldrush_account_type' is distinct from 'staff'
    or nullif(identity.phone,'') is not null or exists(select 1 from public.profiles where id=identity.id or auth_user_id=identity.id)
    or exists(select 1 from fieldrush_private.accounts where user_id=identity.id)
    or exists(select 1 from auth.identities where user_id=identity.id and provider<>'email') then
    raise exception 'Choose an independent staff-only email sign-in, not a player account.' using errcode='22023'; end if;
end $$;

create function public.admin_grant_independent_staff(actor_admin_id uuid,target_auth_user_id uuid,expected_email text,
  display_name_to_use text,role_to_use text,existing_staff_profile_id uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,fieldrush_private as $$
declare staff public.referee_profiles%rowtype; before_state jsonb; already_active boolean:=false;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Staff administration service required.' using errcode='42501'; end if;
  if current_setting('transaction_isolation')<>'read committed' then raise exception 'Staff provisioning requires read committed.' using errcode='22023'; end if;
  if role_to_use is null or role_to_use not in ('admin','referee') or char_length(btrim(coalesce(display_name_to_use,''))) not between 2 and 50
    or display_name_to_use~'[[:cntrl:]]' then raise exception 'Provide a staff name and valid role.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-staff-offboarding',0));
  perform fieldrush_private.validate_independent_staff_auth(target_auth_user_id,expected_email);
  perform 1 from public.referee_profiles where profile_id=actor_admin_id for update;
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Active bound administrator access required.' using errcode='42501'; end if;
  if existing_staff_profile_id is not null then
    select * into staff from public.referee_profiles where profile_id=existing_staff_profile_id for update;
    if staff.profile_id is null or staff.role is distinct from role_to_use or staff.display_name is distinct from btrim(display_name_to_use)
      or (staff.auth_user_id is not null and staff.auth_user_id is distinct from target_auth_user_id) then
      raise exception 'The retained staff identity changed. Refresh the staff directory.' using errcode='22023'; end if;
    if not staff.is_active then
      raise exception 'Inactive staff access cannot receive a new email binding.' using errcode='22023'; end if;
    before_state:=jsonb_build_object('profile_id',staff.profile_id,'role',staff.role,'is_active',staff.is_active,'bound',staff.auth_user_id is not null);
    already_active:=staff.auth_user_id=target_auth_user_id and staff.email=expected_email and staff.is_active;
    update public.referee_profiles set auth_user_id=target_auth_user_id,email=expected_email where profile_id=staff.profile_id returning * into staff;
  else
    select * into staff from public.referee_profiles where auth_user_id=target_auth_user_id for update;
    if found then
      if not staff.is_active then
        raise exception 'Inactive staff access cannot receive a new email binding.' using errcode='22023'; end if;
      if staff.role<>role_to_use or staff.email<>expected_email or staff.display_name<>btrim(display_name_to_use) then
        raise exception 'Existing staff changes require a separate audited flow.' using errcode='22023'; end if;
      already_active:=staff.is_active;
    else
      insert into public.referee_profiles(profile_id,auth_user_id,email,display_name,phone,role,is_active)
        values(gen_random_uuid(),target_auth_user_id,expected_email,btrim(display_name_to_use),null,role_to_use,true) returning * into staff;
    end if;
  end if;
  if not coalesce(already_active,false) then
    insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
      values(actor_admin_id,'INDEPENDENT_STAFF_BOUND','ACTION',staff.profile_id,'Administrator provisioned an independent email staff sign-in.',
        coalesce(before_state,'{}'),jsonb_build_object('profile_id',staff.profile_id,'role',staff.role,'is_active',staff.is_active,'bound',true));
  end if;
  return jsonb_build_object('staff',to_jsonb(staff),'already_active',coalesce(already_active,false));
end $$;
revoke all on function public.admin_grant_independent_staff(uuid,uuid,text,text,text,uuid) from public,anon,authenticated;
grant execute on function public.admin_grant_independent_staff(uuid,uuid,text,text,text,uuid) to service_role;

-- Manual service/operator bootstrap only. The web never calls this endpoint.
-- No pending historical role is changed, and exact retries recover safely.
create function public.bootstrap_independent_staff_admin(target_staff_profile_id uuid,target_auth_user_id uuid,expected_email text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,fieldrush_private as $$
declare staff public.referee_profiles%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Manual staff bootstrap requires the staff administration service.' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-staff-offboarding',0));
  perform fieldrush_private.validate_independent_staff_auth(target_auth_user_id,expected_email);
  select * into staff from public.referee_profiles where profile_id=target_staff_profile_id for update;
  if staff.profile_id is null or staff.role<>'admin' or not staff.is_active then
    raise exception 'Choose an exact retained active administrator for manual bootstrap.' using errcode='22023'; end if;
  if exists(select 1 from public.referee_profiles where is_active and role='admin' and auth_user_id is not null
    and (profile_id<>target_staff_profile_id or auth_user_id<>target_auth_user_id or email<>expected_email)) then
    raise exception 'An administrator is already bound. Use normal staff administration.' using errcode='22023'; end if;
  if staff.auth_user_id is not null then
    if staff.auth_user_id=target_auth_user_id and staff.email=expected_email then
      return jsonb_build_object('staff',to_jsonb(staff),'already_active',true); end if;
    raise exception 'The chosen administrator already has another staff sign-in.' using errcode='22023';
  end if;
  update public.referee_profiles set auth_user_id=target_auth_user_id,email=expected_email where profile_id=staff.profile_id returning * into staff;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,after_state)
    values(staff.profile_id,'INDEPENDENT_STAFF_BOOTSTRAP','ACTION',staff.profile_id,'Operator bound the first independent administrator email sign-in.',
      jsonb_build_object('profile_id',staff.profile_id,'role',staff.role,'bound',true));
  return jsonb_build_object('staff',to_jsonb(staff),'already_active',false);
end $$;
revoke all on function public.bootstrap_independent_staff_admin(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.bootstrap_independent_staff_admin(uuid,uuid,text) to service_role;

-- The former phone grant cannot recreate the coupling through an old client.
create or replace function public.admin_grant_fieldrush_staff(actor_admin_id uuid,target_profile_id uuid,expected_phone text,display_name_to_use text,role_to_use text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
begin raise exception 'Use independent email staff provisioning.' using errcode='22023'; end $$;
revoke all on function public.admin_grant_fieldrush_staff(uuid,uuid,text,text,text) from public,anon,authenticated,service_role;

-- Retain existing offboarding, last-admin and unfinished-assignment guards,
-- adding the independent authentication condition to their authority checks.
do $migration$
declare d text; anchor text; item record;
begin
  d:=pg_get_functiondef('public.admin_offboard_fieldrush_staff(uuid,uuid,text)'::regprocedure);
  anchor:='actor.profile_id is null or actor.role <> ''admin'' or not actor.is_active';
  if position(anchor in d)=0 then raise exception 'Offboarding authority guard changed.'; end if;
  d:=replace(d,anchor,anchor||' or not fieldrush_private.staff_identity_is_active(actor.profile_id)');
  anchor:='where role = ''admin'' and is_active and profile_id <> target.profile_id';
  if position(anchor in d)=0 then raise exception 'Last administrator guard changed.'; end if;
  d:=replace(d,anchor,anchor||' and fieldrush_private.staff_identity_is_active(profile_id)');
  execute d;
  d:=pg_get_functiondef('fieldrush_private.require_active_assigned_staff()'::regprocedure);
  anchor:='select is_active into staff_active from public.referee_profiles';
  if position(anchor in d)=0 then raise exception 'Assignment staff guard changed.'; end if;
  execute replace(d,anchor,'select is_active and fieldrush_private.staff_identity_is_active(profile_id) into staff_active from public.referee_profiles');
  -- A few older report/safety writers check a staff row directly instead of
  -- the shared authorization helpers. Pending legacy identities cannot act
  -- through those service entry points either.
  for item in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','fieldrush_rating_private') and p.prokind='f'
      and p.prosrc like '%from public.referee_profiles referee%'
      and p.prosrc like '%and referee.is_active%'
  loop
    d:=pg_get_functiondef(item.oid);
    execute replace(d,'and referee.is_active','and referee.is_active and fieldrush_private.staff_identity_is_active(referee.profile_id)');
  end loop;
end $migration$;

revoke all on function fieldrush_private.is_staff_auth_user(uuid),fieldrush_private.staff_identity_is_active(uuid),
  fieldrush_private.guard_staff_auth_identity(),fieldrush_private.guard_staff_linked_identity(),fieldrush_private.reject_staff_player_record(),
  fieldrush_private.validate_independent_staff_auth(uuid,text)
from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
