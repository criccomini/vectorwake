//! Are the seven bodies even, now that none of them owns a weapon?
//!
//! Decision 121 took the loadout off the hull, so what separates two ships is
//! a flight row and a footprint and nothing else. That makes the balance
//! question answerable in a way it was not before: hold the build distribution
//! fixed, vary the body, and anything left is the body.
//!
//! The shape is one match: seats drawn at random from the roster, a build
//! drawn at random for each, and the whole thing played twice with the sides
//! swapped so map and spawn asymmetry cancels inside the pair. A pair is the
//! unit of evidence, which is what the bootstrap resamples.
//!
//! Three things this deliberately does not randomize. Skill is a stratum
//! rather than a draw, because the dial is a 5x spread on k/d and body balance
//! genuinely differs along it: a deep slow hull is usually low-skill strong,
//! and averaging over skill would hide exactly the case that matters to a new
//! player. Personality is left out for the same reason in reverse: it is noise
//! against this question. And the stat slots are excluded from the build
//! sampler, since their step is zero in this roster, so a credit spent there
//! buys nothing and a sampler that offered them would fly partly bare ships.

use crate::{ai, calibrate, config, experiment, sim};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Skill strata. All eight seats fly at one of these, never a mixture: a
/// match with a spread inside it measures matchmaking rather than bodies.
pub const STRATA: [(&str, f32); 3] = [("low", 0.15), ("mid", 0.50), ("high", 0.90)];

/// How wide a band around even still counts as balanced, in win-rate points.
///
/// The margin is the whole of what "balanced" means here, and it has to be
/// declared before the run rather than read off it. Five points is a roster
/// nobody could feel; three is the long-run target and costs about four times
/// the bouts.
pub const MARGIN: f64 = 0.05;

/// Family-wise alpha for the equivalence family.
pub const ALPHA: f64 = 0.05;

/// One seat, in one match, as the log records it.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SeatLine {
    /// The pair this seat belongs to. Both arms of a swap share it, and it is
    /// what the bootstrap resamples.
    pub pair: u32,
    /// 0 as drawn, 1 with the sides swapped.
    pub arm: u8,
    pub stratum: &'static str,
    pub map: String,
    pub body: &'static str,
    pub class: u8,
    /// Index into the enumerated build set, so a line is replayable.
    pub build: u32,
    pub team: u8,
    /// 1.0 win, 0.5 draw, 0.0 loss.
    pub outcome: f64,
    pub decided: bool,
    pub kills: u32,
    pub deaths: u32,
    pub damage: u64,
    pub self_damage: u64,
    pub shots: u32,
    pub hits: u32,
    pub engagement_distance: f64,
}

/// Every legal build of exactly `KIT_CREDITS`, excluding the stat slots.
///
/// Enumerated rather than sampled greedily, so the draw is uniform over the
/// space a pilot can actually reach and a build is one integer in the log.
/// Every vector is run back through the core's own `sim_kit_fit`, which must
/// change nothing: a build this returns that the arena would cut is a sampler
/// disagreeing with the game.
pub fn builds(world: &sim::World) -> Vec<[u8; sim::SLOT_COUNT]> {
    // The spendable slots and their ceilings, off the core rather than a copy
    // of it. Bodies are identical here since decision 121, and the assert
    // below is what keeps this honest if a zone ever changes that.
    let mut spend: Vec<(u8, u8)> = Vec::new();
    for slot in sim::UP_COUNT..sim::SLOT_COUNT {
        let cap = world.slot_cap(0, slot as u8);
        for cls in 1..sim::MAX_CLASSES as u8 {
            assert_eq!(
                world.slot_cap(cls, slot as u8),
                cap,
                "slot {slot} has a different ceiling on hull {cls}, so a build \
                 is not the same offer in every body"
            );
        }
        if cap > 0 {
            spend.push((slot as u8, cap));
        }
    }

    let mut out = Vec::new();
    let mut kit = [0u8; sim::SLOT_COUNT];
    walk(world, &spend, 0, sim::KIT_CREDITS, &mut kit, &mut out);
    out
}

