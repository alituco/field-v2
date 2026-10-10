-- The assigned referee may begin recording arrivals as soon as a match exists.
-- The configured opening timestamp remains an informational reminder; the
-- on-time deadline and no-show cutoff still classify and finalize attendance.

do $migration$
declare
  function_definition text;
  old_text text;
  new_text text;
begin
  select pg_get_functiondef(
    'public.get_match_reliability_context(text,uuid)'::regprocedure
  ) into function_definition;

  old_text := $old$    'can_check_in',
      can_view_roster
      and server_now_to_use >= terms_to_use.check_in_opens_at
      and server_now_to_use < terms_to_use.no_show_cutoff_at,$old$;
  new_text := $new$    'can_check_in',
      can_view_roster
      and server_now_to_use < terms_to_use.no_show_cutoff_at,$new$;

  if position(old_text in function_definition) = 0 then
    raise exception 'Could not remove the referee check-in opening gate from match context.';
  end if;
  execute replace(function_definition, old_text, new_text);

  select pg_get_functiondef(
    'public.referee_check_in_player(uuid,text,uuid,uuid)'::regprocedure
  ) into function_definition;

  old_text := $old$  if checked_in_at_to_use < terms_to_use.check_in_opens_at then
    raise exception 'Check-in opens at %.', terms_to_use.check_in_opens_at;
  end if;
$old$;

  if position(old_text in function_definition) = 0 then
    raise exception 'Could not remove the referee check-in opening validation.';
  end if;
  execute replace(function_definition, old_text, '');
end;
$migration$;

revoke all on function public.get_match_reliability_context(text,uuid)
from public, anon;
grant execute on function public.get_match_reliability_context(text,uuid)
to authenticated, service_role;

revoke all on function public.referee_check_in_player(uuid,text,uuid,uuid)
from public, anon, authenticated;
grant execute on function public.referee_check_in_player(uuid,text,uuid,uuid)
to service_role;

comment on function public.get_match_reliability_context(text,uuid) is
'Returns player-safe timing and lets the assigned referee check players in at any time before the no-show cutoff.';

comment on function public.referee_check_in_player(uuid,text,uuid,uuid) is
'Records referee-authoritative attendance at any time before no-show finalization while preserving active-match, eligibility, and team-size safeguards.';
