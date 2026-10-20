// Real PostgreSQL functions in disposable PGlite; no hosted accounts or clips.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
let checks = 0;
const query = (sql, args = []) => db.query(sql, args);
const scalar = async (sql, args = []) => (await query(sql, args)).rows[0]?.value;
const check = (condition, label) => { assert.ok(condition, label); checks++; };
const rejects = async (sql, args, pattern) => { await assert.rejects(query(sql, args), pattern); checks++; };
const viewer = randomUUID(), owner = randomUUID(), popular = randomUUID();
const deleted = randomUUID(), incomplete = randomUUID();
const clips = {};

try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as
      $$select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid$$;
    grant usage on schema auth to authenticated;
    create table public.profiles (
      id uuid primary key, username text, display_name text, avatar_url text,
      account_deleted_at timestamptz, active boolean default true
    );
    create function public.is_fieldrush_account_active(profile_id uuid)
    returns boolean language sql stable as
      $$select coalesce((select active from public.profiles where id = profile_id), false)$$;
    create table public.profile_highlights (
      id uuid primary key default gen_random_uuid(),
      profile_id uuid not null references public.profiles(id) on delete cascade,
      title text, thumbnail_url text, video_url text, duration text default '0:30',
      views integer default 0, clan_tag text, download_url text, source_type text,
      source_match_id uuid, source_event_id uuid, provider_video_id text,
      is_public boolean default true, processing_status text default 'READY',
      created_at timestamptz default now()
    );
  `);
  await db.exec(await readFile(new URL('../migrations/20261019000100_unseen_profile_clip_recommendations.sql', import.meta.url), 'utf8'));
  const orphan = randomUUID(), orphanClip = randomUUID();
  await query("insert into profiles(id,username,display_name) values($1,'retained','Retained profile')", [orphan]);
  await query("insert into profile_highlights(id,profile_id,title) values($1,$2,'Retained clip')", [orphanClip, orphan]);
  await query('insert into profile_highlight_view_history(viewer_profile_id,highlight_id) values($1,$2)', [orphan, orphanClip]);
  await db.exec(await readFile(new URL('../migrations/20261019000200_delete_clip_history_with_account.sql', import.meta.url), 'utf8'));
  check(await scalar('select count(*)::int as value from profile_highlight_view_history where viewer_profile_id=$1', [orphan]) === 0, 'retention migration clears viewing history whose Auth account was already deleted');
  check(await scalar('select count(*)::int as value from profiles where id=$1', [orphan]) === 1, 'retention migration preserves the anonymized match profile');
  await query('delete from profiles where id=$1', [orphan]);
  for (const [id, username] of [[viewer, 'viewer'], [owner, 'creator'], [popular, 'popular'], [deleted, 'deleted'], [incomplete, 'incomplete']]) {
    await query('insert into auth.users(id) values($1)', [id]);
    await query('insert into profiles(id,username,display_name,avatar_url) values($1,$2,$2,$3)', [id, username, `https://example.com/${username}.jpg`]);
  }
  await query('update profiles set account_deleted_at=now() where id=$1', [deleted]);
  await query('update profiles set active=false where id=$1', [incomplete]);
  async function clip(name, profileId, views, { isPublic = true, status = 'READY', video = 'https://example.com/clip.m3u8', createdAt = '2026-10-19T10:00:00Z' } = {}) {
    const id = randomUUID(); clips[name] = id;
    await query(`insert into profile_highlights(id,profile_id,title,thumbnail_url,video_url,views,is_public,processing_status,created_at)
      values($1,$2,$3,'https://example.com/thumbnail.jpg',$4,$5,$6,$7,$8)`, [id, profileId, name, video, views, isPublic, status, createdAt]);
  }
  await clip('source', owner, 7);
  await clip('creatorUnseen', owner, 2);
  await clip('creatorNewer', owner, 2, { createdAt: '2026-10-19T11:00:00Z' });
  await clip('creatorSeen', owner, 500);
  await clip('creatorPrivate', owner, 5000, { isPublic: false });
  await clip('popular', popular, 100);
  await clip('other', popular, 20);
  await clip('popularSeen', popular, 1000);
  await clip('foreignPrivate', popular, 9000, { isPublic: false });
  await clip('pending', owner, 9999, { status: 'PROCESSING' });
  await clip('failed', owner, 9999, { status: 'FAILED' });
  await clip('emptyVideo', owner, 9999, { video: '   ' });
  await clip('deletedOwner', deleted, 9999);
  await clip('incompleteOwner', incomplete, 9999);
  const signIn = id => query("select set_config('request.jwt.claim.sub',$1,false)", [id ?? '']);
  const recommend = async (id = clips.source, limit = 8) => scalar('select get_profile_clip_recommendations($1,$2) as value', [id, limit]);
  const view = id => scalar('select record_profile_highlight_view($1) as value', [id]);

  await signIn(viewer);
  check(await view(clips.creatorSeen) === 501, 'recording preserves the existing global playback counter');
  await view(clips.popularSeen);
  let result = await recommend();
  check(result.map(row => row.highlight.title).join(',') === 'creatorNewer,creatorUnseen,popular,other', 'same creator first, then popularity; hides current, watched, private, processing, missing-video and hidden-owner clips');
  check(result[0].profile_id === owner && result[0].username === 'creator' && result[0].display_name === 'creator' && result[0].avatar_url.endsWith('/creator.jpg'), 'recommendation carries creator identity');
  check(result[0].highlight.profile_id === owner && Date.parse(result[0].highlight.created_at) === Date.parse('2026-10-19T11:00:00Z'), 'clip carries owner and actual creation time');
  check(await scalar('select count(*)::int as value from profile_highlight_view_history where viewer_profile_id=$1', [viewer]) === 2, 'loading recommendations does not mark previews as watched');
  check((await recommend(clips.source, 1)).length === 1, 'limit is enforced');
  for (const limit of [0, 21, null]) await rejects('select get_profile_clip_recommendations($1,$2)', [clips.source, limit], /between 1 and 20/);
  await rejects('select get_profile_clip_recommendations($1,8)', [clips.creatorPrivate], /not available/);
  await rejects('select get_profile_clip_recommendations($1,8)', [randomUUID()], /not available/);
  await rejects('select get_profile_clip_recommendations($1,8)', [clips.deletedOwner], /not available/);
  await rejects('select get_profile_clip_recommendations($1,8)', [clips.incompleteOwner], /not available/);
  await rejects('select record_profile_highlight_view($1)', [clips.creatorPrivate], /not available/);
  await rejects('select record_profile_highlight_view($1)', [clips.pending], /not available/);
  check(await scalar('select views as value from profile_highlights where id=$1', [clips.creatorPrivate]) === 5000, 'unauthorized playback changes neither count nor history');

  await query("update profile_highlight_view_history set first_viewed_at='2026-10-01',last_viewed_at='2026-10-01' where viewer_profile_id=$1 and highlight_id=$2", [viewer, clips.creatorSeen]);
  check(await view(clips.creatorSeen) === 502, 'repeat playback still increments existing view counts');
  const history = (await query('select * from profile_highlight_view_history where viewer_profile_id=$1 and highlight_id=$2', [viewer, clips.creatorSeen])).rows[0];
  check(history.playback_starts === 2 && new Date(history.first_viewed_at).toISOString().startsWith('2026-10-01') && new Date(history.last_viewed_at) > new Date(history.first_viewed_at), 'one durable viewer entry preserves first view and advances last view');
  await view(clips.creatorNewer);
  check((await recommend())[0].highlight.id === clips.creatorUnseen, 'watched recommendation disappears on the next request');

  await signIn(owner);
  result = await recommend();
  check(result[0].highlight.id === clips.creatorPrivate, 'creator can receive their own private clips');
  check(result.some(row => row.highlight.id === clips.creatorSeen), 'another viewer history does not suppress recommendations');
  check(await view(clips.creatorPrivate) === 5001, 'owner can watch and record their private clip');
  check(!(await recommend()).some(row => row.highlight.id === clips.creatorPrivate), 'private clip history also suppresses it after playback');

  await signIn(viewer);
  await db.exec('set role authenticated');
  check(await scalar('select count(*)::int as value from profile_highlight_view_history') === 3, 'RLS reveals only the caller playback history');
  await rejects('insert into profile_highlight_view_history(viewer_profile_id,highlight_id) values($1,$2)', [viewer, clips.other], /permission denied/);
  await rejects('delete from profile_highlight_view_history', [], /permission denied/);
  await rejects('update profile_highlight_view_history set playback_starts=99', [], /permission denied/);
  check((await recommend()).length === 3, 'authenticated RPC is callable with protected tables');
  await db.exec('reset role');

  await signIn(null);
  await rejects('select get_profile_clip_recommendations($1,8)', [clips.source], /sign in again/);
  await rejects('select record_profile_highlight_view($1)', [clips.source], /sign in again/);
  for (const fn of ['get_profile_clip_recommendations(uuid,integer)', 'record_profile_highlight_view(uuid)']) {
    check(!(await scalar('select has_function_privilege($1,$2,\'EXECUTE\') as value', ['anon', `public.${fn}`])), `anonymous cannot execute ${fn}`);
  }
  await query('delete from profile_highlights where id=$1', [clips.creatorSeen]);
  check(await scalar('select count(*)::int as value from profile_highlight_view_history where highlight_id=$1', [clips.creatorSeen]) === 0, 'deleted clips remove watch history by cascade');
  await query('delete from auth.users where id=$1', [viewer]);
  check(await scalar('select count(*)::int as value from profile_highlight_view_history where viewer_profile_id=$1', [viewer]) === 0, 'deleting Auth removes private viewing history even when the player profile is retained');
  check(await scalar('select count(*)::int as value from profiles where id=$1', [viewer]) === 1, 'account history cleanup does not delete the retained match profile');
  console.log(`${checks} profile clip recommendation PostgreSQL checks passed.`);
} finally {
  await db.close();
}
