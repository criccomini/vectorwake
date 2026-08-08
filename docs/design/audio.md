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
at boot, in about a sixth of a second, and hands the buffers to the engine. The
seven soundtracks that are not playing yet are not among them: those are built
while the game runs, a few milliseconds at a time.

That saves the download, but the reason it matters more is that a sound becomes
a thing with parameters instead of a file. A bomb can be pitched by its rung
because the bomb is a function.

The engine plays 22050 and 44100 Hz and nothing else. A buffer at any other rate
is accepted without complaint and is silent, which was found the slow way.

## The vocabulary is deliberately narrow

Bolts crack and charges heave. Explosions are noise under a descending sine,
which is what gives a blast a body rather than a hiss. The interface ticks.

| Sound | Length | What it is |
|---|---|---|
| `gun0` to `gun3` | 70 to 155 ms | a bolt leaving the rail, a weenie up to something nasty |
| `bomb0` to `bomb3` | 200 to 780 ms | a charge leaving the tube, tinny up to throaty |
| `blast0` to `blast3` | 280 to 850 ms | a bomb going off, sized by the hole |
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
| `music` | 15 to 23 s, held | whichever of the eight tracks is playing |

## Every rung is its own sound

A rung is the most useful thing about an incoming round. It is the whole of the
damage a bolt carries and the whole of the radius a bomb clears, and a pilot
cannot read it off anything: the round is three pixels wide and its colour, which
does carry the rung, is behind them as often as in front. So each rung is its own
sound, and it has to be one you can name after hearing it once.

That took three tries and the first two were the same mistake. Both wrote one
recipe and walked its numbers, the first moving weight alone and the second
moving every parameter it had. They measured 2.5 to 4.5 dB apart and then 7.6 to
8.4, and the player who flew both called the first one sound and the second
slight alterations of each other. The lesson is that a recipe stretched far
enough is still a recipe: every rung of it arrives as the same event slightly
off, which is not the question a pilot is asking.

So the rungs are built differently rather than tuned differently. Eight
functions, no shared table, and a brief for each of them.

| Rung | Gun | Bomb |
|---|---|---|
| 0 | a weenie: a pulse an eighth of a cycle wide, high, no drive at all | tinny and hollow: a square rung through a narrow resonance up at 1.4 kHz |
| 1 | a crack: the first one that is a gun rather than a toy | a real charge, the tin now a ring over the top rather than the whole of it |
| 2 | a snarl: two pulses beating, dragged off the harmonic series | throaty: the resonance has come down out of the tin and into the chest |
| 3 | nasty: sub, a throat, and folded past the point of damage | throaty and bass heavy, almost nothing above two hundred hertz |

Three tools arrived with them, because none of this can be built out of
oscillators and lowpasses. A resonator gives a sound a body to have come out of,
which is the whole difference between the tin and the throat. Ring modulation
moves every partial off the harmonic series, which is what makes metal sound
like metal rather than like a low note. And a wavefolder turns a peak back on
itself instead of rounding it off, so what it throws up was never in the source:
drive sounds like loudness and folding sounds like damage.

The ladders are steep now. The gun falls two octaves from rung zero to rung
three and the bomb falls two and a half, and each step is at least a tritone,
which is an interval nobody has to compare two sounds to notice.

## What still tells a gun from a bomb

Not register, any more. A tinny bomb is a high one and a nasty bolt is a low
one, so the brief that made the rungs distinct also drove the lightest bomb and
the heaviest bolt into the same octave. They sit two semitones apart.

What separates them is the front. Every bolt cracks, reaching full level in four
and a half milliseconds at every rung. Every charge heaves out of the tube:
twenty-six milliseconds at the lightest and fifty-eight at the heaviest, and the
check requires the quickest bomb to take at least twice as long to arrive as the
slowest bolt. Neither ladder touches that, so it holds however far either one
climbs.

It replaced a rule that did not survive the brief. The check used to hold the
nearest gun-to-bomb pair further apart than the widest step inside either
ladder, on the theory that two weapons should differ more than two rungs of one
weapon do. That theory is what capped the second attempt: the gun could not be
widened without the top bolt measuring nearer the lightest shell than its own
neighbour.

## Loudness is not in the buffer, and the gains are no longer a ladder

Every buffer is normalised to the same peak before it is written, so the buffer
decides timbre and nothing else. The climb has always lived in the per-sound
gains instead.

What changed is that the gains no longer look like a climb. A folded bolt is a
dense buffer and a resonant one is a sparse one, so eight sounds at the same
peak are eight different loudnesses, and the numbers that make the heard climb
even are not themselves in order: the gun runs 0.30, 0.26, 0.38, 0.43 and the
bomb runs 0.55, 0.58, 0.50, 0.39. Reading those as a mistake is the obvious
error and this paragraph is here to stop it.

