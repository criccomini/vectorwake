//! What rivets buy, and what each thing costs.
//!
//! Slots, and looks. Never strength. Everything in a kit trades against the
//! same thirty points, so what is sold is *which* upgrades a pilot may slot
//! rather than how many. The profile harness compares full builds in mirrored
//! live-format matches and reports family-wise confidence intervals. See
//! docs/design/match-game.md.
//!
//! Every slot in the selected zone is on this shelf, which used to be untrue
//! and was the reason the shelf got rebuilt. Four traits sat on the roster
//! instead of in the kit space: a second barrel, a third bomb rung, six mines,
//! and a deeper rung of shrapnel. Nothing can be sold that exists on one hull.
//! They are slots now, so they are for sale, and the ceiling below is the
//! arena's rather than any hull's. Nothing here can be bought and then refused
//! by the ship somebody wanted to fly it on.
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
/// `owned` is what the account already has there, and `ceiling` is what the
/// selected zone can resolve. The ladder moves one step at a time so every
/// purchase is useful as soon as it lands.
pub(super) fn next_step(slot: usize, owned: u8, ceiling: u8) -> Option<(u8, u32)> {
    // What the selected game has in this slot. Zero is a slot that does not
    // exist there, and the shelf skips it rather than charging for something
    // that room will refuse.
    if ceiling == 0 {
        return None;
    }

    // Stat ceilings are their effective physics depths. Every one is part of
    // the starter profile union, so there is no stat step left to sell and no
    // purchase that can disappear into a clamp.
    if slot < sim::UP_COUNT {
        return None;
    }

    // How many times this account has already bought in this slot, which is
    // what a ladder's price climbs with. Counting purchases rather than rungs
    // is what lets one slot start from nothing and another from what everyone
    // is dealt, and charge the same for the first step of either.
    let bought = owned.saturating_sub(sim::World::base_entitlements()[slot]) as u32;

    // A rung of a trigger's ladder. Everything above the first is bought,
    // and the ceiling is how far the arena's own ladder climbs, so a rung
    // sold is a rung something actually fires.
    if slot < sim::UP_COUNT + sim::TRIG_COUNT {
        return match owned {
            n if n < ceiling => Some((n + 1, 30 + 30 * bought)),
            _ => None,
        };
    }

    // Everything else is a rung, priced the same way and for the same reason:
    // an add-on, or a rung of a charge rack.
    //
    // Starting from nothing is allowed, which it was not while every account
    // began with one rung of every add-on. It is also what the racks needed.
    // Charges used to be sold as a *kind*, one price for 255, which is "the
    // arena decides how many": buying the mine bought all six at once, and
    // repel and burst, which everybody was dealt without limit, could never
    // be bought at all because nobody was ever short of one. A rack is a
    // ladder like every other ladder on that page, and the shelf sells
    // ladders.
    let charges =
        sim::UP_COUNT + sim::TRIG_COUNT + sim::TRIG_COUNT * sim::MOD_COUNT + sim::MAX_CHARGES;
    if slot < charges {
        return match owned {
            n if n < ceiling => Some((n + 1, 20 + 20 * bought)),
            _ => None,
        };
    }
    None
}

/// What to call a slot, as a person reads it. The same vocabulary the corner
/// stack uses while a pilot flies, so nothing is learned twice.
pub(super) fn name_of(slot: usize) -> String {
    const STATS: [&str; sim::UP_COUNT] = ["energy", "recharge", "speed", "thrust", "rotation"];
    const MODS: [&str; sim::MOD_COUNT] = [
        "spray",
        "bouncing",
        "proximity",
        "shrapnel",
        "freeze",
        "push",
    ];
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
        let m = at % sim::MOD_COUNT;
        let gun = at < sim::MOD_COUNT;
        // Which trigger it hangs off, but only where both can hang it.
        // Bouncing and freeze exist on the gun and the bomb, so a card saying
        // "bouncing" would not say which. Spray and the double barrel are the
        // gun's alone and proximity and shrapnel the bomb's, and prefixing
        // those makes a name out of two words where one is the whole answer.
        let ceiling = sim::World::baseline_kit_ceiling();
        let other = if gun {
            sim::slot_mod(sim::TRIG_BOMB, m)
        } else {
            sim::slot_mod(sim::TRIG_GUN, m)
        };
        if ceiling[other as usize] == 0 {
            return MODS[m].to_string();
        }
        return format!("{} {}", if gun { "gun" } else { "bomb" }, MODS[m]);
    }
    CHARGES
        .get(at - sim::TRIG_COUNT * sim::MOD_COUNT)
        .copied()
        .unwrap_or("a charge")
        .to_string()
}

