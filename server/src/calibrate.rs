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
use crate::{ai, catalog, config, nav, rating, sim};

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
                    &bytes, &route, at, &mut r, &roster[i], &roster[j], salt, None,
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

/// What one side did in one bout.
#[derive(Clone, Copy, Default)]
pub struct Side {
    pub kills: u32,
    /// Trigger pulls, by trigger, so a hull nobody fired can be told from one
    /// that was fired and lost.
    pub shots: [u32; sim::TRIG_COUNT],
    /// Damaging impacts on somebody else, and what they came to. A count alone
    /// cannot tell a fuse that lands more often from one that lands harder,
    /// and a blast falls off to nothing at its rim.
    pub hits: u32,
    pub damage: u64,
    /// And the same, landed on yourself. A blast has no owner test, so this is
    /// the count that says whether a hull is losing because the pilot flying
    /// it keeps standing in its own bomb.
    pub self_hits: u32,
    pub self_damage: u64,
}

pub struct Bout {
    pub sides: [Side; 2],
    /// Whether somebody reached the kill target. A pair that mostly times out
    /// is a pair whose numbers mean less than they look.
    pub decided: bool,
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
    Built(fn(&mut sim::sim_map)),
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

/// Two hulls, one bout, and nothing between them but the ships.
///
/// This is the whole balance question in a preconstructed game. It used to
/// need a kit budget on top, because a hull was a shape and a budget bought
/// the rest of the ship; both sides carry their own profiles now, so the only
/// variable left is which two hulls are in the room.
pub fn hull_bout(
    classes: [u8; 2],
    skill: f32,
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
    map: &Arena,
) -> Bout {
    // Sides alternate, so the room's geometry cannot turn into a result. The
    // seats keep their places and their bot seeds; it is the hulls that move.
    let flip = salt % 2 == 1;
    let seats: [u8; 2] = if flip {
        [classes[1], classes[0]]
    } else {
        classes
    };
    let dead = Bout {
        sides: [Side::default(); 2],
        decided: false,
    };
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

    let mut out = [Side::default(); 2];

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

        // The profile goes back on at the dead-to-alive edge, which the core
        // does at the spawn, so this only tracks the edge itself.
        for k in 0..2 {
            alive_was[k] = world.state.ships[ships[k] as usize].alive != 0;
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
        decided,
    }
}

/// Every hull against every other, `bouts` times each, at one bounty.
pub fn run_hulls(
    skill: f32,
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
                let b = hull_bout([i as u8, j as u8], skill, salt, tuning, map);
                salt = salt.wrapping_add(1);

                for (k, side) in [(i, b.sides[0]), (j, b.sides[1])] {
                    rows[k].kills += side.kills;
                    rows[k].hits += side.hits;
                    rows[k].damage += side.damage;
                    rows[k].self_hits += side.self_hits;
                    rows[k].self_damage += side.self_damage;
                    for t in 0..sim::TRIG_COUNT {
                        rows[k].shots[t] += side.shots[t];
                    }
                }

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
    bouts: u32,
    zone: &str,
    map: &str,
    built: &Arena,
) -> serde_json::Value {
    let n = rows.len();
    println!(
        "\nhull tournament: {zone} tuning on the {map}, skill {skill:.2}, \
{bouts} bouts a pair, {n} hulls"
    );

    println!(
        "\n{:<10} {:>7} {:>7} {:>7} {:>7} {:>8} {:>7} {:>6} {:>7}",
        "hull", "win%", "+-95%", "guns", "bombs", "hit/pull", "dmg/hit", "self%", "mirror"
    );
    for r in rows {
        let fired: u32 = r.shots.iter().sum();
        println!(
            "{:<10} {:>7.1} {:>7.1} {:>7} {:>7} {:>8.2} {:>7.0} {:>6.1} {:>7.1}",
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
        // The map's own bytes, so two runs a month apart can be told apart
        // when the map has moved under them and the name has not.
        "map_fingerprint": built.fingerprint(),
        "skill": skill,
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

struct TeamMatchOptions {
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

/// Open the match once every seat is filled: full bars, loaded charges and
/// authored starts, exactly as a live room does at the whistle.
///
/// It used to dress each seat first, from a random kit or an author's, and
/// this is what is left of that: a hull deals its own profile at the spawn, so
/// there is nothing to hand anybody. Spawning and leaving it there measured a
/// fixture the game never deliberately opens, which is the part worth keeping.
fn dress_team(world: &mut sim::World) -> bool {
    world.restart();
    crate::room::face_public_teams(world);
    true
}

fn team_match_with_options(
    lineup: &[u8],
    skill: f32,
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
    map: &Arena,
    options: TeamMatchOptions,
) -> (Vec<Seat>, bool) {
    let per_side = lineup.len() / 2;
    let Some(mut world) = team_world(salt, tuning, map) else {
        return (Vec::new(), false);
    };
    let route = nav::Nav::build(&world.map);
    let route = &route;

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
    if !dress_team(&mut world) {
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
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
    map: &Arena,
) -> (Vec<Seat>, bool) {
    team_match_with_options(
        lineup,
        skill,
        salt,
        tuning,
        map,
        TeamMatchOptions {
            tick_limit: MATCH_TICKS,
            kill_target_per_player: Some(KILL_TARGET),
        },
    )
}

/// Fill both sides at random, `matches` times, and read each hull off its seats.
pub fn run_teams(
    per_side: usize,
    matches: u32,
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
        let (seats, decided) = team_match(&lineup, skill, m, tuning, map);
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
    matches: u32,
    zone: &str,
    map: &str,
    spawn_radius: u16,
) -> serde_json::Value {
    println!(
        "\nteam tournament: {per_side} a side, {zone} tuning on the {map}, skill \
{skill:.2}, spawn radius {spawn_radius}, {matches} matches, \
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
        "spawn_radius": spawn_radius, "matches": matches,
        "hulls": rows.iter().map(|r| serde_json::json!({
            "name": r.name, "class": r.class, "seats": r.seats, "won": r.won,
            "drawn": r.drawn, "win_rate": r.win_rate(), "win_rate_margin": r.margin(),
            "kills": r.kills, "deaths": r.deaths,
            "gun_shots": r.shots[sim::TRIG_GUN], "bomb_shots": r.shots[sim::TRIG_BOMB],
            "mean_planned_range": r.planned_range / r.planned_range_samples.max(1) as f64,
            "mean_engagement_distance": r.engagement_distance / r.engagement_samples.max(1) as f64,
            "hits": r.hits, "damage": r.damage, "self_damage": r.self_damage,
        })).collect::<Vec<_>>(),
    })
}

/* ---- the real-map fixture ------------------------------------------
 *
 * The ladder and every harness that ranks pilots share one room and one
 * bout, because two of them drifting apart is how this file ended up
 * with a tournament that measured something nobody plays.
 */

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
    handicap: Option<(ai::Knob, f32)>,
) -> (i16, i16) {
    let mut world = sim::World::from_packed(0xd0e1 ^ salt, bytes).expect("a map");
    // Nothing is handed out. Both pilots fly their own hull's profile, so the
    // only thing varying between them is the pilot, which is what this
    // harness exists to rank.
    //
    // It used to matter a great deal. A bool meaning "let Alpha do what it
    // does" put thirty upgrades at the spawn and forty-two more on the floor,
    // and whoever scavenged better carried a kit the other did not have,
    // which landed on top of every number this harness printed.
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
        // The profile goes back on at the dead-to-alive edge, which the core
        // does at the spawn, so there is nothing to re-deal here. What is
        // left is watching the edge itself, since a bout counts lives.
        for (k, s) in [s1, s2].iter().enumerate() {
            alive_was[k] = world.state.ships[*s as usize].alive != 0;
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
pub const PILOT_ECONOMY: &str = "preconstructed-hull-profiles";
const PILOT_ZONE: &str = "melee";
const PILOT_ZONE_FILE: &str = "catalog/zones/melee/zone.toml";
const PILOT_MAP_FILE: &str = "catalog/zones/melee/gantry.vwmap";
const PILOT_ZONE_DECLARED_MAP: &str = "gantry.vwmap";
const PILOT_ZONE_BYTES: &[u8] = include_bytes!("../../catalog/zones/melee/zone.toml");
const PILOT_MAP_BYTES: &[u8] = include_bytes!("../../catalog/zones/melee/gantry.vwmap");
const PILOT_WORLD_SEED_LABEL: u64 = 0x0077_6f72_6c64;
const PILOT_BOOTSTRAP_SEED_LABEL: u64 = 0x626f_6f74_7374_7261;
/// Deaths that take one leg of the tournament.
///
/// The harness's own rule rather than the zone's. It measures two pilots
/// against each other, and one life apiece is what makes a leg a clean
/// observation: a first-to-three would fold three fights into one number and
/// tell us less about each of them.
const PILOT_FIXTURE_FIRST_TO: u16 = 1;

/// How far past regulation a leg is flown before the harness gives up on it.
///
/// The live game draws at the whistle, and this rig deliberately does not:
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
            Self::InvalidFixture(message) => write!(f, "invalid fixture: {message}"),
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
    /// The personality this pilot flies with. It has nothing to do with what
    /// the ship carries any more: a hull is preconstructed, so the strategy is
    /// how this pilot uses the ship it was written into.
    pub strategy: String,
    /// The hull, by index, and the profile it flies. Recorded rather than
    /// derived so a saved fixture still says what was actually flown if the
    /// roster is retuned under it.
    pub class: u8,
    pub kit: Vec<u8>,
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
                || pilot.class as usize >= sim::MAX_CLASSES
            {
                return Err(PilotCalibrationError::InvalidFixture(format!(
                    "pilot kit {} is malformed",
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
    if definition.mode != PILOT_ZONE {
        return Err(PilotCalibrationError::InvalidFixture(format!(
            "{PILOT_ZONE_FILE} runs mode {:?}, not the game this measures",
            definition.mode
        )));
    }
    let first_to = PILOT_FIXTURE_FIRST_TO;
    // Calibration flies one fixed map, and that map has to be ground the live
    // zone actually serves: a rating measured somewhere nobody plays describes
    // nothing. The zone rotates, so the fixture asks to be in the rotation
    // rather than to be the whole of it.
    if !definition
        .maps
        .iter()
        .any(|name| name == PILOT_ZONE_DECLARED_MAP)
    {
        return Err(PilotCalibrationError::InvalidFixture(format!(
            "the shipped zone rotates {:?}, which does not include the calibration map {PILOT_ZONE_DECLARED_MAP:?}",
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
            "the fixture tuning only partially applied: {}",
            warnings.join("; ")
        )));
    }
    if roster
        .iter()
        .any(|pilot| pilot.hull >= probe.cfg.class_count)
    {
        return Err(PilotCalibrationError::InvalidRoster(
            "a pilot names a hull outside the fixture".into(),
        ));
    }
    let (_, starts_per_team) = probe.map.spawns();
    if starts_per_team.contains(&0) {
        return Err(PilotCalibrationError::InvalidFixture(
            "the calibration map needs a start for each side".into(),
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

    // What each pilot flies, which is the hull it was written into and that
    // hull's own profile. There is nothing an account could own that would
    // change it, so the two ownership ceilings this used to record are gone
    // along with the shop that moved them.
    let pilot_kits: Vec<FixturePilotKit> = roster
        .iter()
        .map(|pilot| FixturePilotKit {
            pilot_id: pilot.id.0,
            callsign: pilot.callsign.clone(),
            strategy: format!("{:?}", pilot.behavior.strategy),
            class: pilot.hull,
            kit: probe.profile(pilot.hull).to_vec(),
        })
        .collect();
    let regulation_ticks = definition.arena.match_seconds.unwrap_or(180) as u32 * 100;
    let overtime_safety_ticks = regulation_ticks
        .checked_mul(PILOT_OVERTIME_SAFETY_MULTIPLIER)
        .ok_or_else(|| {
            PilotCalibrationError::InvalidFixture("the fixture clock overflows ticks".into())
        })?;
    let zone_fingerprint = fingerprint(&[&raw]);
    let map_fingerprint = fingerprint(&[&map]);
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
        start_policy.as_bytes(),
        start_bytes.as_bytes(),
        heading_policy.as_bytes(),
        kit_bytes.as_bytes(),
        include_bytes!("bots.rs"),
        include_bytes!("catalog.rs"),
        include_bytes!("config.rs"),
        include_bytes!("pilots.rs"),
        include_bytes!("room.rs"),
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
        pilot_kits,
        limitations: vec![
            "Every pilot flies its own hull's profile, recorded in this manifest. A retune of the roster is a different fixture, which the fingerprint says.".into(),
            "The live game draws at the whistle; this harness flies each leg to a death instead, so an undecided matchup is measured rather than censored. It censors a leg after ten additional regulation clocks, records it, and refuses certification if any leg is censored.".into(),
            "The experiment ranks bot-versus-bot performance. It does not estimate human win probability, retention, or fun.".into(),
        ],
    };
    manifest.validate()?;
    Ok(PilotFixtureRuntime {
        definition,
        map,
        route,
        manifest,
    })
}

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
    // The zone file and the simulation rules decide what each persistent
    // pilot carries into its one life, which is now its hull's own profile.
    let economies = vec![ContentFingerprint {
        name: PILOT_ECONOMY.into(),
        digest: fingerprint(&[
            fixture.definition.raw.as_bytes(),
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

/// Open the measured life in the same order as a live room: deal the
/// selected kits, restart to refill their upgraded bars and ammunition, then
/// apply the seeded start pair and headings over the core's ordinary
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
    debug_assert!(warnings.is_empty(), "validated fixture tuning changed");
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

    // Nothing to dress. Each pilot flies the hull it was spawned in and the
    // hull deals its own profile, so what a leg measures is the two pilots.
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
            "the shipped fixture changed after the experiment was planned".into(),
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
    // contract for the shipped fixture. In particular, re-planning a
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
                    "the planned fixture has no start pair".into(),
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
        let mut tastes = HashSet::new();
        for pilot in &roster {
            let recorded = plan
                .fixture
                .pilot_kits
                .iter()
                .find(|kit| kit.pilot_id == pilot.id.0)
                .expect("pilot kit");
            assert_eq!(recorded.class, pilot.hull, "the hull it was written in");
            assert_eq!(
                recorded.kit,
                sim::World::baseline_profiles()[pilot.hull as usize].to_vec(),
                "and that hull's own profile"
            );
            tastes.insert(recorded.strategy.as_str());
        }
        assert!(tastes.len() > 1, "the fixture contains personal tastes");
    }

    #[test]
    fn a_pilot_leg_restarts_with_full_bars_on_its_seeded_starts() {
        let roster = pilots::roster();
        let fixture = load_pilot_fixture(&roster).expect("the live fixture");
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

    #[test]
    fn clock_only_team_match_never_stops_on_score() {
        assert!(match_reached_target([20, 0], 4, Some(5)));
        assert!(!match_reached_target([20, 0], 4, None));
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

    /// A row with a win-loss record and nothing else, for the interval tests.
    fn row_of(wins: u32, losses: u32) -> HullRow {
        HullRow {
            name: "test",
            class: 0,
            wins,
            losses,
            draws: 0,
            kills: 0,
            hits: 0,
            damage: 0,
            self_hits: 0,
            self_damage: 0,
            shots: [0; sim::TRIG_COUNT],
            vs: Vec::new(),
            mirror: 0.0,
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
            let b = hull_bout(
                [cipher, cipher],
                0.5,
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
                let b = hull_bout([c, c], 0.5, salt, None, &Arena::Built(sim::build_pit));
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
}

mod skill_tests {
    use super::*;

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
                        let (ka, kb) = duel(&bytes, &route, at, &mut null, &mid, &same, s, None);
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
                            let (ka, kb) = duel(&bytes, &route, at, &mut r, a, b, salt, None);
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
            let (a, b) = duel(&bytes, &route, at, &mut r, &weak, &strong, salt, None);
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

            {
                println!("\n=== {hull_name}: one knob at 0.30, the rest at 0.90 ===");
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

        {
            let mut gaps: Vec<f64> = Vec::new();
            for run in 0..RUNS {
                let mut r = rating::Rating::new();
                let mut salt = 3_000_000u32 + run * 100_000;
                for i in 0..roster.len() {
                    for j in (i + 1)..roster.len() {
                        for _ in 0..PER_PAIR {
                            duel(
                                &bytes, &route, at, &mut r, &roster[i], &roster[j], salt, None,
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
                "\n  gaps {:?}",
                gaps.iter().map(|g| g.round() as i64).collect::<Vec<_>>()
            );
            println!("  mean {mean:+.0}, spread {sd:.0}");
        }
    }
}

mod draws {

    use super::*;

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
            let (ka, kb) = duel(&bytes, &route, at, &mut r, &a, &b, salt, None);
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
        {
            // Indexed by salt % 4, which is what picks the start tile and the
            // facing between them.
            let mut won = [0u32; 4];
            let mut lost = [0u32; 4];
            let mut r = rating::Rating::new();
            for salt in 0..BOUTS {
                let (ka, kb) = duel(&bytes, &route, at, &mut r, &a, &b, salt, None);
                let s = (salt % 4) as usize;
                match ka.cmp(&kb) {
                    std::cmp::Ordering::Greater => won[s] += 1,
                    std::cmp::Ordering::Less => lost[s] += 1,
                    std::cmp::Ordering::Equal => {}
                }
            }
            println!("\n=== two pilots at 0.60, nothing between them ===");
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

    pub(super) fn the_kit_is_matched_and_real() {
        let (bytes, route, at) = real_map_fixture();
        let _ = route;
        let mut seen = std::collections::HashSet::new();
        for class in 0..sim::MAX_CLASSES as u8 {
            let mut world = sim::World::from_packed(0xd0e1, &bytes).expect("a map");
            world.cfg.spawn_radius = 0;
            let s = world.spawn(class, 0, at.0 .0, at.0 .1, 0) as u8;
            let sh = &world.state.ships[s as usize];
            let lvl: u32 = sh.level.iter().map(|l| *l as u32).sum();
            // Two bits a rung, six add-ons a trigger, which is the same
            // packing `sim_mod_get` reads.
            let mods: u32 = (0..sim::TRIG_COUNT)
                .flat_map(|t| (0..sim::MOD_COUNT).map(move |m| (t, m)))
                .map(|(t, m)| ((sh.mods[t] >> (m * 2)) & 3) as u32)
                .sum();
            let ch: u32 = sh.charge.iter().map(|c| *c as u32).sum();
            let spray = (sh.mods[sim::TRIG_GUN] & 7) as u32;
            println!(
                "  {:<9} gun+bomb {lvl}, {mods} add-ons, spray {spray}, {ch} charges",
                crate::pilots::CLASS_NAMES[class as usize]
            );
            assert!(
                world.eff_max_energy(s as usize) > 0,
                "every hull arrives with a bar"
            );
            seen.insert((lvl, mods, spray, ch, world.eff_max_energy(s as usize)));
        }
        assert!(
            seen.len() > 1,
            "a roster where every hull reads the same is a roster of one ship"
        );
    }
}
