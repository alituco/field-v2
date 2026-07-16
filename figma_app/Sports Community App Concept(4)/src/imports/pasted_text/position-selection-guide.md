Screen 1: Primary position + optional backup positions

Do not phrase it as “pick your main position and all other positions.”

That may encourage users to select everything just to see more matches, even when they would be unhappy playing goalkeeper or defender.

Use:

Where do you play?

Choose your main position

Goalkeeper
Defender
Midfielder
Attacker

Then underneath:

Where else are you comfortable playing?
Goalkeeper
Defender
Midfielder
Attacker
Anywhere

The primary position is required. Backup positions are optional.

For example:

MAIN POSITION
Defender

I CAN ALSO PLAY
Midfielder

The distinction should be visually obvious:

Primary position: solid red
Backup position: red outline
Unselected: neutral grey
Checkmark on selected roles

I would allow at most two backup positions, plus an explicit Anywhere option. That produces cleaner intent than letting everyone casually select all four.

For goalkeeper specifically, add a small confirmation:

Only choose Goalkeeper if you are comfortable playing the full match in goal.

That prevents someone selecting it purely because a place is instantly available.

Keep the interactive pitch on Screen 1

The hybrid design still works very well here.

For a 1–2–2–1 formation:

            ATTACKER

     MIDFIELDER   MIDFIELDER

      DEFENDER      DEFENDER

           GOALKEEPER

When the player selects Defender as primary:

Both defender nodes turn solid red.
The Defender button turns solid red.
A “Main position” label appears.

If they select Midfielder as backup:

Both midfielder nodes get a red outline.
The Midfielder button gets a red outline.
A “Backup” label appears.

This gives the visual formation meaning without making them select left or right.

At the bottom:

Main: Defender
Backup: Midfielder

[See matching games]

You could also display a small summary before they continue:

4 upcoming games found
2 need defenders
1 needs midfielders

But do not let this become the main reason users choose a role. Their actual willingness to play that role matters more than maximizing immediate availability.

Screen 2: Games for you

At the top, keep their selected roles visible:

Defender
Main position

Midfielder
Backup

[Edit positions]

This is important. They should not have to press Back and rebuild everything just to change a role.

Then divide the results into two clear sections.

Section 1: Best matches for your main position
BEST MATCHES FOR YOU

Playing as Defender

Show matches where Defender is available, ordered by:

Instant confirmation
Soonest date and time
How close the match is to filling
Possibly venue proximity later

Example:

TODAY

6:30–7:30 PM
TFA, Saar

DEFENDER NEEDED
Your place can be confirmed now

10 of 12 players
3 BHD

[Join now]
Section 2: More games using backup positions

Use a very clear divider:

MORE GAMES YOU CAN JOIN

Using your backup position

Then every card must state exactly what the user would be booking:

Tuesday, 7:45 PM
TFA, Saar

AVAILABLE AS MIDFIELDER

11 of 12 players
3 BHD

[Join as Midfielder]

Do not use a generic Join button here. The button should say:

Join as Midfielder

That removes any ambiguity.

Avoid showing the same game twice

Suppose a game needs both a Defender and a Midfielder, and the player selected:

Defender as primary
Midfielder as backup

That fixture should appear once, under Defender.

The backup section should only contain additional games that did not already qualify under the primary role.

Otherwise users will think there are more games than actually exist.

The hierarchy should be:

Primary matches
    ↓
Unique backup matches
What happens when no primary-position game exists?

Do not make the player scroll through a large empty section.

Show a compact message:

No Defender spot is available in the next four games.

But two games can confirm you as a Midfielder.

Then immediately show those backup-position games.

This is a major advantage of the two-step model: the app can explain why it is recommending something else.

What if a backup position has a much better opportunity?

For example:

Defender primary: waitlist only
Goalkeeper backup: instant game tonight

You should still respect the primary choice, but show a clear banner near the top:

FASTEST WAY TO PLAY

A Goalkeeper spot is available tonight at 6:30 PM.
Your Defender matches currently have waitlists.

[View Goalkeeper match]

Do not silently reorder everything and make it appear as though Goalkeeper was their primary choice.

Why the two-screen approach is stronger
Advantages
Cleaner comprehension

Screen 1 explains the football formation and preferences.

Screen 2 explains availability.

The player is never solving both problems at once.

Better matchmaking data

You collect:

Main position
Genuine backup positions
Whether they are flexible

That is much better than merely recording whichever game card they clicked.

Better handling of scarce positions

A Defender who is also willing to play Goalkeeper can immediately see goalkeeper opportunities without making every user browse every position.

Better personalization

The page can say:

“These are the best matches for you.”

rather than presenting a generic calendar.

Easier future expansion

Later, the same preference screen can support:

Preferred venue
Availability
Keeper incentives
Ranked versus friendly
Match intensity

without cramming everything into one page