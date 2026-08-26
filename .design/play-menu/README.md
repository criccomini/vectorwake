# The play page, rethought

Chris asked for ways to make the play page more interesting, with mocks of
different ideas. The canvas (artifact fa3069ca) now holds two rounds. The
first round drew three directions beside the page as shipped, all of them
keeping the page as a list and enriching the rows; Chris called them
derivative, which is fair. The second round, on the canvas's Wilder page,
sketches five framings that change what the page is instead. The sticky
notes over each board carry its case and its cost. Nothing here is chosen
yet. Boards are built by `build.py` and seeded with the design skill's
helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out play-menu.html --title "Play Menu" \
      --artboard Main.dc.html --artboard Current.dc.html \
      --artboard Tuner.dc.html --artboard TunerWide.dc.html \
      --artboard ChartRoom.dc.html --artboard Rooms.dc.html \
      --artboard BoardingCall.dc.html --artboard ChannelWall.dc.html \
      --artboard Surf.dc.html --artboard StarChart.dc.html \
      --artboard Ticker.dc.html --canvas canvas.json

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

## A recommendation

From the first round, A is the one direction that is pure drawing, and
it makes the page honest about what the press does; C's name line is the
cheap second step once the directory carries the map's name, and B
should be decided on its own because of its phone story.

Across both rounds, the strongest pair is F and D, and they are really
one design seen from two ends: the stands as the browser, with the
boarding call as the words on top of it. F is where the spectator-first
landing (decision 61) has been pointing, it needs no new wire, and it
makes the two-game
fleet feel bigger rather than smaller. E is the phone-native middle if
F's one-at-a-time browsing feels blind. G and H are the ones to keep in
a drawer until the fleet is big enough to need a map or a news page.

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
