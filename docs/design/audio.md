# Audio

The arena's sound is the game's sound. A pilot should be able to fight with
their eyes on the radar, which means what you hear has to carry information you
can act on: what fired, how big it was, roughly where, and whether it was aimed
at you.

Everything here is ours. Nothing is sampled or recorded, and nothing comes from
the original. That is the rule in [identity.md](identity.md), and the cheapest
way to keep it is to build every sound out of arithmetic rather than source one.

## Every sound is arithmetic, and it runs on the player's machine

The kit is twenty-four sounds and a little over a megabyte of 16-bit PCM. None
of it is in the download. `client/ext/simcore/src/sfx.c` synthesises all of it
at boot, in about a fifth of a second, and hands the buffers to the engine.

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
| `gun0` to `gun3` | 85 to 132 ms | a bolt leaving the rail, one per rung |
| `bomb0` to `bomb3` | 220 to 660 ms | a heavier charge leaving the tube |
| `blast0` to `blast3` | 320 to 850 ms | a bomb going off, sized by the hole |
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

## Every rung is its own sound

A rung is the most useful thing about an incoming round. It is the whole of the
damage a bolt carries and the whole of the radius a bomb clears, and a pilot
cannot read it off anything: the round is three pixels wide and its colour, which
does carry the rung, is behind them as often as in front. So each rung is its own
sound, and it has to be one you can name after hearing it once.

The ladder used to work the other way, on the argument that a rung is the same
weapon harder and so must not sound like a different weapon: the weight climbed
and nothing else moved. The argument is right about the mechanic and it was wrong about
what came out. `client/tools/sfxladder` measures the gap between two sounds as
the difference across third-octave bands and hundredths of a second, and the old
rungs landed 2.5 to 4.5 dB apart, ends 5.0 and 9.4 apart, which is a number you
can print and not a difference anybody hears. What ended it was somebody who had
flown the whole ladder asking for a sound per rung.

They are 6.4 to 7.3 apart now, ends 12.1 to 14.9, and each ladder climbs on every
axis at once. One axis moving is heard as the same sound slightly off; all of
them moving together is heard as a different thing. So the pitch falls, weight
arrives underneath, the drive comes up, and the sound runs longer. Deeper reads
as bigger without anybody having to learn it, and the check holds the fall
monotonic so a rung is never heavier and brighter at the same time.

What each family climbs on differs, because what a rung buys differs. A gun rung
is flat damage on an identical bolt, so the bolt drops a sixth over three rungs,
grows a low-mid body, and picks up a second square slightly flat of the first
that beats against it into a snarl; the top rung is a slam with sub under it. A
bomb rung is blast radius, so the charge leaves a bigger tube: the fall goes down
and slows, the saw gives way to the round body under it, the sub arrives and then
dominates, and the whole thing takes three times as long to clear.

Two things bound the climb. Rung zero of the gun is byte for byte the sound that
was there before the rungs were told apart, so nothing about a fresh spawn moves.
And a rung must still belong to its family: a gun that has climbed into a bomb's
register tells a pilot something false about what is coming at them, which is
worse than a gun that all sounds the same. The gun's air stays bright and gets
brighter as the bombs go dark. And no bomb cracks: every one of them swells out
of the tube, five to sixty-six milliseconds by rung, where nothing in the gun
ladder swells at all. The check holds the nearest gun-to-bomb pair further apart
than the widest step inside any ladder; it is 9.5 against 7.3.

Loudness cannot come from the buffer. Every one is normalised to the same peak
before it is written, so a fatter buffer is a different timbre at the same level.
The climb lives in the per-sound gains instead: 0.30 to 0.40 for the gun, 0.55 to
0.70 for the bomb, 0.62 to 0.84 for the detonation, which stops under a death's
0.85.

## What a bomb rung buys is audible when it goes off

The detonation was one sound for every rung until now, which is the odd half of
the ladder above: a bomb level is bought for the blast, and the blast was where
it could not be heard. The reason was real. A shell in flight carries a spec,
which says what a projectile does and not which rung fired it.

The rung turned out to be readable off the spec anyway, by the same route that
colours the round. But the four detonations are picked by radius instead, which
answers one more case. For a bomb the two say the same thing, since a rung is
exactly a wider blast. A repel is on no ladder at all: its shove clears 512
pixels against a top rung bomb's 320, and asked for its level it answers -1, so
by rung it would have been played as the smallest thing in the kit. The size of
the hole covers both, and it is the hole the player is watching.

A bigger charge is duller, longer and later rather than louder. The crack at the
front is the same fifty milliseconds at every rung, because that is the
detonation itself. Behind it a rumble arrives, and how long it waits, how dark it
is and how long it rolls is the rung: nothing at all at the bottom, ninety
milliseconds behind the crack at the top, where it also runs three times as
long.

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

Length is the one axis the rungs climb only as far as the arena allows. A gun
fires every 250 ms whatever rung it is on, so a bolt that grew with the rung
would start overlapping its own repeat at the top; 132 ms is where that stops.
A bomb is thrown every 1.5 seconds and can have the room.

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
that has to be recorded four times. It is also what makes the claim above
checkable: `make -C client/tools check` renders the kit with the synth the
browser runs and fails the build when two rungs have collapsed into one sound,
which is not a thing you can ask of a folder of wav files.

No sound plays because a moment felt important. Every one of them reports
something that happened in the arena.
