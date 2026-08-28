# The match game

> **The week's table is gone.** The standings tab came out of the client, so
> gripe 5 is answered outside the game again: the site publishes the ladder at
> `/pilots` and nothing inside a session ranks you. What still accumulates is
> the kit, the wallet and the rating. See
> [decision 65](../architecture/decisions.md).

> **Built, for Melee.** Everything below through the week is running: three
> minute matches with an intermission, the kit and the shop that sells slots
> for it, bounty paid as rivets, six match maps, and the six tabs. Capture and
> Holdfast are named here and not written; so are friends, parties and livery.
> Alpha did not survive this document, and greens, gunners and turrets went
> with it.
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

Around that sit three things:

- **A kit** you build and own, dealt to your hull at every spawn. Gripe 3.
- **Bounty** that starts at one and grows with your run, paid to whoever
  ends it. Gripes 1 and 6.
- **Rivets**, which are bounty taken, spent on what you may slot and on what
  you wear. Gripe 6.

Gripe 4 is answered by the match itself. A death still empties the hull, and
the hull refills from your kit at the next spawn, so what a death costs is
the seconds it takes to fly back. Nothing you built goes away, because you
own it.

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
is running you spawn into it with your own kit at bounty 1 and the score
standing; if the room is between matches you land on the podium and the next
one starts in a few seconds.

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

There are three ways to end up beside a person, and a player should be able to
name all of them: the mode list says where the humans are, the sort puts you
where they already are, and the friends panel joins one by name.

**Sitting out is a drop you chose**, and lands in the same place: a bot takes
the seat, you land in the stands, and the seat is yours to reclaim until the
match ends. A dropped socket and the lag ladder benching a bad connection
arrive there too, so three paths produce one state rather than three.
[spectating.md](spectating.md) has the gallery, including what happens to a
seat that frees while people are watching.

**The hull is locked for the match.** Kit and hull change in the hangar
between matches. This is not ceremony: charges
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

What the match paid is not on it. That was BANKED and a rivet in the corner,
and it reads better where the wallet already is: an ending is about the match,
and a running total belongs on the page that spends it. The film has no key either. A second key of equal
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

This is the load-bearing consequence of owning a kit, and it makes spawn
geometry the only thing pricing a death, so the maps carry the weight the
prize table used to.

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
offensively. Camping a spawn is
already close to worthless, because a pilot who has just died is worth one.

## Spray is one ladder

How many rounds a pull throws. Nothing is one; a rung is a round; the top is
six.

It was two add-ons. "Gun spray" opened a wide fan and charged energy and
cooldown; "gun double barrel" put a tight pair abreast and charged energy
alone. Both of them read, on the page that sells them, as *more bullets*, and
nobody could say what the difference bought. So they are one ladder and the
tradeoff moved: it is no longer which add-on but how many rounds, against
everything else thirty points could buy.

What survives of the difference is the spacing. One rung is the pair, and it
leaves at the tighter angle a pair is supposed to, so two abreast still read as
two abreast; three or more open out to the zone's fan. A pilot climbing the
ladder feels the group widen, which is the thing the second add-on was really
about.

