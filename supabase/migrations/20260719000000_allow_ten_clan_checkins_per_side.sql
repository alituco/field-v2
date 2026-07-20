-- Clan matches remain seven-a-side on the pitch, but each clan may check in
-- three substitutes as part of its matchday squad. Keep the frozen
-- playersPerSide policy value at seven because formations, forfeits, and
-- rating rules still use the playing format.

do $migration$
declare
  context_definition text;
  check_in_definition text;
  context_players_per_side text :=
    '(terms_to_use.policy_snapshot #>>
                ''{clan,playersPerSide}'')::integer';
  check_in_players_per_side text :=
    '(terms_to_use.policy_snapshot #>>
      ''{clan,playersPerSide}'')::integer';
begin
  select pg_get_functiondef(
    'public.get_match_reliability_context(text,uuid)'::regprocedure
  ) into context_definition;

  if position(context_players_per_side in context_definition) = 0 then
    raise exception
      'Could not locate the clan check-in eligibility cap in get_match_reliability_context.';
  end if;

  context_definition := replace(
    context_definition,
    context_players_per_side,
    '10'
  );
  execute context_definition;

  select pg_get_functiondef(
    'public.referee_check_in_player(uuid,text,uuid,uuid)'::regprocedure
  ) into check_in_definition;

  if position(check_in_players_per_side in check_in_definition) = 0 then
    raise exception
      'Could not locate the clan check-in cap in referee_check_in_player.';
  end if;

  check_in_definition := replace(
    check_in_definition,
    check_in_players_per_side,
    '10'
  );
  execute check_in_definition;
end;
$migration$;

comment on function public.referee_check_in_player(uuid,text,uuid,uuid) is
'Records a provisional, referee-authoritative arrival. Clan squads permit up to ten checked-in players per clan, including substitutes.';
