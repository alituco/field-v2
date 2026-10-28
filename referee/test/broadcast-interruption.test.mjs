import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const compiled = ts.transpileModule(readFileSync(new URL("../src/lib/broadcasts.ts",import.meta.url),"utf8"),{
  compilerOptions:{ module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022 },
}).outputText;

function harness(kind, initial={}) {
  const table = kind === "SOLO" ? "open_queue_broadcasts" : "fixture_broadcasts";
  const key = kind === "SOLO" ? "game_id" : "fixture_id";
  const row = { [key]:"match",status:"LIVE",live_input_id:"input",active_video_id:"segment-1",
    stream_requested_at:"2026-10-22T09:00:00Z",stream_started_at:"2026-10-22T09:00:00Z",
    stream_stopped_at:null,recovery_upload_id:null,device_key:"paired-mac",...initial };
  const rows = {[table]:[row],broadcast_commands:[]}, calls=[];
  const provider = { live:false,videoUID:"segment-2" };
  const db = {from(name) {
    let op="read", patch; const filters=[];
    const q={
      select(){return q;},eq(k,v){filters.push(r=>r[k]===v);return q;},
      is(k,v){filters.push(r=>(r[k]??null)===v);return q;},
      neq(k,v){filters.push(r=>r[k]!==v);return q;},
      in(k,v){filters.push(r=>v.includes(r[k]));return q;},
      update(p){op="update";patch=p;return q;},insert(p){op="insert";patch=p;return q;},
      async then(resolve,reject){
        try {
          let data=rows[name]??=[];
          if(op==="insert") {data.push({id:`command-${data.length}`,status:"PENDING",...patch});rows[name]=data;data=[data.at(-1)];}
          else {data=data.filter(r=>filters.every(f=>f(r)));if(op==="update")data.forEach(r=>Object.assign(r,patch));}
          return resolve({data:data.map(r=>({...r})),error:null});
        } catch(e){return reject(e);}
      },
      async maybeSingle(){const result=await q;return {...result,data:result.data[0]??null};},
      single(){return q.maybeSingle();},
    };return q;
  }, async rpc(name,args){
    calls.push([name,args]);
    if(name === "sync_broadcast_replay" && row.stream_stopped_at) {
      Object.assign(row,{status:"REPLAY_READY",replay_hls_url:args.replay_url,error_message:null});
    }
    return {data:Boolean(row.stream_stopped_at),error:null};
  }};
  const modules={
    "./cloudflare-stream":{
      getCloudflareLifecycle:async()=>{
        if(provider.lifecycleError) throw new Error("Provider temporarily unavailable");
        return {...provider};
      },
      getCloudflareVideo:async id=>{calls.push(["video",id]);return {uid:id,created:"2026-10-22T09:30:00Z",readyToStream:true,playback:{hls:`https://video.invalid/${id}`}};},
      listCloudflareLiveInputVideos:async()=>provider.recordings??[],cloudflareHlsUrl:id=>`https://video.invalid/${id}`,
      setCloudflareLiveInputEnabled:async(...args)=>calls.push(["input-enabled",...args]),
    },"./broadcast-agent-auth":{},"./broadcast-pairing":{},
  };
  const exports={};vm.runInNewContext(compiled,{exports,Date,require:name=>{assert.ok(name in modules,name);return modules[name];}});
  return {row,rows,calls,provider,
    sync:()=>exports[kind==="SOLO"?"syncOpenQueueBroadcastFromCloudflare":"syncBroadcastFromCloudflare"](db,"match"),
    stop:()=>exports[kind==="SOLO"?"queueOpenQueueBroadcastStop":"queueBroadcastStop"](db,"match","referee"),
    acknowledgeStop:()=>exports[kind==="SOLO"?"markOpenQueueBroadcastStopped":"markBroadcastStopped"](db,"match"),
  };
}

