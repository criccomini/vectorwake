//! What a bot buys with what it has killed for, and what it flies once it has.
//!
//! Bots walk the same three endpoints a player's client walks: `/v1/upgrades`
//! for the shelf, `/v1/buy` for a rung, and `C2S_KIT` to the arena to say what
//! they are flying. Nothing here is privileged, and nothing here knows a price:
//! the meta-layer sets those and refuses what an account cannot afford, exactly
//! as it does for a person. See docs/design/ai-players.md.
//!
//! What is here is taste, and taste is read off the pilot's own behavior
//! rather than named beside it. A `BehaviorProfile` already says where this
//! pilot wants to fight, how hard it chases, whether it stands or leaves, and
//! how much it likes a bomb. Those are the same questions a kit answers, so a
//! kit is derived from them.
//!
//! It used to be a separate three-valued plan: gunner, bomber or runner. Two
//! things were wrong with that. A generated pilot drew its plan from different
//! bits of the same hash that drew its strategy, so the two were uncorrelated
//! and only a third of the pilots whose brains open the bombing gates owned a
//! bomb at all. And three plans over eight strategies meant the game held
//! three kits, so "Ozone throws shrapnel" could not be a fact worth learning
//! when Ozone's purchases had nothing to do with Ozone.

use crate::{pilots::BehaviorProfile, sim};

/// Where a want has to reach before it is worth a point at all.
///
/// Below this the slot is left off the list rather than given a token rung,
/// which is what lets a pilot who does not bomb own no bomb instead of one
/// rung of a weapon it will never throw.
const MIN_WANT: f32 = 0.18;

/// How many times the list is laid down, each round keeping only the wants
/// that clear a rising share of the strongest one.
///
/// This is how weight becomes repeats. `build` walks the list in passes and
/// spends a point per appearance, so a want at the top appears in every round
/// and takes a point every pass, while one just over the floor appears once.
/// Laid down in rounds rather than as runs of one slot so the budget spreads
/// across a pilot's whole taste instead of filling its favorite slot first.
const ROUNDS: usize = 4;

/// Read one profile field as a share of the span the shipped strategies use.
/// Clamped, so a strategy authored outside that span still lands somewhere
/// sensible rather than running the weights off their scale.
fn span(v: f32, lo: f32, hi: f32) -> f32 {
    ((v - lo) / (hi - lo)).clamp(0.0, 1.0)
}

