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

Live sight is your own side, or a written-down grant. Everything else is the
room channel, delayed. That single sentence is the whole security model, and
each clause is load-bearing.

**Same-side live follow leaks nothing the side lacks.** A teammate's screen is
already lawful knowledge, shared over voice every day, and the teammate paid
for a seat, shows on radar, and can be shot. Your side's bots count as
teammates, which mostly dissolves the lonely-side case: bots flow toward
whichever side is short, so a team zone rarely leaves a pilot with nobody
lawful to follow.

**Hostile live follow is a wallhack with a menu entry.** Following your victim
puts a camera on the one hull the fog is supposed to hide, with its movement
and surroundings always centered on screen. The fleet already prices pooled
sight as a scout team, answered with seats, radar visibility and bans; a
hostile follower would pay none of that, on a free guest account, from a
second browser tab. So the ask is never an error and never granted: it lands
on the channel.

**The channel is shared because shared is what defeats re-rolling.** One feed
per room, subject picked by the server on its own clock, identical bytes to
every watcher on it. Reconnecting lands you on the same channel everyone else
is watching, so there is no pulling the lever until your victim comes up. A
per-watcher random pick would die to exactly that: watcher joins cost nothing
and guests are free, so a room of nine humans falls to the intended victim
inside nine rejoins.

**The delay is what makes the frame that does show a stranger film rather than
targeting data.** `channel_delay_ticks` in the zone file, five seconds by
default. A bound radius can afford a short delay and still feel live, which
the whole-room delayed stream this replaced never could, because full
positions only seconds old are still a map of the room. Kills ride the ring
with the frame they belong to, or the feed would announce a death the delayed
picture has not shown yet. A duel zone sets the dial to zero on purpose: there
the audience is the mode and both pilots are equally exposed.

**The subject is told, when somebody is actually looking.** The tally means a
person is seeing you, not that a camera is pointed at you, and those are two
different facts here. The channel picks a subject and fills its ring whether
or not anybody is on it, so an arriving watcher lands in a warm picture rather
than staring at the delay; and the channel runs behind, so a pilot the camera
has just landed on is seconds away from being shown. So `S2C_ONAIR` is derived
from the audience: the channel is showing you and at least one watcher is on
it, or somebody is following your hull directly. Edges only, recomputed every
snapshot.

It is a red tally beside the MENU and PLAYERS keys, swelling slowly rather
than blinking, since it has to hold attention for minutes and a blink that
long is something a player stops seeing. Two minutes on air is something a
pilot can play around, and only if they know.

Staff following you light it like anybody else, because they are already
named in the roster: hiding them here would let a room see that somebody is
watching without being able to tell they are watching you. Covert observation
is the invisibility capability, and when it arrives it should take the roster
row and the tally together rather than half of each.

It sat at the top of the middle first, and could not stay: that strip carries
the flag pennants and the round's banner, both centered, and a notice laid over
them read as a fault in the flags rather than as a fact about you. Those are
about the round; this is about you, like the keys it now sits with. Being on
that row also means the map opening across the corner keeps clear of it under
the rule that already keeps it clear of the keys.

**Staff is the exception that is written down.** The `watch` capability in the
catalog's staff list grants live follow of anybody, and it requires the
account as well as the name, because a guest can claim any name and a grant a
claim could hold would be no grant at all. This sits beside the full-view
capability [networking.md](../architecture/networking.md) already plans, and
it is the operator's reason to be here: watching a room instead of a number.

## What a watcher receives

A follower's snapshot is packed at the followed hull with the human interest
radius, whatever the target's own stream gets. That last clause is not
pedantry: a declared bot is sent radius -1, the whole prize table, and a
watcher who inherited it would hold sight no human lawfully has. A server test
compares the packed bodies byte for byte against a fresh human-radius pack at
the target's coordinates, so the day the two diverge, the mode has started
leaking and CI says so.

