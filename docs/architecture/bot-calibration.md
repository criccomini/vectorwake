# Bot calibration

Calibration answers narrow questions about the bot population: how whole pilot
specifications perform against one another, whether each mirrored matchup is
side-neutral, how uncertain each matchup is, and where stable pilots sit on one
descriptive rating scale. It does not isolate the causal effect of aim,
judgment, strategy, hull, or build because the roster experiment changes those
parts together. It also does not turn a pile of matches into evidence after
somebody likes the result.

A result is statistically significant only when its prespecified test passes
after correction for the declared family. A large bout count by itself earns no
such claim. Practical significance still depends on the effect size and its
interval.

The statistical unit is a scenario seed. Ticks, shots, deaths, and the two
halves of a mirrored bout are correlated observations inside that unit.

## A paired scenario

One scenario fixes everything that should not favor either controller:

- map and arena settings
- hulls, which is the whole of what each pilot flies with
- spawn positions and headings
- economy and pickup stream
- controller configuration and opponent
- the random stream derived from the scenario seed

The harness runs the scenario twice. The controllers exchange seats, starts,
and headings in the second match while the scenario seed stays the same. Scores
are converted back to the subject controller's perspective and averaged. A win
is one, a tie is one half, and a loss is zero.

This pair is one observation. Treating its matches as independent would make
the interval too narrow. Treating every death or shot as independent would be
worse. A team experiment uses the scenario seed as its cluster too, because
pilots sharing one world and one result do not provide separate evidence.

Mirroring removes a stable seat or start advantage from the contrast. It does
not excuse a biased fixture. Every distinct-pilot matchup must establish its
own side equivalence in validation and the final holdout, so opposite biases
cannot cancel in one population average.

## Plan before running

Every confirmatory run begins with a manifest that states:

- the hypotheses and whether each asks for superiority, equivalence, or a
  calibration bound
- the smallest effect worth detecting, or the equivalence band worth accepting
- family alpha and target power
- the paired variance estimate used for planning
- the required number of scenario pairs for each hypothesis
- the complete contrast family
- the maps, economies, pilots, and seed pools

The paired sample planner uses the target power, effect size, observed paired
variance, sidedness, and number of hypotheses. It allocates alpha
conservatively for the family before the run. A fixed habit such as "300 bouts
per pair" is not a power calculation. The required count changes when the
effect, paired variance, or family changes.

Pilot variance comes from a development pool or an older compatible experiment.
If there is no estimate, a pilot run exists to estimate it and makes no balance
claim. The confirmatory sample size is then frozen before validation begins.
Adding matches because a result is almost significant is another experiment
with another manifest.

## Inference

Reports lead with effect sizes and intervals. A p-value alone does not tell a
designer whether a difference matters.

### Simultaneous bootstrap intervals

Measurements with the same seed are averaged into one cluster. The deterministic
bootstrap resamples whole seed clusters and computes every declared contrast on
the same draw. A max-statistic critical value then gives simultaneous intervals
for the whole family. The family width comes from the labels in the manifest,
so adding a contrast widens the correction automatically.

The bootstrap seed is part of the report. Re-running the same observations and
manifest produces the same intervals. Resampling matches, deaths, or rows inside
a seed is forbidden because it invents independent evidence.

### Holm correction

Confirmatory superiority tests keep their raw p-values and apply Holm's
step-down correction over the declared family. The adjusted result controls the
family-wise error rate for that family.

Exploratory contrasts are labeled and kept out of the confirmatory family. They
can motivate the next manifest, but they cannot be promoted into findings from
the run that suggested them.

### Equivalence with TOST

"No significant difference" does not show that two profiles are balanced.
Balance claims use two one-sided tests against a prespecified lower and upper
bound. TOST returns equivalent only when both sides pass at the adjusted alpha.
A wide interval that crosses the band is inconclusive, even when its ordinary
difference test fails to reject zero.

Preference and competence need separate experiments. The roster tournament
compares whole pilots and makes no claim that one field caused a result.

## Strength and Ladder order

The pairwise matchup matrix is retained. Reducing it immediately to one number
would hide hard counters and disconnected comparison groups.

Bradley-Terry fits a strength for each connected pilot from that matrix. A tie
contributes half a win. One named reference pilot is fixed to an exact Elo, and
the other log strengths are converted to the same scale. The fit reports
standard errors and intervals, not only point ratings. It refuses a comparison
graph that does not connect every pilot to the anchor.

