// Real two-connection locking regression. Only a disposable local Supabase
// Docker database is accepted; admin changes and match starts are rolled back.
import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const container = process.argv[2] ?? 'supabase_db_field_v2';
if (!/^supabase_db_[a-zA-Z0-9_-]+$/.test(container)) {
  throw new Error('Pass a local Supabase Docker database container name.');
}
const args = ['exec', '-i', container, 'psql', '-X', '-q', '-A', '-t',
  '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'];
const game = randomUUID();
const actor = randomUUID();
const phone = '1555' + (BigInt('0x' + actor.slice(0, 8)) % 10000000n).toString().padStart(7, '0');
function run(sql, allowFailure = false) {
  const result = spawnSync('docker', args, { input: sql, encoding: 'utf8', timeout: 10000 });
  if (!allowFailure && result.status !== 0) throw new Error(result.stderr || 'Local SQL verification failed.');
  return result;
}
function session() {
  const child = spawn('docker', args, { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = ''; let error = ''; let closed = false;
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { error += chunk; });
  child.on('error', cause => { error += cause.message; closed = true; });
  child.stdin.on('error', cause => { error += cause.message; closed = true; });
  child.on('close', () => { closed = true; });
  return {
    send(sql) { child.stdin.write(sql + '\n'); },
    async marker(marker) {
      const deadline = Date.now() + 6000;
      while (!output.includes(marker)) {
        if (closed || Date.now() > deadline) throw new Error(error || 'SQL session did not reach ' + marker + '.');
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    },
    close() { if (!child.stdin.destroyed) child.stdin.end('rollback;\n'); },
  };
}
const rename = [
  "do $$ declare actor uuid := '" + actor + "'; season public.fieldrush_seasons%rowtype; begin",
  "select * into season from public.fieldrush_seasons order by (lifecycle='ACTIVE') desc,starts_on limit 1;",
  "if season.id is null then raise exception 'Apply season migrations before the concurrency check.'; end if;",
  "perform public.admin_update_fieldrush_season(actor,season.id,'RENAME',",
  "'{\"label\":\"Concurrency verification\"}',null,season.revision); end $$;",
].join('\n');
const booking = session(); const calendar = session();
try {
  run("insert into auth.users(id,phone,phone_confirmed_at) values('" + actor + "','" + phone + "',now()); " +
    "insert into public.profiles(id,auth_user_id,display_name,username) values('" + actor + "','" + actor +
    "','Isolated season concurrency admin','concur_" + actor.replaceAll('-', '').slice(0, 12) +
    "') on conflict(id) do update set display_name=excluded.display_name,username=excluded.username; " +
    "insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values('" + actor +
    "','Isolated season concurrency admin','+" + phone + "','admin',true);");
  run("insert into public.open_queue_games(id,status,venue,starts_at,ends_at,price_fils,market_city_id) " +
    "select '" + game + "','OPEN','Isolated season concurrency regression',kickoff,kickoff+interval '1 hour',0,'phoenix' " +
    "from (select ((now() at time zone 'America/Phoenix')::date+1+time '19:00') at time zone 'America/Phoenix' kickoff) x;");
  run("insert into public.open_queue_clock_states(game_id,status) values('" + game + "','NOT_STARTED') on conflict(game_id) do nothing;");
  booking.send("begin; set local lock_timeout='2s'; select id from public.open_queue_games where id='" + game + "' for update;\n\\echo BOOKING_ROW_LOCKED");
  await booking.marker('BOOKING_ROW_LOCKED');
  calendar.send("begin; set local lock_timeout='2s'; " + rename + "\n\\echo CALENDAR_RENAMED");
  await calendar.marker('CALENDAR_RENAMED');
  // Old global statement/row locking deadlocked here: the calendar held the
  // lifecycle lock while checkout held this existing game row.
  booking.send("update public.open_queue_games set venue='Isolated checkout update' where id='" + game + "';\n\\echo BOOKING_UPDATED\nrollback;");
  await booking.marker('BOOKING_UPDATED');
  calendar.send('rollback;\n\\echo CALENDAR_ROLLED_BACK');
  await calendar.marker('CALENDAR_ROLLED_BACK');

  calendar.send('begin; ' + rename + '\n\\echo CALENDAR_LOCKED_FOR_START');
  await calendar.marker('CALENDAR_LOCKED_FOR_START');
  const blocked = run("\\set VERBOSITY verbose\nbegin; set local lock_timeout='250ms'; " +
    "update public.open_queue_clock_states set status='RUNNING',started_at=now() where game_id='" + game + "'; rollback;", true);
  if (blocked.status === 0 || !blocked.stderr.includes('55P03')) {
    throw new Error('A genuine game start did not serialize with the season calendar.');
  }
  calendar.send('rollback;\n\\echo CALENDAR_RELEASED_FOR_START');
  await calendar.marker('CALENDAR_RELEASED_FOR_START');
  run("begin; set local lock_timeout='2s'; " +
    "update public.open_queue_clock_states set status='RUNNING',started_at=now() where game_id='" + game + "'; " +
    "do $$ begin if not exists(select 1 from public.open_queue_games where id='" + game + "' and season_locked_at is not null) " +
    "then raise exception 'Match start did not freeze the season.'; end if; end $$; rollback;");
  console.log('Season concurrency: checkout row update and calendar rename do not deadlock; genuine starts serialize and retry successfully.');
} finally {
  booking.close(); calendar.close();
  run("delete from public.open_queue_games where id='" + game + "' and venue='Isolated season concurrency regression'; " +
    "delete from public.referee_profiles where profile_id='" + actor + "' and display_name='Isolated season concurrency admin'; " +
    "delete from public.profiles where id='" + actor + "' and username='concur_" + actor.replaceAll('-', '').slice(0, 12) + "'; " +
    "delete from auth.users where id='" + actor + "' and phone='" + phone + "';");
}
