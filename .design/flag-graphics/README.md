# The beacon

Chris's ask, three rounds of it. First: the flags look silly, come up with
cooler ones, mocked up. Then, off the first sheet: the beacon, only the beacon,
and make the collar big enough to clear the ship. Then: Turf can use the same
drawing, and a pilot holding several flags should show several layers, with
the layers going to the clocks where a zone runs one.

So this is no longer a comparison. It is the sheet that develops one drawing,
by [client/tools/flags_svg.lua](../../client/tools/flags_svg.lua). Nothing in
`client/arena/world.lua` has moved yet.

```sh
lua5.1 client/tools/flags_svg.lua /tmp/flags.svg
chromium --headless --screenshot=/tmp/flags.png --window-size=1240,2775 \
  file:///tmp/flags.svg
```

Artifact: [The Beacon](https://claude.ai/code/artifact/082df40a-1937-4796-8873-0dc620c07b3c)

The four it beat, and the argument against the pennant, are in this file's
history and in the artifact's earlier version.

## What it is

A transponder seen from above. A bright core, a ring, three arcs standing off
it that turn, and a ping: a ring that leaves the core and fades on its way
out. A flag is the object telling a room where the game is, so it draws the
broadcast rather than a piece of cloth.

Standing, the arcs sit at twelve pixels, inside the eighteen the core actually
tests for a pickup, and the ping runs one beat every two seconds. It costs 298
triangles.

Carried, the whole thing opens into a collar outside the hull and the ping
comes twice as often. That is a change of rate rather than of shape, which is
what lets the two states be told apart at a size where shape has stopped
working. It costs 514, or about 874 with a carry clock on it.

Turf uses the same drawing. A stand is never carried, so half of it never runs
there, and that is fine: a transponder pinging on claimed ground is exactly
what a held stand has to say, and one flag drawing across the catalog beats two
that a player has to learn separately.

## The collar is built off the roster, not off the eye

The first draft cleared the Apex, which reaches 21 pixels, and that was wrong.
The Cipher is a knife and reaches 23 down its own length, so the collar sat on
the nose of the hull it was supposed to be marking.

The sheet now reads `M.HULLS` out of `world.lua`, takes the widest reach in the
roster, and puts the inner rim four pixels outside it. The first ring of arcs
stands seven beyond that, the first clock rim sixteen, each further flag adds
eight, and the ping runs from whatever the outermost ring turns out to be to
twenty five past it. Every number comes off the polygons, so a hull that gets
recut moves the clearance with it rather than quietly breaking the drawing.

The band called `the whole roster` is the proof: one collar over all seven
hulls at the size they fly, with each hull's own reach drawn as a dashed
circle. Nothing touches.

## Why the collar is outside the ship at all

Two reasons, and the first sheet had it wrong on both. A mark drawn on a hull
hides the thing everybody in the room is trying to shoot. And at the range
where a carried flag decides a round, a mark on a hull is a smudge on a hull
rather than a flag: the ship's own outline is already using that space.

Outside it, the ship stays whole and shootable underneath, and a hull wearing a
bright ring is unmistakable from across a map. The `in a room` band at the foot
of the sheet is where that gets judged, because it is the only one drawn at the
zoom the game is actually played at.

## The carry clock

Capture the Flag drops a carried flag after thirty seconds, per
[zones.md](../../docs/design/zones.md#capture-the-flag), and nothing on screen
counts them down. The collar is round, so the clock is a rim to drain.

It sits sixteen pixels outside the inner rim, far enough out that it cannot be
read as one of the arcs, and it is drawn finer than they are. That is
deliberate: the arcs are the count and have to survive being small, while a rim
is a gauge, read by somebody who is looking at it. At equal weight, four rims
and one collar sat on the same footing and the count stopped being the first
thing anybody saw.

It empties counterclockwise from noon, the way a fuse burns down, and the last
five seconds turn to the other side's color, because that is who the flag is
about to be available to again.

## Carrying more than one

Chris's read, and the right one: the case that matters is not two carriers in
one place, it is one carrier holding several flags. In Capture the Flag that is
the entire round, since holding all four for ten seconds takes it, so a pilot
two flags in has to look like it from anywhere on the map.

**No carry limit: one ring of arcs per flag.** Alternate rings turn against
each other, because two rings turning the same way at the same phase read as
one thick ring and the whole point of the stack is being countable.

**With the clock: one ring of arcs, and a draining rim per flag.** Stacking
both would put eight rings around a ship and say neither. The rims are sorted
so the one about to expire is outermost: it is the one that turns the other
side's color, and it is the answer to the only question a carrier is asking.
`sim_flag` keeps `held` per flag, so the rims drain at their own rates and never
move together, which is what makes the stack worth reading rather than just
counting.

The stack is also the cheap case. One pilot holding four with clocks costs 1930
triangles; four pilots holding one apiece cost 3496, because each of them pays
for its own ping and its own inner rim.

## What the wire owes this

`M.flags` in `world.lua` still draws the pennant, and three things have to
arrive before the rest of this can land.

**`carrier` is on the wire and not in Lua.** `pack.c` writes it beside `team`
and `carried`, but `flag_at` in the extension returns x, y, team and carried
only. Grouping a pilot's flags into one stack needs it, and it costs one
`lua_pushnumber`.

**`held` is on neither.** It is a field of `sim_flag`, it is not packed, and the
client cannot derive it: a client joining mid carry never saw the pickup, and a
snapshot would zero whatever it had counted. That is decision 43's rule, and
[memory 583](../../.optmem/memory) is the last time this repository learned it
the hard way, with Free Roam's greens. Two bytes a flag and a protocol bump.

**`flag_carry_ticks` has no accessor.** Without it `held` is a tick count with
nothing to divide by, and the rim has no full.

## Still open

**Two carriers on top of each other.** Less likely than the stack, but eight
seats means it happens. The collars are rings rather than fills, so they cross
rather than occlude, and it has not been looked at.

## How the sheet is made

`flags_svg.lua` stubs `vwbuf` to write SVG triangles instead of vertex buffers
and drives `client/render/vec.lua` unchanged, the way `marks_svg.lua` and
`hud_svg.lua` do. So the sheet is not a picture of a drawing: every shape on it
went through the same arithmetic the mesh builder runs, in the same two layers,
in the arena's order, with the glow layer blending additively, which is the
blend function `vectorwake.render_script` sets for it.

Three things that were wrong in the mock rather than in the drawing, worth
writing down because the next sheet will hit them too. World y runs down the
screen, which the render script does by swapping top and bottom, so an SVG tool
that flips for its own layout has to flip back or every drawing hangs upside
down. `place` in `world.lua` negates the polygon's y, so a hull at a heading of
zero points up the screen and not along +x. And under ordinary alpha
compositing an arc beads into a dotted line, because an arc is a run of quads
whose falloff ramps meet at every facet and are meant to sum;
`mix-blend-mode: plus-lighter` is what the GPU is doing, and it is the
difference between judging a drawing and judging the mock.

One more, learned on this pass. Every still on the sheet is one frame of an
animation, and the two states ping at different rates, so a single clock for
the whole page catches neither mid flight and the ping renders as a second rim
sitting on the first. Each band picks its own.
