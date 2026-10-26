-- Rollback-only history verification on the complete application schema.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table history_checks(label text);
create sequence pg_temp.history_person_number;
create function pg_temp.history_expect(ok boolean,label text) returns void language plpgsql security definer as $$
begin if ok is distinct from true then raise exception 'Player history: %',label; end if;
insert into history_checks values(label); end $$;
create function pg_temp.history_person() returns uuid language plpgsql as $$
declare p uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.history_person_number'); previous text:=current_setting('request.jwt.claim.sub',true);
begin
insert into auth.users(id,phone,phone_confirmed_at) values(p,'1555264'||lpad(n::text,4,'0'),now());
perform set_config('request.jwt.claim.sub',p::text,true);
perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','History','last_name','Fixture',
  'username','history_'||n,'date_of_birth','2000-01-01','email','history_'||n||'@example.test','skill_assessment','not_sure'),
  'fieldrush-v1','fieldrush-v1');
perform set_config('request.jwt.claim.sub',coalesce(previous,''),true); return p;
end $$;
create function pg_temp.history_payment(p uuid,g uuid,money text default 'USD',amount integer default 13000,phase text default 'FINALIZED')
returns uuid language plpgsql as $$
declare id uuid:=gen_random_uuid();
begin
insert into public.payment_intents(id,profile_id,purpose,status,currency,amount_fils,payload,quote_snapshot,
  transaction_reference,provider,provider_intent_id,provider_payment_id,payment_method,provider_status,captured_at,created_at,capture_method)
values(id,p,'SOLO_BOOKING',phase,money,amount,jsonb_build_object('game_id',g,'role','GK'),'{}',
  'history_'||id,case when money='BHD' then 'LEGACY' else 'STRIPE' end,'pi_history_'||id,
  case when phase in ('FINALIZED','CAPTURED','REQUIRES_REFUND','REFUNDED') then 'ch_history_'||id else null end,
  'VISA',case when phase in ('FINALIZED','CAPTURED','REQUIRES_REFUND','REFUNDED') then 'SUCCEEDED' else 'requires_capture' end,
  case when phase in ('FINALIZED','CAPTURED','REQUIRES_REFUND','REFUNDED') then now() else null end,now(),
  case when phase='PENDING' then 'manual' else 'automatic' end);
return id;
end $$;
create function pg_temp.history_review_case(game_to_use uuid) returns void language plpgsql as $$
begin
insert into public.match_resolution_cases(match_kind,open_queue_game_id,state,reason_code,scheduled_end_at,high_priority_at,policy_snapshot)
select 'SOLO',g.id,'NO_DATA','RESULT_MISSING',g.ends_at,g.ends_at+interval '24 hours',t.policy_snapshot
from public.open_queue_games g join public.match_reliability_terms t on t.open_queue_game_id=g.id and t.match_kind='SOLO'
where g.id=game_to_use;
update public.open_queue_games set operational_state='NO_DATA',operational_reason_code='RESULT_MISSING' where id=game_to_use;
end $$;

do $$
declare owner uuid:=pg_temp.history_person(); other uuid:=pg_temp.history_person(); admin uuid:=pg_temp.history_person(); login uuid:=gen_random_uuid();
  games uuid[]:=array[]::uuid[]; payments uuid[]:=array[]::uuid[]; game uuid; booking uuid; old_booking uuid; original uuid;
  response jsonb; entry jsonb; page jsonb; cursor jsonb; collected uuid[]:=array[]::uuid[]; item jsonb; i integer;
  kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '30 days'; count_before integer;
  legacy_start timestamptz:=(date_trunc('week',(now() at time zone 'Asia/Bahrain')+interval '40 days')+interval '1 day 20 hours 30 minutes') at time zone 'Asia/Bahrain';
begin
insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
  values(admin,'History verification admin','+15552649999','admin',true);
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
  values(login,login||'@history-staff.example.test',now(),'{"fieldrush_account_type":"staff"}');
update public.referee_profiles set auth_user_id=login,email=login||'@history-staff.example.test' where profile_id=admin;
insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
  date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
  config,'Disposable history policy.',now(),admin
  from public.reliability_policy_versions order by version limit 1;
for i in 1..6 loop
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils)
    values('Player history fixture '||i,kickoff+i*interval '1 day',kickoff+i*interval '1 day'+interval '1 hour',0) returning id into game;
  games:=array_append(games,game);
end loop;
perform set_config('request.jwt.claim.sub',owner::text,true);

