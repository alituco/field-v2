-- A player can clear an activity receipt without resolving its invitation,
-- refund, support ticket, or any other underlying operational outcome.
alter table public.notifications
  add column if not exists dismissed_at timestamptz;

comment on column public.notifications.dismissed_at is
  'Recipient-owned activity dismissal receipt; independent of resolved_at.';

create index if not exists notifications_recipient_active_activity_idx
  on public.notifications (recipient_profile_id, created_at desc)
  where resolved_at is null and dismissed_at is null;

create or replace function public.dismiss_my_home_notification(
  notification_id_to_use uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  update public.notifications
  set dismissed_at = coalesce(dismissed_at, now()),
      read_at = coalesce(read_at, now())
  where id = notification_id_to_use
    and recipient_profile_id = auth.uid();

  if not found then
    raise exception 'Notification not found' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.dismiss_my_home_notification(uuid)
  from public, anon;
grant execute on function public.dismiss_my_home_notification(uuid)
  to authenticated;
