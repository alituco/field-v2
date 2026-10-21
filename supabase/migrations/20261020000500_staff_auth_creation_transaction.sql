-- GoTrue admin creation inserts the email user, then updates app metadata in
-- the SAME transaction. Permit that initialization, never a later conversion.
-- Admission rows are private and removed by a deferred trigger before commit.
create table fieldrush_private.staff_auth_creation_context (
  user_id uuid primary key references auth.users(id) on delete cascade,
  creation_transaction xid8 not null
);
revoke all on fieldrush_private.staff_auth_creation_context from public,anon,authenticated,service_role;

create function fieldrush_private.track_staff_auth_creation()
returns trigger language plpgsql security definer set search_path=pg_catalog,fieldrush_private as $$
begin
  if new.email is not null and nullif(new.phone,'') is null
    and new.raw_app_meta_data->>'fieldrush_account_type' is distinct from 'staff' then
    insert into fieldrush_private.staff_auth_creation_context(user_id,creation_transaction)
      values(new.id,pg_current_xact_id());
  end if;
  return new;
end $$;
create function fieldrush_private.close_staff_auth_creation()
returns trigger language plpgsql security definer set search_path=pg_catalog,fieldrush_private as $$
begin
  delete from fieldrush_private.staff_auth_creation_context where user_id=new.id;
  return new;
end $$;
revoke all on function fieldrush_private.track_staff_auth_creation(),fieldrush_private.close_staff_auth_creation()
  from public,anon,authenticated,service_role;
create trigger fieldrush_track_staff_auth_creation after insert on auth.users
  for each row execute function fieldrush_private.track_staff_auth_creation();
create constraint trigger fieldrush_close_staff_auth_creation after insert on auth.users
  deferrable initially deferred for each row execute function fieldrush_private.close_staff_auth_creation();

create or replace function fieldrush_private.guard_staff_auth_identity()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth,fieldrush_private as $$
begin
  if tg_op='UPDATE' and old.raw_app_meta_data->>'fieldrush_account_type' is distinct from 'staff'
    and new.raw_app_meta_data->>'fieldrush_account_type'='staff' then
    if not exists(select 1 from fieldrush_private.staff_auth_creation_context
      where user_id=new.id and creation_transaction=pg_current_xact_id()) then
      raise exception 'Create a new independent staff email sign-in; do not convert a player identity.' using errcode='22023';
    end if;
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
    if new.email is null or nullif(new.phone,'') is not null
      or exists(select 1 from public.profiles where id=new.id or auth_user_id=new.id)
      or exists(select 1 from fieldrush_private.accounts where user_id=new.id)
      or exists(select 1 from auth.identities where user_id=new.id and provider<>'email') then
      raise exception 'Staff email sign-ins must be independent of player accounts.' using errcode='22023';
    end if;
    -- The initial unmarked INSERT ran the player eligibility trigger. Remove
    -- that unused marker in the same transaction as staff initialization.
    if tg_op='UPDATE' and old.raw_app_meta_data->>'fieldrush_account_type' is distinct from 'staff' then
      delete from fieldrush_rating_private.season_zero_initialization_eligibility where user_id=new.id;
      delete from fieldrush_private.staff_auth_creation_context where user_id=new.id;
    end if;
  end if;
  return new;
end $$;
