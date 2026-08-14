# Audio

The arena's sound is the game's sound. A pilot should be able to fight with
their eyes on the radar, which means what you hear has to carry information you
can act on: what fired, how big it was, roughly where, and whether it was aimed
at you.

Everything here is ours. Nothing is sampled or recorded, and nothing comes from
the original. That is the rule in [identity.md](identity.md), and the cheapest
way to keep it is to build every sound out of arithmetic rather than source one.

## Every sound is arithmetic, and it runs on the player's machine

The kit is twenty-five components and a little over a megabyte of 16-bit PCM.
None of it is in the download. `client/ext/simcore/src/sfx.c` synthesises all of it
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
| `gun0` to `gun3` | 62 to 155 ms | a bolt leaving the rail, glass up to metal |
| `bomb0` to `bomb3` | 220 to 780 ms | a charge leaving the tube, tinny up to throaty |
| `blast0` to `blast3` | 340 to 900 ms | a bomb going off, sized by the hole |
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
| `music_a`, `music_b` | 15 to 23 s, held | the two slots the eight tracks alternate between |

## Every rung is its own sound

A rung is the most useful thing about an incoming round. It is the whole of the
damage a bolt carries and the whole of the radius a bomb clears, and a pilot
cannot read it off anything: the round is three pixels wide and its color, which
does carry the rung, is behind them as often as in front. So each rung is its own
sound, and it has to be one you can name after hearing it once.

The first two attempts were the same mistake. Both wrote one recipe and walked
its numbers, the first moving weight alone and the second moving every parameter
it had. They measured 2.5 to 4.5 dB apart and then 7.6 to 8.4, and the player who
flew both called the first one sound and the second slight alterations of each
other. The lesson is that a recipe stretched far enough is still a recipe: every
rung of it arrives as the same event slightly off, which is not the question a
pilot is asking.

So the rungs are built differently rather than tuned differently. Eight
functions, no shared table, and a brief for each of them.

| Rung | Gun | Bomb |
|---|---|---|
| 0 | glass: a harmonic ratio and an index gone in four milliseconds, landing on E6 | tinny and hollow: a square rung through a narrow resonance up at 1.4 kHz |
| 1 | hollow: seven over four, so the sidebands sit a fourth under A5 | a real charge, the tin now a ring over the top rather than the whole of it |
| 2 | metal: root two lands nothing on a harmonic of anything, over C5 | throaty: the resonance has come down out of the tin and into the chest |
| 3 | the bell ratio, held open for a fifth of the sound before it collapses onto E4 | throaty and bass heavy, almost nothing above two hundred hertz |

The bombs brought three tools with them, because none of that can be built out
of oscillators and lowpasses. A resonator gives a sound a body to have come out
of, which is the whole difference between the tin and the throat. Ring modulation
moves every partial off the harmonic series, which is what makes metal sound
like metal rather than like a low note. And a wavefolder turns a peak back on
itself instead of rounding it off, so what it throws up was never in the source:
drive sounds like loudness and folding sounds like damage.

Both throats sit below the pulse rather than over it, which is the whole of why
they are heard. Put at the pulse's own register a resonance only re-emphasises
what is already the loudest part of the sound; measured on the second bomb rung,
that moved the formant peak from 5.5 times the average band to 5.3, which is
backwards. Below the pulse it is a formant rather than a boost.

The ladders are steep. The bomb falls a little over two and a half octaves from
rung zero to rung three, the gun just under two, and every step on either is at
least a tritone, which is an interval nobody has to compare two sounds to
notice.

## A bolt is a strike that resolves into a note

Every bolt is phase modulation over a comb. Modulating a sine's phase with a
second sine throws up a skirt of sidebands, and how far the skirt reaches is the
index, so an index that starts high and collapses is a spectrum that starts as a
wall and clears into one tone. Nothing a filter does to a square wave looks like
that. The comb behind it is a delay line under four milliseconds long fed back
through a one-zero lowpass, which at that length is not an echo but the size of
the thing the sound came out of. Between them they carry one idea: the gun is a
body being hit, the rung is how big the body is, and how hard it is hit decides
whether what comes back is a note or a noise.

Two things climb the ladder and they climb in different currencies.

The ratio between modulator and carrier goes 2, 1.75, 1.414, 2.76. A whole
number lands every sideband on the harmonic series and the burst is a bright
clean instrument. Seven over four is still rational, so it holds together, but
its sidebands sit a fourth under the note and it reads hollow. Root two lands
nothing on a harmonic of anything, which is the definition of metal, and 2.76 is
the ratio that makes bells. Rung three is not a heavier version of rung zero. It
is a different material, and material is the kind of difference a listener
names.

The index goes 3 to 11 and its collapse slows from a bite of 7 to one of 2.2, so
rung zero is over as a wall before it has been heard as one and rung three
snarls for a fifth of its length before it finds a pitch. Weight is the audible
cost of firing rather than a bigger number.

