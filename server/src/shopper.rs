//! What a bot buys with what it has killed for, and what it flies once it has.
//!
//! Bots walk the same three endpoints a player's client walks: `/v1/upgrades`
//! for the shelf, `/v1/buy` for a rung, and `C2S_KIT` to the arena to say what
//! they are flying. Nothing here is privileged, and nothing here knows a price:
//! the meta-layer sets those and refuses what an account cannot afford, exactly
//! as it does for a person. See docs/design/ai-players.md.
//!
//! What is here is taste. An individual has a hull and a skill and now an
//! order it wants slots in, which is the difference between eight bots flying
//! the same thirty points and a room where Ozone throws shrapnel and Kestrel
//! runs. The order does two jobs: it decides what to buy next, and it decides
//! how the thirty points are spent once the rungs are owned.

use crate::sim;

/// A pilot's taste, as an order over slots with repeats for weight.
///
/// Read twice. `next_buy` walks it to pick the next rung to pay for, and
/// `build` walks it in passes to spend a kit's thirty points, so what a bot
/// saves up for is what it flies. A slot appearing twice gets a point on each
/// pass, which is how a build comes out weighted without a second table of
/// numbers to keep in step with this one.
///
/// Every list opens with a rung on its own trigger. Rung zero is what a
/// trigger already fires, so this is the first point that makes a pilot fire
/// something better rather than more of the same.
pub fn wants(name: &str, class: u8) -> Vec<usize> {
    let gun = sim::slot_level(sim::TRIG_GUN) as usize;
    let bomb = sim::slot_level(sim::TRIG_BOMB) as usize;
    let m = |t: usize, k: usize| sim::slot_mod(t, k) as usize;
    let s = |u: usize| sim::slot_stat(u) as usize;
    let c = |k: usize| sim::slot_charge(k) as usize;

    // Which of the three this individual is. From the name rather than the
    // hull, so two pilots in the same chassis are not the same pilot, and
    // stable across restarts because the name is.
    let mut h: u32 = 0x811c9dc5;
    for b in name.as_bytes() {
        h ^= *b as u32;
        h = h.wrapping_mul(0x01000193);
    }
    // The hull tilts it. A wide slow hull that has to get close is a bomber
    // more often than it is a runner; the hash decides the rest.
    let tilt = (h >> 7) % 3 + (class as u32 % 3);
    match tilt % 3 {
        // The gunner: bullets, and the energy to keep firing them.
        0 => vec![
            gun,
            s(sim::UP_ENERGY),
            s(sim::UP_RECHARGE),
            gun,
            m(sim::TRIG_GUN, sim::MOD_MULTI),
            s(sim::UP_ENERGY),
            m(sim::TRIG_GUN, sim::MOD_MULTI),
            c(sim::CHARGE_REPEL),
            s(sim::UP_SPEED),
            m(sim::TRIG_GUN, sim::MOD_BOUNCE),
            s(sim::UP_RECHARGE),
            c(sim::CHARGE_BURST),
        ],
        // The bomber: one heavy answer, aimed at where somebody will be.
        1 => vec![
            bomb,
            m(sim::TRIG_BOMB, sim::MOD_PROX),
            s(sim::UP_ENERGY),
            bomb,
            m(sim::TRIG_BOMB, sim::MOD_SHRAPNEL),
            s(sim::UP_THRUST),
            m(sim::TRIG_BOMB, sim::MOD_BOUNCE),
            c(sim::CHARGE_REPEL),
            s(sim::UP_RECHARGE),
            gun,
            c(sim::CHARGE_MINE),
            s(sim::UP_ENERGY),
        ],
        // The runner: arrive, leave, and be somewhere else when the answer
        // comes back.
        _ => vec![
            s(sim::UP_SPEED),
            s(sim::UP_THRUST),
            gun,
            s(sim::UP_ROTATION),
            m(sim::TRIG_GUN, sim::MOD_BOUNCE),
            s(sim::UP_SPEED),
            c(sim::CHARGE_REPEL),
            s(sim::UP_RECHARGE),
            m(sim::TRIG_GUN, sim::MOD_MULTI),
            c(sim::CHARGE_BURST),
            s(sim::UP_THRUST),
            gun,
        ],
    }
}

/// The next rung to pay for: the first slot this pilot wants that the shelf
/// still sells and the wallet still covers.
///
/// First affordable rather than cheapest. A pilot saving for a barrel and
/// buying a stat step every time one came within reach would never own the
/// barrel, and specializing is the whole point of a taste. What stops it
/// stalling forever on one slot is that prices climb: a ladder that has run
/// out of the wallet's reach steps aside for the next thing on the list.
pub fn next_buy(wants: &[usize], shelf: &[(usize, u32)], rivets: i64) -> Option<usize> {
    for slot in wants {
        for (offered, price) in shelf {
            if offered == slot && (*price as i64) <= rivets {
                return Some(*slot);
            }
        }
    }
    None
}

