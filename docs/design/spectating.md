# Spectating

A watcher is a connection with a seat in the roster and no ship in the
simulation. The core never learns spectating exists: `sim_state` has no field
for it, a watcher is a socket that receives snapshots and sends no inputs, and
moving between watching and flying is a despawn and a spawn on the same
socket, not a reconnect. That much was designed in
[zones-and-arenas.md](../architecture/zones-and-arenas.md) before any of it was
built. What the build had to add was an answer to a question the sketch never
faced: who may see what, live.

## The rule

One feed. Everybody watching a room sees the same frames, centered on a subject
the server picks, five seconds late. There is no second way to watch, and that
is the whole security model.

**Shared is what defeats re-rolling.** One feed per room, identical bytes to
every watcher on it. Reconnecting lands you on the same channel everyone else
is watching, so there is no pulling the lever until your victim comes up. A
per-watcher random pick would die to exactly that: watcher joins cost nothing
and guests are free, so a room of nine humans falls to the intended victim
inside nine rejoins.

**The delay is what makes the frame that does show a stranger film rather than
targeting data.** Five seconds, everywhere. A bound radius can afford a short
delay and still feel live, which the whole-room delayed stream this replaced
never could, because full positions only seconds old are still a map of the
room. Kills ride the ring with the frame they belong to, or the feed would
announce a death the delayed picture has not shown yet.

**The delay is on the whole broadcast rather than on the picture alone.** The
clock, the score, the banner, the scoreboard and the ground ride the ring
beside the frame they belong to. Sent live they described a room five seconds
ahead of the one on screen: a match's last five seconds ticked away over ships
still fighting, and the death that settled it arrived under a clock already
counting the next match down. The ground was the worse half of it. A
whistle changes the map and bumps the settings generation, and a client refuses
a frame whose generation is not the one it holds, so every frame still in the
ring at a rotation was thrown away and the stands went blank for the whole
delay. What a side is called and which of its doors are open stays live: that
describes the room rather than the moment.

It was a zone's number for a while, `channel_delay_ticks`, five seconds by
default and zero in the ladder zone on the reasoning that there the audience
is the mode and both pilots are equally exposed. A dial whose interesting
setting is off is a way to ship the protection turned off by accident, in a
file nobody reads twice, and the zone that wanted zero wanted an audience
rather than a fresh map of a live room. The audience is what it still gets.
Five seconds is a constant in the server now and there is nothing in a zone
file to set.

**There is no live view of any hull, for anybody.** Following your victim puts
a camera on the one hull the fog is supposed to hide, with its movement and
surroundings always centered on screen, so a hostile ask was never granted:
it landed on the channel. Two lawful follows did exist beside it. A watcher
could ride a teammate live, on the reasoning that a teammate's screen is
knowledge the side already has and shares over voice every day; and the
`watch` capability in the catalog's staff list granted live sight of anybody
to a named account.

Both are gone, and the argument for the teammate case was never the problem.
The cost was: a second way to be a watcher, a stream packed per follower
beside the shared one, a sight check on every frame in case the followed hull
crossed sides, a control in the info box, a camera walk on the arrow keys, a
tap target on each half of a phone screen, and a ship byte on the wire. All of
it to serve, live, a fight the channel already shows. Every one of those is
also somewhere a room can start leaking, and none of them can leak now,
because the mode they belonged to does not exist.

What that costs is worth stating plainly. A pilot who sat out, or whom the lag
ladder benched, watches their own side five seconds late along with everybody
else, and cannot choose to watch them at all. In a four a side match that is
somebody's own game being played back at them a beat behind.

**An operator watches what the room watches.** The `watch` capability is gone
with the follow it granted, and nothing in the shipped catalog held it. The
admin surface wanted a way in here to see a game rather than a number, which
the channel gives it.

**The subject is told, when somebody is actually looking.** The tally means a
person is seeing you, not that a camera is pointed at you, and those are two
different facts here. The channel picks a subject and fills its ring whether
or not anybody is on it, so an arriving watcher lands in a warm picture rather
than staring at the delay; and the channel runs behind, so a pilot the camera
has just landed on is seconds away from being shown. So `S2C_ONAIR` is derived
from the audience: the frame going out is centered on you, and there is at
least one person in the stands to see it. Edges only, recomputed every
snapshot.

It is a red tally beside the MENU key, swelling slowly rather
than blinking, since it has to hold attention for minutes and a blink that
long is something a player stops seeing. Two minutes on air is something a
pilot can play around, and only if they know.

Everybody watching is named in the roster, staff included, which is what makes
the tally worth reading: the room can see who is in the stands and the subject
can see that the camera is on them. Covert observation is the invisibility
capability, and when it arrives it should take the roster row and the tally
together rather than half of each.

It sat at the top of the middle first, and could not stay: that strip carries
the flag marks and the round's banner, both centered, and a notice laid over
them read as a fault in the flags rather than as a fact about you. Those are
about the round; this is about you, like the keys it now sits with. Being on
that row also means the map opening across the corner keeps clear of it under
the rule that already keeps it clear of the keys.

## What a watcher receives

The channel is packed once per snapshot tick and fanned out, so its cost is
flat in CPU however many watch. Only one field differs between the copies: the
lifecycle, which says which of a socket's lives the frame belongs to. The ring
runs whether anybody is on the channel or not, so an arriving watcher lands in
a warm picture instead of staring at the delay's worth of nothing. An empty
room points the camera at the middle of the map, and the picker prefers live
humans, because a random camera in a bot-filled room is a bot documentary five
frames out of six. The heat-scored director can replace the picker later
without touching the wire.

The frame is packed at the subject's hull with the human interest radius,
whatever that hull's own stream gets. That last clause is not pedantry: the
camera lands on bots, a declared bot is sent radius -1 and the whole prize
table, and a channel that inherited it would hold sight no human lawfully has.
A server test compares the packed body byte for byte against a fresh
human-radius pack at the subject's coordinates, so the day the two diverge,
the mode has started leaking and CI says so.

## What a watcher is, to the room

Nothing the room polices. The human cap, the fill target, the bot ballast and
the drain all read `players`, and a watcher is not in it, so `max_watchers` is
its own dial: a bandwidth number, eight by default, because a watcher is zero
tick time and a full player's egress, and egress is the fleet's whole bill.
Both a client that arrives watching and a pilot who voluntarily sits out take
one of those slots; a full gallery leaves the pilot in their hull.

They are in the roster, though, by name, in a second section after the ships.
The roster exists so you know who is in the room with you, and an unnamed
watcher is precisely the scout the sight rules price. Invisibility is a staff
capability someday; it is not a default.

A drain refuses new watchers with the players and drops the ones it has once
the last player leaves. And a watcher's socket sends no inputs, so it repeats
its watch ask every thirty seconds as a keepalive; the ask is idempotent and
the simulation does not move for it, which a test pins by hashing the state
across one.

## The client's second life

The welcome byte is the switch: a ship number is flying, 255 is watching, and
sitting out or taking a hull again arrives as a fresh welcome on the same
socket. The watcher client keeps stepping the core every tick with empty
inputs, because `sim.replay` is the step in this client and a watcher that
stopped stepping froze the room into a snapshot-rate slideshow; stepped with
no buttons, the room coasts exactly the way remote hulls already do, and every
snapshot corrects it. No input log, no rollback, no clock steering. The
snapshot's subject byte drives the camera, the terrain window follows the
camera as it always did, and a view switch gets the reconnect treatment,
since a channel frame can move the tick backwards across the delay.

The hull's furniture comes off: corner stack, charge cells, trigger pads, the
DESTROYED card. The room's instruments stay. Exact vitals are drawn for
same-side subjects only; the wire carries them regardless, but wire-reading is
the modified-client tier, and the interface should not hand the number to the
two-tab tier.

Nothing on the pad or the keyboard aims the camera, because the camera is not
this client's to aim. The arrows used to walk it along the occupied seats and
a tap on either half of a phone screen did the same; both are gone, along with
the WATCH key the info box used to carry on a teammate. Nothing is left in
their place. A green play mark and the word CHANNEL sat in the corner row for
a while, in the slot the on-air tally uses, on the argument that a watcher is
never on air and the two are the same kind of fact about the connection. They
are not the same kind of fact. The tally is a warning, because being on air
changes how you fly; a watcher being a watcher changes nothing, and every hull
on screen wears somebody else's call sign while none wears yours, which says
it already.

