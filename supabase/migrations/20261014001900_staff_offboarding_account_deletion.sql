-- Retain staff keys used by immutable operational history while allowing an
-- explicitly offboarded staff member to use normal account deletion.
alter table public.referee_profiles alter column phone drop not null;
alter table public.referee_profiles add constraint referee_profiles_active_phone_required
  check (not is_active or phone is not null);

create function public.admin_offboard_fieldrush_staff(
  actor_admin_id uuid,
  target_profile_id uuid,
  reason_to_use text
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  actor public.referee_profiles%rowtype;
  target public.referee_profiles%rowtype;
  before_state jsonb;
  after_state jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the staff administration service can remove staff access.' using errcode = '42501';
  end if;
  -- The assignment check must receive a fresh snapshot after waiting for a
  -- concurrent assignment's staff-row lock. PostgREST already uses this mode.
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'Staff offboarding requires a read-committed transaction.' using errcode = '22023';
  end if;
  if actor_admin_id is null or target_profile_id is null then
    raise exception 'Choose an administrator and the exact staff account.' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(reason_to_use, ''))) not between 10 and 2000 then
    raise exception 'Give a reason of 10 to 2000 characters for removing staff access.' using errcode = '22023';
  end if;

  -- Serialize removals so two administrators cannot each remove the other
  -- while both still appear to be active. Row locks also serialize assignments
  -- and the final account-deletion transaction against this change.
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-staff-offboarding', 0));
  perform 1 from public.referee_profiles
    where profile_id in (actor_admin_id, target_profile_id)
    order by profile_id for update;
  select * into actor from public.referee_profiles where profile_id = actor_admin_id;
  if actor.profile_id is null or actor.role <> 'admin' or not actor.is_active then
    raise exception 'Active administrator access is required.' using errcode = '42501';
  end if;
  select * into target from public.referee_profiles where profile_id = target_profile_id;
  if target.profile_id is null then
    raise exception 'The exact staff account was not found.' using errcode = '22023';
  end if;
  if target.is_active and target.role = 'admin' and not exists (
    select 1 from public.referee_profiles
    where role = 'admin' and is_active and profile_id <> target.profile_id
  ) then
    raise exception 'The last active administrator cannot be offboarded.' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.open_queue_referee_assignments assignment
    join public.open_queue_games game on game.id = assignment.game_id
    where assignment.referee_id = target.profile_id and game.status not in ('FINAL', 'CANCELLED')
  ) or exists (
    select 1 from public.fixture_referee_assignments assignment
    join public.fixtures fixture on fixture.id = assignment.fixture_id
    where assignment.referee_id = target.profile_id and fixture.status not in ('FINAL', 'CANCELLED')
  ) then
    raise exception 'Reassign or resolve every unfinished match before removing this staff account.' using errcode = '22023';
  end if;
  if not target.is_active then
    return jsonb_build_object('profile_id', target.profile_id, 'is_active', false,
      'role', target.role, 'already_inactive', true);
  end if;

  -- The audit keeps authority changes, not a copy of personal contact details.
  before_state := jsonb_build_object('profile_id', target.profile_id,
    'role', target.role, 'is_active', target.is_active);
  update public.referee_profiles set is_active = false where profile_id = target.profile_id;
  after_state := jsonb_build_object('profile_id', target.profile_id,
    'role', target.role, 'is_active', false);
  insert into public.admin_audit_events(
    actor_referee_id, action, entity_type, entity_id, reason, before_state, after_state
  ) values (
    actor.profile_id, 'STAFF_OFFBOARDED', 'PLAYER', target.profile_id,
    btrim(reason_to_use), before_state, after_state
  );
  return after_state || jsonb_build_object('already_inactive', false);
end;
$$;
revoke all on function public.admin_offboard_fieldrush_staff(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.admin_offboard_fieldrush_staff(uuid,uuid,text) to service_role;

create function fieldrush_private.require_active_assigned_staff()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare staff_active boolean;
begin
  -- A new/reassigned match must share the staff row lock until commit. If
  -- offboarding wins the race, this observes inactive staff and rejects it;
  -- if assignment wins, offboarding sees the committed unfinished match.
  select is_active into staff_active from public.referee_profiles
    where profile_id = new.referee_id for share;
  if staff_active is distinct from true then
    raise exception 'An inactive staff account cannot receive a match assignment.' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function fieldrush_private.require_active_assigned_staff()
  from public, anon, authenticated;
create trigger fieldrush_active_solo_referee_assignment
  before insert or update of referee_id on public.open_queue_referee_assignments
  for each row execute function fieldrush_private.require_active_assigned_staff();
create trigger fieldrush_active_clan_referee_assignment
  before insert or update of referee_id on public.fixture_referee_assignments
  for each row execute function fieldrush_private.require_active_assigned_staff();

-- Patch only the staff clause, leaving recent authentication, clan ownership,
-- active games, both wallets, payment and refund readiness checks intact.
do $migration$
declare definition text; old_clause text; new_clause text;
begin
  definition := pg_get_functiondef('fieldrush_private.assert_deletion_ready(uuid)'::regprocedure);
  old_clause := '  if exists (select 1 from public.referee_profiles where profile_id = caller) then';
  new_clause := E'  perform 1 from public.referee_profiles where profile_id = caller for update;\n  if exists (select 1 from public.referee_profiles where profile_id = caller and is_active) then';
  if position(old_clause in definition) = 0 then
    raise exception 'Staff account deletion guard contract changed.';
  end if;
  execute replace(definition, old_clause, new_clause);

  definition := pg_get_functiondef('fieldrush_private.anonymize_deleted_user()'::regprocedure);
  old_clause := '  update public.referee_profiles set is_active = false where profile_id = old.id;';
  new_clause := E'  update public.referee_profiles set is_active = false, display_name = ''Deleted staff'', phone = null\n    where profile_id = old.id;';
  if position(old_clause in definition) = 0 then
    raise exception 'Staff account anonymization contract changed.';
  end if;
  execute replace(definition, old_clause, new_clause);
end;
$migration$;
revoke all on function fieldrush_private.assert_deletion_ready(uuid),
  fieldrush_private.anonymize_deleted_user()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
