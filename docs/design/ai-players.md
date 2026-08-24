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
specification with its own identity, behavior profile, competence, and build
plan. Zones choose fill and simulation settings. Ladder also asks for a
particular difficulty slot. [bot-ecosystem.md](bot-ecosystem.md) defines the
split.

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
| Denier | Lattice | Mines chokepoints, defends the flag room, rarely chases |
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
because they certify the current roster. None of them may seed ratings, order a
Ladder rung, or support a current balance claim.

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
with the most bouts behind it, has 0.05 losing to everybody and then almost
nothing between 0.45, 0.70 and 0.90: those three pairs read 47.6%, 49.0% and
53.9%, the last of them favoring the weaker pilot. A room stocked from the top
half of the dial would feel uniform. The difficulty lives at the bottom of the
range, which is the argument for fielding it.

**Error has to persist to matter.** Aim error was an angle drawn fresh around
the correct bearing ten to twenty times a second, so a burst sprayed a cone
centered on the truth and the mean shot was a perfect one. It measured as doing
nothing, correctly. Error that survives being averaged is error that is held
across a look and scaled by the thing being estimated: a misread of where the
target will be, which grows with how fast they cross and how far the round must
fly, and is zero against something standing still.

## Survival and greening

Energy is both ammunition and health, so survival is part of weapon discipline.
A pilot breaks contact earlier when it is outnumbered, carrying a flag, or
protecting upgrades and bounty. It uses short-range defensive fire to make room,
then flies for cover or a safe zone and does not re-enter on the first tick above
its danger threshold. A fresh pilot has little to lose and accepts more risk. A built pilot
should look like it knows what death costs.

Greens are not incidental pickups. A fresh life searches its radar for reachable
greens and uses them to build a ship before taking a marginal fight. As the kit
fills, the search radius and willingness to detour shrink. A low bar makes a
nearby green attractive because energy and recharge prizes can rescue the life,
but immediate enemy pressure wins the decision and sends the pilot away instead.
The type is still unknown until pickup, so the bot never chooses a green with
information a player does not have.

## The roster: bots as long-lived individuals

The bot server holds one deterministic roster for the deployment. Each
individual keeps a stable pilot ID, versioned specification, account, rating,
wallet, and upgrades. "Bot A" is somebody because it flies under the same
identity and carries its record across restarts.

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

**Presence.** Presence follows room demand today. Ordinary fill walks the stable
roster and claims an unused individual when an arena needs a seat. Ladder names
a difficulty slot for one room. The director does not keep hours or a weekly
schedule.

**Careers.** Rating, wallet, and purchased upgrades change through ordinary
play. Ladder keeps the identity but flies the base-account kit used in
calibration and does not shop, so a rung cannot drift with traffic. Hull,
competence, behavior, and build remain fixed for a pilot specification version.
There is no automatic competence progression, plateau, retirement, or
replacement policy today. Those systems need rules for timing and account
history before they can be added without quietly changing who a familiar pilot
is.

**Texture is not disguise.** Names are visibly marked as AI everywhere, and
bots do not perform humanity: no fake excuses, no fake typing, no pretending to
have a life the label contradicts. Recognition never becomes deception.

## They buy their own ships

An individual banks the bounty it takes and spends it on the same shelf a
player spends theirs on. It is the visible half of the career above: a pilot
you met a month ago comes back in a ship it paid for.

Nothing about this is privileged. A bot walks the three endpoints a person's
client walks, holding its own account's secret: `/v1/upgrades` for the catalog,
`/v1/buy` for a rung, and `C2S_KIT` to the arena for what it is flying. The
meta-layer prices it, checks the wallet and refuses what the account cannot
afford, and the arena checks the kit against the zone's ceiling and the
account's entitlements, exactly as it does for a person. A bot that has bought
nothing flies what a new player flies.

**Bots earn by killing, like everybody.** Rivets are bounty taken, and a kill
row is where a bounty is taken. Bot kills used to be left out of the pilot log
on the argument that machines killing machines is most of every hour and none
of it is anybody's story. That was cheap and it was the whole reason a bot's
wallet was permanently empty. They file now. The rows are marked as machines
and the week's table reads `where not bot`, so what this adds is a wallet and a
log, not a bot in the standings.

**At most one rung per completed-flight cycle.** Shopping happens before a
flight and never during one. A new individual may buy before its first flight.
After a purchase, a successful flight makes the next connection eligible to buy
again. Failed dials, refused joins, and reconnect churn do not turn one flight
into several purchases. One rung at a time keeps saved bounty from changing a
ship all at once.

**Taste, so a room is not eight of one ship.** Each pilot specification names a
gunner, bomber, or runner build plan. The plan decides what to buy next and how
the thirty points are spent once the rungs are owned, so what a pilot saved for
is what it flies. The choice no longer comes from hashing the call sign. That is
what makes "Ozone throws shrapnel" a fact worth learning rather than a thing to
say about all of them.

A bought-up bot may win more, and its account rating then moves with its record.
Ordinary fill does not select by rating, so a long-lived individual can still
meet a first-week player. Ladder's explicit difficulty request does not change
that policy in regular rooms.

## The population director

The director decides how many bots exist and which ones. It is a deployment
service rather than a per-arena loop: it runs in the bot server, which watches
the directory's browse reply and flies bots into rooms as ordinary declared
clients. [ai-runtime.md](../architecture/ai-runtime.md) has the mechanics.

**Fill to a target.** Every zone names how full its rooms should feel:
`bot_fill`, a share of the room's `max_ships`, 0.8 unless the zone says
otherwise. Bots make up the difference between that target and everybody else
present. A 64-seat room alone in the night holds 51 bots, one human joining
tips it over target and a bot stands down, and a room with humans past the
target holds no bots at all. The unfilled remainder is headroom, so a human
join never waits on a bot leaving.

**Draw from the roster.** Ordinary fill claims unused individuals from the
deterministic deployment roster. A Ladder room instead requests one bot for its
room and names the next difficulty rung. Each rung is one authored archetype
with 1,024 persistent account replicas. This is a mode request rather than a
human rating lookup, so it does not expose account records. A life locks one
replica and never changes its competence while the player is fighting it.

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

## Ladder

Ladder asks for one stable opponent at a measured difficulty slot. Its normal
format is one life, with a win advancing one rung and a loss dropping two by
default without crossing the last checkpoint. The opponent changes between
lives and never changes competence inside one. See
[ladder-mode.md](ladder-mode.md).

## Duels

Duel matchmaking is deferred. No duel queue or duel-specific bot policy ships
today. [duel-mode.md](duel-mode.md) records the design boundary without making
it part of the current roster contract.

## What we are not doing

No machine learning in the first version. Hand-authored utility behavior with
parameters is cheap, debuggable, tunable by a designer, and good enough to be
fun. Imitation learning from recorded human play is an interesting later
experiment and a bad way to start.

No bots that pretend to be human. No chat, social messages, fake typing, friend
requests, or unlabeled entries in the player list.

## Open questions

Whether bots should be allowed in rated arenas at all times, or only below a
population threshold. A zone at full capacity has no need of them, and their
presence complicates ratings.

How good bots actually need to be. The target is not "beats a good player" but
"is worth fighting," and we do not know where that line is until people play.
