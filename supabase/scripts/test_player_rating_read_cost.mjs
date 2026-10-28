// Real ranking/read function bodies on a disposable PostgreSQL/PGlite schema.
// Compare the complete old/new payloads and count expensive calls, not flaky
// wall-clock thresholds. No hosted data, network, or database timeout changes.
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(import.meta.url);
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
const source=name=>readFile(new URL(`../migrations/${name}`,import.meta.url),'utf8');
async function actual(file,name) {
  const sql=await source(file);
  const start=sql.search(new RegExp(`create (?:or replace )?function ${name.replaceAll('.','\\.')}\\(`,'i'));
  const end=sql.indexOf('\n$$;',start);
  assert.ok(start>=0&&end>start,name);
  return sql.slice(start,end+4);
}
const scalar=async(sql,args=[])=>Object.values((await db.query(sql,args)).rows[0])[0];
const id=i=>`00000000-0000-4000-8000-${String(i).padStart(12,'0')}`;
const rankings='20261014000300_fieldrush_city_and_role_rankings.sql';
const privacy='20261014001500_lifetime_rating_visibility.sql';
let checks=0;
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth; create schema fieldrush_private; create schema fieldrush_rating_private;
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.user',true),'')::uuid$$;
    create function auth.role() returns text language sql stable as $$select 'authenticated'::text$$;
    create table profiles(id uuid primary key,display_name text,username text,avatar_url text,account_deleted_at timestamptz);
    create table fieldrush_private.accounts(user_id uuid,preferred_city_id text);
    create table fieldrush_cities(id text primary key,display_name text);
    create table fieldrush_seasons(id text primary key,starts_on date,ends_on date,lifecycle text,minimum_rated_games integer);
    create table fieldrush_player_rating_tracks(profile_id uuid,rating_track text,skill_rating integer,last_change integer,
      initial_seed_rating integer,ratings_reset_at timestamptz default '2000-01-01',ratings_reset_sequence bigint default 0,
      primary key(profile_id,rating_track));
    create table open_queue_games(id uuid primary key,status text,rating_policy_id text,season_id text,
      timezone text,venue text,white_score integer,black_score integer);
    create table player_rating_events(id uuid primary key default gen_random_uuid(),profile_id uuid,rating_track text,
      source_type text default 'OPEN_QUEUE',source_id uuid,season_id text,market_city_id text,played_at timestamptz,
      played_timezone text default 'America/Phoenix',applied_sequence bigint generated always as identity,
      counted_as_played boolean default true,rating_before integer,rating_after integer,rating_change integer,result text,side text);
    create table open_queue_goals(game_id uuid,profile_id uuid);
    create table reliability_sr_appeal_adjustments(id uuid,rating_event_id uuid,rating_adjustment integer);
    create table match_resolution_cases(id uuid,open_queue_game_id uuid);
    create table match_resolution_revisions(case_id uuid,revision integer,resolution_type text);
    create table current_match_attendance_records(match_kind text,open_queue_game_id uuid,profile_id uuid,outcome text);
    create table fieldrush_rating_private.season_zero_rating_baselines(profile_id uuid,rating_track text,baseline jsonb);
    create table fieldrush_rating_private.season_zero_matches(game_id uuid,started_at timestamptz,observed_roster jsonb,settlement_status text);
    create table fieldrush_rating_private.season_zero_legacy_movements(id bigint,source_game_id uuid,ordering_at timestamptz,
      profile_id uuid,rating_track text,movement jsonb);
    create table fieldrush_rating_private.season_zero_active_settlements(game_id uuid,settlement_id bigint);
    create table fieldrush_rating_private.season_zero_settlement_revisions(id bigint,status text,calculation jsonb);
    insert into fieldrush_cities values('phoenix','Phoenix'),('london','London');
    insert into fieldrush_seasons values('past','2020-01-01','2020-12-31','ENDED',2),
      ('active','2021-01-01','2021-12-31','ACTIVE',3),('future','2090-01-01','2090-12-31','SCHEDULED',2),
      ('draft','2091-01-01','2091-12-31','DRAFT',20);
  `);
  const view=(await source(privacy)).match(/create or replace view fieldrush_rating_private\.eligible_track_events as[\s\S]*?;/)[0];
  await db.exec(view);
  for(const [file,name] of [
    ['20261014001400_season_zero_sr_settlement.sql','fieldrush_rating_private.season_zero_track_rating_at'],
    [privacy,'fieldrush_rating_private.track_rating_at'],
    ['20261014000800_fieldrush_season_management.sql','fieldrush_rating_private.season_track_events'],
    [rankings,'fieldrush_rating_private.primary_season_cities'],
    [rankings,'fieldrush_rating_private.validate_ranking_request'],
    ['20261014000200_fieldrush_independent_rating_tracks.sql','fieldrush_rating_private.replace_required'],
    [rankings,'public.get_fieldrush_player_ratings'],
  ]) await db.exec(await actual(file,name));
  await db.exec((await actual('20261014000700_fieldrush_season_rewards.sql','fieldrush_rating_private.track_rankings'))
    .replace('having count(*)>=2',"having count(*)>=coalesce((select minimum_rated_games from public.fieldrush_seasons where starts_on=season_starts_on and ends_on=season_ends_on and lifecycle<>'DRAFT'),2)"));
  await db.exec(`
    alter function public.get_fieldrush_player_ratings(uuid,date,date) rename to get_fieldrush_player_ratings_before_sr_privacy;
    revoke all on function public.get_fieldrush_player_ratings_before_sr_privacy(uuid,date,date) from public,anon,authenticated,service_role;
    revoke all on function fieldrush_rating_private.track_rating_at(uuid,text,date) from public,anon,authenticated,service_role;
    -- Instrument actual implementations so active reads cannot accidentally
    -- replay history, nor calculate the same leaderboard repeatedly.
    create sequence replay_calls minvalue 0 start 0;
    create sequence ranking_calls minvalue 0 start 0;
    alter function fieldrush_rating_private.season_zero_track_rating_at(uuid,text,date) rename to real_season_zero_track_rating_at;
    create function fieldrush_rating_private.season_zero_track_rating_at(uuid,text,date)
      returns table(skill_rating integer,last_change integer) language plpgsql stable as $$begin
        perform nextval('replay_calls'); return query select * from fieldrush_rating_private.real_season_zero_track_rating_at($1,$2,$3);
      end$$;
    alter function fieldrush_rating_private.track_rankings(text,text,text,date,date) rename to real_track_rankings;
    create function fieldrush_rating_private.track_rankings(text,text,text,date,date)
      returns table(rank bigint,profile_id uuid,display_name text,username text,avatar_url text,skill_rating integer,
        matches_played integer,wins integer,losses integer,draws integer,last_change integer,region text,primary_city_id text,primary_city_name text)
      language plpgsql stable as $$begin perform nextval('ranking_calls');
        return query select * from fieldrush_rating_private.real_track_rankings($1,$2,$3,$4,$5); end$$;
  `);
  // Ties, differing cities/roles, a placement player, no games, a deleted
  // player, and history beyond the 50-event limit exercise the whole payload.
  for(let i=1;i<=12;i++) {
    await db.query('insert into profiles values($1,$2,$3,null,$4)',[id(i),i<=4?'Tied':`Player ${i}`,`player${i}`,i===12?'2022-01-01':null]);
    await db.query("insert into fieldrush_private.accounts values($1,'london')",[id(i)]);
    for(const track of ['OUTFIELD','GOALKEEPER']) {
      await db.query('insert into fieldrush_player_rating_tracks(profile_id,rating_track,skill_rating,last_change,initial_seed_rating) values($1,$2,$3,17,850)',[id(i),track,i<=4?1100:900+i*10]);
      // Include real replay state for one player; the others use legacy history.
      if(i===1) await db.query("insert into fieldrush_rating_private.season_zero_rating_baselines values($1,$2,'{\"sr\":1000,\"last_change\":0}')",[id(i),track]);
      for(const season of ['past','active','future','draft']) {
        const count=i===10||(i===4&&track==='GOALKEEPER')?1:i===11?0:i===1&&track==='OUTFIELD'?55:3;
        for(let n=0;n<count;n++) {
          const game=await scalar(`insert into open_queue_games values(gen_random_uuid(),'FINAL','legacy',$1,'America/Phoenix','Test pitch',3,1) returning id`,[season]);
          const city=(n===0||i%2===0)?'london':'phoenix';
          const event=await scalar(`insert into player_rating_events(profile_id,rating_track,source_id,season_id,market_city_id,played_at,
            rating_before,rating_after,rating_change,result,side) values($1,$2,$3,$4,$5,$6,1000,1017,17,$7,$8) returning id`,
            [id(i),track,game,season,city,`${{past:2020,active:2021,future:2090,draft:2091}[season]}-06-01T12:00:00Z`,n%3===0?'WIN':n%3===1?'LOSS':'DRAW',n%2?'BLACK':'WHITE']);
          if(n===1) await db.query('insert into reliability_sr_appeal_adjustments values(gen_random_uuid(),$1,5)',[event]);
          if(i%3===0) await db.query('insert into open_queue_goals values($1,$2)',[game,id(i)]);
          if(i===1&&n===0) {
            await db.query("insert into fieldrush_rating_private.season_zero_matches values($1,$2,$3,'RATED')",[game,`${{past:2020,active:2021,future:2090,draft:2091}[season]}-06-01T12:00:00Z`,JSON.stringify([{id:id(i),rating_track:track}])]);
            await db.query("insert into fieldrush_rating_private.season_zero_legacy_movements values(1,$1,$2,$3,$4,'{\"sr\":25,\"last_change\":25}')",[game,`${{past:2020,active:2021,future:2090,draft:2091}[season]}-06-01T12:00:00Z`,id(i),track]);
          }
        }
      }
    }
  }
  // Empty/missing tracks keep their prior fallback; legacy attendance and
  // counted filters are still evaluated by the actual eligibility view.
  await db.query("delete from fieldrush_player_rating_tracks where profile_id=$1 and rating_track='GOALKEEPER'",[id(11)]);
  await db.query(`insert into current_match_attendance_records
    select 'SOLO',source_id,profile_id,'NO_SHOW' from player_rating_events
    where profile_id=$1 and result='LOSS'`,[id(2)]);
  await db.query("update player_rating_events set counted_as_played=false where profile_id=$1 and result='DRAW'",[id(3)]);
  await db.exec('analyze');
  const samples=[];
  const read=(player,start,end)=>scalar('select public.get_fieldrush_player_ratings_before_sr_privacy($1,$2,$3)',[player,start,end]);
  const beginOld=performance.now();
  for(const player of [1,2,3,4,10,11]) for(const year of [2020,2021,2090,2091,2019]) for(const owner of [true,false]) {
    await db.query("select set_config('test.user',$1,false)",[id(owner?player:9)]);
    samples.push({player,year,owner,payload:await read(id(player),`${year}-01-01`,`${year}-12-31`)});
  }
  const oldMs=performance.now()-beginOld;
  const oldRanks=await scalar('select last_value from ranking_calls');
  assert.equal(oldRanks,samples.length*6-1);
  await db.exec("select setval('replay_calls',0,false)");
  await read(id(1),'2021-01-01','2021-12-31');
  assert.equal(await scalar('select is_called from replay_calls'),true,'old active-season read unnecessarily replays history'); checks++;
  await db.exec(await source('20261021000100_bound_player_rating_reads.sql'));
  const beginNew=performance.now();
  for(const {player,year,owner,payload} of samples) {
    await db.query("select set_config('test.user',$1,false)",[id(owner?player:9)]);
    assert.deepEqual(await read(id(player),`${year}-01-01`,`${year}-12-31`),payload,`payload ${player}/${year}/${owner}`);
    checks++;
  }
  console.log(`Payload parity: ${samples.length} exact comparisons; old ${Math.round(oldMs)}ms, new ${Math.round(performance.now()-beginNew)}ms (local diagnostic, not a timing assertion).`);
  for(const [player,expected] of [[1,2],[4,1],[10,0],[11,0]]) {
    await db.exec("select setval('replay_calls',0,false); select setval('ranking_calls',0,false)");
    await read(id(player),'2021-01-01','2021-12-31');
    assert.equal(await scalar('select is_called from replay_calls'),false,'active season must not replay history');
    const calls=await scalar('select case when is_called then last_value+1 else 0 end from ranking_calls');
    assert.equal(Number(calls),expected,'at most one ranking calculation per qualified role'); checks+=2;
  }
  await read(id(1),'2020-01-01','2020-12-31');
  assert.equal(await scalar('select is_called from replay_calls'),true,'ended season still replays historical ratings'); checks++;
  for(const role of ['anon','authenticated','service_role']) for(const fn of [
    'public.get_fieldrush_player_ratings_before_sr_privacy(uuid,date,date)',
    'fieldrush_rating_private.track_rating_at(uuid,text,date)',
  ]) {assert.equal(await scalar('select has_function_privilege($1,$2,\'EXECUTE\')',[role,fn]),false); checks++;}
  await assert.rejects(()=>read(id(12),'2021-01-01','2021-12-31'),/Player profile not found/); checks++;
  await assert.rejects(()=>read(id(1),'2021-12-31','2021-01-01'),/valid leaderboard season/); checks++;
  console.log(`PASS: ${checks} player rating read parity, bounded expensive calls, historical replay, ACL and validation checks.`);
} finally {await db.close();}
