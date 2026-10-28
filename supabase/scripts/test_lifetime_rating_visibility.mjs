// Isolated PostgreSQL checks for the real privacy migration. Legacy RPC payloads
// are fixtures; this does not claim a full Supabase schema replay.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const user = '10000000-0000-0000-0000-000000000001';
const game = '20000000-0000-0000-0000-000000000001';
let checks = 0;
async function value(sql, args = []) { return Object.values((await db.query(sql, args)).rows[0])[0]; }
async function check(sql, expected = true, args = []) { assert.deepEqual(await value(sql, args), expected); checks++; }
async function rejects(sql, pattern) { await assert.rejects(db.exec(sql), pattern); checks++; }
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    create schema fieldrush_rating_private;
    create table profiles(id uuid primary key);
    insert into profiles values('${user}');
    create table fieldrush_player_rating_tracks(profile_id uuid,rating_track text,skill_rating integer check(skill_rating>=0),matches_played integer,last_change integer,
      ratings_reset_at timestamptz default '-infinity',ratings_reset_sequence bigint default 0,initial_seed_rating integer);
    insert into fieldrush_player_rating_tracks(profile_id,rating_track,skill_rating,matches_played,last_change) values('${user}','OUTFIELD',1080,2,40),('${user}','GOALKEEPER',1000,1,0);
    create table player_ratings(skill_rating integer check(skill_rating>=0));
    create table player_rating_events(rating_before integer check(rating_before>=0),rating_after integer check(rating_after>=0),
      rating_at_match_start integer check(rating_at_match_start>=0),team_average_rating numeric check(team_average_rating>=0),opponent_average_rating numeric check(opponent_average_rating>=0),
      profile_id uuid,rating_track text,source_type text,source_id uuid,counted_as_played boolean,played_at timestamptz,applied_sequence bigint,
      season_id text,played_timezone text,rating_change integer);
    create table open_queue_games(id uuid,status text,highest_division integer,lowest_division integer,public_label text,
      private_financial_context text,white_average_sr numeric check(white_average_sr>=0),black_average_sr numeric check(black_average_sr>=0),
      match_average_sr numeric check(match_average_sr>=0),team_sr_spread numeric,rating_policy_id text default 'LEGACY');
    insert into open_queue_games(id,status,highest_division,lowest_division,public_label,private_financial_context,white_average_sr,black_average_sr,match_average_sr,team_sr_spread)
      values('${game}','OPEN',1,5,'Pitch','private',1000,1000,1000,0);
    create table fieldrush_rating_private.season_zero_matches(game_id uuid,settlement_status text,observed_roster jsonb default '[]');
    create table fieldrush_rating_private.season_zero_settlement_revisions(id bigint primary key,status text,input_snapshot jsonb,normalization jsonb,calculation jsonb);
    create table fieldrush_rating_private.season_zero_active_settlements(game_id uuid primary key,settlement_id bigint);
    create table match_resolution_cases(id uuid,open_queue_game_id uuid);
    create table match_resolution_revisions(case_id uuid,resolution_type text,revision integer);
    create table current_match_attendance_records(match_kind text,open_queue_game_id uuid,profile_id uuid,outcome text);
    create table fieldrush_seasons(id text,starts_on date,ends_on date,lifecycle text,minimum_rated_games integer);
    create view fieldrush_rating_private.eligible_track_events as select * from player_rating_events;
    create function fieldrush_rating_private.season_zero_track_rating_at(uuid,text,date) returns table(skill_rating integer,last_change integer)
      language sql as $$select 1080,40 where false$$;
    create table open_queue_bookings(game_id uuid,profile_id uuid,role text,status text,public_label text,private_financial_context text,
      player_rating_at_booking integer check(player_rating_at_booking>=0),rating_at_team_assignment integer check(rating_at_team_assignment>=0),
      rating_at_match_start integer check(rating_at_match_start>=0),rating_change integer);
    insert into open_queue_bookings values('${game}','${user}','GK','CONFIRMED','Booked','private',1000,1000,1000,0);
    create table fixture_player_appearances(rating_at_start integer check(rating_at_start>=0),rating_change integer);
    create table reliability_sr_appeal_adjustments(rating_before_adjustment integer check(rating_before_adjustment>=0),
      rating_after_adjustment integer check(rating_after_adjustment>=0));
    grant select on player_ratings,player_rating_events,fixture_player_appearances to authenticated;
    grant select(id,status,highest_division,lowest_division,public_label,white_average_sr,black_average_sr,match_average_sr,team_sr_spread) on open_queue_games to authenticated;
    grant select(game_id,profile_id,role,status,public_label,player_rating_at_booking,rating_at_team_assignment,rating_at_match_start,rating_change) on open_queue_bookings to authenticated;
    create function fieldrush_rating_track(text) returns text language sql immutable as $$select case when $1='GK' then 'GOALKEEPER' else 'OUTFIELD' end$$;
    create function fieldrush_division_for_rating(integer) returns integer language sql immutable as $$select case when $1>=1100 then 4 else 5 end$$;
    create function fieldrush_rating_private.replace_required(definition text,needle text,replacement text) returns text language plpgsql as $$
      begin if position(needle in definition)=0 then raise exception 'Missing contract'; end if; return replace(definition,needle,replacement); end$$;
    create function search_fieldrush_players(query_to_use text) returns jsonb language plpgsql stable as $$begin
      -- case when coalesce(s.played,0)>=2 then r.skill_rating end skill_rating
      return case when query_to_use='missing' then '[]'::jsonb
        else '[{"id":"${user}","display_name":"Player","skill_rating":1080,"matches_played":0}]'::jsonb end; end$$;
    create function list_fieldrush_clan_members(clan_id_to_use uuid) returns jsonb language plpgsql stable as $$begin
      -- case when stats.played>=2 then r.skill_rating end
      return case when clan_id_to_use='00000000-0000-4000-8000-000000000000'::uuid then '[]'::jsonb
        else '[{"profile_id":"${user}","skill_rating":1080,"matches_played":0}]'::jsonb end; end$$;
    create function fieldrush_rating_private.track_rankings(text,text,text,date,date) returns jsonb language plpgsql as $$begin
      -- having count(*)>=2
      return '[]'; end$$;
  `);
  const payload = JSON.stringify({profile_id:user,ratings:{OUTFIELD:{skill_rating:1080,last_change:40,matches_played:0},
    GOALKEEPER:{skill_rating:1000,last_change:0,matches_played:1,events:[{rating_before:1000,rating_after:1000,rating_change:0}]}}});
  for (const [name,args] of [
    ['get_fieldrush_player_ratings','profile_id_to_use uuid,season_starts_on date,season_ends_on date'],
    ['get_player_rating_history','profile_id_to_use uuid,limit_to_use integer default 50'],
    ['list_fieldrush_rating_page','scope_to_use text,city_id_to_use text,rating_track_to_use text,season_starts_on date,season_ends_on date,offset_to_use integer default 0,page_size_to_use integer default 23'],
    ['list_fieldrush_placement_page','scope_to_use text,city_id_to_use text,rating_track_to_use text,season_starts_on date,season_ends_on date,offset_to_use integer default 0,page_size_to_use integer default 4'],
    ['get_open_queue_match_detail','game_id_to_use uuid'],
    ['get_fieldrush_season_rewards','season_id_to_use text,city_id_to_use text,rating_track_to_use text'],
  ]) await db.exec(`create function public.${name}(${args}) returns jsonb language sql stable as $$
      -- where (auth.uid() is null or p.id<>auth.uid())
      -- 'source_id', event.source_id,
      select '${payload}'::jsonb$$; grant execute on function public.${name} to authenticated;`);
  // The real party endpoint locks the game while resolving reliability terms.
  // Keep that contract in the fixture instead of stubbing every RPC as a read.
  await db.exec(`create function public.get_open_queue_party_context(game_id_to_use uuid)
    returns jsonb language plpgsql volatile as $$begin
      perform 1 from public.open_queue_games where id=game_id_to_use for update;
      return '${payload}'::jsonb;
    end$$; grant execute on function public.get_open_queue_party_context(uuid) to authenticated;`);
  for (const [name,args] of [['list_open_queue_games',''],['list_open_queue_fixture_games',''],['list_open_queue_games_for_market','market text'],['list_open_queue_games_for_city','city text']]) {
    await db.exec(`create function public.${name}(${args}) returns table(id uuid,white_average_sr numeric,black_average_sr numeric,match_average_sr numeric,team_sr_spread numeric)
      language sql stable as $$select id,white_average_sr,black_average_sr,match_average_sr,team_sr_spread from open_queue_games$$;`);
  }
  await db.exec(await readFile(new URL('../migrations/20261014001500_lifetime_rating_visibility.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('../migrations/20261014002100_preserve_rating_privacy_array_responses.sql', import.meta.url), 'utf8'));
  // PostgREST chooses the transaction mode for POST RPCs from pg_proc, not from
  // the HTTP method alone. Direct calls in a writable SQL session missed this.
  async function partyRpcTransaction() {
    const volatility = await value(`select provolatile from pg_proc
      where oid='public.get_open_queue_party_context(uuid)'::regprocedure`);
    await db.exec(`begin ${volatility === 'v' ? 'read write' : 'read only'}`);
    try {
      await db.exec('set local role authenticated');
      return await value(`select public.get_open_queue_party_context($1)`,[game]);
    } finally { await db.exec('rollback'); }
  }
  await assert.rejects(partyRpcTransaction(), error => error.code === '25006'
    && /SELECT FOR UPDATE.*read-only transaction/.test(error.message)); checks++;
  await db.exec(await readFile(new URL('../migrations/20261014002200_restore_party_context_write_transaction.sql', import.meta.url), 'utf8'));
  const party = await partyRpcTransaction();
  assert.equal(party.profile_id,user); checks++;
  assert.equal(party.ratings.OUTFIELD.skill_rating,1080); checks++;
  assert.equal(party.ratings.GOALKEEPER.skill_rating,null); checks++;
  await check(`select count(*)::integer from pg_proc original join pg_namespace n on n.oid=original.pronamespace
    join pg_proc wrapper on wrapper.pronamespace=original.pronamespace
      and wrapper.proname=replace(original.proname,'_before_sr_privacy','')
      and wrapper.proargtypes=original.proargtypes
    where n.nspname='public' and original.proname like '%_before_sr_privacy'
      and wrapper.provolatile=original.provolatile`,13);
  for (const role of ['anon','authenticated','service_role']) {
    await check(`select has_function_privilege($1,'get_open_queue_party_context_before_sr_privacy(uuid)','execute')`,false,[role]);
  }
  await check(`select has_function_privilege('anon','get_open_queue_party_context(uuid)','execute')`,false);
  for (const role of ['authenticated','service_role']) {
    await check(`select has_function_privilege($1,'get_open_queue_party_context(uuid)','execute')`,true,[role]);
  }
  await check(`select jsonb_array_length(public.search_fieldrush_players('Player'))`,1);
  await check(`select jsonb_array_length(public.list_fieldrush_clan_members($1))`,1,[game]);
  await check(`select public.search_fieldrush_players('missing')`,[]);
  await check(`select public.list_fieldrush_clan_members('00000000-0000-4000-8000-000000000000')`,[]);
  await check(`select public.search_fieldrush_players('Player')->0->>'id'`,user);
  await check(`select public.list_fieldrush_clan_members($1)->0->>'profile_id'`,user,[game]);
  await check(`select public.search_fieldrush_players('Player')->0->'skill_rating'`,1080);
  await db.exec(`update fieldrush_player_rating_tracks set matches_played=1 where rating_track='OUTFIELD'`);
  await check(`select public.search_fieldrush_players('Player')->0->'skill_rating'`,null);
  await check(`select public.list_fieldrush_clan_members($1)->0->'skill_rating'`,null,[game]);
  await db.exec(`update fieldrush_player_rating_tracks set matches_played=2 where rating_track='OUTFIELD'`);
  for (const signature of ['search_fieldrush_players(text)','list_fieldrush_clan_members(uuid)']) {
    await check(`select has_function_privilege('authenticated',$1,'execute')`,true,[signature]);
    await check(`select has_function_privilege('anon',$1,'execute')`,false,[signature]);
  }
  for (const signature of ['search_fieldrush_players_before_sr_privacy(text)','list_fieldrush_clan_members_before_sr_privacy(uuid)']) {
    for (const role of ['anon','authenticated','service_role']) {
      await check(`select has_function_privilege($1,$2,'execute')`,false,[role,signature]);
    }
  }
  const result = await value(`select get_fieldrush_player_ratings($1::uuid,'2027-01-01','2027-03-31')`,[user]);
  assert.equal(result.ratings.OUTFIELD.skill_rating,1080); checks++;
  assert.equal(result.ratings.OUTFIELD.lifetime_counted_matches,2); checks++;
  assert.equal(result.ratings.OUTFIELD.season_counted_matches,0); checks++;
  assert.equal(result.ratings.OUTFIELD.provisional,true); checks++;
  assert.equal(result.ratings.OUTFIELD.minimum_rated_games,2); checks++;
  assert.equal(result.ratings.GOALKEEPER.skill_rating,null); checks++;
  assert.equal(result.ratings.GOALKEEPER.last_change,null); checks++;
  assert.equal(result.ratings.GOALKEEPER.events[0].rating_before,null); checks++;
  assert.equal(result.ratings.GOALKEEPER.events[0].rating_change,null); checks++;
  assert.equal(result.placement_predictions,undefined); checks++;
  await db.exec(`select set_config('request.jwt.claim.sub','${user}',false)`);
  const owner = await value(`select get_fieldrush_player_ratings($1::uuid,'2027-01-01','2027-03-31')`,[user]);
  assert.equal(owner.placement_predictions.GOALKEEPER.skill_rating,1000); checks++;
  assert.equal(owner.placement_predictions.GOALKEEPER.lifetime_counted_matches,1); checks++;
  assert.equal(owner.placement_predictions.OUTFIELD,undefined); checks++;
  assert.equal(owner.ratings.GOALKEEPER.skill_rating,null); checks++;
  assert.equal(owner.ratings.GOALKEEPER.events[0].rating_change,null); checks++;
  await db.exec(`select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',false)`);
  const visitor = await value(`select get_fieldrush_player_ratings($1::uuid,'2027-01-01','2027-03-31')`,[user]);
  assert.equal(visitor.placement_predictions,undefined); checks++;
  await db.exec(`select set_config('request.jwt.claim.sub','',false); set role service_role`);
  const service = await value(`select get_fieldrush_player_ratings($1::uuid,'2027-01-01','2027-03-31')`,[user]);
  assert.equal(service.placement_predictions,undefined); checks++;
  await db.exec('reset role');
  await check(`select has_function_privilege('authenticated','fieldrush_rating_private.owner_placement_predictions(uuid)','execute')`,false);
  await check(`select white_average_sr from list_open_queue_games()`,null);
  const mixedHistory = {profile_id:user,source_type:'OPEN_QUEUE',source_id:game,rating_track:'OUTFIELD',
    rating_change:40,team_average_rating:1000,opponent_average_rating:1000,expected_score:0.5};
  const maskedHistory = await value(`select fieldrush_rating_private.mask_public_rating_payload($1::jsonb)`,[JSON.stringify(mixedHistory)]);
  for (const key of ['team_average_rating','opponent_average_rating','expected_score']) {
    assert.equal(maskedHistory[key],null); checks++;
  }
  assert.equal(maskedHistory.rating_change,40); checks++;
  await check(`select fieldrush_rating_private.mask_public_rating_payload('{"skill_rating":999,"last_change":9}'::jsonb)->'skill_rating'`,null);
  await db.exec(`update fieldrush_player_rating_tracks set matches_played=10 where rating_track='GOALKEEPER'`);
  await check(`select white_average_sr::integer from list_open_queue_games()`,1000);
  const visibleHistory = await value(`select fieldrush_rating_private.mask_public_rating_payload($1::jsonb)`,[JSON.stringify(mixedHistory)]);
  assert.equal(visibleHistory.team_average_rating,1000); checks++;
  assert.equal(visibleHistory.expected_score,0.5); checks++;
  await check(`select fieldrush_rating_private.public_rating_state('${user}','GOALKEEPER')->'provisional'`,false);
  for (const [table,column] of [['player_ratings','skill_rating'],['player_rating_events','rating_after'],['open_queue_bookings','rating_at_match_start'],
    ['open_queue_bookings','private_financial_context'],['open_queue_games','match_average_sr'],['open_queue_games','private_financial_context'],['fixture_player_appearances','rating_at_start']]) {
    await check(`select has_column_privilege('authenticated',$1,$2,'select')`,false,[table,column]);
  }
  for (const table of ['open_queue_games','open_queue_bookings']) await check(`select has_column_privilege('authenticated',$1,'public_label','select')`,true,[table]);
  await check(`select has_function_privilege('authenticated','get_player_rating_history_before_sr_privacy(uuid,integer)','execute')`,false);
  await check(`select has_function_privilege('authenticated','get_player_rating_history(uuid,integer)','execute')`,true);
  await db.exec(`set role authenticated`);
  await rejects(`select rating_at_match_start from open_queue_bookings`,/permission denied/);
  await rejects(`select fieldrush_rating_private.public_rating_state('${user}','GOALKEEPER')`,/permission denied/);
  await check(`select get_fieldrush_player_ratings('${user}','2027-01-01','2027-03-31')->'ratings'->'OUTFIELD'->'skill_rating'`,1080);
  await db.exec(`reset role; update fieldrush_player_rating_tracks set skill_rating=-5 where rating_track='OUTFIELD'; insert into player_ratings values(-5);`);
  await check(`select skill_rating from fieldrush_player_rating_tracks where rating_track='OUTFIELD'`,-5);
  await db.exec(`insert into fixture_player_appearances values(-5,0); insert into reliability_sr_appeal_adjustments values(-5,-1);`);
  await check(`select rating_at_start from fixture_player_appearances`,-5);
  await check(`select rating_before_adjustment from reliability_sr_appeal_adjustments`,-5);
  await db.exec(`insert into fieldrush_seasons values('three','2027-01-01','2027-03-31','ENDED',3)`);
  await check(`select get_fieldrush_player_ratings('${user}','2027-01-01','2027-03-31')->'ratings'->'OUTFIELD'->'minimum_rated_games'`,3);
  await db.exec(`update open_queue_games set status='FINAL',rating_policy_id='field-sr-season0-v2';
    insert into fieldrush_rating_private.season_zero_matches(game_id,settlement_status) values('${game}','HELD');
    insert into player_rating_events(profile_id,rating_track,source_type,source_id,counted_as_played,played_at,applied_sequence)
      values('${user}','OUTFIELD','OPEN_QUEUE','${game}',true,now(),1);
    insert into current_match_attendance_records values('SOLO','${game}','${user}','NO_SHOW');`);
  await check(`select count(*)::integer from fieldrush_rating_private.eligible_track_events`,0);
  const pending = await value(`select fieldrush_rating_private.mask_public_rating_payload($1::jsonb)`,[JSON.stringify({profile_id:user,source_type:'OPEN_QUEUE',source_id:game,rating_track:'OUTFIELD',rating_change:40})]);
  assert.equal(pending.rating_status,'HELD'); checks++;
  assert.equal(pending.rating_change,null); checks++;
  await db.exec(`update fieldrush_rating_private.season_zero_matches set settlement_status='RATED'`);
  await check(`select count(*)::integer from fieldrush_rating_private.eligible_track_events`,1);
  // Match-wide RATED does not mean that every booked player's appearance
  // counted. Only the active audited calculation supplies individual state.
  const perPlayerPayload = {profile_id:user,role:'DEF',rating_at_match_start:900,rating_change:0};
  const matchPayload = {game:{id:game,venue:'Pitch',status:'FINAL'},players:[perPlayerPayload]};
  async function settle(id,seconds,reason,counted,delta,forgiveness=0) {
    await db.query(`insert into fieldrush_rating_private.season_zero_settlement_revisions values($1,'RATED',$2::jsonb,$3::jsonb,$4::jsonb)`,[
      id,JSON.stringify({roster:[{id:user,rating_track:'OUTFIELD',sr_before:1100}]}),
      JSON.stringify({core:{players:[{id:user,actual_seconds:seconds,exit_reason:reason}]}}),
      JSON.stringify({players:{[user]:{counted,delta,sr_after:1100+delta,raw_forgiveness:forgiveness}}})]);
    await db.query(`insert into fieldrush_rating_private.season_zero_active_settlements values($1,$2)
      on conflict(game_id) do update set settlement_id=excluded.settlement_id`,[game,id]);
  }
  await settle(1,480,'EXCUSED_LEAVE',false,0);
  const short = await value(`select fieldrush_rating_private.mask_public_rating_payload($1::jsonb,null,'OUTFIELD',null,$2)`,[JSON.stringify(matchPayload),game]);
  assert.equal(short.game.rating_status,'RATED'); checks++;
  assert.equal(short.players[0].counted_as_played,false); checks++;
  assert.equal(short.players[0].actual_played_seconds,480); checks++;
  assert.match(short.players[0].rating_explanation,/8 min 0 sec played.*does not count/); checks++;
  assert.equal(short.players[0].rating_at_match_start,1100); checks++;
  assert.equal(short.players[0].rating_after,1100); checks++;
  await db.exec(`create or replace function public.get_open_queue_match_detail_before_sr_privacy(game_id_to_use uuid)
    returns jsonb language sql as $$select '${JSON.stringify(matchPayload)}'::jsonb$$;`);
  const publicDetail = await value(`select public.get_open_queue_match_detail($1)`,[game]);
  assert.equal(publicDetail.players[0].counted_as_played,false); checks++;
  assert.equal(publicDetail.players[0].actual_played_seconds,480); checks++;
  await settle(2,599,'BLUE_CARD',false,-9);
  const conduct = await value(`select fieldrush_rating_private.mask_public_rating_payload($1::jsonb,null,'OUTFIELD',null,$2)`,[JSON.stringify(perPlayerPayload),game]);
  assert.equal(conduct.counted_as_played,false); checks++;
  assert.equal(conduct.rating_change,-9); checks++;
  assert.equal(conduct.rating_after,1091); checks++;
  assert.match(conduct.rating_explanation,/Only negative conduct adjustments/); checks++;
  await db.exec(`update fieldrush_player_rating_tracks set matches_played=1 where rating_track='OUTFIELD'`);
  const hidden = await value(`select fieldrush_rating_private.mask_public_rating_payload($1::jsonb,null,'OUTFIELD',null,$2)`,[JSON.stringify(perPlayerPayload),game]);
  for (const key of ['rating_before','rating_at_match_start','rating_after','rating_change']) { assert.equal(hidden[key],null); checks++; }
  assert.equal(hidden.counted_as_played,false); checks++;
  await db.exec(`update fieldrush_player_rating_tracks set matches_played=2 where rating_track='OUTFIELD'`);
  await settle(3,600,'NONE',true,0);
  const countedDraw = await value(`select fieldrush_rating_private.mask_public_rating_payload($1::jsonb,null,'OUTFIELD',null,$2)`,[JSON.stringify(perPlayerPayload),game]);
  assert.equal(countedDraw.counted_as_played,true); checks++;
  assert.equal(countedDraw.rating_change,0); checks++;
  assert.equal(countedDraw.actual_played_seconds,600); checks++;
  await db.exec(`select set_config('request.jwt.claim.sub','${user}',false);
    update fieldrush_player_rating_tracks set matches_played=1,skill_rating=1040 where rating_track='OUTFIELD';
    update player_rating_events set rating_change=40,counted_as_played=true,played_at=now(),applied_sequence=2;`);
  await check(`select get_fieldrush_player_ratings($1,'2027-01-01','2027-03-31')->'placement_predictions'->'OUTFIELD'->'last_change'`,40,[user]);
  await db.exec(`update player_rating_events set counted_as_played=false,rating_change=-9`);
  await check(`select get_fieldrush_player_ratings($1,'2027-01-01','2027-03-31')->'placement_predictions'->'OUTFIELD'->'last_change'`,null,[user]);
  await db.exec(`update fieldrush_player_rating_tracks set matches_played=0,skill_rating=800 where rating_track='OUTFIELD'`);
  await check(`select get_fieldrush_player_ratings($1,'2027-01-01','2027-03-31')->'placement_predictions'->'OUTFIELD'->'skill_rating'`,800,[user]);
  await db.exec(`update fieldrush_player_rating_tracks set matches_played=2 where rating_track='OUTFIELD';
    select set_config('request.jwt.claim.sub','',false);`);
  await settle(4,3600,'NONE',true,-2,12);
  await check(`select fieldrush_rating_private.public_player_match_rating_state($1,$2,'OUTFIELD')->>'rating_explanation'`,
    'This appearance counts. Shorthanded loss protection applied.',[game,user]);
  await check(`select fieldrush_rating_private.public_player_match_rating_state($1,$2,'GOALKEEPER')->'counted_as_played'`,null,[game,user]);
  await db.exec(`update fieldrush_rating_private.season_zero_matches set settlement_status='HELD'`);
  const held = await value(`select fieldrush_rating_private.mask_public_rating_payload($1::jsonb,null,'OUTFIELD',null,$2)`,[JSON.stringify({...perPlayerPayload,counted_as_played:true}),game]);
  assert.equal(held.counted_as_played,null); checks++;
  assert.equal(held.rating_change,null); checks++;
  assert.equal(held.actual_played_seconds,null); checks++;
  await db.exec(`update fieldrush_rating_private.season_zero_matches set settlement_status='NOT_RATED'`);
  await check(`select fieldrush_rating_private.public_player_match_rating_state($1,$2,'OUTFIELD')->'counted_as_played'`,false,[game,user]);
  await check(`select has_function_privilege('authenticated','fieldrush_rating_private.public_player_match_rating_state(uuid,uuid,text)','execute')`,false);
  await db.exec(`update open_queue_bookings set status='CANCELLED'`);
  await check(`select fieldrush_rating_private.public_match_ratings_visible($1)`,false,[game]);
  await db.query(`update fieldrush_rating_private.season_zero_matches set settlement_status='RATED',observed_roster=$1::jsonb`,[
    JSON.stringify([{id:user,rating_track:'OUTFIELD'}])]);
  await db.exec(`update fieldrush_player_rating_tracks set matches_played=1 where rating_track='OUTFIELD'`);
  await check(`select fieldrush_rating_private.public_match_ratings_visible($1)`,false,[game]);
  await db.exec(`update fieldrush_player_rating_tracks set matches_played=2 where rating_track='OUTFIELD'`);
  await check(`select fieldrush_rating_private.public_match_ratings_visible($1)`,true,[game]);
  await db.exec(`update open_queue_games set rating_policy_id='LEGACY'`);
  await check(`select count(*)::integer from fieldrush_rating_private.eligible_track_events`,0);
  await db.exec(`update open_queue_games set white_average_sr=2147483647; update player_rating_events set team_average_rating=2147483647`);
  await check(`select white_average_sr::text from open_queue_games`,'2147483647');
  console.log(`PASS: ${checks} isolated lifetime visibility, null masking, permissions and compatibility checks.`);
} finally { await db.close(); }
