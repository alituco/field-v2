-- Division 1 is strongest; Division 5 is the entry division. Existing games
-- remain unrestricted, and existing paid bookings are never removed.
alter table public.open_queue_games
  add column highest_division smallint not null default 1,
  add column lowest_division smallint not null default 5,
  add constraint open_queue_games_division_range_check check (
    highest_division between 1 and 5 and lowest_division between highest_division and 5
  );
alter table public.game_schedules
  add column highest_division smallint not null default 1,
  add column lowest_division smallint not null default 5,
  add constraint game_schedules_division_range_check check (
    highest_division between 1 and 5 and lowest_division between highest_division and 5
  );
grant select (highest_division, lowest_division) on public.open_queue_games to authenticated;

create function public.fieldrush_division_for_rating(rating_to_use integer)
returns integer language sql immutable set search_path = public, pg_temp as $$
  select case when rating_to_use >= 1650 then 1 when rating_to_use >= 1500 then 2
    when rating_to_use >= 1300 then 3 when rating_to_use >= 1100 then 4 else 5 end;
$$;
create function public.assert_open_queue_division_eligibility(player_id_to_check uuid, game_id_to_check uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare game public.open_queue_games%rowtype; rating integer; played integer; division integer;
begin
  select * into game from public.open_queue_games where id = game_id_to_check for share;
  if game.id is null then raise exception 'Game not found.'; end if;
  -- Attendance/history initialization after an admin cancellation must still
  -- work. Public booking/quote functions separately reject terminal games.
  if game.status not in ('OPEN', 'FULL', 'LIVE') then return; end if;
  select r.skill_rating, r.matches_played into rating, played
    from public.player_ratings r where r.profile_id = player_id_to_check;
  if coalesce(played, 0) < 2 then
    if game.highest_division <> 1 or game.lowest_division <> 5 then
      raise exception 'Placement players can only join DIV 1–5 games until their division is revealed.';
    end if;
    return;
  end if;
  division := public.fieldrush_division_for_rating(rating);
  if division < game.highest_division or division > game.lowest_division then
    raise exception 'This game is for DIV %–%. Your current division is %.', game.highest_division, game.lowest_division, division;
  end if;
end;
$$;
revoke all on function public.fieldrush_division_for_rating(integer),
  public.assert_open_queue_division_eligibility(uuid, uuid) from public, anon, authenticated;
grant execute on function public.fieldrush_division_for_rating(integer),
  public.assert_open_queue_division_eligibility(uuid, uuid) to service_role;

create function public.admin_create_open_queue_game(
  actor_admin_id uuid, field_id_to_use uuid, starts_at_to_use timestamptz,
  price_fils_to_use integer, age_label_to_use text, duration_minutes_to_use integer,
  highest_division_to_use integer, lowest_division_to_use integer
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare created_game public.open_queue_games%rowtype; age_text text := trim(coalesce(age_label_to_use,''));
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if field_id_to_use is null then raise exception 'Choose a saved field before creating the game.'; end if;
  if char_length(age_text) not between 2 and 40 then raise exception 'Age label must be between 2 and 40 characters.'; end if;
  if starts_at_to_use is null or starts_at_to_use <= now() then raise exception 'The solo game must be scheduled in the future.'; end if;
  if duration_minutes_to_use is null or duration_minutes_to_use not between 30 and 180 then
    raise exception 'Duration must be between 30 and 180 whole minutes.';
  end if;
  if price_fils_to_use is null or price_fils_to_use not between 0 and 100000 or price_fils_to_use % 10 <> 0 then
    raise exception 'Price must be between 0 and 100 USD, in whole cents.';
  end if;
  if highest_division_to_use is null or lowest_division_to_use is null
    or highest_division_to_use not between 1 and 5 or lowest_division_to_use not between highest_division_to_use and 5 then
    raise exception 'Choose a division range from 1 to 5, strongest division first.';
  end if;
  insert into public.open_queue_games(status,field_id,venue,starts_at,ends_at,timezone,price_fils,age_label,created_by,highest_division,lowest_division)
  values('OPEN',field_id_to_use,'Saved field',starts_at_to_use,starts_at_to_use+make_interval(mins=>duration_minutes_to_use),
    'America/Phoenix',price_fils_to_use,age_text,actor_admin_id,highest_division_to_use,lowest_division_to_use) returning * into created_game;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,'SOLO_GAME_CREATED','SOLO_MATCH',created_game.id,
    'Admin created a one-off solo game at a saved field.','{}',to_jsonb(created_game));
  return created_game.id;
end;
$$;
create or replace function public.admin_create_open_queue_game(
  actor_admin_id uuid, field_id_to_use uuid, starts_at_to_use timestamptz,
  price_fils_to_use integer, age_label_to_use text, duration_minutes_to_use integer
)
returns uuid language sql security definer set search_path = public, pg_temp as $$
  select public.admin_create_open_queue_game(actor_admin_id,field_id_to_use,starts_at_to_use,
    price_fils_to_use,age_label_to_use,duration_minutes_to_use,1,5);
$$;
revoke all on function public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer,integer,integer) from public,anon,authenticated;
grant execute on function public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer,integer,integer) to service_role;

