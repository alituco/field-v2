-- Open-spot alerts are optional, city/role/division targeted, and generated in
-- bounded batches OUTSIDE the booking cancellation's locked transaction.
alter table public.profile_settings add column open_spots boolean not null default false;
alter table public.profile_settings add column open_spots_enabled_at timestamptz;
create function fieldrush_private.record_open_spots_opt_in()
returns trigger language plpgsql set search_path=pg_catalog,pg_temp as $$
begin
  if new.open_spots and (tg_op='INSERT' or not old.open_spots) then
    new.open_spots_enabled_at:=clock_timestamp();
  elsif not new.open_spots then new.open_spots_enabled_at:=null;
  else new.open_spots_enabled_at:=old.open_spots_enabled_at; end if;
  return new;
end;
$$;
revoke all on function fieldrush_private.record_open_spots_opt_in() from public,anon,authenticated,service_role;
create trigger record_open_spots_opt_in before insert or update on public.profile_settings
  for each row execute function fieldrush_private.record_open_spots_opt_in();

alter function public.get_my_profile_settings() rename to get_my_profile_settings_before_open_spots;
revoke all on function public.get_my_profile_settings_before_open_spots() from public,anon,authenticated,service_role;
create function public.get_my_profile_settings()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,auth,pg_temp as $$
declare result jsonb;
begin
  result:=public.get_my_profile_settings_before_open_spots();
  return jsonb_set(result,'{notifications,open_spots}',to_jsonb(coalesce(
    (select open_spots from public.profile_settings where profile_id=auth.uid()),false)));
end;
$$;
revoke all on function public.get_my_profile_settings() from public,anon;
grant execute on function public.get_my_profile_settings() to authenticated;

