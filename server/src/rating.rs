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

/// Where a pilot nobody has measured sits. The middle of the scale, which is
/// also where the anchor is pinned, so an unrated pilot's first opponent is
/// the reference personality and their first few deaths move them fast enough
/// to find their real level in an evening. See `K_NEW`.
pub const UNRATED: f64 = 1200.0;

/// K starts high so a new pilot finds their level in an evening, and settles
/// low so a settled one stops bouncing. Bots move slowly by comparison: a
/// human should move against a bot far more than the bot moves against them.
const K_NEW: f64 = 64.0;
const K_SETTLED: f64 = 16.0;
const K_CONVERGE: f64 = 50.0;
const K_BOT: f64 = 8.0;

/// No single death moves a rating more than this, which bounds the damage a
/// bug in the attribution ledger can do.
pub(crate) const EVENT_CAP: f64 = 64.0;

/// The farm brake. Beating the AI is meant to place a pilot on the ladder,
/// not to be a way up it, and Elo's own geometry only handles part of that:
/// a bot rated far below you pays nearly nothing, but an arena full of bots
/// pays nearly nothing many times an hour.
///
/// So past the point where the AI is still measuring anybody, a pilot may take
/// only so much from it in a day. The floor is the Ace band, which is where a
/// pilot has clearly outrun a population anchored at `ai::ANCHOR_RATING`, and
/// `the_farm_brake_starts_where_ace_does` holds the two together. Below it
/// nothing is capped, because that is the bots doing the job they exist for.
///
/// Losses are not capped. A pilot who keeps dying to the AI above this line is
/// being told something true.
const AI_FARM_FLOOR: f64 = 1350.0;
const AI_GAIN_PER_DAY: f64 = 50.0;
const DAY_TICKS: u32 = 8_640_000;

/// How long a pilot stays answerable for damage after taking it, in ticks.
/// A disconnect inside this window, with the tank low, settles as a death;
/// outside it the ledger is dropped the way a leave always dropped it. Three
/// seconds: a dogfight here is decided in less, and three seconds unhit is a
/// disengagement, not a pause between volleys.
pub const QUIT_WINDOW: u32 = 300;

/// Visible tiers. A rating is a number the matchmaker reads; a tier is what a
/// player is told, and coarse bands mean a pilot is not watching a number
/// twitch after every death.
///
/// The ladder names the pilot rather than the mark they leave, so it reads in
/// order without a legend: everybody knows an Ace outranks a wingman. These
/// words are held apart from the call sign pool in `meta.rs`, since a pilot
/// called Ace 412 sitting in the Ace tier is two different things wearing one
/// word. `call_words_collide_with_nothing` is what keeps them apart.
///
/// Five bands rather than more. Ace is the widest on purpose: it holds the
/// long stretch between a pilot who has clearly arrived and the handful who
/// are the reason anybody knows the zone's name.
pub const TIERS: [(&str, f64); 5] = [
    ("Newb", f64::NEG_INFINITY),
    ("Wing", 1050.0),
    ("Lead", 1200.0),
    ("Ace", 1350.0),
    ("Legend", 1700.0),
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

/// One rated death. Human-involving entries become permanent records at the
/// meta-layer; bot-only entries move the live projections and leave receipts.
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
    /// What each pilot has taken from the AI in the current day, and when that
    /// day started. Kept per room, which is the scope that can hold it: the
    /// arena is where a delta is decided, and deciding it anywhere else would
    /// leave the log saying one thing and the ladder another.
    ai_gain: HashMap<Id, (f64, u32)>,
    /// Whether this room rates the match rather than the death. A flag game
    /// is won by holding ground, and a death in it is a fact about the
    /// fight and not about the game, so the ledger stays empty and the only
    /// exchange is the one `matched` runs at the whistle. See decision 157.
    by_match: bool,
}

