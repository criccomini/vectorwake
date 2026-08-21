//! What rivets buy, and what each thing costs.
//!
//! Slots, and looks. Never strength. Everything in a kit trades against the
//! same thirty points, so what is sold is *which* upgrades a pilot may
//! slot rather than how many, and the drill harness is the referee: anything
//! that wins more than 55% of matched bouts against the bare kit, on at least
//! two hulls, goes back to the bench. See docs/design/match-game.md.
//!
//! Every slot in the game is on this shelf, which used to be untrue and was
//! the reason the shelf got rebuilt. Four traits sat on the roster instead of
//! in the kit space -- a second barrel, a third bomb rung, six mines, a
//! deeper rung of shrapnel, and nothing can be sold that exists on
//! one hull. They are slots now, so they are for sale, and the ceiling below
//! is the arena's rather than any hull's: nothing here can be bought and then
//! refused by the ship somebody wanted to fly it on.
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
    // What the game has in this slot. Zero is a slot that does not exist --
    // a bullet with a proximity fuse, a bomb that comes in pairs -- and the
    // shelf skips it rather than taking money for it.
    let ceiling = sim::World::baseline_kit_ceiling()[slot];
    if ceiling == 0 {
        return None;
    }

    // The stats, whose last two steps are bought. Six is exactly the
    // budget over five of them, so this is buying the right to concentrate
    // rather than more to spend: five stats at eight is forty against a
    // budget of thirty, and the ceiling is unreachable by construction.
    if slot < sim::UP_COUNT {
        return match owned {
            n if n < sim::UP_STEPS_BASE => None, // nothing below the baseline is for sale
            n if n < ceiling => Some((n + 1, if n == sim::UP_STEPS_BASE { 40 } else { 90 })),
            _ => None,
        };
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
            n if n < ceiling => Some((n + 1, 35 + 35 * bought)),
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
        "double barrel",
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
/// do not: "gun bounce, 35 rivets" is already a sentence.
pub(super) fn note_for(slot: usize, owned: u8, next: u8) -> Option<String> {
    if slot < sim::UP_COUNT {
        return Some(format!("a {}th step, on this stat alone", next));
    }
    let charges = sim::UP_COUNT + sim::TRIG_COUNT + sim::TRIG_COUNT * sim::MOD_COUNT;
    if slot >= charges && owned == 0 {
        return Some("a charge kind, to carry and spend".into());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every ladder ends. A shelf that always had something to sell in a slot
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

    /// A rack is a ladder, climbed a rung at a time like every other.
    ///
    /// These were bought as a *kind*: one price for 255, which is "the arena
    /// decides how many". Buying the mine bought all six at once, and repel
    /// and burst, dealt to everybody without limit, could never be bought at
    /// all because nobody was ever short of one. Two of the three charges in
    /// this game were unsellable by construction.
    #[test]
    fn a_rack_is_climbed_a_rung_at_a_time() {
        let base = sim::World::base_entitlements();
        let ceiling = sim::World::baseline_kit_ceiling();

        let mine = sim::slot_charge(sim::CHARGE_MINE) as usize;
        assert_eq!(base[mine], 0, "nobody is dealt a mine");
        let (first, cheap) = next_step(mine, 0).expect("the first mine is for sale");
        assert_eq!(first, 1, "one mine, not the whole rack");
        let (second, dear) = next_step(mine, first).expect("and a second");
        assert_eq!(second, 2);
        assert!(dear > cheap, "and each rung costs more than the last");

        // All the way to the arena's own ceiling, and no further.
        let mut owned = 0u8;
        let mut rungs = 0;
        while let Some((next, _)) = next_step(mine, owned) {
            owned = next;
            rungs += 1;
        }
        assert_eq!(owned, ceiling[mine], "the rack ends where the arena's does");
        assert_eq!(rungs, 6, "six of them, which is most of a kit");

        // And the two an account is dealt one of have the rest for sale.
        for k in [sim::CHARGE_REPEL, sim::CHARGE_BURST] {
            let slot = sim::slot_charge(k) as usize;
            assert_eq!(base[slot], 1, "one is dealt");
            let mut owned = base[slot];
            let mut rungs = 0;
            while let Some((next, _)) = next_step(slot, owned) {
                owned = next;
                rungs += 1;
            }
            assert_eq!(rungs, 2, "and the other two rungs are bought");
            assert_eq!(owned, ceiling[slot]);
        }
    }

    /// Barrels are for sale, which is the whole reason the slot space was
    /// flattened. This was DoubleBarrel, a flag one hull carried and nothing
    /// could ever offer.
    #[test]
    fn barrels_are_on_the_shelf() {
        let slot = sim::slot_mod(sim::TRIG_GUN, sim::MOD_BARREL) as usize;
        let base = sim::World::base_entitlements();
        assert_eq!(base[slot], 0, "nobody is dealt one");
        let (first, cheap) = next_step(slot, 0).expect("a first barrel is for sale");
        assert_eq!(first, 1);
        let (second, dear) = next_step(slot, first).expect("and a second");
        assert_eq!(second, 2);
        assert!(dear > cheap, "the second costs more than the first");
        assert_eq!(next_step(slot, second), None, "and then it is finished");
    }

    /// The three other traits the roster used to hoard, now that they are
    /// slots: the third bomb rung was the Anvil's, the third rung of shrapnel
    /// was the bombers', and both are on the shelf for anyone.
    #[test]
    fn the_rosters_old_exclusives_are_for_sale() {
        let base = sim::World::base_entitlements();
        let bomb = sim::slot_level(sim::TRIG_BOMB) as usize;
        let mut owned = base[bomb];
        let mut steps = 0;
        while let Some((next, _)) = next_step(bomb, owned) {
            owned = next;
            steps += 1;
        }
        assert_eq!(
            steps, 1,
            "the third bomb rung is for sale, where it was the Anvil's alone"
        );
        assert_eq!(
            owned, 2,
            "and it stops at the rung the arena's ladder actually reaches"
        );

        let shrap = sim::slot_mod(sim::TRIG_BOMB, sim::MOD_SHRAPNEL) as usize;
        owned = base[shrap];
        steps = 0;
        while let Some((next, _)) = next_step(shrap, owned) {
            owned = next;
            steps += 1;
        }
        assert_eq!(
            steps, 3,
            "and shrapnel climbs to the bombers' old three, from nothing: an \
             add-on is bought now rather than granted"
        );
    }

    /// A slot the game does not have is not on the shelf. Bombs neither fan
    /// nor come in pairs, and a bullet carries no fuse: taking money for one
    /// would be the trap the hull rows used to set, moved to the till.
    #[test]
    fn a_slot_that_does_not_exist_is_not_sold() {
        for slot in [
            sim::slot_mod(sim::TRIG_BOMB, sim::MOD_MULTI),
            sim::slot_mod(sim::TRIG_BOMB, sim::MOD_BARREL),
            sim::slot_mod(sim::TRIG_GUN, sim::MOD_PROX),
            sim::slot_mod(sim::TRIG_GUN, sim::MOD_SHRAPNEL),
        ] {
            for owned in 0..4u8 {
                assert_eq!(
                    next_step(slot as usize, owned),
                    None,
                    "slot {slot} does not exist and is not for sale"
                );
            }
        }
    }

    /// Nothing on the shelf is dead on arrival: every step this page will
    /// sell is a step the game's own ceiling can hold. That is the property
    /// the hull rows made impossible, and it is why they went.
    #[test]
    fn everything_sold_fits_in_a_kit() {
        let ceiling = sim::World::baseline_kit_ceiling();
        let base = sim::World::base_entitlements();
        for slot in 0..sim::SLOT_COUNT {
            let mut owned = base[slot];
            while let Some((next, _)) = next_step(slot, owned) {
                assert!(
                    next == 255 || next <= ceiling[slot],
                    "slot {slot} sold a step to {next} over a ceiling of {}",
                    ceiling[slot]
                );
                owned = next;
            }
        }
    }
}
