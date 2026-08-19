//! What the bots actually do, on a map they actually fly.
//!
//!     vectorwake-server drill [zone] [seconds]
//!
//! Calibration measures pilots against each other, and it does it in
//! `sim_map_pit`: a bare thirty-tile box with two blocks in it, no greens, two
//! ships. That is the right room for ranking two pilots and the wrong one for
//! noticing that a pilot cannot fly. Corridors, routing, dodging, a crowd and a
//! prize economy are all absent from it, so every failure that only shows up in
//! Chaos is invisible to the ladder rating them.
//!
//! This is the other measurement. It puts the roster on a zone's own map, runs
//! it, and prints what happened, which makes a change to the brain something
//! with a number on either side of it rather than something somebody watched.
//!
//! It ranks nobody. Nothing here writes a rating, and that is deliberate: a
//! ladder earned in a crowd is a ladder that rewards being near the fight
//! rather than winning it.

use crate::{ai, nav, sim};

/// Ticks. Long enough that a slow start is not the whole sample.
const HZ: u32 = 100;

pub struct Drill {
    pub ticks: u32,
    pub bots: usize,
    pub kills: u32,
    pub deaths: u32,
    pub suicides: u32,
    pub completed_lives: u32,
    pub life_ticks: u64,
    pub energy_at_death: f64,
    pub retreats: u32,
    pub recoveries: u32,
    pub retreat_ticks: u64,
    /// Ships shoved off a wall. The core raises one of these per contact, so
    /// this counts collisions and not the walls themselves.
    pub bounces: u32,
    pub shots: u32,
    /// Trigger presses by weapon, counted off the button word the brain
    /// returns rather than off a fire event, so a press the core refuses for
    /// energy or cooldown still shows. A weapon nobody presses and a weapon
    /// nobody is allowed to fire are different faults with the same symptom.
    pub gun_presses: u32,
    pub bomb_presses: u32,
    pub mine_presses: u32,
    /// Presses per hull, so "bots never bomb" can be asked of the hull that
    /// is supposed to and the six that are not.
    pub bomb_by_class: [u32; 8],
    pub alive_by_class: [u64; 8],
    /// Damage events landed on somebody, so shots over hits is roughly accuracy
    /// once a fight is on.
    pub hits: u32,
    /// Bot-ticks spent under `CRAWL`, which on a hull that does 3 px a tick is a
    /// pilot going nowhere.
    pub crawling: u64,
    /// Bot-ticks alive, which is what the rates above are per.
    pub flying: u64,
    /// Summed speed over those ticks, for a mean.
    pub speed: f64,
    /// How much of the map they covered, as the count of eight-tile cells any
    /// bot stood in. A roster that finds one room and stays in it reads here.
    pub cells: usize,
    /// Bot-ticks spent idle, traveling, fighting, recovering and leaving. A roster that is
    /// nearly all travel is a roster that never finds anybody, and one that is
    /// any measurable share leaving is a roster spending its life walking out:
    /// from the outside a departure looks exactly like a journey, which is why
    /// it is counted rather than watched for.
    pub doing: [u64; 5],
    /// And which of those the crawling ticks land in, so a slow roster can be
    /// told apart from a stuck one.
    pub crawl_by: [u64; 5],
}

/// Half a pixel a tick. A hull under thrust does six times this.
const CRAWL: f32 = 0.5;

fn hostile_kill(w: &sim::World, victim: u8, attacker: u8) -> bool {
    attacker != 255
        && attacker != victim
        && (attacker as usize) < w.state.ship_count as usize
        && w.state.ships[attacker as usize].team != w.state.ships[victim as usize].team
}

