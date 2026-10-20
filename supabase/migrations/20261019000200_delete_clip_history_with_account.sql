-- Auth deletion keeps an anonymized profile to preserve match history. Private
-- viewing history must follow the Auth account instead of that retained row.
delete from public.profile_highlight_view_history history
where not exists (
  select 1 from auth.users account where account.id = history.viewer_profile_id
);

alter table public.profile_highlight_view_history
drop constraint profile_highlight_view_history_viewer_profile_id_fkey;

alter table public.profile_highlight_view_history
add constraint profile_highlight_view_history_viewer_profile_id_fkey
foreign key (viewer_profile_id) references auth.users(id) on delete cascade;
