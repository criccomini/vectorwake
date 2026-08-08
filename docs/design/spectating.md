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
puts a camera on the one hull the fog is supposed to hide, with their exact
energy and their remaining charges in every packed ship. The fleet already
prices pooled sight as a scout team, answered with seats, radar visibility and
bans; a hostile follower would pay none of that, on a free guest account, from
a second browser tab. So the ask is never an error and never granted: it lands
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

**The subject is told.** The channel's camera picks a pilot without asking, so
the room owes them the fact: `S2C_ONAIR` when the camera lands and again when
it moves on, drawn as a mark in their interface. Two minutes on air is
something a pilot can play around, and only if they know.

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

Nothing on screen says the word "watching". The pilot being observed wears
their call sign and their bounty at their hull's lower right, exactly as every
other pilot on screen does, because the one hull that goes unlabelled is your
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

It briefly lived as a third answer on the games-list card that asks whether
you meant to leave. That card is about the game you are in, and what you are
flying is a different question, so it is back to two answers.

The player list carries the gallery under the pilots: no seat, no side, no
score, the word "watching" where the numbers would be, and a count of its own
in the line under the board. The roster exists so you know who is in the room
with you, and somebody watching the fight is in the room.

## What waits

The heat-scored director, a WATCH row on the games list, the long-delay
whole-room stream for film study, and replays from the input trace, which
invert the economics entirely: a deterministic core means a match is its
initial state plus its inputs, and nobody pays egress at match time. Each of
these changes no wire decision made here.
