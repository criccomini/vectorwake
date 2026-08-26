# The play page, rethought

Chris asked for ways to make the play page more interesting, with mocks of
different ideas. Three directions are drawn beside the page as shipped, on
canvas artifact fa3069ca; the sticky notes over each board carry its case
and its cost. Nothing here is chosen yet. Boards are built by `build.py`
and seeded with the design skill's helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out play-menu.html --title "Play Menu" \
      --artboard Main.dc.html --artboard Current.dc.html \
      --artboard Tuner.dc.html --artboard TunerWide.dc.html \
      --artboard ChartRoom.dc.html --artboard Rooms.dc.html \
      --canvas canvas.json

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

## A recommendation

Start with A: it is the one direction that is pure drawing, and it makes
the page honest about what the press does. C's name line is the cheap
second step once the directory carries the map's name, and the full chart
can wait for the geometry. B is the strongest in feel and composes with
either, since it is about the room behind the page rather than the rows;
it is also the one with an unresolved phone story, so it should be
decided on its own rather than ride along.

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