/// Thirty points, spent in the order this pilot wants them, inside whatever
/// ceiling it is flying under.
///
/// A pass at a time rather than filling each slot to its top in turn: six
/// points into one stat before anything else is a ship nobody would build,
/// and the repeats in `wants` are what weight the front of the list instead.
/// Slots that are full, or that the account has not bought, are skipped, so an
/// unspent budget flows to whatever is left.
pub fn build(wants: &[usize], ceiling: &[u8; sim::SLOT_COUNT]) -> [u8; sim::SLOT_COUNT] {
    let mut kit = [0u8; sim::SLOT_COUNT];
    let mut spent = 0u32;
    // Bounded by the budget rather than by a pass count: every pass that
    // spends nothing ends it, and one that spends something has moved the
    // budget, so this cannot loop.
    while spent < sim::KIT_BUDGET {
        let mut moved = false;
        for slot in wants {
            if spent >= sim::KIT_BUDGET {
                break;
            }
            let (Some(want), Some(top)) = (kit.get(*slot), ceiling.get(*slot)) else {
                continue;
            };
            if *want < *top {
                kit[*slot] += 1;
                spent += 1;
                moved = true;
            }
        }
        if !moved {
            // A taste can saturate before the budget does, especially now
            // that thrust and rotation stop after their first effective step.
            // Flow the remainder across the live ceiling rather than flying
            // points short. This is still the last choice: every weighted
            // preference above has already reached its top.
            let charge0 = sim::slot_charge(0) as usize;
            for slot in 0..sim::SLOT_COUNT {
                if spent >= sim::KIT_BUDGET {
                    break;
                }
                if slot >= charge0 && kit[slot] == 0 {
                    let kinds = kit[charge0..].iter().filter(|count| **count > 0).count();
                    if kinds >= sim::KIT_CHARGE_SLOTS {
                        continue;
                    }
                }
                if kit[slot] < ceiling[slot] {
                    kit[slot] += 1;
                    spent += 1;
                    moved = true;
                }
            }
            if !moved {
                break;
            }
        }
    }
    kit
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What an account that has bought everything flies under, which is the
    /// game's own row: the tests below are about taste, not entitlements.
    fn full_ceiling() -> [u8; sim::SLOT_COUNT] {
        *sim::World::baseline_kit_ceiling()
    }

    /// Two individuals are not the same pilot, and one individual is the same
    /// pilot every time the process starts.
    ///
    /// Over the shipped roster rather than a list made up here, because the
    /// eight of them are what fills a room: a roster that hashed to one taste
    /// would put eight identical ships in it, which is the thing this exists
    /// to stop.
    #[test]
    fn taste_is_personal_and_stable() {
        let a = wants("Ozone", 0);
        assert_eq!(a, wants("Ozone", 0), "a name is a career, not a coin toss");
        let mut seen: Vec<Vec<usize>> = Vec::new();
        for (name, class, _) in crate::ai::CALIBRATED {
            let list = wants(name, class);
            assert!(!list.is_empty(), "{name} wants nothing");
            if !seen.contains(&list) {
                seen.push(list);
            }
        }
        assert!(
            seen.len() >= 2,
            "the whole roster flies one build: {} tastes over eight pilots",
            seen.len()
        );
    }

    /// A bot buys what it is saving for rather than whatever is cheapest, and
    /// buys nothing at all with an empty wallet.
    #[test]
    fn a_bot_buys_the_first_thing_it_wants_and_can_afford() {
        let list = vec![9usize, 3, 1];
        let shelf = vec![(1usize, 30u32), (3, 40), (9, 90)];
        assert_eq!(
            next_buy(&list, &shelf, 200),
            Some(9),
            "the wallet covers it"
        );
        assert_eq!(
            next_buy(&list, &shelf, 50),
            Some(3),
            "and steps aside when it does not"
        );
        assert_eq!(
            next_buy(&list, &shelf, 0),
            None,
            "an empty wallet buys none"
        );
        assert_eq!(
            next_buy(&list, &[], 500),
            None,
            "and a shelf with nothing on it sells none"
        );
    }

    /// A build spends the budget, stays inside the ceiling, and puts the
    /// points where the pilot wanted them.
    #[test]
    fn a_build_spends_thirty_points_where_it_wanted_them() {
        let ceiling = full_ceiling();
        for name in ["Ozone", "Kestrel", "Halcyon", "Sable"] {
            let list = wants(name, 0);
            let kit = build(&list, &ceiling);
            let spent: u32 = kit.iter().map(|n| *n as u32).sum();
            assert_eq!(spent, sim::KIT_BUDGET, "{name} left points unspent");
            for slot in 0..sim::SLOT_COUNT {
                assert!(kit[slot] <= ceiling[slot], "{name} overran slot {slot}");
            }
            assert!(kit[list[0]] > 0, "{name} did not buy what it wanted most");
        }
    }

    /// The ceiling is the account's as well as the arena's, so a pilot that
    /// owns nothing flies the same shape a fresh player does rather than
    /// nothing at all.
    #[test]
    fn a_build_inside_a_bare_account_still_flies() {
        let base = sim::World::base_entitlements();
        let kit = build(&wants("Ozone", 0), &base);
        let spent: u32 = kit.iter().map(|n| *n as u32).sum();
        assert!(spent > 0, "a bare account flies a bare hull");
        assert!(spent <= sim::KIT_BUDGET, "and never past the budget");
        for slot in 0..sim::SLOT_COUNT {
            assert!(kit[slot] <= base[slot], "slot {slot} is not owned");
        }
    }
}
