-- Cancelling a match releases a commitment; its lazy attendance snapshot must
-- not be treated as registration in a second active game. Keep the registration
-- guards intact and initialize cancellation receipts after the real terminal
-- transition, under the cancellation RPC's existing validation and row lock.
do $migration$
declare
  definition text;
  old_call text := $old$    reliability_result := public.apply_policy_field_cancellation(
      actor_admin_id,
      'CLAN',
      match_id_to_cancel,
      normalized_reason
    );$old$;
  new_call text := $new$    -- Preserve actor-aware reversal before the status settlement trigger.
    -- This is the same policy applicability rule as the common correction.
    if exists (
      select 1
      from public.match_reliability_terms terms
      join public.reliability_policy_versions policy
        on policy.id = terms.policy_version_id
      where terms.match_kind = 'CLAN'
        and terms.fixture_id = match_id_to_cancel
        and policy.effective_from <= terms.kickoff_at
    ) or (
      not exists (
        select 1 from public.match_reliability_terms terms
        where terms.match_kind = 'CLAN'
          and terms.fixture_id = match_id_to_cancel
      ) and exists (
        select 1 from public.reliability_policy_versions policy
        where policy.state = 'PUBLISHED'
          and policy.effective_from <= public.fixture_start_at(
            fixture_before.match_date, fixture_before.time_slot
          )
      )
    ) then
      clan_reversed_before_transition :=
        public.reverse_match_reliability_incidents_for_field_cancel(
          actor_admin_id, 'CLAN', match_id_to_cancel, normalized_reason
        );
    end if;$new$;
  old_after text := $old$    update public.fixture_clock_states
    set status = 'ENDED', started_at = null$old$;
  new_after text := $new$    -- The complete CANCELLED row above includes the final reason, code and
    -- actor, so status-triggered finance settlement has authoritative metadata.
    -- Its roster snapshot now belongs to a terminal match and cannot register
    -- anyone in a second active game. All effects roll back together on error.
    reliability_result := public.apply_policy_field_cancellation(
      actor_admin_id, 'CLAN', match_id_to_cancel, normalized_reason
    );
    reliability_result := reliability_result || jsonb_build_object(
      'reversed_incident_count', clan_reversed_before_transition
        + coalesce((reliability_result ->> 'reversed_incident_count')::integer, 0)
    );
    update public.fixtures
    set cancellation_context = cancellation_context || jsonb_build_object(
      'reliability', reliability_result
    )
    where id = match_id_to_cancel;

    update public.fixture_clock_states
    set status = 'ENDED', started_at = null$new$;
  attendance_call text := $attendance$  perform public.resolve_clan_cancellation_attendance(
    fixture_to_cancel.id,
    cancelling_clan_id,
    (quote ->> 'cancellation_band') = 'afterKickoff',
    user_id
  );

$attendance$;
  notification_anchor text := $anchor$  insert into public.notifications (
    recipient_profile_id, type, title, body,$anchor$;
begin
  definition := pg_get_functiondef(
    'public.admin_cancel_match(uuid,text,uuid,text,text)'::regprocedure
  );
  if position('clan_reversed_before_transition' in definition) = 0 then
    if position(old_call in definition) = 0
      or position(old_after in definition) = 0
      or position('  reliability_result jsonb;' in definition) = 0
    then
      raise exception 'Admin cancellation ordering contract changed.';
    end if;
    definition := replace(definition, '  reliability_result jsonb;',
      E'  reliability_result jsonb;\n  clan_reversed_before_transition integer := 0;');
    definition := replace(definition, old_call, new_call);
    definition := replace(definition, old_after, new_after);
    execute definition;
  end if;

  definition := pg_get_functiondef(
    'public.cancel_clan_fixture_booking_policy(uuid,text)'::regprocedure
  );
  if position('-- Cancellation attendance follows the terminal transition.' in definition) = 0 then
    if position(attendance_call in definition) = 0
      or position(notification_anchor in definition) = 0 then
      raise exception 'Captain cancellation ordering contract changed.';
    end if;
    definition := replace(definition, attendance_call, '');
    definition := replace(definition, notification_anchor,
      E'  -- Cancellation attendance follows the terminal transition.\n'
        || attendance_call || notification_anchor);
    execute definition;
  end if;
end;
$migration$;

notify pgrst, 'reload schema';
