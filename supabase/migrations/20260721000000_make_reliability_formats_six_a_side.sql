-- Field now operates both Solo and Clan matches as six-a-side. Historical
-- published policies remain immutable and retain their original format, while
-- every editable or newly created draft is normalized to six players per side.

alter table public.reliability_policy_versions
drop constraint if exists reliability_policy_release_controls_check;

create or replace function public.reliability_policy_release_controls_are_valid(
  config_to_check jsonb
)
returns boolean
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  return
    (config_to_check #>> '{solo,playersPerSide}')::integer = 6
    and (config_to_check #>> '{clan,playersPerSide}')::integer = 6
    and (config_to_check #>> '{solo,outcomes,fieldCancelled,strikes}')::integer = 0
    and (config_to_check #>> '{injury,strikeDelta}')::integer = 0
    and (config_to_check #>> '{injury,requiresRefereeVerification}')::boolean
      is true
    and not (config_to_check #>>
      '{appeals,routineTrafficAutomaticallyExcused}')::boolean;
exception
  when others then
    return false;
end;
$$;

create or replace function public.normalize_reliability_draft_format()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  minimum_on_time integer;
  minimum_at_kickoff integer;
begin
  if new.state <> 'DRAFT' then
    return new;
  end if;

  minimum_on_time := least(
    coalesce((new.config #>> '{clan,minimumOnTimeWithoutClanStrike}')::integer, 6),
    6
  );
  minimum_at_kickoff := least(
    coalesce((new.config #>> '{clan,minimumAtKickoffWithoutForfeit}')::integer, 6),
    6
  );

  new.config := jsonb_set(new.config, '{solo,playersPerSide}', '6'::jsonb, false);
  new.config := jsonb_set(new.config, '{clan,playersPerSide}', '6'::jsonb, false);
  new.config := jsonb_set(
    new.config,
    '{clan,minimumOnTimeWithoutClanStrike}',
    to_jsonb(minimum_on_time),
    false
  );
  new.config := jsonb_set(
    new.config,
    '{clan,minimumAtKickoffWithoutForfeit}',
    to_jsonb(minimum_at_kickoff),
    false
  );
  return new;
end;
$$;

drop trigger if exists normalize_reliability_draft_format
on public.reliability_policy_versions;
create trigger normalize_reliability_draft_format
before insert or update of state, config
on public.reliability_policy_versions
for each row execute function public.normalize_reliability_draft_format();

update public.reliability_policy_versions
set config = config
where state = 'DRAFT';

alter table public.reliability_policy_versions
add constraint reliability_policy_release_controls_check
check (
  state = 'PUBLISHED'
  or public.reliability_policy_release_controls_are_valid(config)
);

alter table public.reliability_policy_versions
validate constraint reliability_policy_release_controls_check;

revoke all on function public.reliability_policy_release_controls_are_valid(jsonb)
from public, anon, authenticated;
grant execute on function public.reliability_policy_release_controls_are_valid(jsonb)
to service_role;

revoke all on function public.normalize_reliability_draft_format()
from public, anon, authenticated;

comment on function public.normalize_reliability_draft_format() is
'Keeps every editable reliability policy at Field''s six-a-side Solo and Clan format while preserving immutable historical policies.';

comment on constraint reliability_policy_release_controls_check
on public.reliability_policy_versions is
'Editable reliability drafts must use the supported six-a-side formats and locked safety invariants. Historical published versions remain immutable.';
