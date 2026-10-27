-- Rollback-only full application schema regression. Synthetic people, scores,
-- wallet transactions and clock progression only; no provider/network calls.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table flex_checks(label text);
create function pg_temp.flex_expect(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Referee flex: %',label; end if;
  insert into flex_checks values(label);
end;
$$;

create function pg_temp.flex_reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement;
  exception when others then
    if position(expected in sqlerrm)=0 then raise; end if;
    rejected:=true;
  end;
  perform pg_temp.flex_expect(rejected,'rejected: '||expected);
end;
$$;
create sequence pg_temp.flex_person;
create sequence pg_temp.flex_game_number;
create function pg_temp.flex_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.flex_person');
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555547'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Flex','last_name','Player',
    'username','flex_'||n,'date_of_birth','2000-01-01','email','flex_'||n||'@example.test',
    'skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  return player;
end;
$$;
-- One fixed transaction anchor keeps sequence-offset fixture kickoffs unique.
create function pg_temp.flex_game(admin_id uuid,referee_id uuid,players uuid[],paid boolean default false) returns uuid language plpgsql as $$
declare game uuid; i integer; kickoff timestamptz:=date_trunc('minute',transaction_timestamp())-make_interval(mins=>nextval('pg_temp.flex_game_number')::integer);
begin
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('Disposable referee flex',kickoff,kickoff+interval '1 hour',case when paid then 10000 else 0 end,4,8) returning id into game;
  for i in 1..cardinality(players) loop
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method,payment_status)
      values(game,players[i],case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end,'CONFIRMED',
        case when paid then 10000 else 0 end,case when paid then 10000 else 0 end,case when paid then 'MOCK' else 'FREE' end,'PAID');
  end loop;
  perform public.ensure_match_attendance_records('SOLO',game);
  update public.match_reliability_terms set arrival_policy_version_id='solo-arrival-30-10-v1' where open_queue_game_id=game;
  update public.match_attendance_records a set check_in_deadline_at=t.arrival_check_in_deadline_at
    from public.match_reliability_terms t where a.terms_id=t.id and a.open_queue_game_id=game;
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',checked_in_by=referee_id,
    check_in_timing='EARLY' where open_queue_game_id=game;
  insert into public.open_queue_referee_assignments(game_id,referee_id,assigned_by) values(game,referee_id,admin_id);
  perform public.referee_assign_season_zero_teams(referee_id,game,gen_random_uuid());
  return game;
end;
$$;

