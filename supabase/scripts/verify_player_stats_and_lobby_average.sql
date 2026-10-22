-- Disposable full-schema regression. The caller must BEGIN/ROLLBACK around this
-- file; no hosted data is used and no application trigger is disabled.
set local client_min_messages=warning;
create function pg_temp.player_data_expect(ok boolean,message text)
returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Player data verification: %',message; end if; end;
$$;
create function pg_temp.player_data_denied(statement text)
returns void language plpgsql as $$
begin
  begin execute statement;
  exception when insufficient_privilege then return;
  end;
  raise exception 'Expected denied player write/read: %',statement;
end;
$$;
create temporary table player_data_fixtures(player uuid,other_player uuid,clan uuid,game uuid,empty_game uuid);
grant select on player_data_fixtures to authenticated;

do $$
declare players uuid[]:='{}'; player uuid; clan uuid; game uuid; empty_game uuid; i integer;
  kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '7 days';
begin
  perform set_config('request.jwt.claim.role','service_role',true);
  for i in 1..5 loop
    player:=gen_random_uuid();
    insert into auth.users(id,phone,phone_confirmed_at) values(player,'15557984'||lpad(i::text,3,'0'),now());
    perform set_config('request.jwt.claim.sub',player::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Player','last_name','Data',
      'username','pdcheck_'||replace(left(player::text,13),'-',''),'date_of_birth','2000-01-01',
      'email','pdcheck-'||player::text||'@example.test','skill_assessment','intermediate'),
      'fieldrush-v1','fieldrush-v1');
    players:=array_append(players,player);
  end loop;
  insert into public.clans(name,tag,created_by) values('Player data verification','PDV',players[1]) returning id into clan;
  insert into public.clan_members(clan_id,profile_id) values(clan,players[2]);
  perform pg_temp.player_data_expect(exists(select 1 from public.profile_career_entries
    where profile_id=players[2] and clan_id=clan and is_current),'membership trigger creates server-owned career entry');
  -- Existing archived career values are retained; this fix does not rewrite
  -- clan competition history or alter the separately deferred career reset bug.
  update public.profile_career_entries set apps=10,goals=3 where profile_id=players[2] and clan_id=clan;

  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Player data full lobby verification',kickoff,kickoff+interval '1 hour',0,players[1]) returning id into game;
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Player data empty lobby verification',kickoff+interval '1 day',kickoff+interval '25 hours',0,players[1]) returning id into empty_game;
  insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
    values(game,players[1],'GK','CONFIRMED',0,0,'FREE'),
      (game,players[2],'DEF','CONFIRMED',0,0,'FREE'),
      (game,players[3],'ATT','CONFIRMED',0,0,'FREE'),
      (game,players[4],'ATT','CANCELLED',0,0,'FREE');
  update public.fieldrush_player_rating_tracks set skill_rating=9000 where profile_id=players[4];
  -- The hidden goalkeeper's Outfield number is deliberately different.
  update public.fieldrush_player_rating_tracks set skill_rating=8000 where profile_id=players[1] and rating_track='OUTFIELD';
  update public.fieldrush_player_rating_tracks set skill_rating=1000,matches_played=0 where profile_id=players[1] and rating_track='GOALKEEPER';
  update public.fieldrush_player_rating_tracks set skill_rating=3000,matches_played=1 where profile_id=players[2] and rating_track='OUTFIELD';
  update public.fieldrush_player_rating_tracks set skill_rating=2000,matches_played=2 where profile_id=players[3] and rating_track='OUTFIELD';
  insert into player_data_fixtures values(players[2],players[5],clan,game,empty_game);
  perform set_config('request.jwt.claim.sub',players[2]::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
end;
$$;

set local role authenticated;
select pg_temp.player_data_denied($q$update public.profile_career_entries set apps=999,goals=999 where profile_id=auth.uid()$q$);
select pg_temp.player_data_denied($q$insert into public.profile_career_entries(profile_id,clan_name,tag,period,apps,goals)
  values(auth.uid(),'Invented clan','FAKE','2020 - 2026',999,999)$q$);
select pg_temp.player_data_denied($q$delete from public.profile_career_entries where profile_id=auth.uid()$q$);
select pg_temp.player_data_denied($q$update public.fieldrush_player_rating_tracks set skill_rating=9999 where profile_id=auth.uid()$q$);
select pg_temp.player_data_denied($q$insert into public.player_rating_events(profile_id,source_type,source_id,rating_before,rating_change,rating_after)
  values(auth.uid(),'OPEN_QUEUE',gen_random_uuid(),1,999,1000)$q$);
select pg_temp.player_data_denied($q$insert into public.open_queue_goals(game_id,team,profile_id,minute)
  select game,'WHITE',auth.uid(),1 from player_data_fixtures$q$);
select pg_temp.player_data_denied($q$select fieldrush_rating_private.lobby_rating_average(game) from player_data_fixtures$q$);
select pg_temp.player_data_denied($q$select public.get_open_queue_match_detail_before_sr_privacy(game) from player_data_fixtures$q$);

-- The normal player RPC still closes membership history through its definer
-- trigger, even though the same caller cannot edit a career row directly.
select public.leave_clan(clan) from player_data_fixtures;
select pg_temp.player_data_expect(exists(select 1 from public.profile_career_entries c,player_data_fixtures f
  where c.profile_id=f.player and c.clan_id=f.clan and not c.is_current and c.apps=10 and c.goals=3),
  'authenticated leave RPC updates membership career and preserves stored values');
select pg_temp.player_data_expect((select lobby_average_sr=2000 from player_data_fixtures f
  cross join lateral jsonb_to_record(public.get_open_queue_match_detail(f.game)) d(lobby_average_sr numeric)),
  'whole lobby includes hidden first and second placement games and uses booked goalkeeper pool');
select pg_temp.player_data_expect((select public.get_open_queue_match_detail(empty_game)->'lobby_average_sr'='null'::jsonb
  from player_data_fixtures),'empty lobby has no fabricated average');
select pg_temp.player_data_expect((select count(*)=3 and count(*) filter(where p.value->>'rating_visible'='false')=2
  and bool_and(case when p.value->>'rating_visible'='false' then
    p.value->'rating_at_match_start'='null'::jsonb and p.value->'rating_at_team_assignment'='null'::jsonb else true end)
  from player_data_fixtures f cross join lateral jsonb_array_elements(public.get_open_queue_match_detail(f.game)->'players') p(value)),
  'aggregate does not unmask placement player snapshots and cancelled players stay absent');
select pg_temp.player_data_expect((select public.get_open_queue_match_detail(game)->'match_average_sr'='null'::jsonb
  and public.get_open_queue_match_detail(game)->'white_average_sr'='null'::jsonb
  and public.get_open_queue_match_detail(game)->'black_average_sr'='null'::jsonb from player_data_fixtures),
  'existing team and match rating privacy guards stay intact');
reset role;

-- Everyone can still be in placement: the aggregate is independent of the
-- public reveal threshold, not a mean over whichever players are visible.
update public.fieldrush_player_rating_tracks r set matches_played=1
from public.open_queue_bookings b,player_data_fixtures f
where b.game_id=f.game and b.status='CONFIRMED' and b.role='ATT'
  and r.profile_id=b.profile_id and r.rating_track=b.rating_track;
set local role authenticated;
select pg_temp.player_data_expect((select (public.get_open_queue_match_detail(game)->>'lobby_average_sr')::numeric=2000
  and not exists(select 1 from jsonb_array_elements(public.get_open_queue_match_detail(game)->'players') p(value)
    where (p.value->>'rating_visible')::boolean) from player_data_fixtures),'all-hidden lobby still has full aggregate');
reset role;

-- Missing canonical data is deliberately isolated to a new test-owned lobby.
-- A known 9000-SR player must not become the advertised average of two people.
insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
select f.empty_game,f.other_player,'DEF','CONFIRMED',0,0,'FREE' from player_data_fixtures f
union all
select f.empty_game,b.profile_id,'ATT','CONFIRMED',0,0,'FREE'
from player_data_fixtures f join public.open_queue_bookings b on b.game_id=f.game and b.status='CANCELLED';
delete from public.fieldrush_player_rating_tracks r using player_data_fixtures f
where r.profile_id=f.other_player and r.rating_track='OUTFIELD';
set local role authenticated;
select pg_temp.player_data_expect((select public.get_open_queue_match_detail(empty_game)->'lobby_average_sr'='null'::jsonb
  from player_data_fixtures),'missing rating never produces a partial-roster average');
reset role;

-- Another ordinary player sees the same aggregate and retained, unforgeable
-- career totals. Ownership never selects a more permissive detail projection.
select set_config('request.jwt.claim.sub',other_player::text,true) from player_data_fixtures;
set local role authenticated;
select pg_temp.player_data_expect((select count(*)=1 and bool_and(c.apps=10 and c.goals=3)
  from player_data_fixtures f cross join lateral public.list_profile_career_entries(f.player) c where c.clan_id=f.clan),
  'other player reads unchanged server-owned career totals');
select pg_temp.player_data_expect((select (public.get_open_queue_match_detail(game)->>'lobby_average_sr')::numeric=2000
  from player_data_fixtures),'viewer receives same full-lobby aggregate');
reset role;

-- Prefer the match's recorded snapshots over today's changing ratings.
update public.open_queue_bookings b set rating_at_team_assignment=case b.role when 'GK' then 1200 when 'DEF' then 1800 else 2400 end
from player_data_fixtures f where b.game_id=f.game and b.status='CONFIRMED';
select pg_temp.player_data_expect((select (public.get_open_queue_match_detail(game)->>'lobby_average_sr')::numeric=1800
  from player_data_fixtures),'assignment snapshot precedence');
update public.open_queue_bookings b set rating_at_match_start=case b.role when 'GK' then 1300 when 'DEF' then 1900 else 2500 end
from player_data_fixtures f where b.game_id=f.game and b.status='CONFIRMED';
select pg_temp.player_data_expect((select (public.get_open_queue_match_detail(game)->>'lobby_average_sr')::numeric=1900
  from player_data_fixtures),'kickoff snapshot precedence');
set local role authenticated;
select pg_temp.player_data_expect((select bool_and(p.value->'rating_at_match_start'='null'::jsonb
  and p.value->'rating_at_team_assignment'='null'::jsonb)
  from player_data_fixtures f cross join lateral jsonb_array_elements(public.get_open_queue_match_detail(f.game)->'players') p(value)),
  'populated individual snapshots remain hidden while the full aggregate is visible');
reset role;

-- Actual managed tables exercise replayed settled snapshot selection. This is
-- a synthetic rollback-only settlement fixture, not a match-calculator test.
do $$
declare game uuid; roster jsonb; run uuid; revision bigint;
begin
  select f.game into game from player_data_fixtures f;
  select jsonb_agg(jsonb_build_object('id',b.profile_id,'rating_track',b.rating_track,'sr_before',1100)) into roster
    from public.open_queue_bookings b where b.game_id=game and b.status='CONFIRMED';
  insert into fieldrush_rating_private.season_zero_matches(game_id,started_at,scheduled_seconds,observed_roster,settlement_status)
    values(game,clock_timestamp(),3600,roster,'RATED');
  insert into fieldrush_rating_private.season_zero_settlement_runs(requested_game_id,reason)
    values(game,'Rollback-only lobby aggregate verification') returning id into run;
  insert into fieldrush_rating_private.season_zero_settlement_revisions(run_id,game_id,match_revision,status,input_snapshot)
    values(run,game,1,'RATED',jsonb_build_object('roster',roster)) returning id into revision;
  insert into fieldrush_rating_private.season_zero_active_settlements(game_id,settlement_id) values(game,revision);
end;
$$;
select pg_temp.player_data_expect((select (public.get_open_queue_match_detail(game)->>'lobby_average_sr')::numeric=1100
  from player_data_fixtures),'effective replayed settlement snapshots take precedence');
update fieldrush_rating_private.season_zero_matches s set settlement_status='HELD'
from player_data_fixtures f where s.game_id=f.game;
select pg_temp.player_data_expect((select public.get_open_queue_match_detail(game)->'lobby_average_sr'='null'::jsonb
  from player_data_fixtures),'held match keeps aggregate hidden');
update fieldrush_rating_private.season_zero_matches s set settlement_status='NOT_RATED'
from player_data_fixtures f where s.game_id=f.game;
select pg_temp.player_data_expect((select public.get_open_queue_match_detail(game)->'lobby_average_sr'='null'::jsonb
  from player_data_fixtures),'non-rated match keeps aggregate hidden');
update fieldrush_rating_private.season_zero_matches s set settlement_status='UNSETTLED'
from player_data_fixtures f where s.game_id=f.game;
update public.open_queue_games g set operational_state='UNDER_REVIEW' from player_data_fixtures f where g.id=f.game;
select pg_temp.player_data_expect((select public.get_open_queue_match_detail(game)->'lobby_average_sr'='null'::jsonb
  from player_data_fixtures),'organizer review keeps aggregate hidden');

select pg_temp.player_data_expect(not has_table_privilege('authenticated','public.profile_career_entries','INSERT')
  and not has_table_privilege('authenticated','public.profile_career_entries','UPDATE')
  and not has_table_privilege('authenticated','public.profile_career_entries','DELETE')
  and not exists(select 1 from pg_attribute where attrelid='public.profile_career_entries'::regclass and attnum>0
    and not attisdropped and (has_column_privilege('authenticated',attrelid,attnum,'INSERT')
      or has_column_privilege('authenticated',attrelid,attnum,'UPDATE'))),'no table or column write grants remain');
select pg_temp.player_data_expect(not has_function_privilege('anon','public.get_open_queue_match_detail(uuid)','EXECUTE')
  and has_function_privilege('authenticated','public.get_open_queue_match_detail(uuid)','EXECUTE')
  and has_function_privilege('service_role','public.get_open_queue_match_detail(uuid)','EXECUTE'),
  'public detail retains existing caller grants');
select pg_temp.player_data_expect((select wrapper.provolatile=original.provolatile and wrapper.provolatile='s'
  from pg_proc wrapper,pg_proc original
  where wrapper.oid='public.get_open_queue_match_detail(uuid)'::regprocedure
    and original.oid='public.get_open_queue_match_detail_before_sr_privacy(uuid)'::regprocedure),
  'detail wrapper retains the original STABLE read-only contract');
select pg_temp.player_data_expect((select indisunique and indpred is not null
  from pg_index where indexrelid='public.open_queue_active_booking_unique_idx'::regclass),
  'confirmed roster retains one active booking per player');
select 'PASS: career write containment, server membership history, Solo ledger protection, full placement lobby average, booked role, snapshots, viewer parity and privacy guards' as result;