impl Drill {
    fn report(&self, zone: &str) {
        let mins = self.ticks as f64 / (HZ as f64 * 60.0);
        let per = |n: u32| n as f64 / mins / self.bots as f64;
        println!("drill {zone}: {} bots, {:.1} min", self.bots, mins);
        println!(
            "  kills   {:6.2} per bot-minute  ({} total)",
            per(self.kills),
            self.kills
        );
        println!(
            "  deaths  {:6.2} per bot-minute  ({} total, {} suicides)",
            per(self.deaths),
            self.deaths,
            self.suicides
        );
        println!(
            "  life     {:5.1}s mean, {:.0}% energy at death",
            self.life_ticks as f64 / self.completed_lives.max(1) as f64 / HZ as f64,
            100.0 * self.energy_at_death / self.deaths.max(1) as f64
        );
        println!(
            "  retreat  {} started, {} recovered, {:.1}s mean in recovery",
            self.retreats,
            self.recoveries,
            self.retreat_ticks as f64 / self.retreats.max(1) as f64 / HZ as f64
        );
        println!(
            "  bounces {:6.2} per bot-minute  ({} total)",
            per(self.bounces),
            self.bounces
        );
        println!(
            "  shots   {:6.2} per bot-minute  ({} total)",
            per(self.shots),
            self.shots
        );
        println!(
            "  presses  gun {}, bomb {}, mine {}",
            self.gun_presses, self.bomb_presses, self.mine_presses
        );
        let names = ai::CLASS_NAMES;
        let mut per_class: Vec<String> = Vec::new();
        for (c, name) in names.iter().enumerate().take(8) {
            let secs = self.alive_by_class[c] as f64 / HZ as f64;
            if secs > 0.0 {
                per_class.push(format!(
                    "{name} {:.1}/min",
                    self.bomb_by_class[c] as f64 * 60.0 / secs
                ));
            }
        }
        println!("  bombs by hull  {}", per_class.join(", "));
        println!(
            "  hits    {:6.2} per bot-minute  ({} total, {:.1}% of shots)",
            per(self.hits),
            self.hits,
            100.0 * self.hits as f64 / self.shots.max(1) as f64
        );
        println!(
            "  crawling {:5.1}% of ticks alive, mean speed {:.2} px/tick",
            100.0 * self.crawling as f64 / self.flying.max(1) as f64,
            self.speed / self.flying.max(1) as f64
        );
        println!("  ground   {} cells of eight tiles visited", self.cells);
        let t = self.flying.max(1) as f64;
        println!(
            "  doing    {:.0}% idle, {:.0}% traveling, {:.0}% fighting, \
{:.0}% recovering, {:.0}% leaving",
            100.0 * self.doing[0] as f64 / t,
            100.0 * self.doing[1] as f64 / t,
            100.0 * self.doing[2] as f64 / t,
            100.0 * self.doing[3] as f64 / t,
            100.0 * self.doing[4] as f64 / t
        );
        let c = self.crawling.max(1) as f64;
        println!(
            "  crawl in {:.0}% idle, {:.0}% traveling, {:.0}% fighting, {:.0}% recovering",
            100.0 * self.crawl_by[0] as f64 / c,
            100.0 * self.crawl_by[1] as f64 / c,
            100.0 * self.crawl_by[2] as f64 / c,
            100.0 * self.crawl_by[3] as f64 / c
        );
    }
}