fn walk(
    world: &sim::World,
    spend: &[(u8, u8)],
    at: usize,
    left: u8,
    kit: &mut [u8; sim::SLOT_COUNT],
    out: &mut Vec<[u8; sim::SLOT_COUNT]>,
) {
    if left == 0 {
        assert_eq!(
            world.fit_kit(0, kit),
            *kit,
            "the core would cut a build this sampler calls legal"
        );
        out.push(*kit);
        return;
    }
    if at >= spend.len() {
        return;
    }
    let (slot, cap) = spend[at];
    // The tail cannot make up more than its own ceilings, so prune.
    let reach: u32 = spend[at..].iter().map(|&(_, c)| c as u32).sum();
    if reach < left as u32 {
        return;
    }
    for n in 0..=cap.min(left) {
        kit[slot as usize] = n;
        walk(world, spend, at + 1, left - n, kit, out);
    }
    kit[slot as usize] = 0;
}

/// A room, and what to call it in the log.
pub struct Room {
    pub name: String,
    pub arena: calibrate::Arena,
}

/// The rooms a format is measured in.
///
/// A 1v1 on a melee map is two ships in twenty-four thousand open tiles, which
/// decides nothing and reports it as a draw, so the duel arm runs in the pit:
/// one box both pilots can see across. That flatters everything wanting to be
/// close and charges nothing for being slow, and it is the honest limit on
/// what the duel numbers below can say. The team arm runs the zone's own
/// rotation, which is the game people actually play.
pub fn rooms(per_side: usize, zone_dir: &str) -> Vec<Room> {
    if per_side == 1 {
        return vec![Room {
            name: "pit".into(),
            arena: calibrate::Arena::Built(sim::build_pit),
        }];
    }
    ["maelstrom", "gantry", "warren", "redoubt", "ringworks"]
        .iter()
        .filter_map(|name| {
            let path = format!("{zone_dir}/{name}.vwmap");
            std::fs::read(&path).ok().map(|bytes| Room {
                name: (*name).into(),
                arena: calibrate::Arena::Packed(std::sync::Arc::new(bytes)),
            })
        })
        .collect()
}

