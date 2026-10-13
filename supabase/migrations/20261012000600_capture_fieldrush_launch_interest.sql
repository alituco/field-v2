-- One private interest list serves both legacy applications and launch signups.
-- Existing applications retain their original details, source, and status.
alter table public.season_zero_waitlist
  alter column full_name drop not null,
  drop constraint season_zero_waitlist_interest_check,
  drop constraint season_zero_waitlist_source_check,
  add column signup_placement text,
  add column launch_updates_consented_at timestamptz,
  add column launch_updates_consent_version text;

alter table public.season_zero_waitlist
  add constraint season_zero_waitlist_interest_check check (
    interest in ('SOLO_PLAYER', 'CLAN_PLAYER', 'CLAN_LEADER', 'LAUNCH_UPDATES')
  ),
  add constraint season_zero_waitlist_source_check check (
    source in ('FIELD_BH', 'FIELDRUSH_GG')
  ),
  add constraint season_zero_waitlist_applicant_name_check check (
    interest = 'LAUNCH_UPDATES' or full_name is not null
  ),
  add constraint season_zero_waitlist_launch_consent_check check (
    (
      signup_placement is null
      and launch_updates_consented_at is null
      and launch_updates_consent_version is null
    ) or (
      signup_placement is not null
      and signup_placement in (
        'desktop-hero', 'desktop-footer', 'mobile-hero', 'mobile-footer'
      )
      and launch_updates_consented_at is not null
      and launch_updates_consent_version is not null
      and launch_updates_consent_version = 'launch-updates-v1'
    )
  ),
  add constraint season_zero_waitlist_launch_interest_check check (
    interest <> 'LAUNCH_UPDATES'
    or (
      source = 'FIELDRUSH_GG'
      and launch_updates_consented_at is not null
    )
  );

comment on table public.season_zero_waitlist is
  'Private canonical interest list for Fieldrush launch updates and legacy Field applications.';
comment on column public.season_zero_waitlist.signup_placement is
  'Placement of the first explicit launch-updates signup; null for legacy applications without consent.';
comment on column public.season_zero_waitlist.launch_updates_consented_at is
  'First explicit consent to launch-update emails. A legacy application alone does not grant consent.';
comment on column public.season_zero_waitlist.launch_updates_consent_version is
  'Version of the consent wording accepted by the subscriber.';

-- Shared database buckets enforce the same limit across all server instances.
-- The server supplies a keyed hash; raw client IP addresses are never stored.
create table fieldrush_private.launch_update_rate_limits (
  rate_identity text primary key check (rate_identity ~ '^[a-f0-9]{64}$'),
  window_started_at timestamptz not null,
  request_count smallint not null check (request_count between 1 and 6)
);
create index launch_update_rate_limits_expiry_idx
  on fieldrush_private.launch_update_rate_limits (window_started_at);
alter table fieldrush_private.launch_update_rate_limits enable row level security;
revoke all on table fieldrush_private.launch_update_rate_limits
  from public, anon, authenticated, service_role;

create function public.save_launch_update(
  p_email text,
  p_placement text,
  p_consent_version text,
  p_rate_identity text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  normalized_email text := lower(btrim(p_email));
  captured_at timestamptz := clock_timestamp();
  rate_window_started_at timestamptz;
  rate_count smallint;
begin
  if normalized_email is null
    or char_length(normalized_email) not between 5 and 254
    or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or p_placement is null
    or p_placement not in (
      'desktop-hero', 'desktop-footer', 'mobile-hero', 'mobile-footer'
    )
    or p_consent_version is distinct from 'launch-updates-v1'
    or p_rate_identity is null
    or p_rate_identity !~ '^[a-f0-9]{64}$'
  then
    raise exception 'Invalid launch-update signup.' using errcode = '22023';
  end if;

  -- Opportunistic cleanup bounds retention without a scheduled job. Old
  -- hashes are removed on the next valid signup after their final day.
  delete from fieldrush_private.launch_update_rate_limits
  where window_started_at <= captured_at - interval '1 day';

  insert into fieldrush_private.launch_update_rate_limits as limits (
    rate_identity, window_started_at, request_count
  ) values (p_rate_identity, captured_at, 1)
  on conflict (rate_identity) do update set
    window_started_at = case
      when limits.window_started_at <= captured_at - interval '15 minutes'
        then captured_at
      else limits.window_started_at
    end,
    request_count = case
      when limits.window_started_at <= captured_at - interval '15 minutes'
        then 1
      else least(limits.request_count + 1, 6)
    end
  returning window_started_at, request_count
    into rate_window_started_at, rate_count;

  if rate_count > 5 then
    return jsonb_build_object(
      'status', 'rate_limited',
      'retry_after_seconds', greatest(1, ceil(extract(epoch from (
        rate_window_started_at + interval '15 minutes' - captured_at
      )))::integer)
    );
  end if;

  insert into public.season_zero_waitlist as interest_list (
    full_name, email, interest, source,
    signup_placement, launch_updates_consented_at,
    launch_updates_consent_version
  ) values (
    null, normalized_email, 'LAUNCH_UPDATES', 'FIELDRUSH_GG',
    p_placement, captured_at, p_consent_version
  )
  on conflict (lower(email)) do update set
    signup_placement = coalesce(interest_list.signup_placement, excluded.signup_placement),
    launch_updates_consented_at = coalesce(
      interest_list.launch_updates_consented_at, excluded.launch_updates_consented_at
    ),
    launch_updates_consent_version = coalesce(
      interest_list.launch_updates_consent_version, excluded.launch_updates_consent_version
    )
  where interest_list.launch_updates_consented_at is null;

  -- Identical responses for new and existing emails avoid disclosing the list.
  return jsonb_build_object('status', 'saved');
end;
$$;

revoke all on function public.save_launch_update(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.save_launch_update(text, text, text, text)
  to service_role;
comment on function public.save_launch_update(text, text, text, text) is
  'Server-only normalized, idempotent launch signup with atomic durable rate limiting.';