What holds the four together is that they all land somewhere. The carrier falls
onto E6, A5, C5 and E4, an A minor triad descending across two octaves and in
tune to within a fifth of a semitone, and each bolt's comb is tuned to its own
landing note so the body rings at the pitch the strike resolves to. Four
frequencies an equal distance apart are one thing at four heights. Four
intervals the ear already knows are four places, and it can name which one it is
hearing without having heard the others first.

One tool went in to make that hold. A comb keeps handing back whatever it is
given for as long as it is given anything, so a body with any ring in it props
the sound up against the decay its sources were written with, and the envelopes
came out flat and occasionally climbing. A taper laid over the finished buffer
puts the decay back afterwards. It has no attack of its own, so the transient it
covers survives.

Measured, the rungs are 6.9, 12.3 and 9.4 dB apart and fall 6.6, 7.4 and 8.2
semitones, 18.9 dB and 22.2 semitones end to end. The share of tail energy
sitting on the note's own harmonic series runs 0.91, 0.86, 0.85, 0.73, which
puts the climb from instrument to struck plate in a single number.

Three answers came before this one and all three were one instrument at four
settings: a square wave falling, filtered, driven, and in the last of them
crushed down to a few dozen levels. Pulling those settings further apart bought
measurement and not much hearing, because a listener does not grade a timbre,
they name it, and four settings of one thing have one name. All three are worth
keeping written down, because each was wrong in a way only a listen found.

The first moved weight alone and every rung came out the same sound slightly
off. The second swung into beams: two and a
half octaves of fall, almost no noise, and a self-feeding delay so each shot
arrived three times. Those measured the widest this ladder has ever been, 9.9,
8.5 and 8.1 dB apart, and they were film rather than arcade, with an echo on a
weapon fired four times a second that the arena has no room for. The third went
the other way, dry and bit-crushed, and read as a machine rather than a gun. The
delay and the crusher left with them and are in the history if either is ever
wanted again.

## A bigger charge comes back from further away

Every detonation and the two lightest charges end in a delay line fed back on
itself. How far out the returns come from, how many of them there are, and how
far down the band they sit are the rung. The bodies are untouched.

| Rung | The charge | The detonation |
|---|---|---|
| 0 | 35 ms out, four returns, 1.1 to 5 kHz | 30 ms, 900 Hz to 5.2 kHz |
| 1 | 75 ms, 700 Hz to 3 kHz | 55 ms, 650 Hz to 3 kHz |
| 2 | dry | 85 ms, 420 Hz to 1.7 kHz |
| 3 | dry | 130 ms, 280 to 950 Hz |

The top two charges are dry, which is not where this started. They had rooms of
150 and 200 milliseconds and the player who flew them asked for both to go. It
is a defensible place to land even though it inverts the brief: the two heavy
charges are the ones with a throat that sweeps for most of a second, and handing
a sound that is already moving a set of copies of itself blurs the movement. A
tin can has nothing to blur. The detonations keep theirs at every rung, and that
is where a player hears the room anyway: the launch is a sound you make and the
blast is a sound the map makes back.

Two things about that are not what a delay usually does, and both came out of a
listen that failed.

The return is band limited rather than only darkened. The first version put a
lowpass in the loop, on the sound reasoning that air and every surface take the
top end first. It measured enormous, forty decibels of tail where there had been
silence, and the player who flew it could not hear any difference at all. A bomb
here is a wall of sub with almost nothing above two hundred hertz, so a dark
return lands exactly where the body already is, twenty-five decibels down, on
speakers that mostly cannot make those frequencies anyway. A real distant
reflection is not a sub rumble: long wavelengths bend around obstacles and
arrive as part of the direct sound, and what comes back off a far wall as a
separate event is the mid band. So the loop takes the bottom off as well as the
top and the return sits in the register these sounds deliberately leave empty.

And how loud it is is a separate number from how many times it repeats. Run as
one, which is what a plain feedback delay does, the return can never be louder
than what it reflects, and what it is reflecting has nothing in the band it
returns in. A room is allowed to hand back more mid than arrived at it: it
concentrates into a few arrivals what left as a spread. A send and return says
so, and it is the difference between an echo you can measure and one you can
hear.

The detonations are held quieter than the launches at every rung, and the
reason is the crack. A blast is already most of a second of decaying noise, so
widely spaced repeats inside it read as flutter, and a return loud enough to
beat the crack moves where the event happened. The crack is what says a
detonation occurred at all, so the room climbs in delay and in number of
arrivals and never in level.

Nothing here outlasts what caused it. The two charges that do have rooms run
for 220 and 440 milliseconds. Charges have no firing delay, so consecutive
ones may overlap their echoes; the dry attack still marks each use. The
detonations barely moved because a blast has to be finished while its own
shockwave is on screen and the last spark of one is gone in 900 ms.

One thing had to be got right for any of this to be only an echo. Every envelope
in this synth decays over the buffer's own length rather than over a span of
time, which is what lets one curve fit sounds of four sizes, and it means a
buffer made longer to hold a tail is a longer sound. The first attempt simply
extended the buffers, and the swept resonators stretched with them: the bodies
came out slower and darker and boot went from 36 milliseconds to 45, which is a
rewrite rather than an echo. Each body is built at the length it has always had
and copied into the longer buffer, and the rest of the buffer belongs to the
reflections.

