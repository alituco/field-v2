// Execute the real current-roster migration and lifetime visibility predicate on
// disposable PostgreSQL/PGlite. The prior authorized, masked RPC is a fixture;
// existing lifetime-privacy tests separately execute its real implementation.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
const id=n=>`10000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const viewer=id(1), game=id(100), outsider=id(99);
let checks=0;
const scalar=async(sql,args=[])=>Object.values((await db.query(sql,args)).rows[0])[0];
function equal(actual,expected,message) {assert.deepEqual(actual,expected,message); checks++;}
async function source(name) {return readFile(new URL(`../migrations/${name}`,import.meta.url),'utf8');}
async function asRole(role,sub,sql,args=[]) {
  await db.exec('begin read only');
  try {
    await db.exec(`set local role ${role}`);
    await db.query(`select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claim.role',$2,true)`,[sub,role]);
    return await scalar(sql,args);
  } finally {await db.exec('rollback');}
}
const read=()=>asRole('authenticated',viewer,'select public.get_open_queue_match_detail($1)',[game]);
const roster=(player,role,visible=true)=>({id:player,display_name:player,role,
  is_me:player===viewer,rating_visible:visible,rating_at_team_assignment:null,
  rating_at_match_start:null,rating_change:null});
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth; create schema fieldrush_rating_private;
    grant usage on schema public,auth to anon,authenticated,service_role;
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    create function auth.role() returns text language sql stable as $$
      select nullif(current_setting('request.jwt.claim.role',true),'') $$;
    create table public.fieldrush_player_rating_tracks(profile_id uuid,rating_track text,skill_rating integer,matches_played integer,
      primary key(profile_id,rating_track));
    create table public.open_queue_bookings(game_id uuid,profile_id uuid,role text,status text,
      rating_track text generated always as (case when role='GK' then 'GOALKEEPER' else 'OUTFIELD' end) stored,
      unique(game_id,profile_id));
    create table public.fixture_match_payloads(game_id uuid primary key,payload jsonb);
    grant select on public.fieldrush_player_rating_tracks,public.open_queue_bookings to service_role;
    -- Preserve an existing authorization rejection through the new wrapper.
    create function public.get_open_queue_match_detail(game_id_to_use uuid)
    returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
    declare result jsonb;
    begin
      if auth.uid() is distinct from '${viewer}'::uuid and auth.role() is distinct from 'service_role' then
        raise exception 'Existing match authorization rejected this viewer.';
      end if;
      select payload into result from public.fixture_match_payloads where game_id=game_id_to_use;
      if not found then raise exception 'Game not found.'; end if;
      return result;
    end $$;
    revoke all on function public.get_open_queue_match_detail(uuid) from public,anon;
    grant execute on function public.get_open_queue_match_detail(uuid) to authenticated,service_role;
    insert into public.fieldrush_player_rating_tracks values
      ('${viewer}','OUTFIELD',1228,2),('${viewer}','GOALKEEPER',900,0),
      ('${id(2)}','OUTFIELD',700,1),
      ('${id(3)}','OUTFIELD',1900,3),('${id(3)}','GOALKEEPER',888,1),
      ('${id(4)}','OUTFIELD',1800,3),('${id(4)}','GOALKEEPER',-15,2),
      ('${id(5)}','OUTFIELD',0,2),
      ('${id(7)}','OUTFIELD',2200,4),('${id(8)}','OUTFIELD',2300,4);
  `);
  // Use the real public lifetime predicate, including its missing-track rule.
  const visibility=await source('20261014001500_lifetime_rating_visibility.sql');
  const start=visibility.indexOf('create function fieldrush_rating_private.public_rating_state(');
  const end=visibility.indexOf('\n$$;',start);
  assert.ok(start>=0&&end>start);
  await db.exec(visibility.slice(start,end+4));
  await db.exec(`revoke all on function fieldrush_rating_private.public_rating_state(uuid,text)
    from public,anon,authenticated,service_role`);

  const payload={id:game,status:'FULL',rating_status:null,venue:'Isolated fixture',
    policy_version_id:'retained-policy',team_assignment_at:'2099-01-01T10:00:00Z',
    lobby_average_sr:1201,white_average_sr:null,events:[{id:'event',is_goal_valid:false}],
    players:[roster(viewer,'ATT'),roster(id(2),'DEF',false),roster(id(3),'GK',false),
      roster(id(4),'GK'),roster(id(5),'MID'),roster(id(6),'ATT'),
      roster(id(7),'ATT'),roster(id(8),'DEF'),roster('not-a-uuid','ATT'),
      roster(viewer,'GK'),roster(null,'ATT')]};
  await db.query('insert into public.fixture_match_payloads values($1,$2::jsonb)',[game,JSON.stringify(payload)]);
  for (const [player,role,status='CONFIRMED'] of [
    [viewer,'ATT'],[id(2),'DEF'],[id(3),'GK'],[id(4),'GK'],[id(5),'MID'],[id(6),'ATT'],[id(8),'DEF','CANCELLED'],
  ]) await db.query('insert into public.open_queue_bookings(game_id,profile_id,role,status) values($1,$2,$3,$4)',[game,player,role,status]);
  const update=async patch=>{Object.assign(payload,patch); await db.query('update public.fixture_match_payloads set payload=$1::jsonb',[JSON.stringify(payload)]);};

  // This is the observed defect: no assignment/kickoff snapshot exists yet.
  const before=await read();
  equal(before.players[0].rating_at_team_assignment,null);
  equal(before.players[0].roster_skill_rating,undefined);
  await db.exec(await source('20261027000400_current_roster_ratings.sql'));
  for (const status of ['OPEN','FULL','LIVE']) {
    await update({status,rating_status:status==='LIVE'?'UNSETTLED':null});
    const actual=await read();
    equal(actual.players.map(p=>p.roster_skill_rating),[1228,null,null,-15,0,null,null,null,null,null,null],`${status}: current SR, correct pool and visibility`);
    const withoutCurrent={...actual,players:actual.players.map(({roster_skill_rating,...player})=>player)};
    equal(withoutCurrent,payload,`${status}: every original field and roster order is retained`);
  }

  // Current public SR is independent of provisional result state. No result
  // snapshot, team strength, expected outcome or delta is unmasked by this API.
  for (const rating_status of ['UNSETTLED','HELD','NOT_RATED']) {
    await update({status:'LIVE',rating_status});
    const actual=await read();
    equal(actual.players[0].roster_skill_rating,1228);
    equal(actual.players[0].rating_at_match_start,null);
    equal(actual.players[0].rating_change,null);
    equal(actual.white_average_sr,null);
  }

  await db.exec(`update public.fieldrush_player_rating_tracks set skill_rating=1337
    where profile_id='${viewer}' and rating_track='OUTFIELD'`);
  equal((await read()).players[0].roster_skill_rating,1337,'active roster reads current canonical SR');
  for (const matches of [0,1]) {
    await db.query(`update public.fieldrush_player_rating_tracks set matches_played=$1
      where profile_id=$2 and rating_track='OUTFIELD'`,[matches,viewer]);
    equal((await read()).players[0].roster_skill_rating,null,'owner placement has no public-roster exception');
  }
  await db.exec(`update public.fieldrush_player_rating_tracks set matches_played=2
    where profile_id='${viewer}' and rating_track='OUTFIELD'`);
  equal((await read()).players[0].roster_skill_rating,1337);
  const service=await asRole('service_role','','select public.get_open_queue_match_detail($1)',[game]);
  equal(service.players[1].roster_skill_rating,null,'service role has no hidden-SR exception');
  equal(service.players[2].roster_skill_rating,null,'placed outfield SR cannot expose an unplaced keeper track');

  payload.players[0]={...payload.players[0],rating_at_team_assignment:1090,
    rating_at_match_start:1100,rating_change:28};
  for (const [status,rating_status] of [['FINAL','RATED'],['FINAL','HELD'],['CANCELLED','NOT_RATED']]) {
    await update({status,rating_status});
    equal(await read(),payload,`${status}/${rating_status}: frozen history is byte-for-byte equivalent JSON`);
  }
  await update({status:'FULL',rating_status:null,players:[]});
  equal((await read()).players,[]);
  await update({players:null});
  equal((await read()).players,[],'missing roster entries produce no numbers');

  const signature='public.get_open_queue_match_detail(uuid)';
  const internal='public.get_open_queue_match_detail_before_roster_sr(uuid)';
  equal(await scalar('select provolatile from pg_proc where oid=$1::regprocedure',[signature]),'s');
  equal(await scalar('select prosecdef from pg_proc where oid=$1::regprocedure',[signature]),true);
  for (const role of ['anon','authenticated','service_role']) {
    equal(await scalar('select has_function_privilege($1,$2,\'execute\')',[role,internal]),false,`${role} cannot call the private alias`);
  }
  equal(await scalar('select has_function_privilege(\'anon\',$1,\'execute\')',[signature]),false);
  for (const role of ['authenticated','service_role']) {
    equal(await scalar('select has_function_privilege($1,$2,\'execute\')',[role,signature]),true);
    equal(await scalar('select has_table_privilege($1,\'public.fieldrush_player_rating_tracks\',\'select\')',[role]),role==='service_role','existing table access is unchanged');
  }
  for (const [role,sub,error] of [
    ['anon','',/permission denied for function/],
    ['authenticated','',/Existing match authorization/],
    ['authenticated',outsider,/Existing match authorization/],
  ]) {await assert.rejects(asRole(role,sub,'select public.get_open_queue_match_detail($1)',[game]),error); checks++;}
  await assert.rejects(asRole('authenticated',viewer,'select public.get_open_queue_match_detail($1)',[id(999)]),/Game not found/); checks++;
  console.log(`PASS: ${checks} isolated current-roster SR, role, privacy, frozen-history, read-only and authorization checks.`);
} finally {await db.close();}
