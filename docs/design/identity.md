# What vectorwake is, and what it is not

vectorwake is inspired by Subspace Continuum. It is not a remake, a port, or a
clone. The distinction is not decoration; it decides what we build and what we
refuse to ship.

## The line

**We inherit the system.** Frictionless inertial flight. Energy as health and
ammunition in one pool. A tick-based simulation at centisecond resolution. Teams
called freqs. Arenas whose rules come from configuration. Prizes that upgrade a
ship and vanish on death. Bounty that makes a winning player a target. The lag
response model that degrades a bad connection proportionally instead of banning
it.

**And the numbers, which is the part people expect to be told otherwise.** How
much energy a bullet costs against the bar it draws from, how long a bomb waits
between shots, how fast a hull turns, what a green is worth. A zone here is
tuned to ratios that came out of a real settings file, because inventing them
would have produced a game that felt like nothing in particular, and because
those ratios are the system rather than a picture of it.

These are mechanics and system design. We studied them, wrote down why they
work in [docs/research](../research/README.md), and we are building them
because they are good, not because they are familiar.

**We invent the expression.** Ship names, silhouettes, and roles. Weapon art and
naming. Every sound. Every map. The tileset. The UI. The fiction. The product
name.

**We use none of their assets.** No sprites, no tilesets, no sound effects, no
music, no LVZ overlays, no map files. Not as placeholders, not in prototypes,
not in screenshots. A placeholder has a way of becoming permanent, and an asset
from a thirty-year-old game is somebody's copyrighted work regardless of how
freely it circulates.

The line is between a file somebody made and a fact about how the game works.
A map is a drawing and a sound is a recording, and neither becomes ours by
passing through a converter. A number saying a bomb costs 17% of a full bar is
neither: it is how the thing plays, it is what the paragraph above says we are
here to inherit, and it is not the kind of thing copyright is for. So we ship
tuning derived from a real settings file and we do not ship the file, its map,
its name, or anything it drew.

**We do not use their names.** Not the ships, not the zones, not the game
titles, and not in our marketing. We may say vectorwake is inspired by 1990s
top-down space combat games, and we may cite Subspace in research documents and
in credit where we learned something. We do not imply endorsement, continuity,
or affiliation.

One live exception, small and worth naming rather than quietly keeping. The
zone called Alpha takes its name from the settings file its tuning started
from, which called itself "Alpha Zone Map" in the one line where it said
anything about itself. It is a common enough word that nobody is confused by
it, and it is still a name we did not think of. Renaming it costs a line in
the catalog.

None of this is legal advice, and the plan is to have somebody qualified look at
it before we launch anything public.

## Where the importers fit

[content-pipeline.md](../architecture/content-pipeline.md) describes tools that
read `.lvl` maps and `arena.conf` settings. They exist for one reason: to check
our physics against a known reference. If we import a real settings file, fly
the resulting ship, and it behaves the way the source describes, we understood
the model. That is a test.

Those tools are internal. Their output does not ship, is not distributed, and
does not become vectorwake content. A converted map from an existing zone is
that zone's map.

There is no exception to that now, and there used to be one. Alpha, Chaos and
War were served on maps converted from `.lvl` files supplied by the owner of
this repository, on the reasoning that being given a file settled where it
came from. It does not: whoever drew that map still drew it, and a converter
is not a laundry. Alpha is the only zone left of the three and it now flies a
map this repository generated, from measurements rather than from anybody's
geometry, described in [maps.md](maps.md).

The measurements are the interesting part of that fix. Counting what a map is
made of and building to the counts gets a room that plays in the same register
without a tile of it being traced, which is the same move the rest of this
document makes about ships and sounds. Facts about a work are not the work.

Settings went the other way, and this document used to claim otherwise. Alpha's
tuning began as a translation of a real `arena.conf`, one value at a time, and
it shipped that way. It has moved a long way since: the tech tree was priced by
win rate over thousands of simulated matches, the proximity fuse was rebuilt
after measuring it, thrust and the gun ladder were changed because somebody
flew them and said so, and a hull was removed outright. What is in
`catalog/zones/alpha/zone.toml` now is ours, arrived at from a starting point
that was not.

That is the honest description and it is what the file says. Saying instead
that we ship no zone configuration was a claim this repository contradicted
every time it deployed, which is worse than the practice it was describing.

## Art direction: clean vector

Bright geometric ships on a black field, high contrast, readable at any zoom.

The reasoning is legibility first. A 40-player arena at speed is visual chaos,
and the original's clarity was its most underrated quality: you could tell at a
glance what every dot on your screen was and whose side it was on. Clean vector
gets us that clarity through a different look, without the sprite-sheet
constraints that shaped the original's art.

