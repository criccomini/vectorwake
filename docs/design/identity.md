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

These are mechanics and system design. We studied them, wrote down why they
work in [docs/research](../research/README.md), and we are building them
because they are good, not because they are familiar.

**We invent the expression.** Ship names, silhouettes, and roles. Weapon art and
naming. Every sound. Every map. The tileset. The UI. The fiction. The product
name.

**We use none of their assets.** No sprites, no tilesets, no sound effects, no
music, no LVZ overlays, no map files, no shipped zone configurations. Not as
placeholders, not in prototypes, not in screenshots. A placeholder has a way of
becoming permanent, and an asset from a thirty-year-old game is somebody's
copyrighted work regardless of how freely it circulates.

**We do not use their names.** Not the ships, not the zones, not the game
titles, and not in our marketing. We may say vectorwake is inspired by 1990s
top-down space combat games, and we may cite Subspace in research documents and
in credit where we learned something. We do not imply endorsement, continuity,
or affiliation.

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

One exception, and it is about provenance rather than about converters. Alpha,
Chaos and War are served on maps converted from `.lvl` files supplied by the
owner of this repository, who asked for them by name. Those three ship. A file
somebody else drew does not become shippable by passing through the same tool,
so the rule above is unchanged for everything we did not receive that way.

## Art direction: clean vector

Bright geometric ships on a black field, high contrast, readable at any zoom.

The reasoning is legibility first. A 40-player arena at speed is visual chaos,
and the original's clarity was its most underrated quality: you could tell at a
glance what every dot on your screen was and whose side it was on. Clean vector
gets us that clarity through a different look, without the sprite-sheet
constraints that shaped the original's art.

**Field.** Near-black, with a sparse parallax starfield and no busy nebula
texture. The background never competes with a projectile for attention.

**Ships.** Crisp geometric silhouettes with thin bright outlines and a darker
fill. Each class has a distinct shape read at a glance, and each shape stays
identifiable at radar scale.

Inside that silhouette a hull is built rather than empty, in four weights of
line: the outline, closed plates, panel lines, and a canopy that is the
brightest cell on the ship and always forward of centre. Interior detail draws
in a neutral instrument grey, which keeps the team read on the outline where
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

**Teams.** Team color drives the outline and the fill tint, and the two teams
are separated by hue and by luminance, so the distinction survives colorblind
vision. Shape carries class, color carries team, and neither carries both.

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
you while guns fire in front. Events near you duck events far away, and distance
attenuates fast. There is no combat music; the arena's sound is the game's
sound, and a player should be able to fight with their eyes on the radar.

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