/// One pilot's part in a rated match: which side they were on and what the
/// result did to them.
#[derive(Clone, Debug, PartialEq)]
pub struct Standing {
    pub who: Id,
    pub team: u8,
    pub before: f64,
    pub after: f64,
}

/// One rated match. Filed once per whistle in a zone that rates by match,
/// and every seat that played to the end is on it.
#[derive(Clone, Debug, PartialEq)]
pub struct RatedMatch {
    pub tick: u32,
    /// The final score, per public side, as the mode reported it.
    pub score: Vec<u16>,
    pub standings: Vec<Standing>,
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
            ai_gain: HashMap::new(),
            by_match: false,
        }
    }

    /// Rate the match and not the death. Set once, when the room learns its
    /// mode, and never unset: a room changes mode only by being rebuilt.
    pub fn rate_by_match(&mut self) {
        self.by_match = true;
    }

    pub fn rates_by_match(&self) -> bool {
        self.by_match
    }

    pub fn rating_of(&self, who: &str) -> f64 {
        *self.score.get(who).unwrap_or(&UNRATED)
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
    #[cfg(test)]
    pub fn tier_of(&self, who: &str) -> Option<&'static str> {
        if self.games_of(who) < PROVISIONAL_GAMES {
            return None;
        }
        Some(tier(self.rating_of(who)))
    }

    pub fn damage(
        &mut self,
        tick: u32,
        victim: &str,
        attacker: &str,
        amount: i32,
        same_team: bool,
    ) {
        // Self damage and teammate damage never earn credit, and in a zone
        // rated by match no damage does: with nothing in the ledger, `death`
        // and `quit` find nothing to settle, which is the whole of how a
        // flag game keeps its deaths off the ladder.
        if self.by_match || attacker == victim || same_team || amount <= 0 {
            return;
        }
        let hl = self.half_life;
        let l = self
            .ledgers
            .entry(victim.to_string())
            .or_insert_with(|| Ledger {
                credit: HashMap::new(),
                last_tick: tick,
            });
        // Decay everything to now, then add.
        let dt = tick.wrapping_sub(l.last_tick) as f64;
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
            if tick.wrapping_sub(entry.1) > 30_000 {
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
            // A person taking points off a machine, which is the only
            // direction farming runs. Bot on bot is the calibration ladder
            // talking to itself and is left alone.
            let delta = if self.bots.contains(victim) && !self.bots.contains(attacker) {
                self.throttle_ai_gain(tick, attacker, ra, delta)
            } else {
                delta
            };
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

    /// Settle a match between sides, which is how a flag game is rated.
    ///
    /// Team Elo, the shape every objective game that has kept a ladder
    /// settled on: a side's strength is the mean rating of the pilots on it,
    /// each pair of sides is one contest decided by the score, and every
    /// pilot on a side takes the same signed result at their own K. With more
    /// than two sides the pairwise results are averaged, so a side that beat
    /// two others and lost to one is paid for a win and two thirds of one.
    /// A tie between two sides is a draw and moves nobody at equal strength.
    ///
    /// `sides` is indexed by public team, and a seat is on it only if the
    /// room decided they played: a pilot who arrived for the closing seconds
    /// is not there, and neither is anybody on a private side, which cannot
    /// win. A side with nobody on it is not a side, and fewer than two of
    /// those is not a match; `None` says so and nothing moves.
    ///
    /// The anchor stays put and a bot moves at its own K, as on a death. The
    /// farm brake applies when everybody a pilot beat was a machine, which is
    /// the only match a person can arrange for themselves.
    pub fn matched(&mut self, tick: u32, sides: &[Vec<Id>], score: &[u16]) -> Option<RatedMatch> {
        let live: Vec<usize> = (0..sides.len().min(score.len()))
            .filter(|&t| !sides[t].is_empty())
            .collect();
        if live.len() < 2 {
            return None;
        }
        let strength: Vec<f64> = sides
            .iter()
            .map(|side| {
                if side.is_empty() {
                    UNRATED
                } else {
                    side.iter().map(|who| self.rating_of(who)).sum::<f64>() / side.len() as f64
                }
            })
            .collect();
        let all_bots: Vec<bool> = sides
            .iter()
            .map(|side| side.iter().all(|who| self.bots.contains(who)))
            .collect();
        // Every "before" is read before anything moves, so the order the
        // sides are walked in cannot leak into what anybody is paid.
        let before: HashMap<Id, f64> = live
            .iter()
            .flat_map(|&t| {
                sides[t]
                    .iter()
                    .map(|who| (who.clone(), self.rating_of(who)))
            })
            .collect();
        let mut standings = Vec::new();
        for &s in &live {
            let mut base = 0.0;
            let mut against_bots_only = true;
            for &t in &live {
                if t == s {
                    continue;
                }
                let actual = match score[s].cmp(&score[t]) {
                    std::cmp::Ordering::Greater => 1.0,
                    std::cmp::Ordering::Equal => 0.5,
                    std::cmp::Ordering::Less => 0.0,
                };
                let expected = 1.0 / (1.0 + 10f64.powf((strength[t] - strength[s]) / 400.0));
                base += actual - expected;
                against_bots_only &= all_bots[t];
            }
            base /= (live.len() - 1) as f64;
            for who in &sides[s] {
                let was = before[who];
                let delta = (self.k_for(who) * base).clamp(-EVENT_CAP, EVENT_CAP);
                let delta = if against_bots_only && !self.bots.contains(who) {
                    self.throttle_ai_gain(tick, who, was, delta)
                } else {
                    delta
                };
                let after = if self.anchors.contains(who) {
                    was
                } else {
                    let v = was + delta;
                    self.score.insert(who.clone(), v);
                    v
                };
                *self.games.entry(who.clone()).or_insert(0) += 1;
                standings.push(Standing {
                    who: who.clone(),
                    team: s as u8,
                    before: was,
                    after,
                });
            }
        }
        Some(RatedMatch {
            tick,
            score: score.to_vec(),
            standings,
        })
    }

    /// Trim a gain taken from the AI, once the AI has stopped measuring this
    /// pilot. Returns what they are actually paid.
    ///
    /// Applied where the delta is decided rather than where it is stored, so
    /// the human event log records what the pilot was paid. A cap applied
    /// later would make the rating disagree with that history, and replaying
    /// it under a new model would quietly hand back every point this withheld.
    fn throttle_ai_gain(&mut self, tick: u32, who: &str, rating: f64, delta: f64) -> f64 {
        if delta <= 0.0 || rating < AI_FARM_FLOOR {
            return delta;
        }
        let e = self.ai_gain.entry(who.to_string()).or_insert((0.0, tick));
        // A fresh day. Measured from the first AI gain of the previous one
        // rather than from any wall clock, because a room has no calendar and
        // a rolling window is what the rule is actually about.
        if tick.wrapping_sub(e.1) > DAY_TICKS {
            *e = (0.0, tick);
        }
        let room = (AI_GAIN_PER_DAY - e.0).max(0.0);
        let paid = delta.min(room);
        e.0 += paid;
        paid
    }

    /// A pilot leaving clears their pending ledger.
    pub fn forget(&mut self, who: &str) {
        self.ledgers.remove(who);
    }

    /// A pilot disconnecting with the fight still on them.
    ///
    /// Resolved exactly as a death when the last damage they took is inside
    /// the window, and exactly as `forget` when it is not. Recency is the
    /// only gate this layer can hold: `death` normalizes credit shares, so
    /// any nonzero ledger resolves at full weight and the decay curve can
    /// never distinguish a hot ledger from a stale one. Whether the pilot
    /// was losing is the room's question, answered from the ship's energy
    /// before calling here.
    ///
    /// The ledger is consumed either way, which is what makes settlement
    /// exactly-once: a killing blow and a disconnect racing on the same tick
    /// resolve whichever lands first, and the other finds nothing.
    pub fn quit(&mut self, tick: u32, who: &str) -> Option<RatedEvent> {
        let recent = self
            .ledgers
            .get(who)
            .is_some_and(|l| tick.wrapping_sub(l.last_tick) <= QUIT_WINDOW);
        if !recent {
            self.ledgers.remove(who);
            return None;
        }
        self.death(tick, who)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_quit_under_recent_fire_is_a_death() {
        let mut r = Rating::new();
        r.damage(100, "victim", "killer", 1000, false);
        let ev = r.quit(100 + QUIT_WINDOW, "victim").expect("rated");
        assert_eq!(ev.credits.len(), 1);
        assert!(r.rating_of("victim") < 1200.0, "the quit cost a death");
        assert!(r.rating_of("killer") > 1200.0, "and paid the killer");
    }

    #[test]
    fn a_quit_after_the_window_is_a_leave() {
        let mut r = Rating::new();
        r.damage(100, "victim", "killer", 1000, false);
        assert!(r.quit(101 + QUIT_WINDOW, "victim").is_none());
        assert_eq!(r.rating_of("victim"), 1200.0, "nothing moved");
        // And the ledger went with it: no later event can revive the credit.
        assert!(r.death(101 + QUIT_WINDOW, "victim").is_none());
    }

    #[test]
    fn a_quit_nobody_shot_at_is_nothing() {
        let mut r = Rating::new();
        assert!(r.quit(100, "victim").is_none());
    }

    #[test]
    fn a_death_already_settled_leaves_a_quit_nothing() {
        // The race between the killing blow and the socket closing: whichever
        // settles first consumes the ledger, and the other finds it gone.
        let mut r = Rating::new();
        r.damage(100, "victim", "killer", 1000, false);
        r.death(101, "victim").expect("rated");
        let before = r.rating_of("victim");
        assert!(r.quit(102, "victim").is_none(), "no second settlement");
        assert_eq!(r.rating_of("victim"), before);
    }

    #[test]
    fn a_quit_already_settled_leaves_a_death_nothing() {
        let mut r = Rating::new();
        r.damage(100, "victim", "killer", 1000, false);
        r.quit(101, "victim").expect("rated");
        let before = r.rating_of("victim");
        assert!(r.death(102, "victim").is_none(), "no second settlement");
        assert_eq!(r.rating_of("victim"), before);
    }

    #[test]
    fn randomized_settlements_keep_the_exchange_bounded_and_exactly_once() {
        let mut random = 0x8a5c_31d2u32;
        for case in 0..256 {
            let mut r = Rating::new();
            let attackers = (next_random(&mut random) % 12 + 1) as usize;
            let mut names = Vec::new();
            for i in 0..attackers {
                let name = format!("attacker-{case}-{i}");
                let rating = 800.0 + (next_random(&mut random) % 1201) as f64;
                r.score.insert(name.clone(), rating);
                names.push(name);
            }
            let victim = format!("victim-{case}");
            r.score.insert(
                victim.clone(),
                800.0 + (next_random(&mut random) % 1201) as f64,
            );

            let hits = attackers + (next_random(&mut random) % 24) as usize;
            for tick in 0..hits {
                let attacker = &names[next_random(&mut random) as usize % attackers];
                let damage = (next_random(&mut random) % 20_000 + 1) as i32;
                r.damage(tick as u32, &victim, attacker, damage, false);
            }

            let ev = r.death(hits as u32 + 1, &victim).expect("rated");
            let weights: f64 = ev.credits.iter().map(|credit| credit.1).sum();
            assert!(
                (weights - 1.0).abs() < 1e-9,
                "case {case}: weights sum to {weights}"
            );
            assert!(ev.victim_before.is_finite() && ev.victim_after.is_finite());
            assert!(
                (ev.victim_after - ev.victim_before).abs() <= EVENT_CAP + 1e-9,
                "case {case}: victim movement escaped the event cap"
            );

            let mut credited = std::collections::HashSet::new();
            for (attacker, weight, before, after) in &ev.credits {
                assert!(credited.insert(attacker), "case {case}: duplicate credit");
                assert!(weight.is_finite() && *weight > 0.0);
                assert!(before.is_finite() && after.is_finite());
                assert!(
                    (after - before).abs() <= EVENT_CAP + 1e-9,
                    "case {case}: attacker movement escaped the event cap"
                );
                assert_eq!(
                    r.games_of(attacker),
                    1,
                    "case {case}: attacker counted once"
                );
            }
            assert_eq!(r.games_of(&victim), 1, "case {case}: victim counted once");
            assert!(r.death(hits as u32 + 2, &victim).is_none());
            assert!(r.quit(hits as u32 + 2, &victim).is_none());
            assert_eq!(r.log.len(), 1, "case {case}: one ledger made one event");
        }
    }

    fn next_random(state: &mut u32) -> u32 {
        *state ^= *state << 13;
        *state ^= *state >> 17;
        *state ^= *state << 5;
        *state
    }

    #[test]
    fn solo_kill_is_ordinary_elo() {
        let mut r = Rating::new();
        r.damage(100, "victim", "killer", 1000, false);
        let ev = r.death(101, "victim").expect("rated");
        assert_eq!(ev.credits.len(), 1);
        assert!(
            (ev.credits[0].1 - 1.0).abs() < 1e-9,
            "sole contributor holds all credit"
        );
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
        assert!(
            (w[0].1 - 0.75).abs() < 1e-6,
            "three quarters to the heavy hitter"
        );
        assert!((w[1].1 - 0.25).abs() < 1e-6);
        assert!(
            r.rating_of("heavy") > r.rating_of("light"),
            "more damage, more rating"
        );
    }

    #[test]
    fn healed_damage_stops_counting() {
        let mut r = Rating::new();
        r.damage(0, "v", "old", 1000, false); // long ago
        r.damage(2000, "v", "recent", 1000, false); // five half-lives later
        let ev = r.death(2000, "v").expect("rated");
        let recent = ev.credits.iter().find(|c| c.0 == "recent").unwrap().1;
        assert!(recent > 0.9, "recent damage dominates, got {recent}");
    }

    #[test]
    fn teammate_and_self_damage_earn_nothing() {
        let mut r = Rating::new();
        r.damage(10, "v", "v", 500, false); // self
        r.damage(10, "v", "mate", 500, true); // teammate
        assert!(
            r.death(11, "v").is_none(),
            "an unassisted death rates nothing"
        );
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
        assert!(
            second < first,
            "the second kill on the same victim pays less"
        );
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
        assert_eq!(
            r.rating_of("reference"),
            1200.0,
            "anchor holds after a loss"
        );
        assert!(
            r.rating_of("challenger") != 1200.0,
            "the challenger still moves"
        );
    }

    #[test]
    fn a_human_moves_further_than_the_bot_that_killed_them() {
        let mut r = Rating::new();
        r.mark_bot("bot");
        r.damage(10, "human", "bot", 1000, false);
        r.death(11, "human").unwrap();
        let human_moved = (r.rating_of("human") - 1200.0).abs();
        let bot_moved = (r.rating_of("bot") - 1200.0).abs();
        assert!(
            human_moved > bot_moved * 4.0,
            "human moved {human_moved}, bot moved {bot_moved}"
        );
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
        assert_eq!(r.tier_of("newcomer"), Some("Lead"), "1200 sits in Lead");
    }

    #[test]
    fn every_rating_has_a_tier() {
        assert_eq!(tier(-999.0), "Newb", "the floor is unbounded below");
        assert_eq!(tier(1049.0), "Newb");
        assert_eq!(tier(1050.0), "Wing");
        assert_eq!(tier(1200.0), "Lead");
        assert_eq!(tier(1699.0), "Ace", "the widest band runs to the top one");
        assert_eq!(tier(99999.0), "Legend", "the ceiling is unbounded above");
    }

    /// Grind one bot after another and see what the day pays out.
    fn farm(r: &mut Rating, who: &str, bouts: u32) -> f64 {
        let before = r.rating_of(who);
        for i in 0..bouts {
            // A different bot each time, so repeat dampening is not what is
            // being measured here.
            let bot = format!("bot{i}");
            r.mark_bot(&bot);
            r.score.insert(bot.clone(), 1200.0);
            let t = i * 100;
            r.damage(t, &bot, who, 1000, false);
            r.death(t + 1, &bot);
        }
        r.rating_of(who) - before
    }

    #[test]
    fn the_ai_stops_paying_a_pilot_it_no_longer_measures() {
        let mut r = Rating::new();
        r.score.insert("farmer".into(), 1500.0);
        r.games.insert("farmer".into(), 100);
        let gained = farm(&mut r, "farmer", 200);
        assert!(
            gained <= AI_GAIN_PER_DAY + 1e-6,
            "a day of grinding paid {gained}, cap is {AI_GAIN_PER_DAY}"
        );
        assert!(gained > 0.0, "and it is a cap rather than a wall");
    }

    #[test]
    fn a_pilot_the_ai_is_still_placing_is_not_capped() {
        // The whole point of rating bots is that a human alone in a room can
        // be placed. Capping below the line would break the feature the cap
        // exists to protect.
        let mut r = Rating::new();
        r.score.insert("newcomer".into(), 1200.0);
        let gained = farm(&mut r, "newcomer", 200);
        assert!(
            gained > AI_GAIN_PER_DAY,
            "a placing pilot took only {gained} from a full day of bots"
        );
    }

    #[test]
    fn the_allowance_comes_back_the_next_day() {
        let mut r = Rating::new();
        r.score.insert("farmer".into(), 1500.0);
        r.games.insert("farmer".into(), 100);
        farm(&mut r, "farmer", 200);
        let after_one_day = r.rating_of("farmer");

        // Same pilot, a day later. `farm` starts its ticks at zero, so reach
        // past the window directly rather than replaying a day of nothing.
        let bot = "tomorrow";
        r.mark_bot(bot);
        r.score.insert(bot.into(), 1200.0);
        let t = DAY_TICKS + 10_000;
        r.damage(t, bot, "farmer", 1000, false);
        r.death(t + 1, bot);
        assert!(r.rating_of("farmer") > after_one_day, "the window rolled");
    }

    #[test]
    fn killing_people_is_never_capped() {
        // The brake is about the AI. A pilot who spends a day beating humans
        // has done the thing the ladder is for.
        let mut r = Rating::new();
        r.score.insert("ace".into(), 1500.0);
        r.games.insert("ace".into(), 100);
        let mut gained = 0.0;
        for i in 0..200u32 {
            let foe = format!("human{i}");
            r.score.insert(foe.clone(), 1200.0);
            r.damage(i * 100, &foe, "ace", 1000, false);
            r.death(i * 100 + 1, &foe);
        }
        gained += r.rating_of("ace") - 1500.0;
        assert!(
            gained > AI_GAIN_PER_DAY * 3.0,
            "a day of beating people paid {gained}, which the brake should not touch"
        );
    }

    #[test]
    fn a_bot_beating_a_bot_is_left_alone() {
        // Calibration runs entirely bot on bot. A brake that fired there
        // would flatten the ladder every rating in the fleet is measured
        // against.
        let mut r = Rating::new();
        r.mark_bot("hunter");
        r.score.insert("hunter".into(), 1500.0);
        let gained = farm(&mut r, "hunter", 200);
        assert!(
            gained > AI_GAIN_PER_DAY,
            "the calibration ladder was capped at {gained}"
        );
    }

    #[test]
    fn the_farm_brake_starts_where_ace_does() {
        // Two numbers that have to agree, in two places that cannot see each
        // other. The brake is explainable to a player as "the AI stops paying
        // once you make Ace", and that sentence is only true while this holds.
        let ace = TIERS
            .iter()
            .find(|(n, _)| *n == "Ace")
            .expect("an Ace band");
        assert_eq!(AI_FARM_FLOOR, ace.1);
    }

    #[test]
    fn beating_a_weaker_opponent_pays_almost_nothing() {
        let mut r = Rating::new();
        r.score.insert("fav".into(), 1900.0);
        r.score.insert("dog".into(), 1100.0);
        r.damage(10, "dog", "fav", 1000, false);
        r.death(11, "dog").unwrap();
        assert!(
            r.rating_of("fav") - 1900.0 < 1.0,
            "the favorite gains almost nothing"
        );
    }

    #[test]
    fn a_zone_rated_by_match_keeps_deaths_off_the_ladder() {
        let mut r = Rating::new();
        r.rate_by_match();
        r.damage(100, "victim", "killer", 1000, false);
        assert!(
            r.death(101, "victim").is_none(),
            "no ledger, nothing to settle"
        );
        assert!(r.quit(101, "victim").is_none());
        assert_eq!(r.rating_of("victim"), UNRATED);
        assert_eq!(r.rating_of("killer"), UNRATED);
        assert_eq!(r.games_of("killer"), 0);
    }

    #[test]
    fn a_match_pays_the_winning_side_and_charges_the_other() {
        let mut r = Rating::new();
        r.rate_by_match();
        let sides = vec![
            vec!["a1".to_string(), "a2".to_string()],
            vec!["b1".to_string(), "b2".to_string()],
        ];
        let m = r.matched(1000, &sides, &[7, 3]).expect("a match");
        assert_eq!(m.standings.len(), 4);
        // Equal strength, so a win is worth half of K to everybody on it,
        // and every pilot on a side moves the same.
        let gain = r.rating_of("a1") - UNRATED;
        assert!((gain - K_NEW / 2.0).abs() < 1e-9, "gain {gain}");
        assert_eq!(r.rating_of("a1"), r.rating_of("a2"));
        assert_eq!(r.rating_of("b1"), r.rating_of("b2"));
        assert!(
            (r.rating_of("b1") - UNRATED + gain).abs() < 1e-9,
            "zero-sum at equal K"
        );
        for who in ["a1", "a2", "b1", "b2"] {
            assert_eq!(r.games_of(who), 1, "a match is one game for {who}");
        }
        let a1 = m.standings.iter().find(|s| s.who == "a1").unwrap();
        assert_eq!(a1.team, 0);
        assert_eq!(a1.before, UNRATED);
        assert_eq!(a1.after, r.rating_of("a1"));
    }

    #[test]
    fn a_draw_between_equals_moves_nobody_and_still_counts() {
        let mut r = Rating::new();
        let sides = vec![vec!["a".to_string()], vec!["b".to_string()]];
        r.matched(1000, &sides, &[4, 4]).expect("a match");
        assert_eq!(r.rating_of("a"), UNRATED);
        assert_eq!(r.rating_of("b"), UNRATED);
        assert_eq!(r.games_of("a"), 1);
    }

    #[test]
    fn a_side_is_judged_by_its_mean_and_the_favorite_gains_little() {
        let mut r = Rating::new();
        r.score.insert("strong".into(), 1600.0);
        r.score.insert("weak".into(), 1200.0);
        // A side of one strong and one weak against two average pilots is
        // the stronger side on the mean, and pays little for beating them.
        let sides = vec![
            vec!["strong".to_string(), "weak".to_string()],
            vec!["c".to_string(), "d".to_string()],
        ];
        r.matched(1000, &sides, &[5, 1]).expect("a match");
        let strong = r.rating_of("strong") - 1600.0;
        let weak = r.rating_of("weak") - 1200.0;
        assert!(
            strong > 0.0 && strong < K_NEW / 2.0,
            "a favorite gains less than even money"
        );
        assert_eq!(
            strong, weak,
            "one side, one result, one K: the same movement"
        );
        // And the upset is worth more than the even win.
        let mut u = Rating::new();
        u.score.insert("strong".into(), 1600.0);
        u.score.insert("weak".into(), 1200.0);
        u.matched(1000, &sides, &[1, 5]).expect("a match");
        assert!(
            u.rating_of("c") - UNRATED > K_NEW / 2.0,
            "an upset pays more than even money"
        );
    }

    #[test]
    fn an_empty_side_is_not_a_side_and_one_side_is_not_a_match() {
        let mut r = Rating::new();
        let one = vec![vec!["a".to_string()], Vec::new()];
        assert!(r.matched(1000, &one, &[3, 0]).is_none());
        assert_eq!(r.games_of("a"), 0);
        // Three sides declared, one empty: the two that played settle it
        // between them and the empty one is never a contest.
        let three = vec![vec!["a".to_string()], Vec::new(), vec!["c".to_string()]];
        let m = r.matched(1000, &three, &[3, 0, 1]).expect("two live sides");
        assert_eq!(m.standings.len(), 2);
        assert!(r.rating_of("a") > UNRATED);
        assert!(r.rating_of("c") < UNRATED);
    }

    #[test]
    fn the_anchor_holds_and_a_bot_moves_slowly_in_a_match() {
        let mut r = Rating::new();
        r.set_anchor("anchor", 1200.0);
        r.mark_bot("bot");
        let sides = vec![vec!["anchor".to_string()], vec!["bot".to_string()]];
        r.matched(1000, &sides, &[0, 3]).expect("a match");
        assert_eq!(r.rating_of("anchor"), 1200.0, "pinned");
        assert!((r.rating_of("bot") - 1200.0 - K_BOT / 2.0).abs() < 1e-9);
    }

    #[test]
    fn beating_a_side_of_bots_past_ace_is_on_the_daily_allowance() {
        let mut r = Rating::new();
        r.score.insert("ace".into(), AI_FARM_FLOOR + 10.0);
        r.mark_bot("b1");
        r.mark_bot("b2");
        r.score.insert("b1".into(), AI_FARM_FLOOR + 10.0);
        r.score.insert("b2".into(), AI_FARM_FLOOR + 10.0);
        let sides = vec![
            vec!["ace".to_string()],
            vec!["b1".to_string(), "b2".to_string()],
        ];
        let mut taken = 0.0;
        for n in 0..10 {
            let was = r.rating_of("ace");
            r.matched(n * 1000, &sides, &[3, 0]).expect("a match");
            taken += r.rating_of("ace") - was;
        }
        assert!(
            taken <= AI_GAIN_PER_DAY + 1e-9,
            "took {taken} from bots in a day"
        );
        assert!(taken > AI_GAIN_PER_DAY - 1.0, "the allowance was paid out");
        // With a person on the other side there is no brake.
        let mut open = Rating::new();
        open.score.insert("ace".into(), AI_FARM_FLOOR + 10.0);
        open.mark_bot("b1");
        let mixed = vec![
            vec!["ace".to_string()],
            vec!["b1".to_string(), "human".to_string()],
        ];
        let mut taken = 0.0;
        for n in 0..10 {
            let was = open.rating_of("ace");
            open.matched(n * 1000, &mixed, &[3, 0]).expect("a match");
            taken += open.rating_of("ace") - was;
        }
        assert!(taken > AI_GAIN_PER_DAY, "an unbraked run of wins");
    }
}