Every rung costs energy and cooldown, at a quarter and a half of the shot's
own. That lands a spray of three exactly where the original priced multifire,
and the rest of the ladder climbs from there rather than from a number invented
for the top of it. What the merge cost, and what it bought, is [decision
54](../architecture/decisions.md#54-barrels-and-multifire-are-one-ladder-called-spray).

## Two charges, and which two is the choice

A kit carries two kinds of charge. Which two is a decision made on the ship
page, and which key spends which is decided there too.

Each charge row carries a box beside its pips reading "charge 1 (Q)" or
"charge 2 (W)", and pressing either one trades them. Before that the order was
the core's numbering of the kinds, which meant the lower-numbered kind took Q
whether the pilot wanted it there or not, and the only sign of it was a lone
letter at the far right edge of the page. What key throws what is a preference
about a keyboard rather than a fact about a ship, so it is kept on the device
beside the bindings and nothing about the kit changes when it moves.

Two kinds ship today, a repel and a burst, and the rack above the account's
two of each is what the shelf sells. The rack holds four, so a zone may write
more; the arena refuses a kit that names a third kind and the page will not
offer one, because carrying every kind at once would mean there was nothing to
decide.

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

A kill, and a rivet.

Killing yourself with your own bomb, or killing a wingman with it, takes one
off your kills and one off your wallet. The kill count goes under zero and is
meant to: clamping it at nothing makes the first mistake free and every one
after it visible, which is the wrong way round, and a pilot who has spent a
match bombing their own side should be able to read that off the card. The
wallet does not go under zero, because a negative score is a fact about a match
and a negative balance is a debt, and this game does not have those.

One rivet is not a fine calibrated against anything. A kill is worth dozens, so
this is the smallest amount a wallet can move by, and the point is that the
number goes the other way rather than that it hurts.

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
pocket to the other on each shipped file and flies the polyline at an Apex's
top speed with a kit that spends nothing on speed. Every map stays between
nine and seventeen and a half seconds of home-to-home flight. First contact
therefore lands inside the five-to-eight second design window when both sides
leave together.

## The kit

**A kit is thirty upgrades you choose, dealt to your hull at every spawn.**

Alpha deals thirty random greens to every fresh spawn today (`spawn_prizes =
30`). A kit is those same thirty, chosen once in the hangar instead of rolled
at the pad. Nothing is added to the ship, which is what keeps this cheap: the
sim already holds these as counts, the snapshot already carries them, and the
drill harness already measures matched thirty-upgrade kits.

The space is the one the tech tree already defines, and everything in it
costs exactly one:

| kind | ceiling |
|---|---|
| a step of a stat | eight useful steps on each of five ladders |
| a rung of a trigger's ladder | the arena's row |
| an add-on on a trigger | the arena's row |
| a charge carried | the arena's row |

**Two ceilings, and neither is the hull.** The arena says what it has; the
account says what it has bought; the smaller wins, inside the budget. There
used to be a third, a row per hull saying which add-ons that hull would hold
and how deep, and it is gone. It meant a pilot could buy an upgrade and then
find the ship they wanted to fly it on would not take it, and it meant four
traits could never be sold at all because they existed on one hull each. See
[ships.md](ships.md#the-tech-tree).

**Everyone deals thirty**, new pilot and veteran alike. A new account owns
three complete profiles: Gunner, Bomber and Control. Choosing one takes a
press; changing its slots makes a custom build, and that build can be saved
under a new profile name, renamed later, or dropped. The three the game ships
are not a pilot's to rename or drop, since those names are the code's.
Profiles are ordinary hull-independent kits, so there is no second balance
system hiding behind the convenience.

The old flight row clamped after seven Energy points, five Recharge, five
Speed, one Thrust and one Rotation. Hiding those dead points made the page
honest, but it also erased most of the flight build space. The row now gives
all five stats eight useful steps. The standard `5/4/5/2/2` allocation still
resolves to 1600 Energy, 1150 Recharge, 3250 Speed, 17 Thrust and 230 Rotation,
so the starter still flies the same. Moving away from it is the new choice.

The five ladders contain forty useful points against a budget of thirty. A
pilot may spend the whole kit on flight, with only the base gun and bomb, but
cannot maximize every stat. The starter spends eighteen on flight and leaves
twelve for weapons and charges. Each extra pip therefore has both a physical
effect and a visible opportunity cost.

**Death re-deals the frame, never the ammunition.** Stats, rungs and add-ons
come back at every spawn, because they are what your ship is. Charge counts
do not: you start a match with the charges your kit slotted, and when they
are gone they are gone until the next match.

That rule earns its place twice. It closes an exploit, since a refill on
death means a pilot out of repels can suicide into the nearest enemy to
reload, and at a bounty of one that costs nothing. And it turns one kit slot
into a three minute budget rather than a per-life allowance: spend both
repels in the opening joust and you fly the last minute with no way out of a
corner.

The corner stack already draws spent charges as empty rings. It needs no
change, it just stops refilling.

## Bounty, and rivets

**Bounty starts at one and rises by one for every kill. Your killer takes it,
as rivets. Dying puts you back to one.**

So a pilot's bounty is the length of their current run, and the number over a
ship says exactly how good a prize it is. A fresh spawn is worth one, which
is the anti-farming property `bounty.md` prizes, arrived at by arithmetic a
player can do in their head rather than by a rule about camping.

This collapses two numbers into one. There is no separate score banked into a
separate wallet: rivets are what killing pays, they arrive at the kill, and
nothing takes them back. `sim_bounty` stops being a sum over held counts and
becomes a counter the server owns.

**Objectives raise your bounty rather than paying around it.** In a mode with
a flag, carrying it makes you worth more while you hold it, and capping banks
it. A flag runner should be the most valuable thing on the field, and this is
the way to say so without inventing a second currency for objective play.

**The ending always pays a participant.** Thirty seconds in the match earns
five rivets at the whistle. Winning adds three, and each assist adds one up to
five. Bounty still pays continuously. The completion grant means a first
session advances before its first kill; the win and assist pieces reward
helping the side; the time floor keeps the closing seconds from becoming a
login bonus.

Every price in the shop is denominated in this, which means prices are tens
rather than thousands. A match pays a pilot something in the low tens.

## Kill streaks

**Three kills without dying is a streak. The room is told, the hull is marked,
and the pilot is worth two more until somebody takes them.**

A run is already priced, one point a kill, and that is a slope: at three kills
a pilot is worth four rather than one, and nobody in the room has been told
anything. What the slope cannot do is name a moment. A streak is a step, and a
step is what a room can react to.

So three kills is a threshold rather than a curve. It is the shortest run that
cannot be luck and it is reachable inside a three minute match, which are the
two things the number has to be at once. Counted in kills rather than in
bounty, so a zone that decides a kill pays three has not thereby decided a
streak starts at one.

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

**And two more bounty.** The step has to move the price by more than one more
kill would, or the bonus says nothing the run was not already saying. Two is
that: a pilot three kills into a run jumps from four to six, and the pilot who
ends the run is paid for having ended it rather than merely for a kill.

All four are after the thing `bounty.md` asks for: the pilot who is winning
should be the pilot everybody else is hunting. Bounty said it quietly, in a
figure over a hull that you had to be close enough to read. This says it across
the room.

## What rivets buy

**Slots, and looks. Never strength.** Everything trades against the same
thirty. The profile harness declares ten comparisons among legal 30-point
builds: one matched margin for each stat beside the starter allocation and one
matched seventh-to-eighth margin for each stat.
Every stat margin spends its last point on that pip or the same bomb-bounce pip,
so it asks about one price instead of a bundle. Fixed bots and controllers play
mirrored four-a-side matches for the full 180 seconds, with seeds spread evenly
over the six Melee maps and seven cyclic lineups. Every hull occupies four
lineup seats per cycle. Each declared contrast has a conservative approximate
family-wise 95% paired t interval and a verdict against the 45 to 55 band. The
fifteen-comparison planning bound needs 3,384 pairs for the stated 90% power
target under worst-case paired variance. The frozen screen rounds that minimum
to 3,402, or 81 complete map-by-lineup blocks. Other sample counts are
exploratory. The powered seed stream belongs
to one preregistered attempt for an exact content and analysis fingerprint, so
tuning cannot reuse the confirmatory evidence. Every map and build pair must
also clear fixed activity and mirrored sensitivity gates. A gross observed
side gap is reported as a warning rather than a blocker because the estimator
averages both side assignments. None of those diagnostics is a powered
side-equivalence claim. Kill intervals are descriptive.

That experiment estimates the ten marginal-pip questions
under its bot, controller, map and match fixture. It does not establish that
every legal kit is balanced, nor does it measure fun or perceived fairness for
people.

- **Add-ons and rungs** the arena allows but your account has not bought. Those
  are the purchasable combat upgrades. First the roster held several of them:
  the second barrel, the third bomb rung and the deepest rung of shrapnel were
  one hull's each, and nothing can be sold that exists on one hull.
  A new account owns the three starter profiles, every stat step and the
  established second gun and spray rungs used by saved remixes. The shop begins
  beyond that base equipment envelope, where deeper weapons, add-ons and racks
  create specialization rather than basic competitiveness.
- **Deeper racks.** Two repels and two bursts support the starters, against
  the three the arena allows, so the last rung of each is bought.
- **Charge kinds** beyond those two.
- **Livery.** Decoration, under the art direction's law: hull paint is the
  team read and weapon hues are semantic bands, so livery lives on the wake,
  the nameplate badge and the podium card. You should recognize a pilot by
  their wake before you read the name.
- **A name of your own**, eventually. Not now, and worth writing down: a name
  bought with earned rivets costs time, which makes a throwaway offensive
  name expensive and a ban something that actually takes something. Freeform
  names need review whatever they cost, so the cheap version builds from the
  call sign generator's word pool and the expensive one is freeform behind
  the admin panel's rename tooling. It also needs a reserved list, because
  the tier names and the team names are words that must not become people.

The two pages divide by ownership. The ship page carries what this account can
actually fly, and nothing else: a ladder stops at the rung you own, and a slot
you own none of has no row. It used to draw the arena's whole row with the
rest locked, so the page could say "this exists and is not yours", and what
that produced was four unreachable chips in every group, backed off far enough
to be unreadable and still taking the room a legible one would have.

The page listing all of it shows every slot the game has, not what is left to
buy. A list of what is for sale shrinks as a pilot gets stronger, and the last
purchase in a ladder takes the whole ladder off the page that was selling it:
a shop that empties as you succeed cannot say what you have. So a row carries
the ladder with the rungs you own filled in, the rungs you do not left hollow,
and what everybody is dealt drawn as a bar rather than as rungs, since nobody
bought those and nobody can. Buying is watching a hollow rung fill.

`/v1/upgrades` is where that comes from. Its ceiling is built from the game the
pilot selected, through the same config path as a live room, so a narrowed
zone cannot leave an unusable slot on the shelf. Bots read the same reply: a
row with no price on it is a slot with nothing left to sell, and they skip it.
Inside a mixed room, a bot's usable ceiling is also clamped slot by slot to
what every human there owns. Bot careers still progress in bot-only play, but
a veteran machine cannot turn a new pilot's first match into a gear check.
See [ai-players.md](ai-players.md).

## Charges

Two slots to start, four in the core (`SIM_MAX_CHARGES`). Two repels and two
bursts are in the starter union, against the three of each the arena allows;
the last rung of both racks, and every other kind, are bought.

## Friends

The one genuinely new system here, and the one most likely to move the number
this document opens with. People stay for people.

Built. [friends.md](friends.md) is the design and the reasoning; the short
version is that version one is the three things asked for here and nothing
else: add somebody mutually, see which friends are on and what they are in,
and join them.

Two things landed differently from the sketch this section used to carry.
Presence comes from the meta-layer rather than the directory, because the
meta-layer already holds a row per flying pilot: an arena claims one to make a
rated seat exclusive, so the presence table exists and is kept honest by the
thing that most wants it right. And there is no invite, because there is
nothing to accept: one row per direction, and the friendship is the pair.

No chat, per `decision 28`. Discord carries the talking, per `community.md`,
reached from the site rather than from the game, and with nothing to say to
anybody there is nearly nothing to moderate: what one stranger can do to
another is appear on a list.

The part that is still real work is seating a party together on one side of a
filling match, which is matchmaking logic that does not exist yet. Friends
gets two people into the same room without touching it.

## Dropping mid-match

**A bot takes the seat, in place.** Same hull, same kit, the charge ledger as
the leaver left it. The match stays four a side.

The seat is what persists, so there is no reconnect timer to tune: come back
any time before the final whistle and you take your ship back from the bot.
Come back after it and you land on the podium with whatever you banked.

Forfeiting is right for a game where your absence only hurts you, and wrong
here, where it would punish three teammates for a fourth person's wifi.
Substitution punishes nobody.

Three rules compose:

- **Rating** settles at the socket exactly as it does today, so a drop in the
  middle of a losing fight is a death on your record. From there the seat
  flies **unrated**, which keeps a bot's career clean of inherited doomed
  hulls and closes any angle where farming a substitute pays.
- **Rivets** already earned are yours, because bounty pays at the kill. What
  you forfeit is the ending. Enemies who kill the substitute take its bounty
  as usual, because the ship on the field is real even if the rating book is
  not watching.
- **The lag ladder** feeds the same path. A connection bad enough to bench
  becomes an early substitution rather than a weaponless ship drifting while
  its team plays three against four.

No penalty box beyond the forfeited bonuses. The tactical dodge is already
priced, the social damage is already absorbed, and a game this size does not
need one. The pilot log should count leaves so the question can be answered
with a number later.

## The menu, and where the screens live

The home experience stops being a menu. The ship page is a screen with panes
and grids, and the menu tree was deliberately one narrow column that
[menu.md](menu.md) says "falls apart at 390 points wide". So there are two
surfaces now rather than one:

- **Five tabs** at the front end, which is where you are between matches and
  where there is time to read: play, ship, friends, pilot, settings. Pilot is
  your account, and your call sign at the far end of the row opens the same
  page. Standings was one of
  them until the week's table came out. Upgrades was another for a while,
  drawing the same slots in the same order for the
  other question; the ship page is the shelf now, with the price of the next
  rung on the row that spends the point and the wallet on the reading that
  row opens. The old worry, a wallet and a budget on one screen with "spend"
  meaning both, is answered by shape: points are circles, prices wear the
  rivet mark, and nothing is bought except on the reading. See
  [menu.md](menu.md) and [decision 64](../architecture/decisions.md).
- **Three tabs in a match**: play, friends and settings. Same row in the same
  place, carrying what you can act on from a cockpit. It was two, settings and
  leave; the games list is on it now because the way out of the game you are
  in is a button on that game's own row, and the hangar stays off it because a
  hull is locked for the match.

Settings holds everything that is about the machine rather than about a
match, in one column: audio, video, the control bindings, and about. Help
folds into it rather than standing beside it, because the controls board and
the rebinding screen were always the same list read two ways, and `about` is
three lines that never deserved a destination.

Pilot is the one tab about you rather than about a match: your call sign and
its reroll, whether the account is claimed, your career, the hulls you fly and
what you are wearing. It is also where a bought name lands, which is the
moderation argument as much as the vanity one. A call sign that cost six
hundred rivets is a name a ban actually takes something from, and rivets are
earned by flying rather than bought with money, so the cost is time.

**It is one surface, and in a match it carries three tabs: play, friends and
settings.** Same chrome as the front end, full screen, with the tab row on top;
what differs is which tabs are on it, not how any of it looks or works. That
is the point. A player learns one screen and meets it in both places.

Discord is not a tab, or a button, or a page. It is not in the game at all,
per `decision 73`: the site carries the link and the client carries no way out
to it. [community.md](community.md) has the rest of that argument; what
matters here is that the game carries no chat and does not point at the room
that does.

Nothing you cannot act on right now is on that row, which follows from a rule
[menu.md](menu.md) already has and is proud of: nothing pauses, you can be
shot while reading, and opening a menu is a risk rather than a timeout. In a
three minute match a menu deep enough to browse a shop in costs a real
fraction of the match.

It stays a menu rather than a bare leave button for one reason that does not
show up on a desktop. On a phone this is the only route to sound, to
fullscreen and to the controls reference, and a leave button alone would
strand a player who needs to mute the game.

**The match shows through it.** A scrim rather than a curtain, and the topbar
carries the score and the clock where the front end carries your call sign and
your wallet, so the right-hand slot always answers "how are you doing in the
thing you are in". Hiding the fight would be a lie about what is happening,
which is the same reason the interface stays up today.

None of this needs a new mechanism. `menu.home` already builds rows from the
moment rather than declaring them, which is how the leave button appears on a
game's row only while you are flying that game. The ship page is the same
conditional in the other direction.

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

Two consequences for [menu.md](menu.md). Changing hull is a respawn today and
becomes a front-end action, because the hull is locked for the match. And the
games list stops being a menu node, because picking a mode is a screen now.

## The week

Rating answers "how good am I" on a career scale and moves slowly. The week
is the short ladder beside it: kills, deaths, the ratio, the best run anybody
ended, what the week's bounties banked, and how long each pilot was actually
in a room. It resets Monday 00:00 UTC, with livery paid to the top of a
closing week.

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
death drop, the spawn deal. What survives is the upgrade *space*, which is
the kit's coordinate system. This is a deletion of the delivery mechanism,
not of the state, which is why it is cheap.

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

**Points as a separate number**, folded into bounty.

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
2. **The kit**, and greens out. A spawn is dealt the thirty its pilot chose,
   or the starter kit the core works out for the hull when they have chosen
   nothing. The prize table, the pickup and the death drop are gone.
3. **Bounty and rivets.** One counter, one wallet, prices in tens. Kill bounty
   and the completion, win and assist grant are banked from the pilot log. Its
   unique event index makes an at-least-once delivery pay once.
4. **Maps.** Two pockets, point symmetry, two layouts, and the zone rotates
   between them.
5. **Charges.** Match-scoped counts, and the shop selling the rungs of a rack
   above what an account is dealt.
6. **Friends**, and parties into a match. Not built.

Turrets and gunners are gone, along with the open arena and mode rotation.

## Open questions

Whether a three minute match rates per kill, as today, or per match, since a
match result is a stronger signal than the correlated outcomes inside it.
Probably both, and probably worth measuring.

Whether the kit budget starts at thirty or climbs to it over a first few
matches. Climbing gives a new account something to feel; starting flat is
honest and keeps every match matched.

How a party of three is seated against a fair opposing side, which is the
matchmaking question friends brings with it.

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

Every price, which no harness can measure.

The name "rivets", which is a proposal in the house register rather than an
attachment.