The channel is packed once per snapshot tick and fanned out, so its cost is
flat in CPU however many watch, and the ring runs whether anybody is on the
channel or not, so an arriving watcher lands in a warm picture instead of
staring at the delay's worth of nothing. An empty room points the camera at
the middle of the map, and the picker prefers live humans, because a random
camera in a bot-filled room is a bot documentary five frames out of six. The
heat-scored director can replace the picker later without touching the wire.

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
two-tab tier. The arrows walk the camera along the occupied seats, one step
past the end is the channel, and on glass a tap on either half of the screen
does the same.

Picking a particular pilot is the info box. You open it by tapping a name in
the player list, which is already how you ask who somebody is, and while
watching it carries a WATCH key at its foot, in the slot an invitation would
use and drawn as a key like every other thing in this interface you can press. The two never appear together: inviting wants somebody who is not
on your side, following wants somebody who is. It is drawn only on a
teammate, because the zone grants live sight of your own side and refuses it
of anybody else's, and a control that quietly dropped you back on the channel
would be worse than no control. The box shuts behind the press, unlike an
invitation, since the answer is the whole screen becoming their view.

That needs the watcher to know their own side, so the team list goes to
watchers too: their side, and no open doors, because a watcher crosses nothing
until they take a hull again.

Every watcher has one, including somebody who never flew here. They are seated
at the door by the rule that seats a pilot, on the emptiest of the zone's own
sides, because watching is a way of being in this room rather than a lobby
beside it. The first cut handed an arrival nothing, on the reasoning that they
had sat out from nowhere, and what that produced in Alpha was a spectator
alone off the edge of a ten-team zone: every hull on screen drawn as an
enemy's, and no live sight offered of any of them, while the same person
joining in a hull and then sitting out kept their side and everything that
came with it.

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
whenever the channel crossed the line, and told the info box that a teammate
of the pilot you happen to be watching is a teammate of yours.

Nothing on screen says the word "watching". The pilot being observed wears
their call sign and their bounty at their hull's lower right, exactly as every
other pilot on screen does, because the one hull that goes unlabeled is your
own and a watcher has none. That is also the answer to the only question a
spectator has constantly, and it belongs on the hull rather than in a caption
at the foot of the screen.

## Where the door is

Spectating is a hull you can be in, so it is the ninth cell of the ship page.
Picking a hull is already how a pilot says what they want to be, and "nothing,
I am watching" is an answer to that question rather than a separate act. The
cell draws the pilot helmet instead of a ship, since it is about the person
and not about anything they are flying, and it wears the same "you are here"
wash the hull you are flying wears. Going back is any of the other eight
cells, which is the same page and the same press; a room that filled while you
sat out refuses, and the refusal is staying exactly where you are.

On the home screen too, where the page answers a different tense: not what you
are, which is nothing, but what you will arrive as. Arriving to watch is a
thing the wire has always been able to say and the client simply never said,
so picking the cell there sets the join's watch flag rather than waiting for a
game to exist. It is remembered like the hull is, because it is an answer to
the same question, and picking any of the other eight is what takes it back.

The cell was briefly hidden at home, on the grounds that it did nothing there.
That was the wrong repair: it did nothing because the join never carried the
choice, and hiding it made the page mean two different things on two screens.

Touch gets it on the same terms, because the page is one grid at every size.
Two columns on a phone held upright, where the ninth cell starts a row of its
own and the whole page still fits. Four across a phone held sideways, where it
lands on a third row against a screen with room for about two and a half:
tight rather than broken, and worth a look whenever the ship page is next
opened up.

It briefly lived as a third answer on the games-list card that asks whether
you meant to leave. That card is about the game you are in, and what you are
flying is a different question, so it is back to two answers.

The player list carries the gallery under the pilots: no seat, no score, the
word "watching" where the numbers would be, and a count of its own
in the line under the board. The roster exists so you know who is in the room
with you, and somebody watching the fight is in the room.

## What waits

The heat-scored director, a WATCH row on the games list, the long-delay
whole-room stream for film study, and replays from the input trace, which
invert the economics entirely: a deterministic core means a match is its
initial state plus its inputs, and nobody pays egress at match time. Each of
these changes no wire decision made here.