The team list goes to watchers too: their side, and no open doors, because a
watcher crosses nothing until they take a hull again.

Every watcher has a side, including somebody who never flew here. They are
seated at the door by the rule that seats a pilot, on the emptiest of the
zone's own sides, because watching is a way of being in this room rather than
a lobby beside it. The first cut handed an arrival nothing, on the reasoning that they
had sat out from nowhere, and what that produced in Alpha was a spectator
alone off the edge of a ten-team zone, with every hull on screen drawn as an
enemy's, while the same person joining in a hull and then sitting out kept
their side and everything that came with it.

A watcher weighs nothing while they sit there, since they hold no seat, so the
balance the caps measure cannot see them. Room is checked when they fly, which
is the moment it starts to mean anything, and the side they watched with goes
in as a preference rather than being re-picked from scratch: it was theirs the
whole time they were watching. It is a preference and not a demand, so a side
that took on its last permitted pilot while they sat there puts them somewhere
else instead of holding them in the gallery.

The exception is a free-for-all, where the answer really is none. Every pilot
is a private side of one, so there is no side for an arrival to share and the
channel is the whole of what anybody watching can see.

And the screen is colored from that side rather than from the subject's.
Deriving it from the hull the camera is behind is the obvious reading and the
wrong one, because the camera moves: it repainted your own side as hostile
whenever the channel crossed the line.

The pilot being observed wears their call sign at their
hull's lower right, exactly as every other pilot on screen does, because the
one hull that goes unlabeled is your own and a watcher has none. That is the
answer to the only question a spectator has constantly, and it belongs on the
hull rather than in a caption at the foot of the screen.

## The stands are the front end

