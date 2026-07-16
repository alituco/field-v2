Extend the existing Field mobile app with a new Open Queue experience.

Important context:
Field is a competitive local football app. The Clan system is already designed and should remain intact. Do not redesign the existing Clan flows or create a separate visual language. Reuse the existing Field design system, including its typography, spacing, colors, card treatments, glass headers, buttons, bottom navigation, icons, shadows, and motion.

This new feature allows an individual player to find and book a place in a balanced 6-a-side football match without already having a Clan.

Field will now have two independent ratings:

1. Player Rating
- Belongs to the individual player.
- Used to balance Open Queue teams.
- Open Queue matches affect Player Rating only.
- The rating stays with the player whether or not they join or leave a Clan.

2. Clan Rating
- Belongs to the Clan.
- Used for ranked Clan-versus-Clan competition.
- It is not calculated from the average of the Clan’s players.
- Open Queue never changes Clan Rating.

Use the user-facing labels “Player Rating” and “Clan Rating.” Avoid presenting both of them as the same type of SR.

DESIGN SCOPE

For this iteration, design only:

1. The updated Home page
2. The Open Queue role-selection and match-selection page
3. The booking review and payment flow
4. The booking-success state

Do not design the full team-balancing algorithm, live match screen, referee flow, or post-match Player Rating update yet.

Use high-fidelity mobile screens based on the same iPhone frame size already used by the existing Field app. Use Auto Layout and reusable components where practical.

The functional requirements below are important, but use your design judgment on exact composition, card styling, motion, illustration, iconography, microcopy, and spacing. Keep the experience simple, energetic, football-specific, and immediately understandable.

--------------------------------------------------
1. UPDATED HOME PAGE
--------------------------------------------------

The main purpose of Home should now be helping the player find a game.

The most visually dominant element should be a large primary card or action:

FIND A GAME

Supporting text:
“Choose your position and join a balanced 6-a-side match.”

A smaller label may say:
“Ranked Open Queue”

This should be the clearest primary action on the entire page. It should feel exciting and inviting, not like a technical matchmaking tool.

The Home page should display the player’s personal rating near the top:

PLAYER RATING
1,528
Gold I · #42 Bahrain

Use realistic mock data.

Below the Find a Game action, keep the Clan system visible as a secondary but meaningful part of the app.

For a player who belongs to a Clan, show something like:

YOUR CLAN
Invincibles
Clan Rating 1,714 · #8 Bahrain
Next fixture: Thursday, 8:30 PM
[View Clan]

For a Free Agent, show:

FIND YOUR CLAN
“Build chemistry, compete together, and climb the Clan leaderboard.”
“6 Clans are currently recruiting.”
[Browse Clans]

The visual hierarchy should clearly be:

1. Player identity / Player Rating
2. Find a Game
3. Current Open Queue booking, if one exists
4. Your Clan or Find a Clan
5. Smaller activity or content

Also design an optional Home state where the player already has an Open Queue booking:

MATCH CONFIRMED
Tuesday · 7:00 PM
Position: Defender
Team assignment pending
10 of 12 players confirmed

The primary Home card should adapt to tell the player their most important next action.

--------------------------------------------------
2. OPEN QUEUE ROLE-SELECTION PAGE
--------------------------------------------------

After pressing Find a Game, open a dedicated full-screen flow.

The main title should be:

WHERE DO YOU PLAY?

Supporting instruction:
“Choose one position to see the next games that need you.”

This page should use a hybrid role selector:

A. Interactive football pitch
B. Large role-selection buttons

The format is 6-a-side using this formation:

- 1 Goalkeeper
- 2 Defenders
- 2 Midfielders
- 1 Attacker

Visually represent the formation as:

                ATTACKER

        MIDFIELDER   MIDFIELDER

         DEFENDER      DEFENDER

               GOALKEEPER

The pitch should be easy to understand on a phone. Do not make the position nodes too small.

Under or around the pitch, provide four large role options:

- Goalkeeper
- Defender
- Midfielder
- Attacker

When a role is selected:

- The selected role button becomes filled with Field’s main red/accent color.
- Show a checkmark or another non-color indicator.
- The corresponding positions on the pitch become highlighted in red.
- All other positions remain neutral or light grey.
- Use a subtle transition or haptic-style visual feedback.
- Do not force the user to press Continue just to see availability.

Examples:

Selecting Goalkeeper highlights the single goalkeeper position.

Selecting Defender highlights both defender positions.

Selecting Midfielder highlights both midfielder positions.

Selecting Attacker highlights the single attacker position.

Do not make the player select left or right defender/midfielder yet.

The player selects one primary role.

Optionally include a small secondary setting:

“I can also fill another position”

When enabled, allow the player to select one secondary role. The primary role should remain solid red, while the secondary role can use a red outline.

Make it clear that choosing Goalkeeper means the player is genuinely agreeing to play in goal.

--------------------------------------------------
3. POSITION-BASED LIVE AVAILABILITY
--------------------------------------------------

The role selection must have an immediate, obvious effect on the available games.

The next four Open Queue games should update in-place as soon as the user selects a role.

This cause-and-effect is one of the most important parts of the design.

For example, before selecting a role, role buttons could show:

Goalkeeper
Needed now

