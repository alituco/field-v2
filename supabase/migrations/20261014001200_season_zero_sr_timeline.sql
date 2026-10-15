-- Pure, private normalization for a SERVER-VERIFIED Season 0 roster and clock.
-- No tables, policy activation, settlement, or changes to historical ratings.
-- Event array order is the authoritative server sequence. Clock seconds already
-- exclude pauses; recorded_at is an authoritative ISO-8601 wall timestamp.

create function fieldrush_rating_private.season_zero_sr_interval(
  states jsonb, starts integer, ends integer, running boolean
)
returns jsonb language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
declare
  entry record;
  player jsonb;
  side text;
  seconds integer := ends - starts;
  actual_a integer := 0;
  actual_b integer := 0;
  accounting_a integer := 0;
  accounting_b integer := 0;
  active_ids jsonb := '[]'::jsonb;
  retained_ids jsonb := '[]'::jsonb;
  protected boolean;
begin
  if starts is null or ends is null or starts < 0 or seconds <= 0 or running is distinct from true then
    raise exception 'Positive playing intervals require an advancing, running clock' using errcode = '22023';
  end if;
  for entry in select key, value from jsonb_each(states) loop
    player := entry.value;
    side := player->>'team';
    if (player->>'active')::boolean and (player->>'retained')::boolean then
      raise exception 'A player cannot be active and retained together' using errcode = '22023';
    end if;
    if (player->>'active')::boolean then
      active_ids := active_ids || jsonb_build_array(entry.key);
      if side = 'A' then actual_a := actual_a + 1; else actual_b := actual_b + 1; end if;
    end if;
    if (player->>'retained')::boolean then retained_ids := retained_ids || jsonb_build_array(entry.key); end if;
    if (player->>'active')::boolean or (player->>'retained')::boolean then
      if side = 'A' then accounting_a := accounting_a + 1; else accounting_b := accounting_b + 1; end if;
    end if;
  end loop;
  if actual_a not between 5 and 7 or actual_b not between 5 and 7
      or accounting_a not between actual_a and 7 or accounting_b not between actual_b and 7 then
    raise exception 'Running play requires five to seven actual players per side' using errcode = '22023';
  end if;

  for entry in select key, value from jsonb_each(states) loop
    player := entry.value;
    side := player->>'team';
    if (player->>'active')::boolean then
      protected := case when side = 'A' then actual_a < actual_b and accounting_a < accounting_b
        else actual_b < actual_a and accounting_b < accounting_a end;
      player := player || jsonb_build_object(
        'actual_seconds', (player->>'actual_seconds')::integer + seconds,
        'protected_seconds', (player->>'protected_seconds')::integer + case when protected then seconds else 0 end
      );
    elsif (player->>'retained')::boolean then
      player := player || jsonb_build_object('retained_seconds', (player->>'retained_seconds')::integer + seconds);
    end if;
    states := jsonb_set(states, array[entry.key], player);
  end loop;
  return jsonb_build_object(
    'states', states,
    'manpower_seconds', seconds::numeric * (accounting_a - accounting_b),
    'interval', jsonb_build_object(
      'start', starts, 'end', ends, 'seconds', seconds,
      'actual', jsonb_build_object('A', actual_a, 'B', actual_b),
      'accounting', jsonb_build_object('A', accounting_a, 'B', accounting_b),
      'active_ids', active_ids, 'retained_ids', retained_ids
    )
  );
end;
$$;