The authored competence and behavior prior prespecifies one candidate order
before any pool is read. Validation must reproduce every direction above the practical margin.
The final holdout must pass Holm-corrected superiority tests and simultaneous
seed-cluster intervals for the same directions. The serialized Ladder preserves
that sequence; it never selects directions from development data or re-sorts on
final point estimates. A failed order can inform a new authored design, but it
cannot be repaired inside the attempt that rejected it.

The fit's Elo standard errors and intervals come from the Bradley-Terry model's
information matrix. Shared scenario seeds make those intervals descriptive,
not cluster-robust inference. Complete separation can also push a regularized
point estimate to an arbitrary extreme. Release claims come from the
seed-cluster simultaneous matchup intervals. The compact artifact turns each
final point estimate into an operational account seed bounded to 800 through
1600 Elo. The full unbounded fit stays in the audit report.

## Seed pools and holdouts

Seed ranges are named, role-tagged, and disjoint within their namespace.

| Pool | Use |
|---|---|
| Development | Choose features, tune profiles, and estimate paired variance |
| Validation | Check frozen profiles and thresholds without more tuning |
| Final holdout | Make the release decision once |
| Replication | Test the shipped claim on untouched seeds later |

Looking at a final holdout turns it into development data. A failed final run
does not get repaired and rerun on the unused tail of the same range. A
checked-in, append-only registry binds one attempt ID and seed namespace to a
design fingerprint. The release procedure accepts only the first run triggered
by that registration. Another attempt needs a reviewed design or content
change, a new fingerprint, and a new disjoint seed namespace.

A confirmatory attempt also runs exactly the sample count calculated by its
release plan. More rows are not a harmless extension after the holdout has been
seen; they move every later pool boundary and create a new result under the old
registration. The planner rejects both smaller and larger confirmatory counts.

## Reproducible artifacts

A calibration manifest has its own schema version and identifies the controller,
pilot profile versions, maps, economies, hypotheses, seed ranges, alpha, power,
and sample plans. It binds those labels to the controller source, pilot
specifications, zone settings, map bytes, economy, and complete Ladder fixture.
The release verifier recomputes those fingerprints from the controller, live
wire, fixture, simulation, analysis, and rating-seed sources named by the
implementation. It also binds the Rust compiler, target architecture, operating
system, Cargo inputs, and container recipe. Certification must run in the
release image. At runtime, the arena compares the directory's live Ladder
definition and published map bytes with the measured fixture before opening or
retuning a certified room. The bot director also requires the arena and bot
process to report the same known build and verified attestation signature
before it fills a certified Ladder request. A mismatch refuses the room or
leaves its already certified map and tuning in place.

Human-readable labels are not fingerprints. A file still named `drydock.vwmap`
can contain different geometry, and a controller version can be reused by
mistake. A mismatch leaves the report as an historical result for older
content.

`vectorwake-server calibrate pilots` retains every paired observation in
`pilot-calibration-data.json` and the complete analysis in
`pilot-calibration-report.json`. The release workflow recomputes all fits,
tests, and 5,000 deterministic bootstrap draws from those raw rows. Only then
does it write the compact `pilot-calibration.json` attestation and
`ladder.json`. Production embeds the attestation, not the raw dataset, so arena
startup stays proportional to the eight-pilot roster rather than millions of
observations. The same release process signs every attestation field with the
meta-layer's Ed25519 key, and arenas and bot directors verify it with the
deployment's public half. Reordering a rung or changing a finite Elo value
invalidates the signature. The release command accepts no imported observation
file; it can sign only the in-memory rows its current binary just simulated and
reanalyzed. The checked-in attestation is `null` until a registered, powered
run passes. A point-Elo map by itself is never evidence.

For the current eight-pilot roster, the family contains 28 pairwise
superiority claims and 28 per-matchup side-equivalence claims. Every
superiority direction must clear its practical threshold in validation, then
pass the Holm-corrected test and simultaneous interval in the final holdout.
Validation is a locked threshold check, not a second superiority significance
claim. Side equivalence must pass its prespecified test in both pools. Together
those checks make 112 confirmatory gates. The superiority plan tests a
five-point practical margin above chance and powers a second five-point
increment above that null. It uses paired variance 0.25. The side plan has its
own five-point equivalence band and the worst-case variance 1.0 for a statistic
whose range is minus one to one. Alpha is allocated across all 56 inferential
claims. Beta is allocated across all 112 gates with a union bound, so 90
percent is a conservative whole-roster target instead of marginal power for
one comparison. The command prints both sample requirements and uses the
larger one. That number is recalculated whenever the roster or assumptions
change.

