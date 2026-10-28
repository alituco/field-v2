// Isolated PostgreSQL/PGlite pre-kickoff transfer regression; no remote DB.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite \
//   node supabase/scripts/test_season_zero_rebalance.mjs
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const {PGlite} = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
process.on('uncaughtException', error => {
  console.error(error.message); if (error.where) console.error(error.where);
  if (error.query) console.error(error.query.slice(0, 400)); process.exit(1);
});
let checks = 0;
const admin = randomUUID(), referee = randomUUID(), stranger = randomUUID();
const roles = ['GK','DEF','DEF','DEF','ATT','ATT','ATT'];
const players = ['WHITE','BLACK'].flatMap(team => roles.map((role, index) => ({id:randomUUID(), team, role, index})));
const a = players.filter(p => p.team === 'WHITE'), b = players.filter(p => p.team === 'BLACK');
const source = file => readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8');
async function actualFunction(file, name) {
  const sql = await source(file); const start = sql.search(new RegExp(`create (?:or replace )?function ${name.replaceAll('.', '\\.')}\\(`, 'i'));
  assert.ok(start >= 0); const end = sql.indexOf('\n$$;',start); assert.ok(end >= 0); return sql.slice(start,end+4);
}
async function scalar(sql, args=[]) { return Object.values((await db.query(sql,args)).rows[0])[0]; }
async function check(sql, expected=true, args=[]) { assert.deepEqual(await scalar(sql,args),expected,sql); checks++; }
const move = (p,to_team,consented=true) => ({profile_id:p.id,to_team,consented});
const pair = () => [move(b[6],'WHITE'),move(a[6],'BLACK',false)];
const reason = 'Consented pre-kickoff headcount rebalance with absent slot exchange.';
async function rebalance(id, moves=pair(), {actor=referee,request=randomUUID(),note=reason}={}) {
  return scalar('select public.referee_rebalance_season_zero_match($1,$2,$3,$4::jsonb,$5)',[actor,id,request,JSON.stringify(moves),note]);
}
const place=(gameId,entries,{actor=admin,request=randomUUID()}={})=>scalar(
  'select public.admin_assign_unassigned_open_queue_players($1,$2,$3,$4::jsonb)',[actor,gameId,request,JSON.stringify(entries)]);
async function game({omit=[],status='FULL',absent=[a[5].id,a[6].id]}={}) {
  const id=randomUUID();
  await db.query(`insert into public.open_queue_games(id,format_version,status,operational_state,starts_at,ends_at,teams_assigned_at,
    capacity,goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity)
    values($1,'FIELDRUSH_7V7',$2,'NORMAL',clock_timestamp()-interval '1 minute',clock_timestamp()+interval '59 minutes',clock_timestamp(),14,2,6,0,6)`,[id,status]);
  await db.query('insert into public.open_queue_referee_assignments values($1,$2)',[id,referee]);
  for (const p of players.filter(p=>!omit.includes(p.id))) {
    const booking=randomUUID();
    await db.query(`insert into public.open_queue_bookings(id,game_id,profile_id,role,team,status,rating_at_team_assignment)
      values($1,$2,$3,$4,$5,'CONFIRMED',1000)`,[booking,id,p.id,p.role,p.team]);
    await db.query('insert into public.match_attendance_records values($1,case when $2 then null else clock_timestamp() end)',[booking,absent.includes(p.id)]);
  }
  return id;
}
async function party(id,members,status='ACCEPTED') {
  const pid=randomUUID();
  await db.query('insert into public.open_queue_parties(id,game_id,owner_profile_id) values($1,$2,$3)',[pid,id,members[0].id]);
  for(const p of members) await db.query(`insert into public.open_queue_party_members(party_id,game_id,profile_id,status,invited_by,responded_at,joined_at)
    values($1,$2,$3,$4,$5,case when $4='ACCEPTED' then clock_timestamp() else null end,case when $4='ACCEPTED' then clock_timestamp() else null end)`,[pid,id,p.id,status,members[0].id]);
  return pid;
}
async function snapshot(id) { return scalar(`select jsonb_build_object(
  'bookings',(select jsonb_agg(to_jsonb(b) order by id) from public.open_queue_bookings b where game_id=$1),
  'game',(select to_jsonb(g) from public.open_queue_games g where id=$1),
  'attendance',(select jsonb_agg(to_jsonb(a) order by booking_id) from public.match_attendance_records a join public.open_queue_bookings b on b.id=a.booking_id where game_id=$1),
  'audit',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') from public.admin_audit_events e where entity_id=$1),
  'notifications',(select coalesce(jsonb_agg(to_jsonb(n) order by id),'[]') from public.notifications n where related_entity_id=$1),
  'requests',(select coalesce(jsonb_agg(to_jsonb(r) order by request_id),'[]') from fieldrush_rating_private.season_zero_action_requests r where game_id=$1))`,[id]); }
