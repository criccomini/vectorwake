# The match game

> **Built, for Melee.** Everything below through the week is running: three
> minute matches with an intermission, the kit and the shop that sells slots
> for it, bounty paid as rivets, two match maps, and the six tabs. Capture and
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

Around that sit four things:

- **A kit** you build and own, dealt to your hull at every spawn. Gripe 3.
- **Bounty** that starts at one and grows with your run, paid to whoever
  ends it. Gripes 1 and 6.
- **Rivets**, which are bounty taken, spent on what you may slot and on what
  you wear. Gripe 6.
- **The week**, a standings table that resets on Monday. Gripe 5.

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
match with the intermission between them, which is the arrangement
[duel-mode.md](duel-mode.md) already describes: the server stays alive between
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

**The hull is locked for the match**, the way a duel already locks it. Kit
and hull change in the hangar between matches. This is not ceremony: charges
are match-scoped below, and a mid-match hull change would have to answer what
happens to a half-spent charge ledger across two different charge rows. The
honest answer is to not let the question exist.

**The ending is a podium and a payday**, and the intermission is where the
hangar is one key away. The card leads with the scoreline, set large with the
split of the match drawn between the two figures, because that is the one thing
anybody wants off it in the first half second; the rosters are underneath for
whoever reads further. The last five seconds are counted out loud, one pip a
second and a different sound at nought, since a pilot picking a hull is not
looking at the clock.

**And six things a player can say**, off chips at the foot of the card: "gg",
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

**No safe zones in a home pocket.** The duel design's no-hiding rule applies
to anything played against a clock: a safe pocket is where a leading team
goes to stall. Respawn invulnerability stays as duels specify it, long enough
to orient and short enough to be useless offensively. Camping a spawn is
already close to worthless, because a pilot who has just died is worth one.

## Two charges, and which two is the choice

A kit carries two kinds of charge. Which two is a decision made on the ship
page, and Q and W spend them in the order the core numbers the kinds.

There are three kinds today and the shelf sells them: a repel and a burst come
with the account, and mines are bought. Carrying all of them at once would mean
there was nothing to decide, so the arena refuses a kit that names a third and
the page will not offer one. Taking one off to fit another is the whole of the
interaction.

That is also what the mine key was in the way of. Mines used to sit on Shift
and the bomb trigger, then on a key of their own, which is a key that does
nothing on a ship carrying no mines and a row on the controls page describing a
weapon most pilots have never bought. What a key spends is a slot; what a slot
holds is the pilot's business. So the two keys are named for their positions,
the corner stack says what is in each while you fly, and the ship page says
which key each row landed on.

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

`sim/tools/mapgen --match` draws them. Two are shipped and the zone rotates
between them: **drydock**, pockets north and south with three lanes and a
room in the middle worth fighting through, and **slipway**, pockets at
opposite corners with a lattice down the diagonal, so the short way is the
dangerous one. Both are point symmetric by construction, since the generator
draws one half and `sym_put` turns it, and both are checked for a connected
arena and a cover density between four and sixteen percent before they are
written.

The flight time between the homes is held by a test rather than by a comment.
`the_melee_maps_are_two_homes_with_ground_between_them` routes a hull from one
pocket to the other on the shipped file and flies the polyline at an Apex's
top speed with a kit that spends nothing on speed, which puts both maps at
about nine and a half seconds and first contact a hair under five. It caught
the pockets being moved in for the camera's sake: at twenty seven tiles from
the wall drydock came in under the floor, and twenty two is where the two
constraints meet.

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
| a step of a stat | six over five stats, and eight once bought |
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

**Everyone deals thirty**, new pilot and veteran alike. A new account gets a
sensible starter kit, worth the same thirty. What rivets buy is *which*
upgrades you may slot, never how many.

**Six a stat is exactly the budget**, and that is the reason for the number.
Five stats at six steps is thirty, so a pilot can take every stat to its base
ceiling and own nothing else: no charges, base rungs, no add-ons. It is a
legibly poor ship and a useful one to be able to build, because it turns
thirty from an allowance into a landmark. Every other kit reads as a trade
away from a reference point rather than as an arbitrary allocation.

**The last two steps of each stat are the shop's**, up to the eight the core
allows. That is a purchase worth being suspicious of, since this document's
one rule is that nothing persistent makes a ship stronger, and buying the
right to concentrate looks like buying power.

Two things answer it. Reaching the eighth step still costs two of the same
thirty, so depth buys permission to spend in one place rather than more to
spend. And five stats at eight is forty against a budget of thirty, so no
amount of buying ever makes the kit stop being a set of tradeoffs: the
ceiling being bought toward is unreachable by construction.

It is still a measurement rather than an argument. The drill runs a
concentrated kit against a spread one of the same thirty, on two hulls, and
the 45 to 55 band decides. Depth is the item in this document most likely to
fail that test.

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

**The ending pays a little.** A win, a podium place and the first win of a
day are small flat bonuses. Small because kills already pay continuously and
the bonuses exist to make the ending feel like an ending; nonzero because a
mode where only kills pay is a mode where nobody contests the objective.

Every price in the shop is denominated in this, which means prices are tens
rather than thousands. A match pays a pilot something in the low tens.

## What rivets buy

