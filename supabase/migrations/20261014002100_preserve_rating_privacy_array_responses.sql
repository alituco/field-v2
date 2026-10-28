-- Empty objects are not an identity for jsonb array concatenation: array || {}
-- appends a blank player. These two APIs return arrays, not objects with owner
-- prediction metadata. Keep the privacy boundary and exact response cardinality.
create or replace function public.search_fieldrush_players(query_to_use text)
returns jsonb language sql stable security definer
set search_path=public,pg_temp as $$
  select fieldrush_rating_private.mask_public_rating_payload(
    public.search_fieldrush_players_before_sr_privacy($1),
    null::uuid,'OUTFIELD',null::integer,null::uuid
  );
$$;

create or replace function public.list_fieldrush_clan_members(clan_id_to_use uuid)
returns jsonb language sql stable security definer
set search_path=public,pg_temp as $$
  select fieldrush_rating_private.mask_public_rating_payload(
    public.list_fieldrush_clan_members_before_sr_privacy($1),
    null::uuid,'OUTFIELD',null::integer,null::uuid
  );
$$;

-- CREATE OR REPLACE retains the existing ACLs; do not expose either unmasked
-- implementation while fixing the public presentation wrappers.
do $migration$
declare signature text;
begin
  foreach signature in array array['public.search_fieldrush_players(text)',
    'public.list_fieldrush_clan_members(uuid)'] loop
    if has_function_privilege('anon',signature,'execute')
      or not has_function_privilege('authenticated',signature,'execute')
      or not has_function_privilege('service_role',signature,'execute') then
      raise exception 'Rating array wrapper permissions changed: %',signature;
    end if;
  end loop;
  foreach signature in array array['public.search_fieldrush_players_before_sr_privacy(text)',
    'public.list_fieldrush_clan_members_before_sr_privacy(uuid)'] loop
    if has_function_privilege('anon',signature,'execute')
      or has_function_privilege('authenticated',signature,'execute')
      or has_function_privilege('service_role',signature,'execute') then
      raise exception 'Unmasked rating array implementation must remain private: %',signature;
    end if;
  end loop;
end;
$migration$;
notify pgrst,'reload schema';
