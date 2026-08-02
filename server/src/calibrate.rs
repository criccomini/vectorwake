//! Offline bot ladder calibration.
//!
//! Bot personalities play each other before they ever meet a human, which is
//! what lets the first player to join an empty zone be placed against a ladder
//! that already means something. Implements the "initial calibration is
//! offline" paragraph of docs/design/rating.md.
//!
//! Every match is a real duel: the real simulation, the real bots, the real
//! rating math. Nothing here models an outcome, because a model of a fight is
//! exactly the thing that would drift away from the fight.

use crate::{ai, ingest_damage, modes, rating, sim};

/// A match ends at this many kills, or this many ticks if the two are too
/// evenly matched to settle it. 100 ticks is a second.
const KILL_TARGET: u16 = 5;
const MATCH_TICKS: u32 = 30_000; // five minutes of arena time

/// One duel, fought to a result, with both pilots' credit going into `r`.
fn duel(r: &mut rating::Rating, a: &ai::RosterEntry, b: &ai::RosterEntry, salt: u32) {
    let mut world = sim::World::with_map(0xd0e1 ^ salt, modes::build_duel_map);
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

    // Alternate which pilot starts on which side, so a positional advantage
    // in the duel room cannot accumulate into a rating.
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
            sim::sim_input { ship: s1, buttons: bot1.think(&world) },
            sim::sim_input { ship: s2, buttons: bot2.think(&world) },
        ];
        world.step(&inputs);

        let tick = world.state.tick;
        for (victim, _killer) in ingest_damage(&world, r, &name_of) {
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
                duel(&mut r, &roster[i], &roster[j], salt);
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Skill has to be worth something. The standing roster cannot show this
    /// on its own, because every pilot on it flies a different hull and the
    /// hull matchup is mixed into the result -- which is correct for a rating
    /// and useless for testing the skill parameter. So: same hull, skill
    /// alone, and the ladder had better sort.
    #[test]
    fn skill_decides_a_match_between_equal_hulls() {
        let roster = vec![
            ai::RosterEntry { name: "low", class: 0, team: 0, tile_x: 505, tile_y: 522, skill: 0.15 },
            ai::RosterEntry { name: "mid", class: 0, team: 1, tile_x: 519, tile_y: 502, skill: 0.50 },
            ai::RosterEntry { name: "high", class: 0, team: 1, tile_x: 519, tile_y: 502, skill: 0.95 },
        ];
        let r = run_roster(&roster, 4, false);
        let (lo, hi) = (r.rating_of("low"), r.rating_of("high"));
        assert!(hi > lo, "high {hi:.0} should outrank low {lo:.0}");
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
            assert!(
                r.games_of(e.name) > 0,
                "{} sat out the tournament",
                e.name
            );
        }
    }
}

