-- Staff authority is separate from player identity. The provisioning endpoint
-- must never reset an existing Auth password or overwrite a player's profile.
create function public.admin_grant_fieldrush_staff(
  actor_admin_id uuid,
  target_profile_id uuid,
  expected_phone text,
  display_name_to_use text,
  role_to_use text
)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,auth,fieldrush_private,pg_temp as $$
declare
  actor public.referee_profiles%rowtype;
  staff public.referee_profiles%rowtype;
  identity auth.users%rowtype;
  account_status text;
  before_state jsonb;
  action_to_use text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the staff administration service can grant access.' using errcode='42501';
  end if;
  if current_setting('transaction_isolation')<>'read committed' then
    raise exception 'Staff provisioning requires a read-committed transaction.' using errcode='22023';
  end if;
  if actor_admin_id is null or target_profile_id is null
    or expected_phone is null or expected_phone!~'^\+[1-9][0-9]{7,14}$'
    or role_to_use is null or role_to_use not in ('admin','referee')
    or char_length(btrim(coalesce(display_name_to_use,''))) not between 2 and 50
    or display_name_to_use ~ '[[:cntrl:]]' then
    raise exception 'Provide an exact account, phone, staff name and valid access level.' using errcode='22023';
  end if;

  -- Share offboarding's authority mutex. Auth/account locks precede staff locks,
  -- matching final deletion and preventing phone edits or deletion mid-grant.
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-staff-offboarding',0));
  perform 1 from auth.users where id in (actor_admin_id,target_profile_id) order by id for share;
  if not exists(select 1 from auth.users where id=actor_admin_id and deleted_at is null
    and (banned_until is null or banned_until<=now())) then
    raise exception 'Active administrator access is required.' using errcode='42501';
  end if;
  select * into identity from auth.users where id=target_profile_id;
  if identity.id is null or identity.deleted_at is not null
    or (identity.banned_until is not null and identity.banned_until>now())
    or '+'||ltrim(coalesce(identity.phone,''),'+') is distinct from expected_phone then
    raise exception 'The exact phone account changed or is unavailable. Refresh before granting access.' using errcode='22023';
  end if;
  select status into account_status from fieldrush_private.accounts
    where user_id=target_profile_id for share;
  if account_status='deletion_pending' or exists(select 1 from public.profiles
    where id=target_profile_id and account_deleted_at is not null) then
    raise exception 'An account pending deletion cannot receive staff access.' using errcode='22023';
  end if;
  perform 1 from public.referee_profiles where profile_id in (actor_admin_id,target_profile_id)
    order by profile_id for update;
  select * into actor from public.referee_profiles where profile_id=actor_admin_id;
  if actor.profile_id is null or actor.role<>'admin' or not actor.is_active then
    raise exception 'Active administrator access is required.' using errcode='42501';
  end if;
  select * into staff from public.referee_profiles where profile_id=target_profile_id;
  if staff.profile_id is not null then
    if staff.role is distinct from role_to_use or staff.phone is distinct from expected_phone then
      raise exception 'Existing staff role or phone changes require a separate audited flow.' using errcode='22023';
    end if;
    if staff.is_active then
      return jsonb_build_object('staff',to_jsonb(staff),'already_active',true);
    end if;
    before_state:=jsonb_build_object('profile_id',staff.profile_id,'role',staff.role,'is_active',false);
    update public.referee_profiles set is_active=true where profile_id=target_profile_id returning * into staff;
    action_to_use:='STAFF_REACTIVATED';
  else
    -- Insert only a missing public row. In particular never clear username,
    -- rename a player, replace contact details, or touch private account data.
    insert into public.profiles(id,auth_user_id,display_name,phone)
      values(target_profile_id,target_profile_id,btrim(display_name_to_use),expected_phone)
      on conflict(id) do nothing;
    insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
      values(target_profile_id,btrim(display_name_to_use),expected_phone,role_to_use,true)
      returning * into staff;
    before_state:='{}'::jsonb;
    action_to_use:='STAFF_ACCESS_GRANTED';
  end if;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor.profile_id,action_to_use,'PLAYER',target_profile_id,'Administrator granted staff access.',
      before_state,jsonb_build_object('profile_id',staff.profile_id,'role',staff.role,'is_active',true));
  return jsonb_build_object('staff',to_jsonb(staff),'already_active',false);
end;
$$;
revoke all on function public.admin_grant_fieldrush_staff(uuid,uuid,text,text,text)
  from public,anon,authenticated;
grant execute on function public.admin_grant_fieldrush_staff(uuid,uuid,text,text,text) to service_role;
notify pgrst,'reload schema';
