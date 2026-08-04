# Audio

The arena's sound is the game's sound. A pilot should be able to fight with
their eyes on the radar, which means what you hear has to carry information you
can act on: what fired, how big it was, roughly where, and whether it was aimed
at you.

Everything here is ours. Nothing is sampled or recorded, and nothing comes from
the original. That is the rule in [identity.md](identity.md), and the cheapest
way to keep it is to build every sound out of arithmetic rather than source one.

## Every sound is arithmetic, and it runs on the player's machine

The kit is twenty-one sounds and about a megabyte of 16-bit PCM. None of it is
in the download. `client/ext/simcore/src/sfx.c` synthesises all of it at boot,
in about a fifth of a second, and hands the buffers to the engine.

That saves the download, but the reason it matters more is that a sound becomes
a thing with parameters instead of a file. A bomb can be pitched by its rung
because the bomb is a function.

The engine plays 22050 and 44100 Hz and nothing else. A buffer at any other rate
is accepted without complaint and is silent, which was found the slow way.

## The vocabulary is deliberately narrow

Weapons are short and bright with a hard transient. Explosions are noise under a
descending sine, which is what gives a blast a body rather than a hiss. The
interface ticks.

| Sound | Length | What it is |
|---|---|---|
| `gun0` to `gun3` | 85 to 106 ms | a bolt leaving the rail, one per rung |
| `bomb0` to `bomb3` | 240 to 300 ms | a heavier charge leaving the tube |
| `blast` | 550 ms | a bomb going off |
| `death` | 950 ms | a ship coming apart, the one event allowed a full second |
| `hit` | 70 ms | something struck your hull: a crack, not a tone |
| `bounce` | 75 ms | a wall |
| `spawn` | 320 ms | coming back: rising, clean, and not a weapon |
| `prize` | 220 ms | a green picked up, two intervals up |
| `rust` | 260 ms | a green that took something, the same intervals downward |
| `charge` | 180 ms | something leaving your hands |
| `flag` | 300 ms | a flag changing hands |
| `thrust` | 500 ms, held | a rocket, not an engine |
| `ui_move`, `ui_go` | 35 and 160 ms | the interface |
| `music` | 19.2 s, held | the soundtrack |

## A level is the same weapon harder

The panel says it and the core does it: a gun rung adds flat damage to an
identical bolt fired at an identical rate, and a bomb rung leaves the shell alone
and widens the blast. So the rungs are not four weapons, and they must not sound
like four weapons.

The square and the sine that make a bolt sound like a bolt do not move between
rungs at all. What climbs is weight. Measured across the four, the 200 to 800
hertz band carries 0.9, 2.0, 4.4 and 6.8 per cent of the energy, roughly a
doubling a rung. The bomb pitches its whole fall down instead, its sub going from
13.5 to 20.8 per cent.

Loudness cannot come from the buffer. Every one is normalised to the same peak
before it is written, so a fatter buffer is a different timbre at the same level.
The climb lives in the per-sound gains instead: 0.30 to 0.40 for the gun, 0.55 to
0.70 for the bomb.

Rung zero is byte for byte the sound that was there before rungs existed, so
nothing changes for a fresh spawn.

## Nothing rings longer than the thing that caused it

A busy arena produces dozens of events a second, and anything with a tail turns
into mud. Hence the lengths in that table: a bolt is over before it registers,
and only a death gets a full second.

Three more rules keep a firefight busy rather than additive.

Each family gets a hard budget per frame: three guns, three hits, two each of
bounces, blasts, deaths and bombs, one of everything else. A fourth gun in the
same frame is dropped rather than mixed. The budget counts the family and not the
component, or a pilot at the top of the ladder would be four times as loud as one
at the bottom.

Distance falls off fast. Nothing beyond 760 world pixels is audible at all,
attenuation is the square of what is left, and anything under about 3.5 per cent
of full gain is dropped outright rather than mixed at a level nobody can hear.

Every shot is pitched by plus or minus seven per cent, so repeats do not phase
into a machine gun.

## Silence is a decision

A bouncing bullet makes no sound when it comes off a wall. That is chosen rather
than missing, and there is a comment beside the gap in the code saying so,
because the obvious reading of a missing case is that somebody forgot.

It was the other way round once. A ship's bounce and a weapon's ricochet shared
one event that carried different things, so every ricochet put a wall thump on
the shooter's own hull, anywhere on the map. Fixing that meant deciding what a
ricochet should sound like, and the answer was nothing.