-- A personal cancellation alone is not a Fieldrush-cancelled game receipt.
response:=public.finalize_free_checkout(owner,'SOLO_BOOKING',jsonb_build_object('game_id',games[1],'role','GK'));
old_booking:=(response->>'resource_id')::uuid;
perform public.cancel_open_queue_booking(old_booking);
perform public.admin_cancel_match(admin,'SOLO',games[1],'WEATHER_OR_VENUE','Lightning closed the field.');
perform pg_temp.history_expect(jsonb_array_length(public.list_my_cancelled_games()->'items')=0,
  'a player who cancelled before Fieldrush cancellation does not receive the cancelled-game receipt');

-- Rebooking keeps the original cancelled row private to its financial history.
response:=public.finalize_free_checkout(owner,'SOLO_BOOKING',jsonb_build_object('game_id',games[2],'role','GK'));
old_booking:=(response->>'resource_id')::uuid;
perform public.cancel_open_queue_booking(old_booking);
response:=public.finalize_free_checkout(owner,'SOLO_BOOKING',jsonb_build_object('game_id',games[2],'role','GK'));
booking:=(response->>'resource_id')::uuid;
perform public.admin_cancel_match(admin,'SOLO',games[2],'WEATHER_OR_VENUE','Lightning closed the booked field.');
entry:=public.list_my_cancelled_games()#>'{items,0}';
perform pg_temp.history_expect(entry->>'booking_id'=booking::text and entry->>'booking_id'<>old_booking::text,
  'real organizer cancellation selects the actually booked rebooking, despite different writer timestamps');
perform pg_temp.history_expect(entry->>'reason'='Lightning closed the booked field.' and entry->>'amount_paid_minor'='0',
  'cancelled receipt retains the published cancellation reason and honest free-booking amount');
perform pg_temp.history_expect(entry->>'rating_change'='0' and entry->>'strike_change'='0' and entry->>'streak_kept'='true',
  'ordinary penalty-free venue cancellation has known neutral consequences');

-- The administrative resolution provenance array includes only active bookings.
response:=public.finalize_free_checkout(owner,'SOLO_BOOKING',jsonb_build_object('game_id',games[3],'role','GK'));
old_booking:=(response->>'resource_id')::uuid;
perform public.cancel_open_queue_booking(old_booking);
perform pg_temp.history_review_case(games[3]);
response:=public.admin_resolve_match_case(admin,'SOLO',games[3],0,'FIELD_OR_VENUE_CANCELLATION','The city closed this field for the evening.','{}');
perform pg_temp.history_expect(not exists(select 1 from jsonb_array_elements(public.list_my_cancelled_games()->'items') x
  where x->>'game_id'=games[3]::text),'administrative cancellation cannot relabel an earlier personal cancellation');
response:=public.finalize_free_checkout(owner,'SOLO_BOOKING',jsonb_build_object('game_id',games[4],'role','GK'));
booking:=(response->>'resource_id')::uuid;
perform pg_temp.history_review_case(games[4]);
response:=public.admin_resolve_match_case(admin,'SOLO',games[4],0,'FIELD_OR_VENUE_CANCELLATION','The city closed the field before this match.','{}');
perform pg_temp.history_expect(exists(select 1 from jsonb_array_elements(public.list_my_cancelled_games()->'items') x
  where x->>'game_id'=games[4]::text and x->>'booking_id'=booking::text),
  'administrative provenance admits the confirmed participant');
page:=public.list_my_cancelled_games(null,null,1);
cursor:=page->'next_cursor';
response:=public.list_my_cancelled_games((cursor->>'created_at')::timestamptz,(cursor->>'id')::uuid,1);
perform pg_temp.history_expect(page#>>'{items,0,game_id}'=games[4]::text and response#>>'{items,0,game_id}'=games[2]::text
  and (cursor->>'created_at')::timestamptz=(select starts_at from public.open_queue_games where id=games[4]),
  'cancelled pagination is descending match-date order, independent of cancellation timestamp');
perform pg_temp.history_expect((select count(*)=0 from public.list_profile_previous_games(owner)),
  'cancelled games are not added to public played-match history or lifetime WDL');
-- Preserved historical awards use the same two-match privacy rule as match SR.
update public.open_queue_bookings set rating_change=32 where id=booking;
update public.open_queue_games set cancellation_context=cancellation_context||'{"player_sr_policy":"PRESERVE_APPLIED_SR"}' where id=games[4];
select x into entry from jsonb_array_elements(public.list_my_cancelled_games()->'items') x where x->>'game_id'=games[4]::text;
perform pg_temp.history_expect(entry->>'rating_change' is null and entry->>'rating_hidden'='true',
  'owner cancellation receipt does not reveal numeric placement SR');
update public.fieldrush_player_rating_tracks set matches_played=2 where profile_id=owner and rating_track='GOALKEEPER';
select x into entry from jsonb_array_elements(public.list_my_cancelled_games()->'items') x where x->>'game_id'=games[4]::text;
perform pg_temp.history_expect(entry->>'rating_change'='32' and entry->>'rating_hidden'='false' and entry->>'streak_kept' is null,
  'revealed retained SR is truthful and does not invent a neutral cancellation');