/// A pilot's taste, as an order over slots with repeats for weight.
///
/// Read twice. `next_buy` walks it to pick the next rung to pay for, and
/// `build` walks it in passes to spend a kit's thirty points, so what a bot
/// saves up for is what it flies.
pub fn wants(profile: &BehaviorProfile) -> Vec<usize> {
    // The profile, as shares. Every weight below is written in these, so the
    // behavior numbers stay the one place a pilot is described.
    let close = 1.0 - span(profile.engagement_range, 105.0, 260.0);
    let bombing = profile.bomb_preference.clamp(0.0, 1.0);
    let gunning = 1.0 - bombing;
    // A bomb is a commitment rather than a leaning, so this asks for a real
    // preference before it buys any of the ladder. Below it a pilot carries
    // the rung its trigger already fires and spends the points on the gun.
    let bombs = (bombing - 0.30).max(0.0);
    let stands = span(-profile.retreat_bias, 0.0, 0.08);
    let leaves = span(profile.retreat_bias, 0.0, 0.08);
    let chases = span(profile.pursuit, 0.45, 1.35);
    let pushes = span(profile.aggression, 0.65, 1.25);
    let errands = span(profile.objective, 0.55, 1.75);

    let gun = sim::slot_level(sim::TRIG_GUN) as usize;
    let bomb = sim::slot_level(sim::TRIG_BOMB) as usize;
    let m = |t: usize, k: usize| sim::slot_mod(t, k) as usize;
    let s = |u: usize| sim::slot_stat(u) as usize;
    let c = |k: usize| sim::slot_charge(k) as usize;

    let mut scored: Vec<(usize, f32)> = vec![
        // The weapons. A pilot's own trigger first, then what shapes it.
        (gun, 0.55 + gunning * 0.70 + pushes * 0.25),
        (bomb, bombs * 2.20),
        // Spray covers a dodge, which is worth most where a dodge is short.
        (
            m(sim::TRIG_GUN, sim::MOD_MULTI),
            gunning * (0.45 + close * 0.55),
        ),
        // A wall to shoot round is worth most to somebody holding one.
        (
            m(sim::TRIG_GUN, sim::MOD_BOUNCE),
            gunning * (0.20 + (1.0 - close) * 0.30),
        ),
        // Stalling a bar is a finisher's add-on.
        (m(sim::TRIG_GUN, sim::MOD_FREEZE), gunning * pushes * 0.35),
        (m(sim::TRIG_BOMB, sim::MOD_PROX), bombs * 1.50),
        (m(sim::TRIG_BOMB, sim::MOD_SHRAPNEL), bombs * 1.20),
        (m(sim::TRIG_BOMB, sim::MOD_BOUNCE), bombs * 0.70),
        (m(sim::TRIG_BOMB, sim::MOD_FREEZE), bombs * 0.50),
        // Energy is what a hull has instead of health, so everybody buys some
        // and the pilots who take hits buy most: the ones who fight up close
        // and the ones who do not leave.
        (s(sim::UP_ENERGY), 0.45 + close * 0.55 + stands * 0.50),
        // Recharge is the same bar bought by the minute rather than the
        // exchange, which is what a pilot trading at range is doing.
        (s(sim::UP_RECHARGE), 0.35 + (1.0 - close) * 0.45),
        (
            s(sim::UP_SPEED),
            0.20 + chases * 0.45 + leaves * 0.45 + errands * 0.45,
        ),
        (s(sim::UP_THRUST), 0.20 + chases * 0.40 + close * 0.35),
        (s(sim::UP_ROTATION), 0.15 + close * 0.45),
        // The repel answers a bomb, and a bomb finds everybody.
        (c(sim::CHARGE_REPEL), 0.50),
        (c(sim::CHARGE_BURST), 0.20 + close * 0.30),
    ];

    scored.retain(|(_, w)| *w >= MIN_WANT);
    // Strongest first, and by slot where two tie, so a list is the same list
    // on every host that builds it.
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let top = scored.first().map_or(1.0, |(_, w)| *w);

    let mut list = Vec::new();
    for round in 0..ROUNDS {
        let bar = round as f32 / ROUNDS as f32;
        list.extend(
            scored
                .iter()
                .filter(|(_, w)| *w / top > bar)
                .map(|(slot, _)| *slot),
        );
    }
    list
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
/// A pass at a time rather than filling each slot to its top in turn: filling
/// one stat before anything else is a ship nobody would build,
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
            // A taste can saturate before the budget does when its preferred
            // rungs are shallower than thirty points. Flow the remainder
            // across the live ceiling rather than flying points short. This
            // is still the last choice: every weighted preference above has
            // already reached its top.
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
    use crate::pilots::Strategy;

    /// What an account that has bought everything flies under, which is the
    /// game's own row: the tests below are about taste, not entitlements.
    fn full_ceiling() -> [u8; sim::SLOT_COUNT] {
        *sim::World::baseline_kit_ceiling()
    }

    /// Every strategy the game ships, so a test over all of them stays over
    /// all of them when a ninth is written.
    const STRATEGIES: [Strategy; 8] = [
        Strategy::Duelist,
        Strategy::Bombardier,
        Strategy::Skirmisher,
        Strategy::Heavy,
        Strategy::Ambusher,
        Strategy::Brawler,
        Strategy::Denier,
        Strategy::Runner,
    ];

    fn taste(strategy: Strategy) -> Vec<usize> {
        wants(&BehaviorProfile::for_strategy(strategy))
    }

    /// A taste is the same taste on every host that derives it, and no two
    /// personalities want the same things in the same order.
    #[test]
    fn taste_is_personal_and_stable() {
        assert_eq!(
            taste(Strategy::Brawler),
            taste(Strategy::Brawler),
            "a taste is stable"
        );
        let mut seen: Vec<(Strategy, Vec<usize>)> = Vec::new();
        for strategy in STRATEGIES {
            let list = taste(strategy);
            assert!(!list.is_empty(), "{strategy:?} wants nothing");
            if let Some((other, _)) = seen.iter().find(|(_, l)| *l == list) {
                panic!("{strategy:?} and {other:?} shop from one list");
            }
            seen.push((strategy, list));
        }
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
        for strategy in STRATEGIES {
            let list = taste(strategy);
            let kit = build(&list, &ceiling);
            let spent: u32 = kit.iter().map(|n| *n as u32).sum();
            assert_eq!(spent, sim::KIT_BUDGET, "{strategy:?} left points unspent");
            for slot in 0..sim::SLOT_COUNT {
                assert!(
                    kit[slot] <= ceiling[slot],
                    "{strategy:?} overran slot {slot}"
                );
            }
            assert!(
                kit[list[0]] > 0,
                "{strategy:?} did not buy what it wanted most"
            );
        }
    }

    /// Energy is what a hull carries instead of health, so a personality that
    /// buys none is a personality made of paper.
    ///
    /// The old runner plan bought exactly zero, against the gunner's seven,
    /// and it lost at every skill level in every room the probe measured.
    #[test]
    fn every_personality_buys_a_bar_to_fight_from() {
        let ceiling = full_ceiling();
        let energy = sim::slot_stat(sim::UP_ENERGY) as usize;
        for strategy in STRATEGIES {
            let kit = build(&taste(strategy), &ceiling);
            assert!(
                kit[energy] >= 3,
                "{strategy:?} flies on {} points of energy",
                kit[energy]
            );
        }
    }

    /// What a personality asks for has to follow from what it is. A pilot who
    /// wants the bomb buys more of that ladder than one who does not, and one
    /// who fights up close buys more of a bar than one standing off.
    #[test]
    fn a_kit_follows_the_personality_it_came_from() {
        let ceiling = full_ceiling();
        let bomb = sim::slot_level(sim::TRIG_BOMB) as usize;
        let energy = sim::slot_stat(sim::UP_ENERGY) as usize;
        let speed = sim::slot_stat(sim::UP_SPEED) as usize;

        let bombardier = build(&taste(Strategy::Bombardier), &ceiling);
        let duelist = build(&taste(Strategy::Duelist), &ceiling);
        assert!(
            bombardier[bomb] > duelist[bomb],
            "a bombardier and a duelist buy the same bomb"
        );
        assert_eq!(duelist[bomb], 0, "a duelist buys a bomb it never throws");

        let brawler = build(&taste(Strategy::Brawler), &ceiling);
        let denier = build(&taste(Strategy::Denier), &ceiling);
        assert!(
            brawler[energy] > denier[energy],
            "a brawler in the blender buys no more bar than a pilot standing off"
        );

        let runner = build(&taste(Strategy::Runner), &ceiling);
        assert!(
            runner[speed] > brawler[speed],
            "a runner buys no more speed than a brawler"
        );
    }

    /// The ceiling is the account's as well as the arena's, so a pilot that
    /// owns nothing flies the same shape a fresh player does rather than
    /// nothing at all.
    #[test]
    fn a_build_inside_a_bare_account_still_flies() {
        let base = sim::World::base_entitlements();
        for strategy in STRATEGIES {
            let kit = build(&taste(strategy), &base);
            let spent: u32 = kit.iter().map(|n| *n as u32).sum();
            assert!(spent > 0, "{strategy:?} on a bare account flies nothing");
            assert!(spent <= sim::KIT_BUDGET, "{strategy:?} ran past the budget");
            for slot in 0..sim::SLOT_COUNT {
                assert!(
                    kit[slot] <= base[slot],
                    "{strategy:?} wears slot {slot} unowned"
                );
            }
        }
    }
}
