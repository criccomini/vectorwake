//! What rivets buy, and what each thing costs.
//!
//! Slots, and looks. Never strength. Everything in a kit trades against the
//! same thirty points, so what the shop sells is *which* upgrades a pilot may
//! slot rather than how many, and the drill harness is the referee: anything
//! that wins more than 55% of matched bouts against the bare kit, on at least
//! two hulls, goes back to the bench. See docs/design/match-game.md.
//!
//! Prices are in tens rather than thousands, because bounty pays continuously
//! and a match pays a pilot something in the low tens. A price here is roughly
//! how many matches it costs, which is the unit a player actually feels.
//!
//! Every number in this file is a guess. No harness can measure a price, and
//! the way to find out is to watch what people buy.

use crate::sim;

/// The next step in one slot and what it costs, or `None` when the slot is
/// finished.
///
/// `owned` is what the account already has there, which is the baseline for a
/// slot nobody has spent on. The ladder is a step at a time on purpose: a
/// player who saves for the eighth step of a stat has to pass the seventh, so
/// every purchase is a thing they can use that evening.
pub(super) fn next_step(slot: usize, owned: u8) -> Option<(u8, u32)> {
    // The stats, whose last two steps are the shop's. Six is exactly the
    // budget over five of them, so this is buying the right to concentrate
    // rather than more to spend: five stats at eight is forty against a
    // budget of thirty, and the ceiling is unreachable by construction.
    if slot < sim::UP_COUNT {
        return match owned {
            n if n < sim::UP_STEPS_BASE => None, // nothing below the baseline is for sale
            n if n < sim::UP_STEPS => Some((n + 1, if n == sim::UP_STEPS_BASE { 40 } else { 90 })),
            _ => None,
        };
    }

    // A rung of a trigger's ladder. Two and three are the shop's; how far a
    // hull may climb is still the roster's business, and a pilot who buys a
    // rung their hull lacks has bought nothing they can slot on it.
    if slot < sim::UP_COUNT + sim::TRIG_COUNT {
        return match owned {
            0 => None,
            n if n < sim::MAX_RUNGS as u8 => Some((n + 1, 30 + 30 * (n as u32 - 1))),
            _ => None,
        };
    }

    // An add-on rung, priced the same way and for the same reason.
    let mods = sim::UP_COUNT + sim::TRIG_COUNT + sim::TRIG_COUNT * sim::MOD_COUNT;
    if slot < mods {
        return match owned {
            0 => None,
            n if n < sim::MOD_MAX => Some((n + 1, 35 + 35 * (n as u32 - 1))),
            _ => None,
        };
    }

    // A charge kind. Repel and burst are what everybody starts with, and the
    // other two are bought whole: a kind you may slot or one you may not,
    // with the count inside the kit's own budget either way. 255 is "the hull
    // decides", which is what the two free ones already carry.
    let k = slot - mods;
    if k < sim::MAX_CHARGES && owned == 0 {
        // The mine first, because it is the one the roster is built around:
        // Lattice slots six where everything else slots three, and that row
        // means nothing to an account that may not carry one at all.
        return Some((255, if k == sim::CHARGE_MINE { 120 } else { 200 }));
    }
    None
}

/// What to call a slot, as a person reads it. The same vocabulary the corner
/// stack uses while a pilot flies, so nothing is learned twice.
pub(super) fn name_of(slot: usize) -> String {
    const STATS: [&str; sim::UP_COUNT] = ["energy", "recharge", "speed", "thrust", "rotation"];
    const MODS: [&str; sim::MOD_COUNT] = ["multi", "bounce", "prox", "shrapnel", "freeze", "push"];
    const CHARGES: [&str; 4] = ["repel", "burst", "mine", "charge 4"];
    if slot < sim::UP_COUNT {
        return format!("{} depth", STATS[slot]);
    }
    let at = slot - sim::UP_COUNT;
    if at < sim::TRIG_COUNT {
        return format!("{} rung", if at == 0 { "gun" } else { "bomb" });
    }
    let at = at - sim::TRIG_COUNT;
    if at < sim::TRIG_COUNT * sim::MOD_COUNT {
        let trig = if at < sim::MOD_COUNT { "gun" } else { "bomb" };
        return format!("{trig} {}", MODS[at % sim::MOD_COUNT]);
    }
    CHARGES
        .get(at - sim::TRIG_COUNT * sim::MOD_COUNT)
        .copied()
        .unwrap_or("a charge")
        .to_string()
}

/// One line under a price, where the thing being sold needs a sentence. Most
/// do not: "gun bounce, 35 rivets" is already a sentence.
pub(super) fn note_for(slot: usize, owned: u8, next: u8) -> Option<String> {
    if slot < sim::UP_COUNT {
        return Some(format!("a {}th step, on this stat alone", next));
    }
    if next == 255 {
        return Some("a charge kind, to slot in any kit".into());
    }
    let _ = owned;
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every ladder ends. A shop that always had something to sell in a slot
    /// would let a pilot buy a ceiling the core cannot hold, and the money
    /// would go somewhere the game does not.
    #[test]
    fn every_slot_runs_out() {
        let base = sim::World::base_entitlements();
        for slot in 0..sim::SLOT_COUNT {
            let mut owned = base[slot];
            let mut steps = 0;
            while let Some((next, price)) = next_step(slot, owned) {
                assert!(next > owned, "slot {slot} has to move");
                assert!(price > 0, "slot {slot} is not free");
                owned = next;
                steps += 1;
                assert!(steps < 16, "slot {slot} never finishes");
            }
        }
    }

    /// Nothing below the baseline is for sale, which is what "everyone deals
    /// thirty" means: a new account already owns every step it can afford.
    #[test]
    fn the_baseline_is_not_on_the_shelf() {
        for u in 0..sim::UP_COUNT {
            for n in 0..sim::UP_STEPS_BASE {
                assert_eq!(
                    next_step(u, n),
                    None,
                    "a step below six is nobody's to sell"
                );
            }
        }
    }

    /// A stat's depth costs more the second time. Both steps are real: the
    /// eighth is where a concentrated build actually lands, and pricing them
    /// alike would make the seventh a formality.
    #[test]
    fn depth_gets_dearer() {
        let (seventh, first_price) = next_step(0, sim::UP_STEPS_BASE).expect("a seventh step");
        let (eighth, second_price) = next_step(0, seventh).expect("an eighth");
        assert_eq!((seventh, eighth), (7, 8));
        assert!(second_price > first_price);
        assert_eq!(next_step(0, eighth), None, "and then it is finished");
    }

    /// A charge kind is bought whole, and the hull decides the count.
    #[test]
    fn a_charge_kind_is_bought_whole() {
        let mine = sim::slot_charge(sim::CHARGE_MINE) as usize;
        let (n, price) = next_step(mine, 0).expect("the mine is for sale");
        assert_eq!(n, 255, "which is: the hull's row is the only limit");
        assert!(price > 0);
        assert_eq!(next_step(mine, 255), None, "once, not twice");
        assert_eq!(
            next_step(sim::slot_charge(sim::CHARGE_REPEL) as usize, 255),
            None,
            "and the two everybody starts with are never on the shelf"
        );
    }
}
