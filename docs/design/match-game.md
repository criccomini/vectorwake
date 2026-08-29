# The match game

> **The kit, the shop and the bounty are gone.** Ships are preconstructed:
> every hull is a whole ship with its own flight, gun, bomb and profile, and a
> pilot picks one. Nothing is spent, nothing is bought and nothing is banked,
> so gripes 3 and 6 below are answered differently than this document first
> proposed. The sections that described them have been rewritten rather than
> deleted, because the reasoning that led here is worth keeping. See
> [ships.md](ships.md) and [decisions.md](../architecture/decisions.md).

> **The week's table is gone.** The standings tab came out of the client, so
> gripe 5 is answered outside the game again: the site publishes the ladder at
> `/pilots` and nothing inside a session ranks you. What accumulates is the
> rating. See [decision 65](../architecture/decisions.md).

> **Built, for Melee.** Everything below through the week is running: three
> minute matches with an intermission, seven preconstructed ships, six match
> maps, and the menu's tab row. Capture and Holdfast are named here and not
> written; so are parties and livery. Friends was built and then removed, per
> decision 95. Alpha did not survive this document, and greens, gunners and
> turrets went with it.
>
> It replaces the six-gripe proposal that used to live at `progression.md`,
> which was a persistent layer bolted around an untouched Alpha.

## What playtesting said

Six gripes, from the owner's own sessions:

1. You land in the arena and there is no obvious point.
2. A session has no beginning, middle, or end.
3. You cannot shape your ship to your liking. Greens are random.
4. A death takes everything you built.
5. Rating tiers and `/pilots` exist, but nothing inside the game ranks you at
   a cadence that pulls you back for one more.
6. Points buy nothing. There is no economy.

The live fleet agrees. Of 241 human accounts read off the public pilot API on
2026-08-17, 67% never scored a rated exchange, the median career among those
who did is three games, and nine accounts have passed twenty. Arrivals are
fine. The first session is the wall.

They are one gripe wearing six coats: nothing in the game accumulates
meaning, and the one thing that does accumulate inside a session is designed
to be taken away.

## The shape of the answer

**Every game is a three minute 4v4 match.** There is no open arena, no
practice room, and no lobby to wait in. You pick a mode, you are in a match
within seconds, and three minutes later it ends with a score, a payout and a
next one.

Around that sit two things:

- **A ship you chose off a roster of seven**, each a whole ship rather than a
  shape, dealt to you whole at every spawn. Gripe 3.
- **A rating** that moves on every kill and every death, and a podium that
  says what the match did to it. Gripes 1, 5 and 6.

Three of those gripes used to be answered by an economy: a thirty point kit,
a bounty that grew with a run, and rivets to spend on slots. That is gone, and
the argument for going is in [decisions.md](../architecture/decisions.md). The
short version: a budget every pilot spends the same thirty points against
forces every hull onto one flight row, and once it does, the thing a player
picks is a silhouette. Seven real ships is a better answer to "you cannot
shape your ship" than one ship with thirty sliders.

Gripe 4 is answered by the match itself. A death empties the hull, and the
hull comes back whole at the next spawn, so what a death costs is the seconds
it takes to fly back. There is nothing to lose, because there was nothing to
accumulate inside the match.

## The match

```toml
[arena]
match_seconds = 180
intermission_seconds = 15
team_size = 4
```

**Four a side, three minutes.** Both sides are filled to four by the
population director, so a room is never short. A match starts when it has a
room, not when it has eight humans.

**You never wait.** Press play and a room takes you: an open one if there is
one, a fresh one if there is not, with bots seated in the empty chairs. This
is the reason there is no rotation of modes on a timer. A rotation rations a
queue, and rationing is a thing you do to a population you have; with the one
this game has, every mode has to be startable on demand. If human queues ever
grow enough to need herding, rotation is a directory feature and can return
then.

**You join a room, not a match.** A room is long lived and plays match after
match with the intermission between them: the server stays alive between
matches rather than being built for each one. The match is only what the room
is doing right now. So a join never waits for anything to finish. If a match
is running you spawn into it in your own ship with the score standing; if the
room is between matches you land on the podium and the next one starts in a
few seconds.

