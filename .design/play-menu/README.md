# The play page, rethought

Chris asked for ways to make the play page more interesting, with mocks of
different ideas. The canvas (artifact fa3069ca) holds three rounds, and
the third is the live one. The first drew three directions beside the page
as shipped, all keeping the page as a list and enriching the rows; Chris
called them derivative, which is fair. The second sketched five framings
that change what the page is; Chris passed on those too: the stands
beside the drawer already show a game in flight, so the liveness ideas
(tuner, channel wall, surf) buy what the client already has, and the feed
did not land. His brief for round three is the one to build against: a
structured description of each zone's format. Time, team count, scoring,
as structure rather than a sentence. Four versions of that structure are
on the canvas's Format page, where it opens. The sticky notes over each
board carry its case and its cost. Boards are built by `build.py` and
seeded with the design skill's helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out play-menu.html --title "Play Menu" \
      --artboard Main.dc.html --artboard Current.dc.html \
      --artboard Tuner.dc.html --artboard TunerWide.dc.html \
      --artboard ChartRoom.dc.html --artboard Rooms.dc.html \
      --artboard BoardingCall.dc.html --artboard ChannelWall.dc.html \
      --artboard Surf.dc.html --artboard StarChart.dc.html \
      --artboard Ticker.dc.html --artboard SpecRows.dc.html \
      --artboard FormatTable.dc.html --artboard FormatMarks.dc.html \
      --artboard RuleCard.dc.html --canvas canvas.json

## One rule under all three: a row's figures are the landing room's

A zone can run several arenas and several rooms, so "the zone's clock" or
"the zone's score" is not a thing; Duel alone may hold twenty rooms, one
climber each. What a row can honestly say is what its press does, and a
press already means one specific room: the directory orders each zone's
instances by fullness and the join takes the head instance's first room
with a seat. The shipped page already counts down exactly that room's
clock, and directory.lua says why: a clock read off one room and a
whistle heard in another is worse than no clock.

So every figure these mocks put on a row is that landing room's: its
clock, its seats, its score, its ground. The zone's own totals are a
different fact and never wear the seat grammar, because a zone running
two arenas has twelve people and eight seats, and circles drawn from both
at once would lie. Friends are the one zone-scoped line left ("in this
game", not "in the room you would land in"); under the concentration
rule the two nearly always coincide, since a second room opens only when
the first is full of humans.

When a zone is holding more than one joinable room, `Rooms.dc.html`
shows the shape: the zone head keeps the name, the sentence and the
"wherever the fill ladder puts me" press, and the rooms unfold under it
as numbered lines, each with its own clock and seats, a full one
readable but dim, the one the ladder would pick lit. That is the arena's
ROOMS panel grammar moved onto the page. The cheaper alternative is to
not unfold at all and keep the one row honest about its landing room,
leaving room choice to the ROOMS panel in the arena, as shipped.

## The diagnosis

The page is the games alone (decision 63): a name over a sentence, twice,
and then six hundred points of empty column. The spareness was earned. The
counts, the roster and the DEPLOY key all went for stated reasons, and none
of them should come back as they were.

What makes it boring is that the page also ignores everything it already
knows. The directory reply it re-asks every three seconds carries the
landing room's clock, whether that room is mid-match, and the seat counts.
The account layer knows which friends are in which game. The catalog keeps
a fight running in every room on purpose; ladder's stand-in duel exists,
in its own zone.toml's words, so "the play page has a fight to show
whoever is deciding what to press". And every room is on a named ground
with a shape. The page draws none of it, so choosing a game is reading two
sentences that never change.

## The directions

**A, departures** (`Main.dc.html`, `Rooms.dc.html`). Each row answers
"if I press now, what do I land in?": the landing room's clock at the
right (LIVE 2:04, or NEXT MATCH 0:42), its seats under the name in the
hangar's circle grammar (solid a person, ring a bot holding the seat,
dim nobody), friends in their game's row in their own cyan, and your
Duel rung on Duel's row. The second board is the same direction with a
zone holding two joinable rooms, unfolded into numbered lines.
Every fact is already in the reply the page polls; this direction is a
drawing change and nothing else. Its cost is that it is the busiest of the
three, and it half reverses the decision that stripped the counts, with a
meter where the sentence used to be.

**B, tuner** (`Tuner.dc.html`, `TunerWide.dc.html`). The room bleeding
through the drawer's wash is the game under the cursor: resting on a row
tunes the stands to that game's delayed feed, and the row carries one thin
score line, sides in their colors around the clock. Choosing a game is
watching it, and the page itself stays almost as bare as shipped. The wide
board is the same page docked at 390 beside the fight it is tuned to. Its
costs: a channel change per hover, and a phone has no hover, so there it
becomes first press tunes, second press joins, which bends "pressing a
game means be in it" (decision on the games list as one act).

**C, chart room** (`ChartRoom.dc.html`). A game is a place. Each card
carries a chart of the ground the landing room is on now, drawn in the
radar's own grammar (radar ground, tile-colored walls, spawn tiles in the side
colors), with the ground's name and the rotation's next ground under it.
Team Battle's six maps mean the card actually changes as the rotation
turns, which no other direction gives the page. Its costs: the directory
reply does not carry the map today, so this is a wire change, name first
and geometry after it, and two cards spend most of a phone.

