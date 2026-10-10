-- Give participating clan members a narrow, fixture-scoped view of their own
-- expected matchday roster. Reliability tables remain service-only; this RPC
-- returns only the minimum teammate and lock information required by the app.
create or replace function public.get_my_fixture_reliability_roster(
  fixture_id_to_view uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  fixture_to_use public.fixtures%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  clan_id_to_view uuid;
  side_to_view text;
  member_role text;
  required_count integer;
  confirmed_count integer;
  roster_locked boolean;
  members_to_return jsonb;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into fixture_to_use
  from public.fixtures fixture
  where fixture.id = fixture_id_to_view;
  if fixture_to_use.id is null then
    raise exception 'Match not found.';
  end if;

  select member.clan_id, member.role
  into clan_id_to_view, member_role
  from public.clan_members member
  where member.profile_id = user_id
    and member.left_at is null
    and member.clan_id in (
      fixture_to_use.home_clan_id,
      fixture_to_use.away_clan_id
    )
  limit 1;
  if clan_id_to_view is null then
    raise exception 'Only participating clan members can view this matchday roster.';
  end if;

  side_to_view := case
    when clan_id_to_view = fixture_to_use.home_clan_id then 'HOME'
    else 'AWAY'
  end;

  terms_to_use := public.ensure_match_reliability_terms(
    'CLAN',
    fixture_id_to_view
  );
  perform public.initialize_fixture_reliability_roster(fixture_id_to_view);

  required_count := (terms_to_use.policy_snapshot #>>
    '{clan,playersPerSide}')::integer;
  roster_locked := fixture_to_use.status not in ('OPEN', 'SCHEDULED')
    or clock_timestamp() >= terms_to_use.check_in_deadline_at;

  select count(*)::integer into confirmed_count
  from public.fixture_reliability_roster_history roster
  where roster.fixture_id = fixture_id_to_view
    and roster.clan_id = clan_id_to_view
    and roster.status = 'CONFIRMED';

  with candidates as (
    select
      member.profile_id,
      member.role,
      true as active_member
    from public.clan_members member
    where member.clan_id = clan_id_to_view
      and member.left_at is null
    union all
    select
      roster.profile_id,
      'former_member'::text as role,
      false as active_member
    from public.fixture_reliability_roster_history roster
    where roster.fixture_id = fixture_id_to_view
      and roster.clan_id = clan_id_to_view
      and roster.status = 'CONFIRMED'
      and not exists (
        select 1
        from public.clan_members current_member
        where current_member.clan_id = clan_id_to_view
          and current_member.profile_id = roster.profile_id
          and current_member.left_at is null
      )
  ), roster_members as (
    select
      candidate.profile_id,
      candidate.role,
      candidate.active_member,
      profile.display_name,
      profile.username,
      profile.avatar_url,
      exists (
        select 1
        from public.fixture_reliability_roster_history roster
        where roster.fixture_id = fixture_id_to_view
          and roster.clan_id = clan_id_to_view
          and roster.profile_id = candidate.profile_id
          and roster.status = 'CONFIRMED'
      ) as selected,
      candidate.active_member
        and not public.profile_has_active_play_restriction(
          candidate.profile_id
        ) as eligible
    from candidates candidate
    join public.profiles profile on profile.id = candidate.profile_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'profile_id', roster_member.profile_id,
        'display_name', roster_member.display_name,
        'username', roster_member.username,
        'avatar_url', roster_member.avatar_url,
        'role', roster_member.role,
        'selected', roster_member.selected,
        'eligible', roster_member.eligible,
        'unavailable_reason', case
          when not roster_member.active_member
            then 'No longer an active clan member'
          when not roster_member.eligible
            then 'Unavailable for this fixture'
          else null
        end
      ) order by
        roster_member.selected desc,
        case roster_member.role
          when 'owner' then 0
          when 'leader' then 1
          when 'member' then 2
          else 3
        end,
        lower(roster_member.display_name),
        roster_member.profile_id
    ),
    '[]'::jsonb
  ) into members_to_return
  from roster_members roster_member;

  return jsonb_build_object(
    'fixture_id', fixture_id_to_view,
    'clan_id', clan_id_to_view,
    'side', side_to_view,
    'required_count', required_count,
    'confirmed_count', confirmed_count,
    'is_complete', confirmed_count = required_count,
    'locks_at', terms_to_use.check_in_deadline_at,
    'locked', roster_locked,
    'can_manage', member_role in ('owner', 'leader'),
    'can_edit', member_role in ('owner', 'leader') and not roster_locked,
    'members', members_to_return
  );
end;
$$;

revoke all on function public.get_my_fixture_reliability_roster(uuid)
from public, anon, authenticated;
grant execute on function public.get_my_fixture_reliability_roster(uuid)
to authenticated, service_role;

comment on function public.get_my_fixture_reliability_roster(uuid) is
  'Returns only the signed-in participating member clan roster and edit lock metadata for one fixture.';
