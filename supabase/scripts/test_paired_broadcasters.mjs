// Real PostgreSQL execution of the pairing migration, in a disposable local
// PGlite instance. Base tables are minimal fixtures; no remote data is touched.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || "@electric-sql/pglite");
const db = new PGlite();
let checks = 0;
const check = (value, message) => { assert.ok(value, message); checks++; };
const hash = (value) => createHash("sha256").update(value).digest("hex");
const query = (sql, args = []) => db.query(sql, args);
const result = async (sql, args = []) => (await query(sql, args)).rows[0]?.value;
async function rejects(sql, args, pattern) {
  await assert.rejects(query(sql, args), pattern); checks++;
}
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create table public.profiles(id uuid primary key);
    create table public.referee_profiles(profile_id uuid primary key references profiles,display_name text,phone text,role text,is_active boolean);
    create table public.clans(id uuid primary key,name text);
    create table public.fixtures(id uuid primary key,status text,venue text,home_clan_id uuid,away_clan_id uuid);
    create table public.open_queue_games(id uuid primary key,status text,venue text,starts_at timestamptz);
    create table public.fixture_referee_assignments(fixture_id uuid,referee_id uuid);
    create table public.open_queue_referee_assignments(game_id uuid,referee_id uuid);
    create table public.broadcast_devices(device_key text primary key,display_name text,status text default 'OFFLINE',obs_connected boolean default false,obs_streaming boolean default false,current_fixture_id uuid,current_open_queue_game_id uuid,last_seen_at timestamptz,error_message text,metadata jsonb);
    create table public.fixture_broadcasts(fixture_id uuid primary key,status text,stream_requested_at timestamptz,stream_started_at timestamptz,stream_stopped_at timestamptz,recording_ready_at timestamptz,replay_hls_url text,active_video_id text,error_message text,live_input_id text);
    create table public.open_queue_broadcasts(game_id uuid primary key,status text,stream_requested_at timestamptz,stream_started_at timestamptz,stream_stopped_at timestamptz,recording_ready_at timestamptz,replay_hls_url text,active_video_id text,error_message text,live_input_id text);
    create table public.broadcast_commands(id uuid primary key default gen_random_uuid(),fixture_id uuid,open_queue_game_id uuid,device_key text,action text,requested_by uuid,status text default 'PENDING',completed_at timestamptz,error_message text);
    create unique index broadcast_commands_active_fixture on broadcast_commands(fixture_id,action) where status in ('PENDING','CLAIMED');
    create unique index broadcast_commands_active_solo on broadcast_commands(open_queue_game_id,action) where status in ('PENDING','CLAIMED');
  `);
  await db.exec(await readFile(new URL("../migrations/20261018000100_paired_broadcast_devices.sql", import.meta.url), "utf8"));
  const admin = randomUUID(), ref = randomUUID(), other = randomUUID(), game = randomUUID(), next = randomUUID(), clan = randomUUID();
  for (const [id, role] of [[admin,"admin"],[ref,"referee"],[other,"referee"]]) {
    await query("insert into profiles values($1)", [id]);
    await query("insert into referee_profiles values($1,$2,'phone',$3,true)", [id,role,role]);
  }
  for (const id of [game,next]) {
    await query("insert into open_queue_games values($1,'FULL','Phoenix Pitch 1',now())", [id]);
    await query("insert into open_queue_broadcasts(game_id,status) values($1,'READY')", [id]);
    await query("insert into open_queue_referee_assignments values($1,$2)", [id,ref]);
  }
  await query("insert into fixtures values($1,'SCHEDULED','Phoenix Pitch 1',null,null)", [clan]);
  await query("insert into fixture_broadcasts(fixture_id,status) values($1,'READY')", [clan]);
  const code = hash("code one"), token = hash("device one");
  const mint = "select create_broadcast_pairing($1,$2,$3,$4) as value";
  const redeem = "select redeem_broadcast_pairing($1,$2,$3) as value";
  const session = "select broadcast_device_session($1) as value";
  const start = "select reserve_broadcast_start($1,$2,$3) as value";
  const revoke = "select revoke_broadcast_device($1,$2)";
  await rejects(mint, [other,"SOLO",game,code], /not assigned/);
  check(await result(mint,[ref,"SOLO",game,code]), "assigned referee can create code");
  check((await query("select code_hash from broadcast_pairing_codes")).rows[0].code_hash === code, "only code digest is saved");
  await rejects(redeem,[hash("wrong"),token,"MacBook"],/invalid or expired/);
  const paired = await result(redeem,[code,token,"Referee MacBook"]);
  check(paired.matchId === game && paired.matchKind === "SOLO" && paired.ownerId === ref, "pairing binds exact owner and target");
  const retry = await result(redeem,[code,token,"Different retry name"]);
  check(retry.deviceKey === paired.deviceKey && retry.displayName === "Referee MacBook", "lost-response same-token redemption is idempotent");
  await rejects(redeem,[code,hash("stolen"),"Other laptop"],/already been used/);
  await rejects(mint,[ref,"SOLO",game,hash("new code")],/Disconnect/);
  check((await result(session,[token])).matchLabel === "White Team vs Black Team", "session carries match confirmation");
  await rejects(session,[hash("invalid token")],/expired or was disconnected/);
  await query("update referee_profiles set is_active=false where profile_id=$1", [ref]);
  await rejects(session,[token],/not an active referee/);
  await query("update referee_profiles set is_active=true where profile_id=$1", [ref]);
  await query("delete from open_queue_referee_assignments where game_id=$1 and referee_id=$2", [game,ref]);
  await rejects(session,[token],/not assigned/);
  await query("insert into open_queue_referee_assignments values($1,$2)", [game,ref]);
  await rejects(start,[ref,"SOLO",game],/offline/);
  await query("update broadcast_devices set obs_connected=true,last_seen_at=now(),status='READY' where device_key=$1",[paired.deviceKey]);
  await query("update broadcast_device_credentials set test_input_id='preparing:fixture' where device_key=$1",[paired.deviceKey]);
  await rejects(start,[ref,"SOLO",game],/Finish the connection test/);
  await query("update broadcast_device_credentials set test_input_id=null where device_key=$1",[paired.deviceKey]);
  check(await result(start,[ref,"SOLO",game]) === paired.deviceKey, "start atomically reserves correct laptop");
  check(await result(start,[ref,"SOLO",game]) === paired.deviceKey, "repeated start is idempotent");
  check((await query("select * from broadcast_commands")).rows.length === 1,"repeated start does not create another command");
  check((await query("select * from open_queue_broadcasts where game_id=$1",[game])).rows[0].device_key === paired.deviceKey,"broadcast retains original device for stop");
  await rejects(revoke,[ref,paired.deviceKey],/Stop the broadcast/);
  await rejects(revoke,[other,paired.deviceKey],/not paired to your account/);
  const nextCode = hash("next code"), nextToken = hash("next token");
  await result(mint,[admin,"CLAN",clan,nextCode]);
  const nextPair = await result(redeem,[nextCode,nextToken,"Next laptop"]);
  await query("update broadcast_devices set obs_connected=true,last_seen_at=now() where device_key=$1",[nextPair.deviceKey]);
  await rejects(start,[admin,"CLAN",clan],/pitch already has/);
  check((await query("select * from broadcast_commands")).rows.length === 1,"failed competing start writes no command");
  await query("update broadcast_commands set status='ACKNOWLEDGED'");
  await query("update broadcast_device_credentials set reservation_active=false where device_key=$1",[paired.deviceKey]);
  await query("update open_queue_broadcasts set status='PROCESSING' where game_id=$1",[game]);
  await rejects(start,[ref,"SOLO",game],/finishing/);
  check(await result(start,[admin,"CLAN",clan]) === nextPair.deviceKey,"other match can start after confirmed release");
  await query(revoke,[ref,paired.deviceKey]);
  await rejects(session,[token],/expired or was disconnected/);
  await rejects(redeem,[code,token,"MacBook"],/already been used/);
  await result(mint,[ref,"SOLO",next,hash("expiry code")]);
  await query("update broadcast_pairing_codes set expires_at=now()-interval '1 second' where code_hash=$1",[hash("expiry code")]);
  await rejects(redeem,[hash("expiry code"),hash("expiry token"),"Old laptop"],/invalid or expired/);
  await query("update open_queue_games set status='FINAL' where id=$1",[next]);
  await rejects(mint,[ref,"SOLO",next,hash("finished")],/already finished/);
  await rejects("select begin_broadcast_device_revocation($1,$2)",[ref,nextPair.deviceKey],/Admin access/);
  const revokeResult = await result("select begin_broadcast_device_revocation($1,$2) as value",[admin,nextPair.deviceKey]);
  check(revokeResult.matchId === clan,"admin forced recovery targets exact match");
  await rejects(session,[nextToken],/expired or was disconnected/);
  check(await result("select reservation_active as value from broadcast_device_credentials where device_key=$1",[nextPair.deviceKey]),"forced revoke holds pitch pending provider disable");
  check((await query("select * from broadcast_commands where device_key=$1 and status in ('PENDING','CLAIMED')",[nextPair.deviceKey])).rows.length === 0,"forced revoke cancels outstanding commands");
  // A revoked/expired test still owns its provider cleanup, even without a live
  // match reservation. Neither minting nor an older unused code bypasses it.
  await query("update broadcast_device_credentials set reservation_active=false where device_key=$1",[nextPair.deviceKey]);
  await query("update fixture_broadcasts set status='READY' where fixture_id=$1",[clan]);
  await query("update open_queue_games set status='FULL' where id=$1",[next]);
  const heldCode=hash("before unresolved test");
  await result(mint,[ref,"SOLO",next,heldCode]);
  await query("update broadcast_device_credentials set test_input_id='preparing:inflight',expires_at=now()-interval '1 second' where device_key=$1",[nextPair.deviceKey]);
  await rejects(mint,[admin,"CLAN",clan,hash("blocked same match")],/connection test cleanup/);
  await rejects(mint,[ref,"SOLO",next,hash("blocked same pitch")],/connection test cleanup/);
  await rejects(redeem,[heldCode,hash("blocked redeem"),"Different laptop"],/connection test cleanup/);
  check(await result("select test_input_id is not null as value from broadcast_device_credentials where device_key=$1",[nextPair.deviceKey]),"expired revoked test is never automatically cleared");
  await query("update broadcast_device_credentials set test_input_id=null where device_key=$1",[nextPair.deviceKey]);
  const heldPair=await result(redeem,[heldCode,hash("blocked redeem"),"Different laptop"]);
  await query("update broadcast_devices set obs_connected=true,last_seen_at=now() where device_key=$1",[heldPair.deviceKey]);
  await query("update broadcast_device_credentials set test_input_id='private-inflight' where device_key=$1",[nextPair.deviceKey]);
  await rejects(start,[ref,"SOLO",next],/connection test cleanup/);
  await query("update broadcast_device_credentials set test_input_id=null where device_key=$1",[nextPair.deviceKey]);
  check(await result(start,[ref,"SOLO",next])===heldPair.deviceKey,"confirmed test cleanup permits another match on the pitch");
  for (const role of ["anon","authenticated"]) {
    for (const fn of ["broadcast_match_context(uuid,text,uuid,boolean)","create_broadcast_pairing(uuid,text,uuid,text)","redeem_broadcast_pairing(text,text,text)","broadcast_device_session(text)","reserve_broadcast_start(uuid,text,uuid)","revoke_broadcast_device(uuid,text)","begin_broadcast_device_revocation(uuid,text)"]) {
      check(await result("select not has_function_privilege($1,$2,'EXECUTE') as value",[role,`public.${fn}`]),`${role} cannot call ${fn}`);
    }
    for (const table of ["broadcast_device_credentials","broadcast_pairing_codes"]) {
      check(await result("select not has_table_privilege($1,$2,'SELECT') as value",[role,`public.${table}`]),`${role} cannot read credential hashes`);
    }
  }
  console.log(`${checks} paired broadcaster PostgreSQL checks passed.`);
} finally { await db.close(); }
