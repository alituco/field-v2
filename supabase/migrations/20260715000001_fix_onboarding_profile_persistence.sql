create or replace function public.save_my_onboarding_profile(
  display_name_to_use text default null,
  date_of_birth_to_use date default null
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  supplied_name text := nullif(btrim(display_name_to_use), '');
  existing_name text;
  metadata_name text;
  resolved_name text;
  caller_phone text := nullif(auth.jwt() ->> 'phone', '');
begin
  if caller_id is null then
    raise exception 'You must be signed in to update your profile.'
      using errcode = '42501';
  end if;

  select profile.display_name
  into existing_name
  from public.profiles profile
  where profile.id = caller_id;

  metadata_name := nullif(
    btrim(
      coalesce(
        auth.jwt() -> 'user_metadata' ->> 'display_name',
        auth.jwt() -> 'user_metadata' ->> 'name'
      )
    ),
    ''
  );
  resolved_name := coalesce(supplied_name, existing_name, metadata_name);

  if resolved_name is null
    or char_length(resolved_name) not between 2 and 24 then
    raise exception 'Your name must be between 2 and 24 characters.';
  end if;

  if date_of_birth_to_use is not null
    and date_of_birth_to_use > (current_date - interval '16 years')::date then
    raise exception 'You must be at least 16 years old to play.';
  end if;

  insert into public.profiles as profile (
    id,
    phone,
    display_name,
    date_of_birth
  )
  values (
    caller_id,
    caller_phone,
    resolved_name,
    date_of_birth_to_use
  )
  on conflict (id) do update
  set
    phone = coalesce(profile.phone, excluded.phone),
    display_name = case
      when supplied_name is not null then excluded.display_name
      else profile.display_name
    end,
    date_of_birth = case
      when date_of_birth_to_use is not null then excluded.date_of_birth
      else profile.date_of_birth
    end;
end;
$$;

comment on function public.save_my_onboarding_profile(text, date) is
'Persists the signed-in player''s private onboarding fields without exposing profile DOBs.';

revoke all on function public.save_my_onboarding_profile(text, date)
from public, anon, authenticated;
grant execute on function public.save_my_onboarding_profile(text, date)
to authenticated;