Everything below was written about a mode a player chooses. It is the first
thing that happens now: opening the client seats you in the stands of the game
you were in last, and the front end is the watcher's screen with the menu's
column over its foot. There is no second screen to be on, so a watcher who has
just opened the client and a pilot the whistle benched are looking at the same
thing. See [decision 61](../architecture/decisions.md),
[decision 153](../architecture/decisions.md) and
[menu.md](menu.md#opening-the-client).

Nothing in the rule above changes, which is the point of writing it down as a
rule. A visitor gets the room channel, five seconds behind, exactly as anybody
watching does; they are named in the roster like anybody watching; and the seat
they take when they press the key is dealt on the side they were watching with,
because they were in the room the whole time.

What does change is the volume. Every page load is now a watcher, so
`max_watchers` is the front door's capacity rather than a gallery's, and the
count that used to describe a handful of interested people now describes
everybody who has opened the site. Two consequences are accepted rather than
fixed. A room fills its watcher slots before its seats, which arena servers
answer by opening rooms as they fill. And the roster carries a row for every
drive-by, so a pilot is on air more of the time than the tally was designed
for: that dilutes what it says, and the alternative is an unnamed watcher,
which is the second kind of watcher this design spent real effort deleting.

## Where the door is

Spectating is a hull you can be in, so it is the eighth cell of the ship page.
Picking a hull is already how a pilot says what they want to be, and "nothing,
I am watching" is an answer to that question rather than a separate act. The
cell draws the pilot helmet instead of a ship, since it is about the person
and not about anything they are flying, and it wears the same "you are here"
wash the hull you are flying wears. Going back is any of the other seven
cells, which is the same page and the same press; a room that filled while you
sat out refuses, and the refusal is staying exactly where you are.

On the home screen too, where the page answers a different tense: not what you
are, which is nothing, but what you will arrive as. Arriving to watch is a
thing the wire has always been able to say and the client simply never said,
so picking the cell there sets the join's watch flag rather than waiting for a
game to exist. It is remembered like the hull is, because it is an answer to
the same question, and picking any of the other seven is what takes it back.

The cell was briefly hidden at home, on the grounds that it did nothing there.
That was the wrong repair: it did nothing because the join never carried the
choice, and hiding it made the page mean two different things on two screens.

Touch gets it on the same terms, because the page is one grid at every size.
Two columns on a phone held upright make four rows and the whole page still
fits. Four across a phone held sideways make two rows, with room left for the
kit below.

It briefly lived as a third answer on the games-list card that asks whether
you meant to leave. That card is about the game you are in, and what you are
flying is a different question, so it is back to two answers.

The player list carries the gallery under the pilots: no seat, no score, the
word "watching" where the numbers would be, and a count of its own
in the line under the board. The roster exists so you know who is in the room
with you, and somebody watching the fight is in the room.

## In a match game

[match-game.md](match-game.md) changes what this is for without changing the
rule above, which is the good news and worth stating plainly: the stands see
the channel, five seconds behind. That rule was about who may see what, not
about how long a match runs, so it survives the move to four a side intact.
The delay does more work here than it did in an open arena, not less: a
watcher in a match can be partisan and relay to one side, and four a side is
small enough that one relayed position decides a fight.

What does change is the reason anybody is in the stands. The old one is gone,
since it was a queue of pilots present and not playing, and there is no queue
any more. Three reasons replace it, and they are worth ranking by how often
they actually fire.

**Sitting out, which is now the common one.** In an open arena a pilot who sat
out simply left their side short. Four a side cannot absorb that, so sitting
out does what a disconnect does: a bot takes the seat, the pilot lands in the
stands, and the seat stays theirs. That unifies three paths that used to be
separate, since a voluntary sit-out, a dropped socket, and the lag ladder
benching a bad connection all now produce one state. The lag response keeps
the gentlest step it has, which is the reason it was built.

**Watching a room that is full**, which will rarely fire and matters when it
does. A bot stands down for every arrival, so a room is only truly full at
eight humans; below that a would-be watcher can simply take a seat. When it
is full, though, opening a fresh bot-filled room is the exact wrong answer,
and the gallery is what a watcher gets instead.

**Operators**, who watch what everybody else in the stands watches.

### Two kinds of watcher

The distinction is load-bearing and the room has to keep it.

A **benched pilot** still holds a seat: they sat out, dropped, or were moved
here by the lag ladder, and a bot is keeping the chair warm. They reclaim it
whenever they like and they are not in any line. The hold lasts to the end of
the current match; an unreclaimed seat is free at the intermission, which
bounds it without a timer of its own and puts the expiry on the boundary
everything else in this game already uses.

A **visitor** holds nothing. They arrived to watch, and a seat reaches them
only through the offer below.

### The seat offer

A seat that comes free with the room at its human cap is offered to the
visitors one at a time, in arrival order, with a ten second countdown on each.
Decline it or let it lapse and it passes to the next; either way you go to the
back, so an idle watcher sinks and an attentive one rises rather than the loop
stalling on somebody who has walked away. The loop keeps running into the
match rather than stopping when it starts, because joining a match in progress
is ordinary now, so a visitor who accepts at 1:20 spawns in exactly as any
arrival would.

**An offer does not reserve the seat.** Somebody arriving from the directory
takes it and the offer is withdrawn mid-countdown. That is unfair to a visitor
who has sat through two offers, and it is still right: a visitor chose to
watch and an arrival chose to fly, and when one seat has to settle that, the
unambiguous intent should win. Holding the seat instead would mean the room
advertising a vacancy it refuses to fill, which is the queue this design keeps
saying it does not have. If an acceptance and an assignment race, the server
settles it and the loser keeps their place at the front rather than being sent
to the back, since they said yes.

Worth knowing before any of this is built: it fires only when a room holds
eight humans and one of them leaves. Below that a bot stands down and a
visitor becomes a pilot by asking. So this is the machinery that makes a
popular room behave, and on the population this game has today it will
essentially never run.

## What waits

The heat-scored director, a WATCH row on the games list, the long-delay
whole-room stream for film study, and replays from the input trace, which
invert the economics entirely: a deterministic core means a match is its
initial state plus its inputs, and nobody pays egress at match time. Each of
these changes no wire decision made here.

Replays are also where a pilot who wanted to watch their own team gets to,
and the reason losing live follow costs less than it looks. A finished match
played back from its trace shows any seat from any angle with nothing to leak,
because the fight is over.
