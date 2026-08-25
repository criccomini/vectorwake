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

/// One declared balance question. The two profiles are kept beside the name so
/// calibration cannot silently expand a roster into comparisons nobody meant
/// to certify.
#[derive(Clone, Debug, serde::Serialize)]
pub struct ProfileContrast {
    pub name: &'static str,
    pub a: Profile,
    pub b: Profile,
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
    stats(&mut kit, [5, 4, 5, 2, 2]);
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
    stats(&mut kit, [5, 4, 5, 2, 2]);
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
    stats(&mut kit, [5, 4, 5, 2, 2]);
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

pub(crate) const STARTER_STATS: [u8; sim::UP_COUNT] = [5, 4, 5, 2, 2];

fn calibration_profile(name: &'static str, kit: [u8; sim::SLOT_COUNT]) -> Profile {
    Profile {
        name,
        builtin: false,
        kit,
    }
}

fn margin_chassis() -> [u8; sim::SLOT_COUNT] {
    let bounce = sim::slot_mod(sim::TRIG_BOMB, sim::MOD_BOUNCE) as usize;
    let mut chassis = control();
    chassis[bounce] -= 1;
    chassis
}

/// A twenty-nine-point Control-derived chassis with one named stat at seven.
///
/// Raising the stat is funded from a fixed prefix of equipment points: two
/// Burst charges, two Repel charges, then bomb freeze. Bomb bounce is removed
/// separately because it is the common alternative purchased by the thirtieth
/// point. No other stat moves, so the two finished profiles isolate the eighth
/// pip.
fn top_margin_chassis(stat: usize) -> [u8; sim::SLOT_COUNT] {
    assert!(stat < sim::UP_COUNT, "profile margin stat is out of range");
    let mut chassis = margin_chassis();
    let added = usize::from(
        7u8.checked_sub(STARTER_STATS[stat])
            .expect("starter stat exceeds the top-margin chassis"),
    );
    chassis[sim::slot_stat(stat) as usize] = 7;
    let burst = sim::slot_charge(sim::CHARGE_BURST) as usize;
    let repel = sim::slot_charge(sim::CHARGE_REPEL) as usize;
    let bomb_freeze = sim::slot_mod(sim::TRIG_BOMB, sim::MOD_FREEZE) as usize;
    for slot in [burst, burst, repel, repel, bomb_freeze]
        .into_iter()
        .take(added)
    {
        assert!(chassis[slot] > 0, "profile equipment donor is empty");
        chassis[slot] -= 1;
    }
    assert_eq!(sim::World::kit_cost(&chassis), sim::KIT_BUDGET - 1);
    chassis
}

/// The ordered family certified by the profile calibration screen.
///
/// Five rows price one stat point at the starter margin against the same
/// bomb-bounce point. The last five ask the same question of each eighth stat
/// pip. Only these ten flight-stat comparisons enter the simultaneous family.
pub fn calibration_contrasts() -> Vec<ProfileContrast> {
    let mut contrasts = Vec::with_capacity(10);
    let bounce = sim::slot_mod(sim::TRIG_BOMB, sim::MOD_BOUNCE) as usize;
    for (stat, (name, stat_name, bounce_name)) in [
        (
            "Starter margin: Energy 6 vs bomb bounce 2",
            "Starter margin: Energy 6 and bomb bounce 1",
            "Starter margin: Energy 5 and bomb bounce 2",
        ),
        (
            "Starter margin: Recharge 5 vs bomb bounce 2",
            "Starter margin: Recharge 5 and bomb bounce 1",
            "Starter margin: Recharge 4 and bomb bounce 2",
        ),
        (
            "Starter margin: Speed 6 vs bomb bounce 2",
            "Starter margin: Speed 6 and bomb bounce 1",
            "Starter margin: Speed 5 and bomb bounce 2",
        ),
        (
            "Starter margin: Thrust 3 vs bomb bounce 2",
            "Starter margin: Thrust 3 and bomb bounce 1",
            "Starter margin: Thrust 2 and bomb bounce 2",
        ),
        (
            "Starter margin: Rotation 3 vs bomb bounce 2",
            "Starter margin: Rotation 3 and bomb bounce 1",
            "Starter margin: Rotation 2 and bomb bounce 2",
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let chassis = margin_chassis();
        let mut stat_kit = chassis;
        stat_kit[sim::slot_stat(stat) as usize] += 1;
        let mut bounce_kit = chassis;
        bounce_kit[bounce] += 1;
        contrasts.push(ProfileContrast {
            name,
            a: calibration_profile(stat_name, stat_kit),
            b: calibration_profile(bounce_name, bounce_kit),
        });
    }

    for (stat, (name, stat_name, bounce_name)) in [
        (
            "Top margin: Energy 8 vs bomb bounce 2",
            "Top margin: Energy 8 and bomb bounce 1",
            "Top margin: Energy 7 and bomb bounce 2",
        ),
        (
            "Top margin: Recharge 8 vs bomb bounce 2",
            "Top margin: Recharge 8 and bomb bounce 1",
            "Top margin: Recharge 7 and bomb bounce 2",
        ),
        (
            "Top margin: Speed 8 vs bomb bounce 2",
            "Top margin: Speed 8 and bomb bounce 1",
            "Top margin: Speed 7 and bomb bounce 2",
        ),
        (
            "Top margin: Thrust 8 vs bomb bounce 2",
            "Top margin: Thrust 8 and bomb bounce 1",
            "Top margin: Thrust 7 and bomb bounce 2",
        ),
        (
            "Top margin: Rotation 8 vs bomb bounce 2",
            "Top margin: Rotation 8 and bomb bounce 1",
            "Top margin: Rotation 7 and bomb bounce 2",
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let chassis = top_margin_chassis(stat);
        let mut stat_kit = chassis;
        stat_kit[sim::slot_stat(stat) as usize] += 1;
        let mut bounce_kit = chassis;
        bounce_kit[bounce] += 1;
        contrasts.push(ProfileContrast {
            name,
            a: calibration_profile(stat_name, stat_kit),
            b: calibration_profile(bounce_name, bounce_kit),
        });
    }
    contrasts
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
    fn core_fallback_is_the_builtin_gunner() {
        let ceiling = sim::World::baseline_kit_ceiling();
        assert_eq!(sim::World::starter_kit(ceiling), builtins()[0].kit);
    }

    #[test]
    fn starter_margin_contrasts_isolate_one_last_point() {
        let contrasts = calibration_contrasts();
        let chassis = margin_chassis();
        let bounce = sim::slot_mod(sim::TRIG_BOMB, sim::MOD_BOUNCE) as usize;
        assert_eq!(sim::World::kit_cost(&chassis), sim::KIT_BUDGET - 1);
        for (stat, contrast) in contrasts[0..5].iter().enumerate() {
            let a_changes: Vec<_> = contrast
                .a
                .kit
                .iter()
                .zip(chassis)
                .enumerate()
                .filter(|(_, (value, base))| **value != *base)
                .collect();
            let b_changes: Vec<_> = contrast
                .b
                .kit
                .iter()
                .zip(chassis)
                .enumerate()
                .filter(|(_, (value, base))| **value != *base)
                .collect();
            assert_eq!(a_changes.len(), 1, "{} changes one slot", contrast.name);
            assert_eq!(b_changes.len(), 1, "{} changes one slot", contrast.name);
            assert_eq!(a_changes[0].0, sim::slot_stat(stat) as usize);
            assert_eq!(b_changes[0].0, bounce);
            assert_eq!(
                contrast.a.kit[sim::slot_stat(stat) as usize],
                STARTER_STATS[stat] + 1
            );
            assert_eq!(contrast.a.kit[bounce], 1);
            assert_eq!(
                contrast.b.kit[sim::slot_stat(stat) as usize],
                STARTER_STATS[stat]
            );
            assert_eq!(contrast.b.kit[bounce], 2);
        }
    }

    #[test]
    fn top_margin_contrasts_isolate_the_eighth_pip() {
        let contrasts = calibration_contrasts();
        let bounce = sim::slot_mod(sim::TRIG_BOMB, sim::MOD_BOUNCE) as usize;
        let donors = [
            sim::slot_charge(sim::CHARGE_BURST) as usize,
            sim::slot_charge(sim::CHARGE_BURST) as usize,
            sim::slot_charge(sim::CHARGE_REPEL) as usize,
            sim::slot_charge(sim::CHARGE_REPEL) as usize,
            sim::slot_mod(sim::TRIG_BOMB, sim::MOD_FREEZE) as usize,
        ];
        for (stat, contrast) in contrasts[5..10].iter().enumerate() {
            let chassis = top_margin_chassis(stat);
            let mut expected = margin_chassis();
            expected[sim::slot_stat(stat) as usize] = 7;
            for &slot in donors.iter().take(usize::from(7 - STARTER_STATS[stat])) {
                expected[slot] -= 1;
            }
            assert_eq!(chassis, expected, "{} uses fixed donors", contrast.name);
            assert_eq!(sim::World::kit_cost(&chassis), sim::KIT_BUDGET - 1);
            assert_eq!(chassis[sim::slot_stat(stat) as usize], 7);
            for other in 0..sim::UP_COUNT {
                if other != stat {
                    assert_eq!(
                        chassis[sim::slot_stat(other) as usize],
                        STARTER_STATS[other],
                        "{} changes another stat",
                        contrast.name
                    );
                }
            }
            assert_eq!(contrast.a.kit[sim::slot_stat(stat) as usize], 8);
            assert_eq!(contrast.a.kit[bounce], 1);
            assert_eq!(contrast.b.kit[sim::slot_stat(stat) as usize], 7);
            assert_eq!(contrast.b.kit[bounce], 2);
            for slot in 0..sim::SLOT_COUNT {
                if slot != sim::slot_stat(stat) as usize && slot != bounce {
                    assert_eq!(
                        contrast.a.kit[slot], contrast.b.kit[slot],
                        "{} differs in extra slot {slot}",
                        contrast.name
                    );
                }
            }
        }
    }

    #[test]
    fn calibration_contrasts_are_ordered_named_and_legal() {
        let ceiling = sim::World::baseline_kit_ceiling();
        let contrasts = calibration_contrasts();
        assert_eq!(contrasts.len(), 10);
        assert_eq!(
            contrasts[0].name,
            "Starter margin: Energy 6 vs bomb bounce 2"
        );
        assert_eq!(contrasts[9].name, "Top margin: Rotation 8 vs bomb bounce 2");
        let mut names = std::collections::HashSet::new();
        for contrast in &contrasts {
            assert!(names.insert(contrast.name), "duplicate contrast name");
            for profile in [&contrast.a, &contrast.b] {
                assert_eq!(
                    sim::World::kit_cost(&profile.kit),
                    sim::KIT_BUDGET,
                    "{} is not a full build",
                    profile.name
                );
                assert!(
                    profile
                        .kit
                        .iter()
                        .zip(ceiling)
                        .all(|(want, max)| *want <= *max),
                    "{} exceeds the arena ceiling",
                    profile.name
                );
            }
        }
    }
}
