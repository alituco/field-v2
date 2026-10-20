// Execute recovery transactions against disposable local PostgreSQL (PGlite).
// No provider API, shared database, account or recording is touched.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || "@electric-sql/pglite");
const db = new PGlite();
let checks = 0;
const hash = value => createHash("sha256").update(value).digest("hex");
const query = (sql,args=[]) => db.query(sql,args);
const value = async (sql,args=[]) => (await query(sql,args)).rows[0]?.value;
const check = (condition,message) => { assert.ok(condition,message); checks++; };
async function rejects(sql,args,pattern) { await assert.rejects(query(sql,args),pattern); checks++; }
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create table profiles(id uuid primary key);
    create table referee_profiles(profile_id uuid primary key references profiles,display_name text,phone text,role text,is_active boolean);
    create table clans(id uuid primary key,name text);
    create table fixtures(id uuid primary key,status text,venue text,home_clan_id uuid,away_clan_id uuid,video_url text);
    create table open_queue_games(id uuid primary key,status text,venue text,starts_at timestamptz,video_url text);
    create table fixture_referee_assignments(fixture_id uuid,referee_id uuid);
    create table open_queue_referee_assignments(game_id uuid,referee_id uuid);
    create table broadcast_devices(device_key text primary key,display_name text,status text default 'OFFLINE',obs_connected boolean default false,obs_streaming boolean default false,current_fixture_id uuid,current_open_queue_game_id uuid,last_seen_at timestamptz,error_message text,metadata jsonb);
    create table fixture_broadcasts(fixture_id uuid primary key,status text,stream_requested_at timestamptz,stream_started_at timestamptz,stream_stopped_at timestamptz,recording_ready_at timestamptz,replay_hls_url text,active_video_id text,error_message text,live_input_id text);
    create table open_queue_broadcasts(game_id uuid primary key,status text,stream_requested_at timestamptz,stream_started_at timestamptz,stream_stopped_at timestamptz,recording_ready_at timestamptz,replay_hls_url text,active_video_id text,error_message text,live_input_id text);
    create table broadcast_commands(id uuid primary key default gen_random_uuid(),fixture_id uuid,open_queue_game_id uuid,device_key text,action text,requested_by uuid,status text default 'PENDING',completed_at timestamptz,error_message text);
    create table fixture_events(fixture_id uuid,event_type text,created_at timestamptz);
    create table open_queue_events(game_id uuid,event_type text,occurred_at timestamptz);
  `);
  for (const name of ["20261018000100_paired_broadcast_devices.sql","20261018000200_broadcast_recording_recovery.sql"]) await db.exec(await readFile(new URL(`../migrations/${name}`,import.meta.url),"utf8"));
  const ref = randomUUID(), other = randomUUID();
  for (const id of [ref,other]) {
    await query("insert into profiles values($1)",[id]);
    await query("insert into referee_profiles values($1,'Ref','phone','referee',true)",[id]);
  }
  const setup = async kind => {
    const id=randomUUID(), token=hash(id), key=`paired-${id}`, uid=hash(`${id}-video`).slice(0,32);
    const table=kind==="SOLO"?"open_queue_games":"fixtures", broadcast=kind==="SOLO"?"open_queue_broadcasts":"fixture_broadcasts", fk=kind==="SOLO"?"game_id":"fixture_id";
    await query(`insert into ${table}(id,status,venue,video_url) values($1,'FINAL','Pitch 1','original-replay')`,[id]);
    await query(`insert into ${broadcast}(${fk},status,stream_requested_at,stream_started_at,stream_stopped_at,replay_hls_url,active_video_id,live_input_id) values($1,'REPLAY_READY',now()-interval '100 minutes',now()-interval '100 minutes',now()-interval '10 minutes','original-replay','old-video','live-input')`,[id]);
    await query(`insert into ${kind==="SOLO"?"open_queue_referee_assignments":"fixture_referee_assignments"} values($1,$2)`,[id,ref]);
    await query("insert into broadcast_devices(device_key,display_name,status,obs_connected,last_seen_at) values($1,'Mac','READY',true,now())",[key]);
    await query("insert into broadcast_device_credentials(device_key,owner_profile_id,match_kind,fixture_id,open_queue_game_id,token_hash,expires_at,pitch_key,created_at) values($1,$2,$3,$4,$5,$6,now()+interval '20 hours','pitch',now()-interval '3 hours')",[key,ref,kind,kind==="CLAN"?id:null,kind==="SOLO"?id:null,token]);
    const time=await value("select to_char((now()-interval '110 minutes') at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') as value");
    const eventTable=kind==="SOLO"?"open_queue_events":"fixture_events", eventTime=kind==="SOLO"?"occurred_at":"created_at";
    await query(`insert into ${eventTable}(${fk},event_type,${eventTime}) values($1,'MATCH_STARTED',now()-interval '95 minutes'),($1,'MATCH_ENDED',now()-interval '15 minutes')`,[id]);
    return {id,token,key,uid,time,table,broadcast,fk,eventTable,eventTime};
  };
  const begin="select begin_broadcast_recovery($1,$2,'backup.mkv',10000000) as value";
  const store="select store_broadcast_recovery_upload($1,$2,$3,'https://upload.videodelivery.net/one-use')";
  const attach="select attach_broadcast_recovery($1,$2,$3,$4,$5) as value";
  const reserve="select reserve_broadcast_recovery_attachment($1,$2,$3,$4,$5) as value";
  const url=uid=>`https://customer-test.cloudflarestream.com/${uid}/manifest/video.m3u8`;
  const sync="select sync_broadcast_replay($1,$2,$3,$4,now(),$5,$6,$7) as value";
  for(const kind of ["SOLO","CLAN"]) {
    const f=await setup(kind);
    await rejects(begin,[hash("wrong"),f.time],/expired or was disconnected/);
    await query(`update ${f.table} set status='LIVE' where id=$1`,[f.id]);
    await rejects(begin,[f.token,f.time],/Finish the match/);
    await query(`update ${f.table} set status='FINAL' where id=$1`,[f.id]);
    for(const field of ["reservation_active","test_input_id"]) {
      await query(`update broadcast_device_credentials set ${field}=${field==="reservation_active"?"true":"'test-input'"} where device_key=$1`,[f.key]);
      await rejects(begin,[f.token,f.time],/Stop the stream/);
      await query(`update broadcast_device_credentials set ${field}=${field==="reservation_active"?"false":"null"} where device_key=$1`,[f.key]);
    }
    await query("update broadcast_devices set obs_streaming=true where device_key=$1",[f.key]);
    await rejects(begin,[f.token,f.time],/Stop the stream/);
    await query("update broadcast_devices set obs_streaming=false where device_key=$1",[f.key]);
    await rejects(begin,[f.token,new Date(Date.now()+100000).toISOString()],/saved start time/);
    await rejects("select begin_broadcast_recovery($1,$2,'/Users/ref/file.mkv',10)",[f.token,f.time],/valid complete recording/);
    const attempt=await value(begin,[f.token,f.time]);
    check(attempt.status==="PREPARING",`${kind} reserves before upload`);
    check(await value(`select video_url='original-replay' as value from ${f.table} where id=$1`,[f.id]),"prepare leaves current replay intact");
    await rejects(begin,[f.token,f.time],/being prepared/);
    await query(store,[f.token,attempt.id,f.uid]);
    check((await value(begin,[f.token,f.time])).id===attempt.id,"same prepare request reuses upload");
    await rejects(attach,[f.token,attempt.id,f.time,7000,url(f.uid)],/Reserve this recording/);
    await rejects(reserve,[f.token,attempt.id,f.time,60,url(f.uid)],/complete match/);
    await rejects(reserve,[f.token,attempt.id,new Date(Date.parse(f.time)-1000).toISOString(),7000,url(f.uid)],/saved start time/);
    await rejects(reserve,[f.token,attempt.id,f.time,7000,url(hash("wrong uid").slice(0,32))],/not ready/);
    const requested=await value(`select stream_requested_at as value from ${f.broadcast} where ${f.fk}=$1`,[f.id]);
    check(await value(sync,[kind,f.id,"old-video","old-updated",requested,null,"live-input"]),"normal sync before recovery is atomic");
    check(await value(`select video_url='old-updated' as value from ${f.table} where id=$1`,[f.id]),"normal sync updates game too");
    await rejects(reserve,[f.token,attempt.id,f.time,7000,url(f.uid)],/replay changed/);
    const fresh=await value(begin,[f.token,f.time]);
    check(fresh.id!==attempt.id,"changed replay permits explicit new prepare");
    const uid2=hash(`${f.uid}-2`).slice(0,32);
    await query(store,[f.token,fresh.id,uid2]);
    check((await value(reserve,[f.token,fresh.id,f.time,7000,url(uid2)])).reserved,"complete backup reserves publication first");
    check((await value(reserve,[f.token,fresh.id,f.time,7000,url(uid2)])).reserved,"same reservation is idempotent after a lost response");
    check(await value(`select video_url='old-updated' as value from ${f.table} where id=$1`,[f.id]),"reserved publication keeps the old replay playable");
    check(!(await value(sync,[kind,f.id,"old-video","stale-url",requested,null,"live-input"])),"normal sync cannot change reserved publication");
    await rejects(`update ${f.broadcast} set stream_started_at=now() where ${f.fk}=$1`,[f.id],/replacement is reserved/);
    await rejects(`update ${f.table} set video_url='stale-direct-update' where id=$1`,[f.id],/replacement is reserved/);
    await rejects(reserve,[f.token,fresh.id,f.time,7001,url(uid2)],/reserved recording changed/);
    await query("update broadcast_recording_recoveries set expires_at=now()-interval '1 minute' where id=$1",[fresh.id]);
    check((await value(begin,[f.token,f.time])).id===fresh.id,"reserved publication survives upload expiry");
    check((await value(attach,[f.token,fresh.id,f.time,7000,url(uid2)])).attached,"complete matching backup attaches");
    check((await value(attach,[f.token,fresh.id,f.time,7000,url(uid2)])).attached,"repeat attach is idempotent");
    const saved=(await query(`select * from ${f.broadcast} where ${f.fk}=$1`,[f.id])).rows[0];
    check(saved.active_video_id===uid2&&saved.recovery_upload_id===fresh.id,"replacement records provider and recovery provenance");
    check(await value(`select stream_started_at=$2::timestamptz as value from ${f.broadcast} where ${f.fk}=$1`,[f.id,f.time]),"exact recording start anchors clips");
    check(await value(`select video_url=$2 as value from ${f.table} where id=$1`,[f.id,url(uid2)]),"game replay and broadcast commit together");
    check(!(await value(sync,[kind,f.id,"old-video","stale-url",requested,null,"live-input"])),"late normal poll/webhook cannot overwrite recovery");
    await query("delete from broadcast_device_credentials where device_key=$1",[f.key]);
    check(await value(`select recovery_upload_id=$2 as value from ${f.broadcast} where ${f.fk}=$1`,[f.id,fresh.id]),"recovery guard survives credential removal");
  }
  const f=await setup("SOLO");
  const requested=await value(`select stream_requested_at as value from ${f.broadcast} where ${f.fk}=$1`,[f.id]);
  check(!(await value(sync,["SOLO",f.id,"old-video","stale",null,null,"live-input"])),"null requested timestamp cannot match nonnull generation");
  check(!(await value(sync,["SOLO",f.id,"different-video","stale",requested,null,"live-input"])),"stale active video cannot replace current one");
  check(!(await value(sync,["SOLO",f.id,"old-video","stale",requested,null,"different-input"])),"provider input identity is checked");
  check(!(await value(sync,["SOLO",f.id,"old-video","stale",requested,new Date(Date.parse(requested)-120000).toISOString(),"live-input"])),"recording predating request cannot overwrite newer source");
  await query("update open_queue_broadcasts set stream_requested_at=null where game_id=$1",[f.id]);
  check(await value(sync,["SOLO",f.id,"old-video","valid-null",null,null,"live-input"]),"null compares null exactly for legacy sessions");
  const attempt=await value(begin,[f.token,f.time]);
  await query(store,[f.token,attempt.id,f.uid]);
  await query("delete from open_queue_events where game_id=$1 and event_type='MATCH_ENDED'",[f.id]);
  await rejects(reserve,[f.token,attempt.id,f.time,7000,url(f.uid)],/timestamps are required/);
  await query("update broadcast_device_credentials set revoked_at=now() where device_key=$1",[f.key]);
  await rejects(attach,[f.token,attempt.id,f.time,7000,url(f.uid)],/expired or was disconnected/);
  for(const role of ["anon","authenticated"]) {
    check(await value("select not has_table_privilege($1,'public.broadcast_recording_recoveries','SELECT') as value",[role]),`${role} cannot read upload capabilities`);
    for(const fn of ["broadcast_recovery_context(text)","begin_broadcast_recovery(text,timestamptz,text,bigint)","store_broadcast_recovery_upload(text,uuid,text,text)","reserve_broadcast_recovery_attachment(text,uuid,timestamptz,double precision,text)","attach_broadcast_recovery(text,uuid,timestamptz,double precision,text)","sync_broadcast_replay(text,uuid,text,text,timestamptz,timestamptz,timestamptz,text)","guard_broadcast_recovery_publication()"]) {
      check(await value("select not has_function_privilege($1,$2,'EXECUTE') as value",[role,`public.${fn}`]),`${role} cannot call ${fn}`);
    }
  }
  console.log(`${checks} recording recovery PostgreSQL checks passed.`);
} finally { await db.close(); }