do $$
declare players uuid[]:=array[]::uuid[]; admin_id uuid:=pg_temp.flex_player(); referee_id uuid:=pg_temp.flex_player();
  outsider uuid:=pg_temp.flex_player(); staff uuid; login uuid; game uuid; i integer; late_player uuid; absent uuid;
  current_attendance uuid; original_incident uuid; unrelated_incident uuid; result jsonb; terms public.match_reliability_terms%rowtype;
  finance_before jsonb; old_expiry timestamptz; old_decision timestamptz; notice uuid; initial_roster uuid[];
  appeal_id uuid; moderation_id uuid;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values
    (admin_id,'Flex admin','+15555470001','admin',true),(referee_id,'Flex referee','+15555470002','referee',true);
  foreach staff in array array[admin_id,referee_id] loop
    login:=gen_random_uuid();
    insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
      values(login,login||'@flex-staff.example.test',now(),'{"fieldrush_account_type":"staff"}');
    update public.referee_profiles set auth_user_id=login,email=login||'@flex-staff.example.test' where profile_id=staff;
  end loop;
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable flexible attendance policy.',now(),admin_id
      from public.reliability_policy_versions order by version limit 1;
  perform public.admin_set_season_zero_policy(admin_id,true,'Disposable flexible attendance verification only.');
  for i in 1..14 loop players:=array_append(players,pg_temp.flex_player()); end loop;
  game:=pg_temp.flex_game(admin_id,referee_id,players);
  late_player:=players[13]; absent:=players[14];
  update public.match_attendance_records set checked_in_at=null,checked_in_by=null,check_in_timing=null
    where open_queue_game_id=game and profile_id in (late_player,absent);
  perform pg_temp.flex_expect(public.finalize_match_attendance_internal('SOLO',game,referee_id)=0,
    'unstarted game never finalizes attendance');
  initial_roster:=players[1:12];
  perform public.referee_season_zero_action(referee_id,game,gen_random_uuid(),0,
    jsonb_build_object('action','START','participant_ids',to_jsonb(initial_roster)));
  update public.open_queue_clock_states set accumulated_seconds=2400,started_at=clock_timestamp() where game_id=game;
  perform pg_temp.flex_expect(fieldrush_rating_private.solo_attendance_cutoff(game,clock_timestamp())>
    (select started_at+interval '30 minutes' from fieldrush_rating_private.season_zero_matches where game_id=game),
    'operational cutoff allows arrivals more than 30 wall minutes after actual kickoff');
  perform pg_temp.flex_expect(public.finalize_match_attendance_internal('SOLO',game,referee_id)=0,
    '40-minute live game never finalizes no-shows');
  perform public.finalize_due_match_attendance();
  perform pg_temp.flex_expect(not exists(select 1 from public.match_attendance_records where open_queue_game_id=game and outcome is not null),
    'background finalizer preserves provisional live attendance');
  result:=public.get_match_reliability_context('SOLO',game);
  perform pg_temp.flex_expect(result->>'can_check_in'='true' and result->>'can_finalize_attendance'='false'
    and result->>'no_show_cutoff_at' is null and result->>'finalize_at_full_time'='true','live context agrees with open arrival and full-time finalization');
  result:=fieldrush_rating_private.referee_apply_solo_arrival(referee_id,game,late_player,clock_timestamp(),'');
  perform pg_temp.flex_expect(result#>>'{after,outcome}' is null and result#>>'{after,strikes}'='0'
    and (select checked_in_at is not null from public.match_attendance_records where open_queue_game_id=game and profile_id=late_player),
    'arrival during live play is accepted provisionally');
  perform pg_temp.flex_reject(format('select fieldrush_rating_private.referee_apply_solo_arrival(%L,%L,%L,now(),%L)',
    outsider,game,absent,'Unassigned referee must not correct.'),'not assigned');
  perform pg_temp.flex_reject(format('select fieldrush_rating_private.referee_apply_solo_arrival(%L,%L,%L,now(),%L)',
    referee_id,game,outsider,'Outside roster must not be added.'),'originally booked');
  perform pg_temp.flex_reject(format('select fieldrush_rating_private.referee_apply_solo_arrival(%L,%L,%L,now()+interval ''1 hour'',%L)',
    referee_id,game,absent,'Future arrival must not be recorded.'),'already happened');
  select * into terms from public.match_reliability_terms where open_queue_game_id=game;
  -- One independent, still-active strike makes the genuine no-show cross the
  -- three-strike restriction. Correcting this match must retain the older one.
  insert into public.reliability_incidents(subject_type,profile_id,outcome,strike_delta,occurred_at,expires_at,
    policy_version_id,active_count_before,active_count_after,detail)
    values('PLAYER',absent,'LATE',1,clock_timestamp()-interval '1 day',clock_timestamp()+interval '89 days',
      terms.policy_version_id,0,1,'{"test":"unrelated earlier attendance"}') returning id into unrelated_incident;
  update public.open_queue_clock_states set accumulated_seconds=3600,started_at=clock_timestamp() where game_id=game;
  perform public.referee_finish_season_zero_match(referee_id,game,gen_random_uuid(),1);
  select id,finalized_at into current_attendance,old_decision from public.match_attendance_records where open_queue_game_id=game and profile_id=absent;
  select id,expires_at into original_incident,old_expiry from public.reliability_incidents where attendance_id=current_attendance and reversal_of is null;
  perform pg_temp.flex_expect((select outcome='NO_SHOW' and strike_delta=2 from public.match_attendance_records where id=current_attendance)
    and public.active_reliability_strikes(absent)=3 and public.profile_has_active_reliability_booking_restriction(absent),
    'full time finalizes two-strike no-show and resulting restriction');
  perform pg_temp.flex_expect((select outcome='LATE' and strike_delta=1 from public.match_attendance_records where open_queue_game_id=game and profile_id=late_player),
    'actual late arrival receives one strike at full time');
  select jsonb_build_object('bookings',(select jsonb_agg(to_jsonb(b)-'updated_at' order by id) from public.open_queue_bookings b where game_id=game),
    'wallet',(select jsonb_agg(to_jsonb(t) order by id) from public.field_wallet_transactions t),
    'payments',(select jsonb_agg(to_jsonb(t) order by id) from public.payment_intents t)) into finance_before;
  result:=fieldrush_rating_private.referee_apply_solo_arrival(referee_id,game,absent,
    clock_timestamp()-interval '10 minutes','Player actually arrived at minute thirty.');
  notice:=(result->>'notification_id')::uuid;
  perform pg_temp.flex_expect(result#>>'{after,outcome}'='LATE' and result#>>'{after,strikes}'='1'
    and result#>>'{after,active_strikes}'='2' and result#>>'{after,can_book}'='true',
    'corrected no-show is replaced by one late strike and dependent restriction is lifted');
  perform pg_temp.flex_expect((select count(*)=1 from public.reliability_incidents where reversal_of=original_incident)
    and not exists(select 1 from public.reliability_incidents where reversal_of=unrelated_incident),
    'append-only correction reverses only this attendance finding');
  perform pg_temp.flex_expect((select count(*)=1 and min(expires_at)=old_expiry and min(occurred_at)=old_decision
    from public.reliability_incidents i where attendance_id=current_attendance and reversal_of is null
      and not exists(select 1 from public.reliability_incidents r where r.reversal_of=i.id)),
    'replacement finding preserves original effective time and expiry');
  perform pg_temp.flex_reject(format('select fieldrush_rating_private.referee_apply_solo_arrival(%L,%L,%L,null,%L)',
    referee_id,game,absent,'short'),'ten characters');
  result:=fieldrush_rating_private.referee_apply_solo_arrival(referee_id,game,absent,
    (select check_in_deadline_at from public.match_attendance_records where id=current_attendance),
    'Verified arrival was exactly the saved check-in deadline.');
  perform pg_temp.flex_expect(result#>>'{after,outcome}'='LATE' and result#>>'{after,strikes}'='1',
    'exact saved ten-minute cutoff is late, regardless of later recording time');
  result:=fieldrush_rating_private.referee_apply_solo_arrival(referee_id,game,absent,
    (select check_in_deadline_at-interval '1 minute' from public.match_attendance_records where id=current_attendance),
    'Verified the player was actually present on time.');
  perform pg_temp.flex_expect(result#>>'{after,outcome}'='ON_TIME' and result#>>'{after,strikes}'='0'
    and public.active_reliability_strikes(absent)=1,'second correction removes only game strikes and retains independent strike');
  perform fieldrush_private.emit_player_game_notice(absent,'SOLO_MATCH_CORRECTED','flexible-attendance-same-change',
    'Your match record was updated','The result and SR were corrected.',game,'{}');
  perform pg_temp.flex_expect((select data->>'match_record_updated'='true' and position('result and SR' in body)>0
    from public.notifications where id=(result->>'notification_id')::uuid)
    and not exists(select 1 from public.notifications where recipient_profile_id=absent and type='SOLO_MATCH_CORRECTED'
      and data->>'fieldrush_event_key'='flexible-attendance-same-change'),
    'same correction coalesces the affected player SR notice into their attendance receipt');
  perform pg_temp.flex_expect(not fieldrush_private.emit_player_game_notice(absent,'SOLO_MATCH_CORRECTED','flexible-attendance-same-change',
    'Your match record was updated','The result and SR were corrected.',game,'{}'),
    'coalesced game correction still has an idempotency receipt');
  set constraints all immediate;
  perform pg_temp.flex_expect(not fieldrush_private.player_discipline_notification_source_is_current(notice)
    and fieldrush_private.player_discipline_notification_source_is_current((result->>'notification_id')::uuid),
    'prior correction push expires and current zero-strike correction remains deliverable');
  perform pg_temp.flex_expect((select count(*)=1 from public.notifications where recipient_profile_id=absent
    and type='RELIABILITY_OUTCOME' and resolved_at is null and data->>'referee_attendance_correction'='true'),
    'one current corrected attendance receipt');
  set constraints all deferred;
  perform pg_temp.flex_expect(jsonb_build_object('bookings',(select jsonb_agg(to_jsonb(b)-'updated_at' order by id) from public.open_queue_bookings b where game_id=game),
    'wallet',(select jsonb_agg(to_jsonb(t) order by id) from public.field_wallet_transactions t),
    'payments',(select jsonb_agg(to_jsonb(t) order by id) from public.payment_intents t))=finance_before,
    'attendance corrections do not change bookings, refunds, wallets or payments');
  -- A genuine no-show correction can reintroduce the sanction, with a new
  -- immutable finding; it does not mutate or reactivate an organizer ruling.
  result:=fieldrush_rating_private.referee_apply_solo_arrival(referee_id,game,absent,null,
    'Video confirms the wrong player was checked in.');
  perform pg_temp.flex_expect(public.active_reliability_strikes(absent)=3
    and public.profile_has_active_reliability_booking_restriction(absent),
    'repeated correction can restore correct two-strike no-show policy');
  perform set_config('request.jwt.claim.sub',absent::text,true);
  result:=public.get_my_reliability_status();
  perform pg_temp.flex_expect((select count(*)=1 from jsonb_array_elements(result->'incidents') item
    where item->>'attendance_record_id'=current_attendance::text),'player reliability history displays one current attendance outcome');
  appeal_id:=public.submit_reliability_appeal(current_attendance,'OTHER','Please review the attendance recording carefully.');
  perform pg_temp.flex_expect((select incident_id=(select i.id from public.reliability_incidents i where i.attendance_id=current_attendance
    and i.reversal_of is null and not exists(select 1 from public.reliability_incidents r where r.reversal_of=i.id))
    from public.reliability_appeals where attendance_id=current_attendance),'new appeal targets the current corrected incident');
  perform pg_temp.flex_reject(format('select fieldrush_rating_private.referee_apply_solo_arrival(%L,%L,%L,now()-interval ''10 minutes'',%L)',
    referee_id,game,absent,'Referee cannot replace an appealed decision.'),'has an appeal');
  perform public.admin_review_reliability_appeal(admin_id,appeal_id,'UPHOLD','Organizer reviewed the evidence and upheld this finding.');
  perform pg_temp.flex_reject(format('select fieldrush_rating_private.referee_apply_solo_arrival(%L,%L,%L,now()-interval ''10 minutes'',%L)',
    referee_id,game,absent,'Referee cannot replace the organizer appeal decision.'),'has an appeal');
  perform pg_temp.flex_expect((select status='UPHELD' from public.reliability_appeals where id=appeal_id)
    and public.active_reliability_strikes(absent)=3,'final organizer appeal decision and consequences are preserved');
  insert into public.moderation_actions(subject_type,subject_profile_id,action_type,restriction_scope,reason_code,
    user_message,starts_at,ends_at,issued_by)
    values('PLAYER',late_player,'SUSPENSION','PLAY','TEST_UNRELATED','Independent organizer restriction.',
      clock_timestamp(),clock_timestamp()+interval '1 day',admin_id) returning id into moderation_id;
  result:=fieldrush_rating_private.referee_apply_solo_arrival(referee_id,game,late_player,
    (select check_in_deadline_at-interval '1 minute' from public.match_attendance_records where open_queue_game_id=game and profile_id=late_player),
    'Referee confirms arrival before the check-in deadline.');
  perform pg_temp.flex_expect(result#>>'{after,strikes}'='0' and result#>>'{after,can_book}'='false'
    and (select revoked_at is null from public.moderation_actions where id=moderation_id),
    'fixing attendance does not revoke an unrelated organizer restriction');
end;
$$;

select pg_temp.flex_expect(not has_function_privilege('authenticated',
  'fieldrush_rating_private.referee_apply_solo_arrival(uuid,uuid,uuid,timestamptz,text)','EXECUTE')
  and not has_function_privilege('service_role',
  'fieldrush_rating_private.referee_apply_solo_arrival(uuid,uuid,uuid,timestamptz,text)','EXECUTE'),
  'arrival helper stays private behind unified authorized record writer');
select count(*) as passed_checks from flex_checks;
