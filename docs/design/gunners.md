# Gunners

A gunner is a player riding on a teammate's ship, keeping their own hull,
their own energy bar and their own aim, and giving up all control of where the
ship goes. The hull carrying them is a carrier.

Nothing here is built. `sim/` has no notion of one ship riding another, the
client draws none of it, and [ships.md](ships.md) still lists the mechanic as
an open question. What this document settles is the vocabulary and the
drawing, because both were being argued about in the abstract and a drawing is
cheap to look at. Whether the mechanic ships at all is decided elsewhere and
later.

The original's version, which is where all of this comes from, is written down
in [research/turrets.md](../research/turrets.md).

## The words

Two, and no more. A **gunner** is both the player riding and the slot they
ride in, so a carrier has five gunners whether or not anybody is in them. A
**carrier** is the hull. There is no third term for the fitting, the seat or
the act.

Settings follow the words: `gunner_limit`, `gunner_thrust_penalty`,
`gunner_speed_penalty`, `gunner_bounty`. That is one to one with what the
original called `TurretLimit`, `TurretThrustPenalty`, `TurretSpeedPenalty` and
`AttachBounty`.

## The drawing

One gun glyph per gunner, drawn on the carrier's own point, turned to the
heading that gunner is holding. The glyph is the same for every class. Nothing
is drawn for an empty gunner, so a carrier with nobody aboard is just a ship.

Everything else follows from that:

- **No second hull appears anywhere.** A gunner is a gun, not a small ship,
  which is the whole reason a full carrier stays readable.
- **The overlap is the picture.** Five barrels leaving one hub is what a stack
  is, and it reads as a battery at a glance without anything being laid out.
- **Hull shape stops mattering.** Every glyph shares an origin, so a carrier
  needs no room, no collar and no mounting geometry. A dart carries five as
  legibly as a slab does, which is what lets `gunner_limit` be a number on any
  hull rather than a property of a shape.
- **The count is in the text.** The carrier's name plate gains a line per
  gunner, name and bounty, exactly as the original does it. That is the
  division [identity.md](identity.md) already draws: shape carries class,
  colour carries friend or foe, and text carries the rest.
- **Each gun's brightness is that gunner's energy.** This is a deliberate
  departure. The original hides it, and its own strategy guides spend
  paragraphs on the consequence, which is that a carrier cannot tell it is
  hauling somebody one bullet from death. Gunners are always the same freq,
  and the original had a setting for showing teammates energy, so this is
  inside what a zone could already configure.

What it gives up is which classes are aboard. Names say who, not what, so a
Wedge and an Anvil riding the same carrier look alike. The original gives that
up too. If we want it back it belongs in the name row as a letter or a tint,
never in the geometry, because geometry is what made the first three attempts
at this unreadable.

`client/tools/gunner_mock.py` draws it, reading the hulls out of the client so
the shapes are the real ones. It is a mock and it should be deleted the day
this is built rather than kept in step.

## What the drawing is not allowed to decide

A gunner sits at exactly one point with its carrier, takes damage there, and
is as big as the carrier's own hitbox. Splash that reaches the carrier reaches
everybody aboard. The picture has to keep saying that, which is why the guns
sit on the ship's point rather than fanned out around it: a stack drawn wider
than it is hittable teaches a lie about where to aim.

## Open

Whether the mechanic ships at all, and if it does, whether every hull carries.
The original let every ship carry five and left it to zones to zero the ones
that should not, which is the configurable answer and probably ours.

What a gunner costs a carrier. The original charges a flat penalty on the
first gunner and nothing for the next four, so a carrier with one always wants
five. That is a strange incentive to inherit without thinking about it.

Whether a gunner's own energy is on the wire. The brightness read above needs
it, and it is the one item here that is a networking decision wearing a
drawing's clothes.
