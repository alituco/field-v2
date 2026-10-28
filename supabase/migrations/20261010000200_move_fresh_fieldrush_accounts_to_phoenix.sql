-- Accounts created by the immediately preceding Fieldrush onboarding release
-- inherited the old rating default. Move only proven-unused completed accounts;
-- never move a rating ledger, clan member, old booking, or any wallet balance.
update public.player_ratings rating set region = 'phoenix'
where rating.region = 'bahrain'
  and rating.matches_played = 0
  and rating.wins = 0 and rating.losses = 0 and rating.draws = 0
  and exists (
    select 1 from fieldrush_private.accounts account
    where account.user_id = rating.profile_id and account.status = 'active'
      and account.onboarding_completed_at is not null
  )
  and not exists (select 1 from public.player_rating_events event where event.profile_id = rating.profile_id)
  and not exists (select 1 from public.fixture_player_appearances appearance where appearance.profile_id = rating.profile_id)
  and not exists (select 1 from public.clan_members member where member.profile_id = rating.profile_id)
  and not exists (select 1 from public.open_queue_bookings booking where booking.profile_id = rating.profile_id)
  and not exists (select 1 from public.fixtures fixture where rating.profile_id in (fixture.home_paid_by, fixture.away_paid_by))
  and not exists (select 1 from public.tap_payment_intents intent where intent.profile_id = rating.profile_id)
  and not exists (select 1 from public.field_wallet_transactions transaction where transaction.profile_id = rating.profile_id)
  and not exists (select 1 from public.field_wallet_accounts wallet where wallet.profile_id = rating.profile_id and wallet.balance_fils <> 0)
  and not exists (select 1 from public.field_wallet_usd_accounts wallet where wallet.profile_id = rating.profile_id and wallet.balance_fils <> 0);