-- Extend existing contracts in place, preserving every payment, reliability,
-- capacity, one-game and schedule idempotency check and their current ACLs.
do $migration$
declare definition text; anchor text;
begin
  definition := pg_get_functiondef('public.preview_open_queue_booking_cost(uuid,text)'::regprocedure);
  anchor := '  terms_to_use := public.ensure_match_reliability_terms(';
  if position(anchor in definition) = 0 then raise exception 'Solo quote policy contract changed.'; end if;
  execute replace(definition, anchor, E'  perform public.assert_open_queue_division_eligibility(user_id, game_to_book.id);\n' || anchor);
  definition := pg_get_functiondef('public.book_open_queue_game_server(uuid,text,text,text)'::regprocedure);
  if position(anchor in definition) = 0 then raise exception 'Solo booking policy contract changed.'; end if;
  execute replace(definition, anchor, E'  perform public.assert_open_queue_division_eligibility(user_id, game_id_to_book);\n' || anchor);
  definition := pg_get_functiondef('public.enforce_open_queue_booking_capacity()'::regprocedure);
  anchor := '    perform public.assert_player_has_one_game(new.profile_id,''SOLO'',new.game_id,new.payment_intent_id is null);';
  if position(anchor in definition) = 0 then raise exception 'Solo capacity registration contract changed.'; end if;
  execute replace(definition, anchor, anchor || E'\n    perform public.assert_open_queue_division_eligibility(new.profile_id, new.game_id);');

  definition := pg_get_functiondef('public.admin_save_game_schedule(uuid,uuid,jsonb)'::regprocedure);
  anchor := '''price_fils'',''age_label'',''is_active''';
  if position(anchor in definition) = 0 then raise exception 'Schedule value allowlist changed.'; end if;
  definition := replace(definition,anchor,'''price_fils'',''age_label'',''is_active'',''highest_division'',''lowest_division''');
  anchor := '''age_label'',''18+'',''is_active'',true';
  if position(anchor in definition) = 0 then raise exception 'Schedule defaults changed.'; end if;
  definition := replace(definition,anchor,'''age_label'',''18+'',''highest_division'',1,''lowest_division'',5,''is_active'',true');
  anchor := 'array[''duration_minutes'',''booking_window_days'',''price_fils'']';
  if position(anchor in definition) = 0 then raise exception 'Schedule number validation changed.'; end if;
  definition := replace(definition,anchor,'array[''duration_minutes'',''booking_window_days'',''price_fils'',''highest_division'',''lowest_division'']');
  anchor := 'booking_window_days,price_fils,age_label,is_active,created_by)';
  if position(anchor in definition) = 0 then raise exception 'Schedule insertion changed.'; end if;
  definition := replace(definition,anchor,'booking_window_days,price_fils,age_label,is_active,created_by,highest_division,lowest_division)');
  anchor := '(merged->>''is_active'')::boolean,actor_admin_id)';
  if position(anchor in definition) = 0 then raise exception 'Schedule insertion values changed.'; end if;
  definition := replace(definition,anchor,'(merged->>''is_active'')::boolean,actor_admin_id,(merged->>''highest_division'')::smallint,(merged->>''lowest_division'')::smallint)');
  anchor := 'age_label=trim(merged->>''age_label''),is_active=(merged->>''is_active'')::boolean';
  if position(anchor in definition) = 0 then raise exception 'Schedule update values changed.'; end if;
  definition := replace(definition,anchor,anchor || ',highest_division=(merged->>''highest_division'')::smallint,lowest_division=(merged->>''lowest_division'')::smallint');
  anchor := '''booking_window_days'',''price_fils'',''age_label'']';
  if position(anchor in definition) = 0 then raise exception 'Schedule retry keys changed.'; end if;
  definition := replace(definition,anchor,'''booking_window_days'',''price_fils'',''age_label'',''highest_division'',''lowest_division'']');
  execute definition;

  definition := pg_get_functiondef('fieldrush_private.generate_game_schedule(uuid)'::regprocedure);
  anchor := 'timezone,price_fils,age_label,created_by)';
  if position(anchor in definition) = 0 then raise exception 'Schedule game insertion changed.'; end if;
  definition := replace(definition,anchor,'timezone,price_fils,age_label,created_by,highest_division,lowest_division)');
  anchor := 's.timezone,s.price_fils,s.age_label,s.created_by)';
  if position(anchor in definition) = 0 then raise exception 'Schedule game values changed.'; end if;
  execute replace(definition,anchor,'s.timezone,s.price_fils,s.age_label,s.created_by,s.highest_division,s.lowest_division)');
end;
$migration$;
notify pgrst, 'reload schema';
