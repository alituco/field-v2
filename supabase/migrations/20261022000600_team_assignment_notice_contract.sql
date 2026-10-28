-- Team assignment notices use the same committed policy terms as checkout,
-- parties and the fixture feeds. Reading match detail must not bind/rebuild
-- terms or take row locks: its public RPC remains STABLE and read-only.
create or replace function public.get_open_queue_match_detail(game_id_to_use uuid)
returns jsonb language sql stable security definer
set search_path=public,pg_temp as $$
  select fieldrush_rating_private.mask_public_rating_payload(
    public.get_open_queue_match_detail_before_sr_privacy(requested.game_id),
    null::uuid,'OUTFIELD',null::integer,requested.game_id
  )||jsonb_build_object(
    'lobby_average_sr',fieldrush_rating_private.lobby_rating_average(requested.game_id),
    'policy_version_id',terms.policy_version_id,
    'team_assignment_at',terms.team_assignment_at,
    'party_lock_at',terms.party_lock_at,
    'team_assignment_lead_minutes',
      (terms.policy_snapshot #>> '{solo,teamAssignmentLeadMinutes}')::integer,
    'party_lock_lead_minutes',
      (terms.policy_snapshot #>> '{solo,partyLockLeadMinutes}')::integer,
    'max_party_size',
      (terms.policy_snapshot #>> '{replacement,maxPartySize}')::integer
  )
  from (values (game_id_to_use)) requested(game_id)
  left join public.match_reliability_terms terms
    on terms.match_kind='SOLO' and terms.open_queue_game_id=requested.game_id;
$$;

comment on function public.get_open_queue_match_detail(uuid) is
  'Returns authorized, privacy-masked match detail with a whole-lobby SR aggregate and saved team-assignment/party policy terms; reads never bind or change terms.';

-- CREATE OR REPLACE retains the existing grants. Make the existing public
-- boundary explicit without exposing the unmasked private original.
revoke all on function public.get_open_queue_match_detail(uuid) from public,anon;
grant execute on function public.get_open_queue_match_detail(uuid)
  to authenticated,service_role;
notify pgrst,'reload schema';
