//! Named thirty-point loadouts.
//!
//! These are the builds a new pilot can choose before they know which of the
//! twenty-three kit slots they want to tune. They are ordinary kits, not a
//! second rules system: the hangar can edit one and save the result under a
//! new name, and the arena validates it exactly as it validates any other kit.

use crate::{catalog, sim, Room};

#[derive(Clone, Debug, serde::Serialize)]
pub struct Profile {
    pub name: &'static str,
    pub builtin: bool,
    pub kit: [u8; sim::SLOT_COUNT],
}

pub const BUILTIN_NAMES: [&str; 3] = ["Gunner", "Bomber", "Control"];

fn base() -> [u8; sim::SLOT_COUNT] {
    [0; sim::SLOT_COUNT]
}

fn stats(kit: &mut [u8; sim::SLOT_COUNT], values: [u8; sim::UP_COUNT]) {
    for (slot, value) in values.into_iter().enumerate() {
        kit[sim::slot_stat(slot) as usize] = value;
    }
}

fn gunner() -> [u8; sim::SLOT_COUNT] {
    let mut kit = base();
    stats(&mut kit, [6, 5, 5, 1, 1]);
    kit[sim::slot_level(sim::TRIG_GUN) as usize] = 2;
    kit[sim::slot_level(sim::TRIG_BOMB) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_GUN, sim::MOD_MULTI) as usize] = 2;
    kit[sim::slot_mod(sim::TRIG_GUN, sim::MOD_BOUNCE) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_GUN, sim::MOD_FREEZE) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_BOMB, sim::MOD_PROX) as usize] = 1;
    kit[sim::slot_charge(sim::CHARGE_REPEL) as usize] = 2;
    kit[sim::slot_charge(sim::CHARGE_BURST) as usize] = 2;
    kit
}

fn bomber() -> [u8; sim::SLOT_COUNT] {
    let mut kit = base();
    stats(&mut kit, [6, 5, 5, 1, 1]);
    kit[sim::slot_level(sim::TRIG_GUN) as usize] = 1;
    kit[sim::slot_level(sim::TRIG_BOMB) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_GUN, sim::MOD_BOUNCE) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_GUN, sim::MOD_FREEZE) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_BOMB, sim::MOD_BOUNCE) as usize] = 2;
    kit[sim::slot_mod(sim::TRIG_BOMB, sim::MOD_PROX) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_BOMB, sim::MOD_SHRAPNEL) as usize] = 1;
    kit[sim::slot_charge(sim::CHARGE_REPEL) as usize] = 2;
    kit[sim::slot_charge(sim::CHARGE_BURST) as usize] = 2;
    kit
}

fn control() -> [u8; sim::SLOT_COUNT] {
    let mut kit = base();
    stats(&mut kit, [6, 5, 5, 1, 1]);
    kit[sim::slot_level(sim::TRIG_GUN) as usize] = 1;
    kit[sim::slot_level(sim::TRIG_BOMB) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_GUN, sim::MOD_BOUNCE) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_GUN, sim::MOD_FREEZE) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_BOMB, sim::MOD_BOUNCE) as usize] = 2;
    kit[sim::slot_mod(sim::TRIG_BOMB, sim::MOD_PROX) as usize] = 1;
    kit[sim::slot_mod(sim::TRIG_BOMB, sim::MOD_FREEZE) as usize] = 1;
    kit[sim::slot_charge(sim::CHARGE_REPEL) as usize] = 2;
    kit[sim::slot_charge(sim::CHARGE_BURST) as usize] = 2;
    kit
}

pub fn builtins() -> Vec<Profile> {
    [gunner(), bomber(), control()]
        .into_iter()
        .zip(BUILTIN_NAMES)
        .map(|(kit, name)| Profile {
            name,
            builtin: true,
            kit,
        })
        .collect()
}

/// The bought-up specialization used by the balance harness. It spends the
/// same thirty points as every starter profile and differs only in access to
/// a deeper repel rack, which is exactly the fairness claim progression has
/// to survive.
pub fn calibration_profiles() -> Vec<Profile> {
    let mut profiles = builtins();
    let mut kit = control();
    kit[sim::slot_mod(sim::TRIG_BOMB, sim::MOD_BOUNCE) as usize] = 1;
    kit[sim::slot_charge(sim::CHARGE_REPEL) as usize] = 3;
    profiles.push(Profile {
        name: "Veteran",
        builtin: false,
        kit,
    });
    profiles
}

pub fn is_builtin_name(name: &str) -> bool {
    BUILTIN_NAMES
        .iter()
        .any(|reserved| reserved.eq_ignore_ascii_case(name))
}

/// The slot ceiling for the zone the player named, or the catalog default.
/// The same config application path builds a live room, so the shop cannot
/// sell an add-on that the selected game will refuse.
pub fn zone_ceiling(catalog: &catalog::Catalog, requested: Option<&str>) -> [u8; sim::SLOT_COUNT] {
    let selected = requested
        .filter(|name| catalog.zone(name).is_some())
        .map(str::to_owned)
        .or_else(|| catalog.fallback_zone());
    let mut world = sim::World::with_map(1, sim::build_arena);
    if let Some(zone) = selected.and_then(|name| catalog.zone(&name)) {
        Room::apply_config(&mut world, &zone.arena);
    }
    world.kit_ceilings()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_starter_profile_is_a_owned_full_build() {
        let owned = sim::World::base_entitlements();
        let ceiling = sim::World::baseline_kit_ceiling();
        for profile in builtins() {
            assert_eq!(
                sim::World::kit_cost(&profile.kit),
                sim::KIT_BUDGET,
                "{} is not a full build",
                profile.name
            );
            for (slot, value) in profile.kit.iter().enumerate() {
                assert!(
                    *value <= owned[slot],
                    "{} asks for unowned slot {slot}",
                    profile.name
                );
                assert!(
                    *value <= ceiling[slot],
                    "{} exceeds slot {slot}",
                    profile.name
                );
            }
        }
    }

    #[test]
    fn starter_profile_names_are_reserved_without_case_tricks() {
        assert!(is_builtin_name("gunner"));
        assert!(is_builtin_name("BOMBER"));
        assert!(!is_builtin_name("Screen"));
    }

    #[test]
    fn the_veteran_comparison_buys_choice_and_not_more_points() {
        let profiles = calibration_profiles();
        let veteran = profiles.last().expect("a veteran comparison");
        assert_eq!(sim::World::kit_cost(&veteran.kit), sim::KIT_BUDGET);
        let ceiling = sim::World::baseline_kit_ceiling();
        assert!(veteran
            .kit
            .iter()
            .zip(ceiling)
            .all(|(want, max)| *want <= *max));
        let repel = sim::slot_charge(sim::CHARGE_REPEL) as usize;
        assert!(veteran.kit[repel] > sim::World::base_entitlements()[repel]);
    }
}