## What each test can establish

Unit tests cover deterministic pilot resolution, profile wiring, arithmetic,
seed-pool separation, and the statistical implementations. A short simulation
smoke test catches crashes and gross controller failures. Neither supplies a
balance claim.

`calibrate profiles` is a separate, narrower flight-stat screen. It declares
ten comparisons among legal 30-point builds: five stat margins beside the
starter allocation and five matched seventh-to-eighth stat
pip margins. Every stat margin spends its final point on the named pip or the
same bomb-bounce pip. Fixed bots and controllers play mirrored 4v4 matches for
the full 180 seconds. Paired seeds cycle evenly over the six Melee maps and
seven cyclic lineups, with every hull occupying four lineup seats per cycle.
The ten win-rate contrasts form one Bonferroni family and use conservative
approximate family-wise 95% paired t intervals. Kill intervals are descriptive.
The stricter fifteen-comparison planning bound needs 3,384 pairs for the stated
90% whole-family power target. The prespecified screen rounds that minimum to
3,402, or 81 complete map-by-lineup blocks. Another sample count is
exploratory. Confirmatory seeds come from the
preregistered attempt's namespace. A design fingerprint binds the ordered
contrasts and their builds, maps, zone, controller, live Melee scoring,
simulation, analysis policy, compiler and build target. The registry allows one
confirmatory attempt for that design, while exploratory runs use a separate
seed stream and cannot issue a verdict. The report retains each mirrored
seed-level observation. Before any verdict, each comparison on each map must
average at least eight net positive scored kills per match and preserve a
minimum amount of mirrored outcome sensitivity. A gross observed side gap is
retained as a warning, not a gate, because each contrast averages both side
assignments.
These are fixed, unpowered diagnostics. They do not certify side equivalence,
and the 90% target applies only to the ten declared contrasts. The result
estimates those marginal-pip questions under that fixture. It does
not cover every matchup and cannot establish human fun or perceived
fairness.

Powered bot experiments can establish whole-pilot outcome ordering,
per-matchup side neutrality, matchup structure, and uncertainty under the
scenarios they ran. The world has to resemble the game for those claims to travel. Current
calibration runs the shipped single-life Ladder rules on Drydock. Each pilot
flies the hull its specification names. The match restart deals that ship,
fills its energy bar and its rack, and then places both pilots on the sampled
starts.
Scenario seeds cycle every valid pair of team starts, and the mirror exchanges
pilots between the fixed opposing headings. Live Ladder uses the same start
policy. A same-tick mutual death scores one half, and any leg that reaches the
prespecified overtime censoring boundary blocks certification.

The harness calls each controller against fresh authoritative state at its look
cadence. A live house bot reconstructs that state from 20 Hz snapshots and
predicts between corrections. Against a human, the predictor also cannot know
the opponent's current input between snapshots. The attestation therefore
certifies the direct bot-versus-bot fixture, not the network prediction path.
A release still needs a live-wire soak and online outcome checks before its
order can be described as validated human difficulty.

Bot-only evidence cannot establish fun, frustration, perceived fairness,
learning, or voluntary return. It also cannot show that a pilot's readable
personality survives contact with a person who adapts over several lives. A
bot-versus-bot order is evidence about population strength, not proof that
human win probability decreases monotonically at every rung. That product
claim needs session-level player data.

Aim, judgment, and behavior wiring have deterministic controller tests. Claims
that those axes produce distinct observable behavior or a particular causal
outcome need prespecified ablation or factorial experiments with their own
power, clustering, effects, and multiplicity. Until those experiments exist,
the project makes no statistical claim about an isolated personality axis.

Those questions need human experiments. Randomization happens at the player or
session level, not at the death level. A protocol names one primary outcome,
such as a direct enjoyment rating or voluntary rematch, along with its minimum
worthwhile effect, account-level clustering, guardrails, and stopping rule
before data collection. Retention may be a secondary outcome, but a design that
raises play time while lowering reported enjoyment has not made the game more
fun. Bot calibration and human playtests answer different questions, and both
results stay visible.