Defender
3 spots

Midfielder
2 spots

Attacker
Waitlist

After selecting Goalkeeper, show a clear summary such as:

GOALKEEPER SELECTED

“3 of the next 4 games can confirm you immediately.”

“Earliest available: Today at 6:30 PM.”

After selecting Attacker, the summary could say:

ATTACKER SELECTED

“1 game has an attacker spot.”
“Other games currently have attacker waitlists.”

Do not hide this logic behind a filter icon. Make it visually obvious that selecting a role changes the match opportunities shown below.

--------------------------------------------------
4. NEXT FOUR OPEN QUEUE GAMES
--------------------------------------------------

Show the next four games grouped clearly by date.

Use date headings such as:

TODAY

TUESDAY, 6 JANUARY

THURSDAY, 8 JANUARY

The exact mock dates can be adjusted to fit the prototype, but they should be chronological and very easy to scan.

Each match card should show only the information needed to make a decision:

- Date group
- Time
- Venue
- Selected-position availability
- Number of players confirmed out of 12
- Ranked Open Queue status
- Player price
- Age compatibility label
- Join or Waitlist action

Example card after selecting Goalkeeper:

6:30–7:30 PM
TFA, Saar

GOALKEEPER NEEDED
“Your spot can be confirmed now.”

10 of 12 players confirmed
Ranked Open Queue
Ages 16–20
3 BHD

[Join now]

Example card after selecting Attacker:

7:45–8:45 PM
TFA, Saar

ATTACKER FULL
“Join the waitlist or select another role.”

12 of 12 spots currently allocated
3 BHD

[Join waitlist]

Possible card states:

1. Needed now
- “Goalkeeper needed”
- “Your spot can be confirmed instantly”
- Strongest visual state

2. Available
- “2 defender spots left”
- Join now

3. Last spot
- “Last midfielder spot”
- Add urgency without being overly aggressive

4. Position full
- Join waitlist
- Suggest selecting another position

If the player selected a secondary role and their primary role is full, the card can say:

“Defender full”
“Midfielder spot available”

[Join as Midfielder]

Show four games initially, followed by a secondary action:

“View later dates”

Do not overload the cards with full rosters, rating calculations, referee information, or detailed team balance at this stage.

--------------------------------------------------
5. BOOKING REVIEW SCREEN
--------------------------------------------------

After pressing Join Now, show a simple review screen.

Include:

OPEN QUEUE BOOKING

Tuesday, 7:00–8:00 PM
TFA, Saar

Your position
Defender

Format
6-a-side · Ranked Open Queue

Price
3 BHD

Rating impact
Affects your Player Rating
Does not affect Clan Rating

Team assignment
“White or Black will be assigned when the match fills.”

Players confirmed
10 of 12

The screen should make it obvious what the player is committing to.

Use the existing Field payment and confirmation design language where possible.

Primary action:

[Confirm and Pay]

Secondary action:

[Back]

--------------------------------------------------
6. PAYMENT SCREEN
--------------------------------------------------

Create a clean mock payment screen using Field’s existing payment visual patterns.

The price is:

3 BHD

Use a primary payment option that matches the current Field system, such as mock Apple Pay. You may include BenefitPay as an alternative if it fits the existing Bahrain-focused design, but keep the screen simple.

Show:

- Match time
- Venue
- Position
- Total price
- Cancellation/payment note
- Secure/mock payment treatment

Primary action:

[Pay 3 BHD]

Do not create a complicated checkout form.

--------------------------------------------------
7. SUCCESS SCREEN
--------------------------------------------------

After payment, show a strong but concise success state.

Copy:

YOUR SPOT IS RESERVED

Tuesday · 7:00 PM
TFA, Saar

Position
Defender

10 of 12 players confirmed

“We’ll notify you when teams are balanced and your White or Black shirt assignment is ready.”

Primary action:

[View Booking]

Secondary action:

[Back to Home]

Use a celebratory Field-style treatment, but keep it more controlled than a tournament victory. Confetti or a short success animation is acceptable.

--------------------------------------------------
INTERACTION AND DESIGN PRINCIPLES
--------------------------------------------------

- Preserve the existing Field design system.
- Open Queue should feel like a natural extension of Field, not a separate app.
- Keep one obvious primary action per screen.
- Make football roles understandable visually and through text.
- Do not rely on red alone for selection or status.
- Role selection should instantly update game availability.
- Use progressive disclosure: show only what the user needs at each step.
- Keep cards easy to scan with strong date and time hierarchy.
- Use plain football language rather than technical matchmaking language.
- “Find a Game” should be more prominent than “Open Queue.”
- Explain Player Rating versus Clan Rating with minimal copy.
- Open Queue affects Player Rating only.
- Team colors are assigned after the player pool can be balanced.
- Keep the bottom navigation visible on Home, but the booking flow can use focused full-screen pages with a back action.
- Include realistic loading, empty, full-position, waitlist, and confirmed states where useful.
- You have creative freedom over the exact visual design, animations, card structure, and microcopy as long as the core interaction remains extremely clear.

Deliver the result as a coherent, high-fidelity mobile flow that demonstrates:

Home → Find a Game → Select Role → Games update by role → Select Game → Review → Payment → Success