# Gunners

A gunner is a player riding on a teammate's ship, keeping their own hull,
their own energy bar and their own aim, and giving up all control of where the
ship goes. The hull carrying them is a carrier.

It is built. `sim/` carries the ride, the server grants it, and the client
draws it and offers it on the panel you open by picking a player. What is not
settled is whether it earns its place in the game, which is a question a
playtest answers and not a document.

The original's version, which is where all of this comes from, is written down
in [research/turrets.md](../research/turrets.md).

## The words

Two, and no more. A **gunner** is both the player riding and the slot they
ride in, so a carrier has five gunners whether or not anybody is in them. A
**carrier** is the hull. There is no third term for the fitting, the seat or
the act.

Settings follow the words: `gunner_limit` on the class, and the pair
`gunner_thrust_penalty` and `gunner_speed_penalty` that comes off the carrier
while anybody is aboard. That is one to one with the original's `TurretLimit`,
`TurretThrustPenalty` and `TurretSpeedPenalty`, and the baseline takes its
numbers: five gunners, one of seventeen thrust, 12.5 px/s off the top, charged
once however many are riding.

`AttachBounty` has no counterpart here. The original gates a ride behind a
bounty and every zone whose settings we have read sets it to zero, so it is a
knob that has never been turned.

## The drawing

A drone per gunner, on a ring around the carrier, sitting in the direction
that gunner is aiming and facing out along it. The drone is the same for every
class.

**A carrier is drawn exactly like any other ship.** That is the rule the rest
of this hangs off, and it is a rule rather than a consequence. Carrying people
does not tint a hull, brighten it, add a fitting to it or take anything off
it. The drones are drawn over the top of a ship that has not been touched,
they appear one at a time as gunners attach, and they are gone the moment
those gunners leave. There is no carrier state for the hull to be in.

So a ship that can carry and a ship that cannot look identical while both are
empty, and capacity is invisible until somebody uses it. That is the cost and
it is worth paying: every hull can carry, so a marking that said "this one
can" would be on all of them, which is a marking that says nothing.

Everything else follows from that:

- **Position and facing are the same fact.** Turning does not spin a drone in
  place, it walks it around the ring, so where five guns are pointing is
  legible from where the drones are rather than only while they are firing.
- **The ring is a circle, so it has no local frame.** A drone's place depends
  on its gunner's aim and not at all on where the carrier is pointing: spin
  the carrier and the drones hover.
- **No second hull appears anywhere.** A gunner is a drone, not a small ship,
  which is the whole reason a full carrier stays readable. The gunner's own
  hull is not drawn at all while it rides, and neither is its energy pip.
- **The radius is the 80th percentile of how far the hull reaches.** Not its
  maximum, which puts the ring twenty pixels off a Cipher's flanks because the
  longest thing on a Cipher is a blade. Not a fraction of the maximum either,
  which buries the ring inside a round hull long before it tightens around a
  long one. The spread is what has to be cut through, and at the 80th the ring
  sits on the plating of the hull's body and lets its spikes through: about a
  pixel of overlap on an Anvil, eleven on a Cipher.
- **Yours carries your hull's halo.** Riding takes your silhouette off the
  screen, so without a mark the one question a pilot asks every second, which
  one is me, has no answer at all while they are a gunner. Same halo the hull
  wears when you fly it, and the edge lit the way your own hull's is.
- **Each drone's brightness is that gunner's energy.** This is a deliberate
  departure. The original hides it, and its own strategy guides spend
  paragraphs on the consequence, which is that a carrier cannot tell it is
  hauling somebody one bullet from death. Gunners are always the same freq,
  and the original had a setting for showing teammates energy, so this is
  inside what a zone could already configure.

What it gives up is which classes are aboard. A Wedge and an Anvil riding the
same carrier look alike. The original gives that up too, more completely: it
draws one gun sprite indexed by heading alone and puts the names in a column
under the ship. If we want the class back it belongs in the name plate as a
letter or a tint, never in the geometry, because geometry is what made the
first three attempts at this unreadable.

Getting off is the `d` key, and it is the one part of this that is not on the
panel. Attaching needs a target, so it belongs on the card you open by picking
a person; dropping needs none, and it has to be fast. Attaching empties the
bar it required, so the moment a gunner most needs off is the moment it has
nothing left, and a list, a row, a card and a button is not a control anybody
reaches in that state. The original bound both directions to one key for the
same reason.

`client/tools/gunner_mock.py out/ --drone` draws it against hull geometry read
out of the client. It is a mock of a thing that now exists, so it is a way to
try a change to the ring before writing it, and it should go when it stops
being used rather than being kept in step.

## What the drawing is not allowed to decide

A gunner sits at exactly one point with its carrier, takes damage there, and
is as big as the carrier's own hitbox. Splash that reaches the carrier reaches
everybody aboard.

The drones do not sit at that point, and that is the one place this drawing
knowingly overstates the ship. A loaded Anvil is 34 pixels of drawing over 31
of hull. Shots aimed at a drone hit nothing, and the gunner they were aimed at
takes damage at the carrier's centre wherever its drone is drawn. A pixel and
a half all round is the same order as a barrel poking past a nose, which this
roster already allows, and pulling the ring in until it were exact would put
the drones inside the plating. Recorded rather than fixed.

## Open

Whether it earns its place. Riding is unusual and takes explaining, and the
answer is a playtest rather than an argument.

What a gunner costs a carrier. The baseline inherits the original's flat
penalty, charged on the first gunner and not again for the next four, so a
carrier with one always wants five. That is a strange incentive to take on
without deciding to, and the numbers are per class, so a zone can price it
differently the day somebody wants to.

Whether a gunner should be hittable where its drone is drawn rather than at
the carrier's point. That would be a different mechanic from the original's,
not a drawing of it: splash would stop wiping a stack and drones could be
picked off one at a time. It might be a better game. It is not a decision to
make by looking at a picture.
