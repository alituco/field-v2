-- Warnings are non-blocking, but the affected player must be able to see the
-- player-facing explanation. Private notes and reporter identities stay hidden.
create or replace function public.get_my_moderation_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  active_action record;
  latest_warning record;
  warning_count integer;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select action.action_type, action.restriction_scope, action.reason_code,
    action.user_message, action.starts_at, action.ends_at
  into active_action
  from public.moderation_actions action
  where action.subject_type = 'PLAYER'
    and action.subject_profile_id = user_id
    and action.action_type in ('SUSPENSION', 'BAN')
    and action.revoked_at is null
    and action.starts_at <= now()
    and (action.ends_at is null or action.ends_at > now())
  order by
    case action.action_type when 'BAN' then 0 else 1 end,
    case action.restriction_scope when 'ACCOUNT' then 0 else 1 end,
    action.created_at desc
  limit 1;

  select action.reason_code, action.user_message, action.starts_at
  into latest_warning
  from public.moderation_actions action
  where action.subject_type = 'PLAYER'
    and action.subject_profile_id = user_id
    and action.action_type = 'WARNING'
    and action.revoked_at is null
    and action.starts_at <= now()
  order by action.created_at desc
  limit 1;

  select count(*)::integer into warning_count
  from public.moderation_actions action
  where action.subject_type = 'PLAYER'
    and action.subject_profile_id = user_id
    and action.action_type = 'WARNING'
    and action.revoked_at is null
    and action.starts_at <= now();

  return jsonb_build_object(
    'state', case
      when active_action.action_type = 'BAN' then 'BANNED'
      when active_action.action_type = 'SUSPENSION' then 'SUSPENDED'
      when warning_count > 0 then 'WARNING'
      else 'ACTIVE'
    end,
    'scope', active_action.restriction_scope,
    'reason_code', coalesce(
      active_action.reason_code,
      latest_warning.reason_code
    ),
    'message', coalesce(
      active_action.user_message,
      latest_warning.user_message
    ),
    'starts_at', coalesce(
      active_action.starts_at,
      latest_warning.starts_at
    ),
    'ends_at', active_action.ends_at,
    'warning_count', coalesce(warning_count, 0)
  );
end;
$$;

revoke all on function public.get_my_moderation_status()
from public, anon, authenticated;
grant execute on function public.get_my_moderation_status()
to authenticated;

comment on function public.get_my_moderation_status() is
'Returns only the signed-in player-facing moderation state; private evidence and reporters are never exposed.';
