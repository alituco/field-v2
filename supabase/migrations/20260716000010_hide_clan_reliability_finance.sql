-- Clan reliability deposits reveal private reliability standing and payment
-- history. Fixtures remain broadly readable, but authenticated clients only
-- receive the established public match columns. Finance is exposed to the
-- paying leader through scoped SECURITY DEFINER quote/cancellation RPCs and
-- to operations through the service-role admin application.

revoke select on table public.fixtures from public, anon, authenticated;

grant select (
  id,
  status,
  home_clan_id,
  away_clan_id,
  venue,
  day,
  time_slot,
  match_date,
  home_score,
  away_score,
  winner_clan_id,
  home_sr_change,
  away_sr_change,
  video_url,
  created_by,
  created_at,
  updated_at,
  cancelled_at,
  cancellation_reason,
  cancellation_code,
  cancelled_by,
  cancellation_context,
  home_paid_by,
  away_paid_by,
  home_paid_at,
  away_paid_at
) on table public.fixtures to authenticated;

grant select on table public.fixtures to service_role;

do $$
begin
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
  if not has_column_privilege(
    'authenticated',
    'public.fixtures',
    'match_date',
    'SELECT'
  ) then
    raise exception 'Authenticated fixture browsing lost its public columns.';
  end if;
end;
$$;

comment on column public.fixtures.home_reliability_deposit_fils is
'Private finance: readable through scoped clan checkout/cancellation RPCs and operations service role only.';
comment on column public.fixtures.away_reliability_deposit_fils is
'Private finance: readable through scoped clan checkout/cancellation RPCs and operations service role only.';