/// One line under a price, where the thing being sold needs a sentence. Most
/// do not: "last repel, 20 rivets" is already a sentence.
pub(super) fn note_for(slot: usize, owned: u8, _next: u8) -> Option<String> {
    let charges = sim::UP_COUNT + sim::TRIG_COUNT + sim::TRIG_COUNT * sim::MOD_COUNT;
    if slot >= charges && owned == 0 {
        return Some("a charge kind, to carry and spend".into());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_live_ladder_ends_at_the_given_zone_ceiling() {
        let base = sim::World::base_entitlements();
        let ceiling = sim::World::baseline_kit_ceiling();
        for (slot, dealt) in base.iter().enumerate() {
            let mut owned = *dealt;
            let mut steps = 0;
            while let Some((next, price)) = next_step(slot, owned, ceiling[slot]) {
                assert!(next > owned, "slot {slot} has to move");
                assert!(next <= ceiling[slot], "slot {slot} passed its ceiling");
                assert!(price > 0, "slot {slot} is not free");
                owned = next;
                steps += 1;
                assert!(steps < 16, "slot {slot} never finishes");
            }
        }
    }

    #[test]
    fn stats_and_zone_absences_are_not_for_sale() {
        for slot in 0..sim::UP_COUNT {
            assert_eq!(next_step(slot, 0, 8), None, "stat slot {slot}");
        }
        let spray = sim::slot_mod(sim::TRIG_GUN, sim::MOD_MULTI) as usize;
        assert_eq!(next_step(spray, 0, 0), None, "this zone has no spray");
    }

    #[test]
    fn racks_and_specialties_climb_one_in_increasing_prices() {
        let base = sim::World::base_entitlements();
        let ceiling = sim::World::baseline_kit_ceiling();
        for slot in [
            sim::slot_mod(sim::TRIG_GUN, sim::MOD_MULTI) as usize,
            sim::slot_mod(sim::TRIG_BOMB, sim::MOD_SHRAPNEL) as usize,
            sim::slot_charge(sim::CHARGE_REPEL) as usize,
            sim::slot_charge(sim::CHARGE_BURST) as usize,
            sim::slot_charge(sim::CHARGE_MINE) as usize,
        ] {
            let mut owned = base[slot];
            let mut last = 0;
            while let Some((next, price)) = next_step(slot, owned, ceiling[slot]) {
                assert_eq!(next, owned + 1, "slot {slot} skips a rung");
                assert!(price > last, "slot {slot} did not get dearer");
                owned = next;
                last = price;
            }
            assert_eq!(owned, ceiling[slot], "slot {slot} stopped early");
        }
    }

    #[test]
    fn an_absent_slot_is_never_sold_even_if_an_old_row_claims_it() {
        for slot in [
            sim::slot_mod(sim::TRIG_BOMB, sim::MOD_MULTI),
            sim::slot_mod(sim::TRIG_GUN, sim::MOD_PROX),
            sim::slot_mod(sim::TRIG_GUN, sim::MOD_SHRAPNEL),
        ] {
            for owned in 0..4u8 {
                assert_eq!(
                    next_step(slot as usize, owned, 0),
                    None,
                    "slot {slot} does not exist and is not for sale"
                );
            }
        }
    }
}
