//! Offline bot ladder calibration.
//!
//! Bot personalities play each other before they ever meet a human, which is
//! what lets the first player to join an empty zone be placed against a ladder
//! that already means something. Implements the "initial calibration is
//! offline" paragraph of docs/design/rating.md.
//!
//! Every match is fought for real: the real simulation, the real bots, the real
//! rating math. Nothing here models an outcome, because a model of a fight is
//! exactly the thing that would drift away from the fight.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::error::Error;
use std::fmt;

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};

use crate::experiment::{
    self, BootstrapConfig, BradleyTerryComparison, BradleyTerryConfig, BradleyTerryFit,
    CalibrationManifest, ContentFingerprint, ContrastPValue, EquivalencePowerPlan,
    EquivalencePowerPlanRequest, EquivalenceVerdict, HolmContrast, HypothesisKind, HypothesisSpec,
    PairedScenarioObservation, PowerPlan, PowerPlanRequest, SamplePlan, SeedPool, SeedPoolRole,
    SeededMeasurements, Sidedness, SimultaneousBootstrapReport, TostResult,
};
use crate::pilots::{self, PilotSpec};
use crate::{ai, catalog, config, nav, profiles, rating, shopper, sim};

/// A match ends at this many kills, or this many ticks if the two are too
/// evenly matched to settle it. 100 ticks is a second.
const KILL_TARGET: i16 = 5;
const MATCH_TICKS: u32 = 30_000; // five minutes of arena time

/// What the ladder ranks pilots in.
///
/// It used to be an empty room, and the argument for that was good as far as
/// it went: the kit is the loudest thing in a fight, so holding its budget at
/// zero holds the loadout still the way the hull is held still. Thirty points
/// flatten a two-to-one kill gap to nothing, which was measured here.
///
/// The argument was still wrong, because an empty room is not a place anybody
/// plays and it is missing a whole mechanism. Charges are only ever slotted in
/// a kit, so a pilot at zero holds none, and a branch of the AI that
/// decides when to spend one is unreachable. A ladder measured there ranks
/// pilots on a subset of the game and then seeds their careers in the whole
/// of it.
///
/// So thirty, matched, the same figure Alpha hands out at every spawn. Held
/// still the same way as before, which is what matters: both pilots draw the
/// same kit off the same stream, and none of it is lying on the floor to be
/// raced for.
#[allow(
    dead_code,
    reason = "kept for the legacy scalar calibration compatibility entry point"
)]
const LADDER_KIT: u32 = 30;

/// Run a full round-robin `rounds` times and return the resulting ladder.
///
/// Calibration deliberately does not mark these pilots as bots. A bot's K is
/// small during live play so a human moves further than the bot that killed
/// them; here there are no humans, and a small K would take a very long time
/// to say anything. The ladder this produces is the prior their careers start
/// from, and live play refines it under the slow K.
#[allow(
    dead_code,
    reason = "kept so focused legacy calibration callers continue to compile"
)]
pub fn run(rounds: u32, verbose: bool) -> rating::Rating {
    run_roster(&ai::roster(), rounds, verbose)
}

#[allow(
    dead_code,
    reason = "kept so focused legacy calibration callers continue to compile"
)]
pub fn run_roster(roster: &[ai::RosterEntry], rounds: u32, verbose: bool) -> rating::Rating {
    let mut r = rating::Rating::new();
    r.set_anchor(ai::ANCHOR, ai::ANCHOR_RATING);

    // Alpha, and the same bout every harness that ranks pilots fights.
    //
    // This was the pit, a room thirty-two tiles across, and the reason to
    // leave is not taste. Aim is a gain on the lead, so what a misread costs
    // grows with how far the round has to fly; at knife range there is no lead
    // to get wrong and the trait that carries a fight cannot show up at all.
    // Measured: 0.15, 0.50 and 0.95 came out of the pit on 1219, 1179 and
    // 1203, a gap of minus sixteen across almost the whole dial, while the
    // same three on this map separate ten pairs out of ten at a z of eight.
    //
    // A ladder is the prior a career starts from, and the careers happen here.
    let (bytes, route, at) = real_map_fixture();
    let mut salt = 0u32;
    for round in 0..rounds {
        for i in 0..roster.len() {
            for j in (i + 1)..roster.len() {
                duel(
                    &bytes, &route, at, &mut r, &roster[i], &roster[j], salt, LADDER_KIT, None,
                );
                salt = salt.wrapping_add(1);
            }
        }
        if verbose {
            println!("round {}/{rounds} done", round + 1);
        }
    }
    r
}

/// The ladder as a sorted table, strongest first.
#[allow(
    dead_code,
    reason = "kept so focused legacy calibration callers continue to compile"
)]
pub fn table(r: &rating::Rating) -> Vec<(String, f64, u32, &'static str)> {
    let mut rows: Vec<(String, f64, u32, &'static str)> = ai::roster()
        .iter()
        .map(|e| {
            let name = e.name.to_string();
            let score = r.rating_of(&name);
            (name.clone(), score, r.games_of(&name), rating::tier(score))
        })
        .collect();
    rows.sort_by(|x, y| y.1.partial_cmp(&x.1).unwrap());
    rows
}

/* ---- the loadout tournament -------------------------------------------
 *
 * Everything above holds the tech tree at zero so it can rank pilots. This
 * inverts it: one hull, one skill on both sides, and the kit is the only
 * thing that differs between two pilots. What comes out is a price for each
 * stage of the tree in win probability, which is the balance question the
 * ladder cannot answer and the drill does not ask.
 *
 * It is the same argument the ladder's matched budget makes higher up, read
 * the other way round. Thirty points flatten a two-to-one skill gap, so
 * somewhere between nothing and thirty the kit stops being a garnish on
 * flying and becomes the whole result. This maps where.
 */

/// A kit, handed to a pilot at every spawn.
pub struct Stage {
    pub name: &'static str,
    /// What to grant and how many of each. `TO_CEILING` grants until the hull
    /// refuses, so "every stat maxed" does not require this file to know how
    /// many steps a stat has.
    pub kit: &'static [(u8, u8)],
}

/// Grant this one until the count stops moving.
const TO_CEILING: u8 = 255;
/// A bound on that, so a ceiling that never arrives is a finite bug.
const GRANT_LIMIT: u32 = 64;

impl Stage {
    /// How many grants the kit asks for, or `None` when it asks for a ceiling
    /// and the answer is whatever the hull turns out to hold.
    ///
    /// The report needs this to say `1/2`. Most hulls stop at one
    /// bomb rung, so on those a two-rung stage is the one-rung stage under
    /// another name, and a matrix that did not say so would be inviting a
    /// reader to compare a row against itself.
    pub fn asked(&self) -> Option<u32> {
        if self.kit.iter().any(|&(_, n)| n == TO_CEILING) {
            return None;
        }
        Some(self.kit.iter().map(|&(_, n)| n as u32).sum())
    }
}

/// The stages, in the order the matrix reports them.
///
/// Each is one axis of the tree on its own, because a stage that changes two
/// things at once cannot be priced. The add-ons sit on the trigger they belong
/// to: shrapnel is a bomber's, and asking a hull to wear it on its gun would
/// measure a refusal rather than an add-on.
pub const STAGES: &[Stage] = &[
    Stage {
        name: "bare",
        kit: &[],
    },
    Stage {
        name: "gun 1",
        kit: &[(sim::slot_level(sim::TRIG_GUN), 1)],
    },
    Stage {
        name: "gun 2",
        kit: &[(sim::slot_level(sim::TRIG_GUN), 2)],
    },
    Stage {
        name: "bomb 1",
        kit: &[(sim::slot_level(sim::TRIG_BOMB), 1)],
    },
    Stage {
        name: "bomb 2",
        kit: &[(sim::slot_level(sim::TRIG_BOMB), 2)],
    },
    Stage {
        name: "stats",
        // This ceiling-only diagnostic prices the whole flight axis. With
        // five eight-step ladders it is deliberately not a legal thirty-point
        // build; the profile harness uses legal matched one-point margins.
        kit: &[
            (sim::slot_stat(0), TO_CEILING),
            (sim::slot_stat(1), TO_CEILING),
            (sim::slot_stat(2), TO_CEILING),
            (sim::slot_stat(3), TO_CEILING),
            (sim::slot_stat(4), TO_CEILING),
        ],
    },
    Stage {
        name: "multifire",
        kit: &[(sim::slot_mod(sim::TRIG_GUN, sim::MOD_MULTI), 1)],
    },
    Stage {
        name: "bouncing gun",
        kit: &[(sim::slot_mod(sim::TRIG_GUN, sim::MOD_BOUNCE), 1)],
    },
    Stage {
        name: "freezing gun",
        kit: &[(sim::slot_mod(sim::TRIG_GUN, sim::MOD_FREEZE), 1)],
    },
    Stage {
        name: "shrapnel",
        kit: &[(sim::slot_mod(sim::TRIG_BOMB, sim::MOD_SHRAPNEL), 1)],
    },
    Stage {
        name: "proximity",
        kit: &[(sim::slot_mod(sim::TRIG_BOMB, sim::MOD_PROX), 1)],
    },
    Stage {
        name: "shoving bomb",
        kit: &[(sim::slot_mod(sim::TRIG_BOMB, sim::MOD_PUSH), 1)],
    },
    // A second bare hull, and the most useful row in the table.
    //
    // It is `bare` under another name, so the gap between the two is a
    // difference this harness reports between two identical things: the noise
    // floor, measured rather than assumed, on whatever hull and bout count you
    // just ran. Every other row is worth reading against it, and a run whose
    // control gap is wider than the finding you came for has not found
    // anything. Unwearable stages land here too and widen the estimate, which
    // is right: they are also bare.
    Stage {
        name: "control",
        kit: &[],
    },
];

/// What one side did in one bout.
#[derive(Clone, Copy, Default)]
pub struct Side {
    pub kills: u32,
    /// Trigger pulls, by trigger, so a stage nobody used can be told from a
    /// stage that was used and lost.
    pub shots: [u32; sim::TRIG_COUNT],
    /// Damaging impacts on somebody else, and what they came to. A count alone
    /// cannot tell a fuse that lands more often from one that lands harder,
    /// and a blast falls off to nothing at its rim: a proximity round that
    /// goes off early connects exactly as often and arrives spent.
    pub hits: u32,
    pub damage: u64,
    /// And the same, landed on yourself. A bomb's blast has no owner test, so
    /// this is the count that says whether a stage is losing because the pilot
    /// flying it keeps standing in it.
    pub self_hits: u32,
    pub self_damage: u64,
    /// Grants that landed at the first spawn. Zero on a hull that cannot wear
    /// the kit at all, which makes the row a control rather than a mystery.
    pub worn: u32,
    /// Grants that landed on every spawn after it. The kit going back on is
    /// the property the whole harness rests on and the one that fails
    /// silently, so it is counted rather than assumed.
    pub regrants: u32,
}

pub struct Bout {
    pub sides: [Side; 2],
    #[cfg(test)]
    pub ticks: u32,
    /// Whether somebody reached the kill target. A pair that mostly times out
    /// is a pair whose numbers mean less than they look.
    pub decided: bool,
}

/// Put a kit on, and say how much of it went on.
///
/// Called at every spawn, not once. A stage grants slot by slot rather than
/// setting a kit, so it is put back on at the dead-to-alive edge the way the
/// arena re-deals one; granted once at the start it would measure one
/// outfitted life and four bare ones.
fn wear(world: &mut sim::World, ship: usize, stage: &Stage) -> u32 {
    let mut worn = 0;
    for &(slot, n) in stage.kit {
        let want = if n == TO_CEILING {
            GRANT_LIMIT
        } else {
            n as u32
        };
        for _ in 0..want {
            if !world.grant(ship, slot) {
                break;
            }
            worn += 1;
        }
    }
    // `wear` is called only at a spawn edge. The core filled the bar before
    // these grants raised its ceiling, while a live room opens after dealing
    // its kit. Put both fixtures on the same full starting bar.
    world.state.ships[ship].energy = world.eff_max_energy(ship);
    worn
}

/// Which trigger fired a given spec, for this hull.
///
/// A fire event names the spec that left the barrel rather than the trigger
/// that was pulled, and the report needs the trigger: "the shrapnel stage won
/// nothing" and "the shrapnel stage never threw a bomb" are different findings
/// that look identical from the win column.
pub(crate) fn spec_triggers(
    cfg: &sim::sim_settings,
    class: u8,
) -> std::collections::HashMap<u8, usize> {
    let mut m = std::collections::HashMap::new();
    let c = &cfg.classes[class as usize];
    for t in 0..sim::TRIG_COUNT {
        for r in 0..sim::MAX_RUNGS {
            let p = c.trigger[t][r];
            if p != sim::NO_PATTERN {
                m.entry(cfg.patterns[p as usize].spec).or_insert(t);
            }
        }
    }
    m
}

/// One bout between two kits. The returned sides are in the order passed in,
/// whichever end of the pit each of them actually flew.
///
/// `tuning` is a zone's arena block, or `None` for the roster as this binary
/// compiled it. It matters more than it sounds: a zone owns its weapon table
/// and its add-on steps, so what multifire costs is a zone's answer rather
/// than the core's, and a price measured on the baseline is a price for a room
/// nobody is necessarily running.
///
/// The map stays the pit whatever the zone says. A zone's own map would put
/// routing, corridors and a thousand tiles of separation into a measurement
/// that exists to isolate the kit, and two pilots on Alpha's map would spend
/// most of a bout looking for each other.
pub fn stage_bout(
    kits: [&Stage; 2],
    class: u8,
    skill: f32,
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
) -> Bout {
    stage_bout_for(kits, class, skill, salt, tuning, MATCH_TICKS)
}

fn stage_bout_for(
    kits: [&Stage; 2],
    class: u8,
    skill: f32,
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
    tick_limit: u32,
) -> Bout {
    let mut world = sim::World::with_map(0x5ea1 ^ salt, sim::build_pit);
    let route = nav::Nav::build(&world.map);
    if let Some(c) = tuning {
        // The arena's own path, so a setting this harness reads is a setting a
        // room would read. It rebuilds the baseline first, which is why it
        // comes before the two lines below rather than after.
        crate::Room::apply_config(&mut world, c);
    }
    // And the zone's spawn scatter, for a reason the other two did not have to
    // spell out. A radius drops a respawning ship on a random tile that far
    // from the map's centre, and Alpha's is 250 against a pit thirty-two tiles
    // wide: the first death throws both pilots out of the room and into the
    // empty field around it, where they spend the rest of the bout not finding
    // each other. It halved the kills in this tournament and I spent a while
    // blaming a refactor for it. Zero puts them back on the map's own starts.
    world.cfg.spawn_radius = 0;

    // Sides alternate, so the pit's own geometry cannot turn into a result.
    let flip = salt % 2 == 1;
    let seats: [&Stage; 2] = if flip {
        [kits[1], kits[0]]
    } else {
        [kits[0], kits[1]]
    };

    let ships = [
        world.spawn(class, 0, 505, 522, 0) as u8,
        world.spawn(class, 1, 519, 502, 32768) as u8,
    ];

    let mut out = [Side::default(); 2];
    for k in 0..2 {
        out[k].worn = wear(&mut world, ships[k] as usize, seats[k]);
    }

    let mut bots = [ai::Bot::new(ships[0], skill), ai::Bot::new(ships[1], skill)];
    bots[0].reseed(salt.wrapping_mul(2246822519) ^ 0x1234);
    bots[1].reseed(salt.wrapping_mul(3266489917) ^ 0x5678);

    let trig_of = spec_triggers(&world.cfg, class);
    let mut alive_was = [true; 2];
    #[cfg(test)]
    let mut ticks = 0;
    let mut decided = false;

    for _ in 0..tick_limit {
        let inputs = [
            sim::sim_input {
                ship: ships[0],
                buttons: bots[0].think(
                    &ai::own(&world, ships[0]),
                    &route,
                    bots[0].looks_due().then(|| ai::scan(&world, ships[0])),
                ),
            },
            sim::sim_input {
                ship: ships[1],
                buttons: bots[1].think(
                    &ai::own(&world, ships[1]),
                    &route,
                    bots[1].looks_due().then(|| ai::scan(&world, ships[1])),
                ),
            },
        ];
        world.step(&inputs);
        #[cfg(test)]
        {
            ticks += 1;
        }

        {
            let ev = &*world.events;
            for i in 0..ev.count as usize {
                let e = ev.e[i];
                match e.etype {
                    sim::EV_FIRE => {
                        if let Some(k) = ships.iter().position(|&s| s == e.a) {
                            if let Some(&t) = trig_of.get(&e.b) {
                                out[k].shots[t] += 1;
                            }
                        }
                    }
                    // Victim in `a`, attacker in `b`, damage in `v`. The two
                    // are the same ship when a blast catches whoever set it
                    // off, which the core allows on purpose.
                    sim::EV_HIT => {
                        if let Some(k) = ships.iter().position(|&s| s == e.b) {
                            if e.a == e.b {
                                out[k].self_hits += 1;
                                out[k].self_damage += e.v.max(0) as u64;
                            } else {
                                out[k].hits += 1;
                                out[k].damage += e.v.max(0) as u64;
                            }
                        }
                    }
                    _ => {}
                }
            }
        }

        // The kit goes back on at the dead-to-alive edge.
        for k in 0..2 {
            let alive = world.state.ships[ships[k] as usize].alive != 0;
            if alive && !alive_was[k] {
                out[k].regrants += wear(&mut world, ships[k] as usize, seats[k]);
            }
            alive_was[k] = alive;
        }

        let kills = [
            world.state.ships[ships[0] as usize].kills,
            world.state.ships[ships[1] as usize].kills,
        ];
        if kills[0] >= KILL_TARGET || kills[1] >= KILL_TARGET {
            decided = true;
            break;
        }
    }

    for k in 0..2 {
        out[k].kills = world.state.ships[ships[k] as usize].kills as u32;
    }
    Bout {
        sides: if flip { [out[1], out[0]] } else { out },
        #[cfg(test)]
        ticks,
        decided,
    }
}

/// One stage's whole tournament.
#[derive(Clone)]
pub struct StageRow {
    pub name: &'static str,
    pub worn: u32,
    /// What the kit asked for, when that is a fixed number.
    pub asked: Option<u32>,
    pub wins: u32,
    pub losses: u32,
    pub draws: u32,
    pub kills: u32,
    pub shots: [u32; sim::TRIG_COUNT],
    pub hits: u32,
    pub damage: u64,
    pub self_hits: u32,
    pub self_damage: u64,
    /// Kit re-issued after a death, summed over the tournament.
    pub regrants: u32,
    /// Win rate against each stage, indexed as `STAGES` is. `None` where the
    /// stage meets itself, which is scored as a control instead.
    pub vs: Vec<Option<f64>>,
    /// The mirror match: this kit against itself, as the share of bouts the
    /// first-listed side took. Near a half or the harness has a bias in it.
    pub mirror: f64,
    /// Mirror bouts that nobody won inside the tick limit.
    pub stalemates: u32,
}

/// A win rate, counting a draw as half a win each way.
pub fn win_rate_of(wins: u32, losses: u32, draws: u32) -> f64 {
    let n = wins + losses + draws;
    if n == 0 {
        return 0.0;
    }
    (wins as f64 + 0.5 * draws as f64) / n as f64
}

/// Half the 95% interval on that rate, in points.
///
/// Wilson rather than the textbook normal, so a row that won nothing gets an
/// interval it could actually live in instead of plus or minus zero. Shared by
/// every table this file prints, because a second copy of this is a second
/// chance to get it wrong, and the number it replaced was wrong enough.
pub fn margin_of(wins: u32, losses: u32, draws: u32) -> f64 {
    let n = (wins + losses + draws) as f64;
    if n == 0.0 {
        return 0.0;
    }
    const Z: f64 = 1.96;
    let p = win_rate_of(wins, losses, draws);
    let denom = 1.0 + Z * Z / n;
    100.0 * Z * ((p * (1.0 - p) / n) + (Z * Z / (4.0 * n * n))).sqrt() / denom
}

impl StageRow {
    /// The denominator under `win_rate`, for a caller reporting both.
    #[cfg(test)]
    pub fn bouts(&self) -> u32 {
        self.wins + self.losses + self.draws
    }
    pub fn win_rate(&self) -> f64 {
        win_rate_of(self.wins, self.losses, self.draws)
    }

    /// Half the 95% interval on this row's win rate, in points.
    ///
    /// A win rate is a coin counted `bouts()` times, and this is what that
    /// counting is worth. It exists because the report used to answer "is this
    /// gap real" with the spread of the kit-less rows, which is the range of
    /// four samples and mostly luck: it read 4.2 points where the sampling
    /// spread alone was nearer 15. Every row can price its own error from its
    /// own count, so every row now does.
    pub fn margin(&self) -> f64 {
        margin_of(self.wins, self.losses, self.draws)
    }
}

fn stage_rows() -> Vec<StageRow> {
    let n = STAGES.len();
    STAGES
        .iter()
        .map(|stage| StageRow {
            name: stage.name,
            worn: 0,
            asked: stage.asked(),
            wins: 0,
            losses: 0,
            draws: 0,
            kills: 0,
            shots: [0; sim::TRIG_COUNT],
            hits: 0,
            damage: 0,
            self_hits: 0,
            self_damage: 0,
            regrants: 0,
            vs: vec![None; n],
            mirror: 0.0,
            stalemates: 0,
        })
        .collect()
}

#[derive(Default)]
struct PairTally {
    first_wins: u32,
    second_wins: u32,
    draws: u32,
    stalemates: u32,
    bouts: u32,
}

impl PairTally {
    fn record(&mut self, rows: &mut [StageRow], first: usize, second: usize, bout: Bout) {
        rows[first].worn = bout.sides[0].worn;
        rows[second].worn = bout.sides[1].worn;

        for (row, side) in [(first, bout.sides[0]), (second, bout.sides[1])] {
            rows[row].kills += side.kills;
            rows[row].hits += side.hits;
            rows[row].damage += side.damage;
            rows[row].self_hits += side.self_hits;
            rows[row].self_damage += side.self_damage;
            rows[row].regrants += side.regrants;
            for trigger in 0..sim::TRIG_COUNT {
                rows[row].shots[trigger] += side.shots[trigger];
            }
        }
        if !bout.decided {
            self.stalemates += 1;
        }
        match bout.sides[0].kills.cmp(&bout.sides[1].kills) {
            std::cmp::Ordering::Greater => self.first_wins += 1,
            std::cmp::Ordering::Less => self.second_wins += 1,
            std::cmp::Ordering::Equal => self.draws += 1,
        }
        self.bouts += 1;
    }

    fn finish(self, rows: &mut [StageRow], first: usize, second: usize) {
        let bouts = self.bouts.max(1) as f64;
        let rate = (self.first_wins as f64 + 0.5 * self.draws as f64) / bouts;
        if first == second {
            rows[first].mirror = rate;
            rows[first].stalemates = self.stalemates;
            return;
        }

        rows[first].wins += self.first_wins;
        rows[first].losses += self.second_wins;
        rows[first].draws += self.draws;
        rows[second].wins += self.second_wins;
        rows[second].losses += self.first_wins;
        rows[second].draws += self.draws;
        rows[first].vs[second] = Some(rate);
        rows[second].vs[first] = Some(1.0 - rate);
    }
}

/// Every stage against every other, `bouts` times each, plus a mirror control.
///
/// The diagonal is deliberately not folded into the win column. A stage meeting
/// itself contributes one win and one loss to the same row whatever happens, so
/// counting it would drag every rate toward a half and hide the thing it is
/// actually good for: a mirror that does not come out even says the harness is
/// biased, and a mirror that never resolves says the pair is too dull to score.
pub fn run_stages(
    class: u8,
    skill: f32,
    bouts: u32,
    tuning: Option<&config::ArenaConfig>,
    verbose: bool,
) -> Vec<StageRow> {
    let n = STAGES.len();
    let mut rows = stage_rows();

    let mut salt = 0u32;
    for (i, first) in STAGES.iter().enumerate() {
        for (j, second) in STAGES.iter().enumerate().skip(i) {
            let mut tally = PairTally::default();
            for _ in 0..bouts {
                let b = stage_bout([first, second], class, skill, salt, tuning);
                salt = salt.wrapping_add(1);
                tally.record(&mut rows, i, j, b);
            }
            tally.finish(&mut rows, i, j);
        }
        if verbose {
            println!("{} done ({}/{})", first.name, i + 1, n);
        }
    }
    rows
}

/// Print the tournament, and hand back the document worth keeping.
pub fn report_stages(
    rows: &[StageRow],
    hull: &str,
    skill: f32,
    bouts: u32,
    zone: &str,
) -> serde_json::Value {
    // Whose numbers these are, said at the top. A price for multifire is a
    // price under some zone's `multi_energy` and `mod_spread`, and a report
    // that did not name the tuning would invite being carried to a room that
    // does not use it.
    println!(
        "\nloadout tournament: {hull}, {zone} tuning, skill {skill:.2}, \
{bouts} bouts a pair, {} stages",
        rows.len()
    );
    println!(
        "\n{:<14} {:>5} {:>7} {:>7} {:>7} {:>7} {:>8} {:>7} {:>6} {:>7}",
        "stage", "worn", "win%", "+-95%", "guns", "bombs", "hit/pull", "dmg/hit", "self%", "mirror"
    );
    for r in rows {
        let fired: u32 = r.shots.iter().sum();
        let worn = match r.asked {
            Some(a) if a != r.worn => format!("{}/{a}", r.worn),
            _ => r.worn.to_string(),
        };
        println!(
            "{:<14} {:>5} {:>7.1} {:>7.1} {:>7} {:>7} {:>8.2} {:>7.0} {:>6.1} {:>7.1}",
            r.name,
            worn,
            100.0 * r.win_rate(),
            r.margin(),
            r.shots[sim::TRIG_GUN],
            r.shots[sim::TRIG_BOMB],
            // Impacts per trigger pull, and deliberately not a percentage. A
            // fire event is a trigger being pulled, so a hull with two barrels
            // can land two on one pull and one with a multifire fan four. It
            // read as a hit rate until a Facet came back at 111%.
            r.hits as f64 / fired.max(1) as f64,
            // What one impact actually arrives with. A blast falls off to
            // nothing at its rim, so a fuse that goes off early lands the same
            // count for a fraction of the damage, and only this column says so.
            r.damage as f64 / r.hits.max(1) as f64,
            // The share of everything this stage dealt that it dealt to
            // itself.
            100.0 * r.self_damage as f64 / (r.damage + r.self_damage).max(1) as f64,
            100.0 * r.mirror,
        );
    }

    println!("\nrow's win% against column");
    print!("{:<15}", "");
    for i in 0..rows.len() {
        print!("{:>5}", i + 1);
    }
    println!();
    for (i, r) in rows.iter().enumerate() {
        print!("{:>2} {:<12}", i + 1, r.name);
        for cell in &r.vs {
            match cell {
                Some(v) => print!("{:>5.0}", 100.0 * v),
                None => print!("{:>5}", "-"),
            }
        }
        println!();
    }

    let stale: u32 = rows.iter().map(|r| r.stalemates).sum();
    if stale > 0 {
        println!(
            "\n{stale} mirror bouts of {} reached the tick limit undecided",
            rows.len() as u32 * bouts
        );
    }
    // Every row that ended up wearing nothing is flying the same hull as every
    // other, so they ought to agree, and how far they miss by is worth seeing.
    //
    // It is not this run's error bar, which is what it used to be called. It is
    // the range of a handful of samples, and the range of four is a poor
    // estimator of anything: it carries about as much scatter as the quantity
    // it is estimating. Three runs here read 4.2, 6.2 and 9.6 points while
    // their sampling spreads were near 15, 15 and 5, so it landed a third of
    // the truth twice and double it once. Reading a gap against a number that
    // wrong in either direction is how a coin flip gets written up.
    //
    // The rows do meet equivalent fields, which is worth saying because the
    // spread looks like it ought to have an explanation: `bare` faces the
    // kitted stages plus `control`, `control` faces the same stages plus
    // `bare`, and an empty kit is an empty kit. No structure, just a noisy
    // statistic.
    //
    // The `+-95%` column is the honest version and it is per row, off that
    // row's own count. Two rows differ when their intervals come apart, which
    // is a question this line cannot answer and should not look like it can.
    let flat: Vec<&StageRow> = rows.iter().filter(|r| r.worn == 0).collect();
    let kitless_spread = if flat.len() > 1 {
        let lo = flat
            .iter()
            .map(|r| r.win_rate())
            .fold(f64::INFINITY, f64::min);
        let hi = flat
            .iter()
            .map(|r| r.win_rate())
            .fold(f64::NEG_INFINITY, f64::max);
        let widest = flat.iter().map(|r| r.margin()).fold(0.0, f64::max);
        println!(
            "\n{} rows are wearing nothing at all and spread {:.1} points, against \
a 95% interval of +-{widest:.1} on each of them. Sampling explains a spread of \
about {:.0}; anything past that is those rows meeting different fields, not this \
run being noisy. Either way, read gaps against the per-row interval and not \
against this number.",
            flat.len(),
            100.0 * (hi - lo),
            2.06 * widest,
        );
        Some(100.0 * (hi - lo))
    } else {
        None
    };

    // A row nobody can wear is a copy of `bare` under another name, and a row
    // worn short is a copy of a shallower row. Either one invites a reader to
    // compare a stage against itself and call the difference a finding, so both
    // are said out loud rather than left in the wear column to be noticed.
    let cannot: Vec<&str> = rows
        .iter()
        .filter(|r| r.worn == 0 && r.asked.is_none_or(|a| a > 0))
        .map(|r| r.name)
        .collect();
    if !cannot.is_empty() {
        println!(
            "\n{hull} cannot wear: {} (each is a second copy of bare)",
            cannot.join(", ")
        );
    }
    let short: Vec<String> = rows
        .iter()
        .filter(|r| r.worn > 0 && r.asked.is_some_and(|a| r.worn < a))
        .map(|r| format!("{} ({} of {})", r.name, r.worn, r.asked.unwrap_or(0)))
        .collect();
    if !short.is_empty() {
        println!("worn short on {hull}: {}", short.join(", "));
    }

    serde_json::json!({
        "hull": hull,
        "tuning": zone,
        "skill": skill,
        "bouts_per_pair": bouts,
        /* Percentage points between the best and worst of the rows wearing
         * nothing. A diagnostic and not an error bar: rows that ought to agree
         * and do not have found something the harness is not controlling for.
         * For whether a gap is real, use each row's own `win_rate_margin`. */
        "kitless_spread": kitless_spread,
        "stages": rows.iter().map(|r| serde_json::json!({
            "name": r.name,
            "worn": r.worn,
            "asked": r.asked,
            "wins": r.wins,
            "losses": r.losses,
            "draws": r.draws,
            "win_rate": r.win_rate(),
            /* Half the 95% interval, in points. In the file as well as the
             * table, because a run gets diffed against another run and the
             * only question that ever asks is whether the two moved further
             * apart than either could wander on its own. */
            "win_rate_margin": r.margin(),
            "kills": r.kills,
            "gun_shots": r.shots[sim::TRIG_GUN],
            "bomb_shots": r.shots[sim::TRIG_BOMB],
            "hits": r.hits,
            "damage": r.damage,
            "self_hits": r.self_hits,
            "self_damage": r.self_damage,
            "regrants": r.regrants,
            "mirror": r.mirror,
            "stalemates": r.stalemates,
            "vs": r.vs,
        })).collect::<Vec<_>>(),
    })
}

/* ---- the hull tournament ----------------------------------------------
 *
 * The loadout tournament holds the hull still and varies the kit. This holds
 * the kit still and varies the hull, which is the other half and cannot be got
 * from that one: `stage_bout` puts one `class` on both seats, so it is a mirror
 * by construction and no amount of running it compares two hulls.
 *
 * Pilots are matched on **bounty** rather than on kit, and that is the whole
 * design. Every slot in the kit costs one, including one that lands on a
 * ceiling and grants nothing, so handing both sides the same budget matches
 * them exactly on what they were allowed to spend. It does not match them on
 * power: hulls have different pools and different ceilings, so the same budget
 * buys a Cipher and an Anvil different amounts of ship, and the gap widens as
 * the budget climbs.
 *
 * That difference is the finding rather than the flaw. A hull that saturates
 * early really is weaker at high bounty, and a matrix that erased it would be
 * answering a question nobody is ever in.
 */

/// Where a hull tournament is fought.
///
/// A roster is only balanced on a map, and the two shipped rooms disagree about
/// what a hull is for: the pit is thirty-two tiles across and rewards whatever
/// wins a knife fight, the arena has lanes and somewhere to run to. A hull whose
/// design says "loses outside two tiles" cannot lose there in the first room.
/// So this is a parameter, and a result carries the room it came from.
#[derive(Clone)]
pub enum Arena {
    /// One of the core's own builders, with the fixed facing spawns the
    /// tournament has always used. Symmetric by construction.
    Built(fn(&mut sim::sim_map)),
    /// A packed map off disk, whether shipped with a zone or generated. Spawns
    /// come from the map's own starts, because a coordinate that is open in the
    /// pit is inside a wall somewhere else.
    Packed(std::sync::Arc<Vec<u8>>),
}

impl Arena {
    /// The room, empty. Built before the zone's settings are applied and
    /// seated only after, which is the order that matters: `sim_spawn` reads a
    /// hull's opening energy out of the class table, so a ship seated first
    /// carries the baseline's numbers and then watches the zone's arrive
    /// around it. Measuring a per-hull energy change that way reports a hull
    /// that starts as one ship and recharges toward another.
    fn build(&self, salt: u32) -> Option<sim::World> {
        match self {
            Arena::Built(f) => Some(sim::World::with_map(0x5ea1 ^ salt, *f)),
            Arena::Packed(bytes) => sim::World::from_packed(0x5ea1 ^ salt, bytes).ok(),
        }
    }

    fn fingerprint(&self) -> String {
        match self {
            Arena::Built(_) => "built-core-map".into(),
            Arena::Packed(bytes) => format!("sha256:{}", catalog::sha256_hex(bytes)),
        }
    }

    /// Seat both hulls, once the room is tuned.
    fn seat(&self, w: &mut sim::World, salt: u32, classes: [u8; 2]) -> Option<[u8; 2]> {
        match self {
            Arena::Built(_) => Some([
                w.spawn(classes[0], 0, 505, 522, 0) as u8,
                w.spawn(classes[1], 1, 519, 502, 32768) as u8,
            ]),
            Arena::Packed(_) => {
                // `nth` walks the map's own starts for that team, so the two
                // sides land where the map says a team of theirs begins.
                let a = w.spawn_on_map(classes[0], 0, salt / 2, 0);
                let b = w.spawn_on_map(classes[1], 1, salt / 2, 32768);
                (a >= 0 && b >= 0).then_some([a as u8, b as u8])
            }
        }
    }
}

/// One hull's line in the cross-hull matrix.
pub struct HullRow {
    pub name: &'static str,
    pub class: u8,
    pub wins: u32,
    pub losses: u32,
    pub draws: u32,
    pub kills: u32,
    pub shots: [u32; sim::TRIG_COUNT],
    pub hits: u32,
    pub damage: u64,
    pub self_hits: u32,
    pub self_damage: u64,
    /// Kit points offered, and how many of them moved a count. The first is
    /// what the two sides are matched on, since every slot in the kit costs
    /// one; the second is what this hull got for it. Two hulls on the same
    /// budget with different conversion is the mechanism behind most of this
    /// table.
    pub budget: u32,
    pub converted: u32,
    /// Win rate against each hull, indexed as the roster is. `None` on the
    /// diagonal, which is scored as a bias check instead.
    pub vs: Vec<Option<f64>>,
    /// The mirror: this hull against itself, as the share the first seat took.
    /// Away from a half and the pit's geometry is leaking into the result.
    pub mirror: f64,
    pub stalemates: u32,
}

impl HullRow {
    pub fn bouts(&self) -> u32 {
        self.wins + self.losses + self.draws
    }
    pub fn win_rate(&self) -> f64 {
        win_rate_of(self.wins, self.losses, self.draws)
    }
    pub fn margin(&self) -> f64 {
        margin_of(self.wins, self.losses, self.draws)
    }
}

/// Deal one ship a kit worth `budget`, and return what it actually spent.
///
/// Random within the hull's own ceilings rather than a fixed list, because
/// what this harness measures is a hull at a level of kit rather than a hull
/// wearing one author's idea of a good build. The generator is the caller's,
/// so the same salt builds the same kit and dressing a pilot does not shift
/// the bout's own stream.
///
/// The return is what fit, which is the budget in any arena with room for it.
fn deal_kit(world: &mut sim::World, ship: usize, budget: u32, rng: &mut u32) -> u32 {
    let ceiling = world.kit_ceilings();
    let mut kit = [0u8; sim::SLOT_COUNT];
    let mut spent = 0u32;
    while spent < budget {
        let mut placed = false;
        for _ in 0..64 {
            *rng ^= *rng << 13;
            *rng ^= *rng >> 17;
            *rng ^= *rng << 5;
            let k = (*rng as usize) % sim::SLOT_COUNT;
            // Two kinds of charge, whatever the roll says: the arena refuses
            // a third, and a bout flown on a kit the arena would not take is
            // a bout measuring a bare hull.
            if k >= sim::slot_charge(0) as usize && kit[k] == 0 {
                let kinds = (0..sim::MAX_CHARGES)
                    .filter(|c| kit[sim::slot_charge(*c) as usize] > 0)
                    .count();
                if kinds >= sim::KIT_CHARGE_SLOTS {
                    continue;
                }
            }
            if kit[k] < ceiling[k] {
                kit[k] += 1;
                spent += 1;
                placed = true;
                break;
            }
        }
        if !placed {
            break;
        }
    }
    // Refused where `budget` is more than a kit may hold, which the harness
    // does on purpose to measure a wider build than a match allows; the ship
    // then keeps what it had. Left as it was rather than made an assertion,
    // which is a thread of its own: what this change owes is that the charge
    // cap above is not a new way to be refused.
    if world.set_kit(ship, &kit) {
        // `deal_kit` is likewise a spawn-edge helper. A random Energy count
        // must change the bar that this life starts with, not only its cap.
        world.state.ships[ship].energy = world.eff_max_energy(ship);
    }
    spent
}

/// Two hulls, the same bounty each, one bout.
///
/// Returns the bout and the kit budget each side was offered over it, which is
/// `budget` times the number of lives it had rather than a constant.
pub fn hull_bout(
    classes: [u8; 2],
    skill: f32,
    budget: u32,
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
    map: &Arena,
) -> (Bout, [u32; 2]) {
    // Sides alternate, so the room's geometry cannot turn into a result. The
    // seats keep their places and their bot seeds; it is the hulls that move.
    let flip = salt % 2 == 1;
    let seats: [u8; 2] = if flip {
        [classes[1], classes[0]]
    } else {
        classes
    };
    let dead = (
        Bout {
            sides: [Side::default(); 2],
            #[cfg(test)]
            ticks: 0,
            decided: false,
        },
        [0, 0],
    );
    let Some(mut world) = map.build(salt) else {
        return dead;
    };
    let route = nav::Nav::build(&world.map);
    if let Some(c) = tuning {
        crate::Room::apply_config(&mut world, c);
    }
    // The zone's spawn scatter is overridden, for a reason worth spelling
    // out. A radius drops a respawning ship on a random tile that far
    // from the map's centre, and Alpha's is 250 against a pit thirty-two tiles
    // wide: the first death throws both pilots out of the room and into the
    // empty field around it, where they spend the rest of the bout not finding
    // each other. It halved the kills in this tournament and I spent a while
    // blaming a refactor for it. Zero puts them back on the map's own starts.
    world.cfg.spawn_radius = 0;

    // Seated last, so both hulls open with the settings this room actually has.
    let Some(ships) = map.seat(&mut world, salt, seats) else {
        return dead;
    };

    // Nonzero, because xorshift stays at zero forever once it arrives there and
    // a bout whose kits all rolled the same thing is not obvious from a
    // report that only prints totals.
    let mut prng = [
        (salt.wrapping_mul(2654435761) ^ 0x9E37_79B9) | 1,
        (salt.wrapping_mul(2246822519) ^ 0x85EB_CA6B) | 1,
    ];

    let mut out = [Side::default(); 2];
    let mut offered = [0u32; 2];
    for k in 0..2 {
        out[k].worn = deal_kit(&mut world, ships[k] as usize, budget, &mut prng[k]);
        offered[k] = budget;
    }

    let mut bots = [ai::Bot::new(ships[0], skill), ai::Bot::new(ships[1], skill)];
    bots[0].reseed(salt.wrapping_mul(2246822519) ^ 0x1234);
    bots[1].reseed(salt.wrapping_mul(3266489917) ^ 0x5678);

    // One map per seat, because the two seats are different hulls now and a
    // spec id means nothing without knowing whose trigger threw it.
    let trig_of = [
        spec_triggers(&world.cfg, seats[0]),
        spec_triggers(&world.cfg, seats[1]),
    ];
    let mut alive_was = [true; 2];
    #[cfg(test)]
    let mut ticks = 0;
    let mut decided = false;

    for _ in 0..MATCH_TICKS {
        let inputs = [
            sim::sim_input {
                ship: ships[0],
                buttons: bots[0].think(
                    &ai::own(&world, ships[0]),
                    &route,
                    bots[0].looks_due().then(|| ai::scan(&world, ships[0])),
                ),
            },
            sim::sim_input {
                ship: ships[1],
                buttons: bots[1].think(
                    &ai::own(&world, ships[1]),
                    &route,
                    bots[1].looks_due().then(|| ai::scan(&world, ships[1])),
                ),
            },
        ];
        world.step(&inputs);
        #[cfg(test)]
        {
            ticks += 1;
        }

        {
            let ev = &*world.events;
            for i in 0..ev.count as usize {
                let e = ev.e[i];
                match e.etype {
                    sim::EV_FIRE => {
                        if let Some(k) = ships.iter().position(|&s| s == e.a) {
                            if let Some(&t) = trig_of[k].get(&e.b) {
                                out[k].shots[t] += 1;
                            }
                        }
                    }
                    sim::EV_HIT => {
                        if let Some(k) = ships.iter().position(|&s| s == e.b) {
                            if e.a == e.b {
                                out[k].self_hits += 1;
                                out[k].self_damage += e.v.max(0) as u64;
                            } else {
                                out[k].hits += 1;
                                out[k].damage += e.v.max(0) as u64;
                            }
                        }
                    }
                    _ => {}
                }
            }
        }

        // Death clears the tech tree, so the bounty goes back on at the
        // dead-to-alive edge or the rest of the bout is fought bare.
        for k in 0..2 {
            let alive = world.state.ships[ships[k] as usize].alive != 0;
            if alive && !alive_was[k] {
                out[k].regrants += deal_kit(&mut world, ships[k] as usize, budget, &mut prng[k]);
                offered[k] += budget;
            }
            alive_was[k] = alive;
        }

        let kills = [
            world.state.ships[ships[0] as usize].kills,
            world.state.ships[ships[1] as usize].kills,
        ];
        if kills[0] >= KILL_TARGET || kills[1] >= KILL_TARGET {
            decided = true;
            break;
        }
    }

    for k in 0..2 {
        out[k].kills = world.state.ships[ships[k] as usize].kills as u32;
    }
    (
        Bout {
            sides: if flip { [out[1], out[0]] } else { out },
            #[cfg(test)]
            ticks,
            decided,
        },
        if flip {
            [offered[1], offered[0]]
        } else {
            offered
        },
    )
}

/// Every hull against every other, `bouts` times each, at one bounty.
pub fn run_hulls(
    skill: f32,
    budget: u32,
    bouts: u32,
    tuning: Option<&config::ArenaConfig>,
    map: &Arena,
    verbose: bool,
) -> Vec<HullRow> {
    let n = ai::CLASS_NAMES.len();
    let mut rows: Vec<HullRow> = (0..n)
        .map(|i| HullRow {
            name: ai::CLASS_NAMES[i],
            class: i as u8,
            wins: 0,
            losses: 0,
            draws: 0,
            kills: 0,
            shots: [0; sim::TRIG_COUNT],
            hits: 0,
            damage: 0,
            self_hits: 0,
            self_damage: 0,
            budget: 0,
            converted: 0,
            vs: vec![None; n],
            mirror: 0.0,
            stalemates: 0,
        })
        .collect();

    let mut salt = 0u32;
    for i in 0..n {
        for j in i..n {
            let (mut wi, mut wj, mut drew, mut stale) = (0u32, 0u32, 0u32, 0u32);
            for _ in 0..bouts {
                let (b, offered) = hull_bout([i as u8, j as u8], skill, budget, salt, tuning, map);
                salt = salt.wrapping_add(1);

                for (k, side) in [(i, b.sides[0]), (j, b.sides[1])] {
                    rows[k].kills += side.kills;
                    rows[k].hits += side.hits;
                    rows[k].damage += side.damage;
                    rows[k].self_hits += side.self_hits;
                    rows[k].self_damage += side.self_damage;
                    rows[k].converted += side.worn + side.regrants;
                    for t in 0..sim::TRIG_COUNT {
                        rows[k].shots[t] += side.shots[t];
                    }
                }
                rows[i].budget += offered[0];
                rows[j].budget += offered[1];

                if !b.decided {
                    stale += 1;
                }
                match b.sides[0].kills.cmp(&b.sides[1].kills) {
                    std::cmp::Ordering::Greater => wi += 1,
                    std::cmp::Ordering::Less => wj += 1,
                    std::cmp::Ordering::Equal => drew += 1,
                }
            }

            // A hull against itself is a bias check and not a result: it
            // contributes a win and a loss to the same row however it goes,
            // so counting it would drag every rate toward a half.
            if i == j {
                rows[i].mirror = (wi as f64 + 0.5 * drew as f64) / bouts.max(1) as f64;
                rows[i].stalemates = stale;
                continue;
            }
            rows[i].wins += wi;
            rows[i].losses += wj;
            rows[i].draws += drew;
            rows[j].wins += wj;
            rows[j].losses += wi;
            rows[j].draws += drew;
            let rate = (wi as f64 + 0.5 * drew as f64) / bouts.max(1) as f64;
            rows[i].vs[j] = Some(rate);
            rows[j].vs[i] = Some(1.0 - rate);
        }
        if verbose {
            println!("{} done ({}/{})", ai::CLASS_NAMES[i], i + 1, n);
        }
    }
    rows
}

/// The cross-hull report: a line per ship, then the matrix.
pub fn report_hulls(
    rows: &[HullRow],
    skill: f32,
    budget: u32,
    bouts: u32,
    zone: &str,
    map: &str,
) -> serde_json::Value {
    let n = rows.len();
    println!(
        "\nhull tournament: {zone} tuning on the {map}, skill {skill:.2}, a {budget}-point \
kit a life, {bouts} bouts a pair, {n} hulls"
    );

    println!(
        "\n{:<10} {:>7} {:>7} {:>7} {:>7} {:>8} {:>7} {:>6} {:>7} {:>7}",
        "hull", "win%", "+-95%", "guns", "bombs", "hit/pull", "dmg/hit", "self%", "conv%", "mirror"
    );
    for r in rows {
        let fired: u32 = r.shots.iter().sum();
        println!(
            "{:<10} {:>7.1} {:>7.1} {:>7} {:>7} {:>8.2} {:>7.0} {:>6.1} {:>7.1} {:>7.1}",
            r.name,
            100.0 * r.win_rate(),
            r.margin(),
            r.shots[sim::TRIG_GUN],
            r.shots[sim::TRIG_BOMB],
            // Impacts per trigger pull. Not a hit rate and not a percentage:
            // a fire event is the trigger, so the Facet's two barrels land two
            // on one pull and a multifire fan lands four. It was printed as a
            // percentage and came back at 111, which is how this got noticed.
            r.hits as f64 / fired.max(1) as f64,
            r.damage as f64 / r.hits.max(1) as f64,
            100.0 * r.self_damage as f64 / (r.damage + r.self_damage).max(1) as f64,
            // What this hull turned its budget into. Two hulls matched on
            // budget and split on this column are the same price and not the
            // same ship.
            100.0 * r.converted as f64 / r.budget.max(1) as f64,
            100.0 * r.mirror,
        );
    }

    println!("\nrow's win% against column");
    print!("{:<11}", "");
    for (j, r) in rows.iter().enumerate() {
        let _ = j;
        print!("{:>7}", &r.name[..r.name.len().min(6)]);
    }
    println!();
    for (i, r) in rows.iter().enumerate() {
        print!("{:<11}", r.name);
        for j in 0..n {
            match r.vs[j] {
                Some(v) if i != j => print!("{:>7.0}", 100.0 * v),
                _ => print!("{:>7}", "-"),
            }
        }
        println!();
    }

    // A roster built on counters is not asking every hull to sit at a half.
    // What it is asking is that nothing beats the whole field and nothing
    // loses to it, so that is what gets checked rather than the average.
    //
    // Read against each cell's own interval. A pair meets `bouts` times, so a
    // cell is worth far less than the row beside it, and 21 pairs is 21 tries
    // at finding something at one in twenty.
    let cell = margin_of(bouts / 2, bouts - bouts / 2, 0);
    println!(
        "\neach cell is {bouts} bouts, so +-{cell:.0} points on its own; a row is \
{} and worth +-{:.1}. With {} pairs on the board, one cell in twenty comes out \
past its interval by luck alone.",
        rows.first().map(|r| r.bouts()).unwrap_or(0),
        rows.first().map(|r| r.margin()).unwrap_or(0.0),
        n * (n - 1) / 2,
    );

    for (i, r) in rows.iter().enumerate() {
        let beat: Vec<&str> = (0..n)
            .filter(|&j| j != i && r.vs[j].map(|v| v > 0.5).unwrap_or(false))
            .map(|j| rows[j].name)
            .collect();
        let lost: Vec<&str> = (0..n)
            .filter(|&j| j != i && r.vs[j].map(|v| v < 0.5).unwrap_or(false))
            .map(|j| rows[j].name)
            .collect();
        if beat.is_empty() {
            println!("{} beats nothing on the board", r.name);
        }
        if lost.is_empty() {
            println!("{} loses to nothing on the board", r.name);
        }
    }

    let bias: Vec<&str> = rows
        .iter()
        .filter(|r| (r.mirror - 0.5).abs() > 0.15)
        .map(|r| r.name)
        .collect();
    if !bias.is_empty() {
        println!(
            "mirror is away from even on: {}. The seats are not equivalent for \
those hulls, so read their rows knowing the map is in them.",
            bias.join(", ")
        );
    }

    serde_json::json!({
        "tuning": zone,
        "map": map,
        "skill": skill,
        "kit_budget": budget,
        "bouts_per_pair": bouts,
        "hulls": rows.iter().map(|r| serde_json::json!({
            "name": r.name,
            "class": r.class,
            "wins": r.wins,
            "losses": r.losses,
            "draws": r.draws,
            "win_rate": r.win_rate(),
            "win_rate_margin": r.margin(),
            "kills": r.kills,
            "gun_shots": r.shots[sim::TRIG_GUN],
            "bomb_shots": r.shots[sim::TRIG_BOMB],
            "hits": r.hits,
            "damage": r.damage,
            "self_hits": r.self_hits,
            "self_damage": r.self_damage,
            "kit_offered": r.budget,
            "kit_spent": r.converted,
            "mirror": r.mirror,
            "stalemates": r.stalemates,
            "vs": r.vs,
        })).collect::<Vec<_>>(),
    })
}

/* ---- the team tournament ----------------------------------------------
 *
 * Everything above fights one hull against one hull, which is the only way to
 * price a kit or a stat and the wrong way to ask what a roster is like to play.
 * Alpha is teams. A hull whose job is to deny ground, screen a bomber or spend
 * itself for a trade has nothing to do in a duel and no way to show it, and
 * ships.md says so of the Lattice in as many words: it scores less than
 * anything else and decides more fights than its stats suggest.
 *
 * So this fills both sides at random and reads a hull off the sides it was on.
 * Every seat is one observation: a hull that keeps turning up on winning teams
 * is worth having, whether or not it is the thing collecting the kills.
 *
 * Random rather than balanced on purpose. A hull that appears on both sides
 * cancels, which costs a little power and buys the estimate its honesty: no
 * arrangement of mine decides which hulls meet which.
 */

/// One hull's line in the team tournament.
pub struct TeamRow {
    pub name: &'static str,
    pub class: u8,
    /// Seats this hull filled, and how they ended. A seat is the unit here
    /// rather than a match, because a match holds several of the same hull.
    pub seats: u32,
    pub won: u32,
    pub drawn: u32,
    pub kills: u32,
    /// Times this seat was killed, counted off the alive edge rather than off
    /// anybody's kill column: a blast has no owner test, so a pilot can end
    /// their own life and it belongs in this number all the same.
    pub deaths: u32,
    pub shots: [u32; sim::TRIG_COUNT],
    pub engagement_distance: f64,
    pub engagement_samples: u64,
    pub planned_range: f64,
    pub planned_range_samples: u64,
    pub hits: u32,
    pub damage: u64,
    pub self_damage: u64,
    pub budget: u32,
    pub converted: u32,
}

impl TeamRow {
    pub fn win_rate(&self) -> f64 {
        win_rate_of(self.won, self.seats - self.won - self.drawn, self.drawn)
    }
    pub fn margin(&self) -> f64 {
        margin_of(self.won, self.seats - self.won - self.drawn, self.drawn)
    }
}

/// What one seat did in one match.
#[derive(Clone, Copy, Default)]
pub struct Seat {
    pub class: u8,
    pub team: u8,
    /// Signed match score. Team kills and suicides are scored exactly as the
    /// live melee mode scores them; `kills` below remains a nonnegative combat
    /// counter for the aggregate report.
    pub score: i32,
    pub kills: u32,
    pub deaths: u32,
    pub shots: [u32; sim::TRIG_COUNT],
    pub engagement_distance: f64,
    pub engagement_samples: u64,
    pub planned_range: f64,
    pub planned_range_samples: u64,
    pub hits: u32,
    pub damage: u64,
    pub self_damage: u64,
    pub budget: u32,
    pub converted: u32,
}

/// One match: `lineup` seated in order, the first half on team 0.
///
/// Ordinary team matches end when a side reaches `KILL_TARGET` per player or
/// when the clock does. Profile fixtures disable the score target and run the
/// full configured clock. A match that ran out of clock is still scored on
/// kills, because a team ahead on the board when time expires has out-fought
/// the other one whether or not it finished the job.
fn team_world(salt: u32, tuning: Option<&config::ArenaConfig>, map: &Arena) -> Option<sim::World> {
    let mut world = map.build(salt)?;
    if let Some(c) = tuning {
        crate::Room::apply_config(&mut world, c);
    }
    // Keep the zone's spawn scatter. This tournament uses the real map, so
    // placement is part of the team game it measures.
    Some(world)
}

/// Geometry and navigation prepared once for every profile-screen map.
///
/// A packed map otherwise gets unpacked and its six landmark tables rebuilt
/// for every match. The powered screen plays more than a hundred thousand
/// matches, while both halves are immutable once loaded and can be shared by
/// every comparison worker.
struct ProfileMapFixture {
    map: std::sync::Arc<sim::sim_map>,
    route: nav::Nav,
}

impl ProfileMapFixture {
    fn new(map: std::sync::Arc<sim::sim_map>) -> Self {
        let route = nav::Nav::build(&map);
        Self { map, route }
    }

    fn world(&self, salt: u32, tuning: Option<&config::ArenaConfig>) -> sim::World {
        // Arena::build uses the same seed transformation before unpacking a
        // packed map. Reusing its immutable geometry must not change the
        // simulation stream.
        let mut world = sim::World::on_map(0x5ea1 ^ salt, std::sync::Arc::clone(&self.map));
        if let Some(config) = tuning {
            crate::Room::apply_config(&mut world, config);
        }
        world
    }
}

#[derive(Clone, Copy)]
enum TeamMap<'a> {
    Arena(&'a Arena),
    Profile(&'a ProfileMapFixture),
}

struct TeamMatchOptions<'a> {
    kits: Option<&'a [[u8; sim::SLOT_COUNT]; 2]>,
    tick_limit: u32,
    kill_target_per_player: Option<i16>,
}

fn live_team_score(world: &sim::World, ships: &[u8], seats: &[Seat]) -> [i32; 2] {
    let mut side = [0i32; 2];
    for i in 0..ships.len() {
        side[seats[i].team as usize] += i32::from(world.state.ships[ships[i] as usize].kills);
    }
    side
}

fn dress_team(
    world: &mut sim::World,
    ships: &[u8],
    seats: &mut [Seat],
    budget: u32,
    kits: Option<&[[u8; sim::SLOT_COUNT]; 2]>,
    prng: &mut [u32],
) -> bool {
    for i in 0..ships.len() {
        let converted = match kits {
            Some(kits) => {
                let kit = &kits[seats[i].team as usize];
                if !world.set_kit(ships[i] as usize, kit) {
                    return false;
                }
                sim::World::kit_cost(kit)
            }
            None => deal_kit(world, ships[i] as usize, budget, &mut prng[i]),
        };
        seats[i].converted += converted;
        seats[i].budget += budget;
    }

    // A live match opens after every seat has its kit, then restarts the room:
    // full bars, loaded charges and authored starts. Spawning first and merely
    // dealing the kit left the first life at the zero-point energy ceiling,
    // so the harness measured a fixture the game never deliberately opens.
    world.restart();
    crate::room::face_public_teams(world);
    true
}

fn team_match_with_options(
    lineup: &[u8],
    skill: f32,
    budget: u32,
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
    map: TeamMap<'_>,
    options: TeamMatchOptions<'_>,
) -> (Vec<Seat>, bool) {
    let per_side = lineup.len() / 2;
    let Some(mut world) = (match map {
        TeamMap::Arena(map) => team_world(salt, tuning, map),
        TeamMap::Profile(fixture) => Some(fixture.world(salt, tuning)),
    }) else {
        return (Vec::new(), false);
    };
    let local_route;
    let route = match map {
        TeamMap::Arena(_) => {
            local_route = nav::Nav::build(&world.map);
            &local_route
        }
        TeamMap::Profile(fixture) => &fixture.route,
    };

    let mut seats: Vec<Seat> = Vec::with_capacity(lineup.len());
    let mut ships: Vec<u8> = Vec::with_capacity(lineup.len());
    let mut prng: Vec<u32> = Vec::with_capacity(lineup.len());
    for (i, &cls) in lineup.iter().enumerate() {
        let team = (i / per_side) as u8;
        let heading = if team == 0 { 0 } else { 32768 };
        let id = world.spawn_on_map(cls, team, (i % per_side) as u32, heading);
        if id < 0 {
            return (Vec::new(), false);
        }
        ships.push(id as u8);
        prng.push(
            (salt
                .wrapping_mul(2654435761)
                .wrapping_add((i as u32).wrapping_mul(2246822519))
                ^ 0x9E37_79B9)
                | 1,
        );
        seats.push(Seat {
            class: cls,
            team,
            ..Default::default()
        });
    }
    if !dress_team(
        &mut world,
        &ships,
        &mut seats,
        budget,
        options.kits,
        &mut prng,
    ) {
        return (Vec::new(), false);
    }

    let mut bots: Vec<ai::Bot> = ships
        .iter()
        .enumerate()
        .map(|(i, &s)| {
            let mut b = ai::Bot::new(s, skill);
            b.reseed(salt.wrapping_mul(2246822519) ^ (i as u32).wrapping_mul(2654435761));
            b
        })
        .collect();

    let trig_of: Vec<_> = lineup
        .iter()
        .map(|&c| spec_triggers(&world.cfg, c))
        .collect();
    let mut alive_was = vec![true; ships.len()];
    let mut decided = false;

    for _ in 0..options.tick_limit {
        // The look is decided before the think, because `think` takes the bot
        // mutably and `looks_due` reads it: asking inside the call borrows the
        // same bot twice.
        let mut inputs: Vec<sim::sim_input> = Vec::with_capacity(ships.len());
        for i in 0..ships.len() {
            let own = ai::own(&world, ships[i]);
            let look = bots[i].looks_due().then(|| ai::scan(&world, ships[i]));
            let buttons = bots[i].think(&own, route, look);
            if let Some(distance) = bots[i].engagement_distance() {
                seats[i].engagement_distance += distance as f64;
                seats[i].engagement_samples += 1;
            }
            if let Some(range) = bots[i].planned_engagement_range() {
                seats[i].planned_range += range as f64;
                seats[i].planned_range_samples += 1;
            }
            inputs.push(sim::sim_input {
                ship: ships[i],
                buttons,
            });
        }
        world.step(&inputs);

        {
            let ev = &*world.events;
            for k in 0..ev.count as usize {
                let e = ev.e[k];
                match e.etype {
                    sim::EV_FIRE => {
                        if let Some(i) = ships.iter().position(|&s| s == e.a) {
                            if let Some(&t) = trig_of[i].get(&e.b) {
                                seats[i].shots[t] += 1;
                            }
                        }
                    }
                    sim::EV_HIT => {
                        if let Some(i) = ships.iter().position(|&s| s == e.b) {
                            if e.a == e.b {
                                seats[i].self_damage += e.v.max(0) as u64;
                            } else {
                                seats[i].hits += 1;
                                seats[i].damage += e.v.max(0) as u64;
                            }
                        }
                    }
                    _ => {}
                }
            }
        }

        for i in 0..ships.len() {
            let alive = world.state.ships[ships[i] as usize].alive != 0;
            if alive && !alive_was[i] && options.kits.is_none() {
                seats[i].converted += deal_kit(&mut world, ships[i] as usize, budget, &mut prng[i]);
                seats[i].budget += budget;
            }
            if !alive && alive_was[i] {
                seats[i].deaths += 1;
            }
            alive_was[i] = alive;
        }

        let side = live_team_score(&world, &ships, &seats);
        if match_reached_target(side, per_side, options.kill_target_per_player) {
            decided = true;
            break;
        }
    }

    for i in 0..ships.len() {
        let score = i32::from(world.state.ships[ships[i] as usize].kills);
        seats[i].score = score;
        seats[i].kills = score.max(0) as u32;
    }
    (seats, decided)
}

fn match_reached_target(
    score: [i32; 2],
    per_side: usize,
    kill_target_per_player: Option<i16>,
) -> bool {
    let Some(per_player) = kill_target_per_player else {
        return false;
    };
    let target = i32::from(per_player) * per_side as i32;
    score[0] >= target || score[1] >= target
}

pub fn team_match(
    lineup: &[u8],
    skill: f32,
    budget: u32,
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
    map: &Arena,
) -> (Vec<Seat>, bool) {
    team_match_with_options(
        lineup,
        skill,
        budget,
        salt,
        tuning,
        TeamMap::Arena(map),
        TeamMatchOptions {
            kits: None,
            tick_limit: MATCH_TICKS,
            kill_target_per_player: Some(KILL_TARGET),
        },
    )
}

/// One full-loadout comparison from mirrored live-format matches.
#[derive(Clone, Debug, serde::Serialize)]
pub struct ProfileResult {
    pub contrast: &'static str,
    pub a: &'static str,
    pub b: &'static str,
    pub paired_seeds: u32,
    pub matches: u32,
    pub win_rate: f64,
    pub win_rate_low: f64,
    pub win_rate_high: f64,
    pub kill_difference: f64,
    pub kill_difference_low: f64,
    pub kill_difference_high: f64,
    pub verdict: &'static str,
    pub powered_fixture: bool,
    pub fixture_valid: bool,
    pub fixture_validity: Vec<ProfileMapValidity>,
    pub observations: Vec<ProfileObservation>,
}

/// Fixed descriptive fixture checks for one map in one profile comparison.
///
/// These fields preserve exploratory diagnostics without turning the checks
/// into inferential claims. Thresholds and definitions live beside the run in
/// the report so every measured value has its declared interpretation.
#[derive(Clone, Debug, serde::Serialize)]
pub struct ProfileMapValidity {
    pub map_index: usize,
    pub map: String,
    pub paired_seeds: u32,
    pub matches: u32,
    pub mean_positive_scored_kills_per_match: f64,
    pub mean_profile_sensitivity: f64,
    pub absolute_observed_side_gap: f64,
    pub valid: bool,
    pub failures: Vec<&'static str>,
    pub warnings: Vec<&'static str>,
}

/// One preregistered confirmatory attempt for a fixed profile-screen design.
/// A design can appear only once in the append-only registry, so inspecting a
/// confirmatory result cannot become an invitation to rerun the same design
/// against a fresh seed stream.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProfileCalibrationAttempt {
    pub attempt_id: String,
    pub design_fingerprint: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProfileCalibrationAttemptRegistry {
    pub schema_version: u32,
    pub attempts: Vec<ProfileCalibrationAttempt>,
}

/// Authorization and seed namespace prepared before profile matches begin.
///
/// Its fields are private so callers cannot manufacture a powered run. The
/// collector also recomputes the design fingerprint before the first match,
/// which prevents a prepared attempt from being reused with changed inputs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ProfileCalibrationRun {
    attempt_id: String,
    design_fingerprint: String,
    seed_base: u32,
    powered_fixture: bool,
}

impl ProfileCalibrationRun {
    pub fn attempt_id(&self) -> &str {
        &self.attempt_id
    }

    pub fn design_fingerprint(&self) -> &str {
        &self.design_fingerprint
    }

    pub fn seed_base(&self) -> u32 {
        self.seed_base
    }

    pub fn is_powered(&self) -> bool {
        self.powered_fixture
    }
}

/// One paired seed before any interval or verdict is computed.
#[derive(Clone, Debug, serde::Serialize)]
pub struct ProfileObservation {
    pub scenario_seed: u32,
    pub map_index: usize,
    pub lineup_index: usize,
    pub first_win_score: f64,
    pub mirror_win_score: f64,
    pub first_kill_difference: f64,
    pub mirror_kill_difference: f64,
    /// Positive team scores after suicide penalties, summed across both teams.
    /// This is match activity that self-destruction alone cannot manufacture.
    pub first_scored_kills: u32,
    pub mirror_scored_kills: u32,
    pub first_deaths: u32,
    pub mirror_deaths: u32,
}

#[derive(Clone, Copy)]
struct ProfileGame {
    win_score: f64,
    kill_difference: f64,
    scored_kills: u32,
    deaths: u32,
}

/// Prespecified size for a powered whole-family profile screen.
///
/// The declared family has ten contrasts. Its critical values retain the
/// older fifteen-comparison bound, so 3,384 pairs meet the normal-approximation
/// union-bound target of at least 90% whole-family power at a true rate of 0.5
/// and worst-case paired standard deviation of 0.5. The exact confirmatory
/// sample rounds that minimum up to a complete six-map, seven-lineup block.
/// Runs at smaller samples remain useful exploration, but cannot issue a
/// balance verdict. Exploration stops below the confirmatory boundary so it
/// cannot consume a registered attempt's seed range.
const PROFILE_POWER_MINIMUM_PAIRS: u32 = 3_384;
pub const PROFILE_POWERED_PAIRS: u32 = 3_402;
pub const PROFILE_EXPLORATORY_ATTEMPT: &str = "exploratory";
const PROFILE_SEED_NAMESPACE: u32 = 0x8F31_0000;
const PROFILE_POWERED_MAPS: [&str; 6] = [
    "drydock",
    "relay",
    "convoy",
    "shoal",
    "breakwater",
    "switchyard",
];
const PROFILE_SIDE_SIZE: usize = 4;
const PROFILE_LINEUP_SEATS: usize = PROFILE_SIDE_SIZE * 2;
const PROFILE_LINEUP_ROTATIONS: usize = sim::MAX_CLASSES;
const PROFILE_POWERED_MAP_BYTES: [&[u8]; 6] = [
    include_bytes!("../../catalog/zones/melee/drydock.vwmap"),
    include_bytes!("../../catalog/zones/melee/relay.vwmap"),
    include_bytes!("../../catalog/zones/melee/convoy.vwmap"),
    include_bytes!("../../catalog/zones/melee/shoal.vwmap"),
    include_bytes!("../../catalog/zones/melee/breakwater.vwmap"),
    include_bytes!("../../catalog/zones/melee/switchyard.vwmap"),
];
const PROFILE_POWERED_ZONE: &[u8] = include_bytes!("../../catalog/zones/melee/zone.toml");
const PROFILE_BALANCE_LOW: f64 = 0.45;
const PROFILE_BALANCE_HIGH: f64 = 0.55;
const PROFILE_COMPARISONS: usize = 10;
const PROFILE_PLANNING_COMPARISONS: usize = 15;
const PROFILE_JOINT_POWER: f64 = 0.90;
const PROFILE_WORST_VARIANCE: f64 = 0.25;
/// Fixed, descriptive fixture checks. Activity and sensitivity block a
/// powered verdict when the arena cannot expose a profile effect. The side
/// gap remains a warning rather than an inferential side-equivalence claim.
const PROFILE_MIN_SCORED_KILLS_PER_MATCH: f64 = 8.0;
const PROFILE_MIN_SENSITIVITY: f64 = 0.10;
const PROFILE_SIDE_GAP_WARNING: f64 = 0.10;
// The central-normal quantile after allocating the ten-percent family beta
// across fifteen comparisons: P(|Z| <= value) = 1 - 0.10 / 15. The declared
// family now has ten, so retaining it is conservative.
const PROFILE_POWER_Z: f64 = 2.713_051_888_472;
// 3.10 is a conservative two-sided critical value after a fifteen-comparison
// Bonferroni correction. The ten declared win-rate intervals therefore
// have conservative approximate family-wise 95% coverage. Kill-difference
// intervals are descriptive and do not enter this family or a verdict.
const PROFILE_FAMILY_T: f64 = 3.10;
const PROFILE_DESCRIPTIVE_T: f64 = 1.96;

fn profile_lineup(rotation: usize) -> [u8; PROFILE_LINEUP_SEATS] {
    let mut lineup = [0; PROFILE_LINEUP_SEATS];
    let rotation = rotation % PROFILE_LINEUP_ROTATIONS;
    for seat in 0..PROFILE_SIDE_SIZE {
        let class = ((rotation + seat) % sim::MAX_CLASSES) as u8;
        lineup[seat] = class;
        lineup[PROFILE_LINEUP_SEATS - 1 - seat] = class;
    }
    lineup
}

fn profile_stratum(sample: u32, map_count: usize) -> (usize, usize) {
    let sample = sample as usize;
    (
        sample % map_count,
        (sample / map_count) % PROFILE_LINEUP_ROTATIONS,
    )
}

fn profile_stratification_block(map_count: usize) -> u32 {
    (map_count * PROFILE_LINEUP_ROTATIONS) as u32
}

fn mean_interval_with_critical(samples: &[f64], critical: f64) -> (f64, f64, f64) {
    if samples.is_empty() {
        return (0.0, f64::NEG_INFINITY, f64::INFINITY);
    }
    let n = samples.len() as f64;
    let mean = samples.iter().sum::<f64>() / n;
    if samples.len() < 2 {
        return (mean, f64::NEG_INFINITY, f64::INFINITY);
    }
    let variance = samples
        .iter()
        .map(|sample| (sample - mean).powi(2))
        .sum::<f64>()
        / (n - 1.0);
    let margin = critical * (variance / n).sqrt();
    (mean, mean - margin, mean + margin)
}

fn family_win_interval(samples: &[f64]) -> (f64, f64, f64) {
    mean_interval_with_critical(samples, PROFILE_FAMILY_T)
}

fn descriptive_kill_interval(samples: &[f64]) -> (f64, f64, f64) {
    mean_interval_with_critical(samples, PROFILE_DESCRIPTIVE_T)
}

fn profile_verdict(
    powered_fixture: bool,
    fixture_valid: bool,
    low: f64,
    high: f64,
) -> &'static str {
    if !fixture_valid {
        if powered_fixture {
            "invalid fixture"
        } else {
            "exploratory: fixture checks failed"
        }
    } else if !powered_fixture {
        "exploratory: not prespecified sample"
    } else if low > PROFILE_BALANCE_HIGH {
        "overpowered"
    } else if high < PROFILE_BALANCE_LOW {
        "underpowered"
    } else if low >= PROFILE_BALANCE_LOW && high <= PROFILE_BALANCE_HIGH {
        "balanced"
    } else {
        "inconclusive"
    }
}

// Kits, lineup, mirror assignment, controller strength, seed, tuning and map
// stay explicit because each one is a frozen dimension of the profile fixture.
#[allow(clippy::too_many_arguments)]
fn profile_game(
    a: &[u8; sim::SLOT_COUNT],
    b: &[u8; sim::SLOT_COUNT],
    lineup: &[u8; PROFILE_LINEUP_SEATS],
    flip: bool,
    skill: f32,
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
    map: &ProfileMapFixture,
) -> Option<ProfileGame> {
    // Team one is reversed because the authored half-turn spawn pairs appear
    // in reverse row-major order. Each hull starts opposite its own class
    // rather than inheriting a lane effect from a different footprint.
    // Profile, side, spawn and bot seed are the only things a mirrored pair
    // exchanges.
    let kits = if flip { [*b, *a] } else { [*a, *b] };
    let seconds = tuning
        .and_then(|config| config.match_seconds)
        .unwrap_or(180) as u32;
    let (seats, _) = team_match_with_options(
        lineup,
        skill,
        sim::KIT_BUDGET,
        salt,
        tuning,
        TeamMap::Profile(map),
        TeamMatchOptions {
            kits: Some(&kits),
            tick_limit: seconds * 100,
            // This fixture measures a fixed three-minute exposure, so every
            // mirrored game runs the complete configured clock.
            kill_target_per_player: None,
        },
    );
    if seats.len() != lineup.len() {
        return None;
    }
    let deaths = seats.iter().map(|seat| seat.deaths).sum();
    let mut kills = [0i32; 2];
    for seat in seats {
        kills[seat.team as usize] += seat.score;
    }
    let (result, kill_difference, scored_kills) = profile_score(kills, flip);
    Some(ProfileGame {
        win_score: result,
        kill_difference,
        scored_kills,
        deaths,
    })
}

/// Score a profile leg exactly as live Melee presents it. A side can run its
/// signed ship total below zero with suicides or team kills, but the match
/// scoreboard clamps that total into its unsigned wire range before it chooses
/// a winner.
fn profile_score(kills: [i32; 2], flip: bool) -> (f64, f64, u32) {
    let score = kills.map(|value| value.clamp(0, u16::MAX as i32));
    let scored_kills = score
        .iter()
        .map(|&value| value as u32)
        .fold(0u32, u32::saturating_add);
    let (ours, theirs) = if flip {
        (score[1], score[0])
    } else {
        (score[0], score[1])
    };
    let result = match ours.cmp(&theirs) {
        std::cmp::Ordering::Greater => 1.0,
        std::cmp::Ordering::Equal => 0.5,
        std::cmp::Ordering::Less => 0.0,
    };
    (result, f64::from(ours - theirs), scored_kills)
}

/// Compiler, flags and target that turn the fixed calibration sources into an
/// executable. Source identity alone is not enough: a local binary and the
/// pinned release image must not authorize the same confirmatory attempt when
/// they were produced by different toolchains.
fn calibration_execution_fingerprint() -> String {
    fingerprint(&[
        env!("CARGO_PKG_VERSION").as_bytes(),
        env!("VW_RUSTC_VERSION").as_bytes(),
        env!("VW_BUILD_PROFILE").as_bytes(),
        env!("VW_BUILD_OPT_LEVEL").as_bytes(),
        env!("VW_BUILD_DEBUG").as_bytes(),
        env!("VW_BUILD_TARGET").as_bytes(),
        env!("VW_BUILD_HOST").as_bytes(),
        env!("VW_BUILD_TARGET_FEATURES").as_bytes(),
        env!("VW_BUILD_RUSTFLAGS").as_bytes(),
        env!("VW_CC_IDENTITY").as_bytes(),
        std::env::consts::ARCH.as_bytes(),
        std::env::consts::OS.as_bytes(),
        std::env::consts::FAMILY.as_bytes(),
    ])
}

fn profile_controller_fingerprint() -> String {
    profile_controller_fingerprint_with_modes(include_bytes!("modes.rs"))
}

fn profile_controller_fingerprint_with_modes(modes_source: &[u8]) -> String {
    fingerprint(&[
        include_bytes!("ai.rs"),
        include_bytes!("arena.rs"),
        include_bytes!("bots.rs"),
        include_bytes!("calibrate.rs"),
        include_bytes!("catalog.rs"),
        include_bytes!("config.rs"),
        include_bytes!("main.rs"),
        modes_source,
        include_bytes!("nav.rs"),
        include_bytes!("pilots.rs"),
        include_bytes!("profiles.rs"),
        include_bytes!("room.rs"),
        include_bytes!("shopper.rs"),
        include_bytes!("sim.rs"),
        include_bytes!("../build.rs"),
        include_bytes!("../Cargo.toml"),
        include_bytes!("../Cargo.lock"),
        include_bytes!("../../Dockerfile"),
        include_bytes!("../../sim/src/baseline.c"),
        include_bytes!("../../sim/src/check.c"),
        include_bytes!("../../sim/src/pack.c"),
        include_bytes!("../../sim/src/sim.c"),
        include_bytes!("../../sim/src/sintab.h"),
        include_bytes!("../../sim/include/sim/baseline.h"),
        include_bytes!("../../sim/include/sim/pack.h"),
        include_bytes!("../../sim/include/sim/sim.h"),
    ])
}

/// Fingerprint the profile-screen design without its attempt name or seed
/// namespace. Raw fixture content, loadouts, analysis constants and every
/// source file that can change match behavior are bound into the digest.
pub fn profile_design_fingerprint(
    paired_seeds: u32,
    zone: &str,
    zone_source: &str,
    skill: f32,
    maps: &[(String, Arena)],
) -> Result<String, String> {
    profile_design_fingerprint_with_execution(
        paired_seeds,
        zone,
        zone_source,
        skill,
        maps,
        &calibration_execution_fingerprint(),
    )
}

fn profile_design_fingerprint_with_execution(
    paired_seeds: u32,
    zone: &str,
    zone_source: &str,
    skill: f32,
    maps: &[(String, Arena)],
    execution_fingerprint: &str,
) -> Result<String, String> {
    let contrasts = profiles::calibration_contrasts();
    profile_design_fingerprint_for_contrasts(
        paired_seeds,
        zone,
        zone_source,
        skill,
        maps,
        execution_fingerprint,
        &contrasts,
    )
}

fn profile_design_fingerprint_for_contrasts(
    paired_seeds: u32,
    zone: &str,
    zone_source: &str,
    skill: f32,
    maps: &[(String, Arena)],
    execution_fingerprint: &str,
    contrasts: &[profiles::ProfileContrast],
) -> Result<String, String> {
    let definition: catalog::ZoneDef = toml::from_str(zone_source)
        .map_err(|error| format!("profile calibration cannot parse zone {zone:?}: {error}"))?;
    validate_profile_contrasts(contrasts, Some(&definition.arena))?;
    if contrasts.len() != PROFILE_COMPARISONS {
        return Err(format!(
            "profile calibration defines {} comparisons; the powered design requires {PROFILE_COMPARISONS}",
            contrasts.len()
        ));
    }
    let map_fingerprints: Vec<_> = maps
        .iter()
        .map(|(name, map)| (name, map.fingerprint()))
        .collect();
    let profile_contrasts: Vec<_> = contrasts
        .iter()
        .map(|contrast| {
            (
                contrast.name,
                (contrast.a.name, contrast.a.kit),
                (contrast.b.name, contrast.b.kit),
            )
        })
        .collect();
    let lineups: Vec<_> = (0..PROFILE_LINEUP_ROTATIONS).map(profile_lineup).collect();
    let payload = serde_json::json!({
        "schema_version": 2,
        "paired_seeds": paired_seeds,
        "zone": zone,
        "zone_fingerprint": fingerprint(&[zone_source.as_bytes()]),
        "maps": map_fingerprints,
        "contrasts": profile_contrasts,
        "skill_bits": skill.to_bits(),
        "match_seconds": definition.arena.match_seconds,
        "comparisons": PROFILE_COMPARISONS,
        "planning_comparisons": PROFILE_PLANNING_COMPARISONS,
        "balance_band": [PROFILE_BALANCE_LOW, PROFILE_BALANCE_HIGH],
        "family_critical": PROFILE_FAMILY_T,
        "descriptive_critical": PROFILE_DESCRIPTIVE_T,
        "target_whole_family_power": PROFILE_JOINT_POWER,
        "worst_case_paired_variance": PROFILE_WORST_VARIANCE,
        "per_comparison_central_power_z": PROFILE_POWER_Z,
        "minimum_powered_paired_seeds": PROFILE_POWER_MINIMUM_PAIRS,
        "maximum_exploratory_paired_seeds": PROFILE_POWERED_PAIRS - 1,
        "lineups": lineups,
        "lineup_index_policy": "floor(sample / map count) modulo seven",
        "map_index_policy": "sample modulo map count",
        "stratification_block_paired_seeds": profile_stratification_block(maps.len()),
        "minimum_mean_scored_kills_per_match_per_map": PROFILE_MIN_SCORED_KILLS_PER_MATCH,
        "minimum_mean_profile_sensitivity_per_map": PROFILE_MIN_SENSITIVITY,
        "absolute_observed_side_gap_warning_threshold_per_map": PROFILE_SIDE_GAP_WARNING,
        "controller_fingerprint": profile_controller_fingerprint(),
        "execution_fingerprint": execution_fingerprint,
    });
    let encoded = serde_json::to_vec(&payload)
        .map_err(|error| format!("profile design could not be fingerprinted: {error}"))?;
    Ok(fingerprint(&[&encoded]))
}

fn valid_profile_attempt_id(attempt_id: &str) -> bool {
    let mut bytes = attempt_id.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn valid_sha256_fingerprint(value: &str) -> bool {
    value.strip_prefix("sha256:").is_some_and(|digest| {
        digest.len() == 64
            && digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

fn profile_attempt_seed_base(attempt_id: &str) -> u32 {
    let digest = catalog::sha256_hex(attempt_id.as_bytes());
    let mut folded = PROFILE_SEED_NAMESPACE;
    for offset in (0..digest.len()).step_by(8) {
        let word = u32::from_str_radix(&digest[offset..offset + 8], 16)
            .expect("a SHA-256 word is hexadecimal");
        folded = folded
            .rotate_left(7)
            .wrapping_add(word)
            .wrapping_mul(0x9E37_79B1);
    }
    // Keep the full powered range away from wrapping and from the seed-zero
    // exploratory stream. The registry rejects the unlikely case where two
    // attempt IDs still land on overlapping ranges.
    let first = PROFILE_POWERED_PAIRS as u64;
    let choices = u32::MAX as u64 - 2 * PROFILE_POWERED_PAIRS as u64 + 2;
    (first + u64::from(folded) % choices) as u32
}

fn parse_profile_attempt_registry(
    registry_json: &str,
) -> Result<ProfileCalibrationAttemptRegistry, String> {
    let registry: ProfileCalibrationAttemptRegistry = serde_json::from_str(registry_json)
        .map_err(|error| format!("profile attempt registry is invalid: {error}"))?;
    if registry.schema_version != 1 {
        return Err(format!(
            "profile attempt registry schema {} is unsupported",
            registry.schema_version
        ));
    }
    let mut attempt_ids = HashSet::new();
    let mut designs = HashSet::new();
    let mut seed_bases = Vec::<(u32, &str)>::new();
    for attempt in &registry.attempts {
        if !valid_profile_attempt_id(&attempt.attempt_id)
            || attempt.attempt_id == PROFILE_EXPLORATORY_ATTEMPT
            || !attempt_ids.insert(attempt.attempt_id.as_str())
            || !valid_sha256_fingerprint(&attempt.design_fingerprint)
        {
            return Err(
                "profile attempt registry has an invalid, reserved or duplicate attempt".into(),
            );
        }
        if !designs.insert(attempt.design_fingerprint.as_str()) {
            return Err(format!(
                "profile design {} has more than one registered attempt",
                attempt.design_fingerprint
            ));
        }
        let base = profile_attempt_seed_base(&attempt.attempt_id);
        if let Some((_, other)) = seed_bases
            .iter()
            .find(|(other_base, _)| base.abs_diff(*other_base) < PROFILE_POWERED_PAIRS)
        {
            return Err(format!(
                "profile attempts {:?} and {:?} have overlapping seed namespaces",
                other, attempt.attempt_id
            ));
        }
        seed_bases.push((base, &attempt.attempt_id));
    }
    Ok(registry)
}

/// Validate an exploratory or confirmatory profile request before collection.
/// Exact powered runs fail closed unless the requested attempt is the sole
/// registry entry for the current design.
pub fn prepare_profile_calibration(
    paired_seeds: u32,
    attempt_id: &str,
    registry_json: &str,
    zone: &str,
    zone_source: &str,
    skill: f32,
    maps: &[(String, Arena)],
) -> Result<ProfileCalibrationRun, String> {
    if maps.is_empty() {
        return Err("profile calibration requires at least one readable map".into());
    }
    if paired_seeds == 0 {
        return Err("profile calibration requires at least one paired seed".into());
    }
    if !paired_seeds.is_multiple_of(maps.len() as u32) {
        return Err(format!(
            "{paired_seeds} paired seeds do not divide evenly across {} maps",
            maps.len()
        ));
    }
    let definition: catalog::ZoneDef = toml::from_str(zone_source)
        .map_err(|error| format!("profile calibration cannot parse zone {zone:?}: {error}"))?;
    let powered_fixture = is_powered_profile_fixture(
        paired_seeds,
        zone,
        zone_source,
        skill,
        &definition.arena,
        maps,
    );
    if paired_seeds == PROFILE_POWERED_PAIRS && !powered_fixture {
        return Err(format!(
            "the {PROFILE_POWERED_PAIRS}-pair powered screen requires the shipped melee zone, its ordered six-map rotation, seven cyclic lineups, and a 180-second clock"
        ));
    }
    if !powered_fixture && paired_seeds >= PROFILE_POWERED_PAIRS {
        return Err(format!(
            "exploratory profile calibration requires fewer than {PROFILE_POWERED_PAIRS} paired seeds so its seed-zero stream cannot overlap confirmatory evidence"
        ));
    }
    let design_fingerprint =
        profile_design_fingerprint(paired_seeds, zone, zone_source, skill, maps)?;
    if !powered_fixture {
        if attempt_id != PROFILE_EXPLORATORY_ATTEMPT {
            return Err(format!(
                "profile attempt {attempt_id:?} is confirmatory, but only the exact {PROFILE_POWERED_PAIRS}-pair fixture can use a registered attempt"
            ));
        }
        return Ok(ProfileCalibrationRun {
            attempt_id: attempt_id.into(),
            design_fingerprint,
            seed_base: 0,
            powered_fixture: false,
        });
    }
    if !valid_profile_attempt_id(attempt_id) || attempt_id == PROFILE_EXPLORATORY_ATTEMPT {
        return Err(
            "the powered profile screen requires a valid non-exploratory attempt ID".into(),
        );
    }
    let registry = parse_profile_attempt_registry(registry_json)
        .map_err(|error| format!("{error}; current profile design is {design_fingerprint}"))?;
    let matching: Vec<_> = registry
        .attempts
        .iter()
        .filter(|attempt| attempt.design_fingerprint == design_fingerprint)
        .collect();
    if matching.len() != 1 || matching[0].attempt_id != attempt_id {
        return Err(format!(
            "profile attempt {attempt_id:?} is not preregistered for design {design_fingerprint}"
        ));
    }
    Ok(ProfileCalibrationRun {
        attempt_id: attempt_id.into(),
        design_fingerprint,
        seed_base: profile_attempt_seed_base(attempt_id),
        powered_fixture: true,
    })
}

struct ProfileScreen<'a> {
    paired_seeds: u32,
    seed_base: u32,
    skill: f32,
    tuning: &'a config::ArenaConfig,
    maps: &'a [ProfileMapFixture],
    map_names: Vec<String>,
    powered_fixture: bool,
}

fn run_profile_comparison(
    contrast: &profiles::ProfileContrast,
    screen: &ProfileScreen<'_>,
) -> Result<ProfileResult, String> {
    let a = &contrast.a;
    let b = &contrast.b;
    let mut outcomes = Vec::with_capacity(screen.paired_seeds as usize);
    let mut differences = Vec::with_capacity(screen.paired_seeds as usize);
    let mut observations = Vec::with_capacity(screen.paired_seeds as usize);
    for sample in 0..screen.paired_seeds {
        let (map_index, lineup_index) = profile_stratum(sample, screen.maps.len());
        let map = &screen.maps[map_index];
        let lineup = profile_lineup(lineup_index);
        // Every comparison gets the same map, lineup, spawn and bot streams.
        // Bonferroni does not require comparisons to be independent, and
        // common random numbers make differences between rows easier to
        // attribute to the profiles they name.
        let scenario_seed = screen.seed_base.wrapping_add(sample);
        let salt = scenario_seed.wrapping_mul(2654435761);
        let first = profile_game(
            &a.kit,
            &b.kit,
            &lineup,
            false,
            screen.skill,
            salt,
            Some(screen.tuning),
            map,
        )
        .ok_or_else(|| {
            format!(
                "profile match {} versus {} failed to seat on map {:?}",
                a.name, b.name, screen.map_names[map_index]
            )
        })?;
        let second = profile_game(
            &a.kit,
            &b.kit,
            &lineup,
            true,
            screen.skill,
            salt,
            Some(screen.tuning),
            map,
        )
        .ok_or_else(|| {
            format!(
                "profile mirror {} versus {} failed to seat on map {:?}",
                a.name, b.name, screen.map_names[map_index]
            )
        })?;
        outcomes.push((first.win_score + second.win_score) / 2.0);
        differences.push((first.kill_difference + second.kill_difference) / 2.0);
        observations.push(ProfileObservation {
            scenario_seed,
            map_index,
            lineup_index,
            first_win_score: first.win_score,
            mirror_win_score: second.win_score,
            first_kill_difference: first.kill_difference,
            mirror_kill_difference: second.kill_difference,
            first_scored_kills: first.scored_kills,
            mirror_scored_kills: second.scored_kills,
            first_deaths: first.deaths,
            mirror_deaths: second.deaths,
        });
    }
    let fixture_validity = profile_fixture_validity(&observations, &screen.map_names);
    let fixture_valid = fixture_validity.iter().all(|map| map.valid);
    let (win_rate, win_rate_low, win_rate_high) = family_win_interval(&outcomes);
    let (kill_difference, kill_difference_low, kill_difference_high) =
        descriptive_kill_interval(&differences);
    let verdict = profile_verdict(
        screen.powered_fixture,
        fixture_valid,
        win_rate_low,
        win_rate_high,
    );
    Ok(ProfileResult {
        contrast: contrast.name,
        a: a.name,
        b: b.name,
        paired_seeds: screen.paired_seeds,
        matches: screen.paired_seeds * 2,
        win_rate,
        win_rate_low,
        win_rate_high,
        kill_difference,
        kill_difference_low,
        kill_difference_high,
        verdict,
        powered_fixture: screen.powered_fixture,
        fixture_valid,
        fixture_validity,
        observations,
    })
}

/// Run the ten declared marginal-pip contrasts in four-a-side,
/// configured-length matches on the shipped map and hull rotations. Each seed
/// is played twice with the two profiles exchanging sides, then treated as one
/// paired observation.
pub fn run_profiles(
    run: &ProfileCalibrationRun,
    paired_seeds: u32,
    zone: &str,
    zone_source: &str,
    skill: f32,
    maps: &[(String, Arena)],
    verbose: bool,
) -> Result<Vec<ProfileResult>, String> {
    if maps.is_empty() {
        return Err("profile calibration requires at least one readable map".into());
    }
    if paired_seeds == 0 {
        return Err("profile calibration requires at least one paired seed".into());
    }
    if !paired_seeds.is_multiple_of(maps.len() as u32) {
        return Err(format!(
            "{paired_seeds} paired seeds do not divide evenly across {} maps",
            maps.len()
        ));
    }
    let definition: catalog::ZoneDef = toml::from_str(zone_source)
        .map_err(|error| format!("profile calibration cannot parse zone {zone:?}: {error}"))?;
    let tuning = &definition.arena;
    let mut map_geometries = Vec::with_capacity(maps.len());
    for (name, map) in maps {
        let world = team_world(0, Some(tuning), map)
            .ok_or_else(|| format!("profile calibration cannot build map {name:?}"))?;
        map_geometries.push(std::sync::Arc::clone(&world.map));
    }
    let powered_fixture =
        is_powered_profile_fixture(paired_seeds, zone, zone_source, skill, tuning, maps);
    if paired_seeds == PROFILE_POWERED_PAIRS && !powered_fixture {
        return Err(format!(
            "the {PROFILE_POWERED_PAIRS}-pair powered screen requires the shipped melee zone, its ordered six-map rotation, seven cyclic lineups, and a 180-second clock"
        ));
    }
    if !powered_fixture && paired_seeds >= PROFILE_POWERED_PAIRS {
        return Err(format!(
            "exploratory profile calibration requires fewer than {PROFILE_POWERED_PAIRS} paired seeds so its seed-zero stream cannot overlap confirmatory evidence"
        ));
    }
    let design_fingerprint =
        profile_design_fingerprint(paired_seeds, zone, zone_source, skill, maps)?;
    if design_fingerprint != run.design_fingerprint
        || powered_fixture != run.powered_fixture
        || (powered_fixture && run.attempt_id == PROFILE_EXPLORATORY_ATTEMPT)
        || (powered_fixture && run.seed_base != profile_attempt_seed_base(&run.attempt_id))
        || (!powered_fixture
            && (run.attempt_id != PROFILE_EXPLORATORY_ATTEMPT || run.seed_base != 0))
    {
        return Err(
            "profile calibration inputs do not match the prepared attempt authorization".into(),
        );
    }
    let contrasts = profiles::calibration_contrasts();
    validate_profile_contrasts(&contrasts, Some(tuning))?;
    if contrasts.len() != PROFILE_COMPARISONS {
        return Err(format!(
            "profile calibration defines {} comparisons; the powered design requires {PROFILE_COMPARISONS}",
            contrasts.len()
        ));
    }
    // Navigation is expensive to construct and depends only on immutable map
    // geometry. Build it after authorization, once per map, before any worker
    // starts a match.
    let fixtures: Vec<_> = map_geometries
        .into_iter()
        .map(ProfileMapFixture::new)
        .collect();
    let screen = ProfileScreen {
        paired_seeds,
        seed_base: run.seed_base,
        skill,
        tuning,
        maps: &fixtures,
        map_names: maps.iter().map(|(name, _)| name.clone()).collect(),
        powered_fixture,
    };

    // A contrast owns its entire accumulation stream. Running the ten
    // streams concurrently changes neither sample order nor floating-point
    // addition order, and joining in the declared pair order keeps the report
    // byte-for-byte stable across scheduler decisions.
    std::thread::scope(|scope| -> Result<Vec<ProfileResult>, String> {
        let mut workers = Vec::with_capacity(contrasts.len());
        for contrast in &contrasts {
            let screen = &screen;
            workers.push((
                contrast.name,
                contrast.a.name,
                contrast.b.name,
                scope.spawn(move || run_profile_comparison(contrast, screen)),
            ));
        }

        let mut out = Vec::with_capacity(workers.len());
        let mut first_error = None;
        for (contrast, a, b, worker) in workers {
            match worker.join() {
                Ok(Ok(result)) => {
                    if verbose {
                        println!("{contrast} done: {paired_seeds} paired seeds");
                    }
                    out.push(result);
                }
                Ok(Err(error)) => {
                    first_error.get_or_insert(error);
                }
                Err(_) => {
                    first_error.get_or_insert_with(|| {
                        format!("profile contrast {contrast} ({a} versus {b}) worker panicked")
                    });
                }
            }
        }
        if let Some(error) = first_error {
            Err(error)
        } else {
            Ok(out)
        }
    })
}

fn validate_profile_contrasts(
    contrasts: &[profiles::ProfileContrast],
    tuning: Option<&config::ArenaConfig>,
) -> Result<(), String> {
    let mut names = HashSet::new();
    for contrast in contrasts {
        if contrast.name.trim().is_empty() || !names.insert(contrast.name) {
            return Err("profile calibration has a blank or duplicate contrast name".into());
        }
        if contrast.a.name.trim().is_empty()
            || contrast.b.name.trim().is_empty()
            || contrast.a.name == contrast.b.name
        {
            return Err(format!(
                "profile contrast {:?} does not name both sides unambiguously",
                contrast.name
            ));
        }
    }
    let profiles: Vec<_> = contrasts
        .iter()
        .flat_map(|contrast| [&contrast.a, &contrast.b])
        .cloned()
        .collect();
    validate_profile_kits(&profiles, tuning)
}

fn validate_profile_kits(
    choices: &[profiles::Profile],
    tuning: Option<&config::ArenaConfig>,
) -> Result<(), String> {
    for profile in choices {
        let cost = sim::World::kit_cost(&profile.kit);
        if cost != sim::KIT_BUDGET {
            return Err(format!(
                "profile {:?} costs {cost} points; expected {}",
                profile.name,
                sim::KIT_BUDGET
            ));
        }
        for class in 0..sim::MAX_CLASSES as u8 {
            let mut world = sim::World::with_map(1, sim::build_pit);
            if let Some(config) = tuning {
                crate::Room::apply_config(&mut world, config);
            }
            let ship = world.spawn(class, 0, 505, 522, 0);
            if ship < 0 || !world.set_kit(ship as usize, &profile.kit) {
                return Err(format!(
                    "profile {:?} is rejected by hull {class} in the selected zone",
                    profile.name
                ));
            }
        }
    }
    Ok(())
}

fn profile_fixture_validity<S: AsRef<str>>(
    observations: &[ProfileObservation],
    maps: &[S],
) -> Vec<ProfileMapValidity> {
    let mut validity = Vec::with_capacity(maps.len());
    for (map_index, map) in maps.iter().enumerate() {
        let map = map.as_ref();
        let rows: Vec<_> = observations
            .iter()
            .filter(|row| row.map_index == map_index)
            .collect();
        if rows.is_empty() {
            validity.push(ProfileMapValidity {
                map_index,
                map: map.into(),
                paired_seeds: 0,
                matches: 0,
                mean_positive_scored_kills_per_match: 0.0,
                mean_profile_sensitivity: 0.0,
                absolute_observed_side_gap: 0.0,
                valid: false,
                failures: vec!["no_paired_observations"],
                warnings: Vec::new(),
            });
            continue;
        }
        let scored_kills: u64 = rows
            .iter()
            .map(|row| u64::from(row.first_scored_kills) + u64::from(row.mirror_scored_kills))
            .sum();
        let matches = (rows.len() * 2) as f64;
        let mean_scored_kills = scored_kills as f64 / matches;
        let mut failures = Vec::new();
        if mean_scored_kills < PROFILE_MIN_SCORED_KILLS_PER_MATCH {
            failures.push("mean_positive_scored_kills_per_match_below_minimum");
        }

        // A owns team 0 in the first leg and team 1 in the mirror. From A's
        // recentered perspective, first minus mirror is therefore the observed
        // team-0 score minus team-1 score for the pair.
        let side_gap = (rows
            .iter()
            .map(|row| row.first_win_score - row.mirror_win_score)
            .sum::<f64>()
            / rows.len() as f64)
            .abs();
        let warnings = if side_gap > PROFILE_SIDE_GAP_WARNING {
            vec!["absolute_observed_side_gap_above_warning"]
        } else {
            Vec::new()
        };

        // A pair that reads 0.5 can be two draws or one side winning both
        // legs. Either way it provides no evidence that profiles can affect
        // the result. Weight partial 0.25/0.75 departures by half so this is a
        // mean profile-decisiveness score on zero through one.
        let sensitivity = rows
            .iter()
            .map(|row| {
                let paired = (row.first_win_score + row.mirror_win_score) / 2.0;
                2.0 * (paired - 0.5).abs()
            })
            .sum::<f64>()
            / rows.len() as f64;
        if sensitivity < PROFILE_MIN_SENSITIVITY {
            failures.push("mean_profile_sensitivity_below_minimum");
        }

        validity.push(ProfileMapValidity {
            map_index,
            map: map.into(),
            paired_seeds: rows.len() as u32,
            matches: rows.len() as u32 * 2,
            mean_positive_scored_kills_per_match: mean_scored_kills,
            mean_profile_sensitivity: sensitivity,
            absolute_observed_side_gap: side_gap,
            valid: failures.is_empty(),
            failures,
            warnings,
        });
    }
    validity
}

fn is_powered_profile_fixture(
    paired_seeds: u32,
    zone: &str,
    zone_source: &str,
    skill: f32,
    tuning: &config::ArenaConfig,
    maps: &[(String, Arena)],
) -> bool {
    paired_seeds == PROFILE_POWERED_PAIRS
        && zone == "melee"
        && zone_source.as_bytes() == PROFILE_POWERED_ZONE
        && skill.to_bits() == 0.50f32.to_bits()
        && tuning.match_seconds == Some(180)
        && maps
            .iter()
            .map(|(name, _)| name.as_str())
            .eq(PROFILE_POWERED_MAPS)
        && maps
            .iter()
            .zip(PROFILE_POWERED_MAP_BYTES)
            .all(|((_, map), expected)| {
                matches!(map, Arena::Packed(bytes) if bytes.as_slice() == expected)
            })
}

pub fn report_profiles(
    run: &ProfileCalibrationRun,
    results: &[ProfileResult],
    zone: &str,
    zone_fingerprint: &str,
    skill: f32,
    match_seconds: u16,
    maps: &[(String, Arena)],
) -> serde_json::Value {
    let contrasts = profiles::calibration_contrasts();
    assert_eq!(
        contrasts.len(),
        PROFILE_COMPARISONS,
        "profile report family does not match its declared comparison count"
    );
    assert_eq!(
        results.len(),
        PROFILE_COMPARISONS,
        "profile report is missing declared contrast results"
    );
    for (result, contrast) in results.iter().zip(&contrasts) {
        assert_eq!(
            (result.contrast, result.a, result.b),
            (contrast.name, contrast.a.name, contrast.b.name),
            "profile report results do not follow the declared contrast order"
        );
    }
    let paired_seeds = results.first().map_or(0, |result| result.paired_seeds);
    let stratification_block = profile_stratification_block(maps.len());
    let lineups: Vec<_> = (0..PROFILE_LINEUP_ROTATIONS).map(profile_lineup).collect();
    assert!(
        results
            .iter()
            .all(|result| result.paired_seeds == paired_seeds),
        "profile report results use different paired sample counts"
    );
    println!(
        "\nprofile balance: {zone}, {paired_seeds} paired seeds and {} matches per comparison",
        paired_seeds * 2
    );
    println!(
        "conservative approximate family-wise 95% win-rate intervals across {} declared contrasts; critical value planned for {}; balance band 45% to 55%; prespecified powered sample {PROFILE_POWERED_PAIRS}",
        PROFILE_COMPARISONS, PROFILE_PLANNING_COMPARISONS
    );
    println!("kill-difference intervals are descriptive and do not enter the verdict");
    println!(
        "\n{:<48} {:>7} {:>19} {:>8} {:>19}  verdict",
        "contrast", "win%", "win family 95%", "kill +/-", "descriptive 95%"
    );
    for result in results {
        println!(
            "{:<48} {:>7.1} {:>8.1} to {:>7.1} {:>8.2} {:>8.2} to {:>7.2}  {}",
            result.contrast,
            result.win_rate * 100.0,
            result.win_rate_low * 100.0,
            result.win_rate_high * 100.0,
            result.kill_difference,
            result.kill_difference_low,
            result.kill_difference_high,
            result.verdict,
        );
    }
    println!(
        "\nfixture gates: positive scored kills per match and profile sensitivity; absolute observed side gap is a warning"
    );
    for result in results {
        for map in &result.fixture_validity {
            let notes = map
                .failures
                .iter()
                .chain(&map.warnings)
                .copied()
                .collect::<Vec<_>>()
                .join(", ");
            println!(
                "{:<48} {:<12} {:>6.2} {:>7.3} {:>7.3}  {}",
                result.contrast,
                map.map,
                map.mean_positive_scored_kills_per_match,
                map.mean_profile_sensitivity,
                map.absolute_observed_side_gap,
                if notes.is_empty() { "pass" } else { &notes },
            );
        }
    }
    let fixture_valid = results.iter().all(|result| result.fixture_valid);
    serde_json::json!({
        "attempt_id": run.attempt_id(),
        "design_fingerprint": run.design_fingerprint(),
        "seed_base": run.seed_base(),
        "zone": zone,
        "zone_fingerprint": zone_fingerprint,
        "maps": maps.iter().map(|(name, map)| serde_json::json!({
            "name": name,
            "fingerprint": map.fingerprint()
        })).collect::<Vec<_>>(),
        "contrasts": contrasts,
        "skill": skill,
        "match_seconds": match_seconds,
        "paired_seeds": paired_seeds,
        "matches_per_comparison": paired_seeds * 2,
        "comparisons": PROFILE_COMPARISONS,
        "win_rate_confidence": "conservative approximate family-wise 95% Bonferroni paired t intervals across 10 declared contrasts; critical value planned for 15",
        "kill_difference_confidence": "descriptive approximate 95% paired intervals; excluded from the family and verdict",
        "family_critical": PROFILE_FAMILY_T,
        "descriptive_critical": PROFILE_DESCRIPTIVE_T,
        "balance_band": [PROFILE_BALANCE_LOW, PROFILE_BALANCE_HIGH],
        "prespecified_powered_paired_seeds": PROFILE_POWERED_PAIRS,
        "seed_namespace_policy": format!("zero-based and capped below {PROFILE_POWERED_PAIRS} pairs for exploration; SHA-256-derived and registry-checked for a powered attempt"),
        "fixture_schedule": {
            "side_size": PROFILE_SIDE_SIZE,
            "lineups": lineups,
            "map_index_policy": "sample modulo map count",
            "lineup_index_policy": "floor(sample / map count) modulo seven",
            "stratification_block_paired_seeds": stratification_block,
            "complete_stratification_blocks": paired_seeds / stratification_block,
            "partial_block_paired_seeds": paired_seeds % stratification_block,
        },
        "build": crate::metrics::commit(),
        "execution_fingerprint": calibration_execution_fingerprint(),
        "fixture_valid": fixture_valid,
        "powered_design": {
            "target_whole_family_power": PROFILE_JOINT_POWER,
            "comparisons": PROFILE_COMPARISONS,
            "planning_comparisons": PROFILE_PLANNING_COMPARISONS,
            "minimum_powered_paired_seeds": PROFILE_POWER_MINIMUM_PAIRS,
            "worst_case_paired_sd": PROFILE_WORST_VARIANCE.sqrt(),
            "centered_true_win_rate": 0.5,
            "per_comparison_central_power_z": PROFILE_POWER_Z,
            "method": "conservative normal-approximation two-sided union bound; the power minimum and critical values retain a fifteen-comparison planning bound for ten declared contrasts, and the confirmatory sample rounds up to a complete map-by-lineup block",
            "power_scope": "The design targets at least 90% whole-family power for the ten declared flight-stat contrasts under the stated assumptions because it retains the stricter fifteen-comparison allocation. The fixed fixture-validity gates are unpowered, and no 90% claim covers the chance that the full screen passes.",
            "fixture_validity": {
                "kind": "fixed descriptive activity and sensitivity gates, plus an unpowered side-gap warning; not certified side equivalence",
                "minimum_mean_positive_scored_kills_per_match_per_map": PROFILE_MIN_SCORED_KILLS_PER_MATCH,
                "minimum_mean_profile_sensitivity_per_map": PROFILE_MIN_SENSITIVITY,
                "profile_sensitivity_definition": "mean of 2 * abs((first win score + mirror win score) / 2 - 0.5)",
                "absolute_observed_side_gap_warning_threshold_per_map": PROFILE_SIDE_GAP_WARNING,
                "side_gap_definition": "absolute mean of first win score - mirror win score"
            }
        },
        "run_kind": if run.is_powered() {
            "prespecified powered screen"
        } else {
            "exploratory"
        },
        "results": results,
    })
}

/// Fill both sides at random, `matches` times, and read each hull off its seats.
pub fn run_teams(
    per_side: usize,
    matches: u32,
    budget: u32,
    skill: f32,
    tuning: Option<&config::ArenaConfig>,
    map: &Arena,
    verbose: bool,
) -> Vec<TeamRow> {
    let n = ai::CLASS_NAMES.len();
    let mut rows: Vec<TeamRow> = (0..n)
        .map(|i| TeamRow {
            name: ai::CLASS_NAMES[i],
            class: i as u8,
            seats: 0,
            won: 0,
            drawn: 0,
            kills: 0,
            deaths: 0,
            shots: [0; sim::TRIG_COUNT],
            engagement_distance: 0.0,
            engagement_samples: 0,
            planned_range: 0.0,
            planned_range_samples: 0,
            hits: 0,
            damage: 0,
            self_damage: 0,
            budget: 0,
            converted: 0,
        })
        .collect();

    // The draw is the state's own generator rather than anything of the host's,
    // so a run repeats. Salt walks, so no two matches share a lineup by
    // construction of the seed alone.
    let mut rng = 0x5eed_1eafu32;
    let mut undecided = 0u32;
    for m in 0..matches {
        let mut lineup = Vec::with_capacity(per_side * 2);
        for _ in 0..per_side * 2 {
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            lineup.push((rng % n as u32) as u8);
        }
        let (seats, decided) = team_match(&lineup, skill, budget, m, tuning, map);
        if seats.is_empty() {
            continue;
        }
        if !decided {
            undecided += 1;
        }
        let mut side = [0i32; 2];
        for s in &seats {
            side[s.team as usize] += s.score;
        }
        let winner = match side[0].cmp(&side[1]) {
            std::cmp::Ordering::Greater => Some(0u8),
            std::cmp::Ordering::Less => Some(1u8),
            std::cmp::Ordering::Equal => None,
        };
        for s in &seats {
            let r = &mut rows[s.class as usize];
            r.seats += 1;
            match winner {
                Some(w) if w == s.team => r.won += 1,
                None => r.drawn += 1,
                _ => {}
            }
            r.kills += s.kills;
            r.deaths += s.deaths;
            r.hits += s.hits;
            r.damage += s.damage;
            r.self_damage += s.self_damage;
            r.engagement_distance += s.engagement_distance;
            r.engagement_samples += s.engagement_samples;
            r.planned_range += s.planned_range;
            r.planned_range_samples += s.planned_range_samples;
            r.budget += s.budget;
            r.converted += s.converted;
            for t in 0..sim::TRIG_COUNT {
                r.shots[t] += s.shots[t];
            }
        }
        if verbose && (m + 1) % 100 == 0 {
            println!("{}/{} matches", m + 1, matches);
        }
    }
    if verbose {
        // Eight ships on a real map rarely reach twenty kills inside the five
        // minutes, so most matches are timed rather than raced. That is the
        // better instrument anyway: every lineup gets the same clock and the
        // score is the kill difference when it stops. Printed because a run
        // where matches suddenly start finishing early is a run whose lethality
        // moved, and that is worth noticing rather than averaging over.
        println!(
            "{} of {matches} matches reached the kill target; the rest were \
scored on the difference when the clock stopped",
            matches - undecided
        );
    }
    rows
}

/// The team report: a line per hull, read off the seats it filled.
///
/// Every column of the heading is an argument, because the heading is the
/// whole point of the report: a reader has to be able to see which run this
/// was without going to find the command that produced it.
#[allow(clippy::too_many_arguments)]
pub fn report_teams(
    rows: &[TeamRow],
    per_side: usize,
    skill: f32,
    budget: u32,
    matches: u32,
    zone: &str,
    map: &str,
    spawn_radius: u16,
) -> serde_json::Value {
    println!(
        "\nteam tournament: {per_side} a side, {zone} tuning on the {map}, skill \
{skill:.2}, a {budget}-point kit a life, spawn radius {spawn_radius}, {matches} matches, \
lineups drawn at random"
    );
    println!(
        "\n{:<10} {:>7} {:>7} {:>7} {:>8} {:>8} {:>7} {:>8} {:>7} {:>7} {:>7} {:>7}",
        "hull",
        "win%",
        "+-95%",
        "seats",
        "kills/s",
        "deaths/s",
        "K/D",
        "hit/pull",
        "gun/s",
        "bomb/s",
        "target",
        "actual"
    );
    for r in rows {
        let fired: u32 = r.shots.iter().sum();
        let s = r.seats.max(1) as f64;
        println!(
            "{:<10} {:>7.1} {:>7.1} {:>7} {:>8.2} {:>8.2} {:>7.2} {:>8.2} {:>7.1} {:>7.1} {:>7.0} {:>7.0}",
            r.name,
            100.0 * r.win_rate(),
            r.margin(),
            r.seats,
            r.kills as f64 / s,
            r.deaths as f64 / s,
            r.kills as f64 / r.deaths.max(1) as f64,
            r.hits as f64 / fired.max(1) as f64,
            r.shots[sim::TRIG_GUN] as f64 / s,
            r.shots[sim::TRIG_BOMB] as f64 / s,
            r.planned_range / r.planned_range_samples.max(1) as f64,
            r.engagement_distance / r.engagement_samples.max(1) as f64,
        );
    }
    // A hull is only as measured as the seats it drew, and a random lineup does
    // not deal them evenly. Worth printing rather than assuming.
    let lo = rows.iter().map(|r| r.seats).min().unwrap_or(0);
    let hi = rows.iter().map(|r| r.seats).max().unwrap_or(0);
    println!(
        "\nseats ran {lo} to {hi} across the roster, so the widest interval above \
is the one to read the board by."
    );

    serde_json::json!({
        "per_side": per_side, "tuning": zone, "map": map, "skill": skill,
        "kit_budget": budget, "spawn_radius": spawn_radius, "matches": matches,
        "hulls": rows.iter().map(|r| serde_json::json!({
            "name": r.name, "class": r.class, "seats": r.seats, "won": r.won,
            "drawn": r.drawn, "win_rate": r.win_rate(), "win_rate_margin": r.margin(),
            "kills": r.kills, "deaths": r.deaths,
            "gun_shots": r.shots[sim::TRIG_GUN], "bomb_shots": r.shots[sim::TRIG_BOMB],
            "mean_planned_range": r.planned_range / r.planned_range_samples.max(1) as f64,
            "mean_engagement_distance": r.engagement_distance / r.engagement_samples.max(1) as f64,
            "hits": r.hits, "damage": r.damage, "self_damage": r.self_damage,
            "kit_offered": r.budget, "kit_spent": r.converted,
        })).collect::<Vec<_>>(),
    })
}

/* ---- the real-map fixture ------------------------------------------
 *
 * The ladder and every harness that ranks pilots share one room and one
 * bout, because two of them drifting apart is how this file ended up
 * with a tournament that measured something nobody plays.
 */

/// A comma-separated list from the environment, or the default.
///
/// Sharding, and nothing cleverer. Seven hulls at three economies is
/// sixty-three thousand bouts, which is most of a day on one core and a
/// couple of hours split seven ways, so the run has to be splittable
/// without editing the test between shards.
pub(crate) fn env_list(key: &str, fallback: &[u32]) -> Vec<u32> {
    match std::env::var(key) {
        Ok(s) if !s.trim().is_empty() => {
            s.split(',').filter_map(|t| t.trim().parse().ok()).collect()
        }
        _ => fallback.to_vec(),
    }
}

/// Tiles between the two pilots at the start of a bout.
///
/// Inside `ai::SIGHT`, which is sixty tiles, so they have each other from
/// the first tick and the measurement is of fighting rather than of
/// walking. A tournament where the pilots never meet measures the map.
#[allow(
    dead_code,
    reason = "kept by the legacy calibration fixture and its focused tests"
)]
pub(crate) const APART: usize = 24;

/// Somewhere two pilots can be put down with room to fly.
///
/// Alpha is three per cent wall in clusters with long lanes between, so
/// most of it is open and a pair like this is easy to find; it is still
/// worth finding rather than assuming, because a hard-coded tile that
/// lands inside a cluster spawns nobody and the bout reads as a draw.
/// The map, its route and a place to put two pilots, built once.
#[allow(
    dead_code,
    reason = "kept by the legacy calibration fixture and its focused tests"
)]
pub(crate) fn real_map() -> Vec<u8> {
    // Both the crate directory a test runs in and the repository root a binary
    // is started from, because the ladder is generated by
    // `vectorwake-server calibrate` and measured by `cargo test`.
    const WHERE: [&str; 2] = [
        "../catalog/zones/melee/drydock.vwmap",
        "catalog/zones/melee/drydock.vwmap",
    ];
    WHERE
        .iter()
        .find_map(|p| std::fs::read(p).ok())
        .unwrap_or_else(|| panic!("a shipped map lives here; looked in {WHERE:?}"))
}

/// A shipped map, its routes, and a pair of open points to start two pilots
/// from. What every drill on real ground begins with.
#[allow(
    dead_code,
    reason = "kept by the legacy calibration fixture and its focused tests"
)]
pub(crate) type RealMap = (Vec<u8>, nav::Nav, ((i32, i32), (i32, i32)));

#[allow(
    dead_code,
    reason = "kept by the legacy calibration fixture and its focused tests"
)]
pub(crate) fn real_map_fixture() -> RealMap {
    let bytes = real_map();
    let probe = sim::World::from_packed(0x5eed, &bytes).expect("a map");
    let at = open_pair(&probe.map);
    let route = nav::Nav::build(&probe.map);
    (bytes, route, at)
}

#[allow(
    dead_code,
    reason = "kept by the legacy calibration fixture and its focused tests"
)]
fn open_pair(map: &sim::sim_map) -> ((i32, i32), (i32, i32)) {
    let clear = |cx: usize, cy: usize| {
        (cy.saturating_sub(4)..=cy + 4)
            .all(|y| (cx.saturating_sub(4)..=cx + 4).all(|x| map.class_at(x, y) == 0))
    };
    // Outward from the middle of the map, so the pair sits in the part of it a
    // room actually uses rather than against the boundary. The map's own
    // middle, not the array's: on a 144-tile room the array's middle is four
    // hundred tiles past the far wall, and every candidate out there is the
    // wall the core answers for anywhere off the map.
    let (mx, my) = (map.w as i32 / 2, map.h as i32 / 2);
    let reach = (map.w.min(map.h) as i32 / 2 - APART as i32).max(1);
    for r in 0..reach {
        for (dx, dy) in [(1i32, 0i32), (0, 1), (-1, 0), (0, -1)] {
            let (cx, cy) = (mx + dx * r, my + dy * r);
            if cx < 0 || cy < 0 {
                continue;
            }
            let (cx, cy) = (cx as usize, cy as usize);
            if clear(cx, cy) && clear(cx + APART, cy) {
                return ((cx as i32, cy as i32), ((cx + APART) as i32, cy as i32));
            }
        }
    }
    panic!("no open pair on this map");
}

/// One bout on a real map, returning the kills each pilot took.
///
/// `calibrate::bout` cannot be reused: it builds the pit, and it builds a
/// route per bout, which on a map this size is most of the cost.
///
/// The ground, the pair, the two pilots and the dial: everything a bout needs
/// and nothing it can work out for itself, since working any of it out per
/// bout is the cost this exists to avoid.
#[allow(
    dead_code,
    clippy::too_many_arguments,
    reason = "kept by the legacy calibration fixture and its focused tests"
)]
pub(crate) fn duel(
    bytes: &[u8],
    route: &nav::Nav,
    at: ((i32, i32), (i32, i32)),
    r: &mut rating::Rating,
    a: &ai::RosterEntry,
    b: &ai::RosterEntry,
    salt: u32,
    budget: u32,
    handicap: Option<(ai::Knob, f32)>,
) -> (i16, i16) {
    let mut world = sim::World::from_packed(0xd0e1 ^ salt, bytes).expect("a map");
    // The kit is handed out here rather than inherited from the zone, so both
    // pilots carry exactly `budget` and the only thing left varying between
    // them is the pilot.
    //
    // This used to be a bool that meant "let Alpha do what it does", which was
    // thirty at spawn and forty-two more scattered on the floor. The thirty
    // were matched and fine. The forty-two were not: whoever scavenged better
    // carried a kit the other did not have, and that landed on top of every
    // built number this harness ever printed. A tournament that ranks pilots
    // cannot also be a race for the floor.
    // Always. A scatter of 250 on a map this size throws them apart on
    // the first death and the rest of the bout is two pilots looking for
    // each other.
    world.cfg.spawn_radius = 0;

    // Sides alternate, so a corner cannot accumulate into a rating.
    // Sides alternate, and so does the heading each side is given.
    //
    // Alternating the pilots alone was not enough. A null run of this
    // fixture, two identical pilots and nothing handicapped, came back at
    // 63.6% to one of them: the two starts are not equivalent, and every
    // row measured here was being read against a coin that was not one.
    // Whatever the asymmetry is between these two tiles on this map, the
    // pilot who draws each start also draws each facing now.
    let flip = salt.is_multiple_of(2);
    let (first, second) = if flip { (a, b) } else { (b, a) };
    let (h1, h2) = if salt % 4 < 2 { (0, 32768) } else { (32768, 0) };
    let s1 = world.spawn(first.class, 0, at.0 .0, at.0 .1, h1) as u8;
    let s2 = world.spawn(second.class, 1, at.1 .0, at.1 .1, h2) as u8;

    let mut bot1 = ai::Bot::new(s1, first.skill);
    let mut bot2 = ai::Bot::new(s2, second.skill);
    // The ablation's handicap always rides on `a`, whichever side it drew.
    if let Some((knob, as_if)) = handicap {
        if salt.is_multiple_of(2) {
            bot1.tune(knob, as_if);
        } else {
            bot2.tune(knob, as_if);
        }
    }
    bot1.reseed(salt.wrapping_mul(2246822519) ^ 0x1234);
    bot2.reseed(salt.wrapping_mul(3266489917) ^ 0x5678);

    // The same stream on both sides, so the two pilots draw the same kit
    // on their first life, the same on their second, and so on.
    //
    // The hull tournament gives each side its own stream on purpose: it is
    // measuring hulls at a matched bounty, and matched on the number while
    // inexact on what it bought is the situation a player is in. This one
    // ranks pilots, so kit luck is not realism here, it is the thing being
    // controlled for. Identical draws cost nothing and take a whole source
    // of variance out of a measurement that needs every bout it has.
    //
    // Nonzero because xorshift that reaches zero stays there, and would
    // then deal the same slot for the rest of the bout.
    let seed = (salt.wrapping_mul(2654435761) ^ 0x9E37_79B9) | 1;
    let mut prng = [seed, seed];
    let seats = [s1, s2];
    for k in 0..2 {
        deal_kit(&mut world, seats[k] as usize, budget, &mut prng[k]);
    }
    let mut alive_was = [true; 2];

    let n1 = first.name.to_string();
    let n2 = second.name.to_string();
    let name_of = move |ship: u8| if ship == s1 { n1.clone() } else { n2.clone() };

    for _ in 0..MATCH_TICKS {
        let inputs = [
            sim::sim_input {
                ship: s1,
                buttons: bot1.think(
                    &ai::own(&world, s1),
                    route,
                    bot1.looks_due().then(|| ai::scan(&world, s1)),
                ),
            },
            sim::sim_input {
                ship: s2,
                buttons: bot2.think(
                    &ai::own(&world, s2),
                    route,
                    bot2.looks_due().then(|| ai::scan(&world, s2)),
                ),
            },
        ];
        world.step(&inputs);
        let tick = world.state.tick;
        for (victim, _killer, _paid) in crate::ingest_damage(&world, r, &name_of) {
            r.death(tick, &name_of(victim));
        }
        // The kit goes back on at the dead-to-alive edge, the way the arena
        // re-deals one. Without this a bout at a sixty-point budget is one
        // built exchange followed by four bare ones, which measures
        // something nobody asked about.
        for k in 0..2 {
            let alive = world.state.ships[seats[k] as usize].alive != 0;
            if alive && !alive_was[k] {
                deal_kit(&mut world, seats[k] as usize, budget, &mut prng[k]);
            }
            alive_was[k] = alive;
        }
        let k1 = world.state.ships[s1 as usize].kills;
        let k2 = world.state.ships[s2 as usize].kills;
        if k1 >= KILL_TARGET || k2 >= KILL_TARGET {
            break;
        }
    }
    let k1 = world.state.ships[s1 as usize].kills;
    let k2 = world.state.ships[s2 as usize].kills;
    // Back into the caller's order, whichever side each started on.
    if salt.is_multiple_of(2) {
        (k1, k2)
    } else {
        (k2, k1)
    }
}

/* ---- certified pilot calibration -------------------------------------
 *
 * The older `run` entry point above is kept for tools that still expect an
 * online Elo update after every bout. It is useful for exploration, but it
 * cannot certify a ladder. The API below locks the experiment before a run,
 * treats a mirrored pair as one observation, and keeps the final seeds out of
 * development and validation.
 */

pub const PILOT_CALIBRATION_SCHEMA: u32 = 4;
pub const PILOT_ATTESTATION_SCHEMA: u32 = 1;
pub const PILOT_CONTROLLER_VERSION: &str = "profile-brain-v2";
pub const PILOT_MAP: &str = "gantry";
pub const PILOT_ECONOMY: &str = "base-entitlement-personal-builds";
const PILOT_ZONE: &str = "duel";
const PILOT_ZONE_FILE: &str = "catalog/zones/duel/zone.toml";
const PILOT_MAP_FILE: &str = "catalog/zones/melee/gantry.vwmap";
const PILOT_ZONE_DECLARED_MAP: &str = "../melee/gantry.vwmap";
const PILOT_ZONE_BYTES: &[u8] = include_bytes!("../../catalog/zones/duel/zone.toml");
const PILOT_MAP_BYTES: &[u8] = include_bytes!("../../catalog/zones/melee/gantry.vwmap");
const PILOT_WORLD_SEED_LABEL: u64 = 0x0077_6f72_6c64;
const PILOT_BOOTSTRAP_SEED_LABEL: u64 = 0x626f_6f74_7374_7261;
/// How far past regulation a leg is flown before the harness gives up on it.
///
/// A live Ladder draws at the whistle, and this rig deliberately does not:
/// the question it is asking is which of two pilots wins when the fight is
/// played to a finish, and stopping at the whistle would censor exactly the
/// matchups that are hardest to call, which are the ones the ranking needs
/// most. So the leg keeps flying and the extra time is a measurement window,
/// not a rule the game has. Do not shorten this to match the mode.
///
/// It still needs a finite stop for a broken or permanently passive
/// controller, so ten regulation clocks is the prespecified censoring
/// boundary. Any censored leg blocks certification.
const PILOT_OVERTIME_SAFETY_MULTIPLIER: u32 = 10;

#[derive(Clone, Debug, PartialEq)]
pub enum PilotCalibrationError {
    Experiment(experiment::ExperimentError),
    InvalidRoster(String),
    InvalidRequest(String),
    InvalidDataset(String),
    InvalidFixture(String),
}

impl fmt::Display for PilotCalibrationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Experiment(error) => error.fmt(f),
            Self::InvalidRoster(message) => write!(f, "invalid pilot roster: {message}"),
            Self::InvalidRequest(message) => write!(f, "invalid calibration request: {message}"),
            Self::InvalidDataset(message) => write!(f, "invalid calibration dataset: {message}"),
            Self::InvalidFixture(message) => write!(f, "invalid Ladder fixture: {message}"),
        }
    }
}

impl Error for PilotCalibrationError {}

impl From<experiment::ExperimentError> for PilotCalibrationError {
    fn from(error: experiment::ExperimentError) -> Self {
        Self::Experiment(error)
    }
}

/// Pre-run choices for a pilot tournament.
///
/// `paired_scenarios_per_pool` is the number of scenario seeds used for every
/// matchup in each of the three pools. Every seed produces two mirrored
/// matches. A small request still runs, but its report is exploratory.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotCalibrationRequest {
    /// Unique, reviewed name for this attempt. It determines disjoint seed
    /// pools and prevents a failed holdout from being quietly replayed.
    pub attempt_id: String,
    pub paired_scenarios_per_pool: usize,
    pub alpha: f64,
    pub power: f64,
    /// Practical margin every ordered pair must clear above chance.
    pub minimum_superiority_margin: f64,
    /// Distance between that null margin and the alternative used for power.
    pub superiority_design_increment: f64,
    pub paired_variance: f64,
    pub side_equivalence_half_width: f64,
    pub side_paired_variance: f64,
    pub bootstrap_replicates: usize,
}

impl Default for PilotCalibrationRequest {
    fn default() -> Self {
        Self {
            attempt_id: "exploratory".into(),
            // This is intentionally a quick exploratory run. The power plan
            // in the report says how many pairs a certifying run needs.
            paired_scenarios_per_pool: 32,
            alpha: 0.05,
            power: 0.90,
            minimum_superiority_margin: 0.05,
            superiority_design_increment: 0.05,
            paired_variance: 0.25,
            side_equivalence_half_width: 0.05,
            side_paired_variance: 1.0,
            bootstrap_replicates: 5_000,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotCalibrationPlan {
    pub request: PilotCalibrationRequest,
    pub manifest: CalibrationManifest,
    pub fixture: PilotFixtureManifest,
    pub power: PowerPlan,
    pub side_power: EquivalencePowerPlan,
    pub bootstrap: BootstrapConfig,
    pub matchups: usize,
    pub requested_pairs_per_matchup_per_pool: usize,
    pub exploratory: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FixturePilotKit {
    pub pilot_id: u32,
    pub callsign: String,
    /// The personality this kit was derived from. It was the name of a
    /// separate build plan; a kit comes off the behavior profile now, so the
    /// strategy is what a reader of a fixture needs to see beside the slots.
    pub strategy: String,
    pub kit: Vec<u8>,
    pub spent: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct FixtureStartPair {
    pub indices: [u32; 2],
    /// Q8 world positions returned by the simulation's spawn policy.
    pub positions: [[i32; 2]; 2],
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PilotFixtureManifest {
    pub zone: String,
    pub zone_file: String,
    pub zone_fingerprint: String,
    pub map: String,
    pub map_file: String,
    pub map_fingerprint: String,
    pub fixture_fingerprint: String,
    pub mode: String,
    pub first_to: u16,
    pub regulation_ticks: u32,
    pub overtime_safety_ticks: u32,
    pub start_policy: String,
    pub starts_per_team: [usize; 2],
    pub start_pairs: Vec<FixtureStartPair>,
    pub heading_policy: String,
    pub account_entitlement_policy: String,
    pub account_entitlement_ceiling: Vec<u8>,
    pub effective_zone_entitlement_ceiling: Vec<u8>,
    pub pilot_kits: Vec<FixturePilotKit>,
    pub limitations: Vec<String>,
}

impl PilotFixtureManifest {
    fn validate(&self) -> Result<(), PilotCalibrationError> {
        for (field, value) in [
            ("zone", self.zone.as_str()),
            ("zone file", self.zone_file.as_str()),
            ("zone fingerprint", self.zone_fingerprint.as_str()),
            ("map", self.map.as_str()),
            ("map file", self.map_file.as_str()),
            ("map fingerprint", self.map_fingerprint.as_str()),
            ("fixture fingerprint", self.fixture_fingerprint.as_str()),
            ("mode", self.mode.as_str()),
            ("start policy", self.start_policy.as_str()),
            ("heading policy", self.heading_policy.as_str()),
            (
                "account entitlement policy",
                self.account_entitlement_policy.as_str(),
            ),
        ] {
            if value.trim().is_empty() {
                return Err(PilotCalibrationError::InvalidFixture(format!(
                    "{field} is empty"
                )));
            }
        }
        if self.first_to != 1 {
            return Err(PilotCalibrationError::InvalidFixture(
                "the fixture is not single life".into(),
            ));
        }
        if self.regulation_ticks == 0 || self.overtime_safety_ticks == 0 {
            return Err(PilotCalibrationError::InvalidFixture(
                "the fixture clock is empty".into(),
            ));
        }
        if self.account_entitlement_ceiling.len() != sim::SLOT_COUNT
            || self.effective_zone_entitlement_ceiling.len() != sim::SLOT_COUNT
        {
            return Err(PilotCalibrationError::InvalidFixture(
                "an entitlement ceiling has the wrong width".into(),
            ));
        }
        let pair_count = self.starts_per_team[0]
            .checked_mul(self.starts_per_team[1])
            .ok_or_else(|| {
                PilotCalibrationError::InvalidFixture("the start-pair count overflows".into())
            })?;
        if pair_count == 0 || self.start_pairs.len() != pair_count {
            return Err(PilotCalibrationError::InvalidFixture(
                "the fixture does not contain every valid start pair".into(),
            ));
        }
        let mut starts = HashSet::new();
        let mut indices = HashSet::new();
        for pair in &self.start_pairs {
            if pair.indices[0] as usize >= self.starts_per_team[0]
                || pair.indices[1] as usize >= self.starts_per_team[1]
                || !indices.insert(pair.indices)
                || !starts.insert(*pair)
            {
                return Err(PilotCalibrationError::InvalidFixture(
                    "the fixture contains an invalid start pair".into(),
                ));
            }
        }
        if self.pilot_kits.is_empty() {
            return Err(PilotCalibrationError::InvalidFixture(
                "the fixture has no pilot kits".into(),
            ));
        }
        let mut pilots = HashSet::new();
        for pilot in &self.pilot_kits {
            if !pilots.insert(pilot.pilot_id)
                || pilot.callsign.trim().is_empty()
                || pilot.strategy.trim().is_empty()
                || pilot.kit.len() != sim::SLOT_COUNT
                || pilot.spent != pilot.kit.iter().map(|level| u32::from(*level)).sum::<u32>()
                || pilot.spent > sim::KIT_BUDGET
            {
                return Err(PilotCalibrationError::InvalidFixture(format!(
                    "pilot kit {} is malformed",
                    pilot.pilot_id
                )));
            }
            if pilot
                .kit
                .iter()
                .zip(&self.effective_zone_entitlement_ceiling)
                .any(|(level, ceiling)| level > ceiling)
            {
                return Err(PilotCalibrationError::InvalidFixture(format!(
                    "pilot kit {} exceeds the entitlement ceiling",
                    pilot.pilot_id
                )));
            }
        }
        if self.limitations.is_empty()
            || self
                .limitations
                .iter()
                .any(|limitation| limitation.trim().is_empty())
        {
            return Err(PilotCalibrationError::InvalidFixture(
                "the fixture limitations are empty".into(),
            ));
        }
        Ok(())
    }
}

struct PilotFixtureRuntime {
    definition: crate::catalog::ZoneDef,
    map: Vec<u8>,
    route: nav::Nav,
    effective_entitlement_ceiling: [u8; sim::SLOT_COUNT],
    manifest: PilotFixtureManifest,
}

fn fingerprint(parts: &[&[u8]]) -> String {
    let mut content = Vec::new();
    for part in parts {
        content.extend_from_slice(&((*part).len() as u64).to_le_bytes());
        content.extend_from_slice(part);
    }
    format!("sha256:{}", crate::catalog::sha256_hex(&content))
}

fn profile_fingerprint(spec: &PilotSpec) -> ContentFingerprint {
    let content = format!("{spec:?}");
    ContentFingerprint {
        name: format!("{}:{}", spec.id.0, spec.callsign),
        digest: fingerprint(&[content.as_bytes()]),
    }
}

fn load_pilot_fixture(roster: &[PilotSpec]) -> Result<PilotFixtureRuntime, PilotCalibrationError> {
    let reference_pilot = roster.first().ok_or_else(|| {
        PilotCalibrationError::InvalidRoster("the fixture needs at least one pilot".into())
    })?;
    let raw = PILOT_ZONE_BYTES.to_vec();
    let text = std::str::from_utf8(&raw).map_err(|error| {
        PilotCalibrationError::InvalidFixture(format!("{PILOT_ZONE_FILE}: {error}"))
    })?;
    let mut definition: crate::catalog::ZoneDef = toml::from_str(text).map_err(|error| {
        PilotCalibrationError::InvalidFixture(format!("{PILOT_ZONE_FILE}: {error}"))
    })?;
    definition.raw = text.to_string();
    if definition.mode != "duel" {
        return Err(PilotCalibrationError::InvalidFixture(format!(
            "{PILOT_ZONE_FILE} runs mode {:?}, not Ladder",
            definition.mode
        )));
    }
    let first_to = definition
        .arena
        .duel_first_to
        .unwrap_or(crate::modes::DEFAULT_DUEL_FIRST_TO)
        .max(1);
    if first_to != 1 {
        return Err(PilotCalibrationError::InvalidFixture(format!(
            "the shipped Ladder is first to {first_to}, not single life"
        )));
    }
    // Calibration flies one fixed map, and that map has to be ground the
    // live Ladder actually serves: a rating measured somewhere nobody plays
    // describes nothing. The zone rotates now, so the fixture asks to be in
    // the rotation rather than to be the whole of it.
    if !definition
        .maps
        .iter()
        .any(|name| name == PILOT_ZONE_DECLARED_MAP)
    {
        return Err(PilotCalibrationError::InvalidFixture(format!(
            "the shipped Ladder rotates {:?}, which does not include the calibration map {PILOT_ZONE_DECLARED_MAP:?}",
            definition.maps
        )));
    }
    let map = PILOT_MAP_BYTES.to_vec();

    let mut probe = sim::World::from_packed(0x5eed, &map).map_err(|error| {
        PilotCalibrationError::InvalidFixture(format!("Drydock could not be unpacked: {error}"))
    })?;
    let warnings = crate::Room::apply_config(&mut probe, &definition.arena);
    if !warnings.is_empty() {
        return Err(PilotCalibrationError::InvalidFixture(format!(
            "the Ladder tuning only partially applied: {}",
            warnings.join("; ")
        )));
    }
    if roster
        .iter()
        .any(|pilot| pilot.hull >= probe.cfg.class_count)
    {
        return Err(PilotCalibrationError::InvalidRoster(
            "a pilot names a hull outside the Ladder fixture".into(),
        ));
    }
    let (_, starts_per_team) = probe.map.spawns();
    if starts_per_team.contains(&0) {
        return Err(PilotCalibrationError::InvalidFixture(
            "Drydock needs a start for each Ladder side".into(),
        ));
    }
    let mut start_pairs = Vec::with_capacity(starts_per_team[0] * starts_per_team[1]);
    for first_index in 0..starts_per_team[0] {
        for second_index in 0..starts_per_team[1] {
            let first_position = probe.spawn_point(0, reference_pilot.hull, first_index as u32);
            let second_position = probe.spawn_point(1, reference_pilot.hull, second_index as u32);
            start_pairs.push(FixtureStartPair {
                indices: [first_index as u32, second_index as u32],
                positions: [
                    [first_position.0, first_position.1],
                    [second_position.0, second_position.1],
                ],
            });
        }
    }
    for pair in &start_pairs {
        for pilot in roster {
            let positions = [
                probe.spawn_point(0, pilot.hull, pair.indices[0]),
                probe.spawn_point(1, pilot.hull, pair.indices[1]),
            ];
            if positions
                != [
                    (pair.positions[0][0], pair.positions[0][1]),
                    (pair.positions[1][0], pair.positions[1][1]),
                ]
            {
                return Err(PilotCalibrationError::InvalidFixture(format!(
                    "Drydock start pair {:?} depends on pilot {}'s hull",
                    pair.indices, pilot.callsign
                )));
            }
        }
    }

    // Live bot ownership and the human account both constrain a kit. A saved
    // tournament has neither account, so the fixture prespecifies the base
    // account ceiling. It is the only ceiling every claimed account has.
    let account_ceiling = sim::World::base_entitlements();
    let mut effective_ceiling = probe.kit_ceilings();
    for (ceiling, owned) in effective_ceiling.iter_mut().zip(account_ceiling) {
        *ceiling = (*ceiling).min(owned);
    }
    let pilot_kits: Vec<FixturePilotKit> = roster
        .iter()
        .map(|pilot| {
            let kit = shopper::build(&shopper::wants(&pilot.behavior), &effective_ceiling);
            FixturePilotKit {
                pilot_id: pilot.id.0,
                callsign: pilot.callsign.clone(),
                strategy: format!("{:?}", pilot.behavior.strategy),
                spent: sim::World::kit_cost(&kit),
                kit: kit.to_vec(),
            }
        })
        .collect();
    let regulation_ticks = definition.arena.match_seconds.unwrap_or(180) as u32 * 100;
    let overtime_safety_ticks = regulation_ticks
        .checked_mul(PILOT_OVERTIME_SAFETY_MULTIPLIER)
        .ok_or_else(|| {
            PilotCalibrationError::InvalidFixture("the Ladder clock overflows ticks".into())
        })?;
    let zone_fingerprint = fingerprint(&[&raw]);
    let map_fingerprint = fingerprint(&[&map]);
    let account_bytes = account_ceiling.to_vec();
    let effective_bytes = effective_ceiling.to_vec();
    let start_policy = format!(
        "cycle through all {} valid team-zero by team-one Drydock start pairs by scenario seed",
        start_pairs.len()
    );
    let heading_policy = "each side faces its selected opposing start; the mirror exchanges pilots between those fixed side headings".to_string();
    let kit_bytes = format!("{pilot_kits:?}");
    let start_bytes = format!("{start_pairs:?}");
    let fixture_fingerprint = fingerprint(&[
        &raw,
        &map,
        &account_bytes,
        &effective_bytes,
        start_policy.as_bytes(),
        start_bytes.as_bytes(),
        heading_policy.as_bytes(),
        kit_bytes.as_bytes(),
        include_bytes!("bots.rs"),
        include_bytes!("catalog.rs"),
        include_bytes!("config.rs"),
        include_bytes!("pilots.rs"),
        include_bytes!("room.rs"),
        include_bytes!("shopper.rs"),
        include_bytes!("sim.rs"),
        include_bytes!("modes.rs"),
        include_bytes!("../../sim/src/sim.c"),
    ]);
    let route = nav::Nav::build(&probe.map);
    let manifest = PilotFixtureManifest {
        zone: PILOT_ZONE.into(),
        zone_file: PILOT_ZONE_FILE.into(),
        zone_fingerprint,
        map: PILOT_MAP.into(),
        map_file: PILOT_MAP_FILE.into(),
        map_fingerprint,
        fixture_fingerprint,
        mode: definition.mode.clone(),
        first_to,
        regulation_ticks,
        overtime_safety_ticks,
        start_policy,
        starts_per_team,
        start_pairs,
        heading_policy,
        account_entitlement_policy: "base account ceiling for both pilots".into(),
        account_entitlement_ceiling: account_bytes,
        effective_zone_entitlement_ceiling: effective_bytes,
        pilot_kits,
        limitations: vec![
            "Persistent account purchases are not replayed. Both pilots use the base account entitlement ceiling recorded in this manifest.".into(),
            "A live Ladder draws at the whistle; this harness flies each leg to a death instead, so an undecided matchup is measured rather than censored. It censors a leg after ten additional regulation clocks, records it, and refuses certification if any leg is censored.".into(),
            "The experiment ranks bot-versus-bot performance. It does not estimate human win probability, retention, or fun.".into(),
        ],
    };
    manifest.validate()?;
    Ok(PilotFixtureRuntime {
        definition,
        map,
        route,
        effective_entitlement_ceiling: effective_ceiling,
        manifest,
    })
}

/// Whether a directory-delivered Ladder still describes the exact fixture a
/// report measured. A catalog can be newer than the arena binary, and map
/// publications can replace its rotation without changing that binary. A
/// certified order must fail closed in either case instead of silently being
/// attached to a different game.
pub(crate) fn runtime_pilot_fixture_matches(
    fixture: &PilotFixtureManifest,
    zone: &crate::fleet::WireZone,
) -> bool {
    if zone.name != fixture.zone
        || zone.mode != fixture.mode
        || fingerprint(&[zone.zone_toml.as_bytes()]) != fixture.zone_fingerprint
        || zone.maps_b64.is_empty()
    {
        return false;
    }
    let Ok(definition) = toml::from_str::<crate::catalog::ZoneDef>(&zone.zone_toml) else {
        return false;
    };
    if zone.max_ships != definition.max_ships.unwrap_or(64)
        || zone.max_players != definition.max_players() as u32
        || zone.fill_target != definition.fill_target() as u32
        || zone.bot_fill.to_bits() != definition.bot_fill().to_bits()
        || zone.max_rooms != definition.max_rooms() as u32
        || zone.admission != definition.admission
    {
        return false;
    }
    // The calibration map has to be served, and served unaltered. Which slot
    // of the rotation it arrives in is the zone's business.
    zone.maps_b64.iter().any(|served| {
        crate::fleet::unb64(served)
            .is_some_and(|map| fingerprint(&[&map]) == fixture.map_fingerprint)
    })
}

fn hypothesis_id(a: &PilotSpec, b: &PilotSpec) -> String {
    let (low, high) = if a.id.0 <= b.id.0 {
        (a.id.0, b.id.0)
    } else {
        (b.id.0, a.id.0)
    };
    format!("pilot-{low}-vs-{high}")
}

fn side_hypothesis_id(a: &PilotSpec, b: &PilotSpec) -> String {
    format!("{}-side-equivalence", hypothesis_id(a, b))
}

fn checked_pool_start(base: u64, offset: usize) -> Result<u64, PilotCalibrationError> {
    base.checked_add(offset as u64)
        .ok_or_else(|| PilotCalibrationError::InvalidRequest("seed ranges overflow u64".into()))
}

fn pilot_attempt_namespace(attempt_id: &str) -> u64 {
    let digest = crate::catalog::sha256_hex(attempt_id.as_bytes());
    u64::from_str_radix(&digest[..16], 16).expect("a SHA-256 prefix is hexadecimal")
        ^ pilots::LADDER_START_NAMESPACE
}

struct PilotInputFingerprints {
    controller: String,
    profiles: Vec<ContentFingerprint>,
    maps: Vec<ContentFingerprint>,
    economies: Vec<ContentFingerprint>,
}

fn pilot_input_fingerprints(
    roster: &[PilotSpec],
    fixture: &PilotFixtureRuntime,
) -> PilotInputFingerprints {
    let controller = fingerprint(&[
        include_bytes!("ai.rs"),
        include_bytes!("bots.rs"),
        include_bytes!("experiment.rs"),
        include_bytes!("main.rs"),
        include_bytes!("catalog.rs"),
        include_bytes!("config.rs"),
        include_bytes!("delivery.rs"),
        include_bytes!("fleet.rs"),
        include_bytes!("metrics.rs"),
        include_bytes!("nav.rs"),
        include_bytes!("pilots.rs"),
        include_bytes!("presence.rs"),
        include_bytes!("rating.rs"),
        include_bytes!("room.rs"),
        include_bytes!("arena.rs"),
        include_bytes!("session.rs"),
        include_bytes!("session/commands.rs"),
        include_bytes!("meta.rs"),
        include_bytes!("meta/settlement.rs"),
        include_bytes!("sim.rs"),
        include_bytes!("calibrate.rs"),
        include_bytes!("modes.rs"),
        include_bytes!("protocol.rs"),
        include_bytes!("token.rs"),
        include_bytes!("../build.rs"),
        include_bytes!("../Cargo.toml"),
        include_bytes!("../Cargo.lock"),
        include_bytes!("../../Dockerfile"),
    ]);
    let profiles = roster.iter().map(profile_fingerprint).collect();
    let maps = vec![ContentFingerprint {
        name: PILOT_MAP.into(),
        digest: fixture.manifest.map_fingerprint.clone(),
    }];
    // The zone file, ownership ceiling, derived taste, and simulation rules
    // decide what each persistent pilot carries into its one life.
    let account_ceiling = &fixture.manifest.account_entitlement_ceiling;
    let effective_ceiling = &fixture.manifest.effective_zone_entitlement_ceiling;
    let economies = vec![ContentFingerprint {
        name: PILOT_ECONOMY.into(),
        digest: fingerprint(&[
            fixture.definition.raw.as_bytes(),
            account_ceiling,
            effective_ceiling,
            include_bytes!("shopper.rs"),
            include_bytes!("bots.rs"),
            include_bytes!("catalog.rs"),
            include_bytes!("config.rs"),
            include_bytes!("rating.rs"),
            include_bytes!("room.rs"),
            include_bytes!("arena.rs"),
            include_bytes!("meta.rs"),
            include_bytes!("meta/settlement.rs"),
            include_bytes!("token.rs"),
            include_bytes!("../../sim/src/baseline.c"),
            include_bytes!("../../sim/src/sim.c"),
            include_bytes!("../../sim/src/pack.c"),
            include_bytes!("../../sim/src/check.c"),
            include_bytes!("../../sim/src/sintab.h"),
            include_bytes!("../../sim/include/sim/sim.h"),
            include_bytes!("../../sim/include/sim/baseline.h"),
            include_bytes!("../../sim/include/sim/pack.h"),
            include_bytes!("../build.rs"),
        ]),
    }];
    PilotInputFingerprints {
        controller,
        profiles,
        maps,
        economies,
    }
}

/// Freeze the experiment, content hashes, seed pools, and sample size before
/// simulation starts.
pub fn plan_pilot_calibration(
    roster: &[PilotSpec],
    request: &PilotCalibrationRequest,
) -> Result<PilotCalibrationPlan, PilotCalibrationError> {
    if roster.len() < 2 {
        return Err(PilotCalibrationError::InvalidRoster(
            "at least two pilots are required".into(),
        ));
    }
    if request.attempt_id.is_empty()
        || request.attempt_id.len() > 64
        || !request
            .attempt_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
    {
        return Err(PilotCalibrationError::InvalidRequest(
            "attempt_id must be 1 to 64 ASCII letters, digits, dashes, underscores, or dots".into(),
        ));
    }
    let mut ids = HashSet::new();
    let mut names = HashSet::new();
    for spec in roster {
        if spec.callsign.trim().is_empty() {
            return Err(PilotCalibrationError::InvalidRoster(
                "a callsign is empty".into(),
            ));
        }
        if !ids.insert(spec.id.0) {
            return Err(PilotCalibrationError::InvalidRoster(format!(
                "pilot id {} appears twice",
                spec.id.0
            )));
        }
        if !names.insert(spec.callsign.as_str()) {
            return Err(PilotCalibrationError::InvalidRoster(format!(
                "callsign {:?} appears twice",
                spec.callsign
            )));
        }
    }
    if request.paired_scenarios_per_pool < 2 {
        return Err(PilotCalibrationError::InvalidRequest(
            "paired_scenarios_per_pool must be at least two".into(),
        ));
    }
    if request.power < 0.90 {
        return Err(PilotCalibrationError::InvalidRequest(
            "power must be at least 0.90".into(),
        ));
    }
    if !request.paired_variance.is_finite()
        || request.paired_variance <= 0.0
        || request.paired_variance > 0.25
    {
        return Err(PilotCalibrationError::InvalidRequest(
            "paired_variance must be above zero and at most 0.25".into(),
        ));
    }
    if !request.minimum_superiority_margin.is_finite()
        || request.minimum_superiority_margin <= 0.0
        || request.minimum_superiority_margin >= 0.5
    {
        return Err(PilotCalibrationError::InvalidRequest(
            "minimum_superiority_margin must be between zero and one half".into(),
        ));
    }
    if !request.superiority_design_increment.is_finite()
        || request.superiority_design_increment <= 0.0
        || request.minimum_superiority_margin + request.superiority_design_increment >= 0.5
    {
        return Err(PilotCalibrationError::InvalidRequest(
            "the superiority design alternative must be above the margin and below certainty"
                .into(),
        ));
    }
    if !request.side_equivalence_half_width.is_finite()
        || request.side_equivalence_half_width <= 0.0
        || request.side_equivalence_half_width >= 1.0
    {
        return Err(PilotCalibrationError::InvalidRequest(
            "side_equivalence_half_width must be between zero and one".into(),
        ));
    }
    if !request.side_paired_variance.is_finite()
        || request.side_paired_variance <= 0.0
        || request.side_paired_variance > 1.0
    {
        return Err(PilotCalibrationError::InvalidRequest(
            "side_paired_variance must be above zero and at most one".into(),
        ));
    }
    if request.bootstrap_replicates < 2 {
        return Err(PilotCalibrationError::InvalidRequest(
            "bootstrap_replicates must be at least two".into(),
        ));
    }

    let matchups = roster.len() * (roster.len() - 1) / 2;
    let family_hypotheses = matchups * 2;
    // Certification needs every superiority and side-equivalence claim to
    // replicate in validation and in the final pool. Allocate total beta
    // across that complete gate family with the union bound. This gives the
    // roster-level power target without assuming that shared scenario seeds
    // make the tests independent.
    let confirmatory_gates = matchups * 4;
    let superiority_gate_power = 1.0 - (1.0 - request.power) / confirmatory_gates as f64;
    let power = experiment::plan_paired_mean(PowerPlanRequest {
        alpha: request.alpha,
        power: superiority_gate_power,
        minimum_detectable_effect: request.superiority_design_increment,
        observed_paired_variance: request.paired_variance,
        sidedness: Sidedness::TwoSided,
        family_hypotheses,
    })?;
    let side_power = experiment::plan_paired_equivalence(EquivalencePowerPlanRequest {
        alpha: request.alpha,
        joint_power: request.power,
        half_width: request.side_equivalence_half_width,
        observed_paired_variance: request.side_paired_variance,
        family_hypotheses,
        independent_confirmatory_gates: confirmatory_gates,
    })?;
    let required_pairs = power.required_pairs.max(side_power.required_pairs);
    if request.attempt_id != "exploratory" && request.paired_scenarios_per_pool != required_pairs {
        return Err(PilotCalibrationError::InvalidRequest(format!(
            "a confirmatory attempt must run exactly {required_pairs} paired scenarios per matchup per pool"
        )));
    }

    let count = request.paired_scenarios_per_pool;
    let seed_namespace = pilot_attempt_namespace(&request.attempt_id);
    let first_seed = 1u64;
    let twice = count.checked_mul(2).ok_or_else(|| {
        PilotCalibrationError::InvalidRequest("seed ranges overflow usize".into())
    })?;
    let thrice = count.checked_mul(3).ok_or_else(|| {
        PilotCalibrationError::InvalidRequest("seed ranges overflow usize".into())
    })?;
    let validation_start = checked_pool_start(first_seed, count)?;
    let final_start = checked_pool_start(first_seed, twice)?;
    checked_pool_start(first_seed, thrice)?;
    let mut rng_scenarios = HashSet::with_capacity(thrice);
    for offset in 0..thrice {
        let seed = first_seed + offset as u64;
        if !rng_scenarios.insert(mixed_seed(seed_namespace, seed, PILOT_WORLD_SEED_LABEL)) {
            return Err(PilotCalibrationError::InvalidRequest(format!(
                "scenario seed {seed} collides in the simulation RNG"
            )));
        }
    }

    let fixture = load_pilot_fixture(roster)?;
    fixture.manifest.validate()?;
    let inputs = pilot_input_fingerprints(roster, &fixture);

    let mut hypotheses = Vec::with_capacity(family_hypotheses);
    let mut samples = Vec::with_capacity(family_hypotheses);
    for i in 0..roster.len() {
        for j in (i + 1)..roster.len() {
            let id = hypothesis_id(&roster[i], &roster[j]);
            hypotheses.push(HypothesisSpec {
                id: id.clone(),
                description: format!(
                    "The prespecified stronger pilot in {} versus {} scores above chance plus the declared minimum effect",
                    roster[i].callsign, roster[j].callsign
                ),
                kind: HypothesisKind::Superiority {
                    minimum_effect: request.minimum_superiority_margin,
                },
            });
            samples.push(SamplePlan {
                hypothesis_id: id,
                paired_scenarios: power.required_pairs,
            });
            let side_id = side_hypothesis_id(&roster[i], &roster[j]);
            hypotheses.push(HypothesisSpec {
                id: side_id.clone(),
                description: format!(
                    "The mirrored side effect for {} versus {} stays inside the declared equivalence bound",
                    roster[i].callsign, roster[j].callsign
                ),
                kind: HypothesisKind::Equivalence {
                    lower: -request.side_equivalence_half_width,
                    upper: request.side_equivalence_half_width,
                },
            });
            samples.push(SamplePlan {
                hypothesis_id: side_id,
                paired_scenarios: side_power.required_pairs,
            });
        }
    }

    let manifest = CalibrationManifest {
        schema_version: PILOT_CALIBRATION_SCHEMA,
        controller_version: PILOT_CONTROLLER_VERSION.into(),
        profile_versions: vec![format!("pilot-spec-v{}", pilots::PILOT_SPEC_VERSION)],
        maps: vec![PILOT_MAP.into()],
        economies: vec![PILOT_ECONOMY.into()],
        controller_fingerprint: inputs.controller,
        profile_fingerprints: inputs.profiles,
        map_fingerprints: inputs.maps,
        economy_fingerprints: inputs.economies,
        seed_pools: vec![
            SeedPool {
                name: "development".into(),
                role: SeedPoolRole::Development,
                namespace: seed_namespace,
                first_seed,
                count,
            },
            SeedPool {
                name: "validation".into(),
                role: SeedPoolRole::Validation,
                namespace: seed_namespace,
                first_seed: validation_start,
                count,
            },
            SeedPool {
                name: "final-holdout".into(),
                role: SeedPoolRole::Holdout,
                namespace: seed_namespace,
                first_seed: final_start,
                count,
            },
        ],
        hypotheses,
        alpha: request.alpha,
        power: request.power,
        samples,
    };
    manifest.validate()?;
    Ok(PilotCalibrationPlan {
        request: request.clone(),
        manifest,
        fixture: fixture.manifest,
        power,
        side_power,
        bootstrap: BootstrapConfig {
            confidence: 1.0 - request.alpha,
            replicates: request.bootstrap_replicates,
            rng_seed: seed_namespace ^ PILOT_BOOTSTRAP_SEED_LABEL,
        },
        matchups,
        requested_pairs_per_matchup_per_pool: count,
        exploratory: request.attempt_id == "exploratory"
            || count < power.required_pairs.max(side_power.required_pairs),
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PilotMirrorAssignment {
    pub pilot_id: u32,
    pub side: u8,
    pub start: u32,
    pub heading: u16,
}

/// The two seat maps for a true mirror. A pilot changes side, start, and
/// heading in the second leg.
pub fn pilot_mirror_assignments(
    a: &PilotSpec,
    b: &PilotSpec,
    start_indices: [u32; 2],
    start_positions: [[i32; 2]; 2],
) -> [[PilotMirrorAssignment; 2]; 2] {
    let first = (start_positions[0][0], start_positions[0][1]);
    let second = (start_positions[1][0], start_positions[1][1]);
    let headings = [
        crate::room::heading_toward(first, second),
        crate::room::heading_toward(second, first),
    ];
    [
        [
            PilotMirrorAssignment {
                pilot_id: a.id.0,
                side: 0,
                start: start_indices[0],
                heading: headings[0],
            },
            PilotMirrorAssignment {
                pilot_id: b.id.0,
                side: 1,
                start: start_indices[1],
                heading: headings[1],
            },
        ],
        [
            PilotMirrorAssignment {
                pilot_id: b.id.0,
                side: 0,
                start: start_indices[0],
                heading: headings[0],
            },
            PilotMirrorAssignment {
                pilot_id: a.id.0,
                side: 1,
                start: start_indices[1],
                heading: headings[1],
            },
        ],
    ]
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotLegResult {
    pub a_side: u8,
    pub a_start: u32,
    pub a_heading: u16,
    pub a_kills: i16,
    pub b_kills: i16,
    pub ticks: u32,
    pub a_score: f64,
    pub victim_id: Option<u32>,
    pub killer_id: Option<u32>,
    pub mutual_death: bool,
    pub reached_overtime: bool,
    pub censored: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotMatchupObservation {
    pub pool: String,
    pub seed: u64,
    pub a_id: u32,
    pub a: String,
    pub b_id: u32,
    pub b: String,
    pub fixture_fingerprint: String,
    pub start_indices: [u32; 2],
    pub start_positions: [[i32; 2]; 2],
    pub first: PilotLegResult,
    pub mirrored: PilotLegResult,
}

impl PilotMatchupObservation {
    pub fn paired(&self) -> Result<PairedScenarioObservation, PilotCalibrationError> {
        Ok(PairedScenarioObservation::new(
            self.seed,
            PILOT_MAP,
            PILOT_ECONOMY,
            self.first.a_score,
            self.mirrored.a_score,
            self.first.a_score * 2.0 - 1.0,
            self.mirrored.a_score * 2.0 - 1.0,
        )?)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotCalibrationPool {
    pub name: String,
    pub role: SeedPoolRole,
    pub observations: Vec<PilotMatchupObservation>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotCalibrationDataset {
    pub pools: Vec<PilotCalibrationPool>,
}

fn pilot_dataset_fingerprint(
    dataset: &PilotCalibrationDataset,
) -> Result<String, PilotCalibrationError> {
    let encoded = serde_json::to_vec(dataset).map_err(|error| {
        PilotCalibrationError::InvalidDataset(format!(
            "raw observations could not be fingerprinted: {error}"
        ))
    })?;
    Ok(fingerprint(&[&encoded]))
}

fn mixed_seed(namespace: u64, seed: u64, label: u64) -> u32 {
    let mut value = namespace ^ seed.rotate_left(23) ^ label.wrapping_mul(0x9e37_79b9_7f4a_7c15);
    value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    value ^= value >> 31;
    (value as u32) ^ (value >> 32) as u32
}

fn scenario_start_pair(
    fixture: &PilotFixtureRuntime,
    namespace: u64,
    seed: u64,
) -> Result<FixtureStartPair, PilotCalibrationError> {
    let indices = pilots::ladder_start_pair(namespace, seed, fixture.manifest.starts_per_team)
        .ok_or_else(|| {
            PilotCalibrationError::InvalidFixture("Drydock has no valid start pair".into())
        })?;
    fixture
        .manifest
        .start_pairs
        .iter()
        .find(|pair| pair.indices == indices)
        .copied()
        .ok_or_else(|| {
            PilotCalibrationError::InvalidFixture(format!(
                "Drydock fixture omits selected start pair {indices:?}"
            ))
        })
}

fn first_death_score(victim: u8, a_ship: u8, b_ship: u8) -> Option<f64> {
    if victim == a_ship {
        Some(0.0)
    } else if victim == b_ship {
        Some(1.0)
    } else {
        None
    }
}

fn death_tick_score(deaths: &[(u8, u8)], a_ship: u8, b_ship: u8) -> Option<f64> {
    let a_died = deaths.iter().any(|(victim, _)| *victim == a_ship);
    let b_died = deaths.iter().any(|(victim, _)| *victim == b_ship);
    match (a_died, b_died) {
        (true, true) => Some(0.5),
        (true, false) => Some(0.0),
        (false, true) => Some(1.0),
        (false, false) => None,
    }
}

/// Open the measured life in the same order as a live Ladder room: deal the
/// selected kits, restart to refill their upgraded bars and ammunition, then
/// apply the seeded Ladder start pair and headings over the core's ordinary
/// team lineup.
fn restart_pilot_leg(world: &mut sim::World, ships: [u8; 2], positions: [(i32, i32); 2]) {
    world.restart();
    for index in 0..2 {
        let row = &mut world.state.ships[ships[index] as usize];
        row.x = positions[index].0;
        row.y = positions[index].1;
        row.spawn_x = positions[index].0;
        row.spawn_y = positions[index].1;
        row.vx = 0;
        row.vy = 0;
    }
    crate::room::face_public_teams(world);
}

#[allow(clippy::too_many_arguments)]
fn pilot_leg(
    fixture: &PilotFixtureRuntime,
    start_indices: [u32; 2],
    start_positions: [[i32; 2]; 2],
    namespace: u64,
    seed: u64,
    a: &PilotSpec,
    b: &PilotSpec,
    mirrored: bool,
) -> PilotLegResult {
    let world_seed = mixed_seed(namespace, seed, PILOT_WORLD_SEED_LABEL);
    let mut world = sim::World::from_packed(world_seed, &fixture.map).expect("the shipped map");
    let warnings = crate::Room::apply_config(&mut world, &fixture.definition.arena);
    debug_assert!(warnings.is_empty(), "validated Ladder tuning changed");
    world.cfg.max_ships = fixture.definition.max_ships.unwrap_or(2).min(2);

    let assignments = pilot_mirror_assignments(a, b, start_indices, start_positions);
    let leg = assignments[usize::from(mirrored)];
    let (seat_specs, a_seat) = if mirrored { ([b, a], 1) } else { ([a, b], 0) };
    let actual_positions = [
        world.spawn_point(0, seat_specs[0].hull, start_indices[0]),
        world.spawn_point(1, seat_specs[1].hull, start_indices[1]),
    ];
    assert_eq!(
        actual_positions,
        [
            (start_positions[0][0], start_positions[0][1]),
            (start_positions[1][0], start_positions[1][1]),
        ],
        "the validated spawn policy changed"
    );
    let ships = [
        world.spawn_at(
            seat_specs[0].hull,
            0,
            actual_positions[0].0,
            actual_positions[0].1,
            leg[0].heading,
        ) as u8,
        world.spawn_at(
            seat_specs[1].hull,
            1,
            actual_positions[1].0,
            actual_positions[1].1,
            leg[1].heading,
        ) as u8,
    ];

    let mut bots = [
        ai::Bot::new(ships[0], seat_specs[0].brain()),
        ai::Bot::new(ships[1], seat_specs[1].brain()),
    ];
    for index in 0..2 {
        bots[index].reseed(mixed_seed(namespace, seed, seat_specs[index].id.0 as u64));
    }

    // A live persistent pilot asks for the build named by its spec. Account
    // ownership is the prespecified base ceiling recorded in the fixture.
    for index in 0..2 {
        let kit = shopper::build(
            &shopper::wants(&seat_specs[index].behavior),
            &fixture.effective_entitlement_ceiling,
        );
        assert!(
            world.set_kit(ships[index] as usize, &kit),
            "the fixture kit was validated before collection"
        );
    }
    restart_pilot_leg(&mut world, ships, actual_positions);
    debug_assert_eq!(
        [
            world.state.ships[ships[0] as usize].heading,
            world.state.ships[ships[1] as usize].heading,
        ],
        [leg[0].heading, leg[1].heading],
        "the recorded facing policy changed"
    );
    let mut ticks = 0;
    let regulation_ticks = fixture.manifest.regulation_ticks;
    let total_ticks = regulation_ticks.saturating_add(fixture.manifest.overtime_safety_ticks);
    let mut deaths = Vec::new();
    for _ in 0..total_ticks {
        let look0 = bots[0].looks_due().then(|| ai::scan(&world, ships[0]));
        let look1 = bots[1].looks_due().then(|| ai::scan(&world, ships[1]));
        let own0 = ai::own(&world, ships[0]);
        let own1 = ai::own(&world, ships[1]);
        let inputs = [
            sim::sim_input {
                ship: ships[0],
                buttons: bots[0].think(&own0, &fixture.route, look0),
            },
            sim::sim_input {
                ship: ships[1],
                buttons: bots[1].think(&own1, &fixture.route, look1),
            },
        ];
        world.step(&inputs);
        ticks += 1;
        for event in world.events.e.iter().take(world.events.count as usize) {
            if event.etype == sim::EV_DEATH
                && first_death_score(event.a, ships[a_seat], ships[1 - a_seat]).is_some()
            {
                deaths.push((event.a, event.b));
            }
        }
        if !deaths.is_empty() {
            break;
        }
    }

    let kills = [
        world.state.ships[ships[0] as usize].kills,
        world.state.ships[ships[1] as usize].kills,
    ];
    let b_seat = 1 - a_seat;
    let a_assignment = leg[a_seat];
    let a_score = death_tick_score(&deaths, ships[a_seat], ships[b_seat]).unwrap_or(0.5);
    let mutual_death = deaths.iter().any(|(victim, _)| *victim == ships[a_seat])
        && deaths.iter().any(|(victim, _)| *victim == ships[b_seat]);
    let pilot_id_of = |ship: u8| {
        if ship == ships[a_seat] {
            Some(a.id.0)
        } else if ship == ships[b_seat] {
            Some(b.id.0)
        } else {
            None
        }
    };
    PilotLegResult {
        a_side: a_assignment.side,
        a_start: a_assignment.start,
        a_heading: a_assignment.heading,
        a_kills: kills[a_seat],
        b_kills: kills[b_seat],
        ticks,
        a_score,
        victim_id: (!mutual_death)
            .then(|| deaths.first().and_then(|(victim, _)| pilot_id_of(*victim)))
            .flatten(),
        killer_id: (!mutual_death)
            .then(|| deaths.first().and_then(|(_, killer)| pilot_id_of(*killer)))
            .flatten(),
        mutual_death,
        reached_overtime: ticks > regulation_ticks,
        censored: deaths.is_empty(),
    }
}

/// Run both legs of one scenario. Pilot `a` owns both scores in the result,
/// so callers do not have to undo the side swap themselves.
#[allow(clippy::too_many_arguments)]
fn run_pilot_mirrored_pair(
    fixture: &PilotFixtureRuntime,
    start_indices: [u32; 2],
    start_positions: [[i32; 2]; 2],
    pool: &str,
    namespace: u64,
    seed: u64,
    a: &PilotSpec,
    b: &PilotSpec,
) -> PilotMatchupObservation {
    PilotMatchupObservation {
        pool: pool.into(),
        seed,
        a_id: a.id.0,
        a: a.callsign.clone(),
        b_id: b.id.0,
        b: b.callsign.clone(),
        fixture_fingerprint: fixture.manifest.fixture_fingerprint.clone(),
        start_indices,
        start_positions,
        first: pilot_leg(
            fixture,
            start_indices,
            start_positions,
            namespace,
            seed,
            a,
            b,
            false,
        ),
        mirrored: pilot_leg(
            fixture,
            start_indices,
            start_positions,
            namespace,
            seed,
            a,
            b,
            true,
        ),
    }
}

/// Execute the frozen development, validation, and final holdout pools.
pub fn collect_pilot_calibration(
    roster: &[PilotSpec],
    plan: &PilotCalibrationPlan,
    verbose: bool,
) -> Result<PilotCalibrationDataset, PilotCalibrationError> {
    plan.manifest.validate()?;
    let fixture = load_pilot_fixture(roster)?;
    if fixture.manifest != plan.fixture {
        return Err(PilotCalibrationError::InvalidFixture(
            "the shipped Ladder changed after the experiment was planned".into(),
        ));
    }
    let mut pools = Vec::with_capacity(plan.manifest.seed_pools.len());
    for pool in &plan.manifest.seed_pools {
        let mut observations = Vec::with_capacity(pool.count * plan.matchups);
        for offset in 0..pool.count {
            let seed = pool.first_seed + offset as u64;
            let starts = scenario_start_pair(&fixture, pool.namespace, seed)?;
            for i in 0..roster.len() {
                for j in (i + 1)..roster.len() {
                    observations.push(run_pilot_mirrored_pair(
                        &fixture,
                        starts.indices,
                        starts.positions,
                        &pool.name,
                        pool.namespace,
                        seed,
                        &roster[i],
                        &roster[j],
                    ));
                }
            }
            if verbose {
                println!("{} scenario {}/{}", pool.name, offset + 1, pool.count);
            }
        }
        pools.push(PilotCalibrationPool {
            name: pool.name.clone(),
            role: pool.role,
            observations,
        });
    }
    Ok(PilotCalibrationDataset { pools })
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotPhaseFit {
    pub pool: String,
    pub role: SeedPoolRole,
    pub scenario_seeds: usize,
    pub mirrored_pairs: usize,
    pub fit: BradleyTerryFit,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotPairwiseDecision {
    pub hypothesis_id: String,
    pub stronger: String,
    pub weaker: String,
    pub validation_score: f64,
    pub final_score: f64,
    pub minimum_superiority_margin: f64,
    pub superiority_threshold: f64,
    pub simultaneous_low: f64,
    pub simultaneous_high: f64,
    pub raw_p: f64,
    pub adjusted_p: f64,
    pub simultaneous_clears_threshold: bool,
    pub significant: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotSideEquivalence {
    pub hypothesis_id: String,
    pub a: String,
    pub b: String,
    pub validation: TostResult,
    pub final_holdout: TostResult,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PilotCalibrationStatus {
    Exploratory,
    Uncertified,
    Certified,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CertifiedPilotEntry {
    pub pilot_id: u32,
    pub callsign: String,
    /// Bounded account seed derived from the final pool's descriptive
    /// anchored fit. Inferential ordering comes from the seed-cluster
    /// simultaneous pair intervals.
    pub elo: f64,
}

/// A fitted population can separate completely and send an otherwise finite
/// regularized point estimate far beyond a useful account prior. A four
/// hundred point lead already makes a pilot roughly a ten-to-one favorite,
/// while the full unbounded fit remains in the audit report.
const PILOT_ACCOUNT_SEED_RADIUS: f64 = 400.0;

fn pilot_account_seed(elo: f64) -> f64 {
    elo.clamp(
        ai::ANCHOR_RATING - PILOT_ACCOUNT_SEED_RADIUS,
        ai::ANCHOR_RATING + PILOT_ACCOUNT_SEED_RADIUS,
    )
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotCalibrationReport {
    pub request: PilotCalibrationRequest,
    pub dataset_fingerprint: String,
    pub manifest: CalibrationManifest,
    pub fixture: PilotFixtureManifest,
    pub power: PowerPlan,
    pub side_power: EquivalencePowerPlan,
    pub bootstrap: BootstrapConfig,
    pub status: PilotCalibrationStatus,
    pub reasons: Vec<String>,
    pub development: PilotPhaseFit,
    pub validation: PilotPhaseFit,
    pub final_holdout: PilotPhaseFit,
    pub simultaneous_pair_intervals: SimultaneousBootstrapReport,
    pub pairwise_family_alpha: f64,
    pub pairwise: Vec<PilotPairwiseDecision>,
    pub side_equivalence: Vec<PilotSideEquivalence>,
    /// Present only when every certification gate passes.
    pub certified_ladder: Option<Vec<CertifiedPilotEntry>>,
}

/// One preregistered confirmatory attempt for a fixed design and content set.
/// Registries are append-only: a second attempt needs a different design
/// fingerprint, which in turn requires a reviewed design or content change.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PilotCalibrationAttempt {
    pub attempt_id: String,
    pub design_fingerprint: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PilotCalibrationAttemptRegistry {
    pub schema_version: u32,
    pub attempts: Vec<PilotCalibrationAttempt>,
}

/// Compact release artifact produced only after the raw observations have
/// passed the full deterministic verifier. Runtime checks content and the
/// preregistration against this artifact, but does not replay the expensive
/// bootstrap during startup.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PilotCalibrationAttestation {
    pub schema_version: u32,
    pub request: PilotCalibrationRequest,
    pub design_fingerprint: String,
    pub dataset_fingerprint: String,
    pub report_fingerprint: String,
    pub execution_fingerprint: String,
    pub manifest: CalibrationManifest,
    pub fixture: PilotFixtureManifest,
    pub certified_ladder: Vec<CertifiedPilotEntry>,
    /// Ed25519 signature over every other field, encoded as lowercase hex.
    pub signature: String,
}

#[allow(
    dead_code,
    reason = "used by the checked-in pilot report gate when the runtime embeds a report"
)]
fn finite_interval(estimate: f64, low: f64, high: f64) -> bool {
    estimate.is_finite()
        && low.is_finite()
        && high.is_finite()
        && low <= estimate
        && estimate <= high
}

#[allow(
    dead_code,
    reason = "used by the checked-in pilot report gate when the runtime embeds a report"
)]
fn verified_tost(result: &TostResult, lower: f64, upper: f64, alpha: f64) -> bool {
    result.verdict == EquivalenceVerdict::Equivalent
        && result.lower_bound == lower
        && result.upper_bound == upper
        && result.alpha == alpha
        && result.confidence == 1.0 - 2.0 * alpha
        && result.estimate.is_finite()
        && result.standard_error.is_finite()
        && result.standard_error >= 0.0
        && result.lower_test_p.is_finite()
        && (0.0..=alpha).contains(&result.lower_test_p)
        && result.upper_test_p.is_finite()
        && (0.0..=alpha).contains(&result.upper_test_p)
        && finite_interval(
            result.estimate,
            result.confidence_low,
            result.confidence_high,
        )
        && result.confidence_low > lower
        && result.confidence_high < upper
        && experiment::tost_equivalence(result.estimate, result.standard_error, lower, upper, alpha)
            .is_ok_and(|expected| expected == *result)
}

#[allow(
    dead_code,
    reason = "used by the checked-in pilot report gate when the runtime embeds a report"
)]
fn fitted_score(fit: &BradleyTerryFit, subject: &str, opponent: &str) -> Option<f64> {
    fit.matchup_matrix.iter().find_map(|comparison| {
        if comparison.a == subject && comparison.b == opponent {
            Some(comparison.score_a)
        } else if comparison.a == opponent && comparison.b == subject {
            Some(1.0 - comparison.score_a)
        } else {
            None
        }
    })
}

#[allow(
    dead_code,
    reason = "used by the checked-in pilot report gate when the runtime embeds a report"
)]
fn verified_phase(
    phase: &PilotPhaseFit,
    pool: &SeedPool,
    roster: &[PilotSpec],
    anchor: &str,
    matchups: usize,
    confidence: f64,
) -> bool {
    let Some(expected_pairs) = pool.count.checked_mul(matchups) else {
        return false;
    };
    if phase.pool != pool.name
        || phase.role != pool.role
        || phase.scenario_seeds != pool.count
        || phase.mirrored_pairs != expected_pairs
        || !phase.fit.converged
        || phase.fit.anchor != anchor
        || phase.fit.anchor_elo != ai::ANCHOR_RATING
        || phase.fit.confidence != confidence
        || phase.fit.comparisons != matchups
        || phase.fit.strengths.len() != roster.len()
        || phase.fit.matchup_matrix.len() != matchups
        || !phase.fit.penalized_log_likelihood.is_finite()
    {
        return false;
    }
    let names: HashSet<&str> = roster.iter().map(|pilot| pilot.callsign.as_str()).collect();
    let mut strengths = HashSet::new();
    for strength in &phase.fit.strengths {
        if !names.contains(strength.competitor.as_str())
            || !strengths.insert(strength.competitor.as_str())
            || strength.confidence != confidence
            || strength.standard_error_elo < 0.0
            || !strength.log_strength.is_finite()
            || !strength.standard_error_elo.is_finite()
            || !finite_interval(strength.elo, strength.elo_low, strength.elo_high)
            || strength.anchored != (strength.competitor == anchor)
        {
            return false;
        }
    }
    let mut comparison_pairs = HashSet::new();
    for comparison in &phase.fit.matchup_matrix {
        if comparison.a == comparison.b
            || !names.contains(comparison.a.as_str())
            || !names.contains(comparison.b.as_str())
            || !comparison.score_a.is_finite()
            || !(0.0..=1.0).contains(&comparison.score_a)
            || comparison.weight != pool.count as f64
        {
            return false;
        }
        let pair = if comparison.a < comparison.b {
            (comparison.a.as_str(), comparison.b.as_str())
        } else {
            (comparison.b.as_str(), comparison.a.as_str())
        };
        if !comparison_pairs.insert(pair) {
            return false;
        }
    }
    strengths.len() == roster.len()
        && comparison_pairs.len() == matchups
        && experiment::fit_bradley_terry(
            &phase.fit.matchup_matrix,
            &BradleyTerryConfig {
                anchor: anchor.into(),
                anchor_elo: ai::ANCHOR_RATING,
                confidence,
                ..BradleyTerryConfig::default()
            },
        )
        .is_ok_and(|expected| expected == phase.fit)
}

/// Accept a serialized ladder only when its evidence and every shipped input
/// still satisfy the certification contract.
fn meets_pilot_release_policy(request: &PilotCalibrationRequest) -> bool {
    let release = PilotCalibrationRequest::default();
    request.attempt_id != "exploratory"
        && request.alpha == release.alpha
        && request.power == release.power
        && request.minimum_superiority_margin == release.minimum_superiority_margin
        && request.superiority_design_increment == release.superiority_design_increment
        && request.paired_variance == release.paired_variance
        && request.side_equivalence_half_width == release.side_equivalence_half_width
        && request.side_paired_variance == release.side_paired_variance
        && request.bootstrap_replicates == release.bootstrap_replicates
}

#[allow(
    dead_code,
    reason = "content half of the checked-in evidence gate, also exercised directly by tests"
)]
fn verified_current_report(
    report: &PilotCalibrationReport,
    roster: &[PilotSpec],
) -> Result<bool, PilotCalibrationError> {
    report.manifest.validate()?;
    report.fixture.validate()?;
    if roster.len() < 2 {
        return Err(PilotCalibrationError::InvalidRoster(
            "at least two pilots are required".into(),
        ));
    }
    let mut roster_ids = HashSet::new();
    let mut roster_names = HashSet::new();
    for pilot in roster {
        if pilot.callsign.trim().is_empty()
            || !roster_ids.insert(pilot.id.0)
            || !roster_names.insert(pilot.callsign.as_str())
        {
            return Err(PilotCalibrationError::InvalidRoster(
                "pilot ids and callsigns must be unique and nonempty".into(),
            ));
        }
    }
    if report.status != PilotCalibrationStatus::Certified || !report.reasons.is_empty() {
        return Ok(false);
    }

    // A report may describe a sound experiment without meeting the release
    // contract for the shipped Ladder. In particular, re-planning a
    // self-consistent report with an optimistic variance can reduce the
    // required sample to almost nothing. Keep exploratory flexibility in the
    // planner, but admit a live ordering only under the prespecified policy.
    if !meets_pilot_release_policy(&report.request) {
        return Ok(false);
    }

    let current_plan = plan_pilot_calibration(roster, &report.request)?;
    let current_fixture = load_pilot_fixture(roster)?;
    let current_inputs = pilot_input_fingerprints(roster, &current_fixture);
    if report.dataset_fingerprint.trim().is_empty()
        || report.request.paired_scenarios_per_pool
            < report
                .power
                .required_pairs
                .max(report.side_power.required_pairs)
        || current_plan.exploratory
        || report.manifest != current_plan.manifest
        || report.fixture != current_plan.fixture
        || report.power != current_plan.power
        || report.side_power != current_plan.side_power
        || report.bootstrap != current_plan.bootstrap
        || report.fixture != current_fixture.manifest
        || report.manifest.schema_version != PILOT_CALIBRATION_SCHEMA
        || report.manifest.controller_version != PILOT_CONTROLLER_VERSION
        || report.manifest.profile_versions
            != vec![format!("pilot-spec-v{}", pilots::PILOT_SPEC_VERSION)]
        || report.manifest.maps != vec![PILOT_MAP.to_string()]
        || report.manifest.economies != vec![PILOT_ECONOMY.to_string()]
        || report.manifest.controller_fingerprint != current_inputs.controller
        || report.manifest.profile_fingerprints != current_inputs.profiles
        || report.manifest.map_fingerprints != current_inputs.maps
        || report.manifest.economy_fingerprints != current_inputs.economies
    {
        return Ok(false);
    }

    let matchups = roster.len() * (roster.len() - 1) / 2;
    let confirmatory_gates = matchups * 4;
    let superiority_gate_power = 1.0 - (1.0 - report.manifest.power) / confirmatory_gates as f64;
    if report.power.request.family_hypotheses != matchups * 2
        || report.manifest.hypotheses.len() != matchups * 2
        || report.manifest.samples.len() != matchups * 2
        || report.power.request.alpha != report.manifest.alpha
        || report.power.request.power != superiority_gate_power
        || report.side_power.request.joint_power != report.manifest.power
        || report.power.request.sidedness != Sidedness::TwoSided
        || experiment::plan_paired_mean(report.power.request)? != report.power
        || report.side_power.request.family_hypotheses != matchups * 2
        || report.side_power.request.independent_confirmatory_gates != confirmatory_gates
        || experiment::plan_paired_equivalence(report.side_power.request)? != report.side_power
        || report.manifest.samples.iter().any(|sample| {
            let required = if sample.hypothesis_id.ends_with("-side-equivalence") {
                report.side_power.required_pairs
            } else {
                report.power.required_pairs
            };
            sample.paired_scenarios != required
        })
        || report.manifest.seed_pools.iter().any(|pool| {
            pool.count
                < report
                    .power
                    .required_pairs
                    .max(report.side_power.required_pairs)
        })
    {
        return Ok(false);
    }

    let development_pools: Vec<&SeedPool> = report
        .manifest
        .seed_pools
        .iter()
        .filter(|pool| pool.role == SeedPoolRole::Development)
        .collect();
    let validation_pools: Vec<&SeedPool> = report
        .manifest
        .seed_pools
        .iter()
        .filter(|pool| pool.role == SeedPoolRole::Validation)
        .collect();
    let holdout_pools: Vec<&SeedPool> = report
        .manifest
        .seed_pools
        .iter()
        .filter(|pool| pool.role == SeedPoolRole::Holdout)
        .collect();
    if report.manifest.seed_pools.len() != 3
        || development_pools.len() != 1
        || validation_pools.len() != 1
        || holdout_pools.len() != 1
    {
        return Ok(false);
    }
    let mut rng_scenarios = HashSet::new();
    for pool in &report.manifest.seed_pools {
        for offset in 0..pool.count {
            let seed = pool.first_seed + offset as u64;
            if !rng_scenarios.insert(mixed_seed(pool.namespace, seed, PILOT_WORLD_SEED_LABEL)) {
                return Ok(false);
            }
        }
    }
    let anchor = roster
        .iter()
        .find(|pilot| pilot.callsign == ai::ANCHOR)
        .unwrap_or(&roster[0]);
    let confidence = 1.0 - report.manifest.alpha;
    let namespace = development_pools[0].namespace;
    if validation_pools[0].namespace != namespace
        || holdout_pools[0].namespace != namespace
        || report.bootstrap.confidence != confidence
        || report.bootstrap.replicates < 2
        || report.bootstrap.rng_seed != namespace ^ PILOT_BOOTSTRAP_SEED_LABEL
    {
        return Ok(false);
    }
    if !verified_phase(
        &report.development,
        development_pools[0],
        roster,
        &anchor.callsign,
        matchups,
        confidence,
    ) || !verified_phase(
        &report.validation,
        validation_pools[0],
        roster,
        &anchor.callsign,
        matchups,
        confidence,
    ) || !verified_phase(
        &report.final_holdout,
        holdout_pools[0],
        roster,
        &anchor.callsign,
        matchups,
        confidence,
    ) {
        return Ok(false);
    }

    let expected_pairs = ordered_matchups(roster);
    let known: HashMap<u32, &PilotSpec> = roster.iter().map(|pilot| (pilot.id.0, pilot)).collect();
    let equivalence_alpha = report.manifest.alpha / report.manifest.hypotheses.len() as f64;
    let side_decisions: HashMap<&str, _> = report
        .side_equivalence
        .iter()
        .map(|decision| (decision.hypothesis_id.as_str(), decision))
        .collect();
    if side_decisions.len() != matchups {
        return Ok(false);
    }
    for (a_id, b_id, pair_id) in &expected_pairs {
        let side_id = format!("{pair_id}-side-equivalence");
        let Some(decision) = side_decisions.get(side_id.as_str()) else {
            return Ok(false);
        };
        let Some(bounds) =
            report
                .manifest
                .hypotheses
                .iter()
                .find_map(|hypothesis| match hypothesis.kind {
                    HypothesisKind::Equivalence { lower, upper } if hypothesis.id == side_id => {
                        Some((lower, upper))
                    }
                    _ => None,
                })
        else {
            return Ok(false);
        };
        if decision.a != known[a_id].callsign
            || decision.b != known[b_id].callsign
            || bounds.0 != -bounds.1
            || bounds.1 != report.request.side_equivalence_half_width
            || !verified_tost(&decision.validation, bounds.0, bounds.1, equivalence_alpha)
            || !verified_tost(
                &decision.final_holdout,
                bounds.0,
                bounds.1,
                equivalence_alpha,
            )
        {
            return Ok(false);
        }
    }

    if report.pairwise.len() != matchups
        || report.pairwise_family_alpha
            != report.manifest.alpha * matchups as f64 / report.manifest.hypotheses.len() as f64
        || report.simultaneous_pair_intervals.family_size != matchups
        || report.simultaneous_pair_intervals.clusters != holdout_pools[0].count
        || report.simultaneous_pair_intervals.replicates < 2
        || report.simultaneous_pair_intervals.replicates != report.bootstrap.replicates
        || report.simultaneous_pair_intervals.confidence != confidence
        || report.simultaneous_pair_intervals.estimates.len() != matchups
        || !report
            .simultaneous_pair_intervals
            .critical_value
            .is_finite()
        || report.simultaneous_pair_intervals.critical_value < 0.0
    {
        return Ok(false);
    }
    let intervals: HashMap<&str, _> = report
        .simultaneous_pair_intervals
        .estimates
        .iter()
        .map(|estimate| (estimate.label.as_str(), estimate))
        .collect();
    let decisions: HashMap<&str, _> = report
        .pairwise
        .iter()
        .map(|decision| (decision.hypothesis_id.as_str(), decision))
        .collect();
    let locked_order = prespecified_order(roster);
    if intervals.len() != matchups || decisions.len() != matchups {
        return Ok(false);
    }
    for (a_id, b_id, id) in expected_pairs {
        let (Some(interval), Some(decision)) =
            (intervals.get(id.as_str()), decisions.get(id.as_str()))
        else {
            return Ok(false);
        };
        let a = known[&a_id];
        let b = known[&b_id];
        let (locked_stronger, locked_weaker) =
            if locked_order[&a.callsign] < locked_order[&b.callsign] {
                (a, b)
            } else {
                (b, a)
            };
        let names_match = decision.stronger == locked_stronger.callsign
            && decision.weaker == locked_weaker.callsign;
        let minimum_effect = superiority_effect_from_manifest(&report.manifest, &id)?;
        let threshold = 0.5 + minimum_effect;
        let fitted_validation =
            fitted_score(&report.validation.fit, &decision.stronger, &decision.weaker);
        let fitted_final = fitted_score(
            &report.final_holdout.fit,
            &decision.stronger,
            &decision.weaker,
        );
        if !names_match
            || decision.minimum_superiority_margin != minimum_effect
            || minimum_effect != report.request.minimum_superiority_margin
            || decision.superiority_threshold != threshold
            || !decision.significant
            || !decision.simultaneous_clears_threshold
            || !decision.validation_score.is_finite()
            || decision.validation_score <= threshold
            || fitted_validation != Some(decision.validation_score)
            || !decision.final_score.is_finite()
            || decision.final_score <= threshold
            || fitted_final != Some(decision.final_score)
            || !finite_interval(
                decision.final_score,
                decision.simultaneous_low,
                decision.simultaneous_high,
            )
            || decision.simultaneous_low <= threshold
            || !decision.raw_p.is_finite()
            || !(0.0..=report.pairwise_family_alpha).contains(&decision.raw_p)
            || !decision.adjusted_p.is_finite()
            || !(decision.raw_p..=report.pairwise_family_alpha).contains(&decision.adjusted_p)
            || interval.estimate != decision.final_score
            || interval.low != decision.simultaneous_low
            || interval.high != decision.simultaneous_high
            || !interval.standard_error.is_finite()
            || interval.standard_error < 0.0
            || interval.low
                != interval.estimate
                    - report.simultaneous_pair_intervals.critical_value * interval.standard_error
            || interval.high
                != interval.estimate
                    + report.simultaneous_pair_intervals.critical_value * interval.standard_error
        {
            return Ok(false);
        }
    }

    let Some(ladder) = &report.certified_ladder else {
        return Ok(false);
    };
    if ladder.len() != roster.len() {
        return Ok(false);
    }
    let mut expected_ladder: Vec<&PilotSpec> = roster.iter().collect();
    expected_ladder.sort_by(|left, right| {
        locked_order[&right.callsign]
            .cmp(&locked_order[&left.callsign])
            .then_with(|| left.callsign.cmp(&right.callsign))
    });
    if ladder
        .iter()
        .map(|entry| entry.pilot_id)
        .ne(expected_ladder.iter().map(|pilot| pilot.id.0))
    {
        return Ok(false);
    }
    let final_strengths: HashMap<&str, _> = report
        .final_holdout
        .fit
        .strengths
        .iter()
        .map(|strength| (strength.competitor.as_str(), strength))
        .collect();
    let mut ladder_ids = HashSet::new();
    for entry in ladder {
        let Some(pilot) = known.get(&entry.pilot_id) else {
            return Ok(false);
        };
        let Some(strength) = final_strengths.get(entry.callsign.as_str()) else {
            return Ok(false);
        };
        if !ladder_ids.insert(entry.pilot_id)
            || entry.callsign != pilot.callsign
            || !entry.elo.is_finite()
            || entry.elo != pilot_account_seed(strength.elo)
        {
            return Ok(false);
        }
    }
    Ok(ladder_ids.len() == roster.len())
}

/// Verify the checked-in release from its raw mirrored observations, not from
/// report aggregates supplied by the same file. The analysis is deterministic,
/// so rebuilding it also checks the bootstrap, pair tests, equivalence tests,
/// fits, intervals, and final ordering as one artifact.
pub fn verified_current_evidence(
    report: &PilotCalibrationReport,
    dataset: &PilotCalibrationDataset,
    roster: &[PilotSpec],
) -> Result<bool, PilotCalibrationError> {
    if !verified_current_report(report, roster)?
        || report.dataset_fingerprint != pilot_dataset_fingerprint(dataset)?
    {
        return Ok(false);
    }
    let plan = plan_pilot_calibration(roster, &report.request)?;
    let rebuilt = analyze_pilot_calibration(roster, &plan, dataset)?;
    Ok(rebuilt == *report)
}

/// Fingerprint the prespecified design without its attempt name or seed
/// namespace. The canonical release sample size stays in the payload. A retry
/// against the same design therefore has the same fingerprint and cannot be
/// preregistered as a second confirmatory attempt.
pub fn pilot_design_fingerprint(
    plan: &PilotCalibrationPlan,
) -> Result<String, PilotCalibrationError> {
    let mut request = plan.request.clone();
    request.attempt_id.clear();
    request.paired_scenarios_per_pool = plan
        .power
        .required_pairs
        .max(plan.side_power.required_pairs);
    let encoded = serde_json::to_vec(&(
        request,
        &plan.fixture,
        &plan.manifest.controller_version,
        &plan.manifest.profile_versions,
        &plan.manifest.maps,
        &plan.manifest.economies,
        &plan.manifest.controller_fingerprint,
        &plan.manifest.profile_fingerprints,
        &plan.manifest.map_fingerprints,
        &plan.manifest.economy_fingerprints,
        &plan.manifest.hypotheses,
        &plan.manifest.samples,
    ))
    .map_err(|error| {
        PilotCalibrationError::InvalidRequest(format!(
            "pilot design could not be fingerprinted: {error}"
        ))
    })?;
    Ok(fingerprint(&[&encoded]))
}

pub fn pilot_attempt_registered(
    plan: &PilotCalibrationPlan,
    registry_json: &str,
) -> Result<bool, PilotCalibrationError> {
    let registry: PilotCalibrationAttemptRegistry =
        serde_json::from_str(registry_json).map_err(|error| {
            PilotCalibrationError::InvalidRequest(format!(
                "pilot attempt registry is invalid: {error}"
            ))
        })?;
    if registry.schema_version != 1 {
        return Err(PilotCalibrationError::InvalidRequest(format!(
            "pilot attempt registry schema {} is unsupported",
            registry.schema_version
        )));
    }
    let mut attempt_ids = HashSet::new();
    for attempt in &registry.attempts {
        if attempt.attempt_id.is_empty()
            || !attempt_ids.insert(attempt.attempt_id.as_str())
            || !attempt.design_fingerprint.starts_with("sha256:")
        {
            return Err(PilotCalibrationError::InvalidRequest(
                "pilot attempt registry has a blank or duplicate attempt, or an invalid fingerprint"
                    .into(),
            ));
        }
    }
    let design = pilot_design_fingerprint(plan)?;
    let matching: Vec<&PilotCalibrationAttempt> = registry
        .attempts
        .iter()
        .filter(|attempt| attempt.design_fingerprint == design)
        .collect();
    Ok(matching.len() == 1 && matching[0].attempt_id == plan.request.attempt_id)
}

fn pilot_report_fingerprint(
    report: &PilotCalibrationReport,
) -> Result<String, PilotCalibrationError> {
    let encoded = serde_json::to_vec(report).map_err(|error| {
        PilotCalibrationError::InvalidDataset(format!(
            "pilot report could not be fingerprinted: {error}"
        ))
    })?;
    Ok(fingerprint(&[&encoded]))
}

fn pilot_attestation_payload(
    attestation: &PilotCalibrationAttestation,
) -> Result<Vec<u8>, PilotCalibrationError> {
    let mut unsigned = attestation.clone();
    unsigned.signature.clear();
    serde_json::to_vec(&unsigned).map_err(|error| {
        PilotCalibrationError::InvalidDataset(format!(
            "pilot attestation could not be encoded: {error}"
        ))
    })
}

/// Verify raw evidence once in the release workflow and reduce it to the
/// content-addressed artifact that production can check cheaply.
pub fn attest_pilot_calibration(
    report: &PilotCalibrationReport,
    dataset: &PilotCalibrationDataset,
    roster: &[PilotSpec],
    registry_json: &str,
    signing_key: &SigningKey,
) -> Result<Option<PilotCalibrationAttestation>, PilotCalibrationError> {
    if !verified_current_evidence(report, dataset, roster)? {
        return Ok(None);
    }
    let plan = plan_pilot_calibration(roster, &report.request)?;
    if !pilot_attempt_registered(&plan, registry_json)? {
        return Ok(None);
    }
    let Some(certified_ladder) = report.certified_ladder.clone() else {
        return Ok(None);
    };
    let mut attestation = PilotCalibrationAttestation {
        schema_version: PILOT_ATTESTATION_SCHEMA,
        request: report.request.clone(),
        design_fingerprint: pilot_design_fingerprint(&plan)?,
        dataset_fingerprint: report.dataset_fingerprint.clone(),
        report_fingerprint: pilot_report_fingerprint(report)?,
        execution_fingerprint: calibration_execution_fingerprint(),
        manifest: report.manifest.clone(),
        fixture: report.fixture.clone(),
        certified_ladder,
        signature: String::new(),
    };
    let signature = signing_key.sign(&pilot_attestation_payload(&attestation)?);
    attestation.signature = crate::token::to_hex(&signature.to_bytes());
    Ok(Some(attestation))
}

/// Cheap production gate for a release-time attestation. Source, profiles,
/// map, economy, fixture, policy, sample plan, and preregistration must still
/// match this binary exactly.
pub fn verified_current_attestation(
    attestation: &PilotCalibrationAttestation,
    roster: &[PilotSpec],
    registry_json: &str,
    verifying_key: &VerifyingKey,
) -> Result<bool, PilotCalibrationError> {
    if attestation.schema_version != PILOT_ATTESTATION_SCHEMA
        || !attestation.dataset_fingerprint.starts_with("sha256:")
        || !attestation.report_fingerprint.starts_with("sha256:")
        || attestation.execution_fingerprint != calibration_execution_fingerprint()
        || attestation.certified_ladder.len() != roster.len()
    {
        return Ok(false);
    }
    let Some(signature) = crate::token::from_hex(&attestation.signature)
        .and_then(|bytes| <[u8; 64]>::try_from(bytes).ok())
        .map(|bytes| Signature::from_bytes(&bytes))
    else {
        return Ok(false);
    };
    if verifying_key
        .verify(&pilot_attestation_payload(attestation)?, &signature)
        .is_err()
    {
        return Ok(false);
    }
    let plan = plan_pilot_calibration(roster, &attestation.request)?;
    if plan.exploratory
        || !meets_pilot_release_policy(&attestation.request)
        || !pilot_attempt_registered(&plan, registry_json)?
        || attestation.design_fingerprint != pilot_design_fingerprint(&plan)?
        || attestation.manifest != plan.manifest
        || attestation.fixture != plan.fixture
    {
        return Ok(false);
    }
    let known: HashMap<u32, &PilotSpec> = roster.iter().map(|pilot| (pilot.id.0, pilot)).collect();
    let mut ids = HashSet::new();
    for entry in &attestation.certified_ladder {
        let Some(pilot) = known.get(&entry.pilot_id) else {
            return Ok(false);
        };
        if !ids.insert(entry.pilot_id)
            || entry.callsign != pilot.callsign
            || !entry.elo.is_finite()
            || entry.elo < ai::ANCHOR_RATING - PILOT_ACCOUNT_SEED_RADIUS
            || entry.elo > ai::ANCHOR_RATING + PILOT_ACCOUNT_SEED_RADIUS
        {
            return Ok(false);
        }
    }
    Ok(ids.len() == roster.len())
}

#[allow(
    dead_code,
    reason = "public audit helper used by focused calibration tools and tests"
)]
pub fn pool_manifest_for_role(
    plan: &PilotCalibrationPlan,
    role: SeedPoolRole,
) -> Result<&SeedPool, PilotCalibrationError> {
    let mut matching = plan
        .manifest
        .seed_pools
        .iter()
        .filter(|pool| pool.role == role);
    let pool = matching.next().ok_or_else(|| {
        PilotCalibrationError::InvalidDataset(format!("missing {role:?} seed pool"))
    })?;
    if matching.next().is_some() {
        return Err(PilotCalibrationError::InvalidDataset(format!(
            "more than one {role:?} seed pool"
        )));
    }
    Ok(pool)
}

fn dataset_pool_for_role(
    dataset: &PilotCalibrationDataset,
    role: SeedPoolRole,
) -> Result<&PilotCalibrationPool, PilotCalibrationError> {
    let mut matching = dataset.pools.iter().filter(|pool| pool.role == role);
    let pool = matching.next().ok_or_else(|| {
        PilotCalibrationError::InvalidDataset(format!("missing {role:?} observations"))
    })?;
    if matching.next().is_some() {
        return Err(PilotCalibrationError::InvalidDataset(format!(
            "more than one {role:?} observation pool"
        )));
    }
    Ok(pool)
}

fn validate_leg_metadata(
    leg: &PilotLegResult,
    expected: PilotMirrorAssignment,
    a_id: u32,
    b_id: u32,
    regulation_ticks: u32,
    total_ticks: u32,
) -> Result<(), PilotCalibrationError> {
    if leg.a_side != expected.side
        || leg.a_start != expected.start
        || leg.a_heading != expected.heading
    {
        return Err(PilotCalibrationError::InvalidDataset(
            "a leg does not match its mirrored side, start, and heading assignment".into(),
        ));
    }
    if leg.ticks == 0 || leg.ticks > total_ticks {
        return Err(PilotCalibrationError::InvalidDataset(
            "a leg has an invalid tick count".into(),
        ));
    }
    if leg.reached_overtime != (leg.ticks > regulation_ticks) {
        return Err(PilotCalibrationError::InvalidDataset(
            "a leg's overtime flag disagrees with its tick count".into(),
        ));
    }
    if leg
        .killer_id
        .is_some_and(|killer| killer != a_id && killer != b_id)
    {
        return Err(PilotCalibrationError::InvalidDataset(
            "a leg names a killer outside its matchup".into(),
        ));
    }
    if leg.censored {
        if leg.ticks != total_ticks
            || leg.a_score != 0.5
            || leg.victim_id.is_some()
            || leg.killer_id.is_some()
            || leg.mutual_death
        {
            return Err(PilotCalibrationError::InvalidDataset(
                "a censored leg has completed-match metadata".into(),
            ));
        }
        return Ok(());
    }
    if leg.mutual_death {
        if leg.a_score != 0.5 || leg.victim_id.is_some() || leg.killer_id.is_some() {
            return Err(PilotCalibrationError::InvalidDataset(
                "a mutual death is not recorded as a half-score draw".into(),
            ));
        }
        return Ok(());
    }
    let expected_score = match leg.victim_id {
        Some(victim) if victim == a_id => 0.0,
        Some(victim) if victim == b_id => 1.0,
        _ => {
            return Err(PilotCalibrationError::InvalidDataset(
                "a completed leg names no matchup victim".into(),
            ));
        }
    };
    if leg.a_score != expected_score {
        return Err(PilotCalibrationError::InvalidDataset(
            "a leg's score disagrees with its victim".into(),
        ));
    }
    Ok(())
}

fn validate_pilot_dataset(
    roster: &[PilotSpec],
    plan: &PilotCalibrationPlan,
    dataset: &PilotCalibrationDataset,
) -> Result<(), PilotCalibrationError> {
    plan.manifest.validate()?;
    plan.fixture.validate()?;
    let expected_matchups = roster.len().saturating_mul(roster.len().saturating_sub(1)) / 2;
    if plan.matchups != expected_matchups {
        return Err(PilotCalibrationError::InvalidDataset(
            "the plan's matchup count disagrees with its roster".into(),
        ));
    }
    let is_exploratory = plan.request.attempt_id == "exploratory"
        || plan.requested_pairs_per_matchup_per_pool
            < plan
                .power
                .required_pairs
                .max(plan.side_power.required_pairs);
    if plan.exploratory != is_exploratory {
        return Err(PilotCalibrationError::InvalidDataset(
            "the plan's exploratory label disagrees with its power gate".into(),
        ));
    }
    let expected_profiles: Vec<ContentFingerprint> =
        roster.iter().map(profile_fingerprint).collect();
    if plan.manifest.profile_fingerprints != expected_profiles {
        return Err(PilotCalibrationError::InvalidDataset(
            "the roster does not match the planned profile fingerprints".into(),
        ));
    }
    if dataset.pools.len() != plan.manifest.seed_pools.len() {
        return Err(PilotCalibrationError::InvalidDataset(format!(
            "expected {} pools, got {}",
            plan.manifest.seed_pools.len(),
            dataset.pools.len()
        )));
    }
    let known: HashMap<u32, &PilotSpec> = roster.iter().map(|spec| (spec.id.0, spec)).collect();
    for declared in &plan.manifest.seed_pools {
        let pool = dataset
            .pools
            .iter()
            .find(|pool| pool.name == declared.name)
            .ok_or_else(|| {
                PilotCalibrationError::InvalidDataset(format!(
                    "pool {:?} has no observations",
                    declared.name
                ))
            })?;
        if pool.role != declared.role {
            return Err(PilotCalibrationError::InvalidDataset(format!(
                "pool {:?} has the wrong role",
                pool.name
            )));
        }
        if declared.count != plan.requested_pairs_per_matchup_per_pool {
            return Err(PilotCalibrationError::InvalidDataset(format!(
                "pool {:?} does not match the requested sample",
                pool.name
            )));
        }
        let expected = declared.count * plan.matchups;
        if pool.observations.len() != expected {
            return Err(PilotCalibrationError::InvalidDataset(format!(
                "pool {:?} expected {expected} mirrored pairs, got {}",
                pool.name,
                pool.observations.len()
            )));
        }
        let end = declared.first_seed + declared.count as u64;
        let mut seen = HashSet::new();
        for observation in &pool.observations {
            if observation.pool != pool.name {
                return Err(PilotCalibrationError::InvalidDataset(format!(
                    "an observation names pool {:?} inside {:?}",
                    observation.pool, pool.name
                )));
            }
            if observation.seed < declared.first_seed || observation.seed >= end {
                return Err(PilotCalibrationError::InvalidDataset(format!(
                    "seed {} is outside pool {:?}",
                    observation.seed, pool.name
                )));
            }
            if observation.fixture_fingerprint != plan.fixture.fixture_fingerprint {
                return Err(PilotCalibrationError::InvalidDataset(format!(
                    "seed {} has the wrong fixture fingerprint",
                    observation.seed
                )));
            }
            let expected_indices = pilots::ladder_start_pair(
                declared.namespace,
                observation.seed,
                plan.fixture.starts_per_team,
            )
            .ok_or_else(|| {
                PilotCalibrationError::InvalidDataset(
                    "the planned fixture has no Ladder start pair".into(),
                )
            })?;
            let expected_starts = plan
                .fixture
                .start_pairs
                .iter()
                .find(|pair| pair.indices == expected_indices)
                .ok_or_else(|| {
                    PilotCalibrationError::InvalidDataset(format!(
                        "fixture omits selected start pair {expected_indices:?}"
                    ))
                })?;
            if observation.start_indices != expected_starts.indices
                || observation.start_positions != expected_starts.positions
            {
                return Err(PilotCalibrationError::InvalidDataset(format!(
                    "seed {} has the wrong start metadata",
                    observation.seed
                )));
            }
            let a = known.get(&observation.a_id).ok_or_else(|| {
                PilotCalibrationError::InvalidDataset(format!(
                    "unknown pilot id {}",
                    observation.a_id
                ))
            })?;
            let b = known.get(&observation.b_id).ok_or_else(|| {
                PilotCalibrationError::InvalidDataset(format!(
                    "unknown pilot id {}",
                    observation.b_id
                ))
            })?;
            if a.callsign != observation.a || b.callsign != observation.b {
                return Err(PilotCalibrationError::InvalidDataset(
                    "pilot ids and callsigns disagree".into(),
                ));
            }
            if observation.a_id == observation.b_id {
                return Err(PilotCalibrationError::InvalidDataset(
                    "a pilot is matched against itself".into(),
                ));
            }
            let pair = if observation.a_id < observation.b_id {
                (observation.a_id, observation.b_id)
            } else {
                (observation.b_id, observation.a_id)
            };
            if !seen.insert((observation.seed, pair.0, pair.1)) {
                return Err(PilotCalibrationError::InvalidDataset(format!(
                    "seed {} repeats matchup {} to {}",
                    observation.seed, pair.0, pair.1
                )));
            }
            let assignments = pilot_mirror_assignments(
                a,
                b,
                observation.start_indices,
                observation.start_positions,
            );
            let first_a = assignments[0]
                .iter()
                .find(|assignment| assignment.pilot_id == observation.a_id)
                .copied()
                .ok_or_else(|| {
                    PilotCalibrationError::InvalidDataset(
                        "the first leg omits its subject pilot".into(),
                    )
                })?;
            let mirrored_a = assignments[1]
                .iter()
                .find(|assignment| assignment.pilot_id == observation.a_id)
                .copied()
                .ok_or_else(|| {
                    PilotCalibrationError::InvalidDataset(
                        "the mirrored leg omits its subject pilot".into(),
                    )
                })?;
            let total_ticks = plan
                .fixture
                .regulation_ticks
                .saturating_add(plan.fixture.overtime_safety_ticks);
            validate_leg_metadata(
                &observation.first,
                first_a,
                observation.a_id,
                observation.b_id,
                plan.fixture.regulation_ticks,
                total_ticks,
            )?;
            validate_leg_metadata(
                &observation.mirrored,
                mirrored_a,
                observation.a_id,
                observation.b_id,
                plan.fixture.regulation_ticks,
                total_ticks,
            )?;
            observation.paired()?;
        }
    }
    Ok(())
}

fn aggregate_matchups(
    pool: &PilotCalibrationPool,
) -> Result<Vec<BradleyTerryComparison>, PilotCalibrationError> {
    let mut rows: BTreeMap<(String, String), (f64, f64)> = BTreeMap::new();
    for observation in &pool.observations {
        let pair = observation.paired()?;
        let row = rows
            .entry((observation.a.clone(), observation.b.clone()))
            .or_insert((0.0, 0.0));
        row.0 += pair.score();
        row.1 += 1.0;
    }
    Ok(rows
        .into_iter()
        .map(|((a, b), (score, weight))| BradleyTerryComparison {
            a,
            b,
            score_a: score / weight,
            weight,
        })
        .collect())
}

fn fit_phase(
    pool: &PilotCalibrationPool,
    anchor: &str,
    anchor_elo: f64,
    confidence: f64,
) -> Result<PilotPhaseFit, PilotCalibrationError> {
    let comparisons = aggregate_matchups(pool)?;
    let seeds: HashSet<u64> = pool
        .observations
        .iter()
        .map(|observation| observation.seed)
        .collect();
    let fit = experiment::fit_bradley_terry(
        &comparisons,
        &BradleyTerryConfig {
            anchor: anchor.into(),
            anchor_elo,
            confidence,
            ..BradleyTerryConfig::default()
        },
    )?;
    Ok(PilotPhaseFit {
        pool: pool.name.clone(),
        role: pool.role,
        scenario_seeds: seeds.len(),
        mirrored_pairs: pool.observations.len(),
        fit,
    })
}

fn prespecified_order(roster: &[PilotSpec]) -> HashMap<String, usize> {
    pilots::provisional_ladder_order(roster)
        .into_iter()
        .rev()
        .enumerate()
        .map(|(rank, index)| (roster[index].callsign.clone(), rank))
        .collect()
}

fn oriented_score(
    observation: &PilotMatchupObservation,
    order: &HashMap<String, usize>,
) -> Result<f64, PilotCalibrationError> {
    let score = observation.paired()?.score();
    let a_rank = order.get(&observation.a).ok_or_else(|| {
        PilotCalibrationError::InvalidDataset(format!(
            "prespecified order omitted {:?}",
            observation.a
        ))
    })?;
    let b_rank = order.get(&observation.b).ok_or_else(|| {
        PilotCalibrationError::InvalidDataset(format!(
            "prespecified order omitted {:?}",
            observation.b
        ))
    })?;
    Ok(if a_rank < b_rank { score } else { 1.0 - score })
}

fn matchup_key(a: u32, b: u32) -> (u32, u32) {
    if a < b {
        (a, b)
    } else {
        (b, a)
    }
}

fn ordered_matchups(roster: &[PilotSpec]) -> Vec<(u32, u32, String)> {
    let mut pairs = Vec::new();
    for i in 0..roster.len() {
        for j in (i + 1)..roster.len() {
            pairs.push((
                roster[i].id.0,
                roster[j].id.0,
                hypothesis_id(&roster[i], &roster[j]),
            ));
        }
    }
    pairs.sort_by_key(|pair| matchup_key(pair.0, pair.1));
    pairs
}

fn simultaneous_pair_scores(
    roster: &[PilotSpec],
    pool: &PilotCalibrationPool,
    order: &HashMap<String, usize>,
    config: BootstrapConfig,
) -> Result<SimultaneousBootstrapReport, PilotCalibrationError> {
    let pairs = ordered_matchups(roster);
    let positions: HashMap<(u32, u32), usize> = pairs
        .iter()
        .enumerate()
        .map(|(index, pair)| (matchup_key(pair.0, pair.1), index))
        .collect();
    let mut by_seed: BTreeMap<u64, Vec<Option<f64>>> = BTreeMap::new();
    for observation in &pool.observations {
        let index = *positions
            .get(&matchup_key(observation.a_id, observation.b_id))
            .ok_or_else(|| {
                PilotCalibrationError::InvalidDataset("unknown matchup in bootstrap".into())
            })?;
        let row = by_seed
            .entry(observation.seed)
            .or_insert_with(|| vec![None; pairs.len()]);
        row[index] = Some(oriented_score(observation, order)?);
    }
    let mut rows = Vec::with_capacity(by_seed.len());
    for (seed, values) in by_seed {
        let values = values
            .into_iter()
            .map(|value| {
                value.ok_or_else(|| {
                    PilotCalibrationError::InvalidDataset(format!(
                        "seed {seed} is missing a matchup"
                    ))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        rows.push(SeededMeasurements { seed, values });
    }
    let labels: Vec<String> = pairs.into_iter().map(|pair| pair.2).collect();
    Ok(experiment::bootstrap_simultaneous_means(
        &labels, &rows, config,
    )?)
}

fn pair_values(
    pool: &PilotCalibrationPool,
    a_id: u32,
    b_id: u32,
    order: &HashMap<String, usize>,
) -> Result<Vec<f64>, PilotCalibrationError> {
    pool.observations
        .iter()
        .filter(|observation| {
            matchup_key(observation.a_id, observation.b_id) == matchup_key(a_id, b_id)
        })
        .map(|observation| oriented_score(observation, order))
        .collect()
}

fn side_equivalence(
    pool: &PilotCalibrationPool,
    a_id: u32,
    b_id: u32,
    half_width: f64,
    alpha: f64,
) -> Result<TostResult, PilotCalibrationError> {
    let mut by_seed: BTreeMap<u64, (f64, usize)> = BTreeMap::new();
    for observation in pool.observations.iter().filter(|observation| {
        matchup_key(observation.a_id, observation.b_id) == matchup_key(a_id, b_id)
    }) {
        let pair = observation.paired()?;
        let value = pair.first_score - pair.mirrored_score;
        let row = by_seed.entry(observation.seed).or_insert((0.0, 0));
        row.0 += value;
        row.1 += 1;
    }
    let values: Vec<f64> = by_seed
        .into_values()
        .map(|(sum, count)| sum / count as f64)
        .collect();
    let test = experiment::paired_mean_test(&values, 0.0)?;
    Ok(experiment::tost_equivalence(
        test.estimate,
        test.standard_error,
        -half_width,
        half_width,
        alpha,
    )?)
}

fn certified_entries(
    roster: &[PilotSpec],
    fit: &BradleyTerryFit,
    prescribed_order: &HashMap<String, usize>,
) -> Result<Vec<CertifiedPilotEntry>, PilotCalibrationError> {
    let ids: HashMap<&str, u32> = roster
        .iter()
        .map(|pilot| (pilot.callsign.as_str(), pilot.id.0))
        .collect();
    let mut entries = Vec::with_capacity(fit.strengths.len());
    for strength in &fit.strengths {
        let pilot_id = *ids.get(strength.competitor.as_str()).ok_or_else(|| {
            PilotCalibrationError::InvalidDataset(format!(
                "fit contains unknown pilot {:?}",
                strength.competitor
            ))
        })?;
        entries.push(CertifiedPilotEntry {
            pilot_id,
            callsign: strength.competitor.clone(),
            elo: pilot_account_seed(strength.elo),
        });
    }
    entries.sort_by(|left, right| {
        prescribed_order[&right.callsign]
            .cmp(&prescribed_order[&left.callsign])
            .then_with(|| left.callsign.cmp(&right.callsign))
    });
    Ok(entries)
}

fn superiority_effect_from_manifest(
    manifest: &CalibrationManifest,
    hypothesis_id: &str,
) -> Result<f64, PilotCalibrationError> {
    let hypothesis = manifest
        .hypotheses
        .iter()
        .find(|hypothesis| hypothesis.id == hypothesis_id)
        .ok_or_else(|| {
            PilotCalibrationError::InvalidDataset(format!(
                "manifest omits superiority hypothesis {hypothesis_id:?}"
            ))
        })?;
    match hypothesis.kind {
        HypothesisKind::Superiority { minimum_effect } => Ok(minimum_effect),
        _ => Err(PilotCalibrationError::InvalidDataset(format!(
            "hypothesis {hypothesis_id:?} is not a superiority test"
        ))),
    }
}

fn superiority_effect(
    plan: &PilotCalibrationPlan,
    hypothesis_id: &str,
) -> Result<f64, PilotCalibrationError> {
    superiority_effect_from_manifest(&plan.manifest, hypothesis_id)
}

/// Analyze a completed tournament. This function is separate from collection
/// so tests and operators can audit a saved dataset without replaying matches.
pub fn analyze_pilot_calibration(
    roster: &[PilotSpec],
    plan: &PilotCalibrationPlan,
    dataset: &PilotCalibrationDataset,
) -> Result<PilotCalibrationReport, PilotCalibrationError> {
    validate_pilot_dataset(roster, plan, dataset)?;
    let development_pool = dataset_pool_for_role(dataset, SeedPoolRole::Development)?;
    let validation_pool = dataset_pool_for_role(dataset, SeedPoolRole::Validation)?;
    let final_pool = dataset_pool_for_role(dataset, SeedPoolRole::Holdout)?;
    let anchor = roster
        .iter()
        .find(|pilot| pilot.callsign == ai::ANCHOR)
        .unwrap_or(&roster[0]);
    let confidence = 1.0 - plan.manifest.alpha;
    let development = fit_phase(
        development_pool,
        &anchor.callsign,
        ai::ANCHOR_RATING,
        confidence,
    )?;
    let validation = fit_phase(
        validation_pool,
        &anchor.callsign,
        ai::ANCHOR_RATING,
        confidence,
    )?;
    let final_holdout = fit_phase(final_pool, &anchor.callsign, ai::ANCHOR_RATING, confidence)?;
    let order = prespecified_order(roster);
    let simultaneous = simultaneous_pair_scores(roster, final_pool, &order, plan.bootstrap)?;
    let intervals: HashMap<&str, _> = simultaneous
        .estimates
        .iter()
        .map(|estimate| (estimate.label.as_str(), estimate))
        .collect();

    let pairs = ordered_matchups(roster);
    let mut p_values = Vec::with_capacity(pairs.len());
    let mut tests = HashMap::new();
    for &(a_id, b_id, ref id) in &pairs {
        let values = pair_values(final_pool, a_id, b_id, &order)?;
        let minimum_effect = superiority_effect(plan, id)?;
        let test = experiment::paired_mean_test(&values, 0.5 + minimum_effect)?;
        p_values.push(ContrastPValue {
            hypothesis: id.clone(),
            raw_p: test.greater_p,
        });
        tests.insert(id.clone(), test);
    }
    // Each matchup owns one superiority claim and one side-equivalence claim.
    // Holm spends the superiority half of family alpha; every TOST gets its
    // own Bonferroni share from the other half.
    let pairwise_family_alpha =
        plan.manifest.alpha * plan.matchups as f64 / plan.manifest.hypotheses.len() as f64;
    let adjusted = experiment::holm_adjust(&p_values, pairwise_family_alpha)?;
    let holm: HashMap<&str, &HolmContrast> = adjusted
        .iter()
        .map(|decision| (decision.hypothesis.as_str(), decision))
        .collect();

    let known: HashMap<u32, &PilotSpec> = roster.iter().map(|pilot| (pilot.id.0, pilot)).collect();
    let mut pairwise = Vec::with_capacity(pairs.len());
    for &(a_id, b_id, ref id) in &pairs {
        let a = known[&a_id];
        let b = known[&b_id];
        let a_is_stronger = order[&a.callsign] < order[&b.callsign];
        let (stronger, weaker) = if a_is_stronger { (a, b) } else { (b, a) };
        let validation_values = pair_values(validation_pool, a_id, b_id, &order)?;
        let validation_score =
            validation_values.iter().sum::<f64>() / validation_values.len() as f64;
        let test = &tests[id];
        let interval = intervals[id.as_str()];
        let decision = holm[id.as_str()];
        let minimum_superiority_margin = superiority_effect(plan, id)?;
        let superiority_threshold = 0.5 + minimum_superiority_margin;
        let simultaneous_clears_threshold = interval.low > superiority_threshold;
        pairwise.push(PilotPairwiseDecision {
            hypothesis_id: id.clone(),
            stronger: stronger.callsign.clone(),
            weaker: weaker.callsign.clone(),
            validation_score,
            final_score: test.estimate,
            minimum_superiority_margin,
            superiority_threshold,
            simultaneous_low: interval.low,
            simultaneous_high: interval.high,
            raw_p: decision.raw_p,
            adjusted_p: decision.adjusted_p,
            simultaneous_clears_threshold,
            significant: decision.rejected
                && test.estimate > superiority_threshold
                && simultaneous_clears_threshold,
        });
    }

    let equivalence_alpha = plan.manifest.alpha / plan.manifest.hypotheses.len() as f64;
    let mut side_equivalences = Vec::with_capacity(pairs.len());
    for &(a_id, b_id, ref pair_id) in &pairs {
        let hypothesis_id = format!("{pair_id}-side-equivalence");
        let side_half_width = plan
            .manifest
            .hypotheses
            .iter()
            .find_map(|hypothesis| match hypothesis.kind {
                HypothesisKind::Equivalence { lower, upper } if hypothesis.id == hypothesis_id => {
                    Some((upper - lower) / 2.0)
                }
                _ => None,
            })
            .ok_or_else(|| {
                PilotCalibrationError::InvalidDataset(format!("manifest omits {hypothesis_id}"))
            })?;
        side_equivalences.push(PilotSideEquivalence {
            hypothesis_id,
            a: known[&a_id].callsign.clone(),
            b: known[&b_id].callsign.clone(),
            validation: side_equivalence(
                validation_pool,
                a_id,
                b_id,
                side_half_width,
                equivalence_alpha,
            )?,
            final_holdout: side_equivalence(
                final_pool,
                a_id,
                b_id,
                side_half_width,
                equivalence_alpha,
            )?,
        });
    }

    let mut reasons = Vec::new();
    if plan.request.attempt_id == "exploratory" {
        reasons.push("the default exploratory attempt cannot spend a release holdout".into());
    }
    let required = plan
        .power
        .required_pairs
        .max(plan.side_power.required_pairs);
    if plan.requested_pairs_per_matchup_per_pool < required {
        reasons.push(format!(
            "{} paired scenarios were run per pool; the plan requires {}",
            plan.requested_pairs_per_matchup_per_pool, required
        ));
    }
    if !development.fit.converged || !validation.fit.converged || !final_holdout.fit.converged {
        reasons.push("at least one Bradley-Terry fit did not converge".into());
    }
    let side_validation_failures = side_equivalences
        .iter()
        .filter(|decision| decision.validation.verdict != EquivalenceVerdict::Equivalent)
        .count();
    if side_validation_failures > 0 {
        reasons.push(format!(
            "validation did not establish mirrored-side equivalence for {side_validation_failures} matchups"
        ));
    }
    let side_holdout_failures = side_equivalences
        .iter()
        .filter(|decision| decision.final_holdout.verdict != EquivalenceVerdict::Equivalent)
        .count();
    if side_holdout_failures > 0 {
        reasons.push(format!(
            "the final holdout did not establish mirrored-side equivalence for {side_holdout_failures} matchups"
        ));
    }
    let validation_failures = pairwise
        .iter()
        .filter(|decision| decision.validation_score <= decision.superiority_threshold)
        .count();
    if validation_failures > 0 {
        reasons.push(format!(
            "{validation_failures} prespecified matchups did not clear the declared superiority threshold in validation"
        ));
    }
    let unresolved = pairwise
        .iter()
        .filter(|decision| !decision.significant)
        .count();
    if unresolved > 0 {
        reasons.push(format!(
            "{unresolved} pilot distinctions did not clear the minimum effect with Holm correction and a simultaneous interval"
        ));
    }
    let censored_legs = dataset
        .pools
        .iter()
        .flat_map(|pool| &pool.observations)
        .map(|observation| {
            usize::from(observation.first.censored) + usize::from(observation.mirrored.censored)
        })
        .sum::<usize>();
    if censored_legs > 0 {
        reasons.push(format!(
            "{censored_legs} legs reached the prespecified overtime censoring boundary"
        ));
    }
    let status = if plan.exploratory {
        PilotCalibrationStatus::Exploratory
    } else if reasons.is_empty() {
        PilotCalibrationStatus::Certified
    } else {
        PilotCalibrationStatus::Uncertified
    };
    let certified_ladder = if status == PilotCalibrationStatus::Certified {
        Some(certified_entries(roster, &final_holdout.fit, &order)?)
    } else {
        None
    };
    Ok(PilotCalibrationReport {
        request: plan.request.clone(),
        dataset_fingerprint: pilot_dataset_fingerprint(dataset)?,
        manifest: plan.manifest.clone(),
        fixture: plan.fixture.clone(),
        power: plan.power,
        side_power: plan.side_power,
        bootstrap: plan.bootstrap,
        status,
        reasons,
        development,
        validation,
        final_holdout,
        simultaneous_pair_intervals: simultaneous,
        pairwise_family_alpha,
        pairwise,
        side_equivalence: side_equivalences,
        certified_ladder,
    })
}

/// Plan, collect, and analyze a pilot tournament.
#[allow(
    dead_code,
    reason = "report-only compatibility API for focused calibration callers"
)]
pub fn run_pilot_calibration(
    roster: &[PilotSpec],
    request: &PilotCalibrationRequest,
    verbose: bool,
) -> Result<PilotCalibrationReport, PilotCalibrationError> {
    run_pilot_calibration_with_dataset(roster, request, verbose).map(|(report, _)| report)
}

/// Plan, collect, and analyze a tournament while retaining its raw mirrored
/// observations for a separate audit artifact.
#[allow(
    dead_code,
    reason = "convenience API for callers that do not persist data before analysis"
)]
pub fn run_pilot_calibration_with_dataset(
    roster: &[PilotSpec],
    request: &PilotCalibrationRequest,
    verbose: bool,
) -> Result<(PilotCalibrationReport, PilotCalibrationDataset), PilotCalibrationError> {
    let plan = plan_pilot_calibration(roster, request)?;
    let dataset = collect_pilot_calibration(roster, &plan, verbose)?;
    let report = analyze_pilot_calibration(roster, &plan, &dataset)?;
    Ok((report, dataset))
}

#[cfg(test)]
mod pilot_certification_tests {
    use super::*;

    fn two_pilots() -> Vec<PilotSpec> {
        vec![pilots::individual(0), pilots::individual(1)]
    }

    fn quick_request() -> PilotCalibrationRequest {
        PilotCalibrationRequest {
            paired_scenarios_per_pool: 2,
            bootstrap_replicates: 100,
            ..PilotCalibrationRequest::default()
        }
    }

    fn completed_leg(
        assignment: PilotMirrorAssignment,
        a_id: u32,
        b_id: u32,
        score: f64,
    ) -> PilotLegResult {
        let (a_kills, b_kills, victim_id, killer_id, mutual_death) = if score == 1.0 {
            (1, 0, Some(b_id), Some(a_id), false)
        } else if score == 0.0 {
            (0, 1, Some(a_id), Some(b_id), false)
        } else {
            assert_eq!(score, 0.5, "synthetic legs use a win, draw, or loss");
            (1, 1, None, None, true)
        };
        PilotLegResult {
            a_side: assignment.side,
            a_start: assignment.start,
            a_heading: assignment.heading,
            a_kills,
            b_kills,
            ticks: 1_000,
            a_score: score,
            victim_id,
            killer_id,
            mutual_death,
            reached_overtime: false,
            censored: false,
        }
    }

    #[derive(Clone, Copy)]
    enum SyntheticPattern {
        Tied,
        NearChance,
        Strong,
    }

    fn synthetic_dataset(
        roster: &[PilotSpec],
        plan: &PilotCalibrationPlan,
        pattern: SyntheticPattern,
    ) -> PilotCalibrationDataset {
        let mut pools = Vec::new();
        let prescribed = prespecified_order(roster);
        for pool in &plan.manifest.seed_pools {
            let near_chance_wins = ((pool.count as f64) * 0.55).round() as usize;
            let mut observations = Vec::new();
            for offset in 0..pool.count {
                let seed = pool.first_seed + offset as u64;
                let indices =
                    pilots::ladder_start_pair(pool.namespace, seed, plan.fixture.starts_per_team)
                        .expect("fixture starts");
                let starts = plan
                    .fixture
                    .start_pairs
                    .iter()
                    .find(|pair| pair.indices == indices)
                    .expect("selected fixture pair");
                let assignments = pilot_mirror_assignments(
                    &roster[0],
                    &roster[1],
                    starts.indices,
                    starts.positions,
                );
                let first_a = assignments[0]
                    .iter()
                    .find(|assignment| assignment.pilot_id == roster[0].id.0)
                    .copied()
                    .expect("first subject");
                let mirrored_a = assignments[1]
                    .iter()
                    .find(|assignment| assignment.pilot_id == roster[0].id.0)
                    .copied()
                    .expect("mirrored subject");
                let score = match pattern {
                    SyntheticPattern::Tied => 0.5,
                    SyntheticPattern::NearChance if offset < near_chance_wins => 1.0,
                    SyntheticPattern::NearChance => 0.0,
                    SyntheticPattern::Strong => {
                        if prescribed[&roster[0].callsign] < prescribed[&roster[1].callsign] {
                            1.0
                        } else {
                            0.0
                        }
                    }
                };
                observations.push(PilotMatchupObservation {
                    pool: pool.name.clone(),
                    seed,
                    a_id: roster[0].id.0,
                    a: roster[0].callsign.clone(),
                    b_id: roster[1].id.0,
                    b: roster[1].callsign.clone(),
                    fixture_fingerprint: plan.fixture.fixture_fingerprint.clone(),
                    start_indices: starts.indices,
                    start_positions: starts.positions,
                    first: completed_leg(first_a, roster[0].id.0, roster[1].id.0, score),
                    mirrored: completed_leg(mirrored_a, roster[0].id.0, roster[1].id.0, score),
                });
            }
            pools.push(PilotCalibrationPool {
                name: pool.name.clone(),
                role: pool.role,
                observations,
            });
        }
        PilotCalibrationDataset { pools }
    }

    fn powered_plan(roster: &[PilotSpec]) -> PilotCalibrationPlan {
        let mut request = PilotCalibrationRequest::default();
        let provisional = plan_pilot_calibration(roster, &request).expect("a provisional plan");
        request.attempt_id = "test-release".into();
        request.paired_scenarios_per_pool = provisional
            .power
            .required_pairs
            .max(provisional.side_power.required_pairs)
            .max(2);
        let plan = plan_pilot_calibration(roster, &request).expect("a powered plan");
        assert!(!plan.exploratory);
        plan
    }

    #[test]
    fn a_pair_exchanges_pilots_sides_starts_and_headings() {
        let roster = two_pilots();
        let positions = [[10, 20], [110, 20]];
        let legs = pilot_mirror_assignments(&roster[0], &roster[1], [1, 3], positions);
        let first_a = legs[0]
            .iter()
            .find(|seat| seat.pilot_id == roster[0].id.0)
            .expect("pilot a in the first leg");
        let mirror_a = legs[1]
            .iter()
            .find(|seat| seat.pilot_id == roster[0].id.0)
            .expect("pilot a in the mirror");
        assert_ne!(first_a.side, mirror_a.side);
        assert_ne!(first_a.start, mirror_a.start);
        assert_ne!(first_a.heading, mirror_a.heading);

        let first_b = legs[0]
            .iter()
            .find(|seat| seat.pilot_id == roster[1].id.0)
            .expect("pilot b in the first leg");
        let mirror_b = legs[1]
            .iter()
            .find(|seat| seat.pilot_id == roster[1].id.0)
            .expect("pilot b in the mirror");
        assert_ne!(first_b.side, mirror_b.side);
        assert_ne!(first_b.start, mirror_b.start);
        assert_ne!(first_b.heading, mirror_b.heading);
    }

    #[test]
    fn mutual_deaths_are_draws_regardless_of_event_order() {
        let forward = [(4, 9), (9, 4)];
        let reverse = [(9, 4), (4, 9)];
        assert_eq!(death_tick_score(&forward, 4, 9), Some(0.5));
        assert_eq!(death_tick_score(&reverse, 4, 9), Some(0.5));
        assert_eq!(death_tick_score(&[(9, 4)], 4, 9), Some(1.0));
        assert_eq!(death_tick_score(&[(4, 9)], 4, 9), Some(0.0));
    }

    #[test]
    fn power_gate_and_seed_pools_are_fixed_before_collection() {
        let roster = two_pilots();
        let plan = plan_pilot_calibration(&roster, &quick_request()).expect("a plan");
        assert!(plan.power.request.power >= 0.90);
        assert!(plan.power.required_pairs > plan.requested_pairs_per_matchup_per_pool);
        assert!(plan.exploratory);

        let development =
            pool_manifest_for_role(&plan, SeedPoolRole::Development).expect("development seeds");
        let validation =
            pool_manifest_for_role(&plan, SeedPoolRole::Validation).expect("validation seeds");
        let holdout = pool_manifest_for_role(&plan, SeedPoolRole::Holdout).expect("holdout seeds");
        let development_end = development.first_seed + development.count as u64;
        let validation_end = validation.first_seed + validation.count as u64;
        assert!(development_end <= validation.first_seed);
        assert!(validation_end <= holdout.first_seed);
    }

    #[test]
    fn fixture_is_single_life_personal_and_cycles_every_drydock_start_pair() {
        let roster = pilots::roster();
        let plan = plan_pilot_calibration(&roster, &quick_request()).expect("a plan");
        assert_eq!(plan.fixture.first_to, 1);
        assert_eq!(plan.fixture.regulation_ticks, 18_000);
        assert_eq!(plan.fixture.starts_per_team, [4, 4]);
        assert_eq!(plan.fixture.start_pairs.len(), 16);
        assert_eq!(plan.power.request.family_hypotheses, 56);
        assert_eq!(plan.side_power.request.family_hypotheses, 56);
        assert_eq!(plan.side_power.request.independent_confirmatory_gates, 112);
        assert!(plan.power.required_pairs > 1_950);
        assert!(plan.side_power.required_pairs > plan.power.required_pairs);

        let mut sampled = HashSet::new();
        for seed in 0..16 {
            sampled.insert(
                pilots::ladder_start_pair(0x5151, seed, plan.fixture.starts_per_team)
                    .expect("a start pair"),
            );
        }
        assert_eq!(sampled.len(), 16);
        for pair in &plan.fixture.start_pairs {
            for position in pair.positions {
                for coordinate in position {
                    assert_eq!(
                        coordinate.rem_euclid(sim::TILE_PX * 256),
                        sim::TILE_PX * 128,
                        "spawn points use the tile center"
                    );
                }
            }
        }
        let ceiling: [u8; sim::SLOT_COUNT] = plan
            .fixture
            .effective_zone_entitlement_ceiling
            .clone()
            .try_into()
            .expect("fixture ceiling width");
        let mut tastes = HashSet::new();
        for pilot in &roster {
            let recorded = plan
                .fixture
                .pilot_kits
                .iter()
                .find(|kit| kit.pilot_id == pilot.id.0)
                .expect("pilot kit");
            let expected = shopper::build(&shopper::wants(&pilot.behavior), &ceiling);
            assert_eq!(recorded.kit, expected);
            tastes.insert(recorded.strategy.as_str());
        }
        assert!(tastes.len() > 1, "the fixture contains personal tastes");
    }

    #[test]
    fn a_runtime_catalog_must_match_the_certified_fixture() {
        let roster = pilots::roster();
        let plan = plan_pilot_calibration(&roster, &quick_request()).expect("a plan");
        let text = std::str::from_utf8(PILOT_ZONE_BYTES).expect("the Ladder zone is text");
        let definition: crate::catalog::ZoneDef =
            toml::from_str(text).expect("the Ladder zone parses");
        let exact = crate::fleet::WireZone {
            name: PILOT_ZONE.into(),
            mode: definition.mode.clone(),
            max_ships: definition.max_ships.unwrap_or(64),
            max_players: definition.max_players() as u32,
            fill_target: definition.fill_target() as u32,
            bot_fill: definition.bot_fill(),
            max_rooms: definition.max_rooms() as u32,
            admission: definition.admission.clone(),
            maps_b64: vec![crate::fleet::b64(PILOT_MAP_BYTES)],
            map_names: vec![PILOT_MAP.into()],
            zone_toml: text.into(),
        };
        assert!(runtime_pilot_fixture_matches(&plan.fixture, &exact));

        let mut changed_zone = exact.clone();
        changed_zone.zone_toml.push('\n');
        assert!(!runtime_pilot_fixture_matches(&plan.fixture, &changed_zone));

        let mut changed_map = exact.clone();
        let mut map = PILOT_MAP_BYTES.to_vec();
        map[0] ^= 1;
        changed_map.maps_b64[0] = crate::fleet::b64(&map);
        assert!(!runtime_pilot_fixture_matches(&plan.fixture, &changed_map));

        // Served admission has to agree with the zone file it claims to be
        // serving. The shipped Ladder admits anybody, so the mutation that has
        // to be caught is a fleet quietly shutting the door.
        let mut changed_policy = exact;
        changed_policy.admission = "claimed".into();
        assert!(!runtime_pilot_fixture_matches(
            &plan.fixture,
            &changed_policy
        ));
    }

    #[test]
    fn a_pilot_leg_restarts_with_full_bars_on_its_seeded_starts() {
        let roster = pilots::roster();
        let fixture = load_pilot_fixture(&roster).expect("the live Ladder fixture");
        let pair = fixture.manifest.start_pairs[5];
        let specs = [&roster[0], &roster[1]];
        let mut world = sim::World::from_packed(7, &fixture.map).expect("Drydock");
        assert!(crate::Room::apply_config(&mut world, &fixture.definition.arena).is_empty());
        world.cfg.max_ships = 2;
        let positions = [
            (pair.positions[0][0], pair.positions[0][1]),
            (pair.positions[1][0], pair.positions[1][1]),
        ];
        let ships = [
            world.spawn_at(specs[0].hull, 0, positions[0].0, positions[0].1, 0) as u8,
            world.spawn_at(specs[1].hull, 1, positions[1].0, positions[1].1, 32768) as u8,
        ];
        for index in 0..2 {
            let kit = shopper::build(
                &shopper::wants(&specs[index].behavior),
                &fixture.effective_entitlement_ceiling,
            );
            assert!(world.set_kit(ships[index] as usize, &kit));
        }

        restart_pilot_leg(&mut world, ships, positions);
        let headings = [
            crate::room::heading_toward(positions[0], positions[1]),
            crate::room::heading_toward(positions[1], positions[0]),
        ];

        for index in 0..2 {
            let row = &world.state.ships[ships[index] as usize];
            assert_eq!(row.energy, world.eff_max_energy(ships[index] as usize));
            assert_eq!((row.x, row.y), positions[index]);
            assert_eq!((row.spawn_x, row.spawn_y), positions[index]);
            assert_eq!(row.heading, headings[index]);
        }
    }

    #[test]
    fn an_underpowered_run_cannot_return_a_ladder() {
        let roster = two_pilots();
        let plan = plan_pilot_calibration(&roster, &quick_request()).expect("a plan");
        let dataset = synthetic_dataset(&roster, &plan, SyntheticPattern::Tied);
        let report = analyze_pilot_calibration(&roster, &plan, &dataset).expect("a report");
        assert_eq!(report.status, PilotCalibrationStatus::Exploratory);
        assert!(report.certified_ladder.is_none());
        assert!(report
            .reasons
            .iter()
            .any(|reason| reason.contains("plan requires")));
        assert_eq!(report.final_holdout.fit.matchup_matrix[0].score_a, 0.5);
        assert_eq!(report.fixture, plan.fixture);
        let serialized = serde_json::to_value(&report).expect("a serializable report");
        assert_eq!(
            serialized["fixture"]["fixture_fingerprint"],
            report.fixture.fixture_fingerprint
        );
    }

    #[test]
    fn powered_ties_and_near_chance_results_are_not_certified() {
        let roster = two_pilots();
        let plan = powered_plan(&roster);
        for pattern in [SyntheticPattern::Tied, SyntheticPattern::NearChance] {
            let dataset = synthetic_dataset(&roster, &plan, pattern);
            let report = analyze_pilot_calibration(&roster, &plan, &dataset).expect("a report");
            assert_eq!(report.status, PilotCalibrationStatus::Uncertified);
            assert!(report.certified_ladder.is_none());
            assert_eq!(
                report.pairwise[0].superiority_threshold,
                0.5 + plan.request.minimum_superiority_margin
            );
            assert!(!report.pairwise[0].significant);
            assert!(
                report.pairwise[0].simultaneous_low <= report.pairwise[0].superiority_threshold
            );
        }
    }

    #[test]
    fn censoring_and_fixture_metadata_cannot_pass_as_certifying_data() {
        let roster = two_pilots();
        let plan = powered_plan(&roster);
        let mut censored = synthetic_dataset(&roster, &plan, SyntheticPattern::Tied);
        let total_ticks = plan
            .fixture
            .regulation_ticks
            .saturating_add(plan.fixture.overtime_safety_ticks);
        let leg = &mut censored.pools[0].observations[0].first;
        leg.mutual_death = false;
        leg.censored = true;
        leg.ticks = total_ticks;
        leg.reached_overtime = true;
        let report = analyze_pilot_calibration(&roster, &plan, &censored).expect("a report");
        assert_eq!(report.status, PilotCalibrationStatus::Uncertified);
        assert!(report
            .reasons
            .iter()
            .any(|reason| reason.contains("censoring boundary")));

        let mut wrong_fixture = synthetic_dataset(&roster, &plan, SyntheticPattern::Tied);
        wrong_fixture.pools[0].observations[0].fixture_fingerprint = "sha256:wrong".into();
        assert!(matches!(
            analyze_pilot_calibration(&roster, &plan, &wrong_fixture),
            Err(PilotCalibrationError::InvalidDataset(message))
                if message.contains("fixture fingerprint")
        ));

        let mut wrong_start = synthetic_dataset(&roster, &plan, SyntheticPattern::Tied);
        wrong_start.pools[0].observations[0].start_indices[0] ^= 1;
        assert!(matches!(
            analyze_pilot_calibration(&roster, &plan, &wrong_start),
            Err(PilotCalibrationError::InvalidDataset(message))
                if message.contains("start metadata")
        ));
    }

    #[test]
    fn current_report_gate_rejects_uncertified_forged_and_stale_reports() {
        let roster = two_pilots();
        let plan = powered_plan(&roster);
        let dataset = synthetic_dataset(&roster, &plan, SyntheticPattern::Tied);
        let mut report = analyze_pilot_calibration(&roster, &plan, &dataset).expect("a report");
        assert!(!verified_current_report(&report, &roster).expect("a valid report"));

        report.status = PilotCalibrationStatus::Certified;
        report.reasons.clear();
        assert!(!verified_current_report(&report, &roster).expect("a forged status is rejected"));

        report.manifest.controller_fingerprint = "sha256:stale-controller".into();
        assert!(!verified_current_report(&report, &roster).expect("a stale report is rejected"));
        assert!(!finite_interval(f64::NAN, 0.0, 1.0));
        assert!(!finite_interval(1_200.0, f64::NEG_INFINITY, f64::INFINITY));
    }

    #[test]
    fn current_report_gate_pins_the_release_power_policy() {
        let release = PilotCalibrationRequest {
            attempt_id: "release-test".into(),
            ..PilotCalibrationRequest::default()
        };
        assert!(meets_pilot_release_policy(&release));

        for weak in [
            PilotCalibrationRequest {
                alpha: 0.50,
                ..release.clone()
            },
            PilotCalibrationRequest {
                minimum_superiority_margin: 0.25,
                superiority_design_increment: 0.10,
                side_equivalence_half_width: 0.25,
                ..release.clone()
            },
            PilotCalibrationRequest {
                paired_variance: f64::EPSILON,
                ..release.clone()
            },
            PilotCalibrationRequest {
                side_paired_variance: 0.25,
                ..release.clone()
            },
            PilotCalibrationRequest {
                attempt_id: "exploratory".into(),
                ..release.clone()
            },
        ] {
            assert!(!meets_pilot_release_policy(&weak));
        }
        assert!(!meets_pilot_release_policy(&PilotCalibrationRequest {
            bootstrap_replicates: release.bootstrap_replicates - 1,
            ..release
        }));
    }

    #[test]
    fn a_confirmatory_attempt_binds_the_exact_sample_count() {
        let roster = two_pilots();
        let exploratory = plan_pilot_calibration(&roster, &PilotCalibrationRequest::default())
            .expect("an exploratory plan");
        let required = exploratory
            .power
            .required_pairs
            .max(exploratory.side_power.required_pairs);
        let exact = PilotCalibrationRequest {
            attempt_id: "release-exact-count".into(),
            paired_scenarios_per_pool: required,
            ..PilotCalibrationRequest::default()
        };
        assert!(plan_pilot_calibration(&roster, &exact).is_ok());

        let retry = PilotCalibrationRequest {
            paired_scenarios_per_pool: required + 1,
            ..exact
        };
        assert!(matches!(
            plan_pilot_calibration(&roster, &retry),
            Err(PilotCalibrationError::InvalidRequest(message))
                if message.contains("exactly")
        ));
    }

    #[test]
    fn current_evidence_is_bound_to_every_raw_observation() {
        let roster = two_pilots();
        let plan = powered_plan(&roster);
        let dataset = synthetic_dataset(&roster, &plan, SyntheticPattern::Strong);
        let report = analyze_pilot_calibration(&roster, &plan, &dataset).expect("a report");
        assert_eq!(report.status, PilotCalibrationStatus::Certified);
        assert!(verified_current_report(&report, &roster).expect("a current report"));
        assert_eq!(
            report.dataset_fingerprint,
            pilot_dataset_fingerprint(&dataset).expect("a dataset digest")
        );
        assert_eq!(
            analyze_pilot_calibration(&roster, &plan, &dataset).expect("repeat analysis"),
            report
        );
        assert!(verified_current_evidence(&report, &dataset, &roster).expect("valid evidence"));

        let registry = serde_json::to_string(&PilotCalibrationAttemptRegistry {
            schema_version: 1,
            attempts: vec![PilotCalibrationAttempt {
                attempt_id: plan.request.attempt_id.clone(),
                design_fingerprint: pilot_design_fingerprint(&plan).expect("a design digest"),
            }],
        })
        .expect("a registry");
        let signing_key = SigningKey::from_bytes(&[41; 32]);
        let attestation =
            attest_pilot_calibration(&report, &dataset, &roster, &registry, &signing_key)
                .expect("attestation analysis")
                .expect("a certified attestation");
        assert!(attestation.certified_ladder.iter().all(|entry| {
            (ai::ANCHOR_RATING - PILOT_ACCOUNT_SEED_RADIUS
                ..=ai::ANCHOR_RATING + PILOT_ACCOUNT_SEED_RADIUS)
                .contains(&entry.elo)
        }));
        assert!(verified_current_attestation(
            &attestation,
            &roster,
            &registry,
            &signing_key.verifying_key()
        )
        .expect("a current attestation"));
        let retry_registry = serde_json::to_string(&PilotCalibrationAttemptRegistry {
            schema_version: 1,
            attempts: vec![
                PilotCalibrationAttempt {
                    attempt_id: plan.request.attempt_id.clone(),
                    design_fingerprint: attestation.design_fingerprint.clone(),
                },
                PilotCalibrationAttempt {
                    attempt_id: "optional-retry".into(),
                    design_fingerprint: attestation.design_fingerprint.clone(),
                },
            ],
        })
        .expect("a retry registry");
        assert!(!verified_current_attestation(
            &attestation,
            &roster,
            &retry_registry,
            &signing_key.verifying_key()
        )
        .expect("optional retries are rejected"));

        let mut reordered = attestation.clone();
        reordered.certified_ladder.reverse();
        assert!(!verified_current_attestation(
            &reordered,
            &roster,
            &registry,
            &signing_key.verifying_key()
        )
        .expect("a reordered release is rejected"));

        let mut changed_data = dataset.clone();
        changed_data.pools[0].observations[0].first.ticks += 1;
        assert!(!verified_current_evidence(&report, &changed_data, &roster)
            .expect("changed raw evidence is rejected"));

        let mut changed_report = report.clone();
        changed_report.final_holdout.fit.matchup_matrix[0].score_a = 0.99;
        assert!(
            !verified_current_evidence(&changed_report, &dataset, &roster)
                .expect("changed analysis is rejected")
        );
    }
}

/// Run a long-form calibration measurement by name.
pub fn run_diagnostic(name: &str) -> Result<(), String> {
    match name {
        "calibration-ladder" => diagnostic_calibration_ladder(),
        "skill-ladder" => skill_tests::skill_alone_should_make_a_ladder(),
        "real-map" => real_map_tests::skill_on_a_real_map(),
        "time-bout" => real_map_tests::time_one_real_map_bout(),
        "ablation" => ablation::which_knob_carries_the_dial(),
        "stability" => stability::is_the_built_ladder_a_measurement(),
        "draws" => draws::what_a_draw_is_made_of(),
        "fixture" => fixture::what_the_coin_is_weighted_by(),
        "kit" => kit::the_kit_is_matched_and_real(),
        _ => {
            return Err(format!(
                "unknown diagnostic {name:?}; choose calibration-ladder, skill-ladder, \
                 real-map, time-bout, ablation, stability, draws, fixture, or kit"
            ));
        }
    }
    Ok(())
}

fn diagnostic_calibration_ladder() {
    let roster = vec![
        ai::RosterEntry {
            name: "low".into(),
            class: 0,
            skill: 0.15,
        },
        ai::RosterEntry {
            name: "mid".into(),
            class: 0,
            skill: 0.50,
        },
        ai::RosterEntry {
            name: "high".into(),
            class: 0,
            skill: 0.95,
        },
    ];
    let result = run_roster(&roster, 300, false);
    let (low, middle, high) = (
        result.rating_of("low"),
        result.rating_of("mid"),
        result.rating_of("high"),
    );
    println!("  0.15 {low:.0}, 0.50 {middle:.0}, 0.95 {high:.0}");
    assert!(
        high - low >= 30.0,
        "0.95 should outrank 0.15 by 30 or more, and reads {high:.0} against \
         {low:.0} (0.50 on {middle:.0})"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn powered_profile_maps() -> Vec<(String, Arena)> {
        PROFILE_POWERED_MAPS
            .iter()
            .zip(PROFILE_POWERED_MAP_BYTES)
            .map(|(name, bytes)| {
                (
                    (*name).into(),
                    Arena::Packed(std::sync::Arc::new(bytes.into())),
                )
            })
            .collect()
    }

    #[test]
    fn profile_balance_requires_the_declared_sample_and_whole_interval() {
        assert_eq!(
            profile_verdict(false, true, 0.60, 0.70),
            "exploratory: not prespecified sample"
        );
        assert_eq!(
            profile_verdict(false, false, 0.46, 0.54),
            "exploratory: fixture checks failed"
        );
        assert_eq!(profile_verdict(true, false, 0.46, 0.54), "invalid fixture");
        assert_eq!(profile_verdict(true, true, 0.56, 0.63), "overpowered");
        assert_eq!(profile_verdict(true, true, 0.46, 0.54), "balanced");
        assert_eq!(profile_verdict(true, true, 0.44, 0.56), "inconclusive");
    }

    #[test]
    fn profile_family_matches_its_prespecified_correction() {
        let contrasts = profiles::calibration_contrasts();
        assert_eq!(contrasts.len(), PROFILE_COMPARISONS);
        assert!(contrasts.len() < PROFILE_PLANNING_COMPARISONS);

        let half_width = (PROFILE_BALANCE_HIGH - PROFILE_BALANCE_LOW) / 2.0;
        let raw = PROFILE_WORST_VARIANCE * (PROFILE_FAMILY_T + PROFILE_POWER_Z).powi(2)
            / half_width.powi(2);
        let maps = PROFILE_POWERED_MAPS.len() as u32;
        let map_stratified = (raw.ceil() as u32).div_ceil(maps) * maps;
        assert_eq!(map_stratified, PROFILE_POWER_MINIMUM_PAIRS);
        let full_block = profile_stratification_block(PROFILE_POWERED_MAPS.len());
        let fixture_stratified = PROFILE_POWER_MINIMUM_PAIRS.div_ceil(full_block) * full_block;
        assert_eq!(fixture_stratified, PROFILE_POWERED_PAIRS);
        assert_eq!(PROFILE_POWERED_PAIRS % full_block, 0);

        let conservative_joint_power = 1.0
            - (1.0 - PROFILE_JOINT_POWER) * PROFILE_COMPARISONS as f64
                / PROFILE_PLANNING_COMPARISONS as f64;
        assert!(conservative_joint_power >= PROFILE_JOINT_POWER);
    }

    #[test]
    fn only_the_frozen_melee_fixture_can_issue_a_profile_verdict() {
        let zone_source = std::str::from_utf8(PROFILE_POWERED_ZONE).expect("zone source");
        let definition: catalog::ZoneDef = toml::from_str(zone_source).expect("shipped zone");
        let maps = powered_profile_maps();
        assert!(is_powered_profile_fixture(
            PROFILE_POWERED_PAIRS,
            "melee",
            zone_source,
            0.50,
            &definition.arena,
            &maps
        ));
        assert!(!is_powered_profile_fixture(
            PROFILE_POWERED_PAIRS - 6,
            "melee",
            zone_source,
            0.50,
            &definition.arena,
            &maps
        ));
        assert!(!is_powered_profile_fixture(
            PROFILE_POWERED_PAIRS,
            "ladder",
            zone_source,
            0.50,
            &definition.arena,
            &maps
        ));
        assert!(!is_powered_profile_fixture(
            PROFILE_POWERED_PAIRS,
            "melee",
            "label = 'changed'",
            0.50,
            &definition.arena,
            &maps
        ));
        assert!(!is_powered_profile_fixture(
            PROFILE_POWERED_PAIRS,
            "melee",
            zone_source,
            0.49,
            &definition.arena,
            &maps
        ));
        let mut changed_maps = maps.clone();
        changed_maps[0].1 = Arena::Built(sim::build_pit);
        assert!(!is_powered_profile_fixture(
            PROFILE_POWERED_PAIRS,
            "melee",
            zone_source,
            0.50,
            &definition.arena,
            &changed_maps
        ));
        let short = config::ArenaConfig {
            match_seconds: Some(179),
            ..Default::default()
        };
        assert!(!is_powered_profile_fixture(
            PROFILE_POWERED_PAIRS,
            "melee",
            zone_source,
            0.50,
            &short,
            &maps
        ));
    }

    #[test]
    fn powered_profile_attempt_is_preregistered_before_collection() {
        let zone_source = std::str::from_utf8(PROFILE_POWERED_ZONE).expect("zone source");
        let maps = powered_profile_maps();
        let design =
            profile_design_fingerprint(PROFILE_POWERED_PAIRS, "melee", zone_source, 0.50, &maps)
                .expect("a design fingerprint");
        let empty_registry = serde_json::to_string(&ProfileCalibrationAttemptRegistry {
            schema_version: 1,
            attempts: Vec::new(),
        })
        .expect("an empty registry");
        let error = prepare_profile_calibration(
            PROFILE_POWERED_PAIRS,
            "flight-eight-v1",
            &empty_registry,
            "melee",
            zone_source,
            0.50,
            &maps,
        )
        .unwrap_err();
        assert!(error.contains(&design));

        let registry = serde_json::to_string(&ProfileCalibrationAttemptRegistry {
            schema_version: 1,
            attempts: vec![ProfileCalibrationAttempt {
                attempt_id: "flight-eight-v1".into(),
                design_fingerprint: design.clone(),
            }],
        })
        .expect("a registry");

        let run = prepare_profile_calibration(
            PROFILE_POWERED_PAIRS,
            "flight-eight-v1",
            &registry,
            "melee",
            zone_source,
            0.50,
            &maps,
        )
        .expect("a registered powered run");
        assert!(run.is_powered());
        assert_eq!(run.attempt_id(), "flight-eight-v1");
        assert_eq!(run.design_fingerprint(), design);
        assert_eq!(
            run.seed_base(),
            profile_attempt_seed_base("flight-eight-v1")
        );
        assert_ne!(run.seed_base(), 0);
    }

    #[test]
    fn profile_design_fingerprint_binds_fixture_content_and_parameters() {
        let zone_source = std::str::from_utf8(PROFILE_POWERED_ZONE).expect("zone source");
        let maps = powered_profile_maps();
        let design =
            profile_design_fingerprint(PROFILE_POWERED_PAIRS, "melee", zone_source, 0.50, &maps)
                .expect("a design fingerprint");
        let mut reordered = maps.clone();
        reordered.swap(0, 1);
        assert_ne!(
            profile_design_fingerprint(
                PROFILE_POWERED_PAIRS,
                "melee",
                zone_source,
                0.50,
                &reordered,
            )
            .expect("a reordered design fingerprint"),
            design
        );
        assert_ne!(
            profile_design_fingerprint(
                PROFILE_POWERED_PAIRS,
                "melee",
                &format!("{zone_source}\n"),
                0.50,
                &maps,
            )
            .expect("a changed-source design fingerprint"),
            design
        );
        assert_ne!(
            profile_design_fingerprint(PROFILE_POWERED_PAIRS, "melee", zone_source, 0.49, &maps,)
                .expect("a changed-skill design fingerprint"),
            design
        );
    }

    #[test]
    fn profile_design_fingerprint_binds_execution_identity() {
        let zone_source = std::str::from_utf8(PROFILE_POWERED_ZONE).expect("zone source");
        let maps = powered_profile_maps();
        let execution = calibration_execution_fingerprint();
        let design =
            profile_design_fingerprint(PROFILE_POWERED_PAIRS, "melee", zone_source, 0.50, &maps)
                .expect("a design fingerprint");
        assert_eq!(
            profile_design_fingerprint_with_execution(
                PROFILE_POWERED_PAIRS,
                "melee",
                zone_source,
                0.50,
                &maps,
                &execution,
            )
            .expect("the current execution fingerprint"),
            design
        );
        assert_ne!(
            profile_design_fingerprint_with_execution(
                PROFILE_POWERED_PAIRS,
                "melee",
                zone_source,
                0.50,
                &maps,
                &format!("{execution}-different-toolchain"),
            )
            .expect("a changed execution fingerprint"),
            design
        );
    }

    #[test]
    fn profile_design_fingerprint_binds_ordered_contrast_family() {
        let zone_source = std::str::from_utf8(PROFILE_POWERED_ZONE).expect("zone source");
        let maps = powered_profile_maps();
        let execution = calibration_execution_fingerprint();
        let contrasts = profiles::calibration_contrasts();
        let design = profile_design_fingerprint_for_contrasts(
            PROFILE_POWERED_PAIRS,
            "melee",
            zone_source,
            0.50,
            &maps,
            &execution,
            &contrasts,
        )
        .expect("the declared contrast fingerprint");

        let mut reordered = contrasts.clone();
        reordered.swap(0, 1);
        assert_ne!(
            profile_design_fingerprint_for_contrasts(
                PROFILE_POWERED_PAIRS,
                "melee",
                zone_source,
                0.50,
                &maps,
                &execution,
                &reordered,
            )
            .expect("a reordered contrast fingerprint"),
            design
        );

        let mut reversed = contrasts;
        let first = &mut reversed[0];
        std::mem::swap(&mut first.a, &mut first.b);
        assert_ne!(
            profile_design_fingerprint_for_contrasts(
                PROFILE_POWERED_PAIRS,
                "melee",
                zone_source,
                0.50,
                &maps,
                &execution,
                &reversed,
            )
            .expect("a reversed contrast fingerprint"),
            design
        );
    }

    #[test]
    fn profile_controller_fingerprint_binds_live_melee_scoring() {
        let modes = include_bytes!("modes.rs");
        assert_eq!(
            profile_controller_fingerprint_with_modes(modes),
            profile_controller_fingerprint()
        );
        let mut changed = modes.to_vec();
        changed.extend_from_slice(b"\nchanged live Melee scoring");
        assert_ne!(
            profile_controller_fingerprint_with_modes(&changed),
            profile_controller_fingerprint()
        );
    }

    #[test]
    fn profile_report_records_execution_identity() {
        let maps = powered_profile_maps();
        let run = ProfileCalibrationRun {
            attempt_id: "report-test".into(),
            design_fingerprint: "sha256:report-test".into(),
            seed_base: 1,
            powered_fixture: true,
        };
        let results: Vec<_> = profiles::calibration_contrasts()
            .into_iter()
            .map(|contrast| ProfileResult {
                contrast: contrast.name,
                a: contrast.a.name,
                b: contrast.b.name,
                paired_seeds: PROFILE_POWERED_PAIRS,
                matches: PROFILE_POWERED_PAIRS * 2,
                win_rate: 0.5,
                win_rate_low: 0.46,
                win_rate_high: 0.54,
                kill_difference: 0.0,
                kill_difference_low: -1.0,
                kill_difference_high: 1.0,
                verdict: "balanced",
                powered_fixture: true,
                fixture_valid: true,
                fixture_validity: Vec::new(),
                observations: Vec::new(),
            })
            .collect();
        let report = report_profiles(
            &run,
            &results,
            "melee",
            "sha256:zone-test",
            0.50,
            180,
            &maps,
        );
        let execution = calibration_execution_fingerprint();
        assert_eq!(
            report["execution_fingerprint"].as_str(),
            Some(execution.as_str())
        );
        assert_eq!(
            report["comparisons"].as_u64(),
            Some(PROFILE_COMPARISONS as u64)
        );
        assert_eq!(
            report["powered_design"]["planning_comparisons"].as_u64(),
            Some(PROFILE_PLANNING_COMPARISONS as u64)
        );
        assert_eq!(
            report["powered_design"]["minimum_powered_paired_seeds"].as_u64(),
            Some(PROFILE_POWER_MINIMUM_PAIRS as u64)
        );
        assert_eq!(
            report["fixture_schedule"]["stratification_block_paired_seeds"].as_u64(),
            Some(profile_stratification_block(maps.len()) as u64)
        );
        assert_eq!(
            report["fixture_schedule"]["lineups"]
                .as_array()
                .map(Vec::len),
            Some(PROFILE_LINEUP_ROTATIONS)
        );
        assert_eq!(
            report["fixture_schedule"]["partial_block_paired_seeds"].as_u64(),
            Some(0)
        );
        assert_eq!(
            report["contrasts"].as_array().map(Vec::len),
            Some(PROFILE_COMPARISONS)
        );
    }

    #[test]
    fn a_profile_design_can_register_only_one_attempt() {
        let zone_source = std::str::from_utf8(PROFILE_POWERED_ZONE).expect("zone source");
        let maps = powered_profile_maps();
        let design =
            profile_design_fingerprint(PROFILE_POWERED_PAIRS, "melee", zone_source, 0.50, &maps)
                .expect("a design fingerprint");
        let registry = serde_json::to_string(&ProfileCalibrationAttemptRegistry {
            schema_version: 1,
            attempts: vec![
                ProfileCalibrationAttempt {
                    attempt_id: "first-attempt".into(),
                    design_fingerprint: design.clone(),
                },
                ProfileCalibrationAttempt {
                    attempt_id: "second-attempt".into(),
                    design_fingerprint: design,
                },
            ],
        })
        .expect("a registry");

        let error = prepare_profile_calibration(
            PROFILE_POWERED_PAIRS,
            "first-attempt",
            &registry,
            "melee",
            zone_source,
            0.50,
            &maps,
        )
        .unwrap_err();
        assert!(error.contains("more than one registered attempt"));
    }

    #[test]
    fn nonpowered_profile_runs_are_exploratory() {
        let zone_source = std::str::from_utf8(PROFILE_POWERED_ZONE).expect("zone source");
        let maps = powered_profile_maps();
        let paired_seeds = PROFILE_POWERED_PAIRS - maps.len() as u32;
        let run = prepare_profile_calibration(
            paired_seeds,
            PROFILE_EXPLORATORY_ATTEMPT,
            "not parsed for exploration",
            "melee",
            zone_source,
            0.50,
            &maps,
        )
        .expect("an exploratory run");
        assert!(!run.is_powered());
        assert_eq!(run.seed_base(), 0);
        assert_eq!(
            profile_verdict(run.is_powered(), true, 0.56, 0.63),
            "exploratory: not prespecified sample"
        );

        let error = prepare_profile_calibration(
            paired_seeds,
            "unregistered-confirmatory-run",
            "{}",
            "melee",
            zone_source,
            0.50,
            &maps,
        )
        .unwrap_err();
        assert!(error.contains("only the exact"));

        let error = prepare_profile_calibration(
            PROFILE_POWERED_PAIRS + maps.len() as u32,
            PROFILE_EXPLORATORY_ATTEMPT,
            "not parsed for exploration",
            "melee",
            zone_source,
            0.50,
            &maps,
        )
        .unwrap_err();
        assert!(error.contains(&format!("fewer than {PROFILE_POWERED_PAIRS} paired seeds")));
    }

    #[test]
    fn profile_attempts_get_distinct_deterministic_seed_namespaces() {
        assert_eq!(
            profile_attempt_seed_base("flight-eight-v1"),
            profile_attempt_seed_base("flight-eight-v1")
        );
        assert_ne!(
            profile_attempt_seed_base("flight-eight-v1"),
            profile_attempt_seed_base("flight-eight-v2")
        );
    }

    #[test]
    fn calibration_spawn_dressing_fills_the_resolved_bar() {
        let mut stage_world = sim::World::with_map(1, sim::build_pit);
        let stage_ship = stage_world.spawn(0, 0, 505, 522, 0) as usize;
        let stats = STAGES
            .iter()
            .find(|stage| stage.name == "stats")
            .expect("the stats diagnostic");
        wear(&mut stage_world, stage_ship, stats);
        assert_eq!(
            stage_world.state.ships[stage_ship].energy,
            stage_world.eff_max_energy(stage_ship)
        );

        let mut hull_world = sim::World::with_map(2, sim::build_pit);
        let hull_ship = hull_world.spawn(0, 0, 505, 522, 0) as usize;
        let mut rng = 0x1234_5678;
        assert_eq!(
            deal_kit(&mut hull_world, hull_ship, sim::KIT_BUDGET, &mut rng),
            sim::KIT_BUDGET
        );
        assert_eq!(
            hull_world.state.ships[hull_ship].energy,
            hull_world.eff_max_energy(hull_ship)
        );
    }

    #[test]
    fn paired_interval_tightens_when_the_same_evidence_repeats() {
        let noisy = [0.0, 1.0, 0.0, 1.0];
        let repeated: Vec<f64> = noisy.into_iter().cycle().take(400).collect();
        let (_, low_small, high_small) = family_win_interval(&noisy);
        let (mean, low_large, high_large) = family_win_interval(&repeated);
        assert_eq!(mean, 0.5);
        assert!(high_large - low_large < high_small - low_small);
    }

    #[test]
    fn clock_only_team_match_never_stops_on_score() {
        assert!(match_reached_target([20, 0], 4, Some(5)));
        assert!(!match_reached_target([20, 0], 4, None));
    }

    #[test]
    fn profile_seed_count_must_weight_every_map_equally() {
        let maps = vec![
            ("first".into(), Arena::Built(sim::build_pit)),
            ("second".into(), Arena::Built(sim::build_pit)),
        ];
        let run = ProfileCalibrationRun {
            attempt_id: PROFILE_EXPLORATORY_ATTEMPT.into(),
            design_fingerprint: "unused".into(),
            seed_base: 0,
            powered_fixture: false,
        };
        let error = run_profiles(&run, 1, "test", "test", 0.5, &maps, false).unwrap_err();
        assert!(error.contains("do not divide evenly across 2 maps"));
    }

    #[test]
    fn profile_contrast_order_is_stable() {
        let names: Vec<_> = profiles::calibration_contrasts()
            .into_iter()
            .map(|contrast| contrast.name)
            .collect();
        assert_eq!(
            names,
            [
                "Starter margin: Energy 6 vs bomb bounce 2",
                "Starter margin: Recharge 5 vs bomb bounce 2",
                "Starter margin: Speed 6 vs bomb bounce 2",
                "Starter margin: Thrust 3 vs bomb bounce 2",
                "Starter margin: Rotation 3 vs bomb bounce 2",
                "Top margin: Energy 8 vs bomb bounce 2",
                "Top margin: Recharge 8 vs bomb bounce 2",
                "Top margin: Speed 8 vs bomb bounce 2",
                "Top margin: Thrust 8 vs bomb bounce 2",
                "Top margin: Rotation 8 vs bomb bounce 2",
            ]
        );
    }

    #[test]
    fn profile_lineup_pairs_each_hull_with_its_rotated_start() {
        for rotation in 0..PROFILE_LINEUP_ROTATIONS {
            let lineup = profile_lineup(rotation);
            for (name, bytes) in PROFILE_POWERED_MAPS.iter().zip(PROFILE_POWERED_MAP_BYTES) {
                let mut world = sim::World::from_packed(1, bytes).expect("a shipped Melee map");
                let mut ships = [0u8; PROFILE_LINEUP_SEATS];
                for (index, &class) in lineup.iter().enumerate() {
                    let team = (index / PROFILE_SIDE_SIZE) as u8;
                    let heading = if team == 0 { 0 } else { 32768 };
                    let ship = world.spawn_on_map(
                        class,
                        team,
                        (index % PROFILE_SIDE_SIZE) as u32,
                        heading,
                    );
                    assert!(ship >= 0, "{name} seats profile hull {index}");
                    ships[index] = ship as u8;
                }
                world.restart();
                crate::room::face_public_teams(&mut world);

                let span_x = i32::from(world.map.w) * sim::TILE_PX * 256;
                let span_y = i32::from(world.map.h) * sim::TILE_PX * 256;
                for index in 0..PROFILE_SIDE_SIZE {
                    let opposite = PROFILE_LINEUP_SEATS - 1 - index;
                    let a = world.state.ships[ships[index] as usize];
                    let b = world.state.ships[ships[opposite] as usize];
                    assert_eq!(a.cls, b.cls, "{name} counterpart hull {index}");
                    assert_eq!(a.x + b.x, span_x, "{name} counterpart x {index}");
                    assert_eq!(a.y + b.y, span_y, "{name} counterpart y {index}");
                    assert_eq!(
                        b.heading,
                        a.heading.wrapping_add(32768),
                        "{name} counterpart heading {index}"
                    );
                }
            }
        }
    }

    #[test]
    fn profile_lineup_rotation_covers_every_hull_four_times() {
        let mut appearances = [0u8; sim::MAX_CLASSES];
        for rotation in 0..PROFILE_LINEUP_ROTATIONS {
            let lineup = profile_lineup(rotation);
            for seat in 0..PROFILE_SIDE_SIZE {
                let opposite = PROFILE_LINEUP_SEATS - 1 - seat;
                assert_eq!(lineup[seat], lineup[opposite]);
                appearances[lineup[seat] as usize] += 1;
            }
        }
        assert_eq!(appearances, [PROFILE_SIDE_SIZE as u8; sim::MAX_CLASSES]);
    }

    #[test]
    fn powered_profile_sample_exactly_stratifies_maps_and_lineups() {
        let mut cells = [[0u32; PROFILE_LINEUP_ROTATIONS]; PROFILE_POWERED_MAPS.len()];
        for sample in 0..PROFILE_POWERED_PAIRS {
            let (map, lineup) = profile_stratum(sample, PROFILE_POWERED_MAPS.len());
            cells[map][lineup] += 1;
        }
        assert_eq!(
            cells,
            [[81; PROFILE_LINEUP_ROTATIONS]; PROFILE_POWERED_MAPS.len()]
        );
    }

    #[test]
    fn profile_map_fixture_reuses_geometry_without_changing_the_world() {
        let arena = Arena::Built(sim::build_pit);
        let prepared = team_world(0, None, &arena).expect("a prepared map");
        let fixture = ProfileMapFixture::new(std::sync::Arc::clone(&prepared.map));
        let original = team_world(97, None, &arena).expect("an ordinary world");
        let cached = fixture.world(97, None);
        let cached_again = fixture.world(97, None);

        assert_eq!(cached.hash(), original.hash());
        assert_eq!(cached.packed_map(), original.packed_map());
        assert_eq!(cached.packed_settings(), original.packed_settings());
        assert!(std::sync::Arc::ptr_eq(&fixture.map, &cached.map));
        assert!(std::sync::Arc::ptr_eq(&cached.map, &cached_again.map));
    }

    #[test]
    fn profile_fixture_validity_reports_every_map_and_failure() {
        let observation =
            |map_index, first_win_score, mirror_win_score, scored_kills| ProfileObservation {
                scenario_seed: 1,
                map_index,
                lineup_index: 0,
                first_win_score,
                mirror_win_score,
                first_kill_difference: 0.0,
                mirror_kill_difference: 0.0,
                first_scored_kills: scored_kills,
                mirror_scored_kills: scored_kills,
                first_deaths: 8,
                mirror_deaths: 8,
            };
        let observations = [
            observation(0, 0.5, 0.5, 0),
            // Team 0 wins both legs. From A's perspective that is one win and
            // one loss, so the balance outcome alone would hide the side bias.
            observation(1, 1.0, 0.0, 8),
            // Opposite side advantages can average away while leaving every
            // paired profile outcome at 0.5.
            observation(2, 1.0, 0.0, 8),
            observation(2, 0.0, 1.0, 8),
            observation(3, 1.0, 1.0, 8),
        ];
        let validity = profile_fixture_validity(
            &observations,
            &["dead", "side", "insensitive", "active", "missing"],
        );

        assert_eq!(validity.len(), 5);
        assert_eq!(
            validity[0].failures,
            [
                "mean_positive_scored_kills_per_match_below_minimum",
                "mean_profile_sensitivity_below_minimum"
            ]
        );
        assert_eq!(validity[0].mean_positive_scored_kills_per_match, 0.0);
        assert_eq!(
            validity[1].failures,
            ["mean_profile_sensitivity_below_minimum"]
        );
        assert_eq!(
            validity[1].warnings,
            ["absolute_observed_side_gap_above_warning"]
        );
        assert_eq!(validity[1].absolute_observed_side_gap, 1.0);
        assert_eq!(
            validity[2].failures,
            ["mean_profile_sensitivity_below_minimum"]
        );
        assert_eq!(validity[2].absolute_observed_side_gap, 0.0);
        assert_eq!(validity[2].mean_profile_sensitivity, 0.0);
        assert!(validity[3].valid);
        assert!(validity[3].failures.is_empty());
        assert_eq!(validity[3].mean_positive_scored_kills_per_match, 8.0);
        assert_eq!(validity[3].mean_profile_sensitivity, 1.0);
        assert!(!validity[4].valid);
        assert_eq!(validity[4].failures, ["no_paired_observations"]);
    }

    #[test]
    fn profile_preflight_names_a_rejected_full_cost_kit() {
        let mut profile = profiles::builtins().remove(0);
        let energy = sim::slot_stat(sim::UP_ENERGY) as usize;
        let recharge = sim::slot_stat(sim::UP_RECHARGE) as usize;
        profile.kit[energy] += 4;
        profile.kit[recharge] -= 4;
        assert_eq!(sim::World::kit_cost(&profile.kit), sim::KIT_BUDGET);

        let error = validate_profile_kits(&[profile], None).unwrap_err();
        assert!(error.contains("Gunner"));
        assert!(error.contains("rejected by hull"));
    }

    #[test]
    fn profile_preflight_rejects_ambiguous_contrast_names() {
        let mut contrasts = profiles::calibration_contrasts();
        let duplicate = contrasts[0].name;
        contrasts[1].name = duplicate;
        let error = validate_profile_contrasts(&contrasts, None).unwrap_err();
        assert!(error.contains("blank or duplicate contrast name"));

        let mut contrasts = profiles::calibration_contrasts();
        let duplicate = contrasts[0].a.name;
        contrasts[0].b.name = duplicate;
        let error = validate_profile_contrasts(&contrasts, None).unwrap_err();
        assert!(error.contains("does not name both sides unambiguously"));
    }

    #[test]
    fn team_score_keeps_suicide_penalties_signed() {
        let mut world = sim::World::with_map(7, sim::build_pit);
        let first = world.spawn(0, 0, 505, 522, 0) as u8;
        let second = world.spawn(0, 1, 519, 522, 32768) as u8;
        world.state.ships[first as usize].kills = -1;
        world.state.ships[second as usize].kills = 2;
        let seats = [
            Seat {
                team: 0,
                ..Default::default()
            },
            Seat {
                team: 1,
                ..Default::default()
            },
        ];

        assert_eq!(live_team_score(&world, &[first, second], &seats), [-1, 2]);
    }

    #[test]
    fn profile_results_use_the_live_melee_score_floor() {
        assert_eq!(profile_score([-1, -2], false), (0.5, 0.0, 0));
        assert_eq!(profile_score([-1, 2], false), (0.0, -2.0, 2));
        assert_eq!(profile_score([-1, 2], true), (1.0, 2.0, 2));
        assert_eq!(profile_score([70_000, 80_000], false), (0.5, 0.0, 131_070));
    }

    #[test]
    fn profile_dressing_opens_on_the_authored_full_match_state() {
        let kit = profiles::builtins()[0].kit;
        let mut world = sim::World::with_map(23, sim::build_pit);
        let first = world.spawn_on_map(0, 0, 0, 0) as u8;
        let second = world.spawn_on_map(1, 1, 0, 32768) as u8;
        assert_ne!(first, u8::MAX);
        assert_ne!(second, u8::MAX);
        let ships = [first, second];
        for &ship in &ships {
            let row = &mut world.state.ships[ship as usize];
            row.x += 12_345;
            row.y -= 5_432;
            row.vx = 777;
            row.vy = -333;
            row.energy = 1;
        }
        let mut seats = [
            Seat {
                team: 0,
                ..Default::default()
            },
            Seat {
                team: 1,
                ..Default::default()
            },
        ];
        let mut prng = [1, 2];

        assert!(dress_team(
            &mut world,
            &ships,
            &mut seats,
            sim::KIT_BUDGET,
            Some(&[kit, kit]),
            &mut prng,
        ));

        for (index, &ship) in ships.iter().enumerate() {
            let row = &world.state.ships[ship as usize];
            assert_eq!(row.kit, kit);
            assert_eq!(row.energy, world.eff_max_energy(ship as usize));
            assert_eq!((row.vx, row.vy), (0, 0));
            assert_eq!((row.x, row.y), (row.spawn_x, row.spawn_y));
            let other = world.state.ships[ships[1 - index] as usize];
            assert_eq!(
                row.heading,
                crate::room::heading_toward((row.x, row.y), (other.x, other.y))
            );
            assert_eq!(row.alive, 1);
            for charge in 0..sim::MAX_CHARGES {
                assert_eq!(row.charge[charge], kit[sim::slot_charge(charge) as usize]);
            }
        }
    }

    #[test]
    fn explicit_profiles_are_dealt_once_per_match() {
        let kit = profiles::builtins()[0].kit;
        let (seats, _) = team_match_with_options(
            &[0, 1, 0, 1],
            0.5,
            sim::KIT_BUDGET,
            19,
            None,
            TeamMap::Arena(&Arena::Built(sim::build_pit)),
            TeamMatchOptions {
                kits: Some(&[kit, kit]),
                tick_limit: 12_000,
                kill_target_per_player: Some(KILL_TARGET),
            },
        );

        assert!(seats.iter().map(|seat| seat.deaths).sum::<u32>() > 0);
        for seat in seats {
            assert_eq!(seat.budget, sim::KIT_BUDGET);
            assert_eq!(seat.converted, sim::KIT_BUDGET);
        }
    }

    /// What the ladder does do, and a real regression guard: it runs, it
    /// rates everybody, and nobody floats away from the anchor. A roster that
    /// graded 1400 to 900 would mean the rating maths had come apart, which is
    /// worth catching even while the skill parameter underneath it does not
    /// separate.
    #[test]
    fn a_calibration_run_rates_everybody_near_the_anchor() {
        let roster = vec![
            ai::RosterEntry {
                name: "low".into(),
                class: 0,
                skill: 0.15,
            },
            ai::RosterEntry {
                name: "mid".into(),
                class: 0,
                skill: 0.50,
            },
            ai::RosterEntry {
                name: "high".into(),
                class: 0,
                skill: 0.95,
            },
        ];
        let r = run_roster(&roster, 8, false);
        for name in ["low", "mid", "high"] {
            let v = r.rating_of(name);
            assert!(v > 1000.0 && v < 1400.0, "{name} rated {v:.0}");
        }
    }

    #[test]
    fn calibration_leaves_the_anchor_where_it_was_pinned() {
        let r = run(1, false);
        assert_eq!(
            r.rating_of(ai::ANCHOR),
            ai::ANCHOR_RATING,
            "the fixed point has to stay fixed or the scale drifts"
        );
    }

    #[test]
    fn every_pilot_actually_fought() {
        let r = run(1, false);
        for e in ai::roster() {
            assert!(r.games_of(&e.name) > 0, "{} sat out the tournament", e.name);
        }
    }

    /* ---- the loadout tournament ---- */

    fn row_of(wins: u32, losses: u32) -> StageRow {
        StageRow {
            name: "probe",
            worn: 0,
            asked: None,
            wins,
            losses,
            draws: 0,
            kills: 0,
            shots: [0; sim::TRIG_COUNT],
            hits: 0,
            damage: 0,
            self_hits: 0,
            self_damage: 0,
            regrants: 0,
            vs: Vec::new(),
            mirror: 0.5,
            stalemates: 0,
        }
    }

    /// The interval has to narrow as bouts pile up, which is the whole reason
    /// it replaced a number that did the opposite.
    ///
    /// The figures are the ones this harness actually produced on a Facet: a
    /// coin-flip row over 48 bouts is worth about 14 points either way, and
    /// the same rate over 384 is worth about 5. Anybody reading a gap of ten
    /// off a 48-bout run is reading noise, which is what the old floor let
    /// through by reporting 4.2.
    #[test]
    fn the_interval_narrows_with_bouts() {
        let small = row_of(24, 24);
        let large = row_of(192, 192);
        assert!(
            (13.0..15.0).contains(&small.margin()),
            "48 bouts at even money should be worth about 14 points, got {:.1}",
            small.margin()
        );
        assert!(
            (4.0..6.0).contains(&large.margin()),
            "384 bouts should be worth about 5, got {:.1}",
            large.margin()
        );
        assert!(
            large.margin() < small.margin(),
            "more bouts, tighter interval"
        );

        // Wilson and not the textbook normal, so a row that won nothing gets an
        // interval it could actually live in rather than plus or minus zero.
        let swept = row_of(0, 48);
        assert!(swept.margin() > 3.0, "a shut-out is not measured perfectly");
        assert!(
            swept.win_rate() * 100.0 + swept.margin() < 15.0,
            "and it still reads as a bad stage"
        );

        // Nothing played is not something known.
        assert_eq!(row_of(0, 0).margin(), 0.0);
    }

    /// Bounty is matched a life at a time, which is not the same as matched
    /// over a bout, and the difference is worth pinning rather than assuming.
    ///
    /// Both pilots are handed `budget` at every spawn, so at any moment in the
    /// fight they have drawn the same number since they last died. Totals come
    /// apart, because the side that dies more respawns more and is handed the
    /// opening kit again each time. That is the game's own arrangement and not
    /// an advantage: those extra points are bought with deaths, and a hull
    /// that is dying is not winning.
    ///
    /// What this guards is the silent version of the failure. A point spent
    /// against a ceiling grants nothing, so a harness that counted grants
    /// rather than offers would hand the deeper tech tree more for free and
    /// report the result as balance.
    #[test]
    fn bounty_is_matched_a_life_at_a_time() {
        // The knife against the fortress: the widest gap in tree shape the
        // roster has, so the widest gap between offered and converted.
        let cipher = ai::class_index("Cipher").unwrap() as u8;
        let anvil = ai::class_index("Anvil").unwrap() as u8;
        const BUDGET: u32 = 8;
        for salt in 0..4 {
            let (_, offered) = hull_bout(
                [cipher, anvil],
                0.5,
                BUDGET,
                salt,
                None,
                &Arena::Built(sim::build_pit),
            );
            for (k, got) in offered.iter().enumerate() {
                assert!(
                    *got >= BUDGET,
                    "salt {salt}: side {k} never got its opening"
                );
                assert_eq!(
                    got % BUDGET,
                    0,
                    "salt {salt}: the kit is dealt a life at a time"
                );
            }
        }

        // Deliberately not cross-checked against the other side's kills. A
        // death is not always somebody's kill: a blast has no owner test, so a
        // pilot can end their own life with their own bomb, respawn, and be
        // refitted for a death that appears in nobody's column. Trying to
        // predict the refit count from kills is how that got found.

        // The claim underneath all of this, on its own: the same budget buys
        // the same amount of ship whatever hull it is spent on.
        //
        // It used to be the opposite. A budget bought different hulls
        // different amounts, because each carried its own ceilings and a hull
        // with a short ladder and few add-ons ran out of places to spend
        // before the budget ran out. That difference was defended here as a
        // real part of what the roster was; it was also what made a bought
        // upgrade dead on the wrong hull, and it is gone.
        //
        // Handed more than any kit can hold, both stop in exactly the same
        // place, and every unspent point still counts against the budget it
        // was offered.
        let mut world = sim::World::with_map(1, sim::build_pit);
        let ceiling: u32 = world.kit_ceilings().iter().map(|&n| n as u32).sum();
        let offered = ceiling + 20;
        let mut converted = Vec::new();
        for &(class, name) in &[(cipher, "Cipher"), (anvil, "Anvil")] {
            let ship = world.spawn(class, 0, 505, 522, 0) as usize;
            let mut rng = 0x1234_5678u32;
            let spent = deal_kit(&mut world, ship, offered, &mut rng);
            assert!(spent <= offered, "{name} converted more than it was handed");
            assert!(
                spent < offered,
                "{name} never saturated, so this is not reaching a ceiling at all"
            );
            converted.push(spent);
        }
        assert_eq!(
            converted[0], converted[1],
            "two hulls saturated in different places, so something still tells \
them apart"
        );
    }

    /// A zone's spawn scatter stays out of every harness here.
    ///
    /// `spawn_radius` drops a respawning ship on a random tile that far from
    /// the map's centre. Alpha carries 250 and the pit is thirty-two tiles
    /// across, so the first death puts both pilots outside the room, and they
    /// spend the rest of the bout failing to find each other: it halved the
    /// kills in a 384-bout tournament and moved every hull's win rate, which I
    /// spent a while attributing to a refactor.
    ///
    /// The failure is quiet in the worst way. Nothing errors, every column
    /// still prints, and the numbers are simply about a different fight. Two
    /// settings were already held for the same reason and this is the third.
    #[test]
    fn a_zones_spawn_scatter_does_not_reach_the_harness() {
        let scattered: config::ArenaConfig =
            toml::from_str("spawn_radius = 250\n").expect("a zone that scatters");
        let cipher = ai::class_index("Cipher").unwrap() as u8;

        // Fought in the pit, where a 250-tile radius is off the map's furniture
        // entirely. Kills are the tell: pilots who cannot find each other
        // cannot kill each other.
        let mut kills = 0;
        for salt in 0..6 {
            let (b, _) = hull_bout(
                [cipher, cipher],
                0.5,
                10,
                salt,
                Some(&scattered),
                &Arena::Built(sim::build_pit),
            );
            kills += b.sides[0].kills + b.sides[1].kills;
        }
        // Measured both ways rather than guessed: held, six bouts come to 50
        // kills, which is most of the way to the ten a decided bout is worth.
        // Unheld they come to 19, because after the opening life nobody can
        // find anybody. Forty sits well clear of the broken number and well
        // under the working one.
        assert!(
            kills > 40,
            "six bouts produced {kills} kills between them, against 50 when the \
scatter is held and 19 when it is not, so it is still throwing pilots out of \
the room"
        );
    }

    #[test]
    fn a_team_tournament_keeps_the_zones_spawn_scatter() {
        let scattered: config::ArenaConfig =
            toml::from_str("spawn_radius = 60\n").expect("a zone with scattered spawns");

        let world = team_world(0, Some(&scattered), &Arena::Built(sim::build_arena))
            .expect("a tournament world");

        assert_eq!(world.cfg.spawn_radius, 60);
    }

    /// A bout deals its kits against the zone's ceiling, not the baseline's.
    ///
    /// The ordering hazard this guards used to be about energy: hulls carried
    /// their own flight, `sim_spawn` read the opening bar out of the class
    /// table, and seating a ship before the zone was applied gave it the
    /// baseline's bar. Hulls carry no flight now, so that particular bug
    /// cannot happen, but the shape of it moved rather than going away. The
    /// kit ceiling is the zone's, `deal_kit` reads it every time it places a
    /// point, and a harness that dealt before applying would measure a roster
    /// nobody plays.
    ///
    /// It is worth an assertion for the reason the old one was: nothing in
    /// any column this harness prints would look wrong.
    /// A rung measures the opponent, not a private ruleset.
    ///
    /// Ladder's zone file says in prose that it runs melee's movement,
    /// collision, weapon and kit economy, and prose does not fail a build.
    /// Melee's spray tuning moved and Ladder's did not, so for a while a climb
    /// was scored under numbers nobody played in the main game. Both files are
    /// already compiled in, so hold them against each other.
    ///
    /// Only the shared economy. What a mode legitimately owns stays out:
    /// the clocks, the rung rules, the maps, and how many seats there are.
    #[test]
    fn a_duel_runs_the_melee_economy() {
        let read = |bytes: &[u8]| -> crate::config::ArenaConfig {
            let text = std::str::from_utf8(bytes).expect("a zone file is text");
            let zone: crate::catalog::ZoneDef = toml::from_str(text).expect("a zone parses");
            zone.arena.clone()
        };
        let melee = read(PROFILE_POWERED_ZONE);
        let duel = read(PILOT_ZONE_BYTES);

        // The space and what a hull does in it.
        assert_eq!(duel.bounce, melee.bounce, "bounce");
        assert_eq!(duel.friction, melee.friction, "friction");
        assert_eq!(duel.respawn_delay, melee.respawn_delay, "respawn_delay");
        assert_eq!(duel.spawn_radius, melee.spawn_radius, "spawn_radius");
        assert_eq!(duel.safe_limit, melee.safe_limit, "safe_limit");

        // What a kill is worth.
        assert_eq!(duel.bounty_base, melee.bounty_base, "bounty_base");
        assert_eq!(
            duel.bounty_per_kill, melee.bounty_per_kill,
            "bounty_per_kill"
        );
        assert_eq!(
            duel.points_per_flag, melee.points_per_flag,
            "points_per_flag"
        );

        // The weapons, which is where this actually went wrong.
        assert_eq!(duel.mod_spread, melee.mod_spread, "mod_spread");
        assert_eq!(duel.multi_energy, melee.multi_energy, "multi_energy");
        assert_eq!(duel.multi_delay, melee.multi_delay, "multi_delay");
        assert_eq!(duel.prox_step, melee.prox_step, "prox_step");
        assert_eq!(duel.prox_delay, melee.prox_delay, "prox_delay");
        assert_eq!(duel.bomb_safety, melee.bomb_safety, "bomb_safety");
        assert_eq!(duel.bbomb_damage, melee.bbomb_damage, "bbomb_damage");
        assert_eq!(duel.shrap_inactive, melee.shrap_inactive, "shrap_inactive");
        assert_eq!(
            duel.shrap_inactive_ticks, melee.shrap_inactive_ticks,
            "shrap_inactive_ticks"
        );
        assert_eq!(duel.mod_step, melee.mod_step, "mod_step");
        assert_eq!(duel.weapons, melee.weapons, "weapons");

        // And what a pilot may carry, which is the other half of it.
        assert_eq!(duel.kit.gun_mods, melee.kit.gun_mods, "gun_mods");
        assert_eq!(duel.kit.bomb_mods, melee.kit.bomb_mods, "bomb_mods");
        assert_eq!(duel.kit.charges, melee.kit.charges, "charges");
    }

    #[test]
    fn a_zones_kit_ceiling_reaches_the_kits_it_deals() {
        let cipher = ai::class_index("Cipher").unwrap() as u8;
        let bare: config::ArenaConfig = toml::from_str("[kit]\ngun_mods = { bounce = 1 }\n")
            .expect("a zone with one gun add-on");

        let arena = Arena::Built(sim::build_pit);
        let multi = sim::slot_mod(sim::TRIG_GUN, sim::MOD_MULTI) as usize;

        let plain = arena.build(0).expect("a room");
        assert!(
            plain.kit_ceilings()[multi] > 0,
            "the baseline has multifire to take away"
        );

        let mut room = arena.build(0).expect("a room");
        crate::Room::apply_config(&mut room, &bare);
        let seats = arena.seat(&mut room, 0, [cipher, cipher]).expect("seats");
        assert_eq!(
            room.kit_ceilings()[multi],
            0,
            "the zone took multifire away and the room did not notice"
        );

        // And a kit dealt in that room cannot hold what the room does not
        // have, however much budget it is handed.
        let mut rng = 0x5eed_u32;
        deal_kit(&mut room, seats[0] as usize, sim::KIT_BUDGET, &mut rng);
        assert_eq!(
            room.state.ships[seats[0] as usize].kit[multi], 0,
            "a whole budget still found no multifire to buy"
        );
    }

    /// A hull against itself comes out even, or the pit is doing the deciding.
    ///
    /// The two seats are different places with different headings, so a bout is
    /// not symmetric and cannot be made so. What makes the matrix honest is the
    /// alternation: odd salts swap which hull sits where, and the report undoes
    /// it. If that undoing were wrong every cell would be its own opposite on
    /// half the bouts, which averages to a flat 50% and reads as balance.
    ///
    /// A mirror pairing is where it shows. Both sides are the same hull, so
    /// anything away from even is the seat rather than the ship.
    #[test]
    fn a_hull_against_itself_is_even() {
        for name in ["Apex", "Anvil"] {
            let c = ai::class_index(name).unwrap() as u8;
            let (mut first, mut n) = (0.0f64, 0.0f64);
            for salt in 0..24 {
                let (b, _) = hull_bout([c, c], 0.5, 4, salt, None, &Arena::Built(sim::build_pit));
                first += match b.sides[0].kills.cmp(&b.sides[1].kills) {
                    std::cmp::Ordering::Greater => 1.0,
                    std::cmp::Ordering::Less => 0.0,
                    std::cmp::Ordering::Equal => 0.5,
                };
                n += 1.0;
            }
            let share = first / n;
            assert!(
                (0.2..=0.8).contains(&share),
                "{name} against itself took the first seat {:.0}% of the time, \
which is the pit talking",
                100.0 * share
            );
        }
    }

    /// A stage has to be one thing under one name, or the matrix has two
    /// columns for the same kit and no way to say so.
    #[test]
    fn stages_are_named_once_each() {
        for (i, a) in STAGES.iter().enumerate() {
            for b in STAGES.iter().skip(i + 1) {
                assert_ne!(a.name, b.name, "two stages called {:?}", a.name);
            }
        }
        assert!(
            STAGES.iter().filter(|s| s.kit.is_empty()).count() >= 2,
            "the control is a second empty kit, and it is what the noise floor \
             is measured from"
        );
    }

    /// The kit goes on, and the ceiling is where it stops.
    #[test]
    fn a_kit_is_worn_up_to_the_hull_s_ceiling() {
        let mut world = sim::World::with_map(1, sim::build_pit);
        // Spawned bare, so what this measures is the stage's kit and nothing
        // the baseline put on the hull ahead of it.
        let ship = world.spawn(0, 0, 505, 522, 0) as usize;

        const ONE: &[(u8, u8)] = &[(sim::slot_level(sim::TRIG_GUN), 1)];
        const NINE: &[(u8, u8)] = &[(sim::slot_level(sim::TRIG_GUN), 9)];

        let one = Stage {
            name: "t",
            kit: ONE,
        };
        assert_eq!(wear(&mut world, ship, &one), 1);
        assert_eq!(world.state.ships[ship].level[sim::TRIG_GUN], 1);

        // Asking for more rungs than the ladder has is answered honestly: an
        // Apex climbs to rung 2 and the rest of the ask does not land.
        let greedy = Stage {
            name: "t",
            kit: NINE,
        };
        let worn = wear(&mut world, ship, &greedy);
        assert!(
            worn < 9,
            "a nine-rung gun ladder does not exist; wore {worn}"
        );
        assert_eq!(world.state.ships[ship].level[sim::TRIG_GUN], 2);

        // And dressing a pilot does not make them worth more to kill, which
        // is the one way a kit could quietly change what this measures.
        // Bounty is the run now, so it cannot: a pilot who has not killed
        // anybody is worth the base whatever they are wearing.
        assert_eq!(world.state.ships[ship].run, 0);
    }

    /// Death clears the tech tree, so a bout that does not re-outfit measures
    /// one loaded life and four bare ones. This is that claim, and it is the
    /// one the harness cannot survive being wrong about.
    #[test]
    fn the_kit_goes_back_on_after_a_death() {
        // Two kits an Apex can actually wear, and close enough that both sides
        // will die: a stage that wins five to nothing never respawns, and the
        // property under test would go unexercised.
        let (a, b) = (&STAGES[2], &STAGES[1]);
        assert_eq!((a.name, b.name), ("gun 2", "gun 1"), "the stage list moved");
        let bout = stage_bout([a, b], 0, 0.5, 3, None);

        assert!(
            bout.sides[0].regrants + bout.sides[1].regrants > 0,
            "nobody was re-outfitted in a bout with {} deaths in it",
            bout.sides[0].kills + bout.sides[1].kills
        );
        for k in 0..2 {
            let (died, worn, again) = (
                bout.sides[1 - k].kills,
                bout.sides[k].worn,
                bout.sides[k].regrants,
            );
            assert!(worn > 0, "an Apex wears both of these");
            // Every life after the first is one whole kit. The last death does
            // not get one, because the bout ends on it and the pilot never
            // comes back, so the count sits in that one-kit band.
            assert!(
                again >= died.saturating_sub(1) * worn && again <= died * worn,
                "side {k} died {died} times wearing {worn} and was re-issued {again}"
            );
        }
    }

    /// A zone's tuning has to actually reach the bout, or the report names a
    /// zone over numbers that came from the compiled baseline. Nothing else
    /// would show it: the tournament runs, prints and looks entirely normal.
    #[test]
    fn a_zone_s_tuning_reaches_the_pit() {
        // Two settings a zone plausibly moves, chosen because the baseline's
        // values are known here and neither is what this asks for.
        let mut c = config::ArenaConfig {
            mod_spread: Some(5), // degrees, against the baseline's fifteen
            respawn_delay: Some(123),
            ..Default::default()
        };

        let mut world = sim::World::with_map(1, sim::build_pit);
        assert_ne!(
            world.cfg.respawn_delay, 123,
            "pick a value the baseline lacks"
        );
        let spread_before = world.cfg.mod_spread;

        crate::Room::apply_config(&mut world, &c);
        assert_eq!(world.cfg.respawn_delay, 123);
        assert_ne!(
            world.cfg.mod_spread, spread_before,
            "a five-degree fan is not a fifteen-degree one"
        );

        // And the harness still overrides the one it must, whatever the zone
        // asks for. A spawn scatter is the setting that would quietly erase
        // what is being measured: 250 px of it on a pit thirty-two tiles wide
        // throws both pilots off the map at the first death.
        c.spawn_radius = Some(250);
        let b = stage_bout([&STAGES[1], &STAGES[0]], 0, 0.5, 1, Some(&c));
        assert!(b.ticks > 0, "the bout ran");
        assert_eq!(
            b.sides[1].worn, 0,
            "the bare side stayed bare: a stage's kit is the whole of what it flies"
        );
        assert!(
            b.sides[0].kills + b.sides[1].kills > 0,
            "the pilots still found each other, so the scatter was overridden"
        );
    }

    /// Aggregation records each bout once on each side and makes the matrix
    /// complementary without running a tournament to prove its own arithmetic.
    #[test]
    fn the_matrix_is_the_same_read_either_way() {
        let bout = |first, second, decided| Bout {
            sides: [
                Side {
                    kills: first,
                    worn: 2,
                    ..Default::default()
                },
                Side {
                    kills: second,
                    worn: 3,
                    ..Default::default()
                },
            ],
            ticks: 17,
            decided,
        };
        let mut rows = stage_rows();
        let mut pair = PairTally::default();
        pair.record(&mut rows, 0, 1, bout(3, 1, true));
        pair.record(&mut rows, 0, 1, bout(2, 2, false));
        pair.finish(&mut rows, 0, 1);

        assert_eq!((rows[0].wins, rows[0].losses, rows[0].draws), (1, 0, 1));
        assert_eq!((rows[1].wins, rows[1].losses, rows[1].draws), (0, 1, 1));
        assert_eq!((rows[0].kills, rows[1].kills), (5, 3));
        assert_eq!((rows[0].worn, rows[1].worn), (2, 3));
        assert_eq!(rows[0].bouts(), 2);
        assert_eq!(rows[1].bouts(), 2);
        assert_eq!(rows[0].vs[1], Some(0.75));
        assert_eq!(rows[1].vs[0], Some(0.25));

        let mut mirror = PairTally::default();
        mirror.record(&mut rows, 2, 2, bout(4, 1, true));
        mirror.record(&mut rows, 2, 2, bout(1, 4, false));
        mirror.finish(&mut rows, 2, 2);
        assert_eq!(rows[2].mirror, 0.5);
        assert_eq!(rows[2].stalemates, 1);
        assert_eq!(rows[2].vs[2], None);
    }

    #[test]
    fn one_stage_bout_runs_the_simulation() {
        let bout = stage_bout_for([&STAGES[0], &STAGES[12]], 0, 0.5, 7, None, 1);
        assert_eq!(bout.ticks, 1);
        assert_eq!((bout.sides[0].worn, bout.sides[1].worn), (0, 0));
    }
}

mod skill_tests {
    use super::*;

    /// Does the skill dial separate pilots at all?
    ///
    ///     cargo run --release --manifest-path server/Cargo.toml -- \
    ///       calibrate diagnostics skill-ladder
    ///
    /// This fights a few hundred five-kill matches and takes minutes. The
    /// answer matters: `docs/design/ai-players.md` promises "a single skill dial from 0
    /// to 1" driving reaction, aim, discipline, awareness, greed and map use,
    /// and the whole population director rests on a 0.35 pilot being an easier
    /// evening than a 0.85 one.
    ///
    /// The committed ladder cannot answer it, because all eight calibrated
    /// pilots fly different hulls, so `zone/ladder.json` measures hull and
    /// skill together and cannot say which moved. This holds the hull still
    /// and varies only the dial, which is the one arrangement that can.
    pub(super) fn skill_alone_should_make_a_ladder() {
        // One hull for everybody. Class 1 is the anchor's own, so this is a
        // shape the roster already flies.
        const HULL: u8 = 1;
        const ROUNDS: u32 = 8;
        let roster: Vec<ai::RosterEntry> = [0.30f32, 0.45, 0.60, 0.75, 0.90]
            .iter()
            .map(|s| ai::RosterEntry {
                name: format!("skill{:02}", (s * 100.0) as u32),
                class: HULL,
                skill: *s,
            })
            .collect();

        let r = run_roster(&roster, ROUNDS, false);
        println!("\n  skill   rating   games");
        let mut seen: Vec<(f32, f64)> = Vec::new();
        for e in &roster {
            let score = r.rating_of(&e.name);
            println!(
                "   {:.2}   {:>6.1}   {:>5}",
                e.skill,
                score,
                r.games_of(&e.name)
            );
            seen.push((e.skill, score));
        }
        let lo = seen.first().expect("a roster").1;
        let hi = seen.last().expect("a roster").1;
        let gap = hi - lo;
        println!("\n  weakest {lo:.0}, strongest {hi:.0}, gap {gap:+.0}");

        // This read -26 once, inverted at r = -0.88, with the roster's worst
        // pilot beating its best about as often as a coin lands. What it was
        // measuring was a permission line at 0.35 deciding who was allowed to
        // bomb, and in a pit with no kit the pilot forbidden to bomb keeps
        // its bar and wins. See `skill_on_a_real_map` for the same question
        // asked where people play, and the ablation next door for which of
        // the dial's knobs was carrying it.
        //
        // A hundred points is a 64% result: the least this could mean and
        // still mean something.
        assert!(
            gap >= 100.0,
            "the skill dial should make a ladder, and makes {gap:+.0} points of one"
        );
    }
}

mod real_map_tests {
    use super::*;

    /// The same question the pit asks, asked on the map people play.
    ///
    ///     cargo run --release --manifest-path server/Cargo.toml -- \
    ///       calibrate diagnostics real-map
    ///
    /// Three things the pit run could not do, and the reasons it could not
    /// are exactly the objections to believing it:
    ///
    /// Alpha rather than a thirty-two tile box, so map use, awareness and
    /// route choice have somewhere to happen. Spawns twenty-four tiles apart
    /// and a scatter of zero, so the pilots have each other from the first
    /// tick and the tournament measures fighting instead of walking. And
    /// enough bouts for the answer to be worth reading: three hundred a pair,
    /// which puts the ninety-five per cent interval on a win rate at about
    /// six points, so a real advantage cannot hide inside the noise and a
    /// coin cannot look like one.
    ///
    /// Run twice over, with no kit and with one. The first is the pit's own
    /// control, holding the loadout still the way the hull is held. The second is the game as it ships, because greed and build
    /// planning are two of the six traits the dial is supposed to drive and
    /// a pilot with no kit cannot show either.
    pub(super) fn skill_on_a_real_map() {
        // Every hull, because the first two disagreed about nearly everything
        // and there is no reason the other five agree with either. Class 1 is
        // the Wedge, a Bombardier, and the hull this was measured on all
        // night: the bomb specialist, judged on a fix to bomb judgement. Class
        // 0 is the Apex, a Duelist that fights with its gun. Those two alone
        // put the same knob at a coin and at twenty-four points.
        //
        // Narrow it with VW_HULLS to shard across processes, which is how this
        // is actually run: seven hulls times three economies is more bouts
        // than one core should carry.
        let hulls: Vec<(u8, &str)> = env_list(
            "VW_HULLS",
            &(0..ai::CLASS_NAMES.len() as u32).collect::<Vec<_>>(),
        )
        .into_iter()
        .map(|c| (c as u8, ai::CLASS_NAMES[c as usize]))
        .collect();
        // The two kits a pilot actually fights in. Thirty points is the
        // shipped budget, so that is the game as it ships, and sixty asks
        // whether the flattening a kit does to a skill gap keeps going or
        // levels off.
        //
        // Bare is not one of them. It was worth running while the dial was
        // inverted, because it separates flying from carrying, but nobody
        // plays it: a pilot with no kit holds no charges at all, so a whole
        // branch of the AI is unreachable and a row of the skill table cannot
        // be measured there. Ranking pilots in a room that does not exist was
        // the habit worth dropping.
        let economies = env_list("VW_KIT", &[30, 60]);
        // Three hundred, which is what the doc comment above has always said
        // and what the constant drifted away from: the tables print an
        // interval of eight points, and six is what three hundred buys.
        //
        // It is also what the weakest block needs to be worth running. A built
        // Wedge separates at about 54% pooled, and seeing 54% at z of 3 takes
        // fourteen hundred decided bouts; two hundred a pair delivers eleven
        // hundred once the draws are out, which lands on 2.7 and answers
        // nothing either way. Buying resolution for an effect already known to
        // be small, not lowering a bar to meet it.
        let per_pair = env_list("VW_BOUTS", &[300])[0];
        let bytes = real_map();
        let probe = sim::World::from_packed(0x5eed, &bytes).expect("a map");
        let at = open_pair(&probe.map);
        let route = nav::Nav::build(&probe.map);
        // One row a skill: the dial, the five figures the drill reports, and
        // the two counts under them.
        type Gap = (u32, f64, f64, f64, f64, f64, usize, usize);
        let mut gaps: Vec<Gap> = Vec::new();
        for (hull, hull_name) in hulls {
            // Percent, because env_list deals integers: VW_SKILLS=5,30,90
            // fields a 0.05 pilot against the usual pair. The default is the
            // span the game actually deals: the fill formula runs 0.05 to
            // 0.90, so a tournament that started at 0.30 would be certifying
            // a third of the fielded roster on faith. The bottom rung is
            // where the aim floor lives and the top is where the old dial
            // always was, with the middle spaced to catch a dead band.
            let roster: Vec<ai::RosterEntry> = env_list("VW_SKILLS", &[5, 25, 45, 70, 90])
                .iter()
                .map(|s| ai::RosterEntry {
                    name: format!("{hull}skill{s:02}"),
                    class: hull,
                    skill: *s as f32 / 100.0,
                })
                .collect();

            for budget in economies.iter().copied() {
                println!("\n### {hull_name} ###");
                let mut rates: Vec<f64> = Vec::new();
                // The roster's two ends, which is the span the dial is meant
                // to cover and the pair the size bar is written about.
                let mut ends = 0.0f64;
                let (mut strong_wins, mut all_decided) = (0u64, 0u64);
                println!(
                    "\n=== alpha, spawns {APART} tiles apart, {per_pair} bouts a pair, \
                 a {budget}-point kit a life ==="
                );
                let mut r = rating::Rating::new();
                // A window per economy, so two of them are never the same
                // bouts wearing different kit.
                let mut salt = budget * 500_000;

                // The coin this fixture actually deals, measured rather than
                // assumed, on the same salts the pairs use so it sees the same
                // starts in the same order.
                //
                // It is a control and not a correction, and the difference
                // matters. The ablation's null row once read 62% and was
                // written down as a side bias worth reading every table
                // against; four hundred bouts on independent salts then read
                // 54.2% and 47.2% in the two economies, and the Apex read
                // 52.4% on the very salts where the Wedge read 62. One
                // reading had been believed twice. `duel` deals each pilot the
                // four combinations of start tile, facing and seat in equal
                // numbers, so there was never anywhere for a positional bias
                // to live.
                //
                // So this row is not subtracted from anything: subtracting a
                // number with four points of noise from one with seven adds
                // error rather than removing it. It is asserted on instead. A
                // block whose identical pilots do not split near half is a
                // block where `duel` has broken, and nothing else printed
                // under it can be read.
                let mut null = rating::Rating::new();
                let (mut nw, mut nl, mut nd) = (0u32, 0u32, 0u32);
                {
                    let mid = ai::RosterEntry {
                        name: "null_a".into(),
                        class: hull,
                        skill: 0.60,
                    };
                    let same = ai::RosterEntry {
                        name: "null_b".into(),
                        class: hull,
                        skill: 0.60,
                    };
                    let mut s = salt;
                    for _ in 0..per_pair {
                        let (ka, kb) =
                            duel(&bytes, &route, at, &mut null, &mid, &same, s, budget, None);
                        s = s.wrapping_add(1);
                        match ka.cmp(&kb) {
                            std::cmp::Ordering::Greater => nw += 1,
                            std::cmp::Ordering::Less => nl += 1,
                            std::cmp::Ordering::Equal => nd += 1,
                        }
                    }
                }
                let coin = nw as f64 / (nw + nl).max(1) as f64;
                println!("   pair            won   lost   drew    rate      95% ci");
                println!(
                    "  null, both 0.60 {nw:>5}  {nl:>5}  {nd:>5}   {:>5.1}%   <- the coin",
                    coin * 100.0
                );
                for i in 0..roster.len() {
                    for j in (i + 1)..roster.len() {
                        let (a, b) = (&roster[i], &roster[j]);
                        let (mut wa, mut wb, mut drew) = (0u32, 0u32, 0u32);
                        for _ in 0..per_pair {
                            let (ka, kb) =
                                duel(&bytes, &route, at, &mut r, a, b, salt, budget, None);
                            salt = salt.wrapping_add(1);
                            match ka.cmp(&kb) {
                                std::cmp::Ordering::Greater => wa += 1,
                                std::cmp::Ordering::Less => wb += 1,
                                std::cmp::Ordering::Equal => drew += 1,
                            }
                        }
                        // The weaker pilot's share of the decided bouts. Half of
                        // it is a dial that does nothing.
                        let decided = (wa + wb).max(1) as f64;
                        let rate = wa as f64 / decided;
                        rates.push(rate);
                        // Pooled across every pair, which is the only view of
                        // this table with the power to see a weak dial: one
                        // pair's interval is eight points wide and adjacent
                        // rungs are 0.15 apart, so no pair can resolve them,
                        // while fourteen hundred decided bouts put the
                        // standard error near one point.
                        strong_wins += wb as u64;
                        all_decided += (wa + wb) as u64;
                        if i == 0 && j == roster.len() - 1 {
                            ends = 1.0 - rate;
                        }
                        let ci = 1.96 * (rate * (1.0 - rate) / decided).sqrt();
                        println!(
                        "  {:.2} v {:.2}   {wa:>5}  {wb:>5}  {drew:>5}   {:>5.1}%   +/- {:>4.1}",
                        a.skill,
                        b.skill,
                        rate * 100.0,
                        ci * 100.0
                    );
                    }
                }
                println!("\n   skill   rating   games");
                for e in &roster {
                    println!(
                        "    {:.2}   {:>6.1}   {:>5}",
                        e.skill,
                        r.rating_of(&e.name),
                        r.games_of(&e.name)
                    );
                }
                let lo = r.rating_of(&roster[0].name);
                let hi = r.rating_of(&roster[roster.len() - 1].name);
                let gap = hi - lo;
                println!("   weakest {lo:.0}, strongest {hi:.0}, gap {gap:+.0}");

                // Counted here, judged at the end. Asserting inside the loop
                // aborted the run on the first economy and hid the second, which
                // is the half a change is usually aimed at.
                // Against the coin the fixture deals, not against a half.
                let leaning = rates.iter().filter(|r| **r < coin).count();
                // What the stronger pilot takes of the decided bouts, over
                // every pair rather than the two ends. The Elo gap uses two of
                // five pilots and throws the middle three away, and
                // `is_the_built_ladder_a_measurement` puts a number on what
                // that costs: five runs of the *bare* field, the one that
                // separates cleanly, read 93, 64, 112, 138 and 158. A
                // statistic with a spread of thirty cannot carry a threshold
                // at a hundred without flaking on its own good days.
                //
                // This one pools every bout. Around fifteen hundred decided
                // bouts a run puts its standard error near a point, so a
                // reading of 65% sits ten deviations off a coin where the same
                // data's gap sits three. Same measurement, better instrument.
                let edge = strong_wins as f64 / all_decided.max(1) as f64;
                // How far that sits from a coin, in its own standard errors.
                let z = (edge - 0.5) / (0.25 / all_decided.max(1) as f64).sqrt();
                println!(
                    "   {leaning} of {} pairs beat the coin; ends {:.1}%, pooled {:.1}% \
                     over {all_decided} decided (z {z:.1}), null row {:.1}%",
                    rates.len(),
                    ends * 100.0,
                    edge * 100.0,
                    coin * 100.0
                );
                gaps.push((budget, gap, coin, ends, edge, z, leaning, rates.len()));
            }
        }

        // Two properties, and the bar is the one this test always asked for.
        //
        // Every pair leaning the right way survives a small effect: ten
        // independent pairs on one side of a coin is a thousand to one, so it
        // sees a real but weak dial where no single pair's interval could.
        //
        // Then the size of the effect across the roster's span, which used to
        // be written as a hundred points of Elo and is now written as the win
        // rate that number stood for. The old comment here said a hundred
        // points "is a 64% result and the least this can mean and still mean
        // something", so 64% is the same bar, asked of the same pair: 0.30
        // against 0.90. What changed is the instrument. Five runs of the bare
        // field, the one that separates cleanly, read 93, 64, 112, 138 and
        // 158, so the Elo gap carries a spread of thirty-three against a
        // threshold of a hundred and would fail on the fixture's own good
        // days. The pair's own win rate is the same measurement with a
        // standard error of six.
        //
        // The Elo gap also understates the span whenever the middle of the
        // roster is bunched, because the fit has to place five pilots at once:
        // with a kit on, the ends sit at 67% and the gap reads +38.
        // And the bar is read against the null row rather than against a half,
        // for the reason the null row exists. Sixty-four per cent in a fair
        // fixture is the weaker pilot on thirty-six, fourteen points below its
        // coin; here it is fourteen points below whatever coin the fixture
        // dealt this block. The same bar with one fewer assumption.
        // Three things, in the order a reader should want them.
        //
        // First the control: whatever the fixture deals two identical pilots
        // should be a coin, and if it is not then nothing below means what it
        // says. Four hundred bouts on independent salts read 54.2% and 47.2%
        // in the two economies, so this passes today and exists to shout on
        // the day some change to `duel` breaks the symmetry.
        //
        // Then the size of the effect across the roster's span, which is the
        // bar this test always carried. It used to be written as a hundred
        // points of Elo; the comment that set it said a hundred points "is a
        // 64% result and the least this can mean and still mean something", so
        // 64% it stays, asked of the pair it was written about. The Elo gap is
        // not the instrument any more because it cannot resolve that: five
        // runs of the bare field read 93, 64, 112, 138 and 158, thirty points
        // of spread against a hundred-point threshold, and the gap understates
        // the span besides whenever the middle of the roster is bunched.
        //
        // Then the ordering, which used to be every one of ten pairs landing
        // on the right side of a coin. That is the right hypothesis and the
        // wrong test of it. Adjacent rungs are 0.15 apart and a pair's own
        // interval is eight points wide, so no single pair has the power to
        // order them however well the dial works, and the count fails on
        // whichever adjacent pair the noise picks. Pooling every decided bout
        // in the block tests the same claim at the same strength: z of 3 is
        // the same thousand-to-one the ten-pair count was reaching for, and
        // it spends the evidence instead of discarding it. The per-pair count
        // is still printed, as a diagnostic.
        const ENDS: f64 = 0.64;
        const Z: f64 = 3.0;
        for (budget, gap, coin, ends, edge, z, leaning, pairs) in gaps {
            let economy = format!("{budget} points");
            assert!(
                (coin - 0.5).abs() <= 0.15,
                "at {economy}, the fixture deals {:.1}% to two identical pilots, \
                 so nothing else in this block can be read",
                coin * 100.0
            );
            assert!(
                ends >= ENDS,
                "at {economy}, 0.90 takes {:.1}% of its decided bouts off 0.30 \
                 (wanted {:.0}%), on a ladder of {gap:+.0}",
                ends * 100.0,
                ENDS * 100.0
            );
            assert!(
                z >= Z,
                "at {economy}, the stronger pilot takes {:.1}% of all decided bouts, \
                 z {z:.1} against a wanted {Z:.1} ({leaning} of {pairs} pairs beat the coin)",
                edge * 100.0
            );
        }
    }

    /// What one bout costs on the real map, so a run can be sized.
    ///
    ///     cargo run --release --manifest-path server/Cargo.toml -- \
    ///       calibrate diagnostics time-bout
    pub(super) fn time_one_real_map_bout() {
        let bytes = real_map();
        let probe = sim::World::from_packed(0x5eed, &bytes).expect("a map");
        let at = open_pair(&probe.map);
        println!("spawns at {:?} and {:?}", at.0, at.1);
        let route = nav::Nav::build(&probe.map);
        let mut r = rating::Rating::new();
        let weak = ai::RosterEntry {
            name: "weak".into(),
            class: 1,
            skill: 0.30,
        };
        let strong = ai::RosterEntry {
            name: "strong".into(),
            class: 1,
            skill: 0.90,
        };
        let t = std::time::Instant::now();
        let mut kills = (0u32, 0u32);
        for salt in 0..10u32 {
            let (a, b) = duel(&bytes, &route, at, &mut r, &weak, &strong, salt, 0, None);
            kills.0 += a as u32;
            kills.1 += b as u32;
        }
        println!(
            "10 bouts in {:.1}s, kills weak {} strong {}",
            t.elapsed().as_secs_f32(),
            kills.0,
            kills.1
        );
    }
}

mod ablation {

    use super::*;

    /// Which of the dial's six parameters is doing the work?
    ///
    ///     cargo run --release --manifest-path server/Cargo.toml -- \
    ///       calibrate diagnostics ablation
    ///
    /// Two pilots at 0.90 in every respect but one, where one of them is held
    /// at 0.30. A knob that matters shows up as a win rate away from half; a
    /// knob that does nothing shows up as a coin. The tournament could not ask
    /// this, because moving the dial moves all six at once.
    pub(super) fn which_knob_carries_the_dial() {
        const PER_KNOB: u32 = 200;
        // Both hulls, for the reason the ladder tournament grew a second one:
        // every row this printed came from the Wedge, and the Wedge is the
        // bomb specialist. A knob read on one ship is a fact about that ship.
        const HULLS: [(u8, &str); 2] = [(1, "Wedge, Bombardier"), (0, "Apex, Duelist")];
        let (bytes, route, at) = real_map_fixture();

        for (hull, hull_name) in HULLS {
            let strong = ai::RosterEntry {
                name: "strong".into(),
                class: hull,
                skill: 0.90,
            };
            let same = ai::RosterEntry {
                name: "same".into(),
                class: hull,
                skill: 0.90,
            };

            for budget in env_list("VW_KIT", &[0, 30, 60]).iter().copied() {
                println!(
                    "\n=== {hull_name}: one knob at 0.30, the rest at 0.90, \
                     a {budget}-point kit a life ==="
                );
                println!("  knob          handicapped wins   rate      95% ci");
                for knob in [
                    // Nothing handicapped at all, which this had no business
                    // running without: every other row is read against a coin,
                    // and whether this harness deals one is a question rather
                    // than an assumption. Two identical pilots, alternating
                    // sides. Anything far from half here is the fixture talking.
                    None,
                    Some(ai::Knob::AimErr),
                    Some(ai::Knob::Permission),
                ] {
                    let mut r = rating::Rating::new();
                    let (mut w, mut l, mut d) = (0u32, 0u32, 0u32);
                    let mut salt = 900_000u32;
                    for _ in 0..PER_KNOB {
                        let (ka, kb) = duel(
                            &bytes,
                            &route,
                            at,
                            &mut r,
                            &strong,
                            &same,
                            salt,
                            budget,
                            knob.map(|k| (k, 0.30)),
                        );
                        salt = salt.wrapping_add(1);
                        match ka.cmp(&kb) {
                            std::cmp::Ordering::Greater => w += 1,
                            std::cmp::Ordering::Less => l += 1,
                            std::cmp::Ordering::Equal => d += 1,
                        }
                    }
                    let decided = (w + l).max(1) as f64;
                    let rate = w as f64 / decided;
                    let ci = 1.96 * (rate * (1.0 - rate) / decided).sqrt();
                    println!(
                        "  {:<12}  {w:>5} / {l:<5} {d:>4}d   {:>5.1}%   +/- {:>4.1}",
                        knob.map_or("none".to_string(), |k| format!("{k:?}")),
                        rate * 100.0,
                        ci * 100.0
                    );
                }
            }
        }
    }
}

mod stability {

    use super::*;

    /// Is the built field's ladder a small effect, or an unsteady number?
    ///
    ///     cargo run --release --manifest-path server/Cargo.toml -- \
    ///       calibrate diagnostics stability
    ///
    /// It has read -52, +4, +19, +28, +32, +39, +58 and +60 across
    /// configurations, several of which could not touch it, while the bare
    /// field's stayed inside a band of forty. Two readings are worth telling
    /// apart, and they want opposite responses: a real gap estimated noisily,
    /// which more bouts would settle, or an unsteady statistic, which more
    /// bouts would not.
    ///
    /// So: the same pilots, the same map, five separate tournaments on
    /// disjoint salts. If the gap is a measurement its five values sit near
    /// each other whatever their mean; if it is weather, they do not.
    pub(super) fn is_the_built_ladder_a_measurement() {
        const PER_PAIR: u32 = 120;
        const RUNS: u32 = 5;
        let (bytes, route, at) = real_map_fixture();
        let roster: Vec<ai::RosterEntry> = [0.30f32, 0.60, 0.90]
            .iter()
            .map(|s| ai::RosterEntry {
                name: format!("skill{:02}", (s * 100.0) as u32),
                class: 1,
                skill: *s,
            })
            .collect();

        for budget in env_list("VW_KIT", &[0, 30]).iter().copied() {
            let mut gaps: Vec<f64> = Vec::new();
            for run in 0..RUNS {
                let mut r = rating::Rating::new();
                let mut salt = 3_000_000u32 + run * 100_000;
                for i in 0..roster.len() {
                    for j in (i + 1)..roster.len() {
                        for _ in 0..PER_PAIR {
                            duel(
                                &bytes, &route, at, &mut r, &roster[i], &roster[j], salt, budget,
                                None,
                            );
                            salt = salt.wrapping_add(1);
                        }
                    }
                }
                let lo = r.rating_of(&roster[0].name);
                let hi = r.rating_of(&roster[roster.len() - 1].name);
                gaps.push(hi - lo);
            }
            let mean = gaps.iter().sum::<f64>() / gaps.len() as f64;
            let sd =
                (gaps.iter().map(|g| (g - mean).powi(2)).sum::<f64>() / gaps.len() as f64).sqrt();
            println!(
                "\n  {budget} points: gaps {:?}",
                gaps.iter().map(|g| g.round() as i64).collect::<Vec<_>>()
            );
            println!("  mean {mean:+.0}, spread {sd:.0}");
        }
    }
}

mod draws {

    use super::*;

    /// What a drawn bout in a built field actually looks like.
    ///
    ///     cargo run --release --manifest-path server/Cargo.toml -- \
    ///       calibrate diagnostics draws
    ///
    /// Half the bouts with a kit on end level, and a level bout carries no
    /// information, so the built economy is measured on half the sample the
    /// bare one gets. Whether that is worth fixing depends entirely on what
    /// the draws are: nought-all means two pilots that never found each other,
    /// which is the fixture's problem, and three-all means they found each
    /// other and ran out of clock, which is the match length's.
    pub(super) fn what_a_draw_is_made_of() {
        let (bytes, route, at) = real_map_fixture();
        let a = ai::RosterEntry {
            name: "a".into(),
            class: 1,
            skill: 0.90,
        };
        let b = ai::RosterEntry {
            name: "b".into(),
            class: 1,
            skill: 0.30,
        };
        let mut r = rating::Rating::new();
        let mut tally: std::collections::BTreeMap<i16, u32> = Default::default();
        let mut decided = 0u32;
        for salt in 0..60u32 {
            let (ka, kb) = duel(&bytes, &route, at, &mut r, &a, &b, salt, 30, None);
            if ka == kb {
                *tally.entry(ka).or_default() += 1;
            } else {
                decided += 1;
            }
        }
        println!("\n  decided {decided} of 60");
        for (kills, n) in &tally {
            println!("  drawn {n:>3} at {kills}-{kills}");
        }
    }
}

mod fixture {

    use super::*;

    /// Where the twelve points the null row keeps reading actually come from.
    ///
    ///     cargo run --release --manifest-path server/Cargo.toml -- \
    ///       calibrate diagnostics fixture
    ///
    /// Two pilots identical in class, skill, tuning and everything else, and
    /// one of them takes 62% of the decided bouts in a bare field. It has been
    /// written down as unexplained since the ablation grew a null row, and
    /// living with it was a mistake: it is larger than most of the effects
    /// being measured against it, and it is the reason a pair reading 63.7%
    /// cannot be told from a pair of equals.
    ///
    /// `duel` alternates four things on the salt, and the argument for the
    /// bias being harmless was that all four cancel. So split the same bouts
    /// by what the salt decided and see which slice is lopsided. A bias that
    /// really is positional shows up as two halves at 62 and 38 that a caller
    /// is folding wrongly; a bias in every slice is not positional at all and
    /// the four alternations are beside the point.
    pub(super) fn what_the_coin_is_weighted_by() {
        const BOUTS: u32 = 400;
        let (bytes, route, at) = real_map_fixture();
        let a = ai::RosterEntry {
            name: "a".into(),
            class: 1,
            skill: 0.60,
        };
        let b = ai::RosterEntry {
            name: "b".into(),
            class: 1,
            skill: 0.60,
        };
        for budget in env_list("VW_KIT", &[0, 30]).iter().copied() {
            // Indexed by salt % 4, which is what picks the start tile and the
            // facing between them.
            let mut won = [0u32; 4];
            let mut lost = [0u32; 4];
            let mut r = rating::Rating::new();
            for salt in 0..BOUTS {
                let (ka, kb) = duel(&bytes, &route, at, &mut r, &a, &b, salt, budget, None);
                let s = (salt % 4) as usize;
                match ka.cmp(&kb) {
                    std::cmp::Ordering::Greater => won[s] += 1,
                    std::cmp::Ordering::Less => lost[s] += 1,
                    std::cmp::Ordering::Equal => {}
                }
            }
            println!("\n=== two pilots at 0.60, nothing between them, a {budget}-point kit ===");
            println!("   salt%4   a starts   a faces     a won   a lost    rate");
            for s in 0..4 {
                let decided = (won[s] + lost[s]).max(1) as f64;
                println!(
                    "     {s}      {}      {}   {:>7}  {:>7}   {:>5.1}%",
                    if s % 2 == 0 { "at.0" } else { "at.1" },
                    if s < 2 {
                        if s % 2 == 0 {
                            "north"
                        } else {
                            "south"
                        }
                    } else if s % 2 == 0 {
                        "south"
                    } else {
                        "north"
                    },
                    won[s],
                    lost[s],
                    won[s] as f64 / decided * 100.0
                );
            }
            let w: u32 = won.iter().sum();
            let l: u32 = lost.iter().sum();
            println!(
                "   all      {w:>7}  {l:>7}   {:>5.1}%",
                w as f64 / (w + l).max(1) as f64 * 100.0
            );
        }
    }
}

mod kit {

    use super::*;

    /// Does a pilot in this harness actually carry what it was handed?
    ///
    ///     cargo run --release --manifest-path server/Cargo.toml -- \
    ///       calibrate diagnostics kit
    ///
    /// A budget that silently grants nothing would make every economy in the
    /// sweep the bare one and the tables would still look plausible, so this
    /// counts what is on the hull rather than what was asked for. The
    /// interesting numbers are that the count rises with the offer, that both
    /// sides get the same, and that the ceiling is reached at sixty.
    pub(super) fn the_kit_is_matched_and_real() {
        let (bytes, route, at) = real_map_fixture();
        let _ = route;
        for budget in [0u32, 30, 60] {
            let mut world = sim::World::from_packed(0xd0e1, &bytes).expect("a map");
            world.cfg.spawn_radius = 0;
            let s1 = world.spawn(0, 0, at.0 .0, at.0 .1, 0) as u8;
            let s2 = world.spawn(0, 1, at.1 .0, at.1 .1, 32768) as u8;
            let seed = 0x9E37_79B9u32 | 1;
            let mut prng = [seed, seed];
            for (k, s) in [s1, s2].iter().enumerate() {
                deal_kit(&mut world, *s as usize, budget, &mut prng[k]);
            }
            let held = |s: u8| {
                let sh = &world.state.ships[s as usize];
                let ups: u32 = sh.up.iter().map(|u| *u as u32).sum();
                let lvl: u32 = sh.level.iter().map(|l| *l as u32).sum();
                // Two bits a rung, six add-ons a trigger, which is the same
                // packing `sim_mod_get` reads.
                let mods: u32 = (0..sim::TRIG_COUNT)
                    .flat_map(|t| (0..sim::MOD_COUNT).map(move |m| (t, m)))
                    .map(|(t, m)| ((sh.mods[t] >> (m * 2)) & 3) as u32)
                    .sum();
                let ch: u32 = sh.charge.iter().map(|c| *c as u32).sum();
                (ups, lvl, mods, ch)
            };
            let (u1, l1, m1, c1) = held(s1);
            let (u2, l2, m2, c2) = held(s2);
            println!(
                "  {budget:>2} points: a has {u1} stat steps, gun+bomb {l1}, {m1} add-ons, \
                 {c1} charges; b has {u2}/{l2}/{m2}/{c2}"
            );
            if budget == 0 {
                assert_eq!(
                    (u1, l1, m1, c1),
                    (0, 0, 0, 0),
                    "a bare pilot should carry nothing"
                );
            } else {
                assert!(u1 + l1 + m1 + c1 > 0, "{budget} points bought nothing");
            }
            assert_eq!(
                (u1, l1, m1, c1),
                (u2, l2, m2, c2),
                "at {budget} points the two pilots drew different kit"
            );
        }
    }
}
