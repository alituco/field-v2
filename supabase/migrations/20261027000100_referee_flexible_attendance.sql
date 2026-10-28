-- A booked player's arrival is still attendance evidence after kickoff. The
-- unified match-record writer maps that same timestamp onto the playing clock.
-- Attendance penalties are finalized at full time, never while play continues.
create or replace function fieldrush_rating_private.solo_attendance_cutoff(
  game_id_to_use uuid, scheduled_cutoff_to_use timestamptz
) returns timestamptz language sql volatile security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
  select case when g.rating_policy_id is distinct from 'field-sr-season0-v2' then scheduled_cutoff_to_use
    when g.status='FINAL' and s.lifecycle='FINAL' then s.started_at
    when g.status in ('OPEN','FULL','LIVE') then 'infinity'::timestamptz
    else scheduled_cutoff_to_use end
  from public.open_queue_games g left join fieldrush_rating_private.season_zero_matches s on s.game_id=g.id
  where g.id=game_id_to_use;
$$;

-- Preserve the append-only ledger. Each corrected attendance finding has its
-- own revision; its predecessor is reversed, never overwritten or deleted.
alter table public.reliability_incidents add column attendance_revision integer not null default 0
  check(attendance_revision>=0);
drop index public.reliability_incident_attendance_positive_idx;
create unique index reliability_incident_attendance_positive_idx
  on public.reliability_incidents(attendance_id,attendance_revision)
  where attendance_id is not null and reversal_of is null;

