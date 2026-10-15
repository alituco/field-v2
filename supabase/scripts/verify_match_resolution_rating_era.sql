-- Independent current-period regressions complement the historical correction
-- verifier. All identities, cases, games, payments and settings roll back.
begin;
select set_config('request.jwt.claim.role','service_role',true);

create function pg_temp.expect_replay(condition boolean,message text)
returns void language plpgsql as $$
begin if condition is distinct from true then raise exception 'Rating-era correction: %',message; end if; end;
$$;

do $verify$
declare
  actors uuid[]:=array[]::uuid[]; actor uuid; admin_id uuid; home_player uuid; away_player uuid;
  home_clan uuid; away_clan uuid; fixture uuid; solo_game uuid; i integer; match_day date;
  kickoff timestamptz; settings_before boolean; terms public.match_reliability_terms;
  result jsonb; payload jsonb; track_before jsonb; after_first jsonb; clan_after_first jsonb;
  home_score integer; away_score integer;
begin
  for i in 1..14 loop
    actor:=gen_random_uuid(); actors:=array_append(actors,actor);
    insert into auth.users(id,phone,phone_confirmed_at) values(actor,'155599920'||lpad(i::text,2,'0'),now());
    -- This rollback-only correction regression intentionally retains legacy SR.
    delete from fieldrush_rating_private.season_zero_initialization_eligibility where user_id=actor;
    insert into public.profiles(id,auth_user_id,display_name,username)
    values(actor,actor,'Rating replay player '||i,'rating_replay_'||i) on conflict(id) do nothing;
    insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at)
    values(actor,'active',now()) on conflict(user_id) do update set status='active',onboarding_completed_at=now();
  end loop;
  admin_id:=actors[1]; home_player:=actors[1]; away_player:=actors[8];
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
  values(admin_id,'Rating replay admin','+15559992001','admin',true);
  insert into public.clans(name,tag,created_by,theme_id) values('Rating Replay Home','RRH',home_player,'electric') returning id into home_clan;
  insert into public.clans(name,tag,created_by,theme_id) values('Rating Replay Away','RRA',away_player,'electric') returning id into away_clan;
  for i in 1..14 loop
    insert into public.clan_members(clan_id,profile_id,role)
    values(case when i<=7 then home_clan else away_clan end,actors[i],'member') on conflict(clan_id,profile_id) do nothing;
  end loop;
  select d::date into match_day from generate_series(current_date+7,current_date+35,interval '1 day') d
  where extract(isodow from d) in (2,5) and not exists(
    select 1 from public.fixtures f where f.match_date=d::date and f.time_slot='7:00 PM - 8:00 PM'
      and f.status in ('OPEN','SCHEDULED','LIVE')) order by d limit 1;
  perform pg_temp.expect_replay(match_day is not null,'an isolated future clan slot is available');
  select clan_enabled into settings_before from public.game_payment_settings where singleton;
  update public.game_payment_settings set clan_enabled=true where singleton;
  insert into public.fixtures(status,home_clan_id,away_clan_id,venue,day,time_slot,match_date,created_by,home_paid_by,away_paid_by)
  values('SCHEDULED',home_clan,away_clan,'Rollback current-era correction',
    case when extract(isodow from match_day)=2 then 'TUESDAY' else 'FRIDAY' end,
    '7:00 PM - 8:00 PM',match_day,admin_id,home_player,away_player) returning id into fixture;
  update public.game_payment_settings set clan_enabled=settings_before where singleton;
  kickoff:=public.fixture_start_at(match_day,'7:00 PM - 8:00 PM');
  perform pg_temp.expect_replay(public.player_rating_effective_at_is_current(kickoff),'clan regression is after the reset cutoff');
  terms:=public.ensure_match_reliability_terms('CLAN',fixture);
  -- A server-owned synthetic review case exercises the real resolver without
  -- changing the detector's clock or weakening its overdue-match conditions.
  insert into public.match_resolution_cases(match_kind,fixture_id,reason_code,scheduled_end_at,high_priority_at,policy_snapshot)
  values('CLAN',fixture,'RESULT_MISSING',kickoff+interval '1 hour',kickoff+interval '1 day',terms.policy_snapshot);
  select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id,r.rating_track) into track_before
  from public.fieldrush_player_rating_tracks r where r.profile_id=any(actors);
  result:=public.admin_resolve_match_case(admin_id,'CLAN',fixture,0,'HOME_NO_SHOW','Isolated current-period no-show finding.',
    jsonb_build_object('attendance',jsonb_build_object('HOME','NO_SHOW','AWAY','PRESENT'),'home_strikes',0,'away_strikes',0));
  perform pg_temp.expect_replay(not exists(select 1 from public.player_rating_events where source_type='CLAN_FIXTURE' and source_id=fixture),
    'unplayed clan forfeit creates no player events');
  select f.home_score,f.away_score into home_score,away_score from public.fixtures f where f.id=fixture;
  payload:=jsonb_build_object('home_score',home_score,'away_score',away_score,'attendance',jsonb_build_object('players',jsonb_build_array(
    jsonb_build_object('profile_id',home_player,'state','PRESENT'),jsonb_build_object('profile_id',away_player,'state','PRESENT'))));
  result:=public.admin_resolve_match_case(admin_id,'CLAN',fixture,1,'RECORDED_RESULT','Explicit current-period evidence restores both played sides.',payload);
  perform pg_temp.expect_replay(result#>>'{consequences,initial_player_sr_pipeline_replayed}'='true','same-score clan correction crosses the real replay boundary');
  perform pg_temp.expect_replay((select count(*)=2 from public.fixture_player_appearances where fixture_id=fixture and played)
    and (select count(*)=2 from public.fixture_player_appearances where fixture_id=fixture and played and profile_id in(home_player,away_player)),
    'clan correction restores only the two named participants');
  perform pg_temp.expect_replay((select count(*)=2 from public.player_rating_events where source_type='CLAN_FIXTURE' and source_id=fixture)
    and (select count(distinct profile_id)=2 from public.player_rating_events where source_type='CLAN_FIXTURE' and source_id=fixture and profile_id in(home_player,away_player)),
    'current-period clan correction creates exactly two immutable player events');
  perform pg_temp.expect_replay((select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id,r.rating_track)
    from public.fieldrush_player_rating_tracks r where r.profile_id=any(actors))=track_before,
    'legacy clan correction cannot alter either new solo discipline');
  select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id) into after_first from public.player_ratings r where r.profile_id=any(actors);
  select jsonb_agg(jsonb_build_object('id',c.id,'skill_rating',c.skill_rating,'wins',c.wins,'losses',c.losses) order by c.id)
    into clan_after_first from public.clans c where c.id in(home_clan,away_clan);
  result:=public.admin_resolve_match_case(admin_id,'CLAN',fixture,2,'RECORDED_RESULT','Repeating current-period evidence must preserve the existing ledger.',payload);
  perform pg_temp.expect_replay((select count(*)=2 from public.player_rating_events where source_type='CLAN_FIXTURE' and source_id=fixture)
    and (select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id) from public.player_ratings r where r.profile_id=any(actors))=after_first,
    'clan replay retries do not award player SR twice');
  perform pg_temp.expect_replay((select jsonb_agg(jsonb_build_object('id',c.id,'skill_rating',c.skill_rating,'wins',c.wins,'losses',c.losses) order by c.id)
    from public.clans c where c.id in(home_clan,away_clan))=clan_after_first,'same-score correction preserves Clan SR and results');
  perform pg_temp.expect_replay((select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id,r.rating_track)
    from public.fieldrush_player_rating_tracks r where r.profile_id=any(actors))=track_before,
    'clan replay retries preserve both new solo disciplines');

  -- Current 7v7 solo corrections must still create independent booked-role
  -- events, while the historical 6v6 scenario above must create none.
  kickoff:=date_trunc('minute',clock_timestamp())+interval '3 days';
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils)
  values('OPEN','Rollback current-era solo correction',kickoff,kickoff+interval '1 hour',0) returning id into solo_game;
  insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
  values(solo_game,home_player,'GK','CONFIRMED',0,0,'FREE'),(solo_game,away_player,'DEF','CONFIRMED',0,0,'FREE');
  update public.open_queue_bookings set team=case when profile_id=home_player then 'WHITE' else 'BLACK' end where game_id=solo_game;
  terms:=public.ensure_match_reliability_terms('SOLO',solo_game);
  insert into public.match_resolution_cases(match_kind,open_queue_game_id,reason_code,scheduled_end_at,high_priority_at,policy_snapshot)
  values('SOLO',solo_game,'RESULT_MISSING',kickoff+interval '1 hour',kickoff+interval '1 day',terms.policy_snapshot);
  result:=public.admin_resolve_match_case(admin_id,'SOLO',solo_game,0,'HOME_NO_SHOW','Isolated current-period solo no-show finding.',
    jsonb_build_object('attendance',jsonb_build_object('WHITE','NO_SHOW','BLACK','PRESENT'),'home_strikes',0,'away_strikes',0));
  payload:=jsonb_build_object('home_score',2,'away_score',1,'attendance',jsonb_build_object('players',jsonb_build_array(
    jsonb_build_object('profile_id',home_player,'state','PRESENT'),jsonb_build_object('profile_id',away_player,'state','PRESENT'))));
  -- Like the real-kickoff rating regression, bind the existing service-side
  -- early-finalization test setting to this one transaction-local game. The
  -- case must start after CI's just-created reset; all rating/attendance
  -- triggers still run and the normal cutoff remains covered separately.
  perform set_config('field.allow_early_open_queue_finalization',solo_game::text,true);
  result:=public.admin_resolve_match_case(admin_id,'SOLO',solo_game,1,'RECORDED_RESULT','Explicit current-period solo evidence restores both booked positions.',payload);
  perform set_config('field.allow_early_open_queue_finalization','',true);
  perform pg_temp.expect_replay((select count(*)=2 from public.open_queue_bookings where game_id=solo_game and status='CONFIRMED' and played),
    'solo correction restores the exact two played bookings');
  perform pg_temp.expect_replay((select count(*)=2 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id=solo_game)
    and exists(select 1 from public.player_rating_events where source_id=solo_game and profile_id=home_player and rating_track='GOALKEEPER' and rating_before=1200)
    and exists(select 1 from public.player_rating_events where source_id=solo_game and profile_id=away_player and rating_track='OUTFIELD' and rating_before=1200),
    'current 7v7 correction creates two events in the actual booked disciplines');
  perform pg_temp.expect_replay((select count(*)=2 from public.player_rating_events e
    join public.fieldrush_player_rating_tracks r on r.profile_id=e.profile_id and r.rating_track=e.rating_track
    where e.source_id=solo_game and r.skill_rating=e.rating_after and r.matches_played=1),
    'played solo corrections update both canonical role ratings exactly once');
  perform pg_temp.expect_replay((select skill_rating=1200 and matches_played=0 from public.fieldrush_player_rating_tracks where profile_id=home_player and rating_track='OUTFIELD')
    and (select skill_rating=1200 and matches_played=0 from public.fieldrush_player_rating_tracks where profile_id=away_player and rating_track='GOALKEEPER'),
    'solo correction leaves each unbooked discipline untouched');
  select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id,r.rating_track) into after_first
  from public.fieldrush_player_rating_tracks r where r.profile_id in(home_player,away_player);
  result:=public.admin_resolve_match_case(admin_id,'SOLO',solo_game,2,'RECORDED_RESULT','Repeating current-period solo evidence must not award another rating.',payload);
  perform pg_temp.expect_replay((select count(*)=2 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id=solo_game)
    and (select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id,r.rating_track) from public.fieldrush_player_rating_tracks r where r.profile_id in(home_player,away_player))=after_first,
    'solo replay retries preserve both canonical ratings and exactly two events');
  raise notice 'Current-period correction verified: exact clan/solo lineups, two immutable events, Clan SR, role isolation and replay idempotency.';
end;
$verify$;

rollback;
