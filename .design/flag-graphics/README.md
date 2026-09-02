# Flags that are not golf pins

Chris's ask: the flags look silly, come up with cooler ones, mocked up.

Five candidates against what ships, on one sheet, drawn by
[client/tools/flags_svg.lua](../../client/tools/flags_svg.lua). Nothing has
been picked and nothing in `client/arena/world.lua` has moved.

```sh
lua5.1 client/tools/flags_svg.lua /tmp/flags.svg
chromium --headless --screenshot=/tmp/flags.png --window-size=1240,4360 \
  file:///tmp/flags.svg
```

Artifact: [Flag Graphics](https://claude.ai/code/artifact/082df40a-1937-4796-8873-0dc620c07b3c)

## What ships, and what is wrong with it

`M.flags` in `client/arena/world.lua` draws a vertical staff and a triangle
of cloth hanging off the top of it, the triangle's tip moved by a sine so it
waves. Three things about that.

**It is the only object in the game drawn in elevation.** Everything else on
the ground is a plan view. A turf stand is an octagon with a knob in the
middle. A spawn is two rings. A wall is its own lit face. A wormhole is a
field. The flag alone is drawn as though the camera had turned ninety degrees
to look at it side on, which is why it reads as a golf pin: a pin is the one
real object shaped like that.

**Nothing here has a wind, and the flag is waving in one.** The sine on the
tip is a fabric cue, and it is the tell that gives the whole drawing away.

**It is off center, and the flag is not.** The cloth hangs up and to the
right of the flag's own position, so the shape a pilot flies at sits a dozen
pixels from the point `sim_flag` actually tests. `flag_radius` is eighteen
pixels, wider than the entire drawing, and no part of it says so.

There is a fourth, and it only shows up in the last band of the sheet: at the
zoom the game is played at, a pennant is close to invisible. Put four of them
on a map next to three hulls and you have to hunt for them.

## The five

Each is a pair: a flag standing on its stand or lying where somebody dropped
it, and the same flag riding a hull.

| | what it is | standing | carried |
|---|---|---|---|
| | | triangles | triangles |
| pennant | what ships | 35 | 35 |
| beacon | a transponder: arcs that turn, and a ping leaving the core | 280 | 344 |
| sigil | three blades and a binding ring, as a faction mark | 165 | 143 |
| sweep | a scanning face, one wedge of light turning with a tail | 240 | 258 |
| streamer | a ribbon trailing the carrier, coiled on its stand | 154 | 174 |
| cage | a core inside two counter turning frames | 74 | 50 |

The counts are measured on the sheet by the same layer code the arena runs.
They matter because the glow layer has a hard ceiling it shares with every
hull and every round in flight, and whatever falls past the cap that frame
simply vanishes. Four flags of any of these is affordable; four of the first
draft of the beacon, at nine hundred and sixty triangles each, was not, and
almost all of it was arc facets under a tenth of a pixel across. Every arc on
the sheet is now faceted off `Layer:round_segs`, which is where that number
should have come from in the first place.

## Two rules that came out of drawing them

**Carried is a collar, not a badge.** The first pass drew each mark on the
hull carrying it, and both halves failed: the mark hides the ship everybody
in the room is trying to shoot, and at the range where a carried flag decides
a round it is a smudge on a hull rather than a flag. All five now leave the
inner thirteen pixels alone and live from there out. The ship stays whole
underneath, and a hull wearing a bright collar is unmistakable from across a
map.

**Round leaves somewhere to put the clock.** Capture the Flag drops a carried
flag after thirty seconds, per
[zones.md](../../docs/design/zones.md#capture-the-flag), and nothing on screen
counts them down. Every candidate here is drawn round, so all of them have a
rim to drain. The last band of the sheet shows it on the beacon: a full track,
an arc emptying counterclockwise from noon, and the last fifth in the other
side's color, because that is who the flag is about to be available to again.
It costs one arc.

## What I would ship, and what I would ask first

**Sigil**, if one drawing has to serve both modes. It is the only one of the
five that reads as heraldry rather than as instrumentation, which is what a
flag is: a thing a side owns. It is cheap, it holds its shape at play zoom
better than anything else here, and taken it turns into an unmistakable
splayed mark around the hull without changing color to say so.

**Beacon** is the better answer for Turf on its own, and that is the question
worth putting to you before anything is built. A turf stand is a place, not a
thing you carry: `flag_carry` is clear there, the flag never leaves, and what
the drawing has to say is "this ground is being held." A transponder pinging
on a claimed stand says that exactly, and a heraldic mark on a stand nobody
can pick up says it less well. Capture the Flag is the opposite: the flag is
an object with a life of its own and the sigil is right for it.

So: one mark for both, or one for each. Two costs a second drawing and about
three hundred triangles; one costs Turf a little of the read.

**Sweep** is the strongest looking of the five in isolation and the weakest in
the room. A turning wedge with a tail reads as a gauge, and this game already
puts gauges on the interface layer. Worth having on the sheet; I would not
ship it.

**Streamer** is the honest one, and the one I most wanted to work. It is the
only candidate that answers the question the pennant is pretending to answer:
what a flag does when the thing holding it moves. Trailing the carrier's own
heading is right where a wave is wrong. On its stand it has nothing to trail
from and coils instead, and that state is the weakest thing on the sheet.

**Cage** is the cheapest by a factor of three and has the hardest silhouette
of the five. It is a good drawing of a prize under guard, which is a slightly
different game than the one we have.

## How the sheet is made

`flags_svg.lua` stubs `vwbuf` to write SVG triangles instead of vertex
buffers and drives `client/render/vec.lua` unchanged, the way `marks_svg.lua`
and `hud_svg.lua` do. So the sheet is not a picture of a drawing: every shape
on it went through the same arithmetic the mesh builder runs, in the same two
layers, in the arena's order, and with the glow layer blending additively,
which is the blend function `vectorwake.render_script` sets for it.

Three things that were wrong in the mock rather than in the drawings, worth
writing down because the next sheet will hit them too. World y runs down the
screen, which the render script does by swapping top and bottom, so an SVG
tool that flips for its own layout has to flip back or every flag hangs
upside down. `place` in `world.lua` negates the polygon's y, so a hull at a
heading of zero points up the screen and not along +x. And under ordinary
alpha compositing an arc beads into a dotted line, because an arc is a run of
quads whose falloff ramps meet at every facet and are meant to sum;
`mix-blend-mode: plus-lighter` is what the GPU is doing and it is the
difference between judging a drawing and judging the mock.
