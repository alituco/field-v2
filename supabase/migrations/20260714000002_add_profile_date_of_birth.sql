alter table public.profiles
add column if not exists date_of_birth date;

comment on column public.profiles.date_of_birth is
'Private date of birth collected during onboarding. Players must be 16 or older.';

-- Profiles remain discoverable, but DOB is deliberately excluded from the
-- authenticated column grant. The owner reads it from private auth metadata.
revoke select on table public.profiles from authenticated;
grant select (
  id,
  phone,
  display_name,
  created_at,
  updated_at,
  username,
  bio,
  avatar_url,
  following_count,
  fans_count
) on table public.profiles to authenticated;

create or replace function public.enforce_profile_minimum_age()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.date_of_birth is not null
    and new.date_of_birth > (current_date - interval '16 years')::date then
    raise exception 'You must be at least 16 years old to play.';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_profile_minimum_age on public.profiles;
create trigger enforce_profile_minimum_age
before insert or update of date_of_birth on public.profiles
for each row
execute function public.enforce_profile_minimum_age();

-- Existing development users need a valid birthday so the new onboarding
-- gate does not treat seeded accounts as incomplete. The seed script writes
-- varied birthdays on its next run; this safe backfill covers current data.
with fake_profiles as (
  select id
  from public.profiles
  where phone in (
    '+97338883671',
    '+97338883672',
    '+97338883673',
    '+97338883674',
    '+97338883675',
    '+97338883676',
    '+97338883677',
    '+97338883678',
    '+97338883679'
  )
  or nullif(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), '')::bigint
    between 97338900001 and 97338900082
)
update public.profiles profile
set date_of_birth = date '2000-01-01'
from fake_profiles fake
where profile.id = fake.id
  and profile.date_of_birth is null;

update auth.users auth_user
set raw_user_meta_data = coalesce(auth_user.raw_user_meta_data, '{}'::jsonb)
  || jsonb_build_object(
    'date_of_birth',
    profile.date_of_birth::text
  )
from public.profiles profile
where auth_user.id = profile.id
  and profile.date_of_birth is not null
  and (
    profile.phone in (
      '+97338883671',
      '+97338883672',
      '+97338883673',
      '+97338883674',
      '+97338883675',
      '+97338883676',
      '+97338883677',
      '+97338883678',
      '+97338883679'
    )
    or nullif(
      regexp_replace(coalesce(profile.phone, ''), '\D', '', 'g'),
      ''
    )::bigint
      between 97338900001 and 97338900082
  );