There is a real argument for revisiting it. A bullet coming back off a wall is
information you cannot see, and this document opens by saying sound should carry
exactly that. If it comes back it should be its own thin ricochet at the bullet's
position rather than a second muzzle crack.

## Everybody's guns, not only yours

A fire event belongs to the one pilot this client predicts, and that is not a gap
in the event. The core is handed your buttons and nobody else's, so a stranger is
flown coasting, their trigger is never pulled here, and there is nothing for it to
raise. Their rounds arrive already in the air, in a snapshot.

Left at that, an arena sounds of explosions and wall hits with nothing leaving the
guns making them, which reads as though everyone else is firing blanks. It sounded
that way for a while.

Two things in every snapshot say a stranger fired. Their fire cooldown is the
honest one: a shot sets it and every tick takes one off, so on a hull nothing
local can fire it only counts down, and a rise came off the wire. What it cannot
say is which trigger, so the rounds answer that. Counting their live ones by
family over the same tick, a cooldown that rose while their bomb count did was a
bomb.

Both have to agree, because each is wrong on its own. A round appearing is also
what a mispredicted collision looks like when the next snapshot puts it back.
Missing a shot is cheaper than inventing one, so the price of insisting on both is
the shot fired and finished inside a single snapshot, which nobody was going to
pick out of a firefight anyway.

## A fragment is not a trigger pull

Shrapnel used to raise the same fire event a trigger raises, because both come out
of one function in the core. The client hears that event as a muzzle and puts it
on the hull that pulled it, so a bomb breaking up left a gunshot and a muzzle
flash on the bomber, wherever on the map it had gone off. Only a round somebody
aimed raises one now.

## Held sounds and answered sounds are different problems

Two sounds are held: thrust and the soundtrack. Everything else answers
something, an input or an impact, and has to arrive with it.

That distinction decides more than how the two are mixed. It decides how a sound
reaches the speaker at all. Defold's browser sound device keeps four mixed chunks
queued ahead, which is 43 to 75 milliseconds of audio always waiting to play, so
a gun fired now joins the back of a queue. Measured in the shipped page, a
one-shot played straight into the browser's audio graph instead starts 2.7
milliseconds out.

So one-shots go straight there and held sounds stay on the mixer, where the delay
lands on the start of a rumble that runs for minutes and nobody can time it. The
mechanism, and the two alternatives that were measured and rejected, are in
[client/README.md](../../client/README.md).

The general rule this leaves: a sound that answers a player's hands is worth
engineering for latency, and a sound that describes a state is not.

## The soundtrack is furniture

One track, eight bars, A minor, i-VI-III-VII, a hundred beats a minute, playing
under everything for as long as the game is open. It has to come round without a
seam and it has to stay welcome after the fortieth pass, which are different
problems: the first is arithmetic and the second is restraint. So there is no
melody doing anything clever, and nothing in it arrives more often than the ear
stops noticing.

There is no combat music and there will not be. The music does not know what is
happening, does not swell, and never competes with the thing a pilot is trying to
hear.

It gets its own mixer group and its own row in the menu, because wanting the game
loud and the music off is the commonest thing anybody wants from a game's audio
and one number cannot say it. Its ceiling sits below the effects' on purpose: a
soundtrack you have to shout over is one a player turns off, and then all of this
was for nothing.

| Setting | Off | Quiet | Half | Full |
|---|---|---|---|---|
| Volume | 0 | 0.3 | 0.6 | 1.0 |
| Music | 0 | 0.2 | 0.45 | 0.75 |

The track waits for the browser's audio to be awake before it starts, rather than
starting into a page that cannot make sound yet. Audio mixed into a suspended
context is discarded rather than held, so a track started at boot runs on
silently and a player joins it in the middle.

## What we do not do

We do not copy the original's audio, and we have not studied it. Its sounds are
assets, and assets are the one thing this project takes none of. The wire format
tells us bouncing was part of a shot's identity rather than something noticed
later, since a bouncing bullet is its own weapon type and bouncing shrapnel has
its own bit, but nothing in `docs/research` describes what any of it sounded
like, on purpose.

We do not sample, and we do not intend to. A recorded kit would be a decision
that could not be tuned, and a bomb that cannot be pitched by its rung is a bomb
that has to be recorded four times.

No sound plays because a moment felt important. Every one of them reports
something that happened in the arena.