## What still tells a gun from a bomb

Not register, any more. A tinny bomb is a high one and a nasty bolt is a low
one, so the brief that made the rungs distinct also drove the lightest bomb and
the heaviest bolt onto the same note. They measure within a hertz of each other.

What separates them is the front. Every bolt cracks, reaching full level inside
four and a half milliseconds at every rung. Every charge heaves out of the tube:
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

Every buffer is normalized to the same peak before it is written, so the buffer
decides timbre and nothing else. The climb has always lived in the per-sound
gains instead.

What changed is that the gains no longer look like a climb. A folded bolt is a
dense buffer and a resonant one is a sparse one, so eight sounds at the same
peak are eight different loudnesses, and the numbers that make the heard climb
even are not themselves in order: the gun runs 0.45, 0.35, 0.42, 0.51 and the
bomb runs 0.54, 0.62, 0.81, 0.95. Reading those as a mistake is the obvious
error and this paragraph is here to stop it.

They come from a measurement rather than an ear. Each sound's loudest 300
millisecond window is what a loudness meter integrates, and the window is fixed
rather than cut to each sound: a bolt that is over in sixty milliseconds does
not get to read as loud as a shell that fills the window, and a shell that runs
past the window is not credited for lasting. Solving for an even two decibels a
rung gives the numbers above; the detonations get three a rung instead, since
the rung is bought for the blast and that is where it should be felt.

The window runs through a highpass at 120 Hz first, and that arrived late and by
complaint. Read flat, the meter counts forty hertz the same as a thousand. A
rung three bomb is nearly all forty hertz, and almost nothing anybody plays this
on can make that, so a flat reading was crediting energy that never reached a
listener and handing the heaviest weapon in the game the quietest gain in its
family: 0.38, against 0.55 for the tin can two rungs below it. The player who
flew it reported the red charge as hard to hear, which is what a meter measuring
the wrong thing feels like from the other end. Weighted, the same sound wants
0.95.

A gain cannot exceed one, and that is a real ceiling rather than a rounding
problem. The heaviest detonation wants 1.76 and is capped, so it sits about five
decibels under where an even ladder would put it. The fix for that is less sub
in the buffer, which is a change to what the sound is rather than to how loud it
is, and it has not been made.

Two other readings were tried and are wrong. Total energy makes a 780
millisecond bomb four times the event a 200 millisecond one is. Full A-weighting
goes past the ceiling rather than up to it, discounting bass so hard that an even
climb wanted 3.1 on the heaviest bomb. One pole at 120 Hz is the crude version of
the same idea that stays inside what a gain can do.

## What a bomb rung buys is audible when it goes off

A bomb level is bought for the blast, so the blast is where it has to be heard.
It was one sound for every rung for a long time, and the reason was real: a shell
in flight carries a spec, which says what a projectile does and not which rung
fired it.

The rung is readable off the spec after all, by the same route that colors the
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

## Three minutes each, crossfaded, with the next one built in the gaps

The game plays a track for three minutes and crossfades into the next. That is
long enough that nobody hears a rotation as a change of subject, and short
enough that an hour at the game is not one loop over and over for an hour. Where a session starts is random, so
two people in the same arena are not listening in step and somebody who plays for
ten minutes has not heard only the first three.

Building a track is about an eighth of a second of arithmetic. Spending that on
the frame a rotation falls due is a frozen frame in the middle of a fight, so it
is not spent there: the synth cuts a track into forty-two steps, none longer than
about eight milliseconds, and the client spends one step at a time on frames that
had room, starting as soon as the previous rotation lands. An eighth of a second
of work with three minutes to find room in is never in a hurry, so a frame that
already ran long is not asked to carry a step as well.

Two sound components hold the music and the tracks alternate between them. That
is what the crossfade costs: a component holds one buffer, so two have to be
audible at once for one to give way to the other. Two is also where it stops.
Eight would be eight buffers of about a megabyte each, six of them silent at any
moment, which is most of a page's worth of memory to save a copy. Filling the
idle slot is a copy and costs nothing; only a build that somehow did not finish
costs anything at a rotation, and then it falls back to the hard cut this used to
do.

The fade is two seconds. These eight are in eight keys at eight tempos, so an
overlap is a clash however it is shaped and the only question is how long it
lasts: two seconds is long enough that neither track is cut off and short enough
that the clash reads as a turn rather than as a passage.

Its shape is a sine against a cosine rather than two straight ramps. Two tracks
have nothing to do with each other, so what adds across the fade is their power
rather than their amplitude, and two straight ramps crossing at a half leave a
hole three decibels deep in the middle of every rotation. A sine and a cosine
have squares that sum to one at every point of the fade, so the level holds. That
is a thing a player would hear as the music ducking at the change and would have
no way to describe, which is why it has a test rather than an opinion behind it.

The level is moved with `sound.set_gain`, which the engine documents as setting
the gain on all active playing voices of a sound. That is the one documented way
to move something already playing, and it matters because the alternative was
guessing whether changing a component's gain property reaches a voice that has
already started.

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