/// Play one stratum of one format, `pairs` swapped pairs of it.
pub fn run(
    per_side: usize,
    pairs: u32,
    stratum: (&'static str, f32),
    rooms: &[Room],
    tuning: Option<&config::ArenaConfig>,
    builds: &[[u8; sim::SLOT_COUNT]],
    verbose: bool,
) -> Vec<SeatLine> {
    let seats = per_side * 2;
    let bodies = ai::CLASS_NAMES.len();
    let mut out = Vec::with_capacity(pairs as usize * seats * 2);
    // The state's own generator, so a run repeats from its seed alone.
    let mut rng = 0x0d1e_5eedu32 ^ (stratum.1.to_bits() ^ per_side as u32);
    let draw = |rng: &mut u32, n: u32| -> u32 {
        *rng ^= *rng << 13;
        *rng ^= *rng >> 17;
        *rng ^= *rng << 5;
        *rng % n
    };

    for pair in 0..pairs {
        let room = &rooms[(pair as usize) % rooms.len()];
        let mut lineup: Vec<u8> = Vec::with_capacity(seats);
        let mut picks: Vec<u32> = Vec::with_capacity(seats);
        for _ in 0..seats {
            lineup.push(draw(&mut rng, bodies as u32) as u8);
            picks.push(draw(&mut rng, builds.len() as u32));
        }
        // The salt is the pair's, so both arms open on the same map draw and
        // the swap is the only difference between them.
        let salt = pair.wrapping_mul(2_654_435_761).wrapping_add(1);

        for arm in 0..2u8 {
            // Swapping is a rotation of the seating, so every body keeps its
            // build and changes which side it fights for.
            let (line, pick): (Vec<u8>, Vec<u32>) = if arm == 0 {
                (lineup.clone(), picks.clone())
            } else {
                (
                    lineup[per_side..]
                        .iter()
                        .chain(&lineup[..per_side])
                        .copied()
                        .collect(),
                    picks[per_side..]
                        .iter()
                        .chain(&picks[..per_side])
                        .copied()
                        .collect(),
                )
            };
            let kits: Vec<[u8; sim::SLOT_COUNT]> =
                pick.iter().map(|&b| builds[b as usize]).collect();
            let (result, decided) = calibrate::team_match_with_kits(
                &line,
                stratum.1,
                salt,
                tuning,
                &room.arena,
                Some(&kits),
            );
            if result.is_empty() {
                continue;
            }
            let mut side = [0i32; 2];
            for s in &result {
                side[s.team as usize] += s.score;
            }
            let winner = match side[0].cmp(&side[1]) {
                std::cmp::Ordering::Greater => Some(0u8),
                std::cmp::Ordering::Less => Some(1u8),
                std::cmp::Ordering::Equal => None,
            };
            for (i, s) in result.iter().enumerate() {
                out.push(SeatLine {
                    pair,
                    arm,
                    stratum: stratum.0,
                    map: room.name.clone(),
                    body: ai::CLASS_NAMES[s.class as usize],
                    class: s.class,
                    build: pick[i],
                    team: s.team,
                    outcome: match winner {
                        Some(w) if w == s.team => 1.0,
                        Some(_) => 0.0,
                        None => 0.5,
                    },
                    decided,
                    kills: s.kills,
                    deaths: s.deaths,
                    damage: s.damage,
                    self_damage: s.self_damage,
                    shots: s.shots.iter().sum(),
                    hits: s.hits,
                    engagement_distance: if s.engagement_samples > 0 {
                        s.engagement_distance / s.engagement_samples as f64
                    } else {
                        0.0
                    },
                });
            }
        }
        if verbose && pair % 50 == 49 {
            eprintln!(
                "  {} {}v{}: {} pairs",
                stratum.0,
                per_side,
                per_side,
                pair + 1
            );
        }
    }
    out
}

/// One body's line in the report.
#[derive(Clone, Debug, Serialize)]
pub struct BodyRow {
    pub body: &'static str,
    pub seats: usize,
    pub win_rate: f64,
    /// Bootstrap standard error over whole pairs.
    pub standard_error: f64,
    /// Family-wise interval, from the bootstrap's own max statistic.
    pub low: f64,
    pub high: f64,
    pub draws: f64,
    pub kd: f64,
    pub damage_per_seat: f64,
    pub engagement_distance: f64,
    /// TOST against `MARGIN`, Holm-adjusted across the roster.
    pub equivalence_p: f64,
    pub equivalent: bool,
}

/// Mean outcome per body over a set of pairs, and the pair index it came from.
fn per_pair(lines: &[SeatLine]) -> BTreeMap<u32, [(f64, u32); sim::MAX_CLASSES]> {
    let mut out: BTreeMap<u32, [(f64, u32); sim::MAX_CLASSES]> = BTreeMap::new();
    for line in lines {
        let slot = out.entry(line.pair).or_insert([(0.0, 0); sim::MAX_CLASSES]);
        slot[line.class as usize].0 += line.outcome;
        slot[line.class as usize].1 += 1;
    }
    out
}

/// Cluster bootstrap over pairs, with the family-wise critical value taken
/// from the max statistic across the roster.
///
/// Written here rather than through `experiment::bootstrap_simultaneous_means`
/// because that one wants every label present in every cluster, and a duel
/// pair holds two bodies out of seven. Resampling whole pairs is the same
/// idea against the shape this data actually has: the two arms of a swap are
/// strongly dependent by construction, so neither is evidence on its own.
fn bootstrap(
    lines: &[SeatLine],
    replicates: usize,
    seed: u64,
) -> ([f64; sim::MAX_CLASSES], [f64; sim::MAX_CLASSES], f64) {
    let clusters: Vec<[(f64, u32); sim::MAX_CLASSES]> = per_pair(lines).into_values().collect();
    let mean_of = |set: &[usize], clusters: &[[(f64, u32); sim::MAX_CLASSES]]| {
        let mut sums = [(0.0f64, 0u32); sim::MAX_CLASSES];
        for &i in set {
            for c in 0..sim::MAX_CLASSES {
                sums[c].0 += clusters[i][c].0;
                sums[c].1 += clusters[i][c].1;
            }
        }
        let mut out = [f64::NAN; sim::MAX_CLASSES];
        for c in 0..sim::MAX_CLASSES {
            if sums[c].1 > 0 {
                out[c] = sums[c].0 / sums[c].1 as f64;
            }
        }
        out
    };
    let all: Vec<usize> = (0..clusters.len()).collect();
    let point = mean_of(&all, &clusters);

    let mut state = seed | 1;
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    let mut draws: Vec<[f64; sim::MAX_CLASSES]> = Vec::with_capacity(replicates);
    for _ in 0..replicates {
        let set: Vec<usize> = (0..clusters.len())
            .map(|_| (next() % clusters.len() as u64) as usize)
            .collect();
        draws.push(mean_of(&set, &clusters));
    }

    let mut se = [0.0f64; sim::MAX_CLASSES];
    for c in 0..sim::MAX_CLASSES {
        let values: Vec<f64> = draws
            .iter()
            .filter(|d| d[c].is_finite())
            .map(|d| d[c])
            .collect();
        if values.len() < 2 {
            continue;
        }
        let mean = values.iter().sum::<f64>() / values.len() as f64;
        let var =
            values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (values.len() - 1) as f64;
        se[c] = var.sqrt();
    }

    // The simultaneous critical value: the 95th percentile of the largest
    // standardized deviation any body shows in a replicate. Using it for
    // every interval is what makes the seven of them hold at once.
    let mut maxima: Vec<f64> = draws
        .iter()
        .map(|d| {
            (0..sim::MAX_CLASSES)
                .filter(|&c| d[c].is_finite() && se[c] > 0.0)
                .map(|c| ((d[c] - point[c]) / se[c]).abs())
                .fold(0.0f64, f64::max)
        })
        .collect();
    maxima.sort_by(f64::total_cmp);
    let critical = maxima
        .get(((maxima.len() as f64 * 0.95) as usize).min(maxima.len().saturating_sub(1)))
        .copied()
        .unwrap_or(1.96);
    (point, se, critical)
}

/// Turn a run's log into the roster's report.
pub fn analyze(lines: &[SeatLine]) -> Vec<BodyRow> {
    let (point, se, critical) = bootstrap(lines, 4000, 0x00b0_d1e5);
    let mut rows = Vec::new();
    let mut tost = Vec::new();
    for c in 0..sim::MAX_CLASSES {
        let mine: Vec<&SeatLine> = lines.iter().filter(|l| l.class as usize == c).collect();
        if mine.is_empty() {
            continue;
        }
        let n = mine.len() as f64;
        let kills: u32 = mine.iter().map(|l| l.kills).sum();
        let deaths: u32 = mine.iter().map(|l| l.deaths).sum();
        let result = experiment::tost_equivalence(point[c] - 0.5, se[c], -MARGIN, MARGIN, ALPHA)
            .expect("a finite estimate and a positive band");
        // Equivalence is the harder of the two one-sided tests, so the pair
        // reduces to its maximum before the family correction sees it.
        let raw_p = result.lower_test_p.max(result.upper_test_p);
        tost.push(experiment::ContrastPValue {
            hypothesis: ai::CLASS_NAMES[c].to_string(),
            raw_p,
        });
        rows.push(BodyRow {
            body: ai::CLASS_NAMES[c],
            seats: mine.len(),
            win_rate: point[c],
            standard_error: se[c],
            low: point[c] - critical * se[c],
            high: point[c] + critical * se[c],
            draws: mine.iter().filter(|l| l.outcome == 0.5).count() as f64 / n,
            kd: if deaths > 0 {
                kills as f64 / deaths as f64
            } else {
                f64::INFINITY
            },
            damage_per_seat: mine.iter().map(|l| l.damage).sum::<u64>() as f64 / n,
            engagement_distance: mine.iter().map(|l| l.engagement_distance).sum::<f64>() / n,
            equivalence_p: raw_p,
            equivalent: false,
        });
    }
    // Holm across the roster, so "every body is even" is one claim rather
    // than seven separate ones that happen to agree.
    if let Ok(adjusted) = experiment::holm_adjust(&tost, ALPHA) {
        for (row, holm) in rows.iter_mut().zip(adjusted) {
            row.equivalence_p = holm.adjusted_p;
            row.equivalent = holm.adjusted_p <= ALPHA;
        }
    }
    rows
}

/// What the pilot stage is for: the pair-level variance the sample size is
/// planned from, and how many pairs the declared margin actually needs.
pub fn plan(lines: &[SeatLine]) -> (f64, usize) {
    let clusters = per_pair(lines);
    let mut values: Vec<f64> = Vec::new();
    for bodies in clusters.into_values() {
        for seen in bodies {
            if seen.1 > 0 {
                values.push(seen.0 / seen.1 as f64 - 0.5);
            }
        }
    }
    let n = values.len() as f64;
    let mean = values.iter().sum::<f64>() / n;
    let variance = values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0);
    let plan = experiment::plan_paired_mean(experiment::PowerPlanRequest {
        alpha: ALPHA,
        power: 0.90,
        minimum_detectable_effect: MARGIN,
        observed_paired_variance: variance,
        sidedness: experiment::Sidedness::TwoSided,
        family_hypotheses: sim::MAX_CLASSES,
    })
    .expect("a positive margin and a finite variance");
    (variance, plan.required_pairs)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The sampler offers exactly the builds the arena would accept, spends
    /// the whole purse every time, and never names a stat slot.
    #[test]
    fn every_sampled_build_is_one_a_pilot_could_fly() {
        let world = sim::World::new(1);
        let set = builds(&world);
        assert!(set.len() > 100, "only {} builds", set.len());
        for kit in &set {
            assert_eq!(
                kit.iter().map(|&n| n as u32).sum::<u32>(),
                sim::KIT_CREDITS as u32,
                "a build that does not spend the purse"
            );
            for step in &kit[..sim::UP_COUNT] {
                assert_eq!(*step, 0, "a credit on a stat step worth nothing");
            }
            for cls in 0..sim::MAX_CLASSES as u8 {
                assert_eq!(&world.fit_kit(cls, kit), kit, "hull {cls} would cut it");
            }
        }
        let mut sorted = set.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), set.len(), "the same build twice");
    }

    /// A swap is the same eight ships on the other side, so the two arms of a
    /// pair name the same bodies and the same builds.
    #[test]
    fn a_swapped_arm_is_the_same_ships_on_the_other_side() {
        let world = sim::World::new(1);
        let set = builds(&world);
        let rooms = vec![Room {
            name: "pit".into(),
            arena: calibrate::Arena::Built(sim::build_pit),
        }];
        let lines = run(1, 2, ("mid", 0.5), &rooms, None, &set, false);
        for pair in 0..2u32 {
            let mut arms: Vec<Vec<(u8, u32)>> = (0..2)
                .map(|arm| {
                    let mut seen: Vec<(u8, u32)> = lines
                        .iter()
                        .filter(|l| l.pair == pair && l.arm == arm)
                        .map(|l| (l.class, l.build))
                        .collect();
                    seen.sort();
                    seen
                })
                .collect();
            assert_eq!(arms.remove(0), arms.remove(0), "pair {pair} is not a swap");
        }
    }
}
