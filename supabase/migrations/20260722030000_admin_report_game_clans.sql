-- Let administrators report either clan directly from a fixture overview and,
-- after reviewing evidence, issue policy-backed clan reliability strikes.

create or replace function public.admin_report_game_clan(
  actor_admin_id uuid,
  fixture_id_to_use uuid,
  clan_id_to_use uuid,
  category_to_use text,
  priority_to_use text,
  details_to_use text,
  strike_count_to_use integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_category text := upper(trim(coalesce(category_to_use, '')));
  normalized_priority text := upper(trim(coalesce(priority_to_use, '')));
  normalized_details text := trim(coalesce(details_to_use, ''));
  fixture_to_use public.fixtures%rowtype;
  report_id_to_use uuid;
  incident_id_to_use uuid;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if normalized_category not in (
    'HARASSMENT', 'THREATS_OR_VIOLENCE', 'DISCRIMINATION',
    'DANGEROUS_PLAY', 'CHEATING', 'NO_SHOW_OR_MATCH_MANIPULATION',
    'INAPPROPRIATE_CONTENT', 'SAFETY_OR_VENUE', 'SCORE_OR_RESULT',
    'REFEREE_ABUSE', 'OTHER'
  ) then
    raise exception 'Choose a valid report category.';
  end if;
  if normalized_priority not in ('LOW', 'NORMAL', 'HIGH', 'URGENT') then
    raise exception 'Choose a valid report priority.';
  end if;
  if char_length(normalized_details) not between 10 and 2000 then
    raise exception 'Record a clear reason between 10 and 2000 characters.';
  end if;
  if strike_count_to_use not between 0 and 3 then
    raise exception 'Issue between zero and three strikes.';
  end if;

  select * into fixture_to_use
  from public.fixtures fixture
  where fixture.id = fixture_id_to_use
  for update;
  if fixture_to_use.id is null then raise exception 'Clan fixture not found.'; end if;
  if clan_id_to_use not in (
    fixture_to_use.home_clan_id,
    fixture_to_use.away_clan_id
  ) then
    raise exception 'That clan is not part of this fixture.';
  end if;
  if strike_count_to_use > 0 and exists (
    select 1 from public.reliability_incidents incident
    where incident.subject_type = 'CLAN'
      and incident.fixture_id = fixture_id_to_use
      and incident.clan_id = clan_id_to_use
      and incident.reversal_of is null
  ) then
    raise exception 'This clan already has a reliability incident for this game.';
  end if;

  insert into public.moderation_reports (
    reporter_referee_id, source, subject_type, subject_clan_id,
    fixture_id, category, details, priority, status,
    assigned_admin_id, resolution_note, resolved_by, resolved_at
  ) values (
    actor_admin_id, 'ADMIN', 'CLAN', clan_id_to_use,
    fixture_id_to_use, normalized_category, normalized_details,
    normalized_priority,
    case when strike_count_to_use > 0 then 'ACTIONED' else 'OPEN' end,
    case when strike_count_to_use > 0 then actor_admin_id end,
    case when strike_count_to_use > 0
      then strike_count_to_use::text || ' clan reliability strike(s) issued by an administrator.' end,
    case when strike_count_to_use > 0 then actor_admin_id end,
    case when strike_count_to_use > 0 then clock_timestamp() end
  ) returning id into report_id_to_use;

  if strike_count_to_use > 0 then
    incident_id_to_use := public.record_clan_reliability_incident(
      fixture_id_to_use,
      clan_id_to_use,
      'ADMIN_REPORTED',
      strike_count_to_use,
      clock_timestamp()
    );
  end if;

  insert into public.admin_audit_events (
    actor_referee_id, action, entity_type, entity_id, reason, after_state
  ) values (
    actor_admin_id,
    case when strike_count_to_use > 0
      then 'CLAN_REPORTED_AND_STRUCK' else 'CLAN_REPORTED' end,
    'CLAN', clan_id_to_use, normalized_details,
    jsonb_build_object(
      'report_id', report_id_to_use,
      'fixture_id', fixture_id_to_use,
      'category', normalized_category,
      'priority', normalized_priority,
      'strike_count', strike_count_to_use,
      'incident_id', incident_id_to_use
    )
  );

  return jsonb_build_object(
    'report_id', report_id_to_use,
    'incident_id', incident_id_to_use,
    'strike_count', strike_count_to_use
  );
end;
$$;

revoke all on function public.admin_report_game_clan(
  uuid, uuid, uuid, text, text, text, integer
) from public, anon, authenticated;
grant execute on function public.admin_report_game_clan(
  uuid, uuid, uuid, text, text, text, integer
) to service_role;

comment on function public.admin_report_game_clan(
  uuid, uuid, uuid, text, text, text, integer
) is
'Creates an audited match-linked clan report and optionally applies policy-backed clan reliability strikes.';
