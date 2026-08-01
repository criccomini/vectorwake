//! Skill rating.
//!
//! Implements docs/design/rating.md. A death becomes a set of pairwise
//! contests between the victim and everyone who damaged them, weighted by
//! damage share, with credit decaying at the victim's recharge rate so that
//! damage already healed away stops counting.
//!
//! Rating is not a game rule: the simulation does not know it exists. This
//! layer consumes the events a tick produced and nothing more.

use std::collections::HashMap;

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
    pub k: f64,
}

impl Rating {
    pub fn new() -> Self {
        Rating {
            score: HashMap::new(),
            repeats: HashMap::new(),
            ledgers: HashMap::new(),
            log: Vec::new(),
            half_life: 400.0, // 4 s, clamped range from the design doc
            k: 24.0,
        }
    }

    pub fn rating_of(&self, who: &str) -> f64 {
        *self.score.get(who).unwrap_or(&1200.0)
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

            let delta = (self.k * w * (1.0 - expected) * damp).clamp(-64.0, 64.0);
            let after = ra + delta;
            self.score.insert(attacker.clone(), after);
            victim_delta -= delta;
            credits.push((attacker.clone(), w, ra, after));
        }

        let victim_after = victim_before + victim_delta;
        self.score.insert(victim.to_string(), victim_after);

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
    fn beating_a_weaker_opponent_pays_almost_nothing() {
        let mut r = Rating::new();
        r.score.insert("fav".into(), 1900.0);
        r.score.insert("dog".into(), 1100.0);
        r.damage(10, "dog", "fav", 1000, false);
        r.death(11, "dog").unwrap();
        assert!(r.rating_of("fav") - 1900.0 < 1.0, "the favourite gains almost nothing");
    }
}
