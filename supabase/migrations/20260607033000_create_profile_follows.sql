create table if not exists public.profile_follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  following_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);

create index if not exists profile_follows_follower_idx
on public.profile_follows (follower_id, created_at desc);

create index if not exists profile_follows_following_idx
on public.profile_follows (following_id, created_at desc);

alter table public.profile_follows enable row level security;

drop policy if exists "Profile follows are readable by authenticated users"
on public.profile_follows;
create policy "Profile follows are readable by authenticated users"
on public.profile_follows
for select
to authenticated
using (true);

drop policy if exists "Users can follow profiles"
on public.profile_follows;
create policy "Users can follow profiles"
on public.profile_follows
for insert
to authenticated
with check (auth.uid() = follower_id and follower_id <> following_id);

drop policy if exists "Users can unfollow profiles"
on public.profile_follows;
create policy "Users can unfollow profiles"
on public.profile_follows
for delete
to authenticated
using (auth.uid() = follower_id);
