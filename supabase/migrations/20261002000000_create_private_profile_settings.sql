-- You/account preferences are private and are not part of player discovery.
-- These are saved preferences only. Push registration/delivery is separate.
create table public.profile_settings (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  home_city text check (home_city is null or char_length(btrim(home_city)) between 2 and 80),
  game_reminders boolean not null default true,
  clan_callups boolean not null default true,
  party_invites boolean not null default true,
  ladder_moves boolean not null default true,
  replays_ready boolean not null default false,
  news_and_offers boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column public.profile_settings.home_city is
'Optional private display location. Does not determine ranking region, eligibility, or pricing.';

create trigger set_profile_settings_updated_at
before update on public.profile_settings
for each row execute function public.set_updated_at();

alter table public.profile_settings enable row level security;
create policy "Players read their own settings"
on public.profile_settings for select to authenticated
using (profile_id = auth.uid());

revoke all on public.profile_settings from public, anon, authenticated;
grant select on public.profile_settings to authenticated;
grant all on public.profile_settings to service_role;

create function public.get_my_profile_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  result jsonb;
begin
  if caller_id is null then
    raise exception 'You must be signed in to view account settings.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'home_city', settings.home_city,
    'date_of_birth', profile.date_of_birth,
    'email', nullif(account.email, ''),
    'phone', nullif(account.phone, ''),
    'email_verified', account.email_confirmed_at is not null and nullif(account.email, '') is not null,
    'phone_verified', account.phone_confirmed_at is not null and nullif(account.phone, '') is not null,
    'notifications', jsonb_build_object(
      'game_reminders', coalesce(settings.game_reminders, true),
      'clan_callups', coalesce(settings.clan_callups, true),
      'party_invites', coalesce(settings.party_invites, true),
      'ladder_moves', coalesce(settings.ladder_moves, true),
      'replays_ready', coalesce(settings.replays_ready, false),
      'news_and_offers', coalesce(settings.news_and_offers, false)
    )
  ) into result
  from auth.users account
  join public.profiles profile on profile.id = account.id
  left join public.profile_settings settings on settings.profile_id = profile.id
  where account.id = caller_id;

  if result is null then
    raise exception 'Complete your profile before changing account settings.' using errcode = 'P0002';
  end if;
  return result;
end;
$$;

create function public.update_my_notification_preferences(preferences_to_use jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  allowed_keys text[] := array['game_reminders', 'clan_callups', 'party_invites', 'ladder_moves', 'replays_ready', 'news_and_offers'];
begin
  if caller_id is null then
    raise exception 'You must be signed in to change notification preferences.' using errcode = '42501';
  end if;
  if preferences_to_use is null or jsonb_typeof(preferences_to_use) <> 'object' then
    raise exception 'Notification preferences must be an object.' using errcode = '22023';
  end if;
  if not preferences_to_use ?& allowed_keys
    or exists (
      select 1 from jsonb_each(preferences_to_use) item
      where not (item.key = any(allowed_keys)) or jsonb_typeof(item.value) <> 'boolean'
    ) then
    raise exception 'Provide exactly the six boolean notification preferences.' using errcode = '22023';
  end if;

  insert into public.profile_settings (
    profile_id, game_reminders, clan_callups, party_invites,
    ladder_moves, replays_ready, news_and_offers
  ) values (
    caller_id,
    (preferences_to_use ->> 'game_reminders')::boolean,
    (preferences_to_use ->> 'clan_callups')::boolean,
    (preferences_to_use ->> 'party_invites')::boolean,
    (preferences_to_use ->> 'ladder_moves')::boolean,
    (preferences_to_use ->> 'replays_ready')::boolean,
    (preferences_to_use ->> 'news_and_offers')::boolean
  ) on conflict (profile_id) do update set
    game_reminders = excluded.game_reminders,
    clan_callups = excluded.clan_callups,
    party_invites = excluded.party_invites,
    ladder_moves = excluded.ladder_moves,
    replays_ready = excluded.replays_ready,
    news_and_offers = excluded.news_and_offers;

  return public.get_my_profile_settings();
end;
$$;

create function public.save_my_account_details(
  display_name_to_use text,
  username_to_use text,
  bio_to_use text,
  avatar_url_to_use text,
  home_city_to_use text default null,
  date_of_birth_to_use date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  resolved_name text := btrim(display_name_to_use);
  resolved_username text := lower(btrim(username_to_use));
  resolved_bio text := btrim(coalesce(bio_to_use, ''));
  resolved_avatar text := nullif(btrim(avatar_url_to_use), '');
  resolved_city text := nullif(btrim(home_city_to_use), '');
begin
  if caller_id is null then
    raise exception 'You must be signed in to change account details.' using errcode = '42501';
  end if;
  if resolved_name is null or char_length(resolved_name) not between 2 and 24 then
    raise exception 'Name must be 2 to 24 characters.' using errcode = '22023';
  end if;
  if resolved_username is null or resolved_username !~ '^[a-z0-9_]{2,24}$' then
    raise exception 'Username must be 2 to 24 lowercase letters, numbers, or underscores.' using errcode = '22023';
  end if;
  if char_length(resolved_bio) > 160 then
    raise exception 'Bio must be 160 characters or fewer.' using errcode = '22023';
  end if;
  if resolved_city is not null and char_length(resolved_city) not between 2 and 80 then
    raise exception 'City must be 2 to 80 characters.' using errcode = '22023';
  end if;
  if resolved_avatar is not null and (char_length(resolved_avatar) > 2048 or resolved_avatar !~ '^https?://[^[:space:]]+$') then
    raise exception 'Avatar URL is not valid.' using errcode = '22023';
  end if;
  if date_of_birth_to_use is not null and (
    date_of_birth_to_use < date '1900-01-01'
    or date_of_birth_to_use > (current_date - interval '16 years')::date
  ) then
    raise exception 'Choose a valid birthday. You must be at least 16 years old to play.' using errcode = '22023';
  end if;

  update public.profiles set
    display_name = resolved_name,
    username = resolved_username,
    bio = resolved_bio,
    avatar_url = resolved_avatar,
    date_of_birth = coalesce(date_of_birth_to_use, date_of_birth)
  where id = caller_id;
  if not found then
    raise exception 'Complete your profile before changing account settings.' using errcode = 'P0002';
  end if;

  insert into public.profile_settings (profile_id, home_city)
  values (caller_id, resolved_city)
  on conflict (profile_id) do update set home_city = excluded.home_city;

  -- Keep onboarding metadata aligned without making private DOB discoverable.
  update auth.users set raw_user_meta_data =
    coalesce(raw_user_meta_data, '{}'::jsonb)
    || jsonb_build_object('display_name', resolved_name, 'name', resolved_name)
    || case when date_of_birth_to_use is null then '{}'::jsonb
       else jsonb_build_object('date_of_birth', date_of_birth_to_use::text) end
  where id = caller_id;

  return public.get_my_profile_settings();
exception when unique_violation then
  raise exception 'That username is already taken.' using errcode = '23505';
end;
$$;

revoke all on function public.get_my_profile_settings() from public, anon, authenticated;
revoke all on function public.update_my_notification_preferences(jsonb) from public, anon, authenticated;
revoke all on function public.save_my_account_details(text, text, text, text, text, date) from public, anon, authenticated;
grant execute on function public.get_my_profile_settings() to authenticated;
grant execute on function public.update_my_notification_preferences(jsonb) to authenticated;
grant execute on function public.save_my_account_details(text, text, text, text, text, date) to authenticated;
