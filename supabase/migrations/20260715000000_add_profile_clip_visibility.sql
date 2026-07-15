alter table public.profile_highlights
add column if not exists is_public boolean not null default true;

comment on column public.profile_highlights.is_public is
'Public clips are visible to every authenticated user. Private clips are visible only to their owner.';

drop policy if exists "Profile highlights are readable by authenticated users"
on public.profile_highlights;

create policy "Public highlights and owned highlights are readable"
on public.profile_highlights
for select
to authenticated
using (
  is_public
  or profile_id = auth.uid()
);

drop policy if exists "Users can insert their own highlights"
on public.profile_highlights;

drop policy if exists "Users can update their own highlights"
on public.profile_highlights;

drop policy if exists "Users can delete their own highlights"
on public.profile_highlights;

revoke insert, update, delete on public.profile_highlights
from anon, authenticated;

grant select on public.profile_highlights to authenticated;

create index if not exists profile_highlights_public_profile_idx
on public.profile_highlights (profile_id, sort_order, created_at)
where is_public;

create or replace function public.record_profile_highlight_view(
  highlight_id_to_use uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  updated_views integer;
begin
  if caller_id is null then
    raise exception 'You need to sign in again.';
  end if;

  update public.profile_highlights highlight
  set views = highlight.views + 1
  where highlight.id = highlight_id_to_use
    and highlight.processing_status = 'READY'
    and (
      highlight.is_public
      or highlight.profile_id = caller_id
    )
  returning highlight.views into updated_views;

  if updated_views is null then
    raise exception 'That clip is not available to watch.';
  end if;

  return updated_views;
end;
$$;

revoke all on function public.record_profile_highlight_view(uuid)
from public, anon, authenticated;
grant execute on function public.record_profile_highlight_view(uuid)
to authenticated;

comment on function public.record_profile_highlight_view(uuid) is
'Atomically records one playback start for a ready public clip or a private clip owned by the caller.';
