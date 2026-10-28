-- In-app optional alerts honor the recipient's saved preference. Suppressing an
-- alert never changes its party membership, booking, payment, or safety outcome.
-- Phone push registration/delivery is a separate, unconfigured channel.
create function fieldrush_private.notification_preference_allows(
  recipient_id uuid,notification_type text
)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,pg_temp as $$
  select case notification_type
    when 'GAME_REMINDER' then coalesce((select s.game_reminders from public.profile_settings s where s.profile_id=recipient_id),true)
    when 'CLAN_CALLUP' then coalesce((select s.clan_callups from public.profile_settings s where s.profile_id=recipient_id),true)
    when 'OPEN_QUEUE_PARTY_INVITE' then coalesce((select s.party_invites from public.profile_settings s where s.profile_id=recipient_id),true)
    when 'LADDER_MOVE' then coalesce((select s.ladder_moves from public.profile_settings s where s.profile_id=recipient_id),true)
    when 'REPLAY_READY' then coalesce((select s.replays_ready from public.profile_settings s where s.profile_id=recipient_id),false)
    when 'NEWS_AND_OFFERS' then coalesce((select s.news_and_offers from public.profile_settings s where s.profile_id=recipient_id),false)
  -- Safety, sanctions, support, payments, attendance and team changes remain
  -- operational notices. Unknown types are never silently treated as marketing.
  else true end;
$$;
revoke all on function fieldrush_private.notification_preference_allows(uuid,text)
  from public,anon,authenticated,service_role;

create function fieldrush_private.filter_optional_notification_insert()
returns trigger language plpgsql security definer
set search_path=pg_catalog,fieldrush_private,pg_temp as $$
begin
  if not fieldrush_private.notification_preference_allows(new.recipient_profile_id,new.type) then
    return null;
  end if;
  return new;
end;
$$;
revoke all on function fieldrush_private.filter_optional_notification_insert()
  from public,anon,authenticated,service_role;
create trigger filter_optional_notification_insert before insert on public.notifications
  for each row execute function fieldrush_private.filter_optional_notification_insert();

-- The public policy helper cannot probe another player's private preferences.
-- Keep the original recipient policy and add a restrictive preference policy.
create function public.my_notification_preference_allows(
  recipient_id uuid,notification_type text
)
returns boolean language plpgsql stable security definer
set search_path=pg_catalog,auth,fieldrush_private,pg_temp as $$
begin
  if auth.uid() is null or recipient_id is distinct from auth.uid() then return false; end if;
  return fieldrush_private.notification_preference_allows(recipient_id,notification_type);
end;
$$;
revoke all on function public.my_notification_preference_allows(uuid,text) from public,anon;
grant execute on function public.my_notification_preference_allows(uuid,text) to authenticated;
create policy notifications_optional_preference on public.notifications
  as restrictive for select to authenticated
  using (public.my_notification_preference_allows(recipient_profile_id,type));

-- This SECURITY DEFINER list must apply the same preference itself, rather than
-- relying on table RLS. An Activity dismissal is a receipt, not invite rejection.
create or replace function public.list_my_open_queue_party_invite_notifications()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare user_id uuid:=auth.uid(); result jsonb;
begin
  if user_id is null then raise exception 'You need to sign in again.' using errcode='42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'notification_id',notification.id,
    'type',notification.type,
    'game_id',member.game_id,
    'party_id',member.party_id,
    'membership_id',member.id,
    'created_at',notification.created_at,
    'read_at',notification.read_at,
    'is_read',notification.read_at is not null,
    'inviter',jsonb_build_object('profile_id',inviter.id,'display_name',inviter.display_name,
      'username',inviter.username,'avatar_url',inviter.avatar_url),
    'game',jsonb_build_object('starts_at',game.starts_at,'venue',game.venue,'status',game.status)
  ) order by notification.created_at desc,notification.id desc),'[]'::jsonb)
  into result
  from public.notifications notification
  join public.open_queue_party_members member on member.id=notification.related_entity_id and member.status='INVITED'
  join public.open_queue_parties party on party.id=member.party_id and party.status='ACTIVE'
  join public.open_queue_games game on game.id=member.game_id and game.status in ('OPEN','FULL') and now()<game.starts_at
  join public.profiles inviter on inviter.id=member.invited_by
  where notification.recipient_profile_id=user_id
    and notification.type='OPEN_QUEUE_PARTY_INVITE'
    and notification.related_entity_type='OPEN_QUEUE_PARTY_MEMBERSHIP'
    and notification.resolved_at is null
    and notification.dismissed_at is null
    and fieldrush_private.notification_preference_allows(user_id,notification.type);
  return result;
end;
$$;
revoke all on function public.list_my_open_queue_party_invite_notifications() from public,anon;
grant execute on function public.list_my_open_queue_party_invite_notifications() to authenticated;

notify pgrst,'reload schema';
