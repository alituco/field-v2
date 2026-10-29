-- Rollback-only application-schema contracts. The CI runner supplies BEGIN and
-- ROLLBACK. No hosted/provider calls, credentials or production fixtures.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
create function pg_temp.block_expect(ok boolean,label text)
returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Player blocking: %',label; end if; end $$;
create function pg_temp.block_reject(statement text,expected_state text)
returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement; exception when others then
    if sqlstate<>expected_state then raise; end if; rejected:=true;
  end;
  perform pg_temp.block_expect(rejected,'expected rejection '||expected_state);
end $$;
create function pg_temp.block_actor(user_id uuid,role_to_use text default 'authenticated')
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub',coalesce(user_id::text,''),true);
  perform set_config('request.jwt.claim.role',role_to_use,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',user_id,'role',role_to_use)::text,true);
end $$;
create function pg_temp.block_advisory_keys()
returns text[] language sql as $$
  select coalesce(array_agg(classid::text||':'||objid::text||':'||objsubid::text
    order by classid,objid,objsubid),'{}'::text[]) from pg_locks
  where pid=pg_backend_pid() and locktype='advisory' and granted;
$$;
create temporary table block_fixtures(key text primary key,id uuid not null);
create temporary table block_snapshots(key text primary key,data jsonb not null);
grant select on block_fixtures,block_snapshots to authenticated,anon,service_role;

do $$
declare ids uuid[]:='{}'; player uuid; i integer; clan uuid; other_clan uuid; game uuid;
  party uuid; other_party uuid; invitation uuid; staff_login uuid:=gen_random_uuid(); staff_key uuid:=gen_random_uuid();
begin
  for i in 1..6 loop
    player:=gen_random_uuid(); ids:=array_append(ids,player);
    insert into auth.users(id,phone,phone_confirmed_at)
      values(player,'1555587290'||i,now());
    perform pg_temp.block_actor(player);
    perform public.complete_fieldrush_onboarding(jsonb_build_object(
      'first_name','Blocking','last_name','Player','username','blocking_contract_'||i,
      'date_of_birth','2000-01-01','email','blocking_'||i||'@example.test','skill_assessment','not_sure'),
      'fieldrush-v1','fieldrush-v1');
    insert into block_fixtures values('p'||i,player);
    update public.profiles set bio='Player '||i||' authored biography',
      avatar_url='https://example.test/avatars/blocking-'||i||'.png' where id=player;
  end loop;
  perform pg_temp.block_actor(ids[2]);
  insert into public.clans(name,tag,motto,created_by,emblem,theme_id,pattern_id)
    values('Blocking target club','BLK29','Target authored motto',ids[2],'🏆','crimson','stripes') returning id into clan;
  -- The clan INSERT trigger already created its owner membership.
  insert into public.clan_members(clan_id,profile_id,role) values(clan,ids[1],'member');
  insert into block_fixtures values('clan',clan);
  perform pg_temp.block_actor(ids[3]);
  insert into public.clans(name,tag,motto,created_by)
    values('Other blocking club','BLO29','Other club motto',ids[3]) returning id into other_clan;
  insert into public.clan_members(clan_id,profile_id,role) values(other_clan,ids[4],'leader');
  insert into block_fixtures values('other_clan',other_clan);
  perform pg_temp.block_actor(ids[1],'service_role');
  insert into public.open_queue_games(format_version,currency,timezone,capacity,
    goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity,
    venue,starts_at,ends_at,price_fils,created_by)
    values('LEGACY_6V6','BHD','Asia/Bahrain',12,2,4,4,2,
      'Disposable player blocking contract pitch',now()+interval '30 days',now()+interval '30 days 1 hour',0,ids[1]) returning id into game;
  insert into public.open_queue_bookings(game_id,profile_id,role,amount_paid_fils,
    base_amount_fils,payment_method,payment_status)
    values(game,ids[2],'GK',0,0,'FREE','PAID');
  insert into public.open_queue_bookings(game_id,profile_id,role,amount_paid_fils,
    base_amount_fils,payment_method,payment_status) values
    (game,ids[1],'DEF',0,0,'FREE','PAID'),
    (game,ids[3],'DEF',0,0,'FREE','PAID'),
    (game,ids[4],'MID',0,0,'FREE','PAID');
  insert into block_fixtures values('game',game);
  perform pg_temp.block_actor(ids[1]);
  party:=public.create_open_queue_party(game);
  invitation:=public.invite_open_queue_party_member(party,ids[2]);
  perform pg_temp.block_actor(ids[2]);
  perform public.respond_open_queue_party_invitation(invitation,true);
  perform pg_temp.block_actor(ids[4]);
  other_party:=public.create_open_queue_party(game);
  perform pg_temp.block_actor(ids[1]);
  invitation:=public.invite_open_queue_party_member(party,ids[4]);
  insert into block_fixtures values('party',party),('other_party',other_party),('pending_invite',invitation);
  perform pg_temp.block_actor(ids[4]);
  perform pg_temp.block_expect(jsonb_array_length(public.get_open_queue_party_context(game)->'received_invites')=1
    and jsonb_array_length(public.list_my_open_queue_party_invite_notifications())=1,
    'ordinary unblocked incoming party invitation and receipt are available before blocking');
  perform pg_temp.block_expect(public.get_open_queue_party_context(game)=
    (fieldrush_rating_private.mask_public_rating_payload(
      public.get_open_queue_party_context_before_sr_privacy(game),null::uuid,'OUTFIELD',null::integer,game)||'{}'::jsonb),
    'empty blocking preferences preserve the exact prior SR-masked party payload');
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(staff_login,'blocking_staff@example.test',now(),'{"fieldrush_account_type":"staff"}');
  insert into public.referee_profiles(profile_id,auth_user_id,email,display_name,phone,role,is_active)
    values(staff_key,staff_login,'blocking_staff@example.test','Blocking test staff',null,'admin',true);
  insert into block_fixtures values('staff_login',staff_login),('staff_key',staff_key);
  perform pg_temp.block_actor(ids[1]);
  insert into block_snapshots values
    ('raw_target',(select to_jsonb(p) from public.profiles p where id=ids[2])),
    ('bookings',(select jsonb_agg(to_jsonb(b) order by b.id) from public.open_queue_bookings b where game_id=game)),
    ('game',(select to_jsonb(g) from public.open_queue_games g where id=game)),
    ('members',(select jsonb_agg(to_jsonb(m) order by m.profile_id) from public.clan_members m where clan_id=clan)),
    ('ratings',(select coalesce(jsonb_agg(to_jsonb(r) order by r.rating_track),'[]'::jsonb)
      from public.fieldrush_player_rating_tracks r where r.profile_id=ids[2])),
    ('parties',(select jsonb_agg(to_jsonb(p) order by p.id) from public.open_queue_parties p where game_id=game)),
    ('party_members',(select jsonb_agg(to_jsonb(m) order by m.id) from public.open_queue_party_members m where game_id=game)),
    ('visible_members',public.list_fieldrush_clan_members(clan)),
    ('visible_clan',(select value from jsonb_array_elements(public.list_fieldrush_clans()) where value->>'id'=clan::text));
  -- A historical/operator-created hybrid can still satisfy the older active
  -- player predicate. Current provisioning RPCs reject this binding; create it
  -- directly only in this rollback fixture to verify the safety boundary.
  perform pg_temp.block_actor(ids[6]);
  perform public.set_fieldrush_player_block(ids[1],true);
  insert into public.referee_profiles(profile_id,auth_user_id,email,display_name,phone,role,is_active)
    values(gen_random_uuid(),ids[6],'blocking_hybrid@example.test','Blocking hybrid fixture',null,'referee',true);
end $$;

-- Exercise actual transaction advisory locks, not source-text assertions. The
-- deliberate subtransaction rollback releases each acquired lock and restores
-- its mutation; PL/pgSQL variables retain the captured keys for comparison.
select pg_temp.block_actor((select id from block_fixtures where key='p1'));
set local role authenticated;
do $$
declare a uuid:=(select id from block_fixtures where key='p1'); b uuid:=(select id from block_fixtures where key='p3');
  baseline text[]:=pg_temp.block_advisory_keys(); block_keys text[]; follow_keys text[]; reverse_keys text[]; invite_keys text[];
begin
  begin
    perform public.set_fieldrush_player_block(b,true);
    select array_agg(k order by k) into block_keys from unnest(pg_temp.block_advisory_keys()) k where not(k=any(baseline));
    raise exception using errcode='PT001';
  exception when sqlstate 'PT001' then null; end;
  begin
    insert into public.profile_follows(follower_id,following_id) values(a,b);
    select array_agg(k order by k) into follow_keys from unnest(pg_temp.block_advisory_keys()) k where not(k=any(baseline));
    raise exception using errcode='PT001';
  exception when sqlstate 'PT001' then null; end;
  perform pg_temp.block_actor(b);
  begin
    insert into public.profile_follows(follower_id,following_id) values(b,a);
    select array_agg(k order by k) into reverse_keys from unnest(pg_temp.block_advisory_keys()) k where not(k=any(baseline));
    raise exception using errcode='PT001';
  exception when sqlstate 'PT001' then null; end;
  perform pg_temp.block_actor(a);
  begin
    perform public.invite_open_queue_party_member((select id from block_fixtures where key='party'),b);
    select array_agg(k order by k) into invite_keys from unnest(pg_temp.block_advisory_keys()) k where not(k=any(baseline));
    raise exception using errcode='PT001';
  exception when sqlstate 'PT001' then null; end;
  perform pg_temp.block_expect(cardinality(block_keys)=1 and block_keys=follow_keys and block_keys=reverse_keys,
    'block and either follow direction acquire the same pair transaction lock');
  perform pg_temp.block_expect(block_keys<@invite_keys,
    'an actual authorized party invite also acquires the canonical player-pair lock');
  perform pg_temp.block_expect(not exists(select 1 from public.profile_blocks)
    and not exists(select 1 from public.profile_follows where follower_id in(a,b) and following_id in(a,b)),
    'lock probes rolled back their preferences and follows');
end $$;
reset role;

-- Create both existing follow directions before the block.
insert into public.profile_follows(follower_id,following_id)
  select a.id,b.id from block_fixtures a,block_fixtures b where a.key='p1' and b.key='p2';
insert into public.profile_follows(follower_id,following_id)
  select b.id,a.id from block_fixtures a,block_fixtures b where a.key='p1' and b.key='p2';
select pg_temp.block_actor((select id from block_fixtures where key='p1'));
set local role authenticated;
do $$
declare target uuid:=(select id from block_fixtures where key='p2'); result jsonb; again jsonb; identity jsonb; before_row jsonb;
begin
  result:=public.set_fieldrush_player_block(target,true);
  select to_jsonb(b) into before_row from public.profile_blocks b where blocked_profile_id=target;
  again:=public.set_fieldrush_player_block(target,true);
  perform pg_temp.block_expect(result=again and result->>'blocked_by_me'='true' and result->>'interaction_blocked'='true',
    'repeated block is idempotent');
  perform pg_temp.block_expect((select to_jsonb(b)=before_row from public.profile_blocks b where blocked_profile_id=target),
    'repeated block preserves the original preference timestamp');
  perform pg_temp.block_expect((select count(*)=1 from public.profile_blocks),'owner reads only its one preference');
  perform pg_temp.block_reject(format('select public.set_fieldrush_player_block(%L,true)',auth.uid()),'22023');
  perform pg_temp.block_reject('select public.set_fieldrush_player_block(null,true)','22023');
  perform pg_temp.block_reject(format('select public.set_fieldrush_player_block(%L,null)',target),'22023');
  perform pg_temp.block_reject(format('insert into public.profile_blocks(blocker_profile_id,blocked_profile_id) values(%L,%L)',target,auth.uid()),'42501');
  perform pg_temp.block_reject('delete from public.profile_blocks','42501');
  perform pg_temp.block_reject('select * from fieldrush_safety_private.clan_identity_authors','42501');
  identity:=public.get_fieldrush_profile_identity(target);
  perform pg_temp.block_expect(identity->>'id'=target::text and identity->>'content_hidden'='true'
    and identity->>'display_name'='Blocked player' and identity->>'bio'='' and identity->>'username'=''
    and identity->'avatar_url'='null'::jsonb,'peer identity is redacted without losing its stable ID');
  perform pg_temp.block_expect(not(identity ? 'email') and not(identity ? 'phone') and not(identity ? 'auth_user_id'),
    'safe identity reader exposes no private contact or Auth binding');
  perform pg_temp.block_expect(not exists(select 1 from jsonb_array_elements(public.list_fieldrush_discover_profiles()) p where p->>'id'=target::text),
    'blocked peer is omitted from discovery');
  perform pg_temp.block_expect(jsonb_array_length(public.list_fieldrush_profile_identities(array[target]))=0,
    'blocked peer is omitted from connection identity batches');
  perform pg_temp.block_expect(public.get_fieldrush_profile_clan(target) is null,'blocked peer does not reveal its authored clan through profile');
  perform pg_temp.block_expect(jsonb_array_length(public.list_fieldrush_blocked_players())=1
    and public.list_fieldrush_blocked_players()->0->>'profile_id'=target::text
    and not(public.list_fieldrush_blocked_players()->0 ? 'avatar_url')
    and not(public.list_fieldrush_blocked_players()->0 ? 'email'),'own manageable list includes only identification, not hidden photos/contact');
  perform pg_temp.block_reject('select public.list_fieldrush_profile_identities(array_fill(gen_random_uuid(),array[101]))','22023');
  perform pg_temp.block_reject('select public.list_fieldrush_clan_identities(array_fill(gen_random_uuid(),array[101]))','22023');
  perform pg_temp.block_reject('select public.list_fieldrush_connection_clans(array_fill(gen_random_uuid(),array[101]))','22023');
end $$;
reset role;

-- Target/third-party accounts cannot read another player's preference, and a
-- target's unblock request cannot remove the block owned by the first player.
select pg_temp.block_actor((select id from block_fixtures where key='p2'));
set local role authenticated;
do $$
declare a uuid:=(select id from block_fixtures where key='p1'); b uuid:=(select id from block_fixtures where key='p2'); result jsonb;
begin
  perform pg_temp.block_expect((select count(*)=0 from public.profile_blocks),'target cannot read the blocker private list');
  result:=public.get_fieldrush_player_safety(a);
  perform pg_temp.block_expect(result->>'blocked_by_me'='false' and result->>'interaction_blocked'='true',
    'target receives an interaction restriction without another user block-list data');
  result:=public.set_fieldrush_player_block(a,false);
  perform pg_temp.block_expect(result->>'blocked_by_me'='false' and result->>'interaction_blocked'='true','unblock controls only the caller own edge');
  perform pg_temp.block_expect(public.get_fieldrush_profile_identity(a)->>'content_hidden'='true','target also sees a redacted peer identity');
  perform pg_temp.block_reject(format('insert into public.profile_follows(follower_id,following_id) values(%L,%L)',b,a),'42501');
end $$;
reset role;
select pg_temp.block_actor((select id from block_fixtures where key='p3'));
set local role authenticated;
select pg_temp.block_expect((select count(*)=0 from public.profile_blocks),'unrelated player cannot read another blocker list');
select pg_temp.block_expect(public.get_fieldrush_profile_identity((select id from block_fixtures where key='p2'))->>'content_hidden'='false',
  'unrelated viewers still see permitted profile content');
reset role;

-- INSERT and key-changing UPDATE are both guarded, even from a trusted server
-- writer. User-owned blocking never modifies official facts or roster counts.
select pg_temp.block_actor((select id from block_fixtures where key='p1'),'service_role');
select pg_temp.block_expect((select count(*)=0 from public.profile_follows f where
  (f.follower_id=(select id from block_fixtures where key='p1') and f.following_id=(select id from block_fixtures where key='p2')) or
  (f.follower_id=(select id from block_fixtures where key='p2') and f.following_id=(select id from block_fixtures where key='p1'))),
  'blocking removed both preexisting follow directions');
select pg_temp.block_reject(format('insert into public.profile_follows(follower_id,following_id) values(%L,%L)',
  (select id from block_fixtures where key='p1'),(select id from block_fixtures where key='p2')),'42501');
insert into public.profile_follows(follower_id,following_id)
  select a.id,c.id from block_fixtures a,block_fixtures c where a.key='p1' and c.key='p3';
select pg_temp.block_reject(format('update public.profile_follows set following_id=%L where follower_id=%L and following_id=%L',
  (select id from block_fixtures where key='p2'),(select id from block_fixtures where key='p1'),
  (select id from block_fixtures where key='p3')),'42501');
select pg_temp.block_expect((select to_jsonb(p)=(select data from block_snapshots where key='raw_target')
  from public.profiles p where id=(select id from block_fixtures where key='p2')),'legacy raw profile contract stays unchanged');
select pg_temp.block_expect((select jsonb_agg(to_jsonb(b) order by b.id)=(select data from block_snapshots where key='bookings')
  from public.open_queue_bookings b where game_id=(select id from block_fixtures where key='game')),'booking/payment facts remain byte-for-byte unchanged');
select pg_temp.block_expect((select to_jsonb(g)=(select data from block_snapshots where key='game')
  from public.open_queue_games g where id=(select id from block_fixtures where key='game')),'physical game facts remain unchanged');
select pg_temp.block_expect((select jsonb_agg(to_jsonb(m) order by m.profile_id)=(select data from block_snapshots where key='members')
  from public.clan_members m where clan_id=(select id from block_fixtures where key='clan')),'all official roster rows remain unchanged');
select pg_temp.block_expect((select coalesce(jsonb_agg(to_jsonb(r) order by r.rating_track),'[]'::jsonb)=(select data from block_snapshots where key='ratings')
  from public.fieldrush_player_rating_tracks r where profile_id=(select id from block_fixtures where key='p2')),'official ratings remain unchanged');
select pg_temp.block_actor((select id from block_fixtures where key='p1'));
set local role authenticated;
do $$
declare clan uuid:=(select id from block_fixtures where key='clan'); members jsonb:=public.list_fieldrush_clan_members(clan);
  safe_clan jsonb; original jsonb:=(select data from block_snapshots where key='visible_clan'); member jsonb; old_member jsonb;
begin
  select value into safe_clan from jsonb_array_elements(public.list_fieldrush_clans()) where value->>'id'=clan::text;
  perform pg_temp.block_expect(safe_clan->>'name'='Hidden clan' and safe_clan->>'motto'='' and safe_clan->>'emblem'='⚽',
    'blocked creator clan identity is hidden');
  perform pg_temp.block_expect(safe_clan->>'id'=original->>'id' and safe_clan->'member_count'=original->'member_count'
    and safe_clan->'skill_rating'=original->'skill_rating' and safe_clan->'wins'=original->'wins'
    and safe_clan->'losses'=original->'losses','clan identity masking preserves ID, roster count and official record');
  perform pg_temp.block_expect(jsonb_array_length(members)=jsonb_array_length((select data from block_snapshots where key='visible_members')),
    'clan member masking never drops an official roster row');
  select value into member from jsonb_array_elements(members) where value->>'profile_id'=(select id::text from block_fixtures where key='p2');
  select value into old_member from jsonb_array_elements((select data from block_snapshots where key='visible_members'))
    where value->>'profile_id'=(select id::text from block_fixtures where key='p2');
  perform pg_temp.block_expect(member#>>'{profiles,display_name}'='Blocked player'
    and member#>'{profiles,avatar_url}'='null'::jsonb and member-'profiles'=old_member-'profiles',
    'member photo/name hidden while role/rating/appearance data is retained');
  perform pg_temp.block_expect(public.list_fieldrush_clan_identities(array[clan])->0->>'content_hidden'='true','batch clan identities use the same server mask');
  perform pg_temp.block_expect(public.get_fieldrush_profile_clan(auth.uid())->>'content_hidden'='true','own membership retains safe clan identity');
end $$;
reset role;

-- A blocked latest editor cannot publish identity through someone else's clan.
select pg_temp.block_actor((select id from block_fixtures where key='p4'));
update public.clans set motto='Latest editor authored this motto',emblem='🔥'
where id=(select id from block_fixtures where key='other_clan');
select pg_temp.block_actor((select id from block_fixtures where key='p3'));
update public.clans set motto='Unblocked owner changed only the motto'
where id=(select id from block_fixtures where key='other_clan');
select pg_temp.block_actor((select id from block_fixtures where key='p1'));
set local role authenticated;
select public.set_fieldrush_player_block((select id from block_fixtures where key='p4'),true);
select pg_temp.block_expect(public.list_fieldrush_clan_identities(array[(select id from block_fixtures where key='other_clan')])->0->>'content_hidden'='true',
  'blocked emblem author remains covered after an unblocked owner edits only the motto');
select pg_temp.block_expect(public.list_fieldrush_connection_clans(array[(select id from block_fixtures where key='p3')])->0#>>'{clans,name}'='Hidden clan',
  'connection clan hydration cannot bypass the identity-editor mask');
select pg_temp.block_reject(format('select public.set_fieldrush_player_block(%L,true)',(select id from block_fixtures where key='staff_key')),'22023');
select pg_temp.block_expect(public.submit_moderation_report('PLAYER',(select id from block_fixtures where key='p2'),
  'INAPPROPRIATE_CONTENT','Blocking contract report; transaction rolls back.',null,null) is not null,'reporting remains available after blocking');
do $$
declare payload jsonb:=public.get_open_queue_party_context((select id from block_fixtures where key='game'));
  target uuid:=(select id from block_fixtures where key='p2'); candidate uuid:=(select id from block_fixtures where key='p3');
  hidden_candidates jsonb;
begin
  perform pg_temp.block_expect(payload#>>'{my_party,accepted_count}'='2'
    and payload#>>'{my_party,invited_count}'='1'
    and jsonb_array_length(payload#>'{my_party,members}')=3,
    'content blocking preserves accepted party and pending member counts');
  perform pg_temp.block_expect((select value->>'display_name'='Blocked player'
      and value->'avatar_url'='null'::jsonb from jsonb_array_elements(payload#>'{my_party,members}')
      where value->>'profile_id'=target::text),
    'accepted blocked party member identity is masked without removing their seat');
  perform pg_temp.block_expect(not exists(select 1 from jsonb_array_elements(payload->'eligible_players')
    where value->>'profile_id' in (select id::text from block_fixtures where key in('p2','p4'))),
    'blocked peers cannot appear as party invitation candidates');
  perform pg_temp.block_expect(exists(select 1 from jsonb_array_elements(payload->'eligible_players')
    where value->>'profile_id'=candidate::text),'fixture includes a genuinely eligible unblocked party candidate');
  begin
    perform public.set_fieldrush_player_block(candidate,true);
    hidden_candidates:=public.get_open_queue_party_context((select id from block_fixtures where key='game'));
    perform pg_temp.block_expect(not exists(select 1 from jsonb_array_elements(hidden_candidates->'eligible_players')
      where value->>'profile_id'=candidate::text),'blocking removes an otherwise eligible direct-invitation candidate');
    raise exception using errcode='PT001';
  exception when sqlstate 'PT001' then null; end;
end $$;
reset role;
select pg_temp.block_actor((select id from block_fixtures where key='p4'));
set local role authenticated;
select pg_temp.block_reject(format('select public.invite_open_queue_party_member(%L,%L)',
  (select id from block_fixtures where key='other_party'),(select id from block_fixtures where key='p1')),'42501');
select pg_temp.block_reject(format('select public.respond_open_queue_party_invitation(%L,true)',
  (select id from block_fixtures where key='pending_invite')),'42501');
select pg_temp.block_expect(jsonb_array_length(public.get_open_queue_party_context((select id from block_fixtures where key='game'))->'received_invites')=0,
  'blocked inviter has no actionable incoming invitation or raw owner content');
select pg_temp.block_expect(jsonb_array_length(public.list_my_open_queue_party_invite_notifications())=0,
  'blocked inviter has no actionable pending invitation notification');
reset role;
select pg_temp.block_expect((select jsonb_agg(to_jsonb(p) order by p.id)=(select data from block_snapshots where key='parties')
  from public.open_queue_parties p where game_id=(select id from block_fixtures where key='game')),
  'blocking and denied invitation acceptance preserve existing accepted parties');
select pg_temp.block_expect((select jsonb_agg(to_jsonb(m) order by m.id)=(select data from block_snapshots where key='party_members')
  from public.open_queue_party_members m where game_id=(select id from block_fixtures where key='game')),
  'denied party switch rolls back all existing memberships rather than evicting players');
select pg_temp.block_expect((select jsonb_agg(to_jsonb(b) order by b.id)=(select data from block_snapshots where key='bookings')
  from public.open_queue_bookings b where game_id=(select id from block_fixtures where key='game')),
  'social invitation restrictions preserve every booking/payment and physical roster');

-- Staff keeps operational access; this feature cannot create a player identity
-- or evade staff duties. Service-role retains existing administrative reads.
select pg_temp.block_actor((select id from block_fixtures where key='p6'));
set local role authenticated;
select pg_temp.block_expect(public.is_fieldrush_account_active(auth.uid()),
  'hybrid fixture genuinely satisfies the legacy active-player gate');
select pg_temp.block_expect(not public.is_fieldrush_block_owner(auth.uid()),
  'hybrid staff Auth identity cannot pass the block owner predicate');
select pg_temp.block_expect((select count(*)=0 from public.profile_blocks),
  'owner-only RLS excludes a hybrid staff identity even from its former preferences');
select pg_temp.block_reject('select public.list_fieldrush_blocked_players()','42501');
select pg_temp.block_reject(format('select public.get_fieldrush_player_safety(%L)',(select id from block_fixtures where key='p1')),'42501');
select pg_temp.block_reject(format('select public.set_fieldrush_player_block(%L,false)',(select id from block_fixtures where key='p1')),'42501');
reset role;
delete from public.profile_blocks where blocker_profile_id=(select id from block_fixtures where key='p6');
select pg_temp.block_actor((select id from block_fixtures where key='staff_login'));
set local role authenticated;
select pg_temp.block_expect(public.is_active_moderation_admin((select id from block_fixtures where key='staff_key')),'staff moderation duty remains active');
select pg_temp.block_reject('select public.list_fieldrush_blocked_players()','42501');
select pg_temp.block_expect((select count(*)=0 from public.profile_blocks),'staff login receives no other player private block list');
reset role;
select pg_temp.block_actor((select id from block_fixtures where key='p1'),'service_role');
set local role service_role;
select pg_temp.block_expect((select count(*)=2 from public.profile_blocks),'trusted service role can retain administrative block-table access');
select pg_temp.block_expect((select value->>'name'='Blocking target club'
  from jsonb_array_elements(public.list_fieldrush_clans()) where value->>'id'=(select id::text from block_fixtures where key='clan')),
  'service-role operational clan reads ignore player content preferences even with a subject claim');
reset role;
select pg_temp.block_actor(null,'anon');
set local role anon;
select pg_temp.block_reject('select * from public.profile_blocks','42501');
select pg_temp.block_reject('select public.list_fieldrush_blocked_players()','42501');
select pg_temp.block_reject('select public.list_fieldrush_discover_profiles()','42501');
reset role;

-- Unblocking is idempotent and does not recreate either old follow relationship.
select pg_temp.block_actor((select id from block_fixtures where key='p1'));
set local role authenticated;
select public.set_fieldrush_player_block((select id from block_fixtures where key='p2'),false);
select public.set_fieldrush_player_block((select id from block_fixtures where key='p2'),false);
select pg_temp.block_expect(public.get_fieldrush_profile_identity((select id from block_fixtures where key='p2'))->>'content_hidden'='false',
  'unblocking restores permitted authored identity');
select pg_temp.block_expect(jsonb_array_length(public.list_fieldrush_profile_identities(array[(select id from block_fixtures where key='p2')]))=1,
  'unblocked connection identity is available again');
select pg_temp.block_expect(not exists(select 1 from public.profile_follows where follower_id=auth.uid()
  and following_id=(select id from block_fixtures where key='p2')),'unblock does not silently restore following');
insert into public.profile_follows(follower_id,following_id)
  select auth.uid(),id from block_fixtures where key='p2';
select public.set_fieldrush_player_block((select id from block_fixtures where key='p5'),true);
reset role;
-- This disposable identity has no clan ownership, payments or active bookings.
-- Exercise the real Auth deletion/anonymization path instead of forging its
-- lifecycle flag; dependent block preferences must be cleaned in that path.
select pg_temp.block_actor((select id from block_fixtures where key='p5'),'service_role');
delete from auth.users where id=(select id from block_fixtures where key='p5');
select pg_temp.block_expect(not exists(select 1 from public.profile_blocks where
  blocker_profile_id=(select id from block_fixtures where key='p5') or blocked_profile_id=(select id from block_fixtures where key='p5')),
  'account deletion clears both directions of its private blocking preferences');

select pg_temp.block_expect(not has_function_privilege('authenticated','public.list_fieldrush_clans_before_player_blocks()','execute')
  and not has_function_privilege('anon','public.get_fieldrush_profile_identity(uuid)','execute'),
  'unmasked wrapper implementations and new identity RPCs retain the intended ACL boundary');
select 'Player blocking contracts passed' as result;
