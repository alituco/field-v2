-- Display the effective rules and the caller's actual attendance findings.
-- This adds read-only metadata; attendance, sanctions and appeals are unchanged.
alter function public.get_my_reliability_status()
  rename to get_my_reliability_status_before_display;
revoke all on function public.get_my_reliability_status_before_display()
  from public,anon,authenticated,service_role;

create function public.get_my_reliability_status()
returns jsonb language plpgsql stable security definer
set search_path=public,pg_temp as $$
declare result jsonb; policy jsonb; incidents jsonb; zone text; checked_at timestamptz;
begin
  -- Retain the existing sign-in boundary and authoritative standing/ledger.
  result:=public.get_my_reliability_status_before_display();
  checked_at:=coalesce((result->>'server_now')::timestamptz,statement_timestamp());
  select p.config into policy from public.reliability_policy_versions p
    where p.id::text=result->>'policy_version_id' and p.state='PUBLISHED';
  select c.timezone into zone from fieldrush_private.accounts a
    join public.fieldrush_cities c on c.id=a.preferred_city_id
    where a.user_id=auth.uid();

  select coalesce(jsonb_agg(item.value||jsonb_build_object(
    'timezone',coalesce(g.timezone,t.policy_snapshot->>'timezone',zone,'UTC'),
    'strike_active',exists(select 1 from public.reliability_incidents i
      where i.attendance_id=a.id and i.profile_id=auth.uid() and i.strike_delta>0
        and i.reversal_of is null and i.occurred_at<=checked_at
        and (i.expires_at is null or i.expires_at>checked_at)
        and not exists(select 1 from public.reliability_incidents r where r.reversal_of=i.id)),
    'original_outcome',case when a.outcome='EXCUSED' or item.value->>'appeal_status'='OVERTURNED' then original.outcome end,
    'original_strike_delta',case when a.outcome='EXCUSED' or item.value->>'appeal_status'='OVERTURNED' then original.strike_delta end,
    'appeal_submitted_at',appeal.created_at,
    'appeal_reviewed_at',appeal.reviewed_at,
    'appeal_resolution_note',appeal.resolution_note
  ) order by item.ordinal),'[]'::jsonb) into incidents
  from jsonb_array_elements(coalesce(result->'incidents','[]'::jsonb))
    with ordinality item(value,ordinal)
  join public.match_attendance_records a
    on a.id::text=item.value->>'attendance_record_id' and a.profile_id=auth.uid()
  join public.match_reliability_terms t on t.id=a.terms_id
  left join public.open_queue_games g on g.id=a.open_queue_game_id
  left join lateral (select i.outcome,i.strike_delta from public.reliability_incidents i
    where i.attendance_id=a.id and i.profile_id=auth.uid() and i.strike_delta>0 and i.reversal_of is null
    order by i.attendance_revision desc,i.created_at desc,i.id desc limit 1) original on true
  left join lateral (select p.created_at,p.reviewed_at,p.resolution_note
    from public.reliability_appeals p
    where p.attendance_id=a.id and p.appellant_profile_id=auth.uid()
    order by p.created_at desc,p.id desc limit 1) appeal on true;

  return result||jsonb_build_object('timezone',coalesce(zone,policy->>'timezone','UTC'),
    'policy_display',jsonb_build_object(
      'strike_lifetime_days',policy#>'{attendance,strikeLifetimeDays}',
      'late_strikes',policy#>'{solo,outcomes,late,strikes}',
      'no_show_strikes',policy#>'{solo,outcomes,noShow,strikes}',
      'cancellations',policy#>'{solo,cancellations}',
      'deposit',policy#>'{solo,reliabilityDeposit}',
      'sanctions',policy#>'{solo,sanctions}'),
    'incidents',incidents);
end;
$$;

comment on function public.get_my_reliability_status() is
  'Private reliability standing with effective player policy display and caller-owned incident/appeal metadata. Does not change reliability rules.';
revoke all on function public.get_my_reliability_status() from public,anon;
grant execute on function public.get_my_reliability_status() to authenticated,service_role;
notify pgrst,'reload schema';
