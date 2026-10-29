-- Player-owned content blocking. These preferences do not remove attendance,
-- bookings, payments, match results or staff moderation access. Legacy profile
-- table reads remain compatible; updated clients use the viewer-safe readers.
create schema fieldrush_safety_private;
revoke all on schema fieldrush_safety_private from public, anon, authenticated, service_role;

create table public.profile_blocks (
  blocker_profile_id uuid not null references public.profiles(id) on delete cascade,
  blocked_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (blocker_profile_id, blocked_profile_id),
  check (blocker_profile_id <> blocked_profile_id)
);
create index profile_blocks_reverse_idx
  on public.profile_blocks(blocked_profile_id, blocker_profile_id);
alter table public.profile_blocks enable row level security;
revoke all on public.profile_blocks from public, anon, authenticated;
grant select on public.profile_blocks to authenticated;
grant all on public.profile_blocks to service_role;
comment on table public.profile_blocks is
  'Private player-owned content/following preferences, not account bans or deletion of official game facts.';

create function fieldrush_safety_private.viewer_profile_id()
returns uuid language sql stable security definer
set search_path=pg_catalog,public,auth,fieldrush_private,pg_temp as $$
  select p.id from public.profiles p where p.auth_user_id=auth.uid()
    and auth.role()='authenticated'
    and p.account_deleted_at is null
    and public.is_fieldrush_account_active(p.auth_user_id)
    and not fieldrush_private.is_staff_auth_user(p.auth_user_id);
