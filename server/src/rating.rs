//! Skill rating.
//!
//! Implements docs/design/rating.md. A death becomes a set of pairwise
//! contests between the victim and everyone who damaged them, weighted by
//! damage share, with credit decaying at the victim's recharge rate so that
//! damage already healed away stops counting.
//!
//! Rating is not a game rule: the simulation does not know it exists. This
//! layer consumes the events a tick produced and nothing more.

use std::collections::{HashMap, HashSet};

/// Rated deaths before a rating is worth showing. Below this a pilot is
/// placing, and the client displays that rather than a number nobody should
/// yet believe.
pub const PROVISIONAL_GAMES: u32 = 10;

/// K starts high so a new pilot finds their level in an evening, and settles
/// low so a settled one stops bouncing. Bots move slowly by comparison: a
/// human should move against a bot far more than the bot moves against them.
const K_NEW: f64 = 64.0;
const K_SETTLED: f64 = 16.0;
const K_CONVERGE: f64 = 50.0;
const K_BOT: f64 = 8.0;

/// No single death moves a rating more than this, which bounds the damage a
/// bug in the attribution ledger can do.
const EVENT_CAP: f64 = 64.0;

/// Visible tiers. A rating is a number the matchmaker reads; a tier is what a
/// player is told, and coarse bands mean a pilot is not watching a number
/// twitch after every death.
pub const TIERS: [(&str, f64); 6] = [
    ("Drift", f64::NEG_INFINITY),
    ("Trace", 1050.0),
    ("Vector", 1200.0),
    ("Contrail", 1350.0),
    ("Shockwave", 1500.0),
    ("Wake", 1700.0),
];

/// The band a rating falls in. Always answers: the lowest tier is unbounded
/// below, so there is no rating without a name.
pub fn tier(rating: f64) -> &'static str {
    let mut name = TIERS[0].0;
    for (n, floor) in TIERS {
        if rating >= floor {
            name = n;
        }
    }
    name
}

/// Who a rating belongs to. Ratings follow the pilot, never the seat: a
/// player taking a bot's slot must not inherit that bot's record, and a bot
/// filling a vacated slot must not inherit the player's.
pub type Id = String;

/// One entry of the permanent record. Ratings are a projection of this log,
/// which is what lets the model be replaced by recomputing history.
#[derive(Clone, Debug)]
pub struct RatedEvent {
    pub tick: u32,
    pub victim: Id,
    pub victim_before: f64,
    pub victim_after: f64,
    /// Attacker, damage share, rating before, rating after.
    pub credits: Vec<(Id, f64, f64, f64)>,
}

struct Ledger {
    /// attacker -> decaying credit
    credit: HashMap<Id, f64>,
    last_tick: u32,
}

pub struct Rating {
    pub score: HashMap<Id, f64>,
    /// Kills counted per pair, for the repeat-dampening rule.
    repeats: HashMap<(Id, Id), (u32, u32)>,
    ledgers: HashMap<Id, Ledger>,
    pub log: Vec<RatedEvent>,
    /// Half-life of damage credit, in ticks. Tied to how fast a hull refills.
    pub half_life: f64,
    /// Rated deaths per pilot, which sets how fast their rating still moves.
    pub games: HashMap<Id, u32>,
    /// Pilots whose rating never moves. Bots would otherwise form a closed
    /// economy whose absolute scale drifts, which would quietly make every
    /// rating in the zone meaningless. Everything else floats against these.
    anchors: HashSet<Id>,
    /// Pilots that move slowly, which is to say the AI.
    bots: HashSet<Id>,
}

impl Rating {
    pub fn new() -> Self {
        Rating {
            score: HashMap::new(),
            repeats: HashMap::new(),
            ledgers: HashMap::new(),
            log: Vec::new(),
            half_life: 400.0, // 4 s, clamped range from the design doc
            games: HashMap::new(),
            anchors: HashSet::new(),
            bots: HashSet::new(),
        }
    }

    pub fn rating_of(&self, who: &str) -> f64 {
        *self.score.get(who).unwrap_or(&1200.0)
    }

    pub fn games_of(&self, who: &str) -> u32 {
        *self.games.get(who).unwrap_or(&0)
    }

    /// Pin a pilot's rating. The anchor is the fixed point the whole ladder is
    /// measured against, so it is set once and never earned.
    pub fn set_anchor(&mut self, who: &str, at: f64) {
        self.anchors.insert(who.to_string());
        self.score.insert(who.to_string(), at);
    }

    pub fn mark_bot(&mut self, who: &str) {
        self.bots.insert(who.to_string());
    }

    pub fn is_bot(&self, who: &str) -> bool {
        self.bots.contains(who)
    }

    /// How far one death may move this pilot. A bot barely moves; a human
    /// moves fast while placing and slows as their rating earns confidence.
    fn k_for(&self, who: &str) -> f64 {
        if self.bots.contains(who) {
            return K_BOT;
        }
        let n = self.games_of(who) as f64;
        let settled = (n / K_CONVERGE).min(1.0);
        K_NEW + (K_SETTLED - K_NEW) * settled
    }

