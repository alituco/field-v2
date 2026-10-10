-- Fixtures use column-level grants so clan reliability deposits remain
-- private. Match-resolution status is public match metadata and must be
-- readable by signed-in clients that load fixture cards and details.

grant select (
  operational_state,
  operational_state_updated_at,
  operational_reason_code
) on table public.fixtures to authenticated;

do $$
begin
  if not has_column_privilege(
    'authenticated',
    'public.fixtures',
    'operational_state',
    'SELECT'
  ) or not has_column_privilege(
    'authenticated',
    'public.fixtures',
    'operational_state_updated_at',
    'SELECT'
  ) or not has_column_privilege(
    'authenticated',
    'public.fixtures',
    'operational_reason_code',
    'SELECT'
  ) then
    raise exception
      'Authenticated fixture browsing cannot read operational match state.';
  end if;

  if has_column_privilege(
    'authenticated',
    'public.fixtures',
    'home_reliability_deposit_fils',
    'SELECT'
  ) or has_column_privilege(
    'authenticated',
    'public.fixtures',
    'away_reliability_deposit_fils',
    'SELECT'
  ) then
    raise exception 'Clan reliability deposit columns must remain private.';
  end if;
end;
$$;
