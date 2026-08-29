//! The roster, as the pages that draw it need to see it.
//!
//! A ship is preconstructed: its flight row, its gun and bomb, and the profile
//! it wears all belong to the class and are set by the zone. Nobody spends
//! points on one and nobody buys a rung, so there is nothing here to validate
//! and nothing to price. What is here is a name beside a profile, read out of
//! whichever zone the player selected, for the ship page and for the harness
//! that balances the seven against each other.
//!
//! This file used to hold three named thirty-point loadouts and the ten
//! matched contrasts that certified single stat pips. Both went with the kit:
//! the question "what is one point of Thrust worth against one of bomb
//! bounce" stops existing when there are no points, and what replaces it is
//! whether seven whole ships beat each other in a cycle. That is the hull
//! tournament in `calibrate`, and it is a far cheaper question to ask.

use crate::{catalog, pilots::CLASS_NAMES, sim, Room};

/// One hull, as a name and what it flies with.
#[derive(Clone, Debug, serde::Serialize)]
pub struct Profile {
    pub name: &'static str,
    pub class: u8,
    pub kit: [u8; sim::SLOT_COUNT],
}

/// The roster of the zone the player named, or of the catalog default.
///
/// Built through the same config path a live room takes, so a zone that
/// retunes a hull is describing the ship people will actually fly rather than
/// the baseline's idea of it.
pub fn roster(catalog: &catalog::Catalog, requested: Option<&str>) -> Vec<Profile> {
    let selected = requested
        .filter(|name| catalog.zone(name).is_some())
        .map(str::to_owned)
        .or_else(|| catalog.fallback_zone());
    let mut world = sim::World::with_map(1, sim::build_arena);
    if let Some(zone) = selected.and_then(|name| catalog.zone(&name)) {
        Room::apply_config(&mut world, &zone.arena);
    }
    (0..sim::MAX_CLASSES as u8)
        .map(|class| Profile {
            name: CLASS_NAMES[class as usize],
            class,
            kit: world.profile(class),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two kinds of charge and no more, on every hull.
    ///
    /// Whichever two a profile names bind to Q and W in kind order, so a third
    /// would have no key to be thrown with. The core holds the same line in
    /// `profiles_carry_two_kinds`; this is the shipped zones' half of it.
    #[test]
    fn no_hull_carries_a_third_charge_kind() {
        for kit in sim::World::baseline_profiles() {
            let kinds = (0..sim::MAX_CHARGES)
                .filter(|k| kit[sim::slot_charge(*k) as usize] > 0)
                .count();
            assert!(
                kinds <= sim::KIT_CHARGE_SLOTS,
                "a hull carries {kinds} kinds"
            );
        }
    }

    /// No two hulls are the same ship. A roster where two rows match is a
    /// roster with a name nobody has a reason to pick.
    #[test]
    fn every_hull_is_a_different_ship() {
        let profiles = sim::World::baseline_profiles();
        for (i, a) in profiles.iter().enumerate() {
            for (k, b) in profiles.iter().enumerate().skip(i + 1) {
                assert_ne!(
                    a, b,
                    "{} and {} fly the same profile",
                    CLASS_NAMES[i], CLASS_NAMES[k]
                );
            }
        }
    }
}