create function fieldrush_rating_private.normalize_season_zero_sr(data jsonb)
returns jsonb language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
declare
  scheduled integer;
  played integer;
  roster jsonb;
  events jsonb;
  player jsonb;
  player_id text;
  team text;
  sr integer;
  games integer;
  states jsonb := '{}'::jsonb;
  assigned_a integer := 0;
  assigned_b integer := 0;
  event jsonb;
  event_id text;
  event_ids text[] := array[]::text[];
  event_type text;
  event_index integer;
  event_second integer;
  event_wall_text text;
  event_wall timestamptz;
  last_event_wall timestamptz;
  blue_wall timestamptz;
  cursor_second integer := 0;
  running boolean := true;
  state text;
  history text;
  interval_result jsonb;
  intervals jsonb := '[]'::jsonb;
  manpower_seconds numeric := 0;
  weight numeric;
  weight_a numeric := 0;
  weight_b numeric := 0;
  total_a numeric := 0;
  total_b numeric := 0;
  core_players jsonb := '[]'::jsonb;
  audit_players jsonb := '{}'::jsonb;
  core jsonb;
  rated boolean;
begin
  if jsonb_typeof(data) is distinct from 'object'
      or data->>'policy_id' is distinct from 'field-sr-season0-v2' then
    raise exception 'Unsupported policy_id or input object' using errcode = '22023';
  end if;
  if not data ? 'winner' then
    raise exception 'winner must be explicit (null for a draw)' using errcode = '22023';
  end if;
  scheduled := fieldrush_rating_private.season_zero_sr_integer(data->'scheduled_seconds', 'scheduled_seconds', 600);
  played := fieldrush_rating_private.season_zero_sr_integer(data->'played_seconds', 'played_seconds', 0);
  roster := data->'roster';
  events := data->'events';
  if jsonb_typeof(roster) is distinct from 'array' or jsonb_typeof(events) is distinct from 'array' then
    raise exception 'roster and events must be arrays' using errcode = '22023';
  end if;
  for player in select value from jsonb_array_elements(roster) loop
    player_id := player->>'id';
    team := player->>'team';
    if jsonb_typeof(player) is distinct from 'object' or jsonb_typeof(player->'id') is distinct from 'string'
        or player_id = '' or states ? player_id then
      raise exception 'Roster player IDs must be nonempty and unique across both teams' using errcode = '22023';
    end if;
    if team is null or team not in ('A', 'B') then
      raise exception 'Final team must be A or B' using errcode = '22023';
    end if;
    if jsonb_typeof(player->'initial_active') is distinct from 'boolean' then
      raise exception 'initial_active must be an explicit boolean' using errcode = '22023';
    end if;
    sr := fieldrush_rating_private.season_zero_sr_integer(player->'sr_before', 'sr_before');
    games := fieldrush_rating_private.season_zero_sr_integer(player->'games_before', 'games_before', 0);
    if team = 'A' then assigned_a := assigned_a + 1; else assigned_b := assigned_b + 1; end if;
    states := states || jsonb_build_object(player_id, jsonb_build_object(
      'id', player_id, 'team', team, 'sr_before', sr, 'games_before', games,
      'active', player->'initial_active', 'retained', false,
      'state', case when (player->>'initial_active')::boolean then 'ACTIVE' else 'NOT_ENTERED' end,
      'history', 'NORMAL', 'blue_card_at', null,
      'actual_seconds', 0, 'retained_seconds', 0, 'protected_seconds', 0
    ));
  end loop;
  if assigned_a > 7 or assigned_b > 7 then
    raise exception 'Final booked roster cannot exceed seven players per side' using errcode = '22023';
  end if;

  -- The final synthetic iteration closes [last_event, played). No synthetic
  -- event is recorded. Same-clock real events retain authoritative array order
  -- but no intermediate headcount is treated as a positive playing interval.
  for event_index in 0..jsonb_array_length(events) loop
    if event_index = jsonb_array_length(events) then
      event_second := played;
    else
      event := events->event_index;
      event_id := event->>'id';
      event_type := event->>'type';
      if jsonb_typeof(event) is distinct from 'object' or jsonb_typeof(event->'id') is distinct from 'string'
          or event_id = '' or event_id = any(event_ids) then
        raise exception 'Event IDs must be nonempty and unique' using errcode = '22023';
      end if;
      event_ids := array_append(event_ids, event_id);
      event_second := fieldrush_rating_private.season_zero_sr_integer(event->'second', 'event.second', 0);
      if event_second < cursor_second or event_second > played then
        raise exception 'Events must follow server sequence within the played clock' using errcode = '22023';
      end if;
      event_wall_text := event->>'recorded_at';
      if jsonb_typeof(event->'recorded_at') is distinct from 'string' or event_wall_text !~
          '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$' then
        raise exception 'recorded_at requires an explicit ISO-8601 wall timestamp with timezone' using errcode = '22023';
      end if;
      begin
        event_wall := event_wall_text::timestamptz;
      exception when datetime_field_overflow or invalid_datetime_format then
        raise exception 'Invalid event wall timestamp' using errcode = '22023';
      end;
      if last_event_wall is not null and event_wall < last_event_wall then
        raise exception 'Event wall timestamps must follow server sequence' using errcode = '22023';
      end if;
      last_event_wall := event_wall;
    end if;

    if event_second > cursor_second then
      interval_result := fieldrush_rating_private.season_zero_sr_interval(states, cursor_second, event_second, running);
      states := interval_result->'states';
      intervals := intervals || jsonb_build_array(interval_result->'interval');
      manpower_seconds := manpower_seconds + (interval_result->>'manpower_seconds')::numeric;
      cursor_second := event_second;
    end if;
    exit when event_index = jsonb_array_length(events);

    if event_type in ('PAUSE', 'RESUME') then
      if event->>'player_id' is not null then
        raise exception 'Clock actions cannot target a player' using errcode = '22023';
      end if;
      if event_type = 'PAUSE' then
        if not running then raise exception 'Cannot pause an already paused clock' using errcode = '22023'; end if;
        running := false;
      else
        if running then raise exception 'Cannot resume an already running clock' using errcode = '22023'; end if;
        running := true;
      end if;
      continue;
    end if;
    if event_type is null or event_type not in ('JOIN', 'EXCUSED_LEAVE', 'RETURN', 'QUIT', 'RED_CARD', 'BLUE_CARD', 'BLUE_RETURN') then
      raise exception 'Unknown or unadjudicated event type; team transfers are locked after kickoff' using errcode = '22023';
    end if;
    player_id := event->>'player_id';
    if jsonb_typeof(event->'player_id') is distinct from 'string' or not states ? player_id then
      raise exception 'Only an originally booked player may participate' using errcode = '22023';
    end if;
    -- A supplied team/assignment change cannot override the frozen roster.
    if event ? 'team' and event->>'team' is distinct from states->player_id->>'team' then
      raise exception 'Player team changes after kickoff require review' using errcode = '22023';
    end if;
    player := states->player_id;
    state := player->>'state';
    history := player->>'history';

    if event_type = 'JOIN' then
      if state <> 'NOT_ENTERED' then raise exception 'JOIN requires a never-entered booked player' using errcode = '22023'; end if;
      player := player || jsonb_build_object('state', 'ACTIVE', 'active', true);
    elsif event_type = 'EXCUSED_LEAVE' then
      if state <> 'ACTIVE' then raise exception 'Excused leave requires an active player' using errcode = '22023'; end if;
      player := player || jsonb_build_object('state', 'EXCUSED', 'active', false,
        'history', case when history = 'NORMAL' then 'EXCUSED' else history end);
    elsif event_type = 'RETURN' then
      if state <> 'EXCUSED' then raise exception 'Ordinary RETURN only ends that player''s excused absence' using errcode = '22023'; end if;
      player := player || jsonb_build_object('state', 'ACTIVE', 'active', true);
    elsif event_type in ('QUIT', 'RED_CARD', 'BLUE_CARD') then
      if state <> 'ACTIVE' and not (event_type = 'RED_CARD' and state = 'NOT_ENTERED') then
        raise exception 'Conduct departure requires active presence (except a pre-entry red card)' using errcode = '22023';
      end if;
      player := player || jsonb_build_object(
        'state', event_type, 'history', event_type, 'active', false,
        'retained', (player->>'actual_seconds')::integer > 0,
        'blue_card_at', case when event_type = 'BLUE_CARD' then event_wall_text else null end
      );
    elsif event_type = 'BLUE_RETURN' then
      if state <> 'BLUE_CARD' then raise exception 'BLUE_RETURN requires an active temporary dismissal' using errcode = '22023'; end if;
      blue_wall := (player->>'blue_card_at')::timestamptz;
      if event_wall < blue_wall + interval '120 seconds' then
        raise exception 'Blue-card return requires 120 wall seconds and referee confirmation' using errcode = '22023';
      end if;
      player := player || jsonb_build_object('state', 'ACTIVE', 'active', true, 'retained', false, 'blue_card_at', null);
    end if;
    states := jsonb_set(states, array[player_id], player);
  end loop;

  for player in select value from jsonb_array_elements(roster) loop
    player_id := player->>'id';
    player := states->player_id;
    weight := (player->>'actual_seconds')::numeric + (player->>'retained_seconds')::numeric;
    if player->>'team' = 'A' then
      weight_a := weight_a + weight;
      total_a := total_a + (player->>'sr_before')::numeric * weight;
    else
      weight_b := weight_b + weight;
      total_b := total_b + (player->>'sr_before')::numeric * weight;
    end if;
    core_players := core_players || jsonb_build_array(jsonb_build_object(
      'id', player_id, 'team', player->'team', 'sr_before', player->'sr_before', 'games_before', player->'games_before',
      'actual_seconds', player->'actual_seconds', 'protected_seconds', player->'protected_seconds', 'exit_reason', player->'history'
    ));
    audit_players := audit_players || jsonb_build_object(player_id, jsonb_build_object(
      'actual_seconds', player->'actual_seconds', 'retained_seconds', player->'retained_seconds',
      'rating_weight', weight, 'protected_seconds', player->'protected_seconds',
      'final_state', player->'state', 'exit_reason', player->'history'
    ));
  end loop;
  rated := data->>'status' = 'completed' or (data->>'status' = 'forfeit_confirmed' and played >= 600);
  if rated and (weight_a = 0 or weight_b = 0) then
    raise exception 'A rated match requires verified contribution weight on both sides' using errcode = '22023';
  end if;
  core := jsonb_build_object(
    'policy_id', data->'policy_id', 'status', data->'status', 'winner', data->'winner',
    'scheduled_seconds', scheduled, 'played_seconds', played,
    'team_strengths', jsonb_build_object('A', case when weight_a > 0 then total_a / weight_a else 0 end,
      'B', case when weight_b > 0 then total_b / weight_b else 0 end),
    'average_count_difference_a', case when played > 0 then manpower_seconds / played else 0 end,
    'players', core_players
  );
  -- Reuse the calculator's complete normalized-input validation. This does not
  -- settle or expose anything; the result is discarded, including HELD output.
  perform fieldrush_rating_private.calculate_season_zero_sr(core);
  return jsonb_build_object('core', core, 'audit', jsonb_build_object(
    'intervals', intervals, 'players', audit_players,
    'assigned_players', jsonb_build_object('A', assigned_a, 'B', assigned_b),
    'team_rating_weights', jsonb_build_object('A', weight_a, 'B', weight_b),
    'weighted_sr_totals', jsonb_build_object('A', total_a, 'B', total_b),
    'manpower_seconds_a', manpower_seconds,
    'final_clock_state', case when running then 'RUNNING' else 'PAUSED' end,
    'events_count', jsonb_array_length(events), 'played_seconds', played
  ));
end;
$$;

revoke all on function fieldrush_rating_private.season_zero_sr_interval(jsonb,integer,integer,boolean),
  fieldrush_rating_private.normalize_season_zero_sr(jsonb)
from public, anon, authenticated, service_role;