That replaces a rule saying humans join at match boundaries and open a new
room when they cannot find one. Those two sentences together guaranteed the
thing they were meant to prevent. Press a mode while the only room running it
is ninety seconds in, find no boundary, open a fresh room full of bots: two
humans arriving ninety seconds apart would never meet, not rarely but never.
The cost the rule was avoiding is a minute of a match you cannot win. The cost
it created is that the one other person online never sees you. At three
minutes those are not close, and the boundary rule loses.

**The sort is by humans, and bots do not count as fullness.** That second
clause is the whole mechanism, because a bot always stands down for an
arrival, so a room holding one human and seven bots is one eighth full rather
than full. Joining walks the list in order:

1. rooms running the mode you picked,
2. most humans first,
3. the first one with a seat, where a bot gives one up,
4. and a new room only when every existing one holds eight humans.

Three people pressing Melee across ten minutes therefore land in the same
room, which is the property that matters and the one the old rule destroyed.

**A solo arrival takes the side with fewer humans**, so four humans never
stack against four bots. A party stays together, because that is what a party
is for. The intermission is where the room rebalances and sorts whoever
arrived late, which gives those fifteen seconds a job beyond the podium.

There are two ways to end up beside a person, and a player should be able to
name both: the mode list says where the humans are, and the sort puts you
where they already are.

**Sitting out is a drop you chose**, and lands in the same place: a bot takes
the seat, you land in the stands, and the seat is yours to reclaim until the
match ends. A dropped socket and the lag ladder benching a bad connection
arrive there too, so three paths produce one state rather than three.
[spectating.md](spectating.md) has the gallery, including what happens to a
seat that frees while people are watching.

**The hull is locked for the match.** A ship is chosen between matches. This
is not ceremony: charges
are match-scoped below, and a mid-match hull change would have to answer what
happens to a half-spent charge ledger across two different charge rows. The
honest answer is to not let the question exist.

**The ending is a podium**, and the intermission is where the hangar is one
key away. It leads with the scoreline, set large with the split of the match
drawn between the two figures, because that is the one thing anybody wants off
it in the first half second; the rosters are underneath for whoever reads
further, and under those what there is to say and what the room is counting
down to. The last five seconds are counted out loud, one pip a second and a
different sound at nought, since a pilot picking a hull is not looking at the
clock.

It is a page rather than a card. The card was capped at the width a phone can
hold and drawn at that size on every monitor, which ended a match four people
had just played in a box in the middle of the screen. Now one measure
spans the window up to a thousand and forty points, the two sides stand abreast
where there is room for them and stack where there is not, and each group under
the scoreline wears its name over a rule.

What the match did to your rating is on it, as a column on the board: signed,
green for a climb and the other side's color for a slide, and a zero where the
match did not move you. A rating is the one number that outlives the three
minutes, so the ending is where it belongs, and it is drawn nowhere during the
fight. BANKED and a rivet stood in that corner once; both went with the shop.
The film has no key either. A second key of equal
weight on the one screen with a countdown running made the ending a choice
between leaving and staying, so what remains is the one key that hands the
match to somebody else.