-- Ordinary field cancellation appends a compensating incident; the original
-- positive incident remains immutable and must not reappear as an active strike.
response:=public.finalize_free_checkout(owner,'SOLO_BOOKING',jsonb_build_object('game_id',games[6],'role','GK'));
booking:=(response->>'resource_id')::uuid;
select id into original from public.match_attendance_records where booking_id=booking;
update public.match_attendance_records set outcome='NO_SHOW',strike_delta=2,finalized_at=clock_timestamp() where id=original;
perform public.record_reliability_incident(original,'NO_SHOW',2,clock_timestamp());
perform public.admin_cancel_match(admin,'SOLO',games[6],'WEATHER_OR_VENUE','The venue cancelled and attendance consequences were reversed.');
select x into entry from jsonb_array_elements(public.list_my_cancelled_games()->'items') x where x->>'game_id'=games[6]::text;
perform pg_temp.history_expect((select count(*)=2 and sum(strike_delta)=0 from public.reliability_incidents where booking_id=booking)
  and entry->>'strike_change'='0','real field cancellation nets its retained positive and compensating negative strike incidents');

-- Payment records are financial events, never uncharged authorization attempts.
for i in 1..6 loop payments:=array_append(payments,pg_temp.history_payment(owner,games[5])); end loop;
perform pg_temp.history_payment(owner,games[5],'USD',13000,'PENDING');
perform pg_temp.history_payment(owner,games[5],'USD',13000,'CANCELLED');
perform pg_temp.history_payment(other,games[5]);
response:=public.list_my_player_payments();
perform pg_temp.history_expect(jsonb_array_length(response->'items')=6,'only captured owner charges appear; authorizations, voids and other players are excluded');
perform pg_temp.history_expect(response::text not like '%provider_intent_id%' and response::text not like '%provider_payment_id%'
  and response::text not like '%quote_snapshot%' and response::text not like '%payload%',
  'receipts omit provider identifiers, secrets, payloads and quote internals');
original:=payments[1];
perform public.request_payment_refund(original,6500,'history-partial-'||original,'Partial cancellation refund.');
select id into game from public.payment_refunds where intent_id=original;
perform public.finish_payment_refund(game,'re_history_partial','succeeded',650,'USD');
select x into entry from jsonb_array_elements(public.list_my_player_payments()->'items') x where x->>'id'=original::text;
perform pg_temp.history_expect(entry->>'refunded_minor'='650' and entry->>'amount_minor'='1300','partial settled refund is separate from the original charged amount');
perform public.request_payment_refund(original,6500,'history-rest-'||original,'The remainder of the refund.');
select x into entry from jsonb_array_elements(public.list_my_player_payments()->'items') x where x->>'id'=original::text;
perform pg_temp.history_expect(entry->>'refunded_minor'='650' and entry->>'pending_refund_minor'='650','pending money is not labelled settled');
select id into game from public.payment_refunds where intent_id=original and status='PENDING';
perform public.finish_payment_refund(game,'re_history_rest','succeeded',650,'USD');
select x into entry from jsonb_array_elements(public.list_my_player_payments()->'items') x where x->>'id'=original::text;
perform pg_temp.history_expect(entry->>'refunded_minor'='1300','separate fee/deposit refund movements combine into the full settled amount');
perform public.record_external_stripe_refund(payments[2],'re_history_external',1300,'USD','succeeded');
select x into entry from jsonb_array_elements(public.list_my_player_payments()->'items') x where x->>'id'=payments[2]::text;
perform pg_temp.history_expect(entry->>'refunded_minor'='1300','full direct Stripe refunds are included even when local intent remains FINALIZED');
perform public.record_external_stripe_refund(payments[3],'re_history_pending',400,'USD','pending');
select x into entry from jsonb_array_elements(public.list_my_player_payments()->'items') x where x->>'id'=payments[3]::text;
perform pg_temp.history_expect(entry->>'refunded_minor'='0' and entry->>'pending_refund_minor'='400','pending external refund is not presented as money already returned');
insert into public.payment_refunds(intent_id,recipient_profile_id,idempotency_key,provider_intent_id,provider_refund_id,
  amount_fils,amount_minor,currency,reason,status,provider_status)
values(payments[3],owner,'history-bridge-'||payments[3],'pi_history_'||payments[3],'re_history_pending',4000,400,'USD',
  'Reconciled provider refund identity.','SUCCEEDED','succeeded');