They come from a measurement rather than an ear. Each sound's loudest 300
millisecond window is what a loudness meter integrates, and it is the right
window here for two reasons: a short sound is not credited for the silence
around it, and a long one is not credited twice for lasting. Solving for an even
two decibels a rung gives the numbers above; the detonations get three a rung
instead, since the rung is bought for the blast and that is where it should be
felt.

Total energy was tried first and is wrong, because it makes a 780 millisecond
bomb four times the event a 200 millisecond one is. A-weighting is wrong in the
other direction: it discounts bass so hard that an even climb wanted a gain of
3.1 on the heaviest bomb, which is not a number a gain can be.

## What a bomb rung buys is audible when it goes off

A bomb level is bought for the blast, so the blast is where it has to be heard.
It was one sound for every rung for a long time, and the reason was real: a shell
in flight carries a spec, which says what a projectile does and not which rung
fired it.

The rung is readable off the spec after all, by the same route that colours the
round. But the four detonations are picked by radius instead, which answers one
more case. For a bomb the two say the same thing, since a rung is
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
would start overlapping its own repeat at the top. A bomb is thrown every 1.5
seconds and can have the room.

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

Two sounds are held: thrust and the soundtrack. Both are mixed under
everything else because both are always there. Thrust in particular is the
sound a pilot hears most, since it runs for as long as a finger is on the key,
and it sat at 0.26 until somebody flew with it and said so; it is 0.18 now. Everything else answers
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

Eight tracks, eight bars each, one playing under everything for as long as the
game is open. Each has to come round without a seam and stay welcome after the
fortieth pass, which are different problems: the first is arithmetic and the
second is restraint. So there is no melody doing anything clever, and nothing in
any of them arrives more often than the ear stops noticing.

| | Key | Chords | Tempo |
|---|---|---|---|
| Neon wake | A minor | i-VI-III-VII | 100 |
| Long dark | D minor | i-VII-VI-VII | 84 |
| Coast road | E minor | i-III-VII-VI | 90 |
| Cold open | C minor | i-VI-VII-VI | 105 |
| Undertow | F minor | i-VII-VI-V | 98 |
| Overdrive | G minor | i-VI-III-VII | 120 |
| Low ceiling | B minor | i-VII-VI-VII | 108 |
| Redline | F# minor | i-VI-VII-i | 126 |

Neon wake is the one that was here when there was only one, unchanged to the
byte. i-VI-III-VII is the progression the whole style is built on and the reason
every track in it sounds like every other, so two of the eight use it and the
other six do not.

A tempo is not free to be any number. A beat is 22050 * 60 / BPM samples and the
loop only closes if that divides exactly, so the tempo has to be a divisor of
1323000. The eight above are; 96 and 112 are not, which is worth knowing before
wondering why they are absent.

There is no combat music and there will not be. The music does not know what is
happening, does not swell, and never competes with the thing a pilot is trying to
hear.

## Three minutes each, and the next one built in the gaps

The game plays a track for three minutes and moves to the next. That is long
enough that nobody hears a rotation as a change of subject, and short enough
that an hour at the game is not one loop over and over for an hour. Where a session starts is random, so
two people in the same arena are not listening in step and somebody who plays for
ten minutes has not heard only the first three.

Building a track is about an eighth of a second of arithmetic. Spending that on
the frame a rotation falls due is a frozen frame in the middle of a fight, so it
is not spent there: the synth cuts a track into forty-two steps, none longer than
about eight milliseconds, and the client spends one step at a time on frames that
had room, starting as soon as the previous rotation lands. An eighth of a second
of work with three minutes to find room in is never in a hurry, so a frame that
already ran long is not asked to carry a step as well.

One sound component holds whichever track is playing. Eight components would
mean eight buffers of about a megabyte each, seven of them silent, which is most
of a page's worth of memory to save a copy. Swapping the buffer is a copy and
costs nothing; only a build that somehow did not finish costs anything at the
rotation, and it costs a hitch rather than a silence.

It gets its own mixer group and its own row in the menu, because wanting the game
loud and the music off is the commonest thing anybody wants from a game's audio
and one number cannot say it. Its ceiling sits below the effects' on purpose: a
soundtrack you have to shout over is one a player turns off, and then all of this
was for nothing.

| Setting | Off | Quiet | Half | Full |
|---|---|---|---|---|
| Volume | 0 | 0.3 | 0.6 | 1.0 |
| Music | 0 | 0.2 | 0.45 | 0.75 |

A track waits for the browser's audio to be awake before it starts, rather than
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
