-- Referee-confirmed results use the actual played duration, even when the
-- referee ends before the advertised slot. Preserve every historical result:
-- only an explicit finish or audited organizer opt-in selects this new rule.
alter table fieldrush_rating_private.season_zero_matches
  add column completion_rules_version text not null default 's0-full-duration-v1'
  check (completion_rules_version in ('s0-full-duration-v1','s0-referee-ended-v1'));
comment on column fieldrush_rating_private.season_zero_matches.completion_rules_version is
  'Pinned by explicit finalization. Historical replay retains the full-duration rule unless an organizer explicitly opts in with an audited correction.';

-- Keep the original calculators and normalizers byte-for-byte intact. New
-- versions retain all existing conduct, protection, forfeit and injury rules.
do $migration$
declare d text; variant text; anchor text;
begin
  foreach variant in array array['standard','configurable'] loop
    d:=pg_get_functiondef(('fieldrush_rating_private.calculate_season_zero_sr_'||variant||'(jsonb)')::regprocedure);
    d:=replace(d,'FUNCTION fieldrush_rating_private.calculate_season_zero_sr_'||variant||'(',
      'FUNCTION fieldrush_rating_private.calculate_season_zero_sr_referee_ended_'||variant||'(');
    anchor:='  counted boolean;';
    if position(anchor in d)=0 then raise exception 'Calculator count declaration changed.'; end if;
    d:=replace(d,anchor,anchor||E'\n  minimum_played integer;');
    anchor:='if status = ''completed'' and played < scheduled then';
    if position(anchor in d)=0 then raise exception 'Calculator completion validation changed.'; end if;
    d:=replace(d,anchor,'if status = ''completed'' and played <= 0 then');
    d:=replace(d,'A shortened session is not a normally completed match','A completed match requires positive verified playing time');
    anchor:='    counted := actual_seconds >= 600;';
    if position(anchor in d)=0 then raise exception 'Calculator player eligibility changed.'; end if;
    d:=replace(d,anchor,$new$
    -- Early completion changes ordinary participation only. Quits and cards
    -- keep their original ten-minute counting and negative-only safeguards.
    minimum_played := case when status = 'completed' and reason in ('NORMAL','EXCUSED')
      then least(600,played) else 600 end;
    counted := actual_seconds >= minimum_played;$new$);
    anchor:='elsif actual_seconds < 600 then';
    if position(anchor in d)=0 then raise exception 'Calculator ordinary participation branch changed.'; end if;
    d:=replace(d,anchor,'elsif actual_seconds < minimum_played then');
    anchor:='''games_after'', games_after, ''counted'', counted';
    if position(anchor in d)=0 then raise exception 'Calculator result projection changed.'; end if;
    d:=replace(d,anchor,anchor||', ''minimum_played_seconds'', minimum_played');
    execute d;

    d:=pg_get_functiondef(('fieldrush_rating_private.normalize_season_zero_sr_'||variant||'(jsonb)')::regprocedure);
    d:=replace(d,'FUNCTION fieldrush_rating_private.normalize_season_zero_sr_'||variant||'(',
      'FUNCTION fieldrush_rating_private.normalize_season_zero_sr_referee_ended_'||variant||'(');
    anchor:='  perform fieldrush_rating_private.calculate_season_zero_sr(core);';
    if position(anchor in d)=0 then raise exception 'Normalizer calculator validation changed.'; end if;
    d:=replace(d,anchor,E'  core := core || jsonb_build_object(''completion_rules_version'',''s0-referee-ended-v1'');\n'||anchor);
    execute d;
  end loop;
end $migration$;

create or replace function fieldrush_rating_private.calculate_season_zero_sr(data jsonb)
returns jsonb language plpgsql immutable parallel safe set search_path=pg_catalog as $$
declare version text:=coalesce(data->>'participation_rules_version','s0-standard-v1'); minimum integer;
  completion text:=coalesce(data->>'completion_rules_version','s0-full-duration-v1');
begin
  if data ? 'completion_rules_version' and jsonb_typeof(data->'completion_rules_version') is distinct from 'string'
    or completion not in ('s0-full-duration-v1','s0-referee-ended-v1') then
    raise exception 'Unknown completion rules version' using errcode='22023'; end if;
  if data ? 'participation_rules_version' and jsonb_typeof(data->'participation_rules_version') is distinct from 'string' then
    raise exception 'Participation rules version must be text' using errcode='22023'; end if;
  if version='s0-standard-v1' then
    if completion='s0-referee-ended-v1' then return fieldrush_rating_private.calculate_season_zero_sr_referee_ended_standard(data); end if;
    return fieldrush_rating_private.calculate_season_zero_sr_standard(data);
  end if;
  if version<>'s0-configurable-v1' then raise exception 'Unknown participation rules version' using errcode='22023'; end if;
  minimum:=fieldrush_rating_private.season_zero_sr_integer(data->'minimum_players','minimum_players',2);
  if minimum>14 then raise exception 'Minimum players cannot exceed 14' using errcode='22023'; end if;
  if completion='s0-referee-ended-v1' then return fieldrush_rating_private.calculate_season_zero_sr_referee_ended_configurable(data); end if;
  return fieldrush_rating_private.calculate_season_zero_sr_configurable(data);
end $$;

create or replace function fieldrush_rating_private.normalize_season_zero_sr(data jsonb)
returns jsonb language plpgsql immutable parallel safe set search_path=pg_catalog as $$
declare version text:=coalesce(data->>'participation_rules_version','s0-standard-v1'); minimum integer;
  completion text:=coalesce(data->>'completion_rules_version','s0-full-duration-v1');
begin
  if data ? 'completion_rules_version' and jsonb_typeof(data->'completion_rules_version') is distinct from 'string'
    or completion not in ('s0-full-duration-v1','s0-referee-ended-v1') then
    raise exception 'Unknown completion rules version' using errcode='22023'; end if;
  if data ? 'participation_rules_version' and jsonb_typeof(data->'participation_rules_version') is distinct from 'string' then
    raise exception 'Participation rules version must be text' using errcode='22023'; end if;
  if version='s0-standard-v1' then
    if completion='s0-referee-ended-v1' then return fieldrush_rating_private.normalize_season_zero_sr_referee_ended_standard(data); end if;
    return fieldrush_rating_private.normalize_season_zero_sr_standard(data);
  end if;
  if version<>'s0-configurable-v1' then raise exception 'Unknown participation rules version' using errcode='22023'; end if;
  minimum:=fieldrush_rating_private.season_zero_sr_integer(data->'minimum_players','minimum_players',2);
  if minimum>14 then raise exception 'Minimum players cannot exceed 14' using errcode='22023'; end if;
  if completion='s0-referee-ended-v1' then return fieldrush_rating_private.normalize_season_zero_sr_referee_ended_configurable(data); end if;
  return fieldrush_rating_private.normalize_season_zero_sr_configurable(data);
end $$;

-- Omit the historical default from inputs so old settlement snapshots and
-- calculations remain identical during unrelated chronological replay.
create or replace function fieldrush_rating_private.season_zero_input(game_to_use uuid,played_to_use integer default null)
returns jsonb language sql stable set search_path=public,fieldrush_rating_private,pg_temp as $$
  select jsonb_build_object('policy_id',policy_id,'status',rating_status,'winner',winner,
    'scheduled_seconds',scheduled_seconds,'played_seconds',coalesce(played_to_use,played_seconds),
    'roster',observed_roster,'events',events)
    || case when participation_rules_version='s0-configurable-v1' then
      jsonb_build_object('participation_rules_version',participation_rules_version,'minimum_players',minimum_players) else '{}'::jsonb end
    || case when completion_rules_version='s0-referee-ended-v1' then
      jsonb_build_object('completion_rules_version',completion_rules_version) else '{}'::jsonb end
  from fieldrush_rating_private.season_zero_matches where game_id=game_to_use;
$$;

do $migration$
declare d text; anchor text;
begin
  d:=pg_get_functiondef('public.referee_finish_season_zero_match(uuid,uuid,uuid,integer)'::regprocedure);
  anchor:=$old$finish_reason:=case when elapsed<state.scheduled_seconds then
    'Referee ended the match early. Result saved without SR or a counted appearance.' else 'Referee confirmed the completed result.' end;$old$;
  if position(anchor in d)=0 then raise exception 'Referee finish explanation changed.'; end if;
  d:=replace(d,anchor,$new$finish_reason:=case when elapsed=0 then
    'Referee ended the match without playing time. Result saved without SR or a counted appearance.'
    when elapsed<state.scheduled_seconds then 'Referee confirmed the early completed result. Rating uses the verified playing duration.'
    else 'Referee confirmed the completed result.' end;$new$);
  anchor:='rating_status=case when elapsed<scheduled_seconds then ''unranked'' else ''completed'' end,played_seconds=elapsed,';
  if position(anchor in d)=0 then raise exception 'Referee finish status changed.'; end if;
  d:=replace(d,anchor,'rating_status=case when elapsed=0 then ''unranked'' else ''completed'' end,played_seconds=elapsed,
    completion_rules_version=''s0-referee-ended-v1'',');
  execute d;

  -- Historical corrections remain explicit, authorized and fully audited.
  -- Omission preserves the pinned rule, including previously unrated games.
  d:=pg_get_functiondef('public.admin_resolve_season_zero_match(uuid,uuid,uuid,integer,jsonb)'::regprocedure);
  anchor:='''played_seconds'',''events'',''white_score'',''black_score''';
  if position(anchor in d)=0 then raise exception 'Organizer correction fields changed.'; end if;
  d:=replace(d,anchor,anchor||',''completion_rules_version''');
  anchor:='  corrected_events:=case when resolution_input ? ''events'' then resolution_input->''events'' else state.events end;';
  if position(anchor in d)=0 then raise exception 'Organizer correction timing changed.'; end if;
  d:=replace(d,anchor,$new$  if resolution_input ? 'completion_rules_version' and (
    resolution_input->>'completion_rules_version' is distinct from 's0-referee-ended-v1'
    or status_to_use<>'completed' or played<=0) then
    raise exception 'Completion rule opt-in requires a completed match with positive verified playing time.' using errcode='22023';
  end if;
$new$||anchor);
  anchor:='rating_status=status_to_use,winner=winner_to_use,played_seconds=played,events=corrected_events,';
  if position(anchor in d)=0 then raise exception 'Organizer correction update changed.'; end if;
  d:=replace(d,anchor,anchor||E'\n    completion_rules_version=coalesce(resolution_input->>''completion_rules_version'',state.completion_rules_version),');
  execute d;

  -- Describe the actual applied eligibility instead of promising ten minutes
  -- when a player completed the entire shorter match.
  d:=pg_get_functiondef('fieldrush_rating_private.public_player_match_rating_state(uuid,uuid,text)'::regprocedure);
  anchor:='counted boolean; played integer; explanation text;';
  if position(anchor in d)=0 then raise exception 'Public player rating declaration changed.'; end if;
  d:=replace(d,anchor,'counted boolean; played integer; explanation text; required_seconds integer;');
  anchor:='counted:=(award->>''counted'')::boolean; played:=(participation->>''actual_seconds'')::integer;';
  if position(anchor in d)=0 then raise exception 'Public player rating participation changed.'; end if;
  d:=replace(d,anchor,anchor||E'\n  required_seconds:=coalesce((award->>''minimum_played_seconds'')::integer,600);');
  anchor:=$old$    when not counted then format('No SR change: %s min %s sec played; 10 minutes are required. This appearance does not count.',played/60,played%60)$old$;
  if position(anchor in d)=0 then raise exception 'Public player rating explanation changed.'; end if;
  d:=replace(d,anchor,$new$    when not counted and required_seconds<600 then format('No SR change: %s min %s sec played; this shortened match requires %s min %s sec. This appearance does not count.',played/60,played%60,required_seconds/60,required_seconds%60)
$new$||anchor);
  anchor:=$old$    else 'This appearance counts: at least 10 playing minutes were verified.' end;$old$;
  if position(anchor in d)=0 then raise exception 'Public player counted explanation changed.'; end if;
  d:=replace(d,anchor,$new$    when required_seconds<600 then 'This appearance counts: the full recorded playing duration of this shortened match was verified.'
$new$||anchor);
  execute d;
end $migration$;

revoke all on function
  fieldrush_rating_private.calculate_season_zero_sr_referee_ended_standard(jsonb),
  fieldrush_rating_private.calculate_season_zero_sr_referee_ended_configurable(jsonb),
  fieldrush_rating_private.normalize_season_zero_sr_referee_ended_standard(jsonb),
  fieldrush_rating_private.normalize_season_zero_sr_referee_ended_configurable(jsonb)
from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