$$;
-- RLS cannot read profiles.auth_user_id through the caller's restricted column
-- grants. Expose only this self-owner predicate, never the private Auth binding.
create function public.is_fieldrush_block_owner(profile_id_to_check uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
  select coalesce(profile_id_to_check=fieldrush_safety_private.viewer_profile_id(),false);
$$;
revoke all on function public.is_fieldrush_block_owner(uuid) from public,anon,authenticated,service_role;
grant execute on function public.is_fieldrush_block_owner(uuid) to authenticated;
create policy "Players can read only their own blocks" on public.profile_blocks
for select to authenticated using (public.is_fieldrush_block_owner(blocker_profile_id));
create function fieldrush_safety_private.require_player()
returns uuid language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,fieldrush_safety_private,pg_temp as $$
declare caller uuid:=fieldrush_private.require_user(); player uuid;
begin
  select p.id into player from public.profiles p where p.auth_user_id=caller
    and p.account_deleted_at is null and public.is_fieldrush_account_active(caller)
    and not fieldrush_private.is_staff_auth_user(caller);
  if player is null then
    raise exception 'Complete your player account before managing blocked players.' using errcode='42501';
  end if;
  return player;
end $$;
create function fieldrush_safety_private.pair_blocked(first_profile uuid,second_profile uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,pg_temp as $$
  select first_profile is not null and second_profile is not null and exists(
    select 1 from public.profile_blocks b
    where (b.blocker_profile_id=first_profile and b.blocked_profile_id=second_profile)
       or (b.blocker_profile_id=second_profile and b.blocked_profile_id=first_profile));
$$;
create function fieldrush_safety_private.lock_pair(first_profile uuid,second_profile uuid)
returns void language sql volatile security definer set search_path=pg_catalog as $$
  select pg_advisory_xact_lock(hashtextextended(
    least(first_profile::text,second_profile::text)||':'||greatest(first_profile::text,second_profile::text),0));
$$;

create function fieldrush_safety_private.guard_block_insert()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
begin
  perform fieldrush_safety_private.lock_pair(new.blocker_profile_id,new.blocked_profile_id);
  return new;
end $$;
create trigger fieldrush_block_pair_lock before insert on public.profile_blocks
for each row execute function fieldrush_safety_private.guard_block_insert();
create function fieldrush_safety_private.clear_blocked_follows()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
begin
  delete from public.profile_follows
    where (follower_id=new.blocker_profile_id and following_id=new.blocked_profile_id)
       or (follower_id=new.blocked_profile_id and following_id=new.blocker_profile_id);
  return new;
end $$;
create trigger fieldrush_clear_blocked_follows after insert on public.profile_blocks
for each row execute function fieldrush_safety_private.clear_blocked_follows();
create function fieldrush_safety_private.guard_follow()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
begin
  perform fieldrush_safety_private.lock_pair(new.follower_id,new.following_id);
  -- This VOLATILE trigger executes a fresh query after waiting for the pair
  -- lock. A STABLE helper could otherwise reuse the INSERT statement snapshot
  -- from before a concurrent block committed.
  if exists(select 1 from public.profile_blocks b
    where (b.blocker_profile_id=new.follower_id and b.blocked_profile_id=new.following_id)
       or (b.blocker_profile_id=new.following_id and b.blocked_profile_id=new.follower_id)) then
    raise exception 'Following is unavailable between these players.' using errcode='42501';
  end if;
  return new;
end $$;
create trigger fieldrush_block_follow_guard
before insert or update of follower_id,following_id on public.profile_follows
for each row execute function fieldrush_safety_private.guard_follow();
create function fieldrush_safety_private.guard_party_invitation()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare owner_id uuid; check_pair boolean:=false;
begin
  if tg_op='INSERT' then
    check_pair:=new.status='INVITED';
  else
    check_pair:=(new.status='INVITED' and
      row(new.party_id,new.profile_id,new.status) is distinct from row(old.party_id,old.profile_id,old.status))
      or (old.status='INVITED' and new.status='ACCEPTED');
  end if;
  if not check_pair then return new; end if;
  select p.owner_profile_id into owner_id from public.open_queue_parties p where p.id=new.party_id;
  perform fieldrush_safety_private.lock_pair(owner_id,new.profile_id);
  -- A fresh query after the same pair lock serializes invitation/acceptance
  -- with blocking. Already accepted parties and official bookings are intact.
  if exists(select 1 from public.profile_blocks b
    where (b.blocker_profile_id=owner_id and b.blocked_profile_id=new.profile_id)
       or (b.blocker_profile_id=new.profile_id and b.blocked_profile_id=owner_id)) then
    raise exception 'Party invitations are unavailable between these players.' using errcode='42501';
  end if;
  return new;
end $$;
create trigger fieldrush_block_party_invitation_guard
before insert or update of party_id,profile_id,status on public.open_queue_party_members
for each row execute function fieldrush_safety_private.guard_party_invitation();
create function fieldrush_safety_private.clean_deleted_player()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
begin
  delete from public.profile_blocks
    where blocker_profile_id=new.id or blocked_profile_id=new.id;
  return new;
end $$;
create trigger fieldrush_clear_deleted_player_blocks
after update of account_deleted_at on public.profiles
for each row when (old.account_deleted_at is null and new.account_deleted_at is not null)
execute function fieldrush_safety_private.clean_deleted_player();

create function public.get_fieldrush_player_safety(profile_id_to_use uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare viewer uuid:=fieldrush_safety_private.require_player();
begin
  if not exists(select 1 from public.profiles p where p.id=profile_id_to_use
    and p.account_deleted_at is null and public.is_fieldrush_account_active(p.auth_user_id)) then
    raise exception 'Player profile unavailable.' using errcode='22023';
  end if;
  return jsonb_build_object('profile_id',profile_id_to_use,
    'blocked_by_me',exists(select 1 from public.profile_blocks b
      where b.blocker_profile_id=viewer and b.blocked_profile_id=profile_id_to_use),
    'interaction_blocked',fieldrush_safety_private.pair_blocked(viewer,profile_id_to_use));
end $$;
create function public.set_fieldrush_player_block(profile_id_to_use uuid,blocked_to_use boolean)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare viewer uuid:=fieldrush_safety_private.require_player(); target_active boolean;
begin
  if profile_id_to_use is null or blocked_to_use is null or profile_id_to_use=viewer then
    raise exception 'Choose another player to block or unblock.' using errcode='22023';
  end if;
  perform fieldrush_safety_private.lock_pair(viewer,profile_id_to_use);
  -- Share-lock the identities in a fixed order before writing preferences;
  -- deletion's profile update then clears the preferences after this finishes.
  perform 1 from public.profiles p where p.id in (viewer,profile_id_to_use) order by p.id for share;
  if not exists(select 1 from public.profiles p where p.id=viewer
    and p.account_deleted_at is null and public.is_fieldrush_account_active(p.auth_user_id)
    and not fieldrush_private.is_staff_auth_user(p.auth_user_id)) then
    raise exception 'Your player account is no longer active.' using errcode='42501';
  end if;
  select exists(select 1 from public.profiles p where p.id=profile_id_to_use
    and p.account_deleted_at is null and public.is_fieldrush_account_active(p.auth_user_id)) into target_active;
  if blocked_to_use then
    if not target_active then raise exception 'Player profile unavailable.' using errcode='22023'; end if;
    insert into public.profile_blocks(blocker_profile_id,blocked_profile_id)
      values(viewer,profile_id_to_use) on conflict do nothing;
  else
    delete from public.profile_blocks where blocker_profile_id=viewer and blocked_profile_id=profile_id_to_use;
  end if;
  return jsonb_build_object('profile_id',profile_id_to_use,
    'blocked_by_me',exists(select 1 from public.profile_blocks b
      where b.blocker_profile_id=viewer and b.blocked_profile_id=profile_id_to_use),
    'interaction_blocked',target_active and fieldrush_safety_private.pair_blocked(viewer,profile_id_to_use));
end $$;
create function public.list_fieldrush_blocked_players()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare viewer uuid:=fieldrush_safety_private.require_player(); result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('profile_id',p.id,
    'username',p.username,'display_name',p.display_name,'blocked_at',b.created_at)
    order by b.created_at desc,p.id),'[]'::jsonb) into result
  from public.profile_blocks b join public.profiles p on p.id=b.blocked_profile_id
  where b.blocker_profile_id=viewer and p.account_deleted_at is null;
  return result;
end $$;

create function fieldrush_safety_private.profile_identity(profile_id_to_use uuid,viewer uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
  select jsonb_build_object('id',p.id,
    'display_name',case when fieldrush_safety_private.pair_blocked(viewer,p.id) then 'Blocked player' else p.display_name end,
    'username',case when fieldrush_safety_private.pair_blocked(viewer,p.id) then '' else p.username end,
    'bio',case when fieldrush_safety_private.pair_blocked(viewer,p.id) then '' else p.bio end,
    'avatar_url',case when fieldrush_safety_private.pair_blocked(viewer,p.id) then null else p.avatar_url end,
    'content_hidden',fieldrush_safety_private.pair_blocked(viewer,p.id))
  from public.profiles p where p.id=profile_id_to_use and p.account_deleted_at is null
    and (p.id=viewer or public.is_fieldrush_account_active(p.auth_user_id));
$$;
create function public.get_fieldrush_profile_identity(profile_id_to_use uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare viewer uuid:=fieldrush_safety_private.require_player(); result jsonb;
begin
  result:=fieldrush_safety_private.profile_identity(profile_id_to_use,viewer);
  if result is null then raise exception 'Player profile unavailable.' using errcode='22023'; end if;
  return result;
end $$;
create function public.list_fieldrush_profile_identities(profile_ids_to_use uuid[])
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare viewer uuid:=fieldrush_safety_private.require_player(); result jsonb;
begin
  if coalesce(cardinality(profile_ids_to_use),0)>100 then
    raise exception 'Request at most 100 player identities at once.' using errcode='22023'; end if;
  select coalesce(jsonb_agg(fieldrush_safety_private.profile_identity(p.id,viewer) order by p.id),'[]'::jsonb) into result
  from public.profiles p where p.id=any(profile_ids_to_use) and p.account_deleted_at is null
    and public.is_fieldrush_account_active(p.auth_user_id)
    and not fieldrush_safety_private.pair_blocked(viewer,p.id);
  return result;
end $$;
create function public.list_fieldrush_discover_profiles()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare viewer uuid:=fieldrush_safety_private.require_player(); result jsonb;
begin
  select coalesce(jsonb_agg(fieldrush_safety_private.profile_identity(p.id,viewer)
    order by lower(p.display_name),p.id),'[]'::jsonb) into result
  from (select p.* from public.profiles p where p.id<>viewer and p.account_deleted_at is null
    and public.is_fieldrush_account_active(p.auth_user_id)
    and not fieldrush_safety_private.pair_blocked(viewer,p.id)
    order by lower(p.display_name),p.id limit 1000) p;
  return result;
end $$;

-- Keep identity authorship private and separate from competitive clan fields.
-- Older identities fall back to their creator; subsequent identity edits record
-- the actual signed-in player per field. Editing a motto cannot erase the
-- authorship of another player's emblem. No client-supplied actor is trusted.
create table fieldrush_safety_private.clan_identity_authors (
  clan_id uuid primary key references public.clans(id) on delete cascade,
  name_author_id uuid references public.profiles(id) on delete set null,
  tag_author_id uuid references public.profiles(id) on delete set null,
  motto_author_id uuid references public.profiles(id) on delete set null,
  emblem_author_id uuid references public.profiles(id) on delete set null,
  theme_author_id uuid references public.profiles(id) on delete set null,
  pattern_author_id uuid references public.profiles(id) on delete set null
);
alter table fieldrush_safety_private.clan_identity_authors enable row level security;
create function fieldrush_safety_private.record_clan_identity_author()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare editor uuid:=coalesce(fieldrush_safety_private.viewer_profile_id(),new.created_by);
begin
  if tg_op='INSERT' then
    insert into fieldrush_safety_private.clan_identity_authors
      values(new.id,editor,editor,editor,editor,editor,editor);
  elsif row(new.name,new.tag,new.motto,new.emblem,new.theme_id,new.pattern_id)
    is distinct from row(old.name,old.tag,old.motto,old.emblem,old.theme_id,old.pattern_id) then
    insert into fieldrush_safety_private.clan_identity_authors as authors
      values(new.id,
        case when new.name is distinct from old.name then editor else new.created_by end,
        case when new.tag is distinct from old.tag then editor else new.created_by end,
        case when new.motto is distinct from old.motto then editor else new.created_by end,
        case when new.emblem is distinct from old.emblem then editor else new.created_by end,
        case when new.theme_id is distinct from old.theme_id then editor else new.created_by end,
        case when new.pattern_id is distinct from old.pattern_id then editor else new.created_by end)
      on conflict(clan_id) do update set
        name_author_id=case when new.name is distinct from old.name then editor else authors.name_author_id end,
        tag_author_id=case when new.tag is distinct from old.tag then editor else authors.tag_author_id end,
        motto_author_id=case when new.motto is distinct from old.motto then editor else authors.motto_author_id end,
        emblem_author_id=case when new.emblem is distinct from old.emblem then editor else authors.emblem_author_id end,
        theme_author_id=case when new.theme_id is distinct from old.theme_id then editor else authors.theme_author_id end,
        pattern_author_id=case when new.pattern_id is distinct from old.pattern_id then editor else authors.pattern_author_id end;
  end if;
  return new;
end $$;
create trigger fieldrush_record_clan_identity_author
after insert or update of name,tag,motto,emblem,theme_id,pattern_id on public.clans
for each row execute function fieldrush_safety_private.record_clan_identity_author();
create function fieldrush_safety_private.clan_content_hidden(clan_id_to_use uuid,viewer uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
  select exists(select 1
    from public.clans c left join fieldrush_safety_private.clan_identity_authors a on a.clan_id=c.id
    cross join lateral unnest(array[c.created_by,a.name_author_id,a.tag_author_id,
      a.motto_author_id,a.emblem_author_id,a.theme_author_id,a.pattern_author_id]) as author(profile_id)
    where c.id=clan_id_to_use and fieldrush_safety_private.pair_blocked(viewer,author.profile_id));
$$;
create function fieldrush_safety_private.mask_clan(row_to_use jsonb,viewer uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
begin
  if row_to_use is null then return null; end if;
  if fieldrush_safety_private.clan_content_hidden((row_to_use->>'id')::uuid,viewer) then
    return row_to_use||jsonb_build_object('name','Hidden clan','tag','HIDE','motto','',
      'emblem','⚽','theme_id','pitch','pattern_id','solid','content_hidden',true);
  end if;
  return row_to_use||jsonb_build_object('content_hidden',false);
end $$;
create function fieldrush_safety_private.clan_identity(clan_id_to_use uuid,viewer uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
  select fieldrush_safety_private.mask_clan(jsonb_build_object('id',c.id,'name',c.name,'tag',c.tag,'motto',c.motto,
    'emblem',c.emblem,'theme_id',c.theme_id,'pattern_id',c.pattern_id,'skill_rating',c.skill_rating),viewer)
  from public.clans c where c.id=clan_id_to_use and c.archived_at is null;
$$;
create function public.list_fieldrush_clan_identities(clan_ids_to_use uuid[])
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare viewer uuid:=fieldrush_safety_private.require_player(); result jsonb;
begin
  if coalesce(cardinality(clan_ids_to_use),0)>100 then
    raise exception 'Request at most 100 clan identities at once.' using errcode='22023'; end if;
  select coalesce(jsonb_agg(fieldrush_safety_private.clan_identity(c.id,viewer) order by c.id),'[]'::jsonb) into result
  from public.clans c where c.id=any(clan_ids_to_use) and c.archived_at is null;
  return result;
end $$;
create function public.get_fieldrush_profile_clan(profile_id_to_use uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare viewer uuid:=fieldrush_safety_private.require_player(); result jsonb;
begin
  if fieldrush_safety_private.pair_blocked(viewer,profile_id_to_use) then return null; end if;
  select fieldrush_safety_private.clan_identity(m.clan_id,viewer) into result
  from public.clan_members m join public.profiles p on p.id=m.profile_id
  where m.profile_id=profile_id_to_use and m.left_at is null and p.account_deleted_at is null
    and public.is_fieldrush_account_active(p.auth_user_id)
  order by m.created_at desc,m.clan_id limit 1;
  return result;
end $$;
create function public.list_fieldrush_connection_clans(profile_ids_to_use uuid[])
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare viewer uuid:=fieldrush_safety_private.require_player(); result jsonb;
begin
  if coalesce(cardinality(profile_ids_to_use),0)>100 then
    raise exception 'Request at most 100 player clans at once.' using errcode='22023'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('profile_id',m.profile_id,
    'clans',fieldrush_safety_private.clan_identity(m.clan_id,viewer)) order by m.profile_id),'[]'::jsonb) into result
  from public.clan_members m join public.clans c on c.id=m.clan_id
    join public.profiles p on p.id=m.profile_id
  where m.profile_id=any(profile_ids_to_use) and m.left_at is null and c.archived_at is null
    and p.account_deleted_at is null and public.is_fieldrush_account_active(p.auth_user_id)
    and not fieldrush_safety_private.pair_blocked(viewer,p.id);
  return result;
end $$;

-- Existing server clan readers retain roster cardinality, IDs and official
-- statistics. Only authored identity is masked for the viewer; staff and
-- service-role operational readers have no player-owned block context.
alter function public.list_fieldrush_clans() rename to list_fieldrush_clans_before_player_blocks;
revoke all on function public.list_fieldrush_clans_before_player_blocks() from public,anon,authenticated,service_role;
create function public.list_fieldrush_clans()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
  select coalesce(jsonb_agg(fieldrush_safety_private.mask_clan(c.value,fieldrush_safety_private.viewer_profile_id())
    order by c.ordinality),'[]'::jsonb)
  from jsonb_array_elements(public.list_fieldrush_clans_before_player_blocks()) with ordinality c;
$$;
alter function public.list_fieldrush_clan_members(uuid) rename to list_fieldrush_clan_members_before_player_blocks;
revoke all on function public.list_fieldrush_clan_members_before_player_blocks(uuid) from public,anon,authenticated,service_role;
create function public.list_fieldrush_clan_members(clan_id_to_use uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
  select coalesce(jsonb_agg(case
    when fieldrush_safety_private.pair_blocked(fieldrush_safety_private.viewer_profile_id(),(m.value->>'profile_id')::uuid)
    then m.value||jsonb_build_object('profiles',coalesce(m.value->'profiles','{}'::jsonb)||
      jsonb_build_object('display_name','Blocked player','username','','avatar_url',null,'content_hidden',true))
    else m.value end order by m.ordinality),'[]'::jsonb)
  from jsonb_array_elements(public.list_fieldrush_clan_members_before_player_blocks(clan_id_to_use)) with ordinality m;
$$;
revoke all on function public.list_fieldrush_clans(),public.list_fieldrush_clan_members(uuid) from public,anon;
grant execute on function public.list_fieldrush_clans(),public.list_fieldrush_clan_members(uuid) to authenticated,service_role;

create function fieldrush_safety_private.party_player(row_to_use jsonb,viewer uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
  select case when fieldrush_safety_private.pair_blocked(viewer,(row_to_use->>'profile_id')::uuid)
    then row_to_use||jsonb_build_object('display_name','Blocked player','username','','avatar_url',null,'content_hidden',true)
    else row_to_use end;
$$;
create function fieldrush_safety_private.party_context(payload jsonb,viewer uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
declare result jsonb:=payload; rows_to_use jsonb; invitation jsonb; received jsonb:='[]'::jsonb;
begin
  if viewer is null then return payload; end if;
  select coalesce(jsonb_agg(p.value order by p.ordinality),'[]'::jsonb) into rows_to_use
    from jsonb_array_elements(payload->'eligible_players') with ordinality p
    where not fieldrush_safety_private.pair_blocked(viewer,(p.value->>'profile_id')::uuid);
  result:=jsonb_set(result,'{eligible_players}',rows_to_use);
  if jsonb_typeof(payload->'my_party')='object' then
    select coalesce(jsonb_agg(fieldrush_safety_private.party_player(m.value,viewer) order by m.ordinality),'[]'::jsonb)
      into rows_to_use from jsonb_array_elements(payload#>'{my_party,members}') with ordinality m;
    result:=jsonb_set(result,'{my_party,members}',rows_to_use);
  end if;
  for invitation in select value from jsonb_array_elements(payload->'received_invites') loop
    if fieldrush_safety_private.pair_blocked(viewer,(invitation#>>'{owner,profile_id}')::uuid) then continue; end if;
    select coalesce(jsonb_agg(fieldrush_safety_private.party_player(m.value,viewer) order by m.ordinality),'[]'::jsonb)
      into rows_to_use from jsonb_array_elements(invitation->'members') with ordinality m;
    invitation:=jsonb_set(invitation,'{members}',rows_to_use);
    received:=received||jsonb_build_array(invitation);
  end loop;
  return jsonb_set(result,'{received_invites}',received);
end $$;
-- Preserve the existing private original, lazy reliability terms, volatility,
-- search path and ACLs. The SR privacy projection remains in the same order.
create or replace function public.get_open_queue_party_context(game_id_to_use uuid)
returns jsonb language sql volatile security definer set search_path=public,pg_temp as $$
  select fieldrush_safety_private.party_context(
    fieldrush_rating_private.mask_public_rating_payload(
      public.get_open_queue_party_context_before_sr_privacy($1),null::uuid,'OUTFIELD',null::integer,$1)||'{}'::jsonb,
    fieldrush_safety_private.viewer_profile_id());
$$;
-- Retain recipient scope, dismissal and notification preferences while hiding
-- pending direct invitations between blocked peers. No receipt is deleted.
create or replace function public.list_my_open_queue_party_invite_notifications()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,fieldrush_safety_private,pg_temp as $$
declare user_id uuid:=auth.uid(); viewer uuid:=fieldrush_safety_private.viewer_profile_id(); result jsonb;
begin
  if user_id is null then raise exception 'You need to sign in again.' using errcode='42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'notification_id',notification.id,'type',notification.type,
    'game_id',member.game_id,'party_id',member.party_id,'membership_id',member.id,
    'created_at',notification.created_at,'read_at',notification.read_at,'is_read',notification.read_at is not null,
    'inviter',jsonb_build_object('profile_id',inviter.id,'display_name',inviter.display_name,
      'username',inviter.username,'avatar_url',inviter.avatar_url),
    'game',jsonb_build_object('starts_at',game.starts_at,'venue',game.venue,'status',game.status)
  ) order by notification.created_at desc,notification.id desc),'[]'::jsonb) into result
  from public.notifications notification
  join public.open_queue_party_members member on member.id=notification.related_entity_id and member.status='INVITED'
  join public.open_queue_parties party on party.id=member.party_id and party.status='ACTIVE'
  join public.open_queue_games game on game.id=member.game_id and game.status in ('OPEN','FULL') and now()<game.starts_at
  join public.profiles inviter on inviter.id=member.invited_by
  where notification.recipient_profile_id=user_id
    and notification.type='OPEN_QUEUE_PARTY_INVITE' and notification.related_entity_type='OPEN_QUEUE_PARTY_MEMBERSHIP'
    and notification.resolved_at is null and notification.dismissed_at is null
    and fieldrush_private.notification_preference_allows(user_id,notification.type)
    and not fieldrush_safety_private.pair_blocked(viewer,party.owner_profile_id)
    and not fieldrush_safety_private.pair_blocked(viewer,member.invited_by);
  return result;
end $$;

-- Home reads recipient-owned notification rows directly, while cold links and
-- the push worker validate source freshness through private definer functions.
-- Apply the same pending-invitation boundary to both paths without deleting a
-- receipt or changing operational/nonparty notices or delivery configuration.
create function fieldrush_safety_private.party_receipt_blocked(notification_id_to_use uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,fieldrush_safety_private,pg_temp as $$
  select exists(select 1 from public.notifications n
    join public.open_queue_party_members m on m.id=n.related_entity_id
      and m.profile_id=n.recipient_profile_id and m.status='INVITED'
    join public.open_queue_parties p on p.id=m.party_id
    where n.id=notification_id_to_use and n.type='OPEN_QUEUE_PARTY_INVITE'
      and n.related_entity_type='OPEN_QUEUE_PARTY_MEMBERSHIP'
      and (fieldrush_safety_private.pair_blocked(n.recipient_profile_id,p.owner_profile_id)
        or fieldrush_safety_private.pair_blocked(n.recipient_profile_id,m.invited_by)));
$$;
create function public.my_fieldrush_party_receipt_is_visible(notification_id_to_use uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,auth,fieldrush_safety_private,pg_temp as $$
  select exists(select 1 from public.notifications n
    where n.id=notification_id_to_use and n.recipient_profile_id=auth.uid()
      and not fieldrush_safety_private.party_receipt_blocked(n.id));
$$;
revoke all on function public.my_fieldrush_party_receipt_is_visible(uuid) from public,anon,authenticated,service_role;
grant execute on function public.my_fieldrush_party_receipt_is_visible(uuid) to authenticated;
create policy notifications_player_party_blocks on public.notifications
as restrictive for select to authenticated using (
  type<>'OPEN_QUEUE_PARTY_INVITE' or public.my_fieldrush_party_receipt_is_visible(id)
);
alter function fieldrush_private.player_game_notification_source_is_current(uuid)
  rename to player_game_notification_source_before_player_blocks;
revoke all on function fieldrush_private.player_game_notification_source_before_player_blocks(uuid)
  from public,anon,authenticated,service_role;
create function fieldrush_private.player_game_notification_source_is_current(notification_id_to_use uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,fieldrush_private,fieldrush_safety_private,pg_temp as $$
  select fieldrush_private.player_game_notification_source_before_player_blocks($1)
    and not fieldrush_safety_private.party_receipt_blocked($1);
$$;
revoke all on function fieldrush_private.player_game_notification_source_is_current(uuid)
  from public,anon,authenticated,service_role;

revoke all on all tables in schema fieldrush_safety_private from public,anon,authenticated,service_role;
revoke all on all functions in schema fieldrush_safety_private from public,anon,authenticated,service_role;
do $permissions$
declare signature text;
begin
  foreach signature in array array[
    'public.get_fieldrush_player_safety(uuid)',
    'public.set_fieldrush_player_block(uuid,boolean)',
    'public.list_fieldrush_blocked_players()',
    'public.get_fieldrush_profile_identity(uuid)',
    'public.list_fieldrush_profile_identities(uuid[])',
    'public.list_fieldrush_discover_profiles()',
    'public.list_fieldrush_clan_identities(uuid[])',
    'public.get_fieldrush_profile_clan(uuid)',
    'public.list_fieldrush_connection_clans(uuid[])'
  ] loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',signature);
    execute format('grant execute on function %s to authenticated',signature);
  end loop;
end $permissions$;
notify pgrst,'reload schema';