**Slots, and looks. Never strength.** Everything trades against the same
thirty, and the drill harness is the referee: anything that wins more than
55% of matched bouts against the bare kit, on at least two hulls, goes back
to the bench.

- **Depth on a stat**, its seventh and eighth step.
- **Add-ons and rungs** the arena allows but your account has not bought. That
  is all of them now, which it was not twice over. First the roster held them:
  barrels, the third bomb rung, the deepest rung of shrapnel and the mine
  count were one hull's each, and nothing can be sold that exists on one hull.
  Then the entitlements did: an account arrived owning one rung of every
  add-on, so the four whose arena ceiling is also one were free, complete and
  absent from the shelf forever. Nobody arrives with an add-on now.
- **Deeper racks.** One repel and one burst is what an account starts with,
  against the three the arena allows, so the other two rungs of each are
  bought. They used to be granted without limit, which meant neither was ever
  for sale.
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

`/v1/upgrades` is where that comes from, and the bots read the same reply: a
row with no price on it is a slot with nothing left to sell, and they skip it.
See [ai-players.md](ai-players.md).

## Charges

Two slots to start, four in the core (`SIM_MAX_CHARGES`). One repel and one
burst is what an account begins with, against the three of each the arena
allows; the rest of both racks, and every other kind, are bought.

**A mine is a charge.** It was the bomb trigger's other posture, limited by how
many of yours were already lying about. As a charge it is a count you carry and
spend, which is what the kit makes coherent: how many mines you bring is a
loadout decision priced against everything else, and fitting them means taking
a repel or a burst off, because a kit carries two kinds.

Two changes ride along. A mine currently wears its layer's bomb rung, and a
charge fires one pattern that means the same thing to everybody, so mines
standardize. And the mining role stops belonging to a hull. Six mines was the
Lattice's row, which was exactly the shape of problem this whole space was
flattened to fix: six is the arena's ceiling now, the kind is a purchase, and
whoever is willing to spend a fifth of their kit on mines is the miner.
`mine_max` went with the Shift+Tab chord and its touch cell, and so, in the
end, did the key of its own that replaced them.

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

No chat, per `decision 28`. Discord carries the talking, per
`community.md`, and with nothing to say to anybody there is nearly nothing to
moderate: what one stranger can do to another is appear on a list.

The part that is still real work is seating a party together on one side of a
filling match, which is matchmaking logic that does not exist yet. Friends
gets two people into the same room without touching it.

## Dropping mid-match

**A bot takes the seat, in place.** Same hull, same kit, the charge ledger as
the leaver left it. The match stays four a side.

The seat is what persists, so there is no reconnect timer to tune: come back
any time before the final whistle and you take your ship back from the bot.
Come back after it and you land on the podium with whatever you banked.

Forfeiting is right for a duel, where your absence only hurts you, and wrong
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

The home experience stops being a menu. Ship and standings are screens with
panes and grids, and the menu tree was deliberately one narrow column that
[menu.md](menu.md) says "falls apart at 390 points wide". So there are two
surfaces now rather than one:

- **Six tabs** at the front end, which is where you are between matches and
  where there is time to read: play, ship, upgrades, friends, standings,
  settings. Your call sign at the far end of the row is the way into your
  account. Upgrades and the ship page were one panel for a while, with the
  price of each rung written on the row that spends it, and what that produced
  was a wallet and a budget on one screen with the word "spend" meaning both.
  They are two questions asked at different times. See [menu.md](menu.md).
- **Two tabs in a match**: settings and leave. Same row in the same place,
  carrying what you can act on from a cockpit.

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

**It is one surface, and in a match it carries two tabs: settings and
leave.** Same chrome as the front end, full screen, with the tab row on top;
what differs is which tabs are on it, not how any of it looks or works. That
is the point. A player learns one screen and meets it in both places.

Discord is not a tab. It sits in the friends panel on the play screen,
which is where somebody is already thinking about who to play with, and it is
the only outbound link in the game. [community.md](community.md) has the rest
of that argument; what matters here is that the game carries no chat and the
friends panel is honest about where the talking happens.

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
moment rather than declaring them, which is how the `leave` row appears only
when there is something to leave. Ship, upgrades and standings are the same
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

Every screen at the front end is the same shape, so the ship page and the
standings inherit this rather than each inventing a focus order. The one
thing it costs is that a page needs a first row and a last row that are
obvious, which is a layout constraint worth having anyway.

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
process is precisely what a three minute match game needs, and it is the
model `duel-mode.md` already describes.

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
3. **Bounty and rivets.** One counter, one wallet, prices in tens. Rivets are
   banked from the kill rows the pilot log already carries, and the unique
   index on those rows is what makes an at-least-once delivery pay once.
4. **Maps.** Two pockets, point symmetry, two layouts, and the zone rotates
   between them.
5. **Charges.** Mines as one, match-scoped counts, and the shop selling the
   kinds beyond repel and burst.
6. **Friends**, and parties into a match. Not built.

Turrets and gunners are gone, along with the open arena and mode rotation.

## Open questions

Whether a three minute match rates per kill, as today, or per match, as
`duel-mode.md` argues for a result that is stronger than the correlated
outcomes inside it. Probably both, and probably worth measuring.

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
