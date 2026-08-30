//! Persistent bot pilots and the content that makes each one distinct.
//!
//! Identity, behavior, competence, hull, and rating are separate on purpose.
//! This module owns the first four. Rating remains a career result in the
//! meta-layer rather than a number a designer writes into a pilot.
//!
//! What a pilot flies with is among them again. It was not for a while: a
//! hull was a whole ship, so choosing the hull chose the ship, and a behavior
//! that wanted a bomb picked a hull with a rack. The kit is the pilot's on
//! both sides of the wire now, so a behavior that wants a bomb buys one, and
//! `kit` below is where it does. See decision 117.

pub const PILOT_SPEC_VERSION: u16 = 1;
/// Distinct ordinary house pilots the population director may claim.
pub const HOUSE_PILOT_POOL: usize = 65_536;
/// How many pilots were written by hand rather than generated. They are the
/// ones a tournament measures.
pub const AUTHORED_PILOT_COUNT: usize = CALIBRATED.len();
/// Separates tournament placement from every other deterministic random
/// stream.
pub const LADDER_START_NAMESPACE: u64 = 0x6c61_6464_6572_2d31;

/// Pick one start for each side from the policy the calibration harness
/// uses. Consecutive scenario seeds walk every Cartesian pair
/// once before repeating; the namespace only rotates where that cycle begins.
pub fn ladder_start_pair(
    namespace: u64,
    scenario_seed: u64,
    starts_per_team: [usize; 2],
) -> Option<[u32; 2]> {
    let combinations = starts_per_team[0].checked_mul(starts_per_team[1])?;
    if combinations == 0 {
        return None;
    }
    let mut offset = namespace.wrapping_add(0x9e37_79b9_7f4a_7c15);
    offset = (offset ^ (offset >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    offset = (offset ^ (offset >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    offset ^= offset >> 31;
    let pair = ((scenario_seed % combinations as u64) as usize
        + (offset % combinations as u64) as usize)
        % combinations;
    Some([
        (pair / starts_per_team[1]) as u32,
        (pair % starts_per_team[1]) as u32,
    ])
}

/// An immutable roster identity. Callsigns may become display names later;
/// this key is what lets the career remain the same pilot if that happens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PilotId(pub u32);

/// The parts of execution that have survived measurement.
///
/// Keeping the axes separate permits a careful shot who spends badly and a
/// disciplined pilot whose aim is weak. Neither value is an Elo estimate.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Competence {
    pub aim: f32,
    pub judgment: f32,
}

impl Competence {
    pub const fn uniform(skill: f32) -> Self {
        Self {
            aim: skill,
            judgment: skill,
        }
    }
}

/// A strategy names what a pilot is trying to accomplish. The shared brain
/// still supplies perception, routing, flight control, and weapon safety.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Strategy {
    Duelist,
    Bombardier,
    Skirmisher,
    Heavy,
    Ambusher,
    Brawler,
    Denier,
    Runner,
}

/// Stable behavior preferences. These affect choices, not what the ship is
/// physically allowed to do.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BehaviorProfile {
    pub strategy: Strategy,
    /// Working gun distance in world pixels.
    pub engagement_range: f32,
    /// Willingness to keep closing on a distant target.
    pub pursuit: f32,
    /// Weight given to fighting when an objective is also available.
    pub aggression: f32,
    /// Weight given to flags and other zone objectives.
    pub objective: f32,
    /// Signed change to the energy threshold for breaking contact.
    pub retreat_bias: f32,
    /// Preference for using a bomb when both weapons are viable.
    pub bomb_preference: f32,
}

impl BehaviorProfile {
    pub const fn for_strategy(strategy: Strategy) -> Self {
        match strategy {
            Strategy::Duelist => Self {
                strategy,
                engagement_range: 175.0,
                pursuit: 1.15,
                aggression: 1.15,
                objective: 0.75,
                retreat_bias: -0.03,
                bomb_preference: 0.25,
            },
            Strategy::Bombardier => Self {
                strategy,
                engagement_range: 205.0,
                pursuit: 0.75,
                aggression: 0.90,
                objective: 0.70,
                retreat_bias: 0.02,
                bomb_preference: 1.00,
            },
            Strategy::Skirmisher => Self {
                strategy,
                engagement_range: 240.0,
                pursuit: 0.70,
                aggression: 0.95,
                objective: 0.85,
                retreat_bias: 0.06,
                bomb_preference: 0.30,
            },
            Strategy::Heavy => Self {
                strategy,
                engagement_range: 185.0,
                pursuit: 0.90,
                aggression: 1.05,
                objective: 0.80,
                retreat_bias: -0.01,
                bomb_preference: 0.80,
            },
            Strategy::Ambusher => Self {
                strategy,
                engagement_range: 155.0,
                pursuit: 1.20,
                aggression: 1.10,
                objective: 0.65,
                retreat_bias: -0.02,
                bomb_preference: 0.50,
            },
            Strategy::Brawler => Self {
                strategy,
                engagement_range: 105.0,
                pursuit: 1.35,
                aggression: 1.25,
                objective: 0.55,
                retreat_bias: -0.08,
                bomb_preference: 0.35,
            },
            Strategy::Denier => Self {
                strategy,
                engagement_range: 260.0,
                pursuit: 0.45,
                aggression: 0.80,
                objective: 1.15,
                retreat_bias: 0.03,
                bomb_preference: 0.55,
            },
            Strategy::Runner => Self {
                strategy,
                engagement_range: 210.0,
                pursuit: 0.65,
                aggression: 0.65,
                objective: 1.75,
                retreat_bias: 0.08,
                bomb_preference: 0.20,
            },
        }
    }
}

/// Everything needed to resolve one persistent roster individual.
#[derive(Clone, Debug, PartialEq)]
pub struct PilotSpec {
    pub version: u16,
    pub id: PilotId,
    pub callsign: String,
    pub hull: u8,
    pub competence: Competence,
    pub behavior: BehaviorProfile,
    /// Stable seed for content generation. Match randomness has another seed.
    pub configuration_seed: u32,
}

/// What this pilot spends their seven credits on.
///
/// A bot builds its own ship now, and no two build it alike. It used to fly
/// whatever `sim_deal_kit` put on the hull, which was that hull's own profile
/// off the baseline: every Wedge in the fleet carried the same two rungs of
/// shrapnel, and the only thing separating one bombardier from another was
/// how it flew. The kit is the pilot's on this side of the wire as much as on
/// the client's, so it comes out of the same personality the rest of the
/// choices do. See decision 117.
///
/// Two halves. The strategy says what the ship is for, and buys first: a
/// bombardier levels its bomb and fuses it, a duelist levels its gun, a denier
/// buys the rack it pushes people around with. Then the seed spends whatever
/// is left, so two duelists off the same strategy are not the same ship.
///
/// Every count here is an intent rather than a promise. The arena fits a kit
/// to the hull's ceilings and to the purse before it deals one, so a bot that
/// asks for a bomb on a Cipher gets a Cipher, and one that asks for nine
/// credits' worth gets seven.
pub fn kit(spec: &PilotSpec) -> [u8; crate::sim::SLOT_COUNT] {
    use crate::sim::{
        slot_charge, slot_level, slot_mod, CHARGE_BURST, CHARGE_REPEL, MOD_BOUNCE, MOD_FREEZE,
        MOD_MULTI, MOD_PROX, MOD_SHRAPNEL, SLOT_COUNT, TRIG_BOMB, TRIG_GUN,
    };
    let mut kit = [0u8; SLOT_COUNT];
    let b = &spec.behavior;
    let mut left = crate::sim::KIT_CREDITS;
    let buy = |kit: &mut [u8; SLOT_COUNT], slot: u8, n: u8, left: &mut u8| {
        let n = n.min(*left);
        kit[slot as usize] = kit[slot as usize].saturating_add(n);
        *left -= n;
    };

    // What the ship is for. A bomb preference at or over one is a pilot whose
    // whole job is the rack, and under a quarter is one who never opens it.
    if b.bomb_preference >= 0.75 {
        buy(&mut kit, slot_level(TRIG_BOMB), 1, &mut left);
        buy(&mut kit, slot_mod(TRIG_BOMB, MOD_PROX), 1, &mut left);
        buy(&mut kit, slot_mod(TRIG_BOMB, MOD_SHRAPNEL), 1, &mut left);
    } else if b.bomb_preference >= 0.35 {
        buy(&mut kit, slot_level(TRIG_BOMB), 1, &mut left);
        buy(&mut kit, slot_mod(TRIG_BOMB, MOD_PROX), 1, &mut left);
    }
    // A pilot who works close wants more in the air; one who works long wants
    // the round to arrive. `engagement_range` is in world pixels and the
    // roster's profiles run from 175 to 260.
    if b.engagement_range <= 200.0 {
        buy(&mut kit, slot_mod(TRIG_GUN, MOD_MULTI), 1, &mut left);
    }
    buy(&mut kit, slot_level(TRIG_GUN), 1, &mut left);
    // A way out, for anyone who ever leaves a fight. A retreat bias above
    // nothing is a pilot who breaks contact early and wants two.
    let repels = if b.retreat_bias > 0.03 { 2 } else { 1 };
    buy(&mut kit, slot_charge(CHARGE_REPEL), repels, &mut left);

    // And the rest by the pilot's own seed, so a strategy is a shape rather
    // than a stamp. The four here are the ones that change how a ship fights
    // without changing what it is for.
    let mut r = spec.configuration_seed.wrapping_mul(2_654_435_761).max(1);
    let mut roll = || {
        r ^= r << 13;
        r ^= r >> 17;
        r ^= r << 5;
        r
    };
    let taste = [
        slot_mod(TRIG_GUN, MOD_BOUNCE),
        slot_mod(TRIG_GUN, MOD_FREEZE),
        slot_charge(CHARGE_BURST),
        slot_mod(TRIG_BOMB, MOD_BOUNCE),
    ];
    let mut guard = 0;
    while left > 0 && guard < 32 {
        guard += 1;
        let slot = taste[(roll() % taste.len() as u32) as usize];
        buy(&mut kit, slot, 1, &mut left);
    }
    kit
}

impl PilotSpec {
    pub fn brain(&self) -> BrainConfig {
        BrainConfig {
            competence: self.competence,
            behavior: self.behavior,
            configuration_seed: self.configuration_seed,
        }
    }

    /// A stable fallback used only to order the roster before the
    /// certified tournament artifact exists. It is deliberately not called a
    /// rating: competence dominates, with a small profile tie-breaker.
    pub fn ordering_prior(&self) -> f32 {
        let execution = self.competence.aim * 0.55 + self.competence.judgment * 0.45;
        let style = self.behavior.aggression * 0.010
            + self.behavior.pursuit * 0.005
            + self.behavior.bomb_preference * 0.002
            - self.behavior.retreat_bias * 0.010;
        execution + style
    }
}

/// Prespecified weak-to-strong roster order. Calibration tests this order; it
/// never chooses directions after reading a development pool.
pub fn provisional_ladder_order(roster: &[PilotSpec]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..roster.len()).collect();
    order.sort_by(|&left, &right| {
        roster[left]
            .ordering_prior()
            .total_cmp(&roster[right].ordering_prior())
            .then_with(|| {
                roster[left]
                    .behavior
                    .strategy
                    .cmp(&roster[right].behavior.strategy)
            })
            .then_with(|| roster[left].id.0.cmp(&roster[right].id.0))
    });
    order
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BrainConfig {
    pub competence: Competence,
    pub behavior: BehaviorProfile,
    pub configuration_seed: u32,
}

/// Compatibility for focused harnesses that vary one scalar and do not model
/// a roster personality. Live pilots always pass their full `BrainConfig`.
impl From<f32> for BrainConfig {
    fn from(skill: f32) -> Self {
        Self {
            competence: Competence::uniform(skill),
            behavior: BehaviorProfile::for_strategy(Strategy::Duelist),
            configuration_seed: 0,
        }
    }
}

impl From<&PilotSpec> for BrainConfig {
    fn from(spec: &PilotSpec) -> Self {
        spec.brain()
    }
}

pub const CALIBRATED: [(&str, u8, f32); 8] = [
    ("Kestrel", 0, 0.05),
    ("Halcyon", 3, 0.35),
    ("Vantage", 6, 0.65),
    ("Ridgeline", 2, 0.82),
    ("Sable", 5, 0.90),
    ("Ozone", 1, 0.54),
    ("Tessellate", 4, 0.74),
    ("Cirrus", 2, 0.20),
];

pub const FILL_NAMES: [&str; 39] = [
    "Aperture",
    "Bellwether",
    "Carrack",
    "Downdraft",
    "Escarpment",
    "Foxglove",
    "Gantry",
    "Hollow",
    "Isobar",
    "Jackstay",
    "Keelson",
    "Longshore",
    "Mackerel",
    "Nightjar",
    "Oxbow",
    "Palisade",
    "Quicksilver",
    "Ravine",
    "Saltmarsh",
    "Tideline",
    "Undertow",
    "Vellum",
    "Windrow",
    "Xenolith",
    "Yardarm",
    "Zenith",
    "Alluvium",
    "Bracken",
    "Coppice",
    "Dunelight",
    "Estuary",
    "Fernbrake",
    "Glasswort",
    "Headland",
    "Inlet",
    "Junco",
    "Kittiwake",
    "Limestone",
    "Moraine",
];

pub const CLASS_NAMES: [&str; 7] = [
    "Apex", "Wedge", "Chord", "Anvil", "Cipher", "Facet", "Lattice",
];

const NAMED_STRATEGIES: [Strategy; 8] = [
    Strategy::Duelist,
    Strategy::Heavy,
    Strategy::Denier,
    Strategy::Skirmisher,
    Strategy::Brawler,
    Strategy::Bombardier,
    Strategy::Ambusher,
    Strategy::Skirmisher,
];

/// The scalar in `CALIBRATED` remains the midpoint used by older tournament
/// harnesses. Live pilots carry the two traits separately.
const NAMED_COMPETENCE: [Competence; 8] = [
    Competence {
        aim: 0.04,
        judgment: 0.06,
    },
    Competence {
        aim: 0.40,
        judgment: 0.30,
    },
    Competence {
        aim: 0.72,
        judgment: 0.58,
    },
    Competence {
        aim: 0.78,
        judgment: 0.86,
    },
    Competence {
        aim: 0.94,
        judgment: 0.86,
    },
    Competence {
        aim: 0.48,
        judgment: 0.60,
    },
    Competence {
        aim: 0.80,
        judgment: 0.68,
    },
    Competence {
        aim: 0.16,
        judgment: 0.24,
    },
];

fn calibrated(n: usize) -> Option<PilotSpec> {
    let &(callsign, hull, _) = CALIBRATED.get(n)?;
    Some(PilotSpec {
        version: PILOT_SPEC_VERSION,
        id: PilotId(n as u32 + 1),
        callsign: callsign.to_string(),
        hull,
        competence: NAMED_COMPETENCE[n],
        behavior: BehaviorProfile::for_strategy(NAMED_STRATEGIES[n]),
        configuration_seed: 0x6d2b_79f5 ^ (n as u32 + 1).wrapping_mul(0x9e37_79b9),
    })
}

fn generated_strategy(h: u32) -> Strategy {
    match (h >> 23) % 8 {
        0 => Strategy::Duelist,
        1 => Strategy::Bombardier,
        2 => Strategy::Skirmisher,
        3 => Strategy::Heavy,
        4 => Strategy::Ambusher,
        5 => Strategy::Brawler,
        6 => Strategy::Denier,
        _ => Strategy::Runner,
    }
}

fn generated_competence(h: u32) -> Competence {
    let midpoint = 0.05 + (h % 86) as f32 / 100.0;
    let split = ((h >> 9) % 7) as f32 * 0.01 - 0.03;
    Competence {
        aim: (midpoint + split).clamp(0.01, 0.99),
        judgment: (midpoint - split).clamp(0.01, 0.99),
    }
}

/// Resolve one stable roster individual, counting from zero.
pub fn individual(n: usize) -> PilotSpec {
    if let Some(spec) = calibrated(n) {
        return spec;
    }

    let i = n - CALIBRATED.len();
    let word = FILL_NAMES[i % FILL_NAMES.len()];
    let lap = i / FILL_NAMES.len();
    let callsign = if lap == 0 {
        word.to_string()
    } else {
        format!("{word} {}", lap + 1)
    };
    let h = (i as u32).wrapping_mul(2_654_435_761) ^ 0x9e37_79b9;
    PilotSpec {
        version: PILOT_SPEC_VERSION,
        id: PilotId(0x1_0000 + i as u32),
        callsign,
        hull: (h >> 11) as u8 % CLASS_NAMES.len() as u8,
        competence: generated_competence(h),
        behavior: BehaviorProfile::for_strategy(generated_strategy(h)),
        configuration_seed: 0xa511_e9b3 ^ h.rotate_left(11),
    }
}

/// Validate a name the house director may claim without building the full
/// roster on every account request.
pub fn is_house_callsign(name: &str) -> bool {
    if CALIBRATED.iter().any(|(callsign, _, _)| *callsign == name) {
        return true;
    }

    for (word_index, word) in FILL_NAMES.iter().enumerate() {
        if name == *word {
            return CALIBRATED.len() + word_index < HOUSE_PILOT_POOL;
        }
        let Some(suffix) = name
            .strip_prefix(word)
            .and_then(|rest| rest.strip_prefix(' '))
        else {
            continue;
        };
        let Ok(label) = suffix.parse::<usize>() else {
            continue;
        };
        if label < 2 || label.to_string() != suffix {
            continue;
        }
        let generated = (label - 1)
            .checked_mul(FILL_NAMES.len())
            .and_then(|lap| lap.checked_add(word_index));
        if generated.is_some_and(|index| {
            CALIBRATED
                .len()
                .checked_add(index)
                .is_some_and(|pilot| pilot < HOUSE_PILOT_POOL)
        }) {
            return true;
        }
    }
    false
}

pub fn roster() -> Vec<PilotSpec> {
    (0..CALIBRATED.len()).map(individual).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shipped_pilots_keep_their_careers() {
        let expected = [
            ("Kestrel", 0, 0.05),
            ("Halcyon", 3, 0.35),
            ("Vantage", 6, 0.65),
            ("Ridgeline", 2, 0.82),
            ("Sable", 5, 0.90),
            ("Ozone", 1, 0.54),
            ("Tessellate", 4, 0.74),
            ("Cirrus", 2, 0.20),
        ];
        for (n, &(name, hull, skill)) in expected.iter().enumerate() {
            let spec = individual(n);
            assert_eq!(spec.id, PilotId(n as u32 + 1));
            assert_eq!(spec.callsign, name);
            assert_eq!(spec.hull, hull);
            let midpoint = (spec.competence.aim + spec.competence.judgment) / 2.0;
            assert!((midpoint - skill).abs() < 0.000_001);
        }
    }

    #[test]
    fn live_pilots_have_independent_competence_traits() {
        assert!(
            roster()
                .iter()
                .any(|spec| spec.competence.aim != spec.competence.judgment),
            "the roster must exercise both competence axes"
        );
        let generated = individual(CALIBRATED.len() + 17);
        assert_ne!(generated.competence.aim, generated.competence.judgment);
    }

    #[test]
    fn generated_specs_are_versioned_and_repeatable() {
        let n = CALIBRATED.len() + 53;
        let first = individual(n);
        let second = individual(n);
        assert_eq!(first, second);
        assert_eq!(first.version, PILOT_SPEC_VERSION);
        assert_ne!(first.id, individual(n + 1).id);
        assert_ne!(
            first.configuration_seed,
            individual(n + 1).configuration_seed
        );
    }

    #[test]
    fn house_callsign_validation_covers_both_pools_and_their_edges() {
        assert!(is_house_callsign("Ozone"));
        assert!(is_house_callsign(
            &individual(HOUSE_PILOT_POOL - 1).callsign
        ));
        assert!(!is_house_callsign(&individual(HOUSE_PILOT_POOL).callsign));
        assert!(!is_house_callsign("Definitely Not A House Pilot"));
    }

    /// Every pilot spends what it has, and inside what the purse holds. The
    /// arena fits a kit anyway, so an overspend is not a crash; it is a bot
    /// that asked for a ship it cannot have and got a smaller one.
    #[test]
    fn a_bots_kit_fits_the_purse() {
        for n in 0..256usize {
            let spec = individual(n);
            let kit = kit(&spec);
            let spent: u32 = kit.iter().map(|&c| u32::from(c)).sum();
            assert!(
                spent == u32::from(crate::sim::KIT_CREDITS),
                "{} spent {spent} of {}",
                spec.callsign,
                crate::sim::KIT_CREDITS
            );
        }
    }

    /// And no two build the same ship. A fleet of identical bombardiers is
    /// the thing this exists to stop: the strategy is a shape and the seed is
    /// the pilot, so one strategy has to produce more than one kit.
    #[test]
    fn bots_do_not_all_build_the_same_ship() {
        use std::collections::HashSet;
        let mut all: HashSet<[u8; crate::sim::SLOT_COUNT]> = HashSet::new();
        let mut bombardiers: HashSet<[u8; crate::sim::SLOT_COUNT]> = HashSet::new();
        for n in 0..256usize {
            let spec = individual(n);
            let k = kit(&spec);
            all.insert(k);
            if spec.behavior.strategy == Strategy::Bombardier {
                bombardiers.insert(k);
            }
        }
        assert!(all.len() > 8, "the fleet built {} ships", all.len());
        assert!(
            bombardiers.len() > 1,
            "every bombardier built the same ship"
        );
    }

    /// The strategy is still the shape, though: a pilot whose whole job is
    /// the rack buys the rack, and one who never opens it does not.
    #[test]
    fn a_kit_answers_the_strategy_that_bought_it() {
        use crate::sim::{slot_level, slot_mod, MOD_PROX, TRIG_BOMB};
        let mut bomber = individual(0);
        bomber.behavior = BehaviorProfile::for_strategy(Strategy::Bombardier);
        let mut duelist = individual(0);
        duelist.behavior = BehaviorProfile::for_strategy(Strategy::Duelist);
        let b = kit(&bomber);
        let d = kit(&duelist);
        assert!(
            b[slot_level(TRIG_BOMB) as usize] > 0 && b[slot_mod(TRIG_BOMB, MOD_PROX) as usize] > 0,
            "a bombardier levels and fuses its bomb"
        );
        assert_eq!(
            d[slot_mod(TRIG_BOMB, MOD_PROX) as usize],
            0,
            "a duelist does not buy a fuse it will not use"
        );
    }

    #[test]
    fn strategy_profiles_are_not_hull_aliases() {
        let duel = BehaviorProfile::for_strategy(Strategy::Duelist);
        let skim = BehaviorProfile::for_strategy(Strategy::Skirmisher);
        let deny = BehaviorProfile::for_strategy(Strategy::Denier);
        let run = BehaviorProfile::for_strategy(Strategy::Runner);
        assert!(skim.engagement_range > duel.engagement_range);
        assert!(deny.engagement_range > skim.engagement_range);
        assert!(duel.pursuit > deny.pursuit);
        assert!(run.objective > skim.objective);
        assert!(duel.aggression > run.aggression);
    }
}