    /// The tier to show, or None while the pilot is still placing.
    pub fn tier_of(&self, who: &str) -> Option<&'static str> {
        if self.games_of(who) < PROVISIONAL_GAMES {
            return None;
        }
        Some(tier(self.rating_of(who)))
    }

    pub fn damage(&mut self, tick: u32, victim: &str, attacker: &str, amount: i32, same_team: bool) {
        // Self damage and teammate damage never earn credit.
        if attacker == victim || same_team || amount <= 0 {
            return;
        }
        let hl = self.half_life;
        let l = self.ledgers.entry(victim.to_string()).or_insert_with(|| Ledger {
            credit: HashMap::new(),
            last_tick: tick,
        });
        // Decay everything to now, then add.
        let dt = (tick.saturating_sub(l.last_tick)) as f64;
        if dt > 0.0 {
            let factor = 0.5f64.powf(dt / hl);
            for v in l.credit.values_mut() {
                *v *= factor;
            }
            l.last_tick = tick;
        }
        *l.credit.entry(attacker.to_string()).or_insert(0.0) += amount as f64;
    }

    /// Resolve a death. Returns the event if anybody earned credit for it;
    /// an environmental death rates nothing.
    pub fn death(&mut self, tick: u32, victim: &str) -> Option<RatedEvent> {
        let l = self.ledgers.remove(victim)?;
        let total: f64 = l.credit.values().sum();
        if total <= 0.0 {
            return None;
        }

        let victim_before = self.rating_of(victim);
        let kv = self.k_for(victim);
        let mut victim_delta = 0.0;
        let mut credits = Vec::new();

        for (attacker, &c) in l.credit.iter() {
            let w = c / total;
            if w <= 0.0 {
                continue;
            }
            let ra = self.rating_of(attacker);
            let expected = 1.0 / (1.0 + 10f64.powf((victim_before - ra) / 400.0));

            // Repeat dampening: killing the same opponent again soon is worth
            // progressively less, which is what stops spawn camping and
            // kill trading from inflating anybody.
            let entry = self
                .repeats
                .entry((attacker.clone(), victim.to_string()))
                .or_insert((0, tick));
            if tick.saturating_sub(entry.1) > 30_000 {
                *entry = (0, tick);
            }
            let damp = 1.0 / (1.0 + entry.0 as f64);
            entry.0 += 1;
            entry.1 = tick;

            // K differs per side, so the exchange is not strictly zero-sum:
            // a placing human moves further than the settled bot that killed
            // them. That asymmetry is the point, and the anchor absorbs it.
            let base = w * (1.0 - expected) * damp;
            let ka = self.k_for(attacker);
            let delta = (ka * base).clamp(-EVENT_CAP, EVENT_CAP);
            let after = if self.anchors.contains(attacker) {
                ra
            } else {
                let v = ra + delta;
                self.score.insert(attacker.clone(), v);
                v
            };
            *self.games.entry(attacker.clone()).or_insert(0) += 1;
            victim_delta -= (kv * base).clamp(-EVENT_CAP, EVENT_CAP);
            credits.push((attacker.clone(), w, ra, after));
        }

        let victim_after = if self.anchors.contains(victim) {
            victim_before
        } else {
            let v = victim_before + victim_delta;
            self.score.insert(victim.to_string(), v);
            v
        };
        *self.games.entry(victim.to_string()).or_insert(0) += 1;

        let ev = RatedEvent {
            tick,
            victim: victim.to_string(),
            victim_before,
            victim_after,
            credits,
        };
        self.log.push(ev.clone());
        Some(ev)
    }

    /// A pilot leaving clears their pending ledger.
    pub fn forget(&mut self, who: &str) {
        self.ledgers.remove(who);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solo_kill_is_ordinary_elo() {
        let mut r = Rating::new();
        r.damage(100, "victim", "killer", 1000, false);
        let ev = r.death(101, "victim").expect("rated");
        assert_eq!(ev.credits.len(), 1);
        assert!((ev.credits[0].1 - 1.0).abs() < 1e-9, "sole contributor holds all credit");
        assert!(r.rating_of("killer") > 1200.0, "killer gains");
        assert!(r.rating_of("victim") < 1200.0, "victim loses");
    }

    #[test]
    fn credit_splits_by_damage() {
        let mut r = Rating::new();
        r.damage(100, "v", "heavy", 750, false);
        r.damage(100, "v", "light", 250, false);
        let ev = r.death(100, "v").expect("rated");
        let mut w: Vec<(String, f64)> = ev.credits.iter().map(|c| (c.0.clone(), c.1)).collect();
        w.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
        assert!((w[0].1 - 0.75).abs() < 1e-6, "three quarters to the heavy hitter");
        assert!((w[1].1 - 0.25).abs() < 1e-6);
        assert!(r.rating_of("heavy") > r.rating_of("light"), "more damage, more rating");
    }

    #[test]
    fn healed_damage_stops_counting() {
        let mut r = Rating::new();
        r.damage(0, "v", "old", 1000, false);       // long ago
        r.damage(2000, "v", "recent", 1000, false); // five half-lives later
        let ev = r.death(2000, "v").expect("rated");
        let recent = ev.credits.iter().find(|c| c.0 == "recent").unwrap().1;
        assert!(recent > 0.9, "recent damage dominates, got {recent}");
    }

    #[test]
    fn teammate_and_self_damage_earn_nothing() {
        let mut r = Rating::new();
        r.damage(10, "v", "v", 500, false);        // self
        r.damage(10, "v", "mate", 500, true);      // teammate
        assert!(r.death(11, "v").is_none(), "an unassisted death rates nothing");
    }

    #[test]
    fn repeat_kills_pay_less() {
        let mut r = Rating::new();
        r.damage(10, "v", "k", 1000, false);
        r.death(11, "v").unwrap();
        let first = r.rating_of("k") - 1200.0;
        r.damage(20, "v", "k", 1000, false);
        r.death(21, "v").unwrap();
        let second = r.rating_of("k") - 1200.0 - first;
        assert!(second < first, "the second kill on the same victim pays less");
    }

    #[test]
    fn a_seat_change_does_not_transfer_a_record() {
        // A player taking a bot's ship must start from their own rating, not
        // the bot's, which is the whole reason ratings are keyed by pilot.
        let mut r = Rating::new();
        r.score.insert("Kestrel".into(), 1400.0);
        assert_eq!(r.rating_of("newcomer"), 1200.0);
    }

    #[test]
    fn an_anchor_never_moves() {
        // The whole ladder is measured against this pilot, so it has to sit
        // still whether it wins or loses.
        let mut r = Rating::new();
        r.set_anchor("reference", 1200.0);
        r.damage(10, "challenger", "reference", 1000, false);
        r.death(11, "challenger").unwrap();
        assert_eq!(r.rating_of("reference"), 1200.0, "anchor holds after a win");
        r.damage(20, "reference", "challenger", 1000, false);
        r.death(21, "reference").unwrap();
        assert_eq!(r.rating_of("reference"), 1200.0, "anchor holds after a loss");
        assert!(r.rating_of("challenger") != 1200.0, "the challenger still moves");
    }

    #[test]
    fn a_human_moves_further_than_the_bot_that_killed_them() {
        let mut r = Rating::new();
        r.mark_bot("bot");
        r.damage(10, "human", "bot", 1000, false);
        r.death(11, "human").unwrap();
        let human_moved = (r.rating_of("human") - 1200.0).abs();
        let bot_moved = (r.rating_of("bot") - 1200.0).abs();
        assert!(human_moved > bot_moved * 4.0,
                "human moved {human_moved}, bot moved {bot_moved}");
    }

    #[test]
    fn a_settled_pilot_moves_less_than_a_placing_one() {
        let mut r = Rating::new();
        r.damage(10, "rookie", "k", 1000, false);
        r.death(11, "rookie").unwrap();
        let first = 1200.0 - r.rating_of("rookie");

        // Same pilot, same loss, after enough games to have earned confidence.
        let mut r2 = Rating::new();
        r2.games.insert("veteran".into(), 100);
        r2.damage(10, "veteran", "k", 1000, false);
        r2.death(11, "veteran").unwrap();
        let later = 1200.0 - r2.rating_of("veteran");
        assert!(later < first, "placing loss {first}, settled loss {later}");
    }

    #[test]
    fn a_rating_is_not_shown_until_it_is_earned() {
        let mut r = Rating::new();
        assert_eq!(r.tier_of("newcomer"), None, "a new pilot is placing");
        r.games.insert("newcomer".into(), PROVISIONAL_GAMES);
        assert_eq!(r.tier_of("newcomer"), Some("Vector"), "1200 sits in Vector");
    }

    #[test]
    fn every_rating_has_a_tier() {
        assert_eq!(tier(-999.0), "Drift", "the floor is unbounded below");
        assert_eq!(tier(1049.0), "Drift");
        assert_eq!(tier(1050.0), "Trace");
        assert_eq!(tier(1200.0), "Vector");
        assert_eq!(tier(99999.0), "Wake", "the ceiling is unbounded above");
    }

    #[test]
    fn beating_a_weaker_opponent_pays_almost_nothing() {
        let mut r = Rating::new();
        r.score.insert("fav".into(), 1900.0);
        r.score.insert("dog".into(), 1100.0);
        r.damage(10, "dog", "fav", 1000, false);
        r.death(11, "dog").unwrap();
        assert!(r.rating_of("fav") - 1900.0 < 1.0, "the favourite gains almost nothing");
    }
}
