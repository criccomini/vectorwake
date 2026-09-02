# The beacon

Chris's ask, twice. First: the flags look silly, come up with cooler ones,
mocked up. Then, off the first sheet: the beacon, only the beacon, and make
the collar big enough to clear the ship.

So this is no longer a comparison. It is the sheet that develops one drawing,
by [client/tools/flags_svg.lua](../../client/tools/flags_svg.lua). Nothing in
`client/arena/world.lua` has moved yet.

```sh
lua5.1 client/tools/flags_svg.lua /tmp/flags.svg
chromium --headless --screenshot=/tmp/flags.png --window-size=1240,2060 \
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
working. It costs 490.

## The collar is built off the roster, not off the eye

The first draft cleared the Apex, which reaches 21 pixels, and that was wrong.
The Cipher is a knife and reaches 23 down its own length, so the collar sat on
the nose of the hull it was supposed to be marking.

The sheet now reads `M.HULLS` out of `world.lua`, takes the widest reach in the
roster, and puts the inner rim four pixels outside it. The arcs stand seven
pixels beyond that and the ping runs from the rim out to twenty five past it.
Every number below the arcs comes from the polygons, so a hull that gets recut
moves the clearance with it rather than quietly breaking the drawing.

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
counts them down. The collar is round, so the clock is a rim to drain, and it
costs one arc.

It sits fourteen pixels outside the inner rim, which is far enough out that it
cannot be read as a fourth arc. It empties counterclockwise from noon, the way
a fuse burns down, and the last five seconds turn to the other side's color,
because that is who the flag is about to be available to again.

## What is still open

**Turf may want its own mark.** A turf stand is a place rather than a thing you
carry: `flag_carry` is clear there, the flag never leaves its tile, and what
the drawing has to say is that this ground is being held. A transponder pinging
on a claimed stand says that well, which is the argument for using the same
drawing in both zones. It is also the argument for giving Turf something that
never opens into a collar, since a turf flag is never carried and half of this
drawing is therefore dead there.

**Two carriers close together overlap.** Four flags and eight seats means it
will happen. The collars are rings rather than fills, so they cross rather than
occlude, but it has not been looked at with two ships in one place.

**Nothing is wired up.** `M.flags` in `world.lua` still draws the pennant. What
lands from here is that function, the two states, and the clock, which needs
`flag_carry_ticks` and the carrier's `held` count on the wire where the client
can read them.

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
