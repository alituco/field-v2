-- Recipient-owned player notices from committed solo match state. A deferred
-- observer sees the final transaction (including attendance, refunds and SR),
-- never each intermediate team/score update inside a referee operation.
create table fieldrush_private.player_game_notice_state (
  game_id uuid primary key references public.open_queue_games(id) on delete cascade,
  snapshot jsonb not null,
  revision bigint not null default 0,
  review_epoch bigint not null default 0,
  result_epochs jsonb not null default '{}',
  observed_at timestamptz not null default clock_timestamp()
);
create table fieldrush_private.player_game_notice_activation (
  singleton boolean primary key default true check(singleton),
  activated_at timestamptz not null default clock_timestamp()
);
insert into fieldrush_private.player_game_notice_activation(singleton) values(true);
alter table fieldrush_private.player_game_notice_state enable row level security;
alter table fieldrush_private.player_game_notice_activation enable row level security;
revoke all on fieldrush_private.player_game_notice_state,
  fieldrush_private.player_game_notice_activation from public,anon,authenticated,service_role;

create function fieldrush_private.player_game_notice_snapshot(game_to_use uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  select jsonb_build_object('game',jsonb_build_object(
    'status',g.status,'starts_at',g.starts_at,'ends_at',g.ends_at,'timezone',g.timezone,
    'venue',g.venue,'field_id',g.field_id,'address',g.location_address,
    'assigned',g.teams_assigned_at is not null,'actual_started_at',g.actual_started_at,
    'operational_state',g.operational_state,'operational_state_updated_at',g.operational_state_updated_at,
    'white_score',g.white_score,'black_score',g.black_score,
    'resolution_revision',coalesce((select max(c.current_revision) from public.match_resolution_cases c
      where c.match_kind='SOLO' and c.open_queue_game_id=g.id),0),
    'check_in_at',t.arrival_check_in_opens_at,'deadline_at',t.arrival_check_in_deadline_at),
    'bookings',coalesce((select jsonb_object_agg(b.id::text,jsonb_build_object(
      'profile_id',b.profile_id,'status',b.status,'team',b.team,'booked_at',b.booked_at,
      'cancelled_at',b.cancelled_at,'checked_in_at',a.checked_in_at,'outcome',a.outcome,
      'release_reason',a.consequence_snapshot->>'reason',
      'rating_change',coalesce((select sum(e.rating_change) from public.player_rating_events e
        where e.profile_id=b.profile_id and e.source_type='OPEN_QUEUE' and e.source_id=g.id),b.rating_change)))
      from public.open_queue_bookings b left join public.match_attendance_records a on a.booking_id=b.id
      where b.game_id=g.id),'{}'::jsonb))
  from public.open_queue_games g left join public.match_reliability_terms t
    on t.match_kind='SOLO' and t.open_queue_game_id=g.id where g.id=game_to_use;
$$;
revoke all on function fieldrush_private.player_game_notice_snapshot(uuid)
  from public,anon,authenticated,service_role;

-- Install a silent baseline. Editing an existing match after rollout cannot
-- announce all its old team assignments or old results as fresh events.
insert into fieldrush_private.player_game_notice_state(game_id,snapshot)
select g.id,fieldrush_private.player_game_notice_snapshot(g.id) from public.open_queue_games g;

create function fieldrush_private.player_game_notice_details(game_to_use uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,pg_temp as $$
  select jsonb_build_object('player_push_v1',true,'game_id',g.id,'starts_at',g.starts_at,
    'starts_at_epoch',extract(epoch from g.starts_at),'timezone',g.timezone,
    'check_in_at',t.arrival_check_in_opens_at,'deadline_at',t.arrival_check_in_deadline_at,
    'check_in_label',to_char(t.arrival_check_in_opens_at at time zone g.timezone,'FMHH12:MI AM'),
    'deadline_label',to_char(t.arrival_check_in_deadline_at at time zone g.timezone,'FMHH12:MI AM'),
    'game_date_label',to_char(g.starts_at at time zone g.timezone,'Dy, Mon FMDD'),
    'venue_label',g.venue,'field_id',g.field_id,'address',g.location_address,'cancelled_at',g.cancelled_at)
  from public.open_queue_games g left join public.match_reliability_terms t
    on t.match_kind='SOLO' and t.open_queue_game_id=g.id where g.id=game_to_use;
$$;
revoke all on function fieldrush_private.player_game_notice_details(uuid)
  from public,anon,authenticated,service_role;

create function fieldrush_private.emit_player_game_notice(recipient uuid,event_type text,event_key_to_use text,
  title_to_use text,body_to_use text,game_to_use uuid,event_data jsonb)
returns boolean language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare inserted boolean; saved_id uuid;
begin
  if event_type not in ('SOLO_TEAM_READY','SOLO_TEAM_CHANGED','SOLO_GAME_CHANGED',
    'SOLO_GAME_CANCELLED','SOLO_BOOKING_REMOVED','SOLO_MATCH_REVIEW','SOLO_MATCH_CORRECTED','GAME_REMINDER')
    or event_type is null or char_length(coalesce(event_key_to_use,'')) not between 1 and 512
    or jsonb_typeof(event_data) is distinct from 'object' then
    raise exception 'Invalid player game notification.' using errcode='22023';
  end if;
  if not public.is_fieldrush_account_active(recipient) then return false; end if;
  insert into fieldrush_private.notification_event_receipts(recipient_id,notification_type,event_key)
    values(recipient,event_type,event_key_to_use) on conflict do nothing returning true into inserted;
  if inserted is distinct from true then return false; end if;
  insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id,data)
    values(recipient,event_type,left(title_to_use,120),left(body_to_use,300),'OPEN_QUEUE_GAME',game_to_use,
      event_data||jsonb_build_object('player_push_v1',true,'game_id',game_to_use,'fieldrush_event_key',event_key_to_use))
    returning id into saved_id;
  update fieldrush_private.notification_event_receipts set notification_id=saved_id
    where recipient_id=recipient and notification_type=event_type and event_key=event_key_to_use;
  return saved_id is not null;
end;
$$;
revoke all on function fieldrush_private.emit_player_game_notice(uuid,text,text,text,text,uuid,jsonb)
  from public,anon,authenticated,service_role;

create function fieldrush_private.player_booking_refund_notice(booking_to_use uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare b public.open_queue_bookings%rowtype; currency_to_use text; paid integer; refunds jsonb; message text;
begin
  select * into b from public.open_queue_bookings where id=booking_to_use;
  select currency into currency_to_use from public.open_queue_games where id=b.game_id;
  paid:=case when currency_to_use='USD' then b.amount_paid_fils/10 else b.amount_paid_fils end;
  refunds:=fieldrush_private.player_history_refunds(b.payment_intent_id,b.id,b.profile_id,currency_to_use,paid);
  message:=case
    when paid=0 then 'No payment was taken for this booking.'
    when (refunds->>'refunded_minor')::bigint>=paid then 'Your full refund has been processed. Your bank may still need time to post it.'
    when (refunds->>'failed_refund_minor')::bigint>0 or (refunds->>'refund_needs_review')::boolean
      then 'Your refund needs review. Open payment history for its current status.'
    when (refunds->>'pending_refund_minor')::bigint>0 then 'Your refund is processing. Open payment history for its current status.'
    when (refunds->>'refunded_minor')::bigint>0 then 'A partial refund has been processed. Open payment history for the amount.'
    else 'Open payment history for your payment and refund status.' end;
  return refunds||jsonb_build_object('refund_message',message,'payment_intent_id',b.payment_intent_id,
    'currency',currency_to_use,'amount_paid_minor',paid);
end;
$$;
revoke all on function fieldrush_private.player_booking_refund_notice(uuid)
  from public,anon,authenticated,service_role;

create function fieldrush_private.observe_player_game_notice(game_to_use uuid)
returns void language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare before_state jsonb; after_state jsonb; previous_game jsonb; current_game jsonb;
  next_revision bigint; current_review_epoch bigint; current_result_epoch bigint; result_epochs_to_save jsonb;
  b record; previous_booking jsonb; current_booking jsonb; details jsonb;
  event_data jsonb; refunds jsonb; event_type text; headline text; message text; suffix text;
  game_changed boolean; cancelled boolean; under_review boolean; corrected boolean; forced_removed boolean; decision_recorded boolean;
begin
  -- The game lock order matches booking and referee writers. The observation
  -- row serializes two committed operations without exposing private snapshots.
  perform 1 from public.open_queue_games where id=game_to_use for update;
  if not found then return; end if;
  insert into fieldrush_private.player_game_notice_state(game_id,snapshot)
    values(game_to_use,'{}') on conflict do nothing;
  select snapshot,revision+1,review_epoch,result_epochs into before_state,next_revision,current_review_epoch,result_epochs_to_save
    from fieldrush_private.player_game_notice_state where game_id=game_to_use for update;
  after_state:=fieldrush_private.player_game_notice_snapshot(game_to_use);
  if after_state is not distinct from before_state then return; end if;
  previous_game:=coalesce(before_state->'game','{}'); current_game:=after_state->'game';
  details:=fieldrush_private.player_game_notice_details(game_to_use);
  suffix:=case when details->>'check_in_label' is not null then
    format('%s. Arrive at %s; check in with the referee before %s. %s%s.',
      details->>'game_date_label',details->>'check_in_label',details->>'deadline_label',details->>'venue_label',
      case when nullif(details->>'address','') is not null then ', '||left(details->>'address',110) else '' end)
    else format('%s at %s. Open the game for arrival details.',details->>'game_date_label',details->>'venue_label') end;
  game_changed:=before_state?'game' and
    (previous_game-'assigned'-'status'-'actual_started_at'-'operational_state'-'operational_state_updated_at'-'white_score'-'black_score'-'resolution_revision')
      is distinct from (current_game-'assigned'-'status'-'actual_started_at'-'operational_state'-'operational_state_updated_at'-'white_score'-'black_score'-'resolution_revision');
  cancelled:=current_game->>'status'='CANCELLED' and previous_game->>'status' is distinct from 'CANCELLED';
  under_review:=(current_game->>'operational_state' in ('NO_DATA','UNDER_REVIEW')
    and coalesce(previous_game->>'operational_state','NORMAL') not in ('NO_DATA','UNDER_REVIEW'))
    or (previous_game->>'status'='FINAL' and current_game->>'status'='LIVE');
  if under_review then current_review_epoch:=current_review_epoch+1; end if;
  decision_recorded:=coalesce((current_game->>'resolution_revision')::integer,0)>
    coalesce((previous_game->>'resolution_revision')::integer,0);
  for b in select booking.*,a.consequence_snapshot from public.open_queue_bookings booking
    left join public.match_attendance_records a on a.booking_id=booking.id
    where booking.game_id=game_to_use
  loop
    previous_booking:=coalesce(before_state->'bookings'->b.id::text,'{}');
    current_booking:=after_state->'bookings'->b.id::text;
    current_result_epoch:=coalesce((result_epochs_to_save->>b.id::text)::bigint,0);
    if previous_game->'white_score' is distinct from current_game->'white_score'
      or previous_game->'black_score' is distinct from current_game->'black_score'
      or previous_booking->'rating_change' is distinct from current_booking->'rating_change'
      then current_result_epoch:=current_result_epoch+1; end if;
    result_epochs_to_save:=result_epochs_to_save||jsonb_build_object(b.id::text,current_result_epoch);
    -- A prior personal cancellation can retain its check-in evidence when the
    -- player books again. That historical generation is not a second recipient
    -- of this game's review/result. Injuries and actual early departures remain
    -- eligible: their active booking/attendance outcomes are not cancellations.
    if b.status='CANCELLED' and current_booking->>'outcome' in
      ('CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE') then continue; end if;
    -- Former personal cancellations are not participants in a later Fieldrush
    -- cancellation/review. A confirmed or actually attended booking is relevant.
    if previous_booking->>'status' is distinct from 'CONFIRMED' and b.status<>'CONFIRMED'
      and current_booking->>'checked_in_at' is null then continue; end if;
    event_data:=details||jsonb_build_object('booking_id',b.id,'revision',next_revision,
      'review_epoch',current_review_epoch,'result_epoch',current_result_epoch,'booking_cancelled_at',b.cancelled_at,
      'review_status',current_game->>'operational_state','match_status',current_game->>'status',
      'operational_state_updated_at',current_game->'operational_state_updated_at',
      'expires_at',clock_timestamp()+interval '7 days');
    corrected:=decision_recorded or (current_game->>'status' in ('FINAL','CANCELLED')
      and current_game->>'operational_state' not in ('NO_DATA','UNDER_REVIEW')) and (
        previous_game->>'operational_state' in ('NO_DATA','UNDER_REVIEW')
        or (previous_game->>'status'='FINAL' and (
          previous_game->'white_score' is distinct from current_game->'white_score'
          or previous_game->'black_score' is distinct from current_game->'black_score'
          or previous_booking->'rating_change' is distinct from current_booking->'rating_change'))
        or (previous_game->>'status'='LIVE' and current_game->>'status'='FINAL' and current_review_epoch>0));
    forced_removed:=previous_booking->>'status'='CONFIRMED' and b.status='CANCELLED' and (
      b.consequence_snapshot->>'reason'='FUTURE_BOOKING_RELEASED_BY_SANCTION'
      or exists(select 1 from public.moderation_actions m where m.subject_type='PLAYER'
        and m.subject_profile_id=b.profile_id and m.action_type in ('SUSPENSION','BAN')
        and m.restriction_scope in ('PLAY','ACCOUNT') and m.revoked_at is null
        and m.starts_at<=b.cancelled_at and (m.ends_at is null or m.ends_at>b.cancelled_at)));
    if cancelled and previous_booking->>'status'='CONFIRMED' then
      refunds:=fieldrush_private.player_booking_refund_notice(b.id);
      perform fieldrush_private.emit_player_game_notice(b.profile_id,'SOLO_GAME_CANCELLED',
        format('game:%s:%s:cancel:%s',game_to_use,next_revision,b.id),'Your game was cancelled',
        format('Fieldrush cancelled your game at %s. %s',details->>'venue_label',refunds->>'refund_message'),
        game_to_use,event_data||refunds);
    elsif forced_removed then
      refunds:=fieldrush_private.player_booking_refund_notice(b.id);
      perform fieldrush_private.emit_player_game_notice(b.profile_id,'SOLO_BOOKING_REMOVED',
        format('game:%s:%s:removed:%s',game_to_use,next_revision,b.id),'Your booking was removed',
        'Fieldrush removed your booking. Open the game for details. '||(refunds->>'refund_message'),
        game_to_use,event_data||refunds);
    elsif under_review and not decision_recorded then
      perform fieldrush_private.emit_player_game_notice(b.profile_id,'SOLO_MATCH_REVIEW',
        format('game:%s:%s:review:%s',game_to_use,next_revision,b.id),'Your game is under review',
        'The match record is being reviewed. Open your game for the current result and rating status.',
        game_to_use,event_data||jsonb_build_object('review_status',current_game->>'operational_state',
          'match_status',current_game->>'status'));
    elsif corrected then
      perform fieldrush_private.emit_player_game_notice(b.profile_id,'SOLO_MATCH_CORRECTED',
        format('game:%s:%s:corrected:%s',game_to_use,next_revision,b.id),'Your match record was updated',
        'A reviewed or corrected match record is available. Open your game for the result and any SR changes.',
        game_to_use,event_data||jsonb_build_object('white_score',current_game->'white_score',
          'black_score',current_game->'black_score',
          'resolution_revision',current_game->'resolution_revision','decision_recorded',decision_recorded));
    elsif b.status='CONFIRMED' and current_game->>'status' in ('OPEN','FULL','LIVE')
      and current_game->>'operational_state'='NORMAL' then
      event_data:=event_data||jsonb_build_object('expires_at',case when current_game->>'status'='LIVE'
        then clock_timestamp()+interval '2 hours' else (current_game->>'ends_at')::timestamptz end);
      event_type:=null;
      if (current_game->>'assigned')::boolean and b.team in ('WHITE','BLACK') and (
        previous_booking->>'team' is distinct from b.team or previous_game->>'assigned' is distinct from 'true'
        or previous_booking->>'status' is distinct from 'CONFIRMED') then
        event_type:=case when previous_game->>'assigned'='true' and previous_booking->>'team' in ('WHITE','BLACK')
          then 'SOLO_TEAM_CHANGED' else 'SOLO_TEAM_READY' end;
        headline:='You’re on '||initcap(lower(b.team));
        message:=case when event_type='SOLO_TEAM_CHANGED' then 'Your team changed. ' else 'Your team is ready. ' end||
          case when current_game->>'status'='LIVE' then 'Open the game to see your updated team.' else suffix end;
      elsif game_changed and previous_booking->>'status'='CONFIRMED' then
        event_type:='SOLO_GAME_CHANGED'; headline:='Your game details changed'; message:=suffix;
      end if;
      if event_type is not null then
        perform fieldrush_private.emit_player_game_notice(b.profile_id,event_type,
          format('game:%s:%s:%s:%s',game_to_use,next_revision,event_type,b.id),headline,message,game_to_use,
          event_data||jsonb_build_object('team',b.team));
      end if;
    end if;
  end loop;
  update fieldrush_private.player_game_notice_state set snapshot=after_state,revision=next_revision,
    review_epoch=current_review_epoch,result_epochs=result_epochs_to_save,
    observed_at=clock_timestamp() where game_id=game_to_use;
end;
$$;
revoke all on function fieldrush_private.observe_player_game_notice(uuid)
  from public,anon,authenticated,service_role;

create function fieldrush_private.observe_changed_player_game()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare game_to_use uuid;
begin
  if tg_table_name='open_queue_games' then game_to_use:=coalesce(new.id,old.id);
  elsif tg_table_name='open_queue_bookings' then game_to_use:=coalesce(new.game_id,old.game_id);
  elsif tg_table_name in ('match_attendance_records','match_reliability_terms','match_resolution_cases') then
    game_to_use:=coalesce(new.open_queue_game_id,old.open_queue_game_id);
  elsif tg_table_name='player_rating_events' then
    if coalesce(new.source_type,old.source_type)<>'OPEN_QUEUE' then return null; end if;
    game_to_use:=coalesce(new.source_id,old.source_id);
  end if;
  if game_to_use is not null then perform fieldrush_private.observe_player_game_notice(game_to_use); end if;
  return null;
end;
$$;
revoke all on function fieldrush_private.observe_changed_player_game() from public,anon,authenticated,service_role;
create constraint trigger observe_player_game after insert or update on public.open_queue_games
  deferrable initially deferred for each row execute function fieldrush_private.observe_changed_player_game();
create constraint trigger observe_player_game after insert or update on public.open_queue_bookings
  deferrable initially deferred for each row execute function fieldrush_private.observe_changed_player_game();
create constraint trigger observe_player_game after insert or update on public.match_attendance_records
  deferrable initially deferred for each row execute function fieldrush_private.observe_changed_player_game();
create constraint trigger observe_player_game after insert or update on public.match_reliability_terms
  deferrable initially deferred for each row execute function fieldrush_private.observe_changed_player_game();
create constraint trigger observe_player_game after insert or update on public.match_resolution_cases
  deferrable initially deferred for each row execute function fieldrush_private.observe_changed_player_game();
create constraint trigger observe_player_game after insert or update or delete on public.player_rating_events
  deferrable initially deferred for each row execute function fieldrush_private.observe_changed_player_game();

-- Rebalance and administrative-resolution writers already insert legacy rows.
-- Their replacement above is one event per affected player after all consequences
-- settle. Staff-only dispute messages and clan messages remain unchanged.
create function fieldrush_private.normalize_player_game_notification()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare details jsonb; lock_at timestamptz;
begin
  if new.type='OPEN_QUEUE_TEAM_REASSIGNED'
    or (new.type='MATCH_RESOLUTION_RECORDED' and new.related_entity_type='SOLO_MATCH') then return null; end if;
  if new.type='OPEN_QUEUE_PARTY_INVITE' then
    select t.party_lock_at,fieldrush_private.player_game_notice_details(g.id) into lock_at,details
      from public.open_queue_party_members m join public.open_queue_parties p on p.id=m.party_id and p.status='ACTIVE'
      join public.open_queue_games g on g.id=m.game_id and g.status in ('OPEN','FULL') and g.operational_state='NORMAL'
      join public.match_reliability_terms t on t.open_queue_game_id=g.id and t.match_kind='SOLO'
      where m.id=new.related_entity_id and m.profile_id=new.recipient_profile_id and m.status='INVITED';
    if lock_at is null or lock_at<=clock_timestamp() then return null; end if;
    new.data:=new.data||details||jsonb_build_object('expires_at',lock_at,'party_lock_at',lock_at);
    new.title:=left(new.title,120);
    new.body:=left(new.body,265)||' Accept before '||to_char(lock_at at time zone (details->>'timezone'),'FMHH12:MI AM')||'.';
  end if;
  return new;
end;
$$;
revoke all on function fieldrush_private.normalize_player_game_notification() from public,anon,authenticated,service_role;
create trigger normalize_player_game_notification before insert on public.notifications
  for each row execute function fieldrush_private.normalize_player_game_notification();

create function fieldrush_private.player_game_notification_source_is_current(notification_id_to_use uuid)
returns boolean language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare n public.notifications%rowtype; g public.open_queue_games%rowtype; b public.open_queue_bookings%rowtype;
  t public.match_reliability_terms%rowtype; fresh jsonb; expires timestamptz;
begin
  select * into n from public.notifications where id=notification_id_to_use;
  if not found then return false; end if;
  if n.type='OPEN_QUEUE_PARTY_INVITE' then
    return exists(select 1 from public.open_queue_party_members m
      join public.open_queue_parties p on p.id=m.party_id and p.status='ACTIVE'
      join public.open_queue_games game on game.id=m.game_id and game.status in ('OPEN','FULL')
        and game.operational_state='NORMAL' and game.actual_started_at is null
      join public.match_reliability_terms terms on terms.open_queue_game_id=game.id and terms.match_kind='SOLO'
      join public.open_queue_bookings booking on booking.game_id=game.id and booking.profile_id=m.profile_id and booking.status='CONFIRMED'
      where m.id=n.related_entity_id and n.related_entity_type='OPEN_QUEUE_PARTY_MEMBERSHIP'
        and m.profile_id=n.recipient_profile_id and m.status='INVITED' and terms.party_lock_at>clock_timestamp());
  end if;
  if n.data->>'player_push_v1' is distinct from 'true' or n.related_entity_type<>'OPEN_QUEUE_GAME' then return false; end if;
  select * into g from public.open_queue_games where id=n.related_entity_id;
  select * into b from public.open_queue_bookings where id::text=n.data->>'booking_id'
    and game_id=g.id and profile_id=n.recipient_profile_id;
  if g.id is null or b.id is null then return false; end if;
  select * into t from public.match_reliability_terms where match_kind='SOLO' and open_queue_game_id=g.id;
  expires:=(n.data->>'expires_at')::timestamptz;
  if expires is null or expires<=clock_timestamp() then return false; end if;
  if n.type='SOLO_GAME_CANCELLED' then return g.status='CANCELLED'
    and g.cancelled_at is not distinct from (n.data->>'cancelled_at')::timestamptz;
  elsif n.type='SOLO_BOOKING_REMOVED' then return b.status='CANCELLED' and g.status<>'CANCELLED'
    and b.cancelled_at is not distinct from (n.data->>'booking_cancelled_at')::timestamptz
    and not exists(select 1 from public.open_queue_bookings newer where newer.game_id=g.id
      and newer.profile_id=b.profile_id and newer.status='CONFIRMED');
  elsif n.type='SOLO_MATCH_REVIEW' then return
    exists(select 1 from fieldrush_private.player_game_notice_state state where state.game_id=g.id
      and state.review_epoch::text=n.data->>'review_epoch')
    and ((n.data->>'review_status' in ('NO_DATA','UNDER_REVIEW') and g.operational_state in ('NO_DATA','UNDER_REVIEW'))
      or (n.data->>'review_status'='NORMAL' and n.data->>'match_status'='LIVE' and g.status='LIVE' and g.operational_state='NORMAL'));
  elsif n.type='SOLO_MATCH_CORRECTED' then
    fresh:=fieldrush_private.player_game_notice_snapshot(g.id);
    return (n.data->>'decision_recorded'='true' or
      (g.status in ('FINAL','CANCELLED') and g.operational_state not in ('NO_DATA','UNDER_REVIEW')))
      and g.operational_state=n.data->>'review_status' and g.status=n.data->>'match_status'
      and exists(select 1 from fieldrush_private.player_game_notice_state state where state.game_id=g.id
        and state.review_epoch::text=n.data->>'review_epoch' and state.result_epochs->>b.id::text=n.data->>'result_epoch')
      and g.operational_state_updated_at is not distinct from (n.data->>'operational_state_updated_at')::timestamptz
      and fresh->'game'->'resolution_revision' is not distinct from n.data->'resolution_revision'
      and fresh->'game'->'white_score' is not distinct from n.data->'white_score'
      and fresh->'game'->'black_score' is not distinct from n.data->'black_score';
  end if;
  if b.status<>'CONFIRMED' or g.operational_state<>'NORMAL' then return false; end if;
  if n.type in ('SOLO_TEAM_READY','SOLO_TEAM_CHANGED') then
    if g.status not in ('OPEN','FULL','LIVE') then return false; end if;
  elsif g.status not in ('OPEN','FULL') or g.actual_started_at is not null then return false; end if;
  if extract(epoch from g.starts_at)::text is distinct from n.data->>'starts_at_epoch'
    or t.arrival_check_in_opens_at is distinct from (n.data->>'check_in_at')::timestamptz
    or t.arrival_check_in_deadline_at is distinct from (n.data->>'deadline_at')::timestamptz
    or g.venue is distinct from n.data->>'venue_label' or g.timezone is distinct from n.data->>'timezone'
    or g.field_id::text is distinct from n.data->>'field_id' or g.location_address is distinct from n.data->>'address'
    then return false; end if;
  if n.type in ('SOLO_TEAM_READY','SOLO_TEAM_CHANGED') then
    return g.teams_assigned_at is not null and b.team=n.data->>'team';
  elsif n.type='SOLO_GAME_CHANGED' then return true;
  elsif n.type='GAME_REMINDER' then
    return b.team is not distinct from n.data->>'team'
      and not exists(select 1 from public.match_attendance_records a where a.booking_id=b.id and a.checked_in_at is not null)
      and (n.data->>'reminder_kind'<>'check_in_deadline' or clock_timestamp()<t.arrival_check_in_deadline_at);
  end if;
  return false;
exception when invalid_datetime_format or datetime_field_overflow then return false;
end;
$$;
revoke all on function fieldrush_private.player_game_notification_source_is_current(uuid)
  from public,anon,authenticated,service_role;

create function fieldrush_private.process_player_game_reminders(at_time timestamptz default clock_timestamp())
returns integer language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare item record; details jsonb; sent integer:=0; title text; body text; event_key text; suppressed boolean;
begin
  for item in select g.id game_id,g.ends_at,b.id booking_id,b.profile_id,b.team,g.teams_assigned_at,
      t.arrival_check_in_opens_at check_in_at,t.arrival_check_in_deadline_at deadline_at,threshold.kind,threshold.due_at
    from public.open_queue_games g join public.open_queue_bookings b on b.game_id=g.id and b.status='CONFIRMED'
    join public.match_reliability_terms t on t.open_queue_game_id=g.id and t.match_kind='SOLO'
    cross join lateral (values ('24h',t.arrival_check_in_opens_at-interval '24 hours'),
      ('2h',t.arrival_check_in_opens_at-interval '2 hours'),
      ('check_in_deadline',t.arrival_check_in_deadline_at-interval '5 minutes')) threshold(kind,due_at)
    where g.status in ('OPEN','FULL') and g.operational_state='NORMAL' and g.actual_started_at is null
      and t.arrival_check_in_deadline_at>at_time and threshold.due_at<=at_time
      and threshold.due_at>at_time-interval '5 minutes' and b.booked_at<=threshold.due_at
      and threshold.due_at>=(select activated_at from fieldrush_private.player_game_notice_activation where singleton)
      and public.is_fieldrush_account_active(b.profile_id)
      and not exists(select 1 from fieldrush_private.notification_event_receipts receipt
        where receipt.recipient_id=b.profile_id and receipt.notification_type='GAME_REMINDER'
          and receipt.event_key=format('arrival:%s:%s:%s:%s',g.id,b.id,
            extract(epoch from t.arrival_check_in_opens_at),threshold.kind))
      and not exists(select 1 from public.match_attendance_records a where a.booking_id=b.id and a.checked_in_at is not null)
    order by threshold.due_at,g.id,b.id limit 1000
  loop
    details:=fieldrush_private.player_game_notice_details(item.game_id)||jsonb_build_object(
      'booking_id',item.booking_id,'reminder_kind',item.kind,'team',item.team,
      'expires_at',case when item.kind='check_in_deadline' then item.deadline_at
        else least(item.check_in_at,item.due_at+interval '30 minutes') end);
    event_key:=format('arrival:%s:%s:%s:%s',item.game_id,item.booking_id,
      extract(epoch from item.check_in_at),item.kind);
    suppressed:=item.kind='2h' and exists(select 1 from public.notifications n
      where n.recipient_profile_id=item.profile_id and n.type in ('SOLO_TEAM_READY','SOLO_TEAM_CHANGED','SOLO_GAME_CHANGED')
        and n.related_entity_id=item.game_id and n.created_at>=at_time-interval '60 minutes'
        and n.data->>'check_in_at'=details->>'check_in_at' and n.data->>'deadline_at'=details->>'deadline_at'
        and n.data->>'venue_label'=details->>'venue_label' and n.data->>'team' is not distinct from item.team
        and n.dismissed_at is null);
    if suppressed then
      insert into fieldrush_private.notification_event_receipts(recipient_id,notification_type,event_key)
        values(item.profile_id,'GAME_REMINDER',event_key) on conflict do nothing;
      continue;
    end if;
    title:=case item.kind when '24h' then 'Your game is tomorrow' when '2h' then 'Your game is coming up'
      else 'Check-in deadline approaching' end;
    body:=case when item.kind='check_in_deadline' then
      format('Check in with the referee before %s at %s. Your arrival has not been recorded yet.',details->>'deadline_label',details->>'venue_label')
      else format('%s at %s. Arrive at %s; check in with the referee before %s.%s',
        details->>'game_date_label',details->>'venue_label',details->>'check_in_label',details->>'deadline_label',
        case when item.teams_assigned_at is not null and item.team in ('WHITE','BLACK') then ' You’re on '||initcap(lower(item.team))||'.' else '' end) end;
    if fieldrush_private.emit_player_game_notice(item.profile_id,'GAME_REMINDER',event_key,title,body,item.game_id,details)
      then sent:=sent+1; end if;
  end loop;
  return sent;
end;
$$;
revoke all on function fieldrush_private.process_player_game_reminders(timestamptz)
  from public,anon,authenticated,service_role;

-- Preserve the existing clan/replay/ranking sweep, removing only its old solo
-- kickoff-based reminders. The player reminder sweep uses saved arrival terms.
do $$
declare definition text; anchor text:='where g.status in (''OPEN'',''FULL'') and g.starts_at>at_time';
begin
  definition:=pg_get_functiondef('fieldrush_private.process_notification_events()'::regprocedure);
  if position(anchor in definition)=0 then raise exception 'Solo notification sweep anchor changed'; end if;
  definition:=replace(definition,anchor,anchor||' and false -- solo reminders use the arrival contract below');
  execute definition;
end;
$$;
alter function fieldrush_private.process_notification_events() rename to process_notification_events_before_player_game_notices;
revoke all on function fieldrush_private.process_notification_events_before_player_game_notices()
  from public,anon,authenticated,service_role;
create function fieldrush_private.process_notification_events()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare result jsonb; reminders integer;
begin
  result:=fieldrush_private.process_notification_events_before_player_game_notices();
  if result->>'skipped'='true' then return result; end if;
  reminders:=fieldrush_private.process_player_game_reminders();
  update public.notifications n set resolved_at=clock_timestamp()
    where n.resolved_at is null and n.data->>'player_push_v1'='true'
      and (n.type in ('SOLO_TEAM_READY','SOLO_TEAM_CHANGED','SOLO_GAME_CHANGED','SOLO_GAME_CANCELLED',
        'SOLO_BOOKING_REMOVED','SOLO_MATCH_REVIEW','SOLO_MATCH_CORRECTED','OPEN_QUEUE_PARTY_INVITE','GAME_REMINDER'))
      and not fieldrush_private.player_game_notification_source_is_current(n.id);
  return result||jsonb_build_object('player_reminders',reminders);
end;
$$;
revoke all on function fieldrush_private.process_notification_events() from public,anon,authenticated,service_role;
-- The last call is only useful before the deadline. Keep its sweep at a minute;
-- push dispatch has its own independent disabled-until-configured switch.
select cron.schedule('fieldrush-notification-events','* * * * *','select fieldrush_private.process_notification_events();');
notify pgrst,'reload schema';