async function invalid(id, moves, error, options={}) {
  const before=await snapshot(id); await assert.rejects(()=>rebalance(id,moves,options),error); checks++;
  assert.deepEqual(await snapshot(id),before,'Invalid transfer rolls back bookings, audit, notifications and requests'); checks++;
}

try {
  await db.exec(`create role anon; create role authenticated; create role service_role; create schema fieldrush_rating_private;
    create table public.profiles(id uuid primary key);
    create table public.referee_profiles(profile_id uuid primary key references public.profiles,role text,is_active boolean);
    create table public.open_queue_games(id uuid primary key,format_version text,status text,operational_state text,
      starts_at timestamptz,ends_at timestamptz,actual_started_at timestamptz,teams_assigned_at timestamptz,capacity integer,goalkeeper_capacity integer,
      defender_capacity integer,midfielder_capacity integer,attacker_capacity integer,
      white_average_sr numeric(8,2),black_average_sr numeric(8,2),match_average_sr numeric(8,2),team_sr_spread numeric(8,2));
    create table public.open_queue_referee_assignments(game_id uuid,referee_id uuid);
    create table public.fixture_referee_assignments(fixture_id uuid,referee_id uuid);
    create table public.fieldrush_player_rating_tracks(profile_id uuid references public.profiles,rating_track text,
      skill_rating integer,matches_played integer,primary key(profile_id,rating_track));
    create table public.open_queue_bookings(id uuid primary key,game_id uuid references public.open_queue_games,
      profile_id uuid references public.profiles,role text,team text,status text,played boolean default false,
      rating_at_match_start integer,rating_at_team_assignment integer,rating_change integer,unique(game_id,profile_id));
    create table public.open_queue_clock_states(game_id uuid primary key,status text,started_at timestamptz,accumulated_seconds integer,duration_seconds integer);
    create table public.match_attendance_records(booking_id uuid primary key,checked_in_at timestamptz);
    create table public.open_queue_events(game_id uuid,event_type text,occurred_at timestamptz);
    create table public.match_reserve_assignments(status text,match_kind text,open_queue_game_id uuid);
    create function public.referee_start_open_queue_game(uuid,uuid[],integer) returns public.open_queue_games language sql as $$
      select * from public.open_queue_games where id=$1 $$;`);
  const partySource=await source('20260715000007_create_open_queue_parties.sql');
  await db.exec(partySource.slice(0,partySource.indexOf('drop trigger')));
  const notificationSource=await source('20260715000008_allow_open_queue_party_switches.sql');
  const nStart=notificationSource.indexOf('create table public.notifications');
  await db.exec(notificationSource.slice(nStart,notificationSource.indexOf('\n);',nStart)+4));
  const moderationSource=await source('20260715000002_create_moderation_system.sql');
  const auditStart=moderationSource.indexOf('create table if not exists public.admin_audit_events');
  await db.exec(moderationSource.slice(auditStart,moderationSource.indexOf('\n);',auditStart)+4));
  for(const [file,name] of [
    ['20260715000002_create_moderation_system.sql','public.is_active_moderation_admin'],
    ['20260716000002_enforce_reliability_attendance.sql','public.referee_can_manage_reliability_match'],
    ['20261014000200_fieldrush_independent_rating_tracks.sql','public.fieldrush_rating_track'],
  ]) await db.exec(await actualFunction(file,name));
  for(const id of [admin,referee,stranger,...players.map(p=>p.id)]) await db.query('insert into public.profiles values($1)',[id]);
  for(const [id,role] of [[admin,'admin'],[referee,'referee'],[stranger,'referee']]) await db.query('insert into public.referee_profiles values($1,$2,true)',[id,role]);
  for(const p of players) for(const track of ['OUTFIELD','GOALKEEPER']) await db.query('insert into public.fieldrush_player_rating_tracks values($1,$2,$3,10)',[p.id,track,(track==='GOALKEEPER'?1200:1000)+p.index]);
  for(const file of ['20261014001000_season_zero_sr_calculator.sql','20261014001200_season_zero_sr_timeline.sql','20261014001300_season_zero_match_evidence.sql','20261014001600_season_zero_rebalance.sql','20261027000700_admin_unassigned_players.sql']) await db.exec(await source(file));
  const legacy=await game();
  await invalid(legacy,pair(),/requires a Season 0/);
  const lateEntries=[{profile_id:a[6].id,to_team:'WHITE'},{profile_id:b[6].id,to_team:'BLACK'}];
  await db.query('update public.open_queue_bookings set team=null where game_id=$1 and profile_id=any($2::uuid[])',[legacy,[a[6].id,b[6].id]]);
  const legacyBefore=await scalar('select jsonb_agg(to_jsonb(b) order by id) from public.open_queue_bookings b where game_id=$1 and team is not null',[legacy]);
  const legacyRequest=randomUUID();
  const legacyPlaced=await place(legacy,lateEntries,{request:legacyRequest});
  assert.equal(legacyPlaced.assigned_count,2); checks++;
  await check("select rating_policy_id from public.open_queue_games where id=$1",'LEGACY',[legacy]);
  await check('select jsonb_agg(to_jsonb(b) order by id) from public.open_queue_bookings b where game_id=$1 and profile_id<>all($2::uuid[])',legacyBefore,[legacy,[a[6].id,b[6].id]]);
  await check("select count(*)::integer from public.admin_audit_events where entity_id=$1 and action='OPEN_QUEUE_UNASSIGNED_PLAYERS_PLACED'",1,[legacy]);
  await invalidPlacement(legacy,lateEntries,/already been assigned/);
  await db.query("update public.open_queue_games set status='LIVE' where id=$1",[legacy]);
  assert.deepEqual(await place(legacy,lateEntries,{request:legacyRequest}),legacyPlaced,'legacy placement retry remains idempotent after kickoff'); checks++;
  await check("select count(*)::integer from public.admin_audit_events where entity_id=$1 and action='OPEN_QUEUE_UNASSIGNED_PLAYERS_PLACED'",1,[legacy]);
  await invalidPlacement(legacy,[{...lateEntries[0],to_team:'BLACK'},lateEntries[1]],/request ID belongs/,{request:legacyRequest});

  const legacySix=await game({omit:[a[6].id,b[6].id]});
  await db.query("update public.open_queue_games set format_version='LEGACY_6V6',capacity=12,defender_capacity=4,midfielder_capacity=4,attacker_capacity=2 where id=$1",[legacySix]);
  for(const side of [a,b]) for(const [index,p] of side.slice(0,6).entries()) await db.query(
    'update public.open_queue_bookings set role=$3 where game_id=$1 and profile_id=$2',[legacySix,p.id,['GK','DEF','DEF','MID','MID','ATT'][index]]);
  await db.query('update public.open_queue_bookings set team=null where game_id=$1 and profile_id=any($2::uuid[])',[legacySix,[a[5].id,b[5].id]]);
  await invalidPlacement(legacySix,[{profile_id:a[5].id,to_team:'WHITE'},{profile_id:b[5].id,to_team:'WHITE'}],/saved game capacity/);
  await place(legacySix,[{profile_id:a[5].id,to_team:'WHITE'},{profile_id:b[5].id,to_team:'BLACK'}]);
  for(const team of ['WHITE','BLACK']) await check("select jsonb_object_agg(role,n) from (select role,count(*)::integer n from public.open_queue_bookings where game_id=$1 and team=$2 group by role) x",{GK:1,DEF:2,MID:2,ATT:1},[legacySix,team]);
  await check("select format_version||':'||rating_policy_id from public.open_queue_games where id=$1",'LEGACY_6V6:LEGACY',[legacySix]);

  const legacyPartial=await game({omit:[a[4].id,a[5].id,a[6].id,b[4].id,b[5].id,b[6].id],status:'OPEN'});
  await db.query('update public.open_queue_bookings set team=null where game_id=$1 and profile_id=$2',[legacyPartial,a[3].id]);
  await place(legacyPartial,[{profile_id:a[3].id,to_team:'WHITE'}]);
  await check("select status||':'||rating_policy_id from public.open_queue_games where id=$1",'OPEN:LEGACY',[legacyPartial]);
  await check('select count(*)::integer from public.open_queue_bookings where game_id=$1 and played',0,[legacyPartial]);
  await db.query('update public.open_queue_bookings set team=null where game_id=$1',[legacyPartial]);
  const resetEntries=players.filter(p=>[a[0],a[1],a[2],a[3],b[0],b[1],b[2],b[3]].includes(p)).map(p=>({profile_id:p.id,to_team:p.team}));
  await place(legacyPartial,resetEntries);
  await check('select count(*)::integer from public.open_queue_bookings where game_id=$1 and team is not null',8,[legacyPartial]);

  const legacyParty=await game();
  await db.query('update public.open_queue_bookings set team=null where game_id=$1 and profile_id=any($2::uuid[])',[legacyParty,[a[6].id,b[6].id]]);
  await party(legacyParty,[a[5],a[6]]);
  await invalidPlacement(legacyParty,[{...lateEntries[0],to_team:'BLACK'},{...lateEntries[1],to_team:'WHITE'}],/parties must stay together/);
  await invalidPlacement(legacyParty,[lateEntries[0]],/every unassigned player/);
  await invalidPlacement(legacyParty,[{profile_id: a[5].id,to_team:'WHITE'},...lateEntries],/already been assigned/);
  await db.query("insert into public.open_queue_events values($1,'MATCH_STARTED',clock_timestamp())",[legacyParty]);
  await invalidPlacement(legacyParty,lateEntries,/before actual kickoff/);
  await db.query('delete from public.open_queue_events where game_id=$1',[legacyParty]);
  await db.query("update public.open_queue_games set operational_state='UNDER_REVIEW' where id=$1",[legacyParty]);
  await invalidPlacement(legacyParty,lateEntries,/no active review/);
  await db.query("update public.open_queue_games set operational_state='NORMAL',actual_started_at=clock_timestamp() where id=$1",[legacyParty]);
  await invalidPlacement(legacyParty,lateEntries,/before actual kickoff/);
  await scalar('select public.admin_set_season_zero_policy($1,true,$2)',[admin,'Enable only isolated transfer test fixtures']);
  const id=await game();
  await invalid(id,pair(),/not assigned/,{actor:stranger});
  await invalid(id,[move(b[6],'WHITE',false),move(a[6],'BLACK',false)],/must agree/);
  await invalid(id,[move(b[6],'WHITE')],/no more than seven/);
  await invalid(id,[move(b[6],'WHITE'),move(a[0],'BLACK')],/position quotas/);
  await invalid(id,[move(b[6],'WHITE'),move(b[6],'WHITE')],/only once/);
  await invalid(id,[move(a[0],'WHITE')],/already assigned/);
  await invalid(id,[{profile_id:stranger,to_team:'WHITE',consented:true}],/originally confirmed/);
  await invalid(id,[{...move(b[6],'WHITE'),role:'DEF'}],/explicit consent status only/);
  await invalid(id,[{...move(b[6],'WHITE'),to_team:'GREEN'}],/explicit consent status only/);
  await invalid(id,[{...move(b[6],'WHITE'),consented:'true'}],/explicit consent status only/);
  await invalid(id,[{profile_id:b[6].id,to_team:'WHITE'}],/explicit consent status only/);
  await invalid(id,[{profile_id:'not-uuid',to_team:'WHITE',consented:true}],/Invalid player ID/);
  await invalid(id,[],/one to fourteen/);
  await invalid(id,null,/one to fourteen/);
  await invalid(id,Array(15).fill(move(b[6],'WHITE')),/one to fourteen/);
  await invalid(id,pair(),/ten and 2000/,{note:'short'});
  await invalid(id,pair(),/ten and 2000/,{note:'x'.repeat(2001)});
  for(const state of [null,'REVIEW']) {
    await db.query('update public.open_queue_games set operational_state=$2 where id=$1',[id,state]);
    await invalid(id,pair(),/before actual kickoff/);
  }
  await db.query("update public.open_queue_games set operational_state='NORMAL',teams_assigned_at=null where id=$1",[id]);
  await db.query('update public.open_queue_bookings set team=null where game_id=$1',[id]);
  await invalid(id,pair(),/before actual kickoff/);
  await db.query("update public.open_queue_bookings set team=case when profile_id=any($2::uuid[]) then 'WHITE' else 'BLACK' end where game_id=$1",[id,a.map(p=>p.id)]);
  await db.query('update public.open_queue_games set teams_assigned_at=clock_timestamp() where id=$1',[id]);
  await db.query("insert into public.open_queue_clock_states values($1,'RUNNING',clock_timestamp(),0,3600)",[id]);
  await invalid(id,pair(),/before actual kickoff/);
  await db.query('delete from public.open_queue_clock_states where game_id=$1',[id]);
  await party(id,[b[5],b[6]]);
  await invalid(id,pair(),/parties must stay together/);
  // Entire accepted party can move only with a same-role two-slot exchange.
  const partyMoves=[move(b[5],'WHITE'),move(b[6],'WHITE'),move(a[5],'BLACK',false),move(a[6],'BLACK',false)];
  const partyResult=await rebalance(id,partyMoves);
  assert.equal(partyResult.moves.length,4); checks++;
  await check("select count(distinct b.team)::integer from public.open_queue_party_members m join public.open_queue_bookings b on b.profile_id=m.profile_id and b.game_id=m.game_id where m.game_id=$1",1,[id]);

  const simple=await game(); const request=randomUUID();
  // A failure after bookings and audit insertion must undo the entire transfer.
  await db.exec("alter table public.notifications add constraint test_reject_rebalance_notification check(type<>'OPEN_QUEUE_TEAM_REASSIGNED') not valid");
  await invalid(simple,pair(),error=>error.code==='23514');
  await db.exec('alter table public.notifications drop constraint test_reject_rebalance_notification');
  const result=await rebalance(simple,pair(),{request});
  assert.equal(result.moves.length,2); checks++;
  assert.equal(result.moves.find(m=>m.profile_id===a[6].id).consented,false); checks++;
  assert.equal(result.moves.find(m=>m.profile_id===a[6].id).checked_in,false); checks++;
  assert.equal(result.moves.find(m=>m.profile_id===b[6].id).consent_recorded_by,referee); checks++;
  assert.ok(result.projected_booked_strengths.WHITE>1000); checks++;
  for(const team of ['WHITE','BLACK']) {
    await check('select count(*)::integer from public.open_queue_bookings where game_id=$1 and team=$2',7,[simple,team]);
    await check("select jsonb_object_agg(role,n) from (select role,count(*)::integer n from public.open_queue_bookings where game_id=$1 and team=$2 group by role) x",{GK:1,DEF:3,ATT:3},[simple,team]);
  }
  await check('select count(*)::integer from public.notifications where related_entity_id=$1',2,[simple]);
  await check("select count(*)::integer from public.admin_audit_events where entity_id=$1 and before_state->'roster' @> $2::jsonb",1,[simple,JSON.stringify([{profile_id:b[6].id,team:'BLACK'}])]);
  await check('select count(*)::integer from public.open_queue_bookings b join public.match_attendance_records a on a.booking_id=b.id where b.game_id=$1 and a.checked_in_at is null',2,[simple]);
  await check('select count(*)::integer from public.open_queue_bookings where game_id=$1 and played',0,[simple]);
  assert.deepEqual(await rebalance(simple,pair(),{request}),result,'idempotent exact response'); checks++;
  await check('select count(*)::integer from public.notifications where related_entity_id=$1',2,[simple]);
  await invalid(simple,[move(b[6],'BLACK'),move(a[6],'WHITE',false)],/request ID belongs/,{request});
  const acceptedIds=players.filter(p=>![a[5].id,a[6].id].includes(p.id)).map(p=>p.id);
  const started=await scalar('select public.referee_season_zero_action($1,$2,$3,0,$4::jsonb)',[referee,simple,randomUUID(),JSON.stringify({action:'START',participant_ids:acceptedIds})]);
  assert.equal(started.observed_roster.find(p=>p.id===b[6].id).team,'A'); checks++;
  assert.equal(started.observed_roster.find(p=>p.id===a[6].id).team,'B'); checks++;
  for(const [i,p] of [a[5],a[6]].entries()) {
    await db.query('update public.match_attendance_records set checked_in_at=clock_timestamp() where booking_id=(select id from public.open_queue_bookings where game_id=$1 and profile_id=$2)',[simple,p.id]);
    const joined=await scalar('select public.referee_season_zero_action($1,$2,$3,$4,$5::jsonb)',[referee,simple,randomUUID(),i+1,JSON.stringify({action:'JOIN',profile_id:p.id})]);
    assert.equal(joined.audit.players[p.id].final_state,'ACTIVE'); checks++;
  }
  await invalid(simple,[move(b[6],'BLACK'),move(a[6],'WHITE')],/before actual kickoff/);
  assert.deepEqual(await rebalance(simple,pair(),{request}),result,'successful pre-kickoff retry remains idempotent after start'); checks++;

  const incomplete=await game({omit:[a[6].id],status:'OPEN',absent:[]});
  await invalid(incomplete,[move(b[0],'WHITE')],/position quotas/);
  await rebalance(incomplete,[move(b[6],'WHITE')]);
  await check("select count(*)::integer from public.open_queue_bookings where game_id=$1 and team='WHITE'",7,[incomplete]);
  await check("select count(*)::integer from public.open_queue_bookings where game_id=$1 and team='BLACK'",6,[incomplete]);
  const stale=await game();
  await db.query('update public.open_queue_games set teams_assigned_at=null where id=$1',[stale]);
  await rebalance(stale,pair());
  await check('select teams_assigned_at is not null from public.open_queue_games where id=$1',true,[stale]);
  // New null-team bookings have no previously revealed team to consent away.
  // Every slot still needs a valid final assignment in the same atomic repair.
  const newSlots=await game({absent:[]});
  await db.query('update public.open_queue_games set teams_assigned_at=null where id=$1',[newSlots]);
  await db.query('update public.open_queue_bookings set team=null where game_id=$1 and profile_id=any($2::uuid[])',[newSlots,[a[6].id,b[6].id]]);
  await invalid(newSlots,[move(a[6],'WHITE',false)],/final team to every/);
  const filled=await rebalance(newSlots,[move(a[6],'WHITE',false),move(b[6],'BLACK',false)]);
  assert.ok(filled.moves.every(m=>m.from_team===null && m.checked_in && !m.consented)); checks++;
  await check('select teams_assigned_at is not null from public.open_queue_games where id=$1',true,[newSlots]);
  const invited=await game(); await party(invited,[b[5],b[6]],'INVITED');
  await rebalance(invited,pair());
  await check("select count(*)::integer from public.open_queue_party_members where game_id=$1 and status='INVITED'",2,[invited]);
  // The saved formation, including the newer 1/2/4 default, is authoritative.
  // This setup models a game originally booked with that formation; production
  // formation-edit guards are outside this minimal-schema harness.
  const saved124=await game();
  await db.query('update public.open_queue_games set defender_capacity=4,attacker_capacity=8 where id=$1',[saved124]);
  await db.query("update public.open_queue_bookings set role='ATT' where game_id=$1 and profile_id=any($2::uuid[])",[saved124,[a[3].id,b[3].id]]);
  await rebalance(saved124,pair());
  for(const team of ['WHITE','BLACK']) await check("select jsonb_object_agg(role,n) from (select role,count(*)::integer n from public.open_queue_bookings where game_id=$1 and team=$2 group by role) x",{GK:1,DEF:2,ATT:4},[saved124,team]);
  const saved106=await game();
  await db.query('update public.open_queue_games set defender_capacity=0,attacker_capacity=12 where id=$1',[saved106]);
  await db.query("update public.open_queue_bookings set role='ATT' where game_id=$1 and role='DEF'",[saved106]);
  await rebalance(saved106,pair());
  for(const team of ['WHITE','BLACK']) await check("select jsonb_object_agg(role,n) from (select role,count(*)::integer n from public.open_queue_bookings where game_id=$1 and team=$2 group by role) x",{GK:1,ATT:6},[saved106,team]);
  // The admin's narrow placement action cannot transfer an existing player,
  // including one assigned by another staff member after the form was opened.
  const placing=await game();
  await db.query('update public.open_queue_bookings set team=null where game_id=$1 and profile_id=any($2::uuid[])',[placing,[a[6].id,b[6].id]]);
  await db.query('update public.open_queue_games set teams_assigned_at=null where id=$1',[placing]);
  const assignments=[{profile_id:a[6].id,to_team:'WHITE'},{profile_id:b[6].id,to_team:'BLACK'}];
  async function invalidPlacement(gameId,entries,error,options={}) {
    const before=await snapshot(gameId);
    await assert.rejects(()=>place(gameId,entries,options),error); checks++;
    assert.deepEqual(await snapshot(gameId),before,'Rejected placement preserves roster, audit and notifications'); checks++;
  }
  await invalidPlacement(placing,assignments,/Only an active admin/,{actor:referee});
  await invalidPlacement(placing,[{profile_id:a[0].id,to_team:'BLACK'},...assignments],/already been assigned/);
  await invalidPlacement(placing,[{profile_id:stranger,to_team:'BLACK'},...assignments],/no longer has a confirmed booking/);
  await invalidPlacement(placing,[...assignments,assignments[0]],/only once/);
  await invalidPlacement(placing,[{...assignments[0],consented:true},assignments[1]],/Choose a player/);
  await invalidPlacement(placing,[assignments[0],{...assignments[1],to_team:'WHITE'}],/no more than seven/);
  await invalidPlacement(placing,[assignments[0]],/every original booked player/);
  const retained=await scalar('select jsonb_object_agg(profile_id,team) from public.open_queue_bookings where game_id=$1 and team is not null',[placing]);
  const placementRequest=randomUUID();
  const placed=await place(placing,assignments,{request:placementRequest});
  assert.equal(placed.action,'ASSIGN_UNASSIGNED'); checks++;
  assert.equal(placed.assigned_count,2); checks++;
  for(const [profileId,team] of Object.entries(retained)) await check('select team from public.open_queue_bookings where game_id=$1 and profile_id=$2',team,[placing,profileId]);
  await check('select count(*)::integer from public.notifications where related_entity_id=$1',2,[placing]);
  await check('select count(*)::integer from public.open_queue_bookings where game_id=$1 and played',0,[placing]);
  const savedPlacement=await snapshot(placing);
  assert.deepEqual(await place(placing,assignments,{request:placementRequest}),placed,'same request safely acknowledges an already completed placement'); checks++;
  assert.deepEqual(await snapshot(placing),savedPlacement,'retry has no duplicate notifications or audit'); checks++;
  await invalidPlacement(placing,assignments,/already been assigned/);
  await invalidPlacement(placing,[{...assignments[0],to_team:'BLACK'},assignments[1]],/request ID belongs/,{request:placementRequest});
  await db.query("update public.open_queue_games set status='LIVE' where id=$1",[placing]);
  assert.deepEqual(await place(placing,assignments,{request:placementRequest}),placed,'completed placement can be acknowledged after kickoff'); checks++;

  const partyPlacement=await game();
  await db.query('update public.open_queue_bookings set team=null where game_id=$1 and profile_id=any($2::uuid[])',[partyPlacement,[a[6].id,b[6].id]]);
  await party(partyPlacement,[a[5],a[6]]);
  await invalidPlacement(partyPlacement,[{...assignments[0],to_team:'BLACK'},{...assignments[1],to_team:'WHITE'}],/parties must stay together/);
  await db.query("update public.open_queue_games set operational_state='REVIEW' where id=$1",[partyPlacement]);
  await invalidPlacement(partyPlacement,assignments,/before actual kickoff/);
  await db.query("update public.open_queue_games set operational_state='NORMAL',status='LIVE' where id=$1",[partyPlacement]);
  await invalidPlacement(partyPlacement,assignments,/before actual kickoff/);

  for(const role of ['anon','authenticated']) {
    await check("select has_function_privilege($1,'public.admin_assign_unassigned_open_queue_players(uuid,uuid,uuid,jsonb)','EXECUTE')",false,[role]);
    await check("select has_function_privilege($1,'public.referee_rebalance_season_zero_match(uuid,uuid,uuid,jsonb,text)','EXECUTE')",false,[role]);
  }
  await check("select has_function_privilege('service_role','public.admin_assign_unassigned_open_queue_players(uuid,uuid,uuid,jsonb)','EXECUTE')",true);
  await check("select has_function_privilege('service_role','public.referee_rebalance_season_zero_match(uuid,uuid,uuid,jsonb,text)','EXECUTE')",true);
  await check('select count(*)::integer from public.fieldrush_player_rating_tracks where matches_played<>10',0);
  await check('select count(*)::integer from public.open_queue_bookings where rating_change is not null',0);
  console.log(`PASS: ${checks} atomic pre-kickoff transfer checks: formation, accepted parties, consent, absent slots, both late arrivals, audit, notifications, idempotency and rollback.`);
  console.log('NOT TESTED: API/JWT relay, UI consent collection, notification delivery outside the existing in-app outbox, full migration replay, or real multi-connection races. No production database or policy activation occurred.');
} finally { await db.close(); }
