# AI players

A new multiplayer game has nobody in it. That is the whole problem, and it kills
most of them: the first player arrives, finds an empty arena, and never comes
back. AI opponents exist to make an empty server into a game worth playing, and
to get out of the way as humans arrive.

They are also a practice partner, a way to keep off-peak arenas alive, a load
generator for testing, and the calibration anchor for the rating system in
[rating.md](rating.md).

## Principles

**Bots play by the same rules.** A bot emits the same input command as a human
client over the same protocol. It cannot use a ship outside its sight radius,
see through walls, see a cloaked ship it has no business seeing, turn faster
than its ship's rotation rate, or fire faster than the settings allow.
Difficulty is imperfection added, never permission granted.

Since [decision 29](../architecture/decisions.md#29-a-bot-is-a-client), every
bot is a WebSocket client that decodes simulation snapshots and sends ordinary
input messages. House bots receive a complete snapshot so the fleet can share
one predicted world. The brain's `own`, `scan`, and departure-crowd interfaces
enforce sight before that state reaches a decision.

This is a design commitment with a pleasant side effect: if a bot can play well
under those rules, the input model is rich enough for humans. If it cannot, the
problem is probably our controls.

**Bots are labeled.** The player list, the kill feed, and the profile all say
which players are AI. Two reasons. Players deserve to know who they are fighting,
and a rating system that quietly mixes bots into your record without telling you
is a system nobody will trust. The label is the bot's own declaration at join,
carried in the roster to every client; a fleet credential additionally marks the
house roster apart from visiting bots where trust matters, such as anchoring the
rating scale.

**Bots leave gracefully.** They do not blink out when a human joins. A bot told
to stand down sees out the fight it is in, because turning tail the moment it is
told reads as running away and takes a kill somebody had earned with it. Then it
stops playing: the trigger shuts, nothing is chased, and it flies for an empty
corner of the map, preferring a safe zone, which is where a player goes to stop.
It logs off once it is a sight radius clear of where it broke contact and has
seen nobody for two looks running. Dying on the way is the cleanest ending of
all and takes it immediately.

The whole departure is budgeted, because a bot on its way out is still holding a
seat: past forty seconds it goes wherever it happens to be. Reaching that
ceiling means something went wrong rather than being the ordinary way out. The
rule it replaces waited for a death or an empty horizon while the bot fought on
at full strength, and in a busy room neither arrives, so what fired was the
timer and what a player saw was an opponent vanishing mid-duel.

**Nobody in a safe zone is a target.** Nothing can be shot into one, so a bot
that kept a pilot selected after they ducked inside held station at the door
with its trigger shut for as long as they cared to stand there. A pilot in a
safe is not in the game, and the bots treat them accordingly.

**No rubber-banding inside a fight.** A bot's skill is set when it spawns and
does not change while you are fighting it. Adaptation happens at the roster
level: the director spawns harder or easier opponents. Players can feel a bot
that suddenly starts missing, and it insults them.

**Bots are content.** The fleet has one deployment-wide roster and one shared
controller. Each roster individual resolves from a versioned pilot
specification with its own identity, behavior profile and competence, the
profile carrying both how it flies and what it buys. Zones choose fill and
simulation settings.
[bot-ecosystem.md](bot-ecosystem.md) defines the split.

## Styles

Each bot is an archetype plus a skill level plus a ship. The archetypes map to
the roster in [ships.md](ships.md) without being locked to it:

| Archetype | Usual ship | Behavior |
|---|---|---|
| Duelist | Apex | Seeks one-on-one fights, chases hard, breaks off at low energy |
| Bombardier | Wedge, Anvil | Holds corridors and chokepoints, avoids open space, lobs into traffic |
| Skirmisher | Chord | Pokes from range, sustains fire, retreats early and often |
| Heavy | Anvil | Accepts midrange fights, spends bombs readily, retreats a little later |
| Ambusher | Cipher | Cloaks near routes, waits, commits once, leaves |
| Brawler | Facet | Closes to knife range, fights in tunnels, dies in the open |
| Denier | Lattice | Holds chokepoints at range, defends the flag room, rarely chases |
| Runner | Any | Plays the objective over the kill, takes flags, chases the ball |

An arena's bot roster mixes these, so the room feels like a room rather than
eight copies of one opponent.

## Skill

Competence has two parameters. A table of six was tried, ablated one knob at a
time on two hulls in two economies, and four of the six could not be told from a
coin. A weak bot and a strong bot run the same code and differ in how well they
execute:

| Parameter | Weak | Strong |
|---|---|---|
| Aim | Misreads the target's motion most looks, badly | Reads the lead nearly right, nearly always |
| Judgment | Spends the bar on shots that are not there, bombs on cooldown, panics charges early | Keeps a reserve, throws the bomb the geometry asks for, spends a charge on the round that would have hit |

Aim and judgment are independent fields from 0 to 1. An authored pilot may set
them to the same value, but the data model does not require it. Aim error is a
misread of motion, so it grows with how fast the target crosses and how far the
round must fly. A quarter of even a bad pilot's looks come out clean: nobody is
uniformly wrong, they are mostly wrong. Reaction time and look rate stay fixed.
Engagement range now belongs to behavior, where it changes style rather than
claiming to measure execution.

The scalar tournaments below are the historical measurements that selected
these two axes. New population calibration compares full pilot specifications
and reports profile and competence claims separately. See
[bot-calibration.md](../architecture/bot-calibration.md).

Those older runs were exploratory. They did not freeze one hypothesis family,
power the sample from a declared minimum effect, correct every comparison, or
hold back an untouched release pool. Their percentages and descriptive z
scores remain below because they explain why the controller changed, not
because they certify the current roster. None of them may seed ratings or
support a current balance claim.

Reaction time deserves its own line, because it was built twice and failed
twice, differently. As re-plan cadence it measured as a coin: in a fight the
plan is stable and a slow re-plan has nothing to get wrong. As a delay on the
hands it destroyed the dial, because steering is a closed loop and a lagged
correction answers an error the ship no longer has, so every pilot oscillated
and none could shoot. If it comes back a third time it has to lag what the
pilot knows rather than what its hands do. The code records both attempts.

### What the exploratory instruments got wrong

Three of the instruments that produced the numbers below were wrong, and each
was wrong in the direction that flatters a change.

The ladder was judged by the Elo gap between the roster's ends, and that gap
carries about thirty points of run-to-run noise. Five tournaments of the same
pilots on disjoint salts read 93, 64, 112, 138 and 158 with greens off, and 46,
1, 24, -18 and 43 with them on, against a threshold of a hundred. The gap also
understates the span whenever the middle of the roster bunches, because the fit
has to place five pilots at once: a block whose ends sit at 67% can report +38.
A win rate says the same thing with a fraction of the noise, so the bar is
stated in one.

The tournament had no null row. The ablation grew one, read 62% for two pilots
identical in every respect, and that got written down as a side bias worth
reading every table against. Four hundred bouts on independent salts then read
54.2% and 47.2% in the two economies, and the Apex read 52.4% on the very salts
where the Wedge read 62, so the 62 was one reading believed twice. `duel` deals
each pilot the four combinations of start tile, facing and seat in equal
numbers, and there was never anywhere for a positional bias to live. Each block
measures its own coin and asserts on it rather than subtracting it, because
taking a number with four points of noise off one with seven adds error instead
of removing it.

And every number came from one hull. Class 1 is the Wedge, whose doctrine is
Bombardier, so a dial judged there was a dial judged on the bomb specialist. The
tournament and the ablation both run the Apex too. The two hulls agree that aim
is what separates pilots and disagree about the prize economy, where the Wedge
flattens completely and the Apex does not.

### What the dial actually drove

That table described an intention for a long time rather than the code. Three of
its six rows were decisions no pilot varied: the share of the bar a pilot would
not spend attacking, how it chose greens, and the energy at which it broke off a
fight were the same numbers for everybody in the game. What the dial did vary
was mostly a permission line at 0.35 deciding who was allowed to throw a bomb or
spend a charge at all.

A tournament on alpha found the consequence. Bots were held one tile class
apart, spawned inside sight of each other so the measurement was of fighting
rather than walking, and fought three hundred bouts a pair. The ladder came out
*inverted*, the roster's weakest pilot on top, because the pilot forbidden to
bomb keeps its bar and a bare bomb is a poor trade. With the prize economy
running it inverted the other way, because a built bomb is an excellent one. A
parameter whose sign depends on whether greens are on the map is two games with
a threshold between them, not a difficulty setting.

`calibrate`'s ablation is what settles which knob is doing what: two pilots
identical but for one parameter, and a null row of two pilots identical in every
parameter, so every reading is a distance from the coin this fixture actually
deals rather than from the one it was assumed to deal. Anybody changing these
numbers should run it, because the first three attempts here were all wrong in
ways only it caught, including one where greed was tuned backwards and the
reckless side won 64% of its bouts.

Two hypotheses from it were worth carrying into the confirmatory harness. They
remain hypotheses until a prespecified, powered report passes.

**Aim may decide a bare field.** A pilot that misreads a target's motion loses 37
points of win rate on a bare Wedge and 28 on a bare Apex, against knobs that
otherwise land inside their own intervals of a coin. With greens on the map it
falls to two points on the Wedge and fourteen on the Apex: once multifire and
shrapnel are on a hull nobody is aiming, they are spraying, and precision stops
separating anybody.

**Energy discipline may decide a built Apex.**
Holding the permission knob at 0.30 costs a built Apex 24 points, which is more
than aim costs it. That knob is the share of the bar a pilot will not spend
attacking, plus the cadence and the margins that go with it, and a built hull
firing multifire drains its bar fast enough for the question to decide fights. A
built Wedge has no such knob: every one of the six lands inside a coin there, and
so does the tournament, which puts 0.45 through 0.90 on 1224, 1223, 1221 and
1216. Bombs and shrapnel together are the most stochastic thing in this game and
they swamp the pilot flying behind them.

So a change to reaction, look rate, tolerance or engagement range changes how
the bots read rather than how hard they are. Difficulty lives in aim and in
energy discipline.

### Archived exploratory table

Seven hulls, two economies, five pilots from 0.05 to 0.90, three hundred bouts
a pair, with both sides handed the same kit at every spawn and nothing on the
floor to scavenge. The column is what the strongest pilot took off the weakest
in decided bouts. The z value is descriptive and has no family correction, so
it is not a release verdict.

| Hull | 30 greens | 60 greens |
|---|---|---|
| Cipher | 78.6% (z 10.6) | 77.9% (z 15.2) |
| Apex | 76.7% (z 13.2) | 72.9% (z 15.3) |
| Anvil | 67.2% (z 9.8) | 75.0% (z 11.9) |
| Wedge | 64.9% (z 4.5) | 69.0% (z 7.1) |
| Lattice | 64.9% (z 7.6) | 67.4% (z 6.7) |
| Facet | 67.1% (z 5.0) | 66.5% (z 5.7) |
| Chord | 66.9% (z 7.2) | 66.1% (z 8.4) |

Chord's second column is from seven hundred bouts a pair rather than three
hundred. At three hundred it read 57.9%, under the bar with an interval wide
enough to span it, and more samples put it on 66.1%: the low number was noise.
Worth writing down, because the other option on the table was calling 57.9%
close enough.

Three hypotheses came out of it. Doubling the kit may not flatten the
dial: five of seven hulls separate at least as well at sixty greens as at thirty,
which contradicts the older finding that thirty greens turn a two-to-one gap
flat. That finding came from a room where both pilots also raced for greens on
the floor, so it was measuring who scavenged better as much as who flew better.

The observed spread across hulls was large. Cipher and Apex separated pilots twice as
sharply as Chord does, so how much your skill matters depends on what you fly.
Nobody designed that and it is not obviously wrong, but it is worth knowing
before anybody tunes a hull.

Separation also appeared uneven along the dial. Chord at sixty greens, the block
with the most bouts behind it, had 0.05 losing to everybody and then almost
nothing between 0.45, 0.70 and 0.90: those three pairs read 47.6%, 49.0% and
53.9%, the last of them favoring the weaker pilot. A room stocked from the top
half of the dial felt uniform, and the reading at the time was that the
difficulty lives at the bottom of the range and the answer is to field it.

**The flat half was the dial, not the game.** Swept in a live Team Battle room
with hull, personality and kit held still, the dial bought something between
0.05 and 0.18 and nothing at all above: a 0.31 pilot and a 0.95 one scored the
same, and the whole range end to end was a factor of 1.5. Its judgment half was
noise from bottom to top.

Two things were wrong. Both mechanisms that make a pilot genuinely bad, the
held bearing error and the starved clean look, switched off above a floor at
0.30, which left lead error as the only thing separating seven eighths of the
dial, and lead error scales with a target's crossing motion so it cannot touch
something flying straight at you. And what judgment did vary was caution: the
reserve, the bomb cadence and the self-blast margin all climbed with the dial,
so a top pilot fired less, bombed less and refused more, which is why 0.44
finished ahead of 0.95.

So the aim error runs the length of the dial now, squared against the deficit
so the middle stays nearly straight and the bottom is where the wildness lives.
Judgment stopped buying caution, since how much risk to take is what
`aggression` and `retreat_bias` are for. And the dodge grades, because a 0.95
pilot already aims almost perfectly and there is no headroom left on that axis:
a poor pilot flinches only at what is dead on, a good one clears anything that
would touch it. Across the six match maps the roster now spans roughly a factor
of five, 0.32 to 2.01 on kills over deaths, and skill correlates with it at
+0.82 to +0.91.

**Error has to persist to matter.** Aim error was an angle drawn fresh around
the correct bearing ten to twenty times a second, so a burst sprayed a cone
centered on the truth and the mean shot was a perfect one. It measured as doing
nothing, correctly. Error that survives being averaged is error that is held
across a look and scaled by the thing being estimated: a misread of where the
target will be, which grows with how fast they cross and how far the round must
fly, and is zero against something standing still.

## Survival

Energy is both ammunition and health, so survival is part of weapon discipline.
A pilot breaks contact earlier when it is outnumbered, carrying a flag, or on a
run somebody is hunting. It uses short-range defensive fire to make room, then
flies for cover and does not re-enter on the first tick above its danger
threshold.

Greens left with the match game and came back with Free Roam, and what a pilot
does about them lives in [Playing the objective](#playing-the-objective)
below. Inside a match the only thing a pilot accumulates and spends is still
the charge budget here.

Charges are spent against the match rather than the moment. The rack the hull
carries is dealt at the start of a match and never at a spawn, so a repel is a third of a
three-minute supply rather than something a life comes with. A pilot prices one
accordingly: near the whistle, with the whole match still to cover, only a round
that would end the life is worth spending on, and in the last thirty seconds a
charge still in hand is about to be wasted, so nearly anything buys it. Asking
instead whether a round was arriving empties every rack into the opening joust,
because in a room of eight there is always a round arriving.

## Playing the objective

The four zones beside Team Battle each ask the brain for something the melee
never did, and this section is the design for all of it. Stage, plainly:
greens and growth are being built now; the rest is settled design with no code
behind it yet, and each piece should arrive with the zone probe below saying
what it changed.

**A bot learns what game it is in from the settings it was dealt.** Nothing
tells it the mode, and nothing needs to: a bot is a client (decision 29) and
the zone's settings arrive the way they arrive for anybody. Flags that cannot
be carried are Turf, a carry clock on carriable flags is Capture the Flag, a
green target above zero is Free Roam. Reading the game off the physics it is
flying under keeps every input a bot has one a player has too.

**Objectives are map knowledge; greens are sight knowledge.** A player reads
every flag's ownership off the flag strip and the map, so a bot restricted
to seeing flags at sixty tiles is playing blinder than the person next to it,
and the brain reads the set off the state instead. A green is the opposite: it
is drawn in the world and nowhere else, so a bot wants only the greens a
player in its seat would have noticed.

### Greens are opportunism

A pilot detours for a green the way a person does: when it is close, when
nothing is shooting at them, and in proportion to how hungry this life still
is. Hunger is the complement of growth, so a fresh spawn wants the trip and a
grown life has better things to protect, and the score for a green sits under
any fightable foe and under any flag, which is what keeps one something
collected on the way rather than instead. A green whose slot this hull already
has at its ceiling is not worth a detour at all: the core consumes it anyway,
and a player watching a bot collect nothing reads it as a bot being a bot.

### A grown life flies like it is worth something

Growth is the steps a pilot is wearing above the build they spawned on. Only a
green ever raises it and only death takes it back, so it is zero in every
match game and it is the whole ladder of a Free Roam life. It feeds the
retreat threshold: the further into a grown life a pilot is, the earlier they
break contact, worth a little less than a carried flag, which somebody else is
waiting on. That caution is not a handicap, it is the hunting dynamic the zone
runs on: a hull that has been alive four minutes runs sooner, is chased
further, and is worth more to bring down, which is true of the person flying
next to it for the same reason.

### Holding a point is a race, not a circle

Turf stands and dropped flags need a pilot who stays, and Travel cannot
stay: it arrives, the goal clears, and the next decision drifts off to fight.
The missing mode is a hold, and its leash is the part that has to be right.
A radius drawn in map distance holds a bot eight tiles from its stand on the
wrong side of a long wall while the enemy walks in the open side, sixty tiles
away by any road the bot can actually fly. So the leash is a race in route
terms: this pilot's road back to the anchor must stay shorter than the nearest
threat's road to it, with straight-line distance serving for the threat's side
because underestimating their road overestimates the danger, which errs
toward hugging the post. With nobody on the scan the leash goes slack, and a
holder can drift to a nearby green without abandoning anything; as a hostile
closes it tightens to sitting on the point.

Route cost is paid the way `plot` already pays it: line of sight as the cheap
first answer, the router consulted at the planning cadence and memoized
against drift, and an empty route read as "out of leash, walk at it" rather
than as fine, because the one geometry that returns empty is the wall the
leash exists for. The hold anchor is not the stand but the door: nav's route
from the stand toward trouble names the side trouble comes from, and the
orbit biases there. And a holder re-decides the moment its anchor changes
hands rather than at the next cadence, because ownership is in every
snapshot and a defender that watches its stand flip and finishes its orbit
first reads as asleep.

### Turf spreads out; Capture the Flag ferries and counts

A turf side of four on six stands must not arrive anywhere as a clump, so a
stand's score is discounted by the allies already nearer it than you, which
spreads the side with no captain and re-forms it the moment somebody dies.
Defense enters as its own choice: your own stand with a hostile nearer to it
than any ally is a place to be. Which pilots take and which hold falls out of
the personalities the roster already has, the way everything else about a
bot's taste does.

Capture the Flag wants two behaviors on top of the shared flag chase. The
ferry: a carried flag drops after thirty seconds wherever its carrier is,
keeping the side, so
the whole skill of carrying is to fly it home and stay alive until the clock
puts it down on your doorstep, then go get the next. A pilot knows it is
carrying from the state and flies accordingly, which the retreat logic
already half does. And the count: the set is in every snapshot, so the brain
knows we-hold-three the same way the mode does. A side holding the whole set
turtles on its flags while the ten seconds run; a side facing a completed set
rushes the nearest enemy flag, because touching one resets the clock; and in
between the ordinary take-ferry-hunt loop plays.

### The room follows the people

On a thousand tiles, thirty-two bots spread evenly is a map of nobody. Roam
targets get nudged toward the nearest human, with enough jitter to arrive as
traffic rather than as a swarm, through the same room-level seam that already
hands a pilot its standing. And the duel's stand-in should be cast by
strength, the archetype nearest the waiting pilot's rating, which is the one
piece of decision 92 worth taking back: it is a bot-server choice, not a
brain's, and it is the difference between a new player's first duel being a
game and being an execution.

### Measured before believed

None of this ships on the feeling that the bots seem better. A zone probe in
the melee probe's family runs bot-only rooms and reports the number that says
the game happened at all: rounds completed per match in Capture the Flag, score
spread and stand traffic in Turf, greens taken and time spent near humans in
Free Roam. The probe runs before a behavior lands and after, and the difference
is the review.

## The roster: bots as long-lived individuals

The bot server holds one deterministic roster for the deployment. Each
individual keeps a stable pilot ID, versioned specification, account and
rating. "Bot A" is somebody because it flies under the same identity and
carries its record across restarts.

**One individual, one place.** An individual never appears in two arenas at
once, and never twice in one arena. This is the rule that makes it an
individual: its rating is the record of one career, not an average over clones.

**An individual is an account.** The career above is not a metaphor for one:
each individual holds a real account at the meta-layer, claimed by name with
the bot server's pool credential and the same one every time, so a restart
resumes a career rather than starting one. Its rating lives where a human's
does and moves by the same math. The pinned anchor is the only offline seed in
the checked-in build today. Other priors become eligible only when a powered
report and its current-content fingerprints ship together. See
[accounts.md](accounts.md) and
[meta-layer.md](../architecture/meta-layer.md).

**Presence.** Presence follows room demand today. Fill claims an unused
individual when an arena needs a seat. The director does not keep hours or a
weekly schedule.

The authored roster is claimed first and in order, which is what keeps the
pinned anchor in the air. Past it the generated pool is entered at random. It
used to be walked from index zero, so a room that lost a pilot was handed back
the lowest free individual every time, and a two seat zone dealt one opponent
for a whole session.

**Careers.** Rating changes through ordinary play. Hull, competence and
behavior remain fixed for a pilot specification version, and the hull is the
whole ship, so what a familiar pilot flies is stable by construction.
There is no automatic competence progression, plateau, retirement, or
replacement policy today. Those systems need rules for timing and account
history before they can be added without quietly changing who a familiar pilot
is.

**Texture is not disguise.** Names are visibly marked as AI everywhere, and
bots do not perform humanity: no fake excuses, no fake typing, no pretending to
have a life the label contradicts. Recognition never becomes deception.

## They fly what their behavior asks for

A pilot's hull is read off its behavior profile rather than drawn beside it.
Where it wants to fight, how hard it chases, whether it stands or leaves and
how much it likes a bomb are the same questions a ship answers, so choosing
the ship is choosing all of them at once. Eight personalities fly eight
different hulls, and a test refuses two that come out the same.

There was a shop, and this section described a bot walking `/v1/upgrades`,
`/v1/buy` and `C2S_KIT` with its own account's secret to spend the bounty it
had banked, so a pilot you met a month ago came back in a ship it had paid
for. The whole apparatus is gone with the shop, and the claim it existed to
make is now structural: a Bombardier flies a hull with a rack because it
picked one, not because it saved up for one.

Which fixes the bug that section was written about. A generated pilot drew its
build plan from different bits of the same hash that drew its strategy, so the
two were uncorrelated: only a third of the pilots whose brains opened the
bombing gates owned a bomb, and Ozone, whose strategy is Bombardier, flew a
runner kit with no bomb ladder on it at all.

A bot's rating moves with its record. Fill still answers a count rather than a
question about who, so the first pilot into a room is dealt blind and a
long-lived individual can meet a first-week player. What the director does about
that is below.

## The population director

The director decides how many bots exist and which ones. It is a deployment
service rather than a per-arena loop: it runs in the bot server, which watches
the directory's browse reply and flies bots into rooms as ordinary declared
clients. [ai-runtime.md](../architecture/ai-runtime.md) has the mechanics.

**Deal a rival, not a body.** A room with a person in it gets a new pilot after
three matches against the same one, and at once where the one it has does not
suit them at all. The replacement comes from a window on the roster's strength
order, one window per tier, and is never one of the last few that room has had.

The director can ask that question because a bot is a client: the roster it is
sent carries every seat's rating and whether that seat is a machine, so a
connection inside a room can see who it is across from and report it back. None
of it is published. An arena's bot requests are answerable to anybody without
joining, and who is sitting in a room is not the sort of thing that belongs on
a public status; a rival chosen on a player's arrival would also make leaving
and rejoining a way to roll for a favorable opponent. It is chosen on the room's
clock, inside the process that flies the pilots. See
[decision 146](../architecture/decisions.md#146-a-duel-is-one-kill-and-the-room-deals-you-a-rival).

The bands are written down rather than measured. `ordering_prior` is
deliberately not a rating and the generated pool has no calibrated one, so there
is nothing to derive them from; what holds them honest is that their rows are
the tiers in the rating layer and a test fails when the two lists drift apart.

**Fill to a target.** Every zone names how full its rooms should feel:
`bot_fill`, a share of the room's `max_ships`, 0.8 unless the zone says
otherwise. Bots make up the difference between that target and everybody else
present. A 64-seat room alone in the night holds 51 bots, one human joining
tips it over target and a bot stands down, and a room with humans past the
target holds no bots at all. The unfilled remainder is headroom, so a human
join never waits on a bot leaving.

**Draw from the roster.** Fill claims unused individuals from the
deterministic deployment roster. A request names a room and a count, and the
director picks who goes.

**Yield to humans.** When a human joins, a bot is marked for removal and leaves
under the graceful rules above. Bots never outnumber humans on the opposing team
by more than the configured ratio once a room is populated. One bot is asked at
a time, whatever the surplus: a room sheds a seat per person who joins it, and a
group arriving together would otherwise send that many bots across the map at
once, which is an evacuation rather than a room getting quieter.

The arena backstops the race a burst of joins can win, and that backstop is the
one place there is no walking out: a join that would otherwise be refused for
space takes a declared bot's seat that tick. It takes it from the bot fewest
people are looking at, preferring one that is dead and then one with nobody
within sight, because the room holds the whole simulation and can tell. Age only
breaks ties. The headroom remains a courtesy rather than a load-bearing
assumption.

**Resist churn.** A bot lives at least thirty seconds. After a removal, no bot is
added for a minute. A player joining and leaving repeatedly should not make the
roster flicker.

A seat changing occupant on purpose is not that, and the guard knows the
difference. A pilot leaving so its room can be dealt another one keeps filling
that room's request until it has actually gone, so the room is never counted
short, nothing is claimed at a chair somebody is still in, and one room rotating
does not hold refill for every other room on the arena.

**Balance before asking humans to.** If teams are uneven, bots switch sides
first. Nobody enjoys being told to change teams.

**The floor is the target.** Off-peak a room simply sits at `bot_fill`, so an
arriving player finds a game in progress rather than an empty map. A zone that
wants no bots sets it to zero.

## Rating

Bots carry ratings, which is what makes the arena useful for ranking humans. See
[rating.md](rating.md). A bot's rating belongs to the individual account, and
one reference personality is pinned to a fixed rating so the population cannot
drift as a closed system. The repository currently seeds only that anchor. A
future offline prior must arrive through a powered, fingerprint-matched report;
generated fill pilots have no separate calibrated prior.

## What we are not doing

No machine learning in the first version. Hand-authored utility behavior with
parameters is cheap, debuggable, tunable by a designer, and good enough to be
fun. Imitation learning from recorded human play is an interesting later
experiment and a bad way to start.

No bots that pretend to be human. No chat, social messages, fake typing,
social requests, or unlabeled entries in the player list.

## Open questions

Whether bots should be allowed in rated arenas at all times, or only below a
population threshold. A zone at full capacity has no need of them, and their
presence complicates ratings.

How good bots actually need to be. The target is not "beats a good player" but
"is worth fighting," and we do not know where that line is until people play.