**And six things a player can say**, off chips under the rosters: "gg",
"nice shot", "close one", "good luck", "thanks", "sorry". A press puts the
words on your own row on every screen in the room for four seconds. It is a
closed list, one byte on the wire, refused while a match is running and
throttled to one every two seconds, which is what makes it cost nothing to
moderate. See [decision
51](../architecture/decisions.md#51-six-phrases-and-no-way-to-add-a-seventh).

**The arena empties at that whistle, and the next map goes down under it.** A
podium drawn over the fight you have just finished, with the wrecks and the
last bomb still in the air, is fifteen seconds of looking at something that is
over. So the whistle clears the arena, benches everybody, and moves the room to
the ground the next match is played on, which is the one you spend the wait
looking at. Nothing anybody earned is touched: the tallies the podium is
reading live on the ships, and nobody is killed to take them off the map.

They go out rather than blowing up, and so does whatever was in the air. A
wreck is what a kill looks like, so eight of them at once said the room had
been wiped rather than that time was up.

## What a death costs

Nothing you own, and a walk.

A ship comes back whole, so spawn geometry is the only thing pricing a death
and the maps carry the weight the prize table used to.

**Each side spawns in its own pocket, at its own end of the map.** Not a
shared scatter with a radius. Two homes, far apart, with real ground between
them.

Frictionless flight makes the trip do more work than it looks like it should.
The run from your spawn is also your run-up, so pilots reach the middle
carrying speed and the opening engagement is a jousting pass rather than a
knife fight in a phone booth. A side that gets wiped re-arrives together,
which produces waves and regroups without a respawn-wave rule written
anywhere.

**No safe zones in a home pocket.** Nowhere to hide, in anything played
against a clock: a safe pocket is where a leading team goes to stall. Respawn
invulnerability stays long enough to orient and short enough to be useless
offensively.

## Spray is one ladder

How many rounds a pull throws, and it is a number on the hull rather than a
thing a pilot climbs. The Lattice throws one, the Apex two, the Chord three
and the Facet five.

It was two add-ons on a shelf. "Gun spray" opened a wide fan and charged energy
and cooldown; "gun double barrel" put a tight pair abreast and charged energy
alone. Both read, on the page that sold them, as *more bullets*, and nobody
could say what the difference bought. So they became one ladder, and then the
shelf went and the ladder became a row in each hull's profile.

What survives of the difference is the spacing. Two rounds leave at the tighter
angle a pair is supposed to, so the Apex's pair lands together out to three
hundred pixels; three or more open out to the zone's fan, which is what makes
the Facet a shotgun rather than a heavier gun. Every round past the first costs
energy and cooldown, at a quarter and a half of the shot's own, so five rounds
is two and a quarter times the energy and three and a half times the wait. That
lands a spray of three exactly where the original priced multifire. What the
merge cost, and what it bought, is [decision
54](../architecture/decisions.md#54-barrels-and-multifire-are-one-ladder-called-spray).

## Two charges, and which two is the hull's

A ship carries two kinds of charge, and which two is the hull's: the Anvil
carries three repels and one burst, the Cipher one and two, the Lattice three
of each. What is left for the pilot is which key throws which.

That is a row on the ship page, beside the wake, reading "repel first" or
"burst first" and stepped by the arrows. Before it existed the order was the
core's numbering of the kinds, so the lower-numbered kind took Q whether the
pilot wanted it there or not. What key throws what is a preference about a
keyboard rather than a fact about a ship, so it is kept on the device beside
the bindings and nothing about the ship changes when it moves. The row is not
drawn on a hull that carries one kind, because there is nothing to trade.

Two kinds ship today, a repel and a burst. The rack holds four, so a zone may
write more; the arena refuses a profile naming a third kind, because carrying
every kind at once would mean there was nothing to decide.

The keys are named for their positions rather than for weapons. A key named
for a weapon does nothing on a ship not carrying it, and puts a row on the
controls page describing something the pilot may never have bought. What a key
spends is a slot; what a slot holds is the pilot's business. So the corner
stack says what is in each while you fly, and the ship page says which key each
row landed on.

## Assists

A hull rarely comes apart to one pilot's fire. Two columns told the pilot who
did four fifths of the work and lost the last shot that they had done nothing,
so there is a third: kills you were part of and did not finish.

An assist is not a share. Every pilot who damaged the victim recently and was
not the one who landed the last round gets one, whole, and the column counts
deaths you were in rather than how much of each you did. The rating layer
already weighs the damage properly, and it is the thing that should: a rating
is a judgment and a scoreboard column is a count.

"Recently" is six seconds, against the rating layer's four-second half-life. A
pilot who softened somebody and lost the finish is inside it; a shot traded in
a previous engagement is not. A hull remembers four attackers, which is more
than any death in this game has had.

It sits beside kills and deaths everywhere the two of them do: the scoreboard
in a match, the podium card, the corner readout, and the week's table. See
[decision 53](../architecture/decisions.md#53-assists-are-counted-in-the-core).

## What a misfire costs

A kill.

Killing yourself with your own bomb, or killing a wingman with it, takes one
off your kills. The count goes under zero and is meant to: clamping it at
nothing makes the first mistake free and every one after it visible, which is
the wrong way round, and a pilot who has spent a match bombing their own side
should be able to read that off the card.

It cost a rivet as well while there was a wallet to take it out of. That was
never a fine calibrated against anything, and it went with the wallet.

Flying into a rock is free. It is a death and not a mistake anybody aimed, and
the walk back is already what it costs. The two that are charged are the two
with a thrower: your own hull, and your own side's.

The side's score carries it too, since a side's score is the sum of what its
pilots have taken. It cannot go below nothing, because the score is a pair of
numbers on a wire and a bar drawn as a share of their sum, and neither has an
answer for a negative one.

A misfire is a row in the pilot log of its own, so the week's table subtracts
it from that pilot's kills as well: two screens, one number. See [decision
52](../architecture/decisions.md#52-a-misfire-costs-a-kill-and-a-rivet).

## Maps

Small, and symmetric.

144 tiles square, inside the 1024-tile world the core still allocates. The
big number was for arenas holding sixty-four; a match holds eight, and what is
outside the arena is solid, which is the border a pilot actually meets.

**Point-symmetric**, rotated a half turn rather than mirrored, so both sides
face identical approach geometry rather than handed versions of it.

**Two or three distinct routes between the homes**, which is the rule that
keeps the roster honest. One corridor between spawns makes the Wedge the only
ship in the game.

Sized in seconds of flight rather than in tiles, which is the unit spawn
radius is already sized in: first contact five to eight seconds from the
opening whistle, and four to six from a respawn back into the fight. Against
a three minute clock and lives that run about twenty seconds, that is a real
cost that never eats a quarter of the match. Hulls will differ, and that is
the roster expressing itself: an Apex arriving first and an Anvil arriving
last is both ships doing their job.

`mapforge` draws them from authored recipes. Six ship in the first rotation:
drydock, relay, convoy, shoal, breakwater, and switchyard. Together they use
three lanes, ring and spokes, twin hubs, and archipelago layouts in square,
wide, and tall arenas. Dockyard, relay, derelict, and asteroid themes decide
what the structures are without deciding how the routes work.

Every map is point symmetric by construction. Each recipe asks for three
separated routes at least seven tiles wide, and generation stops if the shared
core validator, route gate, symmetry gate, spawn gate, or contact-time gate
fails. The metrics and preview beside each map make the remaining judgment,
such as whether cover feels purposeful, visible before it joins the rotation.

The flight time between the homes is held by a test rather than by a comment.
`the_melee_maps_are_two_homes_with_ground_between_them` routes a hull from one
pocket to the other on each shipped file and flies the polyline at the
roster's median top speed. Every map stays between six and eleven and a half
seconds of home-to-home flight. First contact therefore lands inside the design
window when both sides leave together.

The median rather than class zero's floor, which is what it used to be. That
floor was the bottom of a shared flight row nobody flew: every pilot spent
points on speed, so the gate was timing a ship that did not exist and every
window was scaled to it. Seven ships fly at seven speeds now and the middle of
them is the honest one to measure against.

## The roster

**A ship is preconstructed, and a pilot picks one of seven.**

Alpha dealt thirty random greens to every fresh spawn (`spawn_prizes = 30`).
The first answer to that was a kit: those same thirty, chosen once in a hangar
instead of rolled at the pad, over a flat space where a step of a stat, a rung
of a weapon, an add-on and a charge each cost exactly one. It shipped, it
worked, and it was the wrong shape.

The reason is a constraint it dragged behind it. Thirty points is only a fair
trade if every pilot spends thirty against the same starting ship, so every
hull had to sit on one flight row: same speed, same thrust, same turn, same
energy, same recharge. What separated the seven was the rectangle each one put
between a bullet and the pilot, and nothing else. That is a real difference and
it is not enough of one. A player who has picked a silhouette has not picked a
ship, and the thirty sliders they picked afterwards were the same thirty
sliders in every cockpit.

So the budget goes, and with it the constraint. Each hull now carries its own
flight row, its own gun, its own bomb, and its own profile over the same flat
slot space the kit used to spend points on. The Anvil is slow and hits for 500
a round; the Cipher outruns everything and has no bomb rack at all; the Facet
throws five bouncing rounds; the Lattice cannot kill you and carries six
charges to move you with. The whole roster is four tables in
`sim/src/baseline.c` and it is documented in [ships.md](ships.md).

Nothing is added to the ship to make this work. The core already held a profile
as counts over that flat space, the snapshot already carried them, and the only
change is which record they hang off: the class rather than the ship.

**Everyone flies the same seven.** No account owns anything another does not,
because there is nothing to own. A new pilot's Apex is a veteran's Apex, which
is the property the shop spent its whole existence failing to have: an economy
that sells strength has to sell it to somebody who does not have it yet, and
that pilot is by definition the one who most needs the fight to be fair.

**Death re-deals the frame, never the ammunition.** Flight, weapons and add-ons
come back at every spawn, because they are what your ship is. Charge counts do
not: you start a match with the charges your hull carries, and when they are
gone they are gone until the next match.

That rule earns its place twice. It closes an exploit, since a refill on death
means a pilot out of repels can suicide into the nearest enemy to reload, and
dying costs nothing but the walk. And it turns the rack into a three minute
budget rather than a per-life allowance: spend both repels in the opening joust
and you fly the last minute with no way out of a corner.

The corner stack already draws spent charges as empty rings. It needs no
change, it just stops refilling.

**Balance is now a roster question.** `calibrate hulls` flies the seven against
each other and reports the matrix, and it is the harness that matters: with no
kit in the way, a hull that beats the field beats the field, and there is
nothing a pilot could have spent to answer it. The kit had a profile harness
that measured ten marginal-pip contrasts among legal thirty-point builds, with
a preregistered powered seed stream and a family-wise interval on each. That
question no longer exists, and the machinery that answered it went with it.

## What a match is worth

**Kills, deaths, assists, and a streak. That is all a match counts.**

Three of those are on the board all match and on the podium at the whistle. The
fourth is the announcement in the next section.

A bounty stood here once: a number over every hull, starting at one on a fresh
spawn and climbing one a kill, paid to whoever ended the run. It did a real
job, and its anti-farming property was arrived at by arithmetic a player could
do in their head rather than by a rule about camping. It also meant that a
pilot two kills into a run looked exactly like a pilot on none unless you were
close enough to read a small figure over their hull, which is most of what the
streak announcement was invented to fix. With the streak doing that job at
three kills, the figure underneath it was a second, quieter answer to a
question already answered loudly.

Rivets went with it. They were bounty taken, banked in a wallet, and spent on
what an account could slot; with nothing to buy there is nothing for them to
be. The whistle used to pay five for finishing, three for a win and one an
assist, and none of that is filed any more.

What is left durable is the rating. It moves on every kill and every death,
against humans and machines alike, and the podium carries a column saying what
the match did to it. See [rating.md](rating.md). One number that outlives the
match beats two that do not.

## Kill streaks

**Three kills without dying is a streak. The room is told and the hull is
marked.**

It is the only thing this game says about how a pilot is doing right now, and
that is deliberate. A bounty said it continuously, one point a kill, which is a
slope: at three kills a pilot was worth four rather than one and nobody in the
room had been told anything. What a slope cannot do is name a moment. A streak
is a step, and a step is what a room reacts to.

So three kills is a threshold rather than a curve. It is the shortest run that
cannot be luck and it is reachable inside a three minute match, which are the
two things the number has to be at once.

The cost is real and it is accepted: below three, a pilot on two kills looks
exactly like a pilot on none. A second, quieter marker for the pilots under the
threshold would be the bounty again, in a smaller font.

Three things happen at once, and each of them reaches a pilot who is missing
the other two. The feed is read, the hull is caught out of the corner of an
eye, and the sound needs no looking at all.

- **The feed says so, in gold that shimmers.** The feed is otherwise a column
  of things that have finished happening. This is the one line in it about
  something still going on, and it moves because a still line among still
  lines is only a sixth line.
- **The hull wears it.** Gold outside the silhouette, a bloom, and four sparks
  going round. In a hue no side owns, because friend or foe is a call a pilot
  makes in a tenth of a second and nothing may put a second question inside
  it. This is what makes a streaking pilot findable across the arena rather
  than only nameable in a corner.
- **A fanfare plays.** Not attenuated by distance, unlike everything else the
  arena makes noise about. This one is an announcement, and an announcement
  that fades with range is a rumor.

Nothing is paid for ending one. There is nothing to pay in, and the reward for
taking down the pilot everybody in the room is hunting is that you were the one
who did it, in front of them.

All three are after one thing: the pilot who is winning should be the pilot
everybody else is hunting. A bounty said that quietly, in a figure over a hull
you had to be close enough to read. This says it across the room.

## What is not for sale

**Nothing, because there is no shop.**

There was one, and this section listed what it sold: rungs and add-ons the
arena allowed but an account had not bought, the last rung of each charge rack,
charge kinds past the first two, livery, and eventually a name of your own. The
first three are gone with the kit they slotted into. Livery and names are worth
keeping as ideas and need a currency that no longer exists, so they wait for
one or for a different way of earning them.

The argument against the first three is worth writing down, because it is the
one that took the shop with it. An economy that sells combat strength has to
sell it to the pilot who does not have it, and that pilot is the one whose
first match most needs to be fair. Every mechanism the shop grew was an attempt
to manage that: a base equipment envelope so nothing essential was behind a
price, a ceiling clamp so a veteran machine could not gear-check a new pilot,
a page that drew what you did not own so the shelf could say what existed.
All of it was scaffolding around a hole in the middle.

Livery keeps its rule for whenever it arrives. Hull paint is the team read and
weapon hues are semantic bands, so decoration lives on the wake, the nameplate
badge and the podium card. You should recognize a pilot by their wake before
you read the name. The wake already works that way and costs nothing.

## Charges

Two kinds, four in the core (`SIM_MAX_CHARGES`), and which two a hull carries
is the hull's. A repel and a burst ship today. The depth is the hull's too: one
of each on the Cipher's terms, three of each on the Lattice's. See
[ships.md](ships.md#the-profile).

## Friends

Built, and then removed at the owner's ask: see
[decision 95](../architecture/decisions.md). The page, the wire, the tables
and the presence column are gone, and nothing in the game asks who is on.
Chat is still refused on its own grounds, per `decision 28`, and the talking
happens on Discord, per `community.md`, reached from the site rather than
from the game.

The claim this section made is the part worth keeping: people stay for
people. Nothing that shipped moved the number this document opens with, so if
the question comes back it comes back as a design rather than as this one put
back.

## Dropping mid-match

**A bot takes the seat, in place.** Same ship, and the charge ledger as the
leaver left it. The match stays four a side.

The seat is what persists, so there is no reconnect timer to tune: come back
any time before the final whistle and you take your ship back from the bot.
Come back after it and you land on the podium.

Forfeiting is right for a game where your absence only hurts you, and wrong
here, where it would punish three teammates for a fourth person's wifi.
Substitution punishes nobody.

Two rules compose:

- **Rating** settles at the socket exactly as it does today, so a drop in the
  middle of a losing fight is a death on your record. From there the seat
  flies **unrated**, which keeps a bot's career clean of inherited doomed
  hulls and closes any angle where farming a substitute pays.
- **The lag ladder** feeds the same path. A connection bad enough to bench
  becomes an early substitution rather than a weaponless ship drifting while
  its team plays three against four.

No penalty box. The tactical dodge is already priced by the rating, the social
damage is already absorbed, and a game this size does not need one. The pilot log should count leaves so the question can be answered
with a number later.

## The menu, and where the screens live

The home experience stops being a menu. The ship page is a screen with panes
and grids, and the menu tree was deliberately one narrow column that
[menu.md](menu.md) says "falls apart at 390 points wide". So there are two
surfaces now rather than one:

- **Three tabs** at the front end, which is where you are when you are not in a
  room and where there is time to read: ship, pilot, settings. Pilot is
  your account, and your call sign at the far end of the row opens the same
  page. Standings was one of
  them until the week's table came out, and friends was one until decision 95.
  Upgrades was another, selling rungs for the kit, and it went with the kit;
  the ship page is the roster now, one row a ship, and nothing behind it. Play
  was one until [decision 98](../architecture/decisions.md), because at home it
  put the same games on the screen twice, once in a page and once in the
  landing's zone stop behind it. See [menu.md](menu.md) and
  [decision 64](../architecture/decisions.md).
- **In a room**: the side you are on, the ship in the window where a hull is
  not locked, the way out, and settings. Same row in the same place, carrying
  what you can act on from where you are standing. Side appears with a room
  that has named some, because a side is a thing a room has and at home the
  stop would stand there saying nothing. The roster is off the row while a
  match is being flown, because a ship is locked for one, and back on it
  between matches and for as long as a pilot is benched. It was settings and
  leave once, then the games list, which carried the way out as a button on the
  row of the game you were flying; with the list gone, leaving is a stop again.

Settings holds everything that is about the machine rather than about a
match, in one column: audio, video, the control bindings, and about. Help
folds into it rather than standing beside it, because the controls board and
the rebinding screen were always the same list read two ways, and `about` is
three lines that never deserved a destination.

Pilot is the one tab about you rather than about a match: your call sign and
its reroll, whether the account is claimed, and your career. It carried a
wallet until there was nothing to spend.

**It is one surface, and in a room it carries the way out where the front end
carries your account.** Same chrome as the front end, full screen, with the tab
row on top; what differs is which tabs are on it, not how any of it looks or
works. That is the point. A player learns one screen and meets it in both
places.

Discord is not a tab, or a button, or a page. It is not in the game at all,
per `decision 73`: the site carries the link and the client carries no way out
to it. [community.md](community.md) has the rest of that argument; what
matters here is that the game carries no chat and does not point at the room
that does.

Nothing you cannot act on right now is on that row, which follows from a rule
[menu.md](menu.md) already has and is proud of: nothing pauses, you can be
shot while reading, and opening a menu is a risk rather than a timeout. In a
three minute match a menu deep enough to read a roster in costs a real
fraction of the match.

It stays a menu rather than a bare leave button for one reason that does not
show up on a desktop. On a phone this is the only route to sound, to
fullscreen and to the controls reference, and a leave button alone would
strand a player who needs to mute the game.

**The match shows through it.** A scrim rather than a curtain, and the topbar
carries the score and the clock where the front end carries your call sign, so
the right-hand slot always answers "how are you doing in the thing you are
in". Hiding the fight would be a lie about what is happening,
which is the same reason the interface stays up today.

None of this needs a new mechanism. `menu.home` already builds rows from the
moment rather than declaring them, which is how the way out takes the slot your
call sign holds at home. The ship page is the same conditional in the other
direction, on the row only while a hull is not locked.

### It stays navigable from a keyboard, a d-pad and a thumb

A tab row over a page is two axes where the old tree had one, and it would be
easy to end up with a screen only a mouse can drive. It does not need more
than [menu.md](menu.md)'s five inputs:

- Focus opens on the tab row. **Left and right** move along it.
- **Down** enters the page. **Up** from the first row returns to the tabs.
- On a focused row, **left and right** set that row's value, which is what
  those keys already mean everywhere else in the game.
- **Escape** closes, or steps back to the tab row first.

Every screen at the front end is the same shape, so the ship page inherits
this rather than inventing a focus order of its own. The one thing it costs is
that a page needs a first row and a last row that are obvious, which is a
layout constraint worth having anyway.

Two consequences for [menu.md](menu.md). Changing ship is a respawn today and
becomes a front-end action, because a ship is locked for the match. And the
games list stops being a menu node, because picking a game is what the
landing's zone stop is for.

## The week

Rating answers "how good am I" on a career scale and moves slowly. The week
is the short ladder beside it: kills, deaths, the ratio, the best run anybody
ended, the matches a pilot was still in at the whistle and their side took, and
how long each pilot was actually in a room. It resets Monday 00:00 UTC.

Rating measures skill and ignores attendance. The week measures what you did
with it lately, and starts again often enough that tonight is worth playing.
So the table carries both, side by side and named apart: the rating a pilot
is at, and the swing this week put on it. The rating is read in whichever
class the week's own rated rows say they flew, because a rating is kept per
class and somebody who only plays melee has an arena rating that has never
moved.

There was a card down the right hand side saying more about whichever row the
cursor stood on. Every line in it was a column the table could carry instead,
so it is columns, and the quarter of the page the card took is what pays for
them.

Nothing about how the table is read belongs to the fleet. It answers with a
week; the page orders it by any column, turns that order over, narrows it to
a name typed into the box above it, and asks for a week further back. A rank
stays the place a pilot held in the week rather than in the filter: somebody
who is fourteenth does not become first because the other thirteen were
hidden.

The table has two axes and uses both. Down the page is the ladder, and across
it is time: left and right on any row are the pair of arrows drawn over the
table, one week back and one week forward, and there is no forward from the
week that is running. There is nothing else to the side of a pilot's row, and
the way back up to the tabs is up, out of the first row into the filter box
and out of the box to the row of tabs.

Under about five hundred points of width a row stops being a line of columns.
Two of them fitted on a phone and the second was drawn half off the panel's
edge, so a leaderboard's entire content was how many times everybody died. A
packed row is two lines instead: who, with the one number the table is ordered
on, and the rest underneath in the small face. Which number that is, is a
stepper, the same control the week's own name already uses, and the filter box
takes a line of its own rather than sharing one.

## What goes

The direction is mostly subtraction. Named here because a design document
that only adds is lying about its cost.

**Greens, entirely.** The pickup, the prize table and its weights, rust, the
death drop, the spawn deal. What survives is the upgrade *space*, which is how
the core still writes down what a ship carries. This is a deletion of the
delivery mechanism, not of the state, which is why it is cheap.

It also retires a class of bug this repository has fixed twice: a green sown
through a door and sealed inside a wall, and the point-versus-box confusions
that came with it.

**Turrets and gunners.** Two pilots on one hull is a quarter of a side parked
in a game of four. `ships.md` asked whether gunners earn their place and said
a playtest would settle it; this is the playtest settling it. About sixty
lines of the core, the `ATTACH` message, the player-card verbs, the drop key,
the drone ring and `gunners.md`, all now deleted.

**The open arena.** Alpha, its sixty-four seats, its ten teams, its
`max_rooms` ladder and its fill target.

**Mode rotation**, before it was ever built.

**Points, bounty, rivets, the shop and the kit**, in that order over several
months. Points folded into bounty, then bounty and rivets folded into nothing
at all, and the kit they were spent on became seven preconstructed ships.

Nothing here is irreversible, and that is worth saying plainly: a zone is a
row in a catalog. If the open arena is ever wanted back, it comes back as
configuration rather than as an excavation.

## What this costs the framing

`CLAUDE.md` opens by calling vectorwake a top-down space MMO. After this it is
a session-based 4v4 match game that happens to be built on an MMO's
simulation. The fleet architecture stays exactly as it is and finally gets
the workload it was designed for, since rooms-on-demand in a long-lived
process is precisely what a three minute match game needs.

The word is the owner's to change, and the copy on the public site is
downstream of it. It is listed here so the decision is made deliberately
rather than discovered later.

## Order of work

Each step leaves a running game. The first five are done, for Melee.

1. **The match**: teams of four, a clock, an ending, a re-deal, an
   intermission. A room plays match after match and rebalances the sides
   during the podium, so five matches back to back cost nobody a keystroke.
   The number this exists to move is the median first-session career, three
   games when this was written.
2. **The roster**, and greens out. A spawn is dealt the ship its pilot picked,
   whole. The prize table, the pickup and the death drop are gone. This was
   built first as a thirty point kit with a shop selling slots for it, and
   rebuilt as seven preconstructed ships when the budget turned out to be what
   was forcing all seven onto one flight row.
3. **Maps.** Two pockets, point symmetry, two layouts, and the zone rotates
   between them.
4. **Charges.** Match-scoped counts, and the depth of each rack a fact about
   the hull.
5. **The podium's rating column**, which is what a match is worth now that
   nothing is paid.
6. **Parties** into a match. Not built. Friends was, and came out again per
   decision 95.

Turrets and gunners are gone, along with the open arena and mode rotation.

## Open questions

Whether a three minute match rates per kill, as today, or per match, since a
match result is a stronger signal than the correlated outcomes inside it.
Probably both, and probably worth measuring.

Whether seven ships that are genuinely different can be kept balanced. It is a
harder problem than seven silhouettes on one flight row, and `calibrate hulls`
exists so the answer is measured rather than argued.

How a party of three is seated against a fair opposing side, which is the
matchmaking question a party brings with it.

Whether three modes is two too many at this population. Settled by building
one: Melee ships alone, and Capture and Holdfast light when the crowd
justifies them. Modes divide a small crowd the way rooms do, and the sort
cannot help somebody who picked differently, so four people online across
three modes is four people alone. Adding a mode is a row in the catalog, and
that is the point of leaving it until there are people to divide.

What Capture and Holdfast actually are. Both are named and neither is
designed. Three modes is the launch set on purpose: a turf mode was cut
because several fixed points and one contested room collapse into the same
game at four a side on a small map, and the one room is the better version
because it forces contact. If a fourth is ever wanted, the one structural
axis nothing uses is an objective that moves.

What a new account has to look forward to, now that nothing accumulates but a
rating. The bet is that the rating and the ladder are enough, and that a game
worth playing does not need a drip. If it turns out not to be, the answer is
something worth earning that is not strength, because strength behind a price
is the thing that just came out.