select x into entry from jsonb_array_elements(public.list_my_player_payments()->'items') x where x->>'id'=payments[3]::text;
perform pg_temp.history_expect(entry->>'refunded_minor'='400' and entry->>'pending_refund_minor'='0',
  'one provider refund observed in both sources is counted once with settled evidence preferred');
perform public.request_payment_refund(payments[4],13000,'history-failed-'||payments[4],'A refund requiring a retry.');
select id into game from public.payment_refunds where intent_id=payments[4];
perform public.finish_payment_refund(game,'re_history_failed','failed',1300,'USD','Provider refused the transfer.');
select x into entry from jsonb_array_elements(public.list_my_player_payments()->'items') x where x->>'id'=payments[4]::text;
perform pg_temp.history_expect(entry->>'refunded_minor'='0' and entry->>'failed_refund_minor'='1300','failed refunds remain unreturned');

-- Stable keyset pagination goes beyond PostgREST's row ceiling, including ties.
for i in 1..1005 loop perform pg_temp.history_payment(owner,games[5]); end loop;
cursor:=null;
loop
  page:=public.list_my_player_payments((cursor->>'created_at')::timestamptz,(cursor->>'id')::uuid,100);
  for item in select value from jsonb_array_elements(page->'items') loop collected:=array_append(collected,(item->>'id')::uuid); end loop;
  cursor:=page->'next_cursor'; exit when cursor is null or cursor='null'::jsonb;
end loop;
perform pg_temp.history_expect(cardinality(collected)=1011 and (select count(distinct x)=1011 from unnest(collected) x),
  'more than one thousand equally timed charges page without gaps or duplicates');
-- Historical original payments can refund to their original wallet contract.
insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,format_version,currency,timezone,
  capacity,goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity)
values('Historical Bahrain fixture',legacy_start,legacy_start+interval '1 hour',1000,
  'LEGACY_6V6','BHD','Asia/Bahrain',12,2,4,4,2) returning id into game;
original:=pg_temp.history_payment(owner,game,'BHD',1000);
insert into public.open_queue_bookings(game_id,profile_id,role,status,player_rating_at_booking,amount_paid_fils,
  base_amount_fils,payment_method,payment_status,payment_intent_id,provider_payment_id)
values(game,owner,'GK','CANCELLED',1200,1000,1000,'VISA','PAID',original,'ch_history_'||original) returning id into booking;
perform public.credit_legacy_field_wallet(owner,1000,'BOOKING_REFUND','history-wallet-'||booking,
  'Historical booking refund.',null,booking,null,'{}');
update public.payment_intents set captured_at=clock_timestamp() where id=original;
entry:=public.list_my_player_payments()#>'{items,0}';
perform pg_temp.history_expect(entry->>'id'=original::text and entry->>'currency'='BHD' and entry->>'amount_minor'='1000'
  and entry->>'refunded_minor'='1000' and entry->>'refund_destination'='FIELD_WALLET',
  'legacy BHD payments preserve three-decimal wallet refunds without inventing card transfers');
perform set_config('request.jwt.claim.sub',other::text,true);
set local role authenticated;
perform pg_temp.history_expect(jsonb_array_length(public.list_my_player_payments()->'items')=1
  and jsonb_array_length(public.list_my_cancelled_games()->'items')=0,'changing the signed-in owner never reuses another account history');
reset role;
begin perform public.list_my_player_payments(null,null,101); raise exception 'Invalid page unexpectedly succeeded';
exception when invalid_parameter_value then perform pg_temp.history_expect(true,'oversized history requests are rejected'); end;
begin perform public.list_my_cancelled_games(now(),null,30); raise exception 'Incomplete cursor unexpectedly succeeded';
exception when invalid_parameter_value then perform pg_temp.history_expect(true,'incomplete keyset cursors are rejected'); end;
perform set_config('request.jwt.claim.sub','',true);
begin perform public.list_my_player_payments(); raise exception 'Anonymous history unexpectedly succeeded';
exception when insufficient_privilege then perform pg_temp.history_expect(true,'payment history rejects missing identity'); end;
begin perform public.list_my_cancelled_games(); raise exception 'Anonymous cancelled history unexpectedly succeeded';
exception when insufficient_privilege then perform pg_temp.history_expect(true,'cancelled history rejects missing identity'); end;
perform pg_temp.history_expect(not has_function_privilege('anon','public.list_my_player_payments(timestamptz,uuid,integer)','EXECUTE')
  and has_function_privilege('authenticated','public.list_my_player_payments(timestamptz,uuid,integer)','EXECUTE')
  and not has_function_privilege('authenticated','fieldrush_private.player_history_refunds(uuid,uuid,uuid,text,integer)','EXECUTE'),
  'only authenticated owner RPCs are exposed; financial helper stays private');
end $$;
select count(*) as player_history_checks from history_checks;
