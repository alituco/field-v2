-- A recipient can acknowledge an activity item, but cannot rewrite its body,
-- ownership or resolution state. Existing SELECT RLS remains unchanged.
create or replace function public.mark_my_home_notification_read(notification_id_to_use uuid)
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
  set read_at = coalesce(read_at, now())
  where id = notification_id_to_use and recipient_profile_id = auth.uid();
end;
$$;
revoke all on function public.mark_my_home_notification_read(uuid) from public, anon;
grant execute on function public.mark_my_home_notification_read(uuid) to authenticated;
