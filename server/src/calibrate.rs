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

use crate::{ai, config, ingest_damage, nav, rating, sim};

/// A match ends at this many kills, or this many ticks if the two are too
/// evenly matched to settle it. 100 ticks is a second.
const KILL_TARGET: u16 = 5;
const MATCH_TICKS: u32 = 30_000; // five minutes of arena time

/// One match, fought to a result, with both pilots' credit going into `r`.
fn bout(r: &mut rating::Rating, a: &ai::RosterEntry, b: &ai::RosterEntry, salt: u32) {
    let mut world = sim::World::with_map(0xd0e1 ^ salt, sim::build_pit);
    // The pit is one room and a pilot can see across it, so nothing here ever
    // routes. Built anyway, because the brain takes one and a brain that took
    // an Option would grow a branch nobody exercises.
    let route = nav::Nav::build(&world.map);
    // No opening loadout, whatever the zone ships. This is a measurement of
    // the pilot, and thirty random greens at every spawn is not noise on that
    // measurement -- it erases it. Over a 48-round round-robin the skill
    // parameter moves kills 93 / 102 / 187 across the three bots with this at
    // zero, and 313 / 290 / 299 with it at thirty: a two-to-one gap becomes
    // flat, because everyone is firing multifire from the first second and
    // the fight is decided before flying it matters.
    //
    // Which is a fact about the zone rather than about the pilots, and this
    // harness already controls for the others -- one map, fixed spawns, sides
    // alternated, one seed. The ladder has to rank pilots, so it holds the
    // loadout still the same way it holds the hull still.
    world.cfg.spawn_prizes = 0;
    // And none on the floor either, for the same reason and by the same
    // argument. This was true by accident until greens learned to appear near a
    // pilot: they had been placed uniformly over a map 1024 tiles across, so a
    // forty-tile pit almost never saw one, and the ladder has been ranking
    // pilots in an empty room without ever saying so. Said now. With greens
    // reachable the pit turns into a scavenger hunt and matches end with nobody
    // having shot anybody, which is a fact about the prize economy rather than
    // about who can fly.
    world.cfg.prize_max = 0;
    // And the zone's spawn scatter, for a reason the other two did not have to
    // spell out. A radius drops a respawning ship on a random tile that far
    // from the map's centre, and Alpha's is 250 against a pit thirty-two tiles
    // wide: the first death throws both pilots out of the room and into the
    // empty field around it, where they spend the rest of the bout not finding
    // each other. It halved the kills in this tournament and I spent a while
    // blaming a refactor for it. Zero puts them back on the map's own starts.
    world.cfg.spawn_radius = 0;

    // Alternate which pilot starts on which side, so a positional advantage
    // in the pit cannot accumulate into a rating.
    let (first, second) = if salt % 2 == 0 { (a, b) } else { (b, a) };
    let s1 = world.spawn(first.class, 0, 505, 522, 0) as u8;
    let s2 = world.spawn(second.class, 1, 519, 502, 32768) as u8;

    let mut bot1 = ai::Bot::new(s1, first.skill);
    let mut bot2 = ai::Bot::new(s2, second.skill);
    bot1.reseed(salt.wrapping_mul(2246822519) ^ 0x1234);
    bot2.reseed(salt.wrapping_mul(3266489917) ^ 0x5678);

    let n1 = first.name.to_string();
    let n2 = second.name.to_string();
    let name_of = move |ship: u8| {
        if ship == s1 {
            n1.clone()
        } else {
            n2.clone()
        }
    };

    for _ in 0..MATCH_TICKS {
        let inputs = [
            sim::sim_input {
                ship: s1,
                buttons: bot1.think(
                    &ai::own(&world, s1),
                    &route,
                    bot1.looks_due().then(|| ai::scan(&world, s1)),
                ),
            },
            sim::sim_input {
                ship: s2,
                buttons: bot2.think(
                    &ai::own(&world, s2),
                    &route,
                    bot2.looks_due().then(|| ai::scan(&world, s2)),
                ),
            },
        ];
        world.step(&inputs);

        let tick = world.state.tick;
        for (victim, _killer, _paid) in ingest_damage(&world, r, &name_of) {
            r.death(tick, &name_of(victim));
        }

        let k1 = world.state.ships[s1 as usize].kills;
        let k2 = world.state.ships[s2 as usize].kills;
        if k1 >= KILL_TARGET || k2 >= KILL_TARGET {
            break;
        }
    }
}

/// Run a full round-robin `rounds` times and return the resulting ladder.
///
/// Calibration deliberately does not mark these pilots as bots. A bot's K is
/// small during live play so a human moves further than the bot that killed
/// them; here there are no humans, and a small K would take a very long time
/// to say anything. The ladder this produces is the prior their careers start
/// from, and live play refines it under the slow K.
pub fn run(rounds: u32, verbose: bool) -> rating::Rating {
    run_roster(&ai::roster(), rounds, verbose)
}