## Round two: framings, not rows

The first round decorated a list. These five each answer the page's
question, "what should I be in next?", with a different kind of page.
Sketches on the canvas's Wilder page, drawn just far enough to judge.

**D, boarding call** (`BoardingCall.dc.html`). The page is one question:
the next whistle across the fleet, what it is, and one key that means
deal me in. The fill ladder already picks the seat, so the page stops
pretending the player has homework; browsing survives as two quiet lines
underneath. Costs: hides the second game behind a default, and the big
clock is only honest if joins land at whistles rather than mid-match.

**E, channel wall** (`ChannelWall.dc.html`). No rows: one live window
per game, the fight drawn small with its name and clock on a corner
band, and pressing a window means be in that room. Two games means the
whole fleet fits on a phone with no scroll. Costs: two delayed feeds at
once, and it stops scaling past three or four games.

**F, surf the stands** (`Surf.dc.html`). No page at all: the play stop
drops the drawer, you are simply in some room's stands, chevrons flick
between live rooms, and PLAY seats you in the one you are watching. The
endpoint of the spectator-first landing (decision 61): choosing and
watching become the same act. Costs: the games are never seen side by
side, and a game nobody is running has no channel to land on.

**G, star chart** (`StarChart.dc.html`). A game is a beacon on one
chart, your mark at the foot, a plotted route to the one under the
cursor and its card beside it. Going somewhere is the register the whole
game is named in, and a chart has room for whatever the fleet grows.
Costs: the most new drawing for the same two presses, and with two games
the chart is mostly empty space.

**H, the wire** (`Ticker.dc.html`). The page is what just happened
across the fleet, each line pressable toward the room it happened in:
streaks in the streak's gold, kills in the payout green, whistles in
ink. You choose by story rather than by name, and the bare game rows
sink to the foot. Costs: needs a new event feed on the directory wire,
and at today's population the wire can go quiet.

## Round three: the format, structured

The same facts on all four boards, read off the catalog. Team Battle:
two sides of four with AI holding empty seats, three-minute matches
with fifteen seconds between, a kill scores its victim's bounty (one,
plus one per kill on their run), six grounds in rotation. Duel: one
against a measured house pilot, one life a round, a win climbs a rung
and a loss drops two with a checkpoint every five, always on drydock.
The versions differ only in the shape the facts wear. Whatever ships,
the values belong on the wire the way `label` and `description` already
travel, not hardcoded: the catalog states them per zone, so the client
should read them, not know them.

**I, spec stacks** (`SpecRows.dc.html`). Each fact is a label over a
value with vrules between, the grammar the landing's room band wore for
TIME and PLAYERS. The sentence stays under the name. The most house of
the four and the cheapest. Cost: four stacks is the width; a fifth fact
starts to squeeze.

**J, the table** (`FormatTable.dc.html`). One labeled header, every
game measured in the same columns, so reading the list is comparing
games. The shape these facts want once there are more games than two.
Costs: three columns is the ceiling on 390, and a header over two rows
is a lot of chrome for a two-game fleet.

**K, format marks** (`FormatMarks.dc.html`). The structure drawn: seat
circles in two clusters facing across a gap for the sides, a dial for
timed, a single ringed life for Duel, the crosshair for kills, the
rungs for the climb, each mark over its word. Reads before it is read.
Cost: a mark vocabulary nobody has been taught, so the captions can
never come off.

**L, rule card** (`RuleCard.dc.html`). Every row carries the one-line
spec; the row under the cursor unfolds the whole format as labeled
lines behind a left rule, the hangar's reading grammar. The deepest
answer for the least standing ink. Costs: it hides the side-by-side
comparison a table gives away free, and on a phone the unfold needs its
own press.

## A recommendation

I with L behind it: the spec stacks as the standing answer, since they
are the landing band's own grammar and they hold the sentence, and the
rule card's unfold as where the whole format lives, the same
press-to-read gesture the hangar teaches. J is the shape to move to if
the fleet ever lists six games. K's marks are worth keeping for the
sides cluster alone, which could sit inside I's SIDES stack as the
value's mark.

The earlier rounds stand as the record. From round one, the landing
room scoping rule (below) still governs anything live a row ever says;
rounds one and two's boards stay on their pages as what was tried and
why not.

## What is here

`build.py` writes the six artboards from the same design system the
earlier mocks lift from the client: hues from `client/arena/palette.lua`,
the drawer's row and key grammar from `client/arena/ui.lua`, the top line
and rail from the pilot-page boards. The facts on the rows are the
catalog's: Duel and Team Battle with their shipped descriptions, Pylon
and Caisson, eight seats, three-minute matches, the melee rotation's
grounds. The seeded file is git-ignored: it is editor payload, and
nothing in it is authored here.

## Rebuilding

```sh
python3 build.py
```

That rewrites the artboards. To rebuild the canvas they are published in,
re-seed with the helper command above and publish the result to the same
URL.
