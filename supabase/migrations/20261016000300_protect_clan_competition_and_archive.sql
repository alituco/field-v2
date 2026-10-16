-- Managers may edit their clan's presentation, not manufacture its competitive
-- record or bypass the archive action's fixture checks/membership cleanup.
-- This is deliberately an INVOKER trigger: trusted SECURITY DEFINER match and
-- archive actions retain their existing authorization and atomic behavior.
create or replace function public.protect_clan_competitive_fields()
returns trigger language plpgsql set search_path=pg_catalog,public,pg_temp as $$
begin
  if current_user='authenticated' then
    if tg_op='INSERT' then
      if new.skill_rating is distinct from 1500 or new.wins is distinct from 0
        or new.losses is distinct from 0 then
        raise exception 'New clans start with 1500 SR and no results.' using errcode='42501';
      end if;
      if new.archived_at is not null or new.archived_by is not null then
        raise exception 'Use the archive clan action.' using errcode='42501';
      end if;
    else
      if (new.skill_rating,new.wins,new.losses) is distinct from
        (old.skill_rating,old.wins,old.losses) then
        raise exception 'Competitive clan records are referee-controlled.' using errcode='42501';
      end if;
      if (new.archived_at,new.archived_by) is distinct from (old.archived_at,old.archived_by) then
        raise exception 'Use the archive clan action so fixtures and memberships are checked.' using errcode='42501';
      end if;
    end if;
  end if;
  return new;
end;
$$;
drop trigger protect_clan_competitive_fields on public.clans;
create trigger protect_clan_competitive_fields before insert or update on public.clans
  for each row execute function public.protect_clan_competitive_fields();
revoke all on function public.protect_clan_competitive_fields() from public,anon,authenticated,service_role;

-- Do not rewrite historical SR or assume a historical archive was fraudulent.
-- New direct writes are rejected; the existing owner-only archive RPC remains
-- responsible for pending requests, active memberships, and scheduled fixtures.
notify pgrst,'reload schema';
