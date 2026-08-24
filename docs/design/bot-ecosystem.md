# Bot ecosystem

The house roster is a population of named pilots, not a row of difficulty
settings. Each pilot has a stable identity, a way of trying to win, a way of
spending its upgrade budget, and a measured level of execution. Those parts
can vary independently, so two pilots can be equally hard while asking the
player to solve different problems.

All of them still use the common controller described in
[ai-runtime.md](../architecture/ai-runtime.md). They see through the same
bounded perception, route on the same map, fly through the same input protocol,
and obey the same weapon and movement rules as a human.

## The pilot specification

`PilotSpec` is versioned content. It resolves one roster slot into these fields:

| Part | Fields | Meaning |
|---|---|---|
| Identity | version, pilot ID, call sign | The durable answer to "which bot is this?" |
| Ship | hull | The class this pilot flies |
| Competence | aim, judgment | How reliably the pilot executes the shared controller |
| Behavior | strategy and preference weights | Which fights, ranges, objectives, and exits the pilot prefers |
| Build | gunner, bomber, or runner | What the pilot buys and how it spends a kit budget |
| Configuration | stable seed | Repeatable variation that belongs to the pilot |

The pilot ID owns identity. A call sign is a display name and can change later
without turning the career into a different pilot. The specification version
makes a deliberate content change visible to calibration and persistence code.

The shipped named pilots retain their existing IDs, call signs, hulls, and
careers. Extra fill pilots are generated deterministically. Resolving the same
roster slot twice produces the same specification, including its stable seed.
An individual still appears in only one arena at a time.

## Preference and competence are separate

A behavior profile says what the pilot wants. The shared controller says how a
ship can pursue it. Current strategies include dueling, bombardment,
skirmishing, heavy fighting, ambush, brawling, area denial, and running
objectives. Their profiles vary working range, pursuit, aggression, objective
priority, retreat bias, and weapon preferences.

These are style controls. A Denier can value mines and chokepoints without
receiving hidden map knowledge. A Runner can prefer an objective without moving
faster. A Brawler can accept close fights without getting extra energy.

Competence has two axes:

| Axis | A weaker pilot | A stronger pilot |
|---|---|---|
| Aim | Carries a larger, longer-lived error in its estimate of target motion | Estimates lead more accurately |
| Judgment | Spends energy and limited charges in worse situations | Keeps a better reserve and spends when the situation justifies it |

Aim and judgment are independent fields even when an authored pilot gives them
the same value. That permits a careful shooter who spends badly, or a disciplined
pilot whose shots are unreliable. Neither field is an Elo rating. Elo is an
estimate produced by matches, while competence values are controller inputs.

Build plans are separate for the same reason. A bomber is not hard merely
because it buys bombs, and a pilot does not change personality because its
wallet happens to afford another rung. The explicit plan replaces a purchase
order inferred from the pilot's name.

## Stable character, fresh matches

Configuration randomness and match randomness have different jobs. The stable
configuration seed belongs to the pilot and keeps its authored variation
repeatable. Match entropy changes between bouts. Mixing the two at the start of
a match gives a recognizable pilot without making it replay the same errors in
the same order forever.

No result may depend on a call sign hash. Renaming a pilot must not alter its
build, behavior, or random stream. Those choices live in the versioned
specification.

## Population and rating

Ordinary rooms ask the bot server for enough pilots to reach their configured
fill. The director uses unused roster individuals and yields their seats as
humans arrive. A Ladder room makes a room-specific request for one opponent at
a particular difficulty slot. The request changes between lives, never during
one.

Ladder has one rung for each of the eight authored archetypes and 1,024
persistent replica identities per rung. Replicas let concurrent rooms use
separate accounts without changing the measured controller. Their IDs and call
signs differ; their hull, competence, behavior, build, configuration seed, and
Ladder kit do not.

The authored weak-to-strong order is provisional until a powered calibration report passes
its holdout, multiplicity, practical-effect, side-equivalence, and content
fingerprint gates. A plain list of Elo values cannot change the live order.
The experiment tests that prespecified sequence in validation and the final
holdout. A verified report preserves the sequence instead of choosing a new
one from final Elo point estimates. Live careers still move through ordinary
rated play, but Ladder freezes each rival to the base-account entitlement
ceiling used by the experiment and does no shopping. A popular low rung cannot
quietly become stronger because its replicas earned more purchases.

## Social boundary

House bots do not chat, send social messages, make or accept friend requests,
or imitate typing. They never claim a human history or excuse. Their bot label
is visible anywhere their name appears.

The boundary is deliberate. Personality is expressed by decisions on the
field. Communication and friendship can be designed later if there is a
concrete player need, but neither is inferred from the existence of a
persistent bot identity.

## Verification

The specification layer has deterministic tests for stable IDs, generated
pilots, build plans, and strategy profiles. Controller tests check that
competence changes execution while behavior changes preference. The two kinds
of comparison stay separate because a profile can be distinctive without being
stronger.

Offline tournaments then test the population, using the procedure in
[bot-calibration.md](../architecture/bot-calibration.md). They must establish
uncertainty around ordering and matchup results before those results can seed a
Ladder. The current live order remains provisional because no powered report is
checked in. A tournament can show that two pilots differ and estimate who wins
more often under its exact fixture. It cannot show that either one is fun to
fight. It also does not isolate aim, judgment, behavior, hull, or build because
a whole-pilot comparison changes those inputs together. Causal claims about one
axis need a separate powered ablation or factorial experiment.