**Field.** Near-black, under a parallax sky with real depth in it: two vast
washes beneath everything, clouds drawn as runs of knots rather than round
smudges, a band of fine grain along one diagonal, three depths of star in four
temperatures with a rare one burning, a sun and a comet anchored in the map,
the flare the sun throws inside the camera, and a near layer of dust that
streaks along the camera's own motion. Nothing is stored. Every part of it is hashed from position, so a map twice the size costs
the same, and the band and the set pieces are placed from the map's name, so a
room has a sky of its own and the same one every time it is played.

This replaces a rule asking for a sparse starfield and no nebula texture. The
reasoning under that rule is the part worth keeping and it has not moved: the
background never competes with a projectile for attention. It is why the clouds
stay faint enough to read as distance rather than as objects, why the sun is dim
and sits out at the rim of the view instead of over the fight, and why the
band's grain is no brighter than the far stars already were. What changed is the
belief that the only safe background is an empty one.

**Ships.** Crisp geometric silhouettes with thin bright outlines and a darker
fill. Each class has a distinct shape read at a glance, and each shape stays
identifiable at radar scale.

Inside that silhouette a hull is built rather than empty, in four weights of
line: the outline, closed plates, panel lines, and a canopy that is the
brightest cell on the ship and always forward of center. Interior detail draws
in a neutral instrument gray, which keeps the team read on the outline where
this document puts it. The silhouette is lit from the hull's own nose, so an
edge facing the way a ship is pointing draws brighter than one facing away, and
the body fill is lit along the same axis: slate at the bow, near black at the
stern.

This replaces a rule that said detail was minimal by design and a ship was a
silhouette plus a thruster. That was a good rule for as long as the hulls were
six-sided and every line was the same weight, and it stopped being one the
moment the shapes were worth looking at. What has not changed is the constraint
underneath it: a class is identifiable by silhouette alone, and detail that
competes with that is wrong.

**Teams.** A hull carries two colors and only two: yours and not yours. The
outline and the fill tint say which, separated by hue and by luminance so the
distinction survives colorblind vision. That is the read a player needs in the
half second before firing, and putting ten hues on the field would slow it down.

Which side an enemy belongs to is a slower question, so it is answered in text
rather than in paint. Names, bounties, the scoreboard and the stage list write a
side in a color derived from its number, the same color on every machine with
nothing sent to agree on it. Shape carries class, hull color carries friend or
foe, and text carries the side.

This replaces a rule that said team color drove the outline and that there were
two teams to separate. Zones run ten.

**Weapons.** Bright bolts with sharp falloff and short trails. Bombs bloom into
geometric shockwaves rather than fireballs. Every weapon class occupies a
distinct color band, so a screen full of fire is still parseable.

**Effects.** Additive, brief, and cheap. Nothing lingers long enough to hide a
ship, because an effect that obscures gameplay is a bug wearing a costume.

**Interface.** Thin lines, monospace numerals, high contrast, no skeuomorphism.
The radar is a first-class element rather than a corner decoration, since it is
where most of the information actually is.

The whole direction is renderer-friendly, which matters when the target list
includes a browser tab and a phone. Geometry and glow cost less than detailed
sprite sheets, and they scale to any resolution without a redraw.

## Audio direction

Synthetic, punchy, and short. Every sound has a fast attack and a quick decay,
because a busy arena produces dozens of events per second and anything with a
long tail turns into mud.

Weapon classes occupy separate frequency bands, so you can hear a bomb behind
you while guns fire in front. Distance attenuates fast, and where a lot of one
thing happens at once the extra copies are dropped rather than piled up. There
is no combat music; the arena's sound is the game's sound, and a player should
be able to fight with their eyes on the radar.

The kit itself, what each sound is for and what stays silent, is in
[audio.md](audio.md).

## Fiction

Deliberately thin. Subspace never explained itself and was better for it: the
ships have names, the teams have numbers, and the rest is the players' business.

We give the ship classes names and shapes with an internal logic, and we let
zones supply their own framing. A zone author who wants a story tells one. The
base game supplies a world with no plot to contradict.

## Naming

`vectorwake` names the project, the engine, and the client. Zones name
themselves. Ship class names are ours and are listed in [ships.md](ships.md).

## Open questions

Whether the clean vector direction survives contact with a real artist, or
whether it reads as programmer art with a justification attached. Get a
professional on it before M3.

How much visual customization a zone gets. The original let zones replace
tilesets and add overlays, and that is a large part of why zones felt like
different games. Doing the same means our art direction is a default rather than
a rule, which is probably correct and slightly uncomfortable.