for(const kind of ["SOLO","CLAN"]) {
  test(`${kind}: disconnect stays stoppable and reconnect selects the current live segment`,async()=>{
    const h=harness(kind);await h.sync();
    assert.equal(h.row.status,"STARTING");assert.equal(h.row.stream_stopped_at,null);
    assert.equal(h.calls.some(c=>c[0]==="sync_broadcast_replay"),false);
    h.provider.live=true;await h.sync();
    assert.equal(h.row.status,"LIVE");assert.equal(h.row.active_video_id,"segment-2");
    assert.equal(h.row.stream_started_at,"2026-10-22T09:30:00.000Z");
    await h.stop();await h.stop();
    assert.equal(h.row.status,"STOPPING");assert.equal(h.rows.broadcast_commands.length,1);
    assert.equal(h.rows.broadcast_commands[0].action,"STOP_STREAM");
    await h.sync();assert.equal(h.row.status,"STOPPING","late LIVE poll must not cancel stopping");
    await h.acknowledgeStop();assert.equal(h.row.status,"REPLAY_READY");
    assert.ok(h.row.stream_stopped_at);assert.deepEqual(h.calls.find(c=>c[0]==="input-enabled"),["input-enabled","input",false]);
    h.provider.live=false;await h.sync();assert.equal(h.calls.at(-1)[0],"sync_broadcast_replay");
  });
  test(`${kind}: a legacy premature replay cannot suppress stop or provider shutdown`,async()=>{
    const h=harness(kind,{status:"REPLAY_READY",replay_hls_url:"partial",recording_ready_at:"2026-10-22T09:15:00Z"});
    await h.stop();assert.equal(h.rows.broadcast_commands.length,1);assert.equal(h.row.status,"STOPPING");
    await h.acknowledgeStop();assert.equal(h.row.status,"REPLAY_READY");assert.ok(h.row.stream_stopped_at);
    assert.equal(h.calls.filter(c=>c[0]==="input-enabled").length,1);
  });
  test(`${kind}: a legacy premature replay can reconnect without becoming terminal`,async()=>{
    const h=harness(kind,{status:"REPLAY_READY",replay_hls_url:"partial",recording_ready_at:"2026-10-22T09:15:00Z"});
    h.provider.live=true;await h.sync();assert.equal(h.row.status,"LIVE");
    assert.equal(h.row.replay_hls_url,null);assert.equal(h.row.recording_ready_at,null);
  });
  test(`${kind}: ready before stop acknowledgement publishes without another phone poll`,async()=>{
    const h=harness(kind,{status:"STOPPING"});
    // A ready callback/poll before acknowledgement is ignored; the stop receipt
    // must reconcile even while the provider's lifecycle still reports LIVE.
    await h.sync();assert.equal(h.calls.some(c=>c[0]==="sync_broadcast_replay"),false);
    h.provider.live=true;await h.acknowledgeStop();
    assert.equal(h.row.status,"REPLAY_READY");assert.equal(h.row.replay_hls_url,"https://video.invalid/segment-1");
    assert.equal(h.calls.filter(c=>c[0]==="sync_broadcast_replay").length,1);
  });
  test(`${kind}: retrying stop acknowledgement recovers reconciliation failure after saved stop`,async()=>{
    const h=harness(kind,{status:"STOPPING"});h.provider.lifecycleError=true;
    await assert.rejects(h.acknowledgeStop(),/Provider temporarily unavailable/);
    assert.ok(h.row.stream_stopped_at);assert.equal(h.row.status,"PROCESSING");
    h.provider.lifecycleError=false;await h.acknowledgeStop();
    assert.equal(h.row.status,"REPLAY_READY");assert.equal(h.row.error_message,null);
    assert.equal(h.calls.filter(c=>c[0]==="input-enabled").length,1);
  });
  test(`${kind}: stop discovers a reconnected segment even without an intervening live poll`,async()=>{
    const h=harness(kind,{status:"STOPPING"});
    h.provider.recordings=[{uid:"segment-1",created:"2026-10-22T09:00:00Z"},
      {uid:"previous-session",created:"2026-10-21T09:00:00Z"},
      {uid:"segment-2",created:"2026-10-22T09:30:00Z"}];
    await h.acknowledgeStop();
    assert.equal(h.row.active_video_id,"segment-2");assert.equal(h.row.replay_hls_url,"https://video.invalid/segment-2");
    assert.equal(h.row.stream_started_at,"2026-10-22T09:30:00.000Z");
    const rpc=h.calls.find(c=>c[0]==="sync_broadcast_replay");
    assert.equal(rpc[1].video_id,"segment-2");assert.equal(rpc[1].recording_started_at,"2026-10-22T09:30:00.000Z");
  });
  test(`${kind}: acknowledged or recovered final replay is not resurrected by stale LIVE`,async()=>{
    for (const recovery of [null,"recovered-upload"]) {
      const h=harness(kind,{status:"REPLAY_READY",stream_stopped_at:"2026-10-22T10:00:00Z",recovery_upload_id:recovery,replay_hls_url:"final"});
      h.provider.live=true;await h.sync();await h.stop();await h.acknowledgeStop();
      assert.equal(h.row.status,"REPLAY_READY");assert.equal(h.row.replay_hls_url,"final");
      assert.equal(h.rows.broadcast_commands.length,0);assert.equal(h.calls.length,0);
    }
  });
}