/// Fly `bots` pilots on `map` for `ticks` and report.
pub fn run_on(map: std::sync::Arc<sim::sim_map>, bots: usize, ticks: u32, seed: u32) -> Drill {
    let route = nav::Nav::build(&map);
    let mut w = sim::World::on_shared_map(seed, map);
    // The zone's own settings are not loaded: this measures flying, and a
    // spawn kit of thirty greens decides a fight before flying it matters, for
    // the same reason calibration turns them off.
    w.cfg.spawn_prizes = 0;

    let mut brains = Vec::new();
    for i in 0..bots {
        let e = ai::individual(i);
        // Sides alternate, which is what a free-for-all does not have and what
        // makes anybody hostile to anybody. Two teams is the harsher test: it
        // puts half the room between a pilot and its nearest enemy.
        let ship = w.spawn_on_map(e.class, (i % 2) as u8, i as u32, 0) as u8;
        let mut b = ai::Bot::new(ship, e.skill);
        b.reseed(seed ^ (i as u32).wrapping_mul(2654435761));
        brains.push(b);
    }

    let mut d = Drill {
        ticks,
        bots,
        kills: 0,
        deaths: 0,
        suicides: 0,
        completed_lives: 0,
        life_ticks: 0,
        energy_at_death: 0.0,
        retreats: 0,
        recoveries: 0,
        retreat_ticks: 0,
        bounces: 0,
        shots: 0,
        gun_presses: 0,
        bomb_presses: 0,
        mine_presses: 0,
        bomb_by_class: [0; 8],
        alive_by_class: [0; 8],
        hits: 0,
        crawling: 0,
        flying: 0,
        speed: 0.0,
        cells: 0,
        doing: [0; 5],
        crawl_by: [0; 5],
    };
    let mut seen: std::collections::HashSet<u32> = std::collections::HashSet::new();
    let brains_first = brains[0].ship;
    // Read once. This sat inside the per-bot loop as a var() call per think,
    // which is a getenv and an allocation five thousand times a second to
    // answer a question whose answer cannot change mid-run.
    let tracing = std::env::var("DRILL_TRACE").is_ok();
    let trace_from: u32 = std::env::var("DRILL_FROM")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let mut inputs = Vec::with_capacity(bots);
    let mut before_energy = vec![0.0f32; bots];
    let mut life_age = vec![0u32; bots];

    for _ in 0..ticks {
        inputs.clear();
        for (bi, b) in brains.iter_mut().enumerate() {
            let ship = b.ship;
            let fresh = b.looks_due().then(|| ai::scan(&w, ship));
            let o = ai::own(&w, ship);
            before_energy[bi] = o.energy;
            let buttons = b.think(&o, &route, fresh);
            let cls = (w.state.ships[ship as usize].cls as usize).min(7);
            if o.alive {
                d.alive_by_class[cls] += 1;
            }
            if buttons & sim::BTN_FIRE != 0 {
                d.gun_presses += 1;
            }
            if buttons & sim::BTN_BOMB != 0 {
                d.bomb_presses += 1;
                d.bomb_by_class[cls] += 1;
            }
            if buttons & sim::BTN_MINE != 0 {
                d.mine_presses += 1;
            }
            if tracing
                && ship == brains_first
                && w.state.tick >= trace_from
                && w.state.tick < trace_from + 120
            {
                let v = (o.vx * o.vx + o.vy * o.vy).sqrt();
                println!(
                    "t{:>4} mode {} v {:.2} head {:.3} btn {:>3} pos {:.0},{:.0}",
                    w.state.tick,
                    b.doing(),
                    v,
                    o.heading,
                    buttons,
                    o.x,
                    o.y
                );
            }
            inputs.push(sim::sim_input { ship, buttons });
        }
        w.step(&inputs);

        let ev = &*w.events;
        for i in 0..ev.count as usize {
            match ev.e[i].etype {
                sim::EV_FIRE => d.shots += 1,
                sim::EV_HIT => d.hits += 1,
                sim::EV_DEATH => {
                    let victim = ev.e[i].a;
                    let attacker = ev.e[i].b;
                    d.deaths += 1;
                    if attacker == 255 || attacker == victim {
                        d.suicides += 1;
                    } else if hostile_kill(&w, victim, attacker) {
                        d.kills += 1;
                    }
                    if let Some(bi) = brains.iter().position(|b| b.ship == victim) {
                        d.completed_lives += 1;
                        d.life_ticks += life_age[bi] as u64;
                        d.energy_at_death += before_energy[bi] as f64;
                        life_age[bi] = 0;
                    }
                }
                sim::EV_BOUNCE => d.bounces += 1,
                _ => {}
            }
        }

        for (bi, b) in brains.iter().enumerate() {
            let s = &w.state.ships[b.ship as usize];
            if s.active == 0 || s.alive == 0 {
                continue;
            }
            life_age[bi] += 1;
            d.doing[b.doing()] += 1;
            let (vx, vy) = (s.vx as f32 / 65536.0, s.vy as f32 / 65536.0);
            let v = (vx * vx + vy * vy).sqrt();
            d.flying += 1;
            d.speed += v as f64;
            if v < CRAWL {
                d.crawling += 1;
                d.crawl_by[b.doing()] += 1;
            }
            let cx = (s.x >> 8) / (16 * 8);
            let cy = (s.y >> 8) / (16 * 8);
            seen.insert((cx as u32) << 16 | cy as u32);
        }
    }
    d.retreats = brains.iter().map(ai::Bot::retreats_started).sum();
    d.recoveries = brains.iter().map(ai::Bot::retreats_completed).sum();
    d.retreat_ticks = brains.iter().map(ai::Bot::retreat_ticks).sum();
    d.cells = seen.len();
    d
}

/// `vectorwake-server drill [zone] [seconds] [bots]`, against the catalog beside
/// the binary.
pub fn run_check() {
    let a: Vec<String> = std::env::args().collect();
    let zone = a.get(2).cloned().unwrap_or_else(|| "chaos".into());
    let secs: u32 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(120);
    let bots: usize = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(24);

    // A drill runs from a checkout and never registers anything, so the two
    // variables the catalog names are placeholders here.
    #[cfg(debug_assertions)]
    crate::catalog::set_placeholder_identity();
    let cat = match crate::catalog::load("catalog") {
        Ok(c) => c,
        Err(e) => {
            println!("drill: {e}");
            std::process::exit(1);
        }
    };
    let Some(bytes) = cat.map_bytes(&zone) else {
        println!("drill: zone {zone:?} has no map");
        std::process::exit(1);
    };
    let Some(map) = sim::unpack_map(&bytes) else {
        println!("drill: zone {zone:?} has a map this build cannot read");
        std::process::exit(1);
    };
    let d = run_on(map, bots, secs * HZ, 0xd2111);
    d.report(&zone);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_hostile_attacker_counts_as_a_kill() {
        let mut w = sim::World::new(1);
        let victim = w.spawn(0, 0, 500, 500, 0) as u8;
        let hostile = w.spawn(0, 1, 510, 500, 0) as u8;
        let teammate = w.spawn(0, 0, 520, 500, 0) as u8;
        assert!(hostile_kill(&w, victim, hostile));
        assert!(!hostile_kill(&w, victim, teammate));
        assert!(!hostile_kill(&w, victim, victim));
        assert!(!hostile_kill(&w, victim, 255));
    }
}
