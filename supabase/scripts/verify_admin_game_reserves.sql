begin;

do $verify$
declare
  reserve_table regclass := to_regclass('public.match_reserve_assignments');
  rls_enabled boolean;
  authenticated_privileges integer;
begin
  if reserve_table is null then
    raise exception 'Missing match_reserve_assignments table.';
  end if;

  select class.relrowsecurity into rls_enabled
  from pg_class class
  where class.oid = reserve_table;
  if not coalesce(rls_enabled, false) then
    raise exception 'Reserve assignments must have RLS enabled.';
  end if;

  if to_regprocedure(
    'public.admin_assign_match_reserve(uuid,text,uuid,uuid,text,text)'
  ) is null then
    raise exception 'Missing audited reserve assignment RPC.';
  end if;
  if to_regprocedure(
    'public.admin_remove_match_reserve(uuid,uuid,text)'
  ) is null then
    raise exception 'Missing audited reserve removal RPC.';
  end if;

  if to_regclass('public.match_reserve_active_fixture_side_idx') is null
    or to_regclass('public.match_reserve_active_solo_side_idx') is null
  then
    raise exception 'Each match side must be limited to one active reserve.';
  end if;

  select count(*) into authenticated_privileges
  from information_schema.role_table_grants grant_row
  where grant_row.table_schema = 'public'
    and grant_row.table_name = 'match_reserve_assignments'
    and grant_row.grantee in ('anon', 'authenticated');
  if authenticated_privileges <> 0 then
    raise exception 'Reserve assignments must stay private to service-role admin APIs.';
  end if;
end;
$verify$;

rollback;
