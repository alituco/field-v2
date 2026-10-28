# Referee arrivals and match corrections

For Season 0 solo matches, arrival is entry into play. The referee records one
arrival time. Players checked in before actual kickoff form the starting lineup;
a player arriving later joins their original team at the corresponding playing
second. Pauses do not count as playing time. A late arrival remains available
throughout a live game, including after the former ten-minute admission cutoff.

The saved attendance deadline still determines whether arrival is on time or
late. Recording an earlier on-time arrival later does not itself create a late
strike. No-shows are finalized at the actual finish. A later correction replaces
the mistaken decision: no-show to late means two strikes become one, rather than
three. Attendance retains its original policy and strike-expiry dates.

## Referee workflow

- Record **Arrived now**, or the actual earlier arrival. There is no separate
  entry-into-play action.
- Record injuries, departures, cards and returns as they happen.
- Use **Correct match record** for a missed arrival, incorrect event, goal or
  playing time. Give a reason for changing an existing record. Review the actual
  consequences before publishing a correction.
- Use **Reopen game** only when play will resume. Correcting a finished record
  keeps the game finished.

When a late full-time tap overstated a finished game's duration, the corrected
playing duration determines its effective finish time. The original observed
finish remains in the audit. A live clock correction must agree with the actual
pause and resume history; stopped time cannot become extra playing minutes.

Only the assigned referee or an authorized organizer can access the game.
The original booked roster, teams, roles and kickoff observations remain audit
evidence. A new live arrival cannot bypass an active playing suspension.
Referee corrections do not introduce replacements, manual SR values,
refunds or overrides of organizer-resolved disputes and appeals.

## Consistency and audit

The server saves attendance, entry events, reliability consequences and rating
replay as one transaction. It recalculates dependent later ratings, counted
appearances and the existing referral eligibility views. Unrelated restrictions
and financial records remain unchanged. Lateness carries no direct Season 0 SR
multiplier; actual participation and the existing qualification rules determine
SR and short-handed protection.

Published correction previews are bound to the exact proposed record and current
evidence and affected reliability decisions. A stale preview must be refreshed.
Request receipts make retries safe
after an interrupted response; a successful retry does not apply a second
correction. Previews roll back their trial changes, including notification work.

Goal corrections validate that the scorer and assist were playing for the
scoring side at the recorded minute. Removing or replacing a goal retains its
original event plus a linked correction, invalidates its old highlight and
updates the score used for SR. Unchanged goals retain their IDs and clips.

Every saved correction retains its actor, reason, original facts and resulting
record. Existing player notifications report the committed decision; intermediate
trial states are not sent.
