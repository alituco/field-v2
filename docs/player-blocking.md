# Player blocking

Players can block another player from that player's profile and manage their
blocked-player list from You settings. Reporting remains available separately.
A block is stored for the signed-in player and survives sign-out or a device
change. Only the blocker can list or change their block preferences.

## What a block changes

The player client hides blocked peers' authored profile content and removes
them from discovery and following. Relevant clan identity and game-detail
avatar presentation use viewer-safe identity reads. Existing follows in both
directions are removed; new follows are rejected while either player blocks
the other. New party invitations and acceptance of a pending invitation are also
rejected between the blocked pair. Blocked invite candidates and unaccepted
incoming invitations are hidden. Unblocking does not recreate previous follows.

Blocking does not change a booking, payment, refund, official score, rating,
roster count, attendance record, accepted party membership, or staff moderation
duty. Players may still
attend the same physical games and appear in official participation/results.
The confirmation explains this scope before a player blocks someone.

## Privacy and compatibility boundary

The block relationships are protected by owner-only row-level security.
Mutations infer the owner from the authenticated session; clients cannot
supply another blocker. Self-blocking is rejected and repeated operations are
idempotent.

The new client uses server-filtered identity reads. The migration does not
remove profile rows or revoke legacy public-profile table access: doing so
would break existing game/roster joins and older clients. Blocking controls
content and interactions in the app; it is not data erasure or revocation of
previously known avatar URLs. Older installed clients do not automatically gain
the new blocking controls.

Clan masking checks the original creator and the author of each current identity
field recorded by the server. An unrelated motto edit cannot erase attribution
for an emblem. For identity edits made before this migration, no editor history
was recorded; those rows fall back to their original creator. The change does
not invent historical authorship.

## Release and verification

The hosted database job runs supabase/scripts/verify_player_blocking.sql inside
a rollback transaction against the fresh local CI database. It checks ownership
and access boundaries, block/unblock behavior, visibility, follows and party
invitations, while
preserving official records. Flutter model, repository and widget tests exercise
the reachable player controls and failure paths.

Use the normal complete staging qualification and identical-tree production
promotion. Deploy the additive backend migration before distributing a client
that calls its RPCs. Do not bypass the protected deployment or signing gates.
An Android release does not replace the currently selected Apple build or submit
a production iOS build.