alter function public.update_my_notification_preferences(jsonb) rename to update_my_notification_preferences_before_open_spots;
revoke all on function public.update_my_notification_preferences_before_open_spots(jsonb) from public,anon,authenticated,service_role;
create function public.update_my_notification_preferences(preferences_to_use jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,auth,pg_temp as $$
begin
  if preferences_to_use?'open_spots' and jsonb_typeof(preferences_to_use->'open_spots') is distinct from 'boolean' then
    raise exception 'Open-spot alerts must be a boolean.' using errcode='22023';
  end if;
  -- Old mobile clients can still save their original six preferences without
  -- accidentally opting in or overwriting this separately chosen preference.
  perform public.update_my_notification_preferences_before_open_spots(preferences_to_use-'open_spots');
  if preferences_to_use?'open_spots' then
    update public.profile_settings set open_spots=(preferences_to_use->>'open_spots')::boolean where profile_id=auth.uid();
  end if;
  return public.get_my_profile_settings();
end;
$$;
revoke all on function public.update_my_notification_preferences(jsonb) from public,anon;
grant execute on function public.update_my_notification_preferences(jsonb) to authenticated;

alter function fieldrush_private.notification_preference_allows(uuid,text) rename to notification_preference_allows_before_open_spots;
create function fieldrush_private.notification_preference_allows(recipient_id uuid,notification_type text)
returns boolean language sql stable security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  select case when notification_type='OPEN_QUEUE_REPLACEMENT_AVAILABLE' then
    coalesce((select open_spots from public.profile_settings where profile_id=recipient_id),false)
  else fieldrush_private.notification_preference_allows_before_open_spots(recipient_id,notification_type) end;
$$;
revoke all on function fieldrush_private.notification_preference_allows(uuid,text),
  fieldrush_private.notification_preference_allows_before_open_spots(uuid,text) from public,anon,authenticated,service_role;

create table fieldrush_private.replacement_notification_jobs(
  source_booking_id uuid primary key references public.open_queue_bookings(id) on delete cascade,
  game_id uuid not null references public.open_queue_games(id) on delete cascade,
  recipient_cursor uuid,
  completed_at timestamptz,
  created_at timestamptz not null default clock_timestamp()
);
alter table fieldrush_private.replacement_notification_jobs enable row level security;
revoke all on fieldrush_private.replacement_notification_jobs from public,anon,authenticated,service_role;
create index replacement_notification_jobs_pending on fieldrush_private.replacement_notification_jobs(created_at)
  where completed_at is null;
create index accounts_replacement_city_recipients on fieldrush_private.accounts(preferred_city_id,user_id) where status='active';

create function fieldrush_private.replacement_recipient_eligible(recipient uuid,game_to_use uuid,source_to_use uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  select exists(
    select 1 from public.open_queue_games g
    join public.fieldrush_cities city on city.id=g.market_city_id and city.active
    join fieldrush_private.accounts a on a.user_id=recipient and a.preferred_city_id=city.id and a.status='active'
    join public.profile_settings settings on settings.profile_id=recipient and settings.open_spots
    join public.open_queue_bookings source on source.id=source_to_use and source.game_id=g.id
      and source.profile_id<>recipient and source.status='CANCELLED'
    left join public.fieldrush_player_rating_tracks track on track.profile_id=recipient
      and track.rating_track=public.fieldrush_rating_track(g.replacement_discount_role)
    where g.id=game_to_use and g.status='OPEN' and g.operational_state='NORMAL' and g.currency='USD'
      and g.starts_at>clock_timestamp() and g.replacement_offer_expires_at>clock_timestamp()
      and g.replacement_source_booking_id=source_to_use and g.replacement_discount_role=source.role
      and public.is_fieldrush_account_active(recipient)
      and not public.profile_has_active_play_restriction(recipient)
      and not public.profile_has_active_reliability_booking_restriction(recipient)
      and case when coalesce(track.matches_played,0)<2 then g.highest_division=1 and g.lowest_division=5
        else public.fieldrush_division_for_rating(track.skill_rating) between g.highest_division and g.lowest_division end
      and (select count(*) from public.open_queue_bookings b where b.game_id=g.id and b.status='CONFIRMED'
        and b.role=g.replacement_discount_role)<case g.replacement_discount_role
          when 'GK' then g.goalkeeper_capacity when 'DEF' then g.defender_capacity
          when 'MID' then g.midfielder_capacity when 'ATT' then g.attacker_capacity else 0 end
      -- Mirror the one-upcoming-game TOTAL guard, not just time overlap. Use
      -- its read-only predicate/current attendance, never its advisory locks.
      and not exists(select 1 from public.open_queue_bookings b join public.open_queue_games other on other.id=b.game_id
        where b.profile_id=recipient and b.status='CONFIRMED' and (b.game_id=g.id or
          (public.player_game_blocks_registration(other.status,other.ends_at,other.operational_state)
            and not exists(select 1 from public.current_match_attendance_records attendance
              where attendance.match_kind='SOLO' and attendance.open_queue_game_id=other.id
                and attendance.profile_id=b.profile_id and attendance.booking_id=b.id
                and attendance.outcome in ('NO_SHOW','EXCUSED','FIELD_CANCELLED','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE')))))
      and not exists(select 1 from public.fixture_reliability_roster_history roster join public.fixtures f on f.id=roster.fixture_id
        where roster.profile_id=recipient and roster.status='CONFIRMED'
          and public.player_game_blocks_registration(f.status,public.fixture_end_at(f.match_date,f.time_slot),f.operational_state)
          and not exists(select 1 from public.current_match_attendance_records attendance where attendance.match_kind='CLAN'
            and attendance.fixture_id=f.id and attendance.profile_id=recipient
            and attendance.outcome in ('NO_SHOW','EXCUSED','FIELD_CANCELLED','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE')))
      and not exists(select 1 from public.match_reserve_assignments reserve
        left join public.open_queue_games other on other.id=reserve.open_queue_game_id
        left join public.fixtures f on f.id=reserve.fixture_id
        where reserve.profile_id=recipient and reserve.status='ACTIVE'
          and public.player_game_blocks_registration(coalesce(other.status,f.status),
            coalesce(other.ends_at,public.fixture_end_at(f.match_date,f.time_slot)),coalesce(other.operational_state,f.operational_state))
          and not exists(select 1 from public.current_match_attendance_records attendance
            where attendance.match_kind=reserve.match_kind and attendance.profile_id=recipient
              and coalesce(attendance.open_queue_game_id,attendance.fixture_id)=coalesce(reserve.open_queue_game_id,reserve.fixture_id)
              and attendance.outcome in ('NO_SHOW','EXCUSED','FIELD_CANCELLED','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE')))
      and not exists(select 1 from public.payment_intents p where p.profile_id=recipient and p.status in ('PENDING','CAPTURED'))
  );
$$;
revoke all on function fieldrush_private.replacement_recipient_eligible(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create function fieldrush_private.enqueue_replacement_offer(game_to_use uuid,source_to_use uuid)
returns void language sql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  insert into fieldrush_private.replacement_notification_jobs(source_booking_id,game_id)
  select source_to_use,g.id from public.open_queue_games g
  where g.id=game_to_use and g.replacement_source_booking_id=source_to_use
    and g.replacement_offer_expires_at>clock_timestamp() and g.starts_at>clock_timestamp()
  on conflict(source_booking_id) do nothing;
$$;
revoke all on function fieldrush_private.enqueue_replacement_offer(uuid,uuid) from public,anon,authenticated,service_role;

-- Fail migration rather than silently retaining a broad, profile-wide fanout
-- if an earlier policy wrapper ever changes its canonical body.
do $migration$
declare definition text; original text:=$old$      insert into public.notifications (
        recipient_profile_id,
        type,
        title,
        body,
        related_entity_type,
        related_entity_id,
        data
      )
      select
        profile.id,
        'OPEN_QUEUE_REPLACEMENT_AVAILABLE',
        case
          when (late_rule ->> 'discountBps')::integer > 0
            then 'A discounted solo spot just opened'
          else 'A solo spot just opened'
        end,
        booking_to_cancel.role || ' at ' || game_to_reopen.venue ||
          case
            when (late_rule ->> 'discountBps')::integer > 0
              then ' is now ' ||
                round((late_rule ->> 'discountBps')::integer / 100.0)::integer ||
                '% off.'
            else ' is available now.'
          end,
        'OPEN_QUEUE_GAME',
        game_to_reopen.id,
        jsonb_build_object(
          'game_id', game_to_reopen.id,
          'role', booking_to_cancel.role,
          'discount_bps', (late_rule ->> 'discountBps')::integer,
          'expires_at', offer_expiry
        )
      from public.profiles profile
      where profile.id <> user_id
        and not public.profile_has_active_play_restriction(profile.id)
        and not public.profile_has_active_reliability_booking_restriction(profile.id)
        and not exists (
          select 1
          from public.open_queue_bookings existing
          where existing.game_id = game_to_reopen.id
            and existing.profile_id = profile.id
            and existing.status = 'CONFIRMED'
        );$old$;
begin
  definition:=pg_get_functiondef('public.cancel_open_queue_booking_policy(uuid)'::regprocedure);
  if length(definition)-length(replace(definition,original,''))<>length(original) then
    raise exception 'Expected exactly one legacy replacement fanout block.';
  end if;
  execute replace(definition,original,'      perform fieldrush_private.enqueue_replacement_offer(game_to_reopen.id,booking_to_cancel.id);');
end;
$migration$;

create function fieldrush_private.process_replacement_notifications()
returns integer language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare job record; game public.open_queue_games%rowtype; candidate record; last_recipient uuid; scanned integer;
  emitted integer:=0; saved_id uuid; receipt_created boolean;
begin
  if not pg_try_advisory_xact_lock(hashtextextended('fieldrush-replacement-notifications',0)) then return 0; end if;
  -- At most 4 jobs x 100 city opt-ins per transaction. A cancellation only
  -- enqueues one row; it never loops over the player base under the game lock.
  for job in select * from fieldrush_private.replacement_notification_jobs where completed_at is null
    order by created_at,source_booking_id limit 4 for update skip locked
  loop
    select * into game from public.open_queue_games where id=job.game_id;
    if game.id is null or game.replacement_source_booking_id is distinct from job.source_booking_id
      or game.status<>'OPEN' or game.starts_at<=clock_timestamp()
      or game.replacement_offer_expires_at is null or game.replacement_offer_expires_at<=clock_timestamp() then
      update fieldrush_private.replacement_notification_jobs set completed_at=clock_timestamp() where source_booking_id=job.source_booking_id;
      continue;
    end if;
    scanned:=0; last_recipient:=job.recipient_cursor;
    for candidate in select a.user_id from fieldrush_private.accounts a
      join public.profile_settings settings on settings.profile_id=a.user_id and settings.open_spots
      where a.status='active' and a.preferred_city_id=game.market_city_id
        and (job.recipient_cursor is null or a.user_id>job.recipient_cursor)
        -- New opt-ins after the cancellation do not receive a stale backlog.
        and settings.open_spots_enabled_at<=job.created_at
      order by a.user_id limit 100
    loop
      scanned:=scanned+1; last_recipient:=candidate.user_id;
      if not fieldrush_private.replacement_recipient_eligible(candidate.user_id,game.id,job.source_booking_id) then continue; end if;
      insert into fieldrush_private.notification_event_receipts(recipient_id,notification_type,event_key)
      values(candidate.user_id,'OPEN_QUEUE_REPLACEMENT_AVAILABLE','replacement:'||job.source_booking_id::text)
      on conflict do nothing returning true into receipt_created;
      if receipt_created is distinct from true then continue; end if;
      insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id,data)
      values(candidate.user_id,'OPEN_QUEUE_REPLACEMENT_AVAILABLE',
        case when game.replacement_discount_bps>0 then 'A discounted solo spot just opened' else 'A solo spot just opened' end,
        'A spot in your city is available. Open the game to check its position and price.',
        'OPEN_QUEUE_GAME',game.id,jsonb_build_object('game_id',game.id,'role',game.replacement_discount_role,
          'source_booking_id',job.source_booking_id,'discount_bps',game.replacement_discount_bps,
          'expires_at',game.replacement_offer_expires_at,'fieldrush_event_key','replacement:'||job.source_booking_id::text))
      returning id into saved_id;
      update fieldrush_private.notification_event_receipts set notification_id=saved_id
        where recipient_id=candidate.user_id and notification_type='OPEN_QUEUE_REPLACEMENT_AVAILABLE'
          and event_key='replacement:'||job.source_booking_id::text;
      if saved_id is not null then emitted:=emitted+1; end if;
    end loop;
    update fieldrush_private.replacement_notification_jobs set recipient_cursor=last_recipient,
      completed_at=case when scanned<100 then clock_timestamp() else null end where source_booking_id=job.source_booking_id;
  end loop;
  update public.notifications n set resolved_at=clock_timestamp()
    where n.type='OPEN_QUEUE_REPLACEMENT_AVAILABLE' and n.resolved_at is null
      and not fieldrush_private.notification_source_is_current(n.id);
  return emitted;
end;
$$;
revoke all on function fieldrush_private.process_replacement_notifications() from public,anon,authenticated,service_role;

alter function fieldrush_private.notification_source_is_current(uuid) rename to notification_source_is_current_before_open_spots;
create function fieldrush_private.notification_source_is_current(notification_id_to_use uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  select coalesce((select case when n.type='OPEN_QUEUE_REPLACEMENT_AVAILABLE' then
    -- Join on canonical UUID text, not an unchecked cast of arbitrary JSON.
    exists(select 1 from public.open_queue_games g where g.id=n.related_entity_id
      and n.related_entity_type='OPEN_QUEUE_GAME' and g.replacement_source_booking_id::text=n.data->>'source_booking_id'
      and g.replacement_discount_role=n.data->>'role' and g.replacement_discount_bps::text=n.data->>'discount_bps'
      and exists(select 1 from fieldrush_private.replacement_notification_jobs job
        join public.profile_settings settings on settings.profile_id=n.recipient_profile_id
        where job.source_booking_id=g.replacement_source_booking_id and job.game_id=g.id
          and settings.open_spots and settings.open_spots_enabled_at<=job.created_at)
      and fieldrush_private.replacement_recipient_eligible(n.recipient_profile_id,g.id,g.replacement_source_booking_id))
    else fieldrush_private.notification_source_is_current_before_open_spots(n.id) end
    from public.notifications n where n.id=notification_id_to_use),false);
$$;
revoke all on function fieldrush_private.notification_source_is_current(uuid),
  fieldrush_private.notification_source_is_current_before_open_spots(uuid) from public,anon,authenticated,service_role;

-- Dedicated minute sweep: urgent replacement alerts do not wait for the
-- five-minute reminder/ranking job. Phone-push dispatch already runs minutely.
select cron.schedule('fieldrush-replacement-notifications','* * * * *','select fieldrush_private.process_replacement_notifications();');
notify pgrst,'reload schema';