do $migration$
declare d text; signature text; anchor text;
begin
  select pg_get_constraintdef(oid) into d from pg_constraint
    where conrelid='public.attendance_events'::regclass and conname='attendance_events_event_type_check';
  if position('''CHECKED_IN''::text' in d)=0 then raise exception 'Attendance event type contract changed.'; end if;
  d:=replace(d,'''CHECKED_IN''::text','''CHECKED_IN''::text, ''CHECK_IN_CORRECTED''::text');
  alter table public.attendance_events drop constraint attendance_events_event_type_check;
  execute 'alter table public.attendance_events add constraint attendance_events_event_type_check '||d;

  foreach signature in array array[
    'public.referee_check_in_player(uuid,text,uuid,uuid)',
    'public.referee_check_in_player_with_timing(uuid,text,uuid,uuid,text)'
  ] loop
    d:=pg_get_functiondef(signature::regprocedure);
    anchor:=E'begin\n';
    if position(anchor in d)=0 then raise exception 'Referee check-in entry contract changed: %',signature; end if;
    d:=overlay(d placing anchor||$new$
  if upper(trim(match_kind_to_use))='SOLO' and exists(select 1 from public.open_queue_games g
    join fieldrush_rating_private.season_zero_matches s on s.game_id=g.id
    where g.id=match_id_to_use and g.rating_policy_id='field-sr-season0-v2') then
    raise exception 'Record arrival and entry together in the match record.';
  end if;
$new$ from position(anchor in d) for char_length(anchor));
    execute d;
  end loop;

  foreach signature in array array[
    'public.record_reliability_incident(uuid,text,integer,timestamptz)',
    'public.get_my_reliability_status()',
    'public.submit_reliability_appeal(uuid,text,text)',
    'public.admin_review_reliability_appeal(uuid,uuid,text,text)',
    'public.admin_report_game_player(uuid,text,uuid,uuid,text,text,text,integer)'
  ] loop
    d:=pg_get_functiondef(signature::regprocedure);
    anchor:='incident.reversal_of is null';
    if position(anchor in d)=0 then raise exception 'Current attendance incident contract changed: %',signature; end if;
    d:=replace(d,anchor,anchor||' and not exists(select 1 from public.reliability_incidents reversed_finding where reversed_finding.reversal_of=incident.id)');
    if signature='public.record_reliability_incident(uuid,text,integer,timestamptz)' then
      anchor:=E'    subject_type,\n    profile_id,\n    attendance_id,';
      if position(anchor in d)=0 then raise exception 'Attendance incident insert contract changed.'; end if;
      d:=replace(d,anchor,E'    attendance_revision,\n'||anchor);
      anchor:=E'    ''PLAYER'',\n    attendance_to_use.profile_id,\n    attendance_to_use.id,';
      if position(anchor in d)=0 then raise exception 'Attendance incident values contract changed.'; end if;
      d:=replace(d,anchor,E'    attendance_to_use.check_in_revision,\n'||anchor);
    end if;
    execute d;
  end loop;

  d:=pg_get_functiondef('public.finalize_match_attendance_internal(text,uuid,uuid)'::regprocedure);
  anchor:='  perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);';
  if position(anchor in d)=0 then raise exception 'Attendance finalization entry changed.'; end if;
  d:=replace(d,anchor,$new$
  if normalized_kind='SOLO' then
    perform 1 from public.open_queue_games where id=match_id_to_use for update;
    if exists(select 1 from public.open_queue_games g where g.id=match_id_to_use
      and g.rating_policy_id='field-sr-season0-v2'
      and (g.status<>'FINAL' or not exists(select 1 from fieldrush_rating_private.season_zero_matches s
        where s.game_id=g.id and s.lifecycle='FINAL'))) then return 0; end if;
  end if;
$new$||anchor);
  execute d;

  d:=pg_get_functiondef('public.get_match_reliability_context(text,uuid)'::regprocedure);
  anchor:=$old$'no_show_cutoff_at', terms_to_use.no_show_cutoff_at,$old$;
  if position(anchor in d)=0 then raise exception 'Attendance context cutoff contract changed.'; end if;
  d:=replace(d,anchor,$new$'no_show_cutoff_at', case when normalized_kind='SOLO'
      and exists(select 1 from public.open_queue_games where id=match_id_to_use and rating_policy_id='field-sr-season0-v2')
      then null else terms_to_use.no_show_cutoff_at end,
    'finalize_at_full_time', normalized_kind='SOLO' and exists(select 1 from public.open_queue_games
      where id=match_id_to_use and rating_policy_id='field-sr-season0-v2'),$new$);
  execute d;
end;
$migration$;

-- Re-evaluate only policy-derived reliability sanctions. Moderator sanctions,
-- appeal rulings and financial/booking side effects are outside this writer.
create function fieldrush_rating_private.reconcile_referee_attendance_sanctions(
  actor uuid, player uuid, reason text, since_at timestamptz
) returns void language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
declare finding public.reliability_incidents%rowtype; existing public.reliability_sanctions%rowtype;
  rule jsonb; config jsonb; before_count integer; after_count integer; crossed integer[];
  expires timestamptz; highest boolean;
begin
  perform pg_advisory_xact_lock(hashtextextended(player::text,9174));
  -- A reversal invalidates every sanction belonging to that finding.
  update public.reliability_sanctions s set revoked_at=clock_timestamp(),revoked_by=actor,
    revocation_reason=left('Referee attendance correction: '||reason,2000)
    where s.subject_type='PLAYER' and s.profile_id=player and s.revoked_at is null
      and exists(select 1 from public.reliability_incidents i join public.reliability_incidents r on r.reversal_of=i.id
        where i.id=s.incident_id and i.occurred_at>=since_at);
  for finding in select * from public.reliability_incidents i
    where i.subject_type='PLAYER' and i.profile_id=player and i.reversal_of is null and i.strike_delta>0
      and i.occurred_at>=since_at
      and not exists(select 1 from public.reliability_incidents r where r.reversal_of=i.id)
    order by i.occurred_at,i.created_at,i.id
  loop
    select coalesce(t.policy_snapshot,p.config) into config
      from public.reliability_policy_versions p
      left join public.match_attendance_records a on a.id=finding.attendance_id
      left join public.match_reliability_terms t on t.id=a.terms_id
      where p.id=finding.policy_version_id;
    select coalesce(sum(i.strike_delta),0)::integer into before_count
      from public.reliability_incidents i where i.subject_type='PLAYER' and i.profile_id=player
        and i.reversal_of is null and i.strike_delta>0 and i.id<>finding.id
        and (i.occurred_at,i.created_at,i.id)<(finding.occurred_at,finding.created_at,finding.id)
        and (i.expires_at is null or i.expires_at>finding.occurred_at)
        and not exists(select 1 from public.reliability_incidents r where r.reversal_of=i.id);
    after_count:=before_count+finding.strike_delta;
    highest:=coalesce((config#>>'{solo,highestCrossedOnly}')::boolean,false);
    select coalesce(array_agg((v->>'threshold')::integer),'{}') into crossed
      from jsonb_array_elements(coalesce(config#>'{solo,sanctions}','[]')) v
      where (v->>'threshold')::integer>before_count and (v->>'threshold')::integer<=after_count;
    if highest and cardinality(crossed)>0 then crossed:=array[(select max(v) from unnest(crossed) v)]; end if;
    update public.reliability_sanctions s set revoked_at=clock_timestamp(),revoked_by=actor,
      revocation_reason=left('Referee attendance correction: '||reason,2000)
      where s.incident_id=finding.id and s.revoked_at is null and not(s.threshold=any(crossed));
    for rule in select v from jsonb_array_elements(coalesce(config#>'{solo,sanctions}','[]')) v
      where (v->>'threshold')::integer=any(crossed)
    loop
      expires:=case when rule->>'kind' in ('WARNING','INDEFINITE_SUSPENSION') then null
        else finding.occurred_at+make_interval(days=>(rule->>'durationDays')::integer) end;
      -- Never resurrect an organizer's revocation or restart an expired ban.
      if expires is not null and expires<=clock_timestamp() then continue; end if;
      select * into existing from public.reliability_sanctions
        where incident_id=finding.id and threshold=(rule->>'threshold')::integer for update;
      if existing.id is null then
        insert into public.reliability_sanctions(subject_type,profile_id,incident_id,policy_version_id,
          threshold,sanction_kind,starts_at,ends_at,release_future_bookings)
        values('PLAYER',player,finding.id,finding.policy_version_id,(rule->>'threshold')::integer,
          rule->>'kind',finding.occurred_at,expires,false);
      elsif existing.revoked_at is not null and existing.revocation_reason like 'Referee attendance correction:%' then
        update public.reliability_sanctions set revoked_at=null,revoked_by=null,revocation_reason=null
          where id=existing.id;
      end if;
    end loop;
  end loop;
end;
$$;

create function fieldrush_rating_private.referee_apply_solo_arrival(
  actor uuid, game uuid, player uuid, arrived_at timestamptz, reason text
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_rating_private,fieldrush_private,pg_temp as $$
declare g public.open_queue_games%rowtype; a public.match_attendance_records%rowtype;
  previous public.match_attendance_records%rowtype; terms public.match_reliability_terms%rowtype;
  finding public.reliability_incidents%rowtype; finding_id uuid; old_effective timestamptz;
  state fieldrush_rating_private.season_zero_matches%rowtype; outcome_to_use text; strikes integer;
  current_count integer; old_count integer; before_state jsonb; after_state jsonb; rule jsonb;
  actual_now timestamptz:=clock_timestamp(); timing text; new_notice uuid;
begin
  if not public.referee_can_manage_reliability_match(actor,'SOLO',game) then
    raise exception 'This match is not assigned to you.' using errcode='42501'; end if;
  select * into g from public.open_queue_games where id=game for update;
  if g.rating_policy_id is distinct from 'field-sr-season0-v2' or g.status not in ('OPEN','FULL','LIVE','FINAL') then
    raise exception 'This game does not support referee arrival corrections.'; end if;
  if g.operational_state is distinct from 'NORMAL' then raise exception 'This match is locked for organizer review.'; end if;
  select * into state from fieldrush_rating_private.season_zero_matches where game_id=game for update;
  if state.adjudicated_by is not null or state.lifecycle='REVIEW' then
    raise exception 'This match has an organizer decision. Ask the organizer to review this correction.'; end if;
  perform public.ensure_match_attendance_records('SOLO',game);
  select attendance.* into a from public.match_attendance_records attendance
    join public.open_queue_bookings b on b.id=attendance.booking_id
    where attendance.match_kind='SOLO' and attendance.open_queue_game_id=game
      and attendance.profile_id=player and attendance.is_current and b.status='CONFIRMED'
      and (state.game_id is null or exists(select 1 from jsonb_array_elements(state.observed_roster) r
        where r->>'id'=player::text and r->>'booking_id'=b.id::text)) for update of attendance;
  if a.id is null then raise exception 'Only the originally booked player can have an arrival recorded.'; end if;
  if a.checked_in_at is not distinct from arrived_at then
    return jsonb_build_object('attendance_id',a.id,'profile_id',player,'changed',false);
  end if;
  if arrived_at is not null and (not isfinite(arrived_at) or arrived_at>actual_now) then
    raise exception 'Arrival must be a real time that has already happened.'; end if;
  if state.game_id is null and not fieldrush_rating_private.solo_start_window_allows(g.starts_at,actual_now) then
    raise exception 'Check in players within 24 hours before or after the scheduled kickoff.'; end if;
  if arrived_at is not null and arrived_at<g.starts_at-interval '24 hours' then
    raise exception 'Arrival is outside this game''s check-in window.'; end if;
  if (g.status='FINAL' or a.checked_in_at is not null or a.finalized_at is not null or arrived_at is null)
    and char_length(trim(coalesce(reason,'')))<10 then
    raise exception 'Explain this correction in at least ten characters.'; end if;
  if char_length(coalesce(reason,''))>2000 then raise exception 'The correction reason is too long.'; end if;
  if a.outcome is not null and a.outcome not in ('ON_TIME','LATE','NO_SHOW') then
    raise exception 'This attendance has an organizer decision. Ask the organizer to review this correction.'; end if;
  perform 1 from public.reliability_appeals where attendance_id=a.id for update;
  if found then raise exception 'This attendance has an appeal. Ask the organizer to review this correction.'; end if;
  if exists(select 1 from public.reliability_incidents i where i.attendance_id=a.id and i.reversal_of is null
    and i.outcome not in ('LATE','NO_SHOW') and not exists(select 1 from public.reliability_incidents r where r.reversal_of=i.id)) then
    raise exception 'This attendance has an organizer decision. Ask the organizer to review this correction.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(player::text,9174));
  previous:=a;
  old_count:=public.active_reliability_strikes(player,actual_now);
  before_state:=jsonb_build_object('checked_in_at',a.checked_in_at,'outcome',a.outcome,'strikes',a.strike_delta,
    'active_strikes',old_count,'can_book',not(public.profile_has_active_play_restriction(player)
      or public.profile_has_active_reliability_booking_restriction(player)),'check_in_revision',a.check_in_revision);
  select * into terms from public.match_reliability_terms where id=a.terms_id;
  terms:=fieldrush_private.arrival_attendance_terms(terms);
  timing:=case when arrived_at is null then null
    when fieldrush_private.arrival_is_on_time(arrived_at,null,terms) then 'EARLY'
    when state.game_id is not null and arrived_at>=state.started_at then 'AFTER_KICKOFF' else 'LATE' end;
  outcome_to_use:=case when g.status<>'FINAL' then null when arrived_at is null then 'NO_SHOW'
    when timing='EARLY' then 'ON_TIME' else 'LATE' end;
  rule:=case outcome_to_use when 'NO_SHOW' then terms.policy_snapshot#>'{solo,outcomes,noShow}'
    when 'LATE' then terms.policy_snapshot#>'{solo,outcomes,late}' else terms.policy_snapshot#>'{solo,outcomes,onTime}' end;
  strikes:=case when outcome_to_use is null then 0 else coalesce((rule->>'strikes')::integer,0) end;
  old_effective:=coalesce(a.finalized_at,case when g.status='FINAL' then actual_now end);
  -- Every old positive revision is offset at its original effective time. Its
  -- expiry is retained; editing a historical game never creates fresh strikes.
  for finding in select * from public.reliability_incidents i where i.attendance_id=a.id
    and i.reversal_of is null and not exists(select 1 from public.reliability_incidents r where r.reversal_of=i.id)
    order by i.created_at,i.id for update
  loop
    current_count:=public.active_reliability_strikes(player,actual_now);
    insert into public.reliability_incidents(subject_type,profile_id,attendance_id,booking_id,outcome,strike_delta,
      occurred_at,expires_at,policy_version_id,reversal_of,active_count_before,active_count_after,detail,attendance_revision)
    values('PLAYER',player,a.id,a.booking_id,'REFEREE_CORRECTED',-finding.strike_delta,finding.occurred_at,
      finding.expires_at,finding.policy_version_id,finding.id,current_count,
      greatest(0,current_count-case when finding.expires_at is null or finding.expires_at>actual_now then finding.strike_delta else 0 end),
      jsonb_build_object('reason',reason,'actor_id',actor,'recorded_at',actual_now,'old_attendance_revision',a.check_in_revision),a.check_in_revision+1);
    old_effective:=least(old_effective,finding.occurred_at);
  end loop;
  update public.match_attendance_records set checked_in_at=arrived_at,
    checked_in_by=case when arrived_at is null then null else actor end,check_in_timing=timing,
    check_in_revision=check_in_revision+1,outcome=outcome_to_use,strike_delta=strikes,
    positive_sr_multiplier_bps=10000,negative_sr_multiplier_bps=10000,
    finalized_at=case when outcome_to_use is null then null else coalesce(old_effective,actual_now) end,
    appeal_due_at=case when outcome_to_use is null then null else actual_now+make_interval(hours=>(terms.policy_snapshot#>>'{attendance,appealWindowHours}')::integer) end,
    consequence_snapshot=consequence_snapshot||jsonb_build_object('referee_arrival_correction',jsonb_build_object(
      'recorded_at',actual_now,'actor_id',actor,'reason',reason,'arrival_is_entry',true,'previous',before_state,
      'outcome_code',outcome_to_use,'strike_delta',strikes),
      'final_attendance_decision',case when outcome_to_use is null then null
        else coalesce(consequence_snapshot->'final_attendance_decision','{}'::jsonb)||jsonb_build_object(
          'outcome_code',outcome_to_use,'strike_delta',strikes,'checked_in_at',arrived_at,
          'check_in_revision',check_in_revision+1,'corrected_at',actual_now,'corrected_by',actor) end)
    where id=a.id returning * into a;
  if strikes>0 then
    current_count:=public.active_reliability_strikes(player,actual_now);
    insert into public.reliability_incidents(subject_type,profile_id,attendance_id,booking_id,outcome,strike_delta,
      occurred_at,expires_at,policy_version_id,active_count_before,active_count_after,detail,attendance_revision)
    values('PLAYER',player,a.id,a.booking_id,outcome_to_use,strikes,a.finalized_at,
      a.finalized_at+make_interval(days=>(terms.policy_snapshot#>>'{attendance,strikeLifetimeDays}')::integer),a.policy_version_id,
      current_count,current_count+case when a.finalized_at+make_interval(days=>(terms.policy_snapshot#>>'{attendance,strikeLifetimeDays}')::integer)>actual_now then strikes else 0 end,
      jsonb_build_object('match_kind','SOLO','open_queue_game_id',game,'reason',reason,'actor_id',actor,
        'recorded_at',actual_now,'referee_attendance_correction',true),a.check_in_revision) returning id into finding_id;
  end if;
  if old_effective is not null then
    perform fieldrush_rating_private.reconcile_referee_attendance_sanctions(actor,player,coalesce(reason,'Arrival recorded'),old_effective);
  end if;
  after_state:=jsonb_build_object('checked_in_at',a.checked_in_at,'outcome',a.outcome,'strikes',a.strike_delta,
    'active_strikes',public.active_reliability_strikes(player,actual_now),'can_book',not(public.profile_has_active_play_restriction(player)
      or public.profile_has_active_reliability_booking_restriction(player)),'check_in_revision',a.check_in_revision);
  insert into public.attendance_events(attendance_id,event_type,actor_referee_id,event_at,detail,idempotency_key)
    values(a.id,case when previous.checked_in_at is null and previous.finalized_at is null and arrived_at is not null
      then 'CHECKED_IN' else 'CHECK_IN_CORRECTED' end,actor,actual_now,
      jsonb_build_object('reason',reason,'arrival_is_entry',true,'before',before_state,'after',after_state),
      'referee-arrival:'||a.id||':r'||a.check_in_revision);
  if previous.finalized_at is not null then
    update public.notifications n set resolved_at=coalesce(n.resolved_at,actual_now)
      where n.recipient_profile_id=player and n.type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION')
        and (n.related_entity_type='MATCH_ATTENDANCE' and n.related_entity_id=a.id
          or n.related_entity_type='RELIABILITY_SANCTION' and exists(select 1 from public.reliability_sanctions s
            join public.reliability_incidents i on i.id=s.incident_id where s.id=n.related_entity_id and i.attendance_id=a.id));
    insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id,data)
      values(player,'RELIABILITY_OUTCOME','Attendance corrected',
        left('Your arrival record was corrected. '||case outcome_to_use when 'ON_TIME' then 'You were on time; this game has no attendance strikes.'
          when 'LATE' then 'Late arrival: '||strikes||' attendance strike'||case when strikes=1 then '.' else 's.' end
          when 'NO_SHOW' then 'No-show: '||strikes||' attendance strikes.' else 'Attendance will be finalized when the game ends.' end
          ||case when before_state->>'can_book'='false' and after_state->>'can_book'='true' then ' You can book games again.'
            when after_state->>'can_book'='false' then ' A booking restriction remains active.' else '' end,300),
        'MATCH_ATTENDANCE',a.id,jsonb_build_object('player_push_v1',true,'referee_attendance_correction',true,
          'attendance_id',a.id,'attendance_revision',a.check_in_revision,'outcome',a.outcome,'game_id',game,
          'booking_id',a.booking_id,'incident_id',finding_id,'active_strikes',after_state->'active_strikes',
          'can_book',after_state->'can_book','appeal_due_at',a.appeal_due_at,'expires_at',actual_now+interval '7 days')) returning id into new_notice;
  end if;
  return jsonb_build_object('attendance_id',a.id,'profile_id',player,'changed',true,'before',before_state,'after',after_state,'notification_id',new_notice);
end;
$$;

do $migration$
declare d text; anchor text;
begin
  d:=pg_get_functiondef('fieldrush_private.emit_player_game_notice(uuid,text,text,text,text,uuid,jsonb)'::regprocedure);
  anchor:='  if inserted is distinct from true then return false; end if;';
  if position(anchor in d)=0 then raise exception 'Game notice receipt contract changed.'; end if;
  d:=replace(d,anchor,anchor||$new$
  if event_type='SOLO_MATCH_CORRECTED' then
    select n.id into saved_id from public.notifications n where n.recipient_profile_id=recipient
      and n.type='RELIABILITY_OUTCOME' and n.data->>'referee_attendance_correction'='true'
      and n.data->>'game_id'=game_to_use::text and n.resolved_at is null
      and n.created_at>=transaction_timestamp() order by n.created_at desc,n.id limit 1;
    if saved_id is not null then
      update public.notifications set data=data||jsonb_build_object('match_record_updated',true),
        body=case when data->>'match_record_updated'='true' then body else left(body,210)||
          ' Your match record was also updated. Open match history for the result and SR.' end where id=saved_id;
      update fieldrush_private.notification_event_receipts set notification_id=saved_id
        where recipient_id=recipient and notification_type=event_type and event_key=event_key_to_use;
      return true;
    end if;
  end if;
$new$);
  execute d;
  d:=pg_get_functiondef('fieldrush_private.coalesce_player_discipline_notification()'::regprocedure);
  anchor:='  select * into n from public.notifications where id=new.id;';
  if position(anchor in d)=0 then raise exception 'Discipline notification read changed.'; end if;
  d:=replace(d,anchor,anchor||E'\n  if n.resolved_at is not null or n.data->>''referee_attendance_correction''=''true'' then return new; end if;');
  anchor:='select * into incident from public.reliability_incidents where attendance_id=n.related_entity_id and subject_type=''PLAYER'' and reversal_of is null;';
  if position(anchor in d)=0 then raise exception 'Discipline incident lookup changed.'; end if;
  d:=replace(d,anchor,'select i.* into incident from public.reliability_incidents i where i.attendance_id=n.related_entity_id and i.subject_type=''PLAYER'' and i.reversal_of is null and not exists(select 1 from public.reliability_incidents r where r.reversal_of=i.id);');
  execute d;
  d:=pg_get_functiondef('fieldrush_private.observe_player_restriction_notification(uuid,timestamptz)'::regprocedure);
  anchor:=$old$or not is_restricted and n.type='RELIABILITY_APPEAL_DECIDED')$old$;
  if position(anchor in d)=0 then raise exception 'Restriction notification coalescing changed.'; end if;
  execute replace(d,anchor,$new$or not is_restricted and (n.type='RELIABILITY_APPEAL_DECIDED'
        or n.type='RELIABILITY_OUTCOME' and n.data->>'referee_attendance_correction'='true'))$new$);
  d:=pg_get_functiondef('fieldrush_private.player_discipline_notification_source_is_current(uuid)'::regprocedure);
  anchor:=$old$when n.type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION') then$old$;
  if position(anchor in d)=0 then raise exception 'Discipline source validation changed.'; end if;
  execute replace(d,anchor,$new$when n.type='RELIABILITY_OUTCOME' and n.data->>'referee_attendance_correction'='true' then
      exists(select 1 from public.match_attendance_records a where a.id=n.related_entity_id
        and a.profile_id=n.recipient_profile_id and a.match_kind='SOLO'
        and a.check_in_revision::text=n.data->>'attendance_revision'
        and a.outcome is not distinct from n.data->>'outcome')
    $new$||anchor);
end;
$migration$;

revoke all on function fieldrush_rating_private.reconcile_referee_attendance_sanctions(uuid,uuid,text,timestamptz),
  fieldrush_rating_private.referee_apply_solo_arrival(uuid,uuid,uuid,timestamptz,text)
  from public,anon,authenticated,service_role;