pub fn run_roster(roster: &[ai::RosterEntry], rounds: u32, verbose: bool) -> rating::Rating {
    let mut r = rating::Rating::new();
    r.set_anchor(ai::ANCHOR, ai::ANCHOR_RATING);

    let mut salt = 0u32;
    for round in 0..rounds {
        for i in 0..roster.len() {
            for j in (i + 1)..roster.len() {
                bout(&mut r, &roster[i], &roster[j], salt);
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
 * It is the same argument the spawn-prize zeroing makes higher up, read the
 * other way round. Thirty greens flatten a two-to-one skill gap, so somewhere
 * between nothing and thirty the kit stops being a garnish on flying and
 * becomes the whole result. This maps where.
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
        kit: &[(sim::prize_level(sim::TRIG_GUN), 1)],
    },
    Stage {
        name: "gun 2",
        kit: &[(sim::prize_level(sim::TRIG_GUN), 2)],
    },
    Stage {
        name: "bomb 1",
        kit: &[(sim::prize_level(sim::TRIG_BOMB), 1)],
    },
    Stage {
        name: "bomb 2",
        kit: &[(sim::prize_level(sim::TRIG_BOMB), 2)],
    },
    Stage {
        name: "stats",
        kit: &[
            (sim::prize_stat(0), TO_CEILING),
            (sim::prize_stat(1), TO_CEILING),
            (sim::prize_stat(2), TO_CEILING),
            (sim::prize_stat(3), TO_CEILING),
            (sim::prize_stat(4), TO_CEILING),
        ],
    },
    Stage {
        name: "multifire",
        kit: &[(sim::prize_mod(sim::TRIG_GUN, sim::MOD_MULTI), 1)],
    },
    Stage {
        name: "bouncing gun",
        kit: &[(sim::prize_mod(sim::TRIG_GUN, sim::MOD_BOUNCE), 1)],
    },
    Stage {
        name: "freezing gun",
        kit: &[(sim::prize_mod(sim::TRIG_GUN, sim::MOD_FREEZE), 1)],
    },
    Stage {
        name: "shrapnel",
        kit: &[(sim::prize_mod(sim::TRIG_BOMB, sim::MOD_SHRAPNEL), 1)],
    },
    Stage {
        name: "proximity",
        kit: &[(sim::prize_mod(sim::TRIG_BOMB, sim::MOD_PROX), 1)],
    },
    Stage {
        name: "shoving bomb",
        kit: &[(sim::prize_mod(sim::TRIG_BOMB, sim::MOD_PUSH), 1)],
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
    pub ticks: u32,
    /// Whether somebody reached the kill target. A pair that mostly times out
    /// is a pair whose numbers mean less than they look.
    pub decided: bool,
}

/// Put a kit on, and say how much of it went on.
///
/// Called at every spawn, not once. Death clears the tech tree and a bout runs
/// to five kills, so a kit granted at the start would measure one outfitted
/// life and four bare ones, plus whatever advantage the first blood bought.
fn wear(world: &mut sim::World, ship: usize, stage: &Stage) -> u32 {
    let mut worn = 0;
    for &(prize, n) in stage.kit {
        let want = if n == TO_CEILING {
            GRANT_LIMIT
        } else {
            n as u32
        };
        for _ in 0..want {
            if !world.grant(ship, prize) {
                break;
            }
            worn += 1;
        }
    }
    worn
}

/// Which trigger fired a given spec, for this hull.
///
/// A fire event names the spec that left the barrel rather than the trigger
/// that was pulled, and the report needs the trigger: "the shrapnel stage won
/// nothing" and "the shrapnel stage never threw a bomb" are different findings
/// that look identical from the win column.
fn spec_triggers(cfg: &sim::sim_settings, class: u8) -> std::collections::HashMap<u8, usize> {
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
    let mut world = sim::World::with_map(0x5ea1 ^ salt, sim::build_pit);
    let route = nav::Nav::build(&world.map);
    if let Some(c) = tuning {
        // The arena's own path, so a setting this harness reads is a setting a
        // room would read. It rebuilds the baseline first, which is why it
        // comes before the two lines below rather than after.
        crate::Room::apply_config(&mut world, c);
    }
    // The same two settings the ladder holds still, for the same reason: a
    // green landing mid-bout would be a kit this harness did not hand out.
    // Held even against a zone that asks for thirty, since the whole point is
    // that the kit is the only difference between the two pilots.
    world.cfg.spawn_prizes = 0;
    world.cfg.prize_max = 0;
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
        ticks += 1;

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
    let mut rows: Vec<StageRow> = STAGES
        .iter()
        .map(|s| StageRow {
            name: s.name,
            worn: 0,
            asked: s.asked(),
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
        .collect();

    let mut salt = 0u32;
    for i in 0..n {
        for j in i..n {
            let (mut wi, mut wj, mut drew) = (0u32, 0u32, 0u32);
            let mut stale = 0u32;
            for _ in 0..bouts {
                let b = stage_bout([&STAGES[i], &STAGES[j]], class, skill, salt, tuning);
                salt = salt.wrapping_add(1);

                // Worn is a property of the kit and the hull rather than of a
                // bout, so the last one to say it is as good as the first.
                rows[i].worn = b.sides[0].worn;
                rows[j].worn = b.sides[1].worn;

                for (k, side) in [(i, b.sides[0]), (j, b.sides[1])] {
                    rows[k].kills += side.kills;
                    rows[k].hits += side.hits;
                    rows[k].damage += side.damage;
                    rows[k].self_hits += side.self_hits;
                    rows[k].self_damage += side.self_damage;
                    rows[k].regrants += side.regrants;
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
            println!("{} done ({}/{})", STAGES[i].name, i + 1, n);
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
 * design. `sim_bounty` counts every green as one whatever it turned out to be,
 * including one that landed on a ceiling, so handing both sides the same number
 * of greens matches them exactly on the number a player actually sees over an
 * enemy's head. It does not match them on power: hulls have different pools and
 * different ceilings, so the same bounty buys a Cipher and an Anvil different
 * amounts of kit, and the gap widens as the count climbs.
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
    /// Greens offered, and how many of them moved a count. The first is what
    /// the two sides are matched on, since every green is one bounty; the
    /// second is what this hull got for it. Two hulls at the same bounty with
    /// different conversion is the mechanism behind most of this table.
    pub greens: u32,
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

/// Roll `greens` greens for one ship, and return how many of them moved a count.
///
/// The generator is the caller's so the same salt draws the same greens, and so
/// that handing out a loadout does not shift the bout's own stream.
///
/// Conversion is read off `earned` rather than off the delta the core returns.
/// That delta is +1 for everything except rust, so it answers "was this a
/// green" and never "did it land on anything" -- measuring with it reported
/// every hull converting all of sixty greens, which is what sent me looking.
/// `earned` is the counter the core moves in exactly the case wanted: a green
/// whose count was already at its ceiling banks a bounty there instead. Read
/// across the grants alone, with no ticks in between, it cannot pick up the
/// bounty that killing also earns.
fn green(world: &mut sim::World, ship: usize, greens: u32, rng: &mut u32) -> u32 {
    let before = world.state.ships[ship].earned;
    for _ in 0..greens {
        world.take_prize_from(ship, rng);
    }
    let wasted = world.state.ships[ship].earned.saturating_sub(before) as u32;
    greens.saturating_sub(wasted)
}

/// Two hulls, the same bounty each, one bout.
///
/// Returns the bout and how many greens each side was offered over it, which is
/// `greens` times the number of lives it had rather than a constant.
pub fn hull_bout(
    classes: [u8; 2],
    skill: f32,
    greens: u32,
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
    // The zone's own spawn kit would arrive on top of the one being measured,
    // and greens on the floor would let one side out-scavenge the other. Held
    // against the zone for the same reason the other two harnesses hold them.
    world.cfg.spawn_prizes = 0;
    world.cfg.prize_max = 0;
    // And the zone's spawn scatter, for a reason the other two did not have to
    // spell out. A radius drops a respawning ship on a random tile that far
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
    // a bout whose greens all rolled the same thing is not obvious from a
    // report that only prints totals.
    let mut prng = [
        (salt.wrapping_mul(2654435761) ^ 0x9E37_79B9) | 1,
        (salt.wrapping_mul(2246822519) ^ 0x85EB_CA6B) | 1,
    ];

    let mut out = [Side::default(); 2];
    let mut offered = [0u32; 2];
    for k in 0..2 {
        out[k].worn = green(&mut world, ships[k] as usize, greens, &mut prng[k]);
        offered[k] = greens;
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
        ticks += 1;

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
                out[k].regrants += green(&mut world, ships[k] as usize, greens, &mut prng[k]);
                offered[k] += greens;
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
    greens: u32,
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
            greens: 0,
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
                let (b, offered) = hull_bout([i as u8, j as u8], skill, greens, salt, tuning, map);
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
                rows[i].greens += offered[0];
                rows[j].greens += offered[1];

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
    greens: u32,
    bouts: u32,
    zone: &str,
    map: &str,
) -> serde_json::Value {
    let n = rows.len();
    println!(
        "\nhull tournament: {zone} tuning on the {map}, skill {skill:.2}, {greens} greens \
a life, {bouts} bouts a pair, {n} hulls"
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
            // What this hull turned its bounty into. Two hulls matched on
            // greens and split on this column are the same price and not the
            // same ship.
            100.0 * r.converted as f64 / r.greens.max(1) as f64,
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
        "greens_per_life": greens,
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
            "greens_offered": r.greens,
            "greens_converted": r.converted,
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
    pub mines: u32,
    pub engagement_distance: f64,
    pub engagement_samples: u64,
    pub planned_range: f64,
    pub planned_range_samples: u64,
    pub hits: u32,
    pub damage: u64,
    pub self_damage: u64,
    pub greens: u32,
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
    pub kills: u32,
    pub deaths: u32,
    pub shots: [u32; sim::TRIG_COUNT],
    pub mines: u32,
    pub engagement_distance: f64,
    pub engagement_samples: u64,
    pub planned_range: f64,
    pub planned_range_samples: u64,
    pub hits: u32,
    pub damage: u64,
    pub self_damage: u64,
    pub greens: u32,
    pub converted: u32,
}

/// One match: `lineup` seated in order, the first half on team 0.
///
/// Ends when a side reaches `KILL_TARGET` per player, so a four a side match
/// runs to twenty, or when the clock does. A match that ran out of clock is
/// still scored on kills, because a team ahead on the board when time expires
/// has out-fought the other one whether or not it finished the job.
fn team_world(salt: u32, tuning: Option<&config::ArenaConfig>, map: &Arena) -> Option<sim::World> {
    let mut world = map.build(salt)?;
    if let Some(c) = tuning {
        crate::Room::apply_config(&mut world, c);
    }
    world.cfg.spawn_prizes = 0;
    world.cfg.prize_max = 0;
    // Keep the zone's spawn scatter. This tournament uses the real map, so
    // placement is part of the team game it measures.
    Some(world)
}

pub fn team_match(
    lineup: &[u8],
    skill: f32,
    greens: u32,
    salt: u32,
    tuning: Option<&config::ArenaConfig>,
    map: &Arena,
) -> (Vec<Seat>, bool) {
    let per_side = lineup.len() / 2;
    let Some(mut world) = team_world(salt, tuning, map) else {
        return (Vec::new(), false);
    };
    let route = nav::Nav::build(&world.map);

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
                .wrapping_add(i as u32 * 2246822519)
                ^ 0x9E37_79B9)
                | 1,
        );
        seats.push(Seat {
            class: cls,
            team,
            ..Default::default()
        });
    }
    for i in 0..ships.len() {
        seats[i].converted += green(&mut world, ships[i] as usize, greens, &mut prng[i]);
        seats[i].greens += greens;
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
    let target = KILL_TARGET as u32 * per_side as u32;
    let mut decided = false;

    for _ in 0..MATCH_TICKS {
        // The look is decided before the think, because `think` takes the bot
        // mutably and `looks_due` reads it: asking inside the call borrows the
        // same bot twice.
        let mut inputs: Vec<sim::sim_input> = Vec::with_capacity(ships.len());
        for i in 0..ships.len() {
            let own = ai::own(&world, ships[i]);
            let look = bots[i].looks_due().then(|| ai::scan(&world, ships[i]));
            let buttons = bots[i].think(&own, &route, look);
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
                            if world.cfg.specs[e.b as usize].still != 0 {
                                seats[i].mines += 1;
                            } else if let Some(&t) = trig_of[i].get(&e.b) {
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
            if alive && !alive_was[i] {
                seats[i].converted += green(&mut world, ships[i] as usize, greens, &mut prng[i]);
                seats[i].greens += greens;
            }
            if !alive && alive_was[i] {
                seats[i].deaths += 1;
            }
            alive_was[i] = alive;
        }

        let mut side = [0u32; 2];
        for i in 0..ships.len() {
            side[seats[i].team as usize] += world.state.ships[ships[i] as usize].kills as u32;
        }
        if side[0] >= target || side[1] >= target {
            decided = true;
            break;
        }
    }

    for i in 0..ships.len() {
        seats[i].kills = world.state.ships[ships[i] as usize].kills as u32;
    }
    (seats, decided)
}

/// Fill both sides at random, `matches` times, and read each hull off its seats.
pub fn run_teams(
    per_side: usize,
    matches: u32,
    greens: u32,
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
            mines: 0,
            engagement_distance: 0.0,
            engagement_samples: 0,
            planned_range: 0.0,
            planned_range_samples: 0,
            hits: 0,
            damage: 0,
            self_damage: 0,
            greens: 0,
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
        let (seats, decided) = team_match(&lineup, skill, greens, m, tuning, map);
        if seats.is_empty() {
            continue;
        }
        if !decided {
            undecided += 1;
        }
        let mut side = [0u32; 2];
        for s in &seats {
            side[s.team as usize] += s.kills;
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
            r.mines += s.mines;
            r.engagement_distance += s.engagement_distance;
            r.engagement_samples += s.engagement_samples;
            r.planned_range += s.planned_range;
            r.planned_range_samples += s.planned_range_samples;
            r.greens += s.greens;
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
pub fn report_teams(
    rows: &[TeamRow],
    per_side: usize,
    skill: f32,
    greens: u32,
    matches: u32,
    zone: &str,
    map: &str,
    spawn_radius: u16,
) -> serde_json::Value {
    println!(
        "\nteam tournament: {per_side} a side, {zone} tuning on the {map}, skill \
{skill:.2}, {greens} greens a life, spawn radius {spawn_radius}, {matches} matches, \
lineups drawn at random"
    );
    println!(
        "\n{:<10} {:>7} {:>7} {:>7} {:>8} {:>8} {:>7} {:>8} {:>7} {:>7} {:>7} {:>7} {:>7}",
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
        "mine/s",
        "target",
        "actual"
    );
    for r in rows {
        let fired: u32 = r.shots.iter().sum();
        let s = r.seats.max(1) as f64;
        println!(
            "{:<10} {:>7.1} {:>7.1} {:>7} {:>8.2} {:>8.2} {:>7.2} {:>8.2} {:>7.1} {:>7.1} {:>7.2} {:>7.0} {:>7.0}",
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
            r.mines as f64 / s,
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
        "greens_per_life": greens, "spawn_radius": spawn_radius, "matches": matches,
        "hulls": rows.iter().map(|r| serde_json::json!({
            "name": r.name, "class": r.class, "seats": r.seats, "won": r.won,
            "drawn": r.drawn, "win_rate": r.win_rate(), "win_rate_margin": r.margin(),
            "kills": r.kills, "deaths": r.deaths,
            "gun_shots": r.shots[sim::TRIG_GUN], "bomb_shots": r.shots[sim::TRIG_BOMB],
            "mines": r.mines,
            "mean_planned_range": r.planned_range / r.planned_range_samples.max(1) as f64,
            "mean_engagement_distance": r.engagement_distance / r.engagement_samples.max(1) as f64,
            "hits": r.hits, "damage": r.damage, "self_damage": r.self_damage,
            "greens_offered": r.greens, "greens_converted": r.converted,
        })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Skill has to be worth something in the game it actually controls.
    ///
    /// This test passed for months on four rounds, where the whole roster
    /// lands inside a point of the anchor and the assertion is a coin flip:
    /// it read low 1201.1, mid 1197.8, high 1201.2, and `hi > lo` came down
    /// to a fraction the format string rounded away. Run it long enough for
    /// the ratings to settle and it says the opposite, on the code as it was
    /// and on the code as it is:
    ///
    /// ```text
    ///                       low(.15)  mid(.50)  high(.95)
    ///   60 rounds            1208.0    1189.5     1202.3
    /// ```
    ///
    /// The old implementation made strong pilots fire less and fight closer,
    /// which canceled their better reactions and aim. Range and fire reserve
    /// are now neutral, while reaction time, aim, awareness and loadout use
    /// carry the skill difference. This long sample keeps them honest.
    #[test]
    fn skill_decides_a_match_between_equal_hulls() {
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
        let r = run_roster(&roster, 60, false);
        let (lo, hi) = (r.rating_of("low"), r.rating_of("high"));
        assert!(hi > lo, "high {hi:.0} should outrank low {lo:.0}");
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
    /// Both pilots are handed `greens` at every spawn, so at any moment in the
    /// fight they have drawn the same number since they last died. Totals come
    /// apart, because the side that dies more respawns more and is handed the
    /// opening bounty again each time. That is the game's own arrangement and
    /// not an advantage: those extra greens are bought with deaths, and a hull
    /// that is dying is not winning.
    ///
    /// What this guards is the silent version of the failure. A green landing
    /// on a ceiling grants nothing, so a harness that counted grants rather
    /// than offers would hand the deeper tech tree more bounty for free and
    /// report the result as balance.
    #[test]
    fn bounty_is_matched_a_life_at_a_time() {
        // The knife against the fortress: the widest gap in tree shape the
        // roster has, so the widest gap between offered and converted.
        let cipher = ai::class_index("Cipher").unwrap() as u8;
        let anvil = ai::class_index("Anvil").unwrap() as u8;
        const GREENS: u32 = 8;
        for salt in 0..4 {
            let (_, offered) = hull_bout(
                [cipher, anvil],
                0.5,
                GREENS,
                salt,
                None,
                &Arena::Built(sim::build_pit),
            );
            for k in 0..2 {
                assert!(
                    offered[k] >= GREENS,
                    "salt {salt}: side {k} never got its opening"
                );
                assert_eq!(
                    offered[k] % GREENS,
                    0,
                    "salt {salt}: greens arrive a life at a time"
                );
            }
        }

        // Deliberately not cross-checked against the other side's kills. A
        // death is not always somebody's kill: a blast has no owner test, so a
        // pilot can end their own life with their own bomb, respawn, and be
        // refitted for a death that appears in nobody's column. Trying to
        // predict the refit count from kills is how that got found.

        // The claim underneath all of this, on its own: the same bounty buys
        // different hulls different amounts of ship. Handed enough greens to
        // saturate, a hull stops converting them, and every one of those still
        // counts a bounty.
        let mut world = sim::World::with_map(1, sim::build_pit);
        let mut short = 0;
        for &(class, name) in &[(cipher, "Cipher"), (anvil, "Anvil")] {
            let ship = world.spawn(class, 0, 505, 522, 0) as usize;
            let mut rng = 0x1234_5678u32;
            let offered = 60;
            let converted = green(&mut world, ship, offered, &mut rng);
            assert!(
                converted <= offered,
                "{name} converted more than it was handed"
            );
            if converted < offered {
                short += 1;
            }
        }
        assert!(
            short > 0,
            "sixty greens saturated nobody, so this harness is not reaching \
the ceilings the matched-bounty argument turns on"
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
            toml::from_str("spawn_radius = 60\nspawn_prizes = 30\nprize_max = 42\n")
                .expect("a zone with scattered, prized spawns");

        let world = team_world(0, Some(&scattered), &Arena::Built(sim::build_arena))
            .expect("a tournament world");

        assert_eq!(world.cfg.spawn_radius, 60);
        assert_eq!(world.cfg.spawn_prizes, 0);
        assert_eq!(world.cfg.prize_max, 0);
    }

    /// A hull opens the bout with the zone's numbers, not the baseline's.
    ///
    /// `sim_spawn` reads opening energy out of the class table, so seating a
    /// ship before the zone's settings are applied gives it the baseline's bar
    /// and then swaps the ceiling out from under it. It is invisible in every
    /// column the report prints and it corrupts exactly the measurement anybody
    /// would reach for this harness to make, which is what a per-hull change is
    /// worth. It happened: a refactor moved the seating inside the map builder,
    /// and the Cipher energy change came back moving hulls it cannot touch.
    #[test]
    fn a_zones_ship_settings_reach_the_opening_bar() {
        let cipher = ai::class_index("Cipher").unwrap() as u8;
        let thin: config::ArenaConfig =
            toml::from_str("[[ships]]\nname = \"Cipher\"\ninitial_energy = 250\nenergy = 400\n")
                .expect("a zone that thins one hull");

        let arena = Arena::Built(sim::build_pit);

        let mut plain = arena.build(0).expect("a room");
        let p = arena.seat(&mut plain, 0, [cipher, cipher]).expect("seats");
        let untuned = plain.state.ships[p[0] as usize].energy;

        let mut room = arena.build(0).expect("a room");
        crate::Room::apply_config(&mut room, &thin);
        let s = arena.seat(&mut room, 0, [cipher, cipher]).expect("seats");
        let opened = room.state.ships[s[0] as usize].energy;

        assert!(
            opened < untuned,
            "a Cipher opened on {opened} either way, so the zone's ship block \
never reached the spawn"
        );

        // Checked on the bar directly and not through a bout, because a bout
        // cannot see it. Seat a ship early and it opens on the baseline's
        // energy and then recharges toward the zone's ceiling within a few
        // seconds, so the fight converges and every column this harness prints
        // comes out the same. That is the whole reason it went unnoticed, and
        // it is why the ordering in `hull_bout` carries a comment rather than
        // a second assertion: nothing observable from outside that function
        // distinguishes the two orders.
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
        // The baseline hands out thirty greens at spawn, which would put rungs
        // and add-ons on this hull before the kit does and leave the test
        // measuring the roll it is supposed to be replacing.
        world.cfg.spawn_prizes = 0;
        let ship = world.spawn(0, 0, 505, 522, 0) as usize;

        const ONE: &[(u8, u8)] = &[(sim::prize_level(sim::TRIG_GUN), 1)];
        const NINE: &[(u8, u8)] = &[(sim::prize_level(sim::TRIG_GUN), 9)];

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

        // And a ceiling reached is not a bounty paid, which is the one way a
        // grant could quietly change what it is measuring: bounty is derived
        // from what you hold, so an `earned` bumped here would make the
        // outfitted side worth more to kill for no reason a player could see.
        assert_eq!(world.state.ships[ship].earned, 0);
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
        let mut c = config::ArenaConfig::default();
        // Two settings a zone plausibly moves, chosen because the baseline's
        // values are known here and neither is what this asks for.
        c.mod_spread = Some(5); // degrees, against the baseline's fifteen
        c.respawn_delay = Some(123);

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

        // And the harness still overrides the two it must, whatever the zone
        // asks for. A zone can hand out thirty spawn greens, which is exactly
        // the thing that would erase what is being measured.
        c.spawn_prizes = Some(30);
        c.prize_max = Some(42);
        let b = stage_bout([&STAGES[1], &STAGES[0]], 0, 0.5, 1, Some(&c));
        assert!(b.ticks > 0, "the bout ran");
        assert_eq!(
            b.sides[1].worn, 0,
            "the bare side stayed bare under a zone \
                                        that hands out thirty greens"
        );
    }

    /// The matrix has to agree with itself: if one stage took three of eight,
    /// the other took five, and a bout counted once on one side and not the
    /// other would show up here before it showed up as a balance conclusion.
    #[test]
    fn the_matrix_is_the_same_read_either_way() {
        let rows = run_stages(0, 0.5, 2, None, false);
        for (i, r) in rows.iter().enumerate() {
            for (j, cell) in r.vs.iter().enumerate() {
                match cell {
                    None => assert_eq!(i, j, "only the diagonal goes unplayed"),
                    Some(v) => {
                        let back = rows[j].vs[i].expect("played one way, not the other");
                        assert!(
                            (v + back - 1.0).abs() < 1e-9,
                            "{} vs {} reads {v:.3} and {back:.3}",
                            r.name,
                            rows[j].name
                        );
                    }
                }
            }
            assert_eq!(
                r.bouts(),
                (rows.len() as u32 - 1) * 2,
                "{} played the wrong number of bouts",
                r.name
            );
        }
    }
}

#[cfg(test)]
mod skill_tests {
    use super::*;

    /// Does the skill dial separate pilots at all?
    ///
    ///     cargo test --manifest-path server/Cargo.toml \
    ///       skill_alone_should_make_a_ladder -- --ignored --nocapture
    ///
    /// Ignored because it fights a few hundred five-kill matches and takes
    /// minutes, not because the answer does not matter. It matters a great
    /// deal: `docs/design/ai-players.md` promises "a single skill dial from 0
    /// to 1" driving reaction, aim, discipline, awareness, greed and map use,
    /// and the whole population director rests on a 0.35 pilot being an easier
    /// evening than a 0.85 one.
    ///
    /// The committed ladder cannot answer it, because all eight calibrated
    /// pilots fly different hulls, so `zone/ladder.json` measures hull and
    /// skill together and cannot say which moved. This holds the hull still
    /// and varies only the dial, which is the one arrangement that can.
    #[test]
    #[ignore]
    fn skill_alone_should_make_a_ladder() {
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
        // bomb, and in a pit with no greens the pilot forbidden to bomb keeps
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

#[cfg(test)]
mod real_map_tests {
    use super::*;

    /// A known asymmetry in this fixture, unexplained.
    ///
    /// Two identical pilots, nothing handicapped, sides alternating and now
    /// facings alternating too, and one of them still takes about 62% of the
    /// decided bouts. Which pilot draws which start, which team, which facing
    /// and which seat index all alternate on the salt, so the obvious causes
    /// are all accounted for and something else is doing it.
    ///
    /// It matters in a specific direction rather than generally, and the
    /// direction is worth knowing before reading any table here. The ablation
    /// prints a `none` row so every other row can be read as a distance from
    /// it. The ladder tournament has no such row, and there the favoured side
    /// is always `roster[i]`, which is the *weaker* pilot of the pair: so a
    /// gap it reports is a floor, and the dial separates pilots by more than
    /// the number printed, not less.
    const KNOWN_SIDE_BIAS: f64 = 0.62;

    /// Tiles between the two pilots at the start of a bout.
    ///
    /// Inside `ai::SIGHT`, which is sixty tiles, so they have each other from
    /// the first tick and the measurement is of fighting rather than of
    /// walking. A tournament where the pilots never meet measures the map.
    const APART: usize = 24;

    /// Somewhere two pilots can be put down with room to fly.
    ///
    /// Alpha is three per cent wall in clusters with long lanes between, so
    /// most of it is open and a pair like this is easy to find; it is still
    /// worth finding rather than assuming, because a hard-coded tile that
    /// lands inside a cluster spawns nobody and the bout reads as a draw.
    /// The map, its route and a place to put two pilots, built once.
    pub(super) fn real_map_fixture() -> (Vec<u8>, nav::Nav, ((i32, i32), (i32, i32))) {
        let bytes =
            std::fs::read("../catalog/zones/alpha/alpha.vwmap").expect("the alpha map ships here");
        let probe = sim::World::from_packed(0x5eed, &bytes).expect("a map");
        let at = open_pair(&probe.map);
        let route = nav::Nav::build(&probe.map);
        (bytes, route, at)
    }

    fn open_pair(map: &sim::sim_map) -> ((i32, i32), (i32, i32)) {
        let clear = |cx: usize, cy: usize| {
            (cy.saturating_sub(4)..=cy + 4).all(|y| {
                (cx.saturating_sub(4)..=cx + 4).all(|x| {
                    x < sim::MAP_TILES
                        && y < sim::MAP_TILES
                        && map.tile[y * sim::MAP_TILES + x] & 0x0f == 0
                })
            })
        };
        // Outward from the middle, so the pair sits in the part of the map a
        // room actually uses rather than against the boundary.
        for r in 0..400usize {
            for (dx, dy) in [(1i32, 0i32), (0, 1), (-1, 0), (0, -1)] {
                let cx = (512 + dx * r as i32) as usize;
                let cy = (512 + dy * r as i32) as usize;
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
    pub(super) fn duel(
        bytes: &[u8],
        route: &nav::Nav,
        at: ((i32, i32), (i32, i32)),
        r: &mut rating::Rating,
        a: &ai::RosterEntry,
        b: &ai::RosterEntry,
        salt: u32,
        greens: bool,
        handicap: Option<(ai::Knob, f32)>,
    ) -> (u16, u16) {
        let mut world = sim::World::from_packed(0xd0e1 ^ salt, bytes).expect("a map");
        if !greens {
            // The same three the pit tournament holds still, for the same
            // reason: this ranks pilots, so the loadout is held the way the
            // hull is held.
            world.cfg.spawn_prizes = 0;
            world.cfg.prize_max = 0;
        }
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
        let flip = salt % 2 == 0;
        let (first, second) = if flip { (a, b) } else { (b, a) };
        let (h1, h2) = if salt % 4 < 2 { (0, 32768) } else { (32768, 0) };
        let s1 = world.spawn(first.class, 0, at.0 .0, at.0 .1, h1) as u8;
        let s2 = world.spawn(second.class, 1, at.1 .0, at.1 .1, h2) as u8;

        let mut bot1 = ai::Bot::new(s1, first.skill);
        let mut bot2 = ai::Bot::new(s2, second.skill);
        // The ablation's handicap always rides on `a`, whichever side it drew.
        if let Some((knob, as_if)) = handicap {
            if salt % 2 == 0 {
                bot1.tune(knob, as_if);
            } else {
                bot2.tune(knob, as_if);
            }
        }
        bot1.reseed(salt.wrapping_mul(2246822519) ^ 0x1234);
        bot2.reseed(salt.wrapping_mul(3266489917) ^ 0x5678);

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
            let k1 = world.state.ships[s1 as usize].kills;
            let k2 = world.state.ships[s2 as usize].kills;
            if k1 >= KILL_TARGET || k2 >= KILL_TARGET {
                break;
            }
        }
        let k1 = world.state.ships[s1 as usize].kills;
        let k2 = world.state.ships[s2 as usize].kills;
        // Back into the caller's order, whichever side each started on.
        if salt % 2 == 0 {
            (k1, k2)
        } else {
            (k2, k1)
        }
    }

    /// The same question the pit asks, asked on the map people play.
    ///
    ///     cargo test --release --manifest-path server/Cargo.toml \\
    ///       skill_on_a_real_map -- --ignored --nocapture
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
    /// Run twice over, without the prize economy and with it. The first is
    /// the pit's own control, holding the loadout still the way the hull is
    /// held. The second is the game as it ships, because greed and build
    /// planning are two of the six traits the dial is supposed to drive and
    /// a field with no greens on it cannot show either.
    #[test]
    #[ignore]
    fn skill_on_a_real_map() {
        // Two hulls, because every number this printed before came from one.
        //
        // Class 1 is the Wedge, whose doctrine is Bombardier, and it is the
        // hull this was measured on all night: the bomb specialist, judged on
        // a fix to bomb judgement, in a built field where bombs and shrapnel
        // together are the most stochastic thing this game does. Class 0 is
        // the Apex, a Duelist, which fights with its gun and where the aim
        // error should carry. If the built economy separates on one and not
        // the other, that is a fact about a ship rather than about the dial.
        const HULLS: [(u8, &str); 2] = [(1, "Wedge, Bombardier"), (0, "Apex, Duelist")];
        const PER_PAIR: u32 = 200;
        let bytes =
            std::fs::read("../catalog/zones/alpha/alpha.vwmap").expect("the alpha map ships here");
        let probe = sim::World::from_packed(0x5eed, &bytes).expect("a map");
        let at = open_pair(&probe.map);
        let route = nav::Nav::build(&probe.map);
        let mut gaps: Vec<(bool, f64, usize, usize)> = Vec::new();
        for (hull, hull_name) in HULLS {
            let roster: Vec<ai::RosterEntry> = [0.30f32, 0.45, 0.60, 0.75, 0.90]
                .iter()
                .map(|s| ai::RosterEntry {
                    name: format!("{hull}skill{:02}", (s * 100.0) as u32),
                    class: hull,
                    skill: *s,
                })
                .collect();

            for greens in [false, true] {
                println!("\n### {hull_name} ###");
                let mut rates: Vec<f64> = Vec::new();
                println!(
                "\n=== alpha, spawns {APART} tiles apart, {PER_PAIR} bouts a pair, greens {} ===",
                if greens { "on" } else { "off" }
            );
                let mut r = rating::Rating::new();
                let mut salt = if greens { 500_000u32 } else { 0 };
                println!("   pair            won   lost   drew    rate      95% ci");
                for i in 0..roster.len() {
                    for j in (i + 1)..roster.len() {
                        let (a, b) = (&roster[i], &roster[j]);
                        let (mut wa, mut wb, mut drew) = (0u32, 0u32, 0u32);
                        for _ in 0..PER_PAIR {
                            let (ka, kb) =
                                duel(&bytes, &route, at, &mut r, a, b, salt, greens, None);
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
                        let ci = 1.96 * (rate * (1.0 - rate) / decided).sqrt();
                        let _ = KNOWN_SIDE_BIAS;
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
                let leaning = rates.iter().filter(|r| **r < 0.5).count();
                println!(
                    "   {leaning} of {} pairs favour the stronger pilot",
                    rates.len()
                );
                gaps.push((greens, gap, leaning, rates.len()));
            }
        }

        // Every pair leaning the right way, which is the property that
        // survives a small effect: ten independent pairs on one side of a coin
        // is a thousand to one, so it sees a real but weak dial where no single
        // pair's interval could. And a hundred points of ladder, which is a
        // 64% result and the least this can mean and still mean something.
        for (greens, gap, leaning, pairs) in gaps {
            let economy = if greens { "on" } else { "off" };
            assert_eq!(
                leaning, pairs,
                "with greens {economy}, {leaning} of {pairs} pairs favour the stronger pilot"
            );
            assert!(
                gap >= 100.0,
                "with greens {economy}, the dial makes {gap:+.0} points of ladder"
            );
        }
    }

    /// What one bout costs on the real map, so a run can be sized.
    #[test]
    #[ignore]
    fn time_one_real_map_bout() {
        let bytes =
            std::fs::read("../catalog/zones/alpha/alpha.vwmap").expect("the alpha map ships here");
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
            let (a, b) = duel(
                &bytes, &route, at, &mut r, &weak, &strong, salt, false, None,
            );
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

#[cfg(test)]
mod ablation {
    use super::real_map_tests::*;
    use super::*;

    /// Which of the dial's six parameters is doing the work?
    ///
    ///     cargo test --release --manifest-path server/Cargo.toml \
    ///       which_knob_carries_the_dial -- --ignored --nocapture
    ///
    /// Two pilots at 0.90 in every respect but one, where one of them is held
    /// at 0.30. A knob that matters shows up as a win rate away from half; a
    /// knob that does nothing shows up as a coin. The tournament could not ask
    /// this, because moving the dial moves all six at once.
    #[test]
    #[ignore]
    fn which_knob_carries_the_dial() {
        const PER_KNOB: u32 = 200;
        let (bytes, route, at) = real_map_fixture();
        let strong = ai::RosterEntry {
            name: "strong".into(),
            class: 1,
            skill: 0.90,
        };
        let same = ai::RosterEntry {
            name: "same".into(),
            class: 1,
            skill: 0.90,
        };

        for greens in [false, true] {
            println!(
                "\n=== one knob at 0.30, the rest at 0.90, greens {} ===",
                if greens { "on" } else { "off" }
            );
            println!("  knob          handicapped wins   rate      95% ci");
            for knob in [
                // Nothing handicapped at all, which this had no business
                // running without: every other row is read against a coin,
                // and whether this harness deals one is a question rather
                // than an assumption. Two identical pilots, alternating
                // sides. Anything far from half here is the fixture talking.
                None,
                Some(ai::Knob::React),
                Some(ai::Knob::Look),
                Some(ai::Knob::AimErr),
                Some(ai::Knob::Permission),
                Some(ai::Knob::Tolerance),
                Some(ai::Knob::Range),
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
                        greens,
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

#[cfg(test)]
mod stability {
    use super::real_map_tests::*;
    use super::*;

    /// Is the built field's ladder a small effect, or an unsteady number?
    ///
    ///     cargo test --release --manifest-path server/Cargo.toml \
    ///       is_the_built_ladder_a_measurement -- --ignored --nocapture
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
    #[test]
    #[ignore]
    fn is_the_built_ladder_a_measurement() {
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

        for greens in [false, true] {
            let mut gaps: Vec<f64> = Vec::new();
            for run in 0..RUNS {
                let mut r = rating::Rating::new();
                let mut salt = 3_000_000u32 + run * 100_000;
                for i in 0..roster.len() {
                    for j in (i + 1)..roster.len() {
                        for _ in 0..PER_PAIR {
                            duel(
                                &bytes, &route, at, &mut r, &roster[i], &roster[j], salt, greens,
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
                "\n  greens {}: gaps {:?}",
                if greens { "on " } else { "off" },
                gaps.iter().map(|g| g.round() as i64).collect::<Vec<_>>()
            );
            println!("  mean {mean:+.0}, spread {sd:.0}");
        }
    }
}

#[cfg(test)]
mod draws {
    use super::real_map_tests::*;
    use super::*;

    /// What a drawn bout in a built field actually looks like.
    ///
    ///     cargo test --release --manifest-path server/Cargo.toml \
    ///       what_a_draw_is_made_of -- --ignored --nocapture
    ///
    /// Half the bouts with greens on end level, and a level bout carries no
    /// information, so the built economy is measured on half the sample the
    /// bare one gets. Whether that is worth fixing depends entirely on what
    /// the draws are: nought-all means two pilots that never found each other,
    /// which is the fixture's problem, and three-all means they found each
    /// other and ran out of clock, which is the match length's.
    #[test]
    #[ignore]
    fn what_a_draw_is_made_of() {
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
        let mut tally: std::collections::BTreeMap<u16, u32> = Default::default();
        let mut decided = 0u32;
        for salt in 0..60u32 {
            let (ka, kb) = duel(&bytes, &route, at, &mut r, &a, &b, salt, true, None);
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
