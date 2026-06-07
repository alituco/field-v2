insert into public.profiles (id, phone, display_name)
select
  users.id,
  users.phone,
  case
    when char_length(trim(coalesce(users.raw_user_meta_data ->> 'display_name', ''))) between 2 and 24
      then trim(users.raw_user_meta_data ->> 'display_name')
    when char_length(trim(coalesce(users.raw_user_meta_data ->> 'name', ''))) between 2 and 24
      then trim(users.raw_user_meta_data ->> 'name')
    else 'Player'
  end as display_name
from auth.users
where not exists (
  select 1
  from public.profiles
  where profiles.id = users.id
);
