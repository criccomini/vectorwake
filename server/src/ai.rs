//! AI pilots.
//!
//! A bot produces an `InputCommand` and nothing else, from a view no better
//! than a human's, exactly as docs/design/ai-players.md requires. Skill is
//! imperfection added: reaction delay, aim error, range misjudgement, and how
//! early the pilot stops firing to protect its energy.

use crate::sim::{self, World};

pub struct RosterEntry {
    pub name: &'static str,
    pub class: u8,
    pub team: u8,
    pub tile_x: i32,
    pub tile_y: i32,
    pub skill: f32,
}

/// The zone's standing roster. Long-lived individuals rather than template
/// spawns: each keeps its name, its hull, and its skill.
pub fn roster() -> Vec<RosterEntry> {
    vec![
        RosterEntry { name: "Kestrel",    class: 0, team: 1, tile_x: 486, tile_y: 486, skill: 0.30 },
        RosterEntry { name: "Halcyon",    class: 3, team: 1, tile_x: 538, tile_y: 486, skill: 0.46 },
        RosterEntry { name: "Vantage",    class: 6, team: 1, tile_x: 538, tile_y: 538, skill: 0.62 },
        RosterEntry { name: "Ridgeline",  class: 2, team: 1, tile_x: 486, tile_y: 538, skill: 0.78 },
        RosterEntry { name: "Sable",      class: 5, team: 1, tile_x: 512, tile_y: 478, skill: 0.90 },
        RosterEntry { name: "Meridian",   class: 7, team: 1, tile_x: 478, tile_y: 512, skill: 0.38 },
        RosterEntry { name: "Ozone",      class: 1, team: 0, tile_x: 546, tile_y: 512, skill: 0.54 },
        RosterEntry { name: "Tessellate", class: 4, team: 0, tile_x: 512, tile_y: 546, skill: 0.70 },
        RosterEntry { name: "Cirrus",     class: 2, team: 0, tile_x: 500, tile_y: 546, skill: 0.44 },
    ]
}

/// The pinned reference. Its rating is fixed by definition and never earned,
/// and every other pilot in the zone floats against it. Without a fixed point
/// the bots form a closed economy whose absolute scale drifts, which makes
/// every rating quietly meaningless. See docs/design/rating.md.
pub const ANCHOR: &str = "Ozone";
pub const ANCHOR_RATING: f64 = 1200.0;

/// Map a class name from a zone file to its index, so an operator writes
/// "Apex" rather than remembering that Apex is 0.
/// The roster, in the core's class order. Zone files name hulls, and so do
/// the weapons the baseline builds for them.
pub const CLASS_NAMES: [&str; 8] = [
    "Apex", "Wedge", "Chord", "Anvil", "Spire", "Cipher", "Facet", "Lattice",
];

pub fn class_index(name: &str) -> Option<usize> {
    CLASS_NAMES.iter().position(|n| n.eq_ignore_ascii_case(name))
}

pub fn name_for(ship: u8) -> String {
    roster()
        .get(ship as usize)
        .map(|r| r.name.to_string())
        .unwrap_or_else(|| format!("pilot{ship}"))
}

pub struct Bot {
    pub ship: u8,
    skill: f32,
    react: u32,
    aim_err: f32,
    timer: u32,
    want: u16,
    seed: u32,
    /// Where the last plan wanted to shoot, and how far off the target was.
    /// The trigger reads these every tick while the plan refreshes them at
    /// the pilot's reaction cadence.
    aim: (f32, f32),
    dist: f32,
}

impl Bot {
    pub fn new(ship: u8, skill: f32) -> Self {
        Bot {
            ship,
            skill,
            react: (38.0 - skill * 30.0).max(3.0) as u32,
            aim_err: (1.0 - skill) * 0.42,
            timer: ship as u32 * 7, // stagger so they do not all think at once
            want: 0,
            seed: 0x9e3779b9 ^ ((ship as u32) << 16),
            aim: (0.0, 0.0),
            dist: 0.0,
        }
    }

    /// Vary this pilot's luck. Two bots with the same hull and skill would
    /// otherwise fly an identical match every time, which makes a calibration
    /// tournament replay one game rather than sample many.
    pub fn reseed(&mut self, seed: u32) {
        self.seed = 0x9e3779b9 ^ seed.wrapping_mul(2654435761).max(1);
        self.timer = seed % 64;
    }

    fn rand(&mut self) -> f32 {
        self.seed ^= self.seed << 13;
        self.seed ^= self.seed >> 17;
        self.seed ^= self.seed << 5;
        (self.seed % 10_000) as f32 / 10_000.0
    }

    /// One tick of input.
    ///
    /// Where the pilot is going is re-planned at their reaction cadence; when
    /// they pull the trigger is judged every tick. Gating both on reaction
    /// time -- the obvious way to write this -- makes reaction time secretly
    /// control rate of fire, and since firing costs the same pool as living,
    /// the quickest pilot then shoots itself down to nothing. That is what
    /// made a skill-0.95 bot lose 20-1 to a skill-0.15 one.
    pub fn think(&mut self, w: &World) -> u16 {
        self.timer += 1;
        if self.timer % self.react == 0 {
            self.want = self.plan(w);
        }
        self.want | self.trigger(w)
    }

    /// The reflex: fire when the shot is on and the reserve allows it.
    fn trigger(&mut self, w: &World) -> u16 {
        let me = &w.state.ships[self.ship as usize];
        if me.active == 0 || me.alive == 0 || self.aim == (0.0, 0.0) {
            return 0;
        }
        // In a safe zone the trigger is the brake. A bot crossing one with a
        // shot lined up would stop dead in the middle of it.
        if unsafe { sim::sim_in_safe(&*w.map, me.x, me.y) } != 0 {
            return 0;
        }
        let max_e = w.eff_max_energy(self.ship as usize) as f32;
        let e = me.energy as f32 / max_e;
        // Energy is health and ammunition in one pool, so knowing when to
        // stop shooting is the whole game. A pilot who fires whenever the
        // shot is on sits permanently at their floor and dies to the first
        // round that lands. Skill is the size of the reserve kept back.
        let floor = 0.22 + self.skill * 0.20;
        if e <= floor {
            return 0;
        }
        if self.aim_diff(w, self.aim.0, self.aim.1).abs() >= 0.16 {
            return 0;
        }
        let mut out = sim::BTN_FIRE;
        if self.dist < 320.0 && self.skill > 0.5 && self.timer % 180 < self.react {
            out |= sim::BTN_BOMB;
        }
        out
    }

    fn plan(&mut self, w: &World) -> u16 {
        let me = &w.state.ships[self.ship as usize];
        if me.active == 0 || me.alive == 0 {
            self.aim = (0.0, 0.0);
            return 0;
        }

        let mx = me.x as f32 / 256.0;
        let my = me.y as f32 / 256.0;

        // Get out of a safe zone, and never pull the trigger inside one: in
        // there the trigger is the brake, so a bot that fires on its way
        // through stops dead in the one place nothing can shoot into.
        if unsafe { sim::sim_in_safe(&*w.map, me.x, me.y) } != 0 {
            let cx = (sim::MAP_TILES as f32 / 2.0) * 16.0;
            let cy = (sim::MAP_TILES as f32 / 2.0) * 16.0;
            return self.steer(w, cx - mx, cy - my, false) | sim::BTN_THRUST;
        }

        // Nearest live enemy.
        let mut best: Option<(f32, f32, f32)> = None; // (dist2, dx, dy)
        let mut best_v = (0.0f32, 0.0f32);
        for i in 0..w.state.ship_count as usize {
            let o = &w.state.ships[i];
            if i == self.ship as usize || o.active == 0 || o.alive == 0 || o.team == me.team {
                continue;
            }
            let dx = o.x as f32 / 256.0 - mx;
            let dy = o.y as f32 / 256.0 - my;
            let d2 = dx * dx + dy * dy;
            if best.map_or(true, |b| d2 < b.0) {
                best = Some((d2, dx, dy));
                best_v = (o.vx as f32 / 65536.0, o.vy as f32 / 65536.0);
            }
        }

        // A flag nobody owns, or one the other side holds, is worth crossing
        // the room for. Flags decide the round; kills only clear the way.
        if let Some((dx, dy)) = nearest_flag(w, mx, my, me.team, 420.0) {
            self.aim = (0.0, 0.0); // hands off the trigger while running a flag
            return self.steer(w, dx, dy, false);
        }

        // A green within easy reach is worth the detour when energy allows.
        let max_e = w.eff_max_energy(self.ship as usize) as f32;
        if me.energy as f32 > max_e * 0.4 {
            if let Some((dx, dy)) = nearest_prize(w, mx, my, 200.0) {
                self.aim = (0.0, 0.0);
                return self.steer(w, dx, dy, false);
            }
        }

        let Some((d2, dx, dy)) = best else {
            self.aim = (0.0, 0.0);
            return 0;
        };
        let dist = d2.sqrt();
        self.dist = dist;

        // Lead the target: bullets travel about 2 px per tick.
        let lead = (dist / 2.0).min(140.0);
        let ax = dx + best_v.0 * lead;
        let ay = dy + best_v.1 * lead;
        self.aim = (ax, ay);

        let mut out = self.steer(w, ax, ay, true);

        // Hold a working range; weaker pilots misjudge it.
        let ideal = 130.0 + (1.0 - self.skill) * 90.0;
        if dist > ideal * 1.15 {
            out |= sim::BTN_THRUST;
        } else if dist < ideal * 0.55 {
            out |= sim::BTN_REVERSE;
        }

        // Energy is health and ammunition in one pool, so knowing when to
        // stop shooting is the whole game. A pilot who fires whenever the
        // shot is on sits permanently at their floor and dies to the first
        // round that lands -- which is why accurate aim alone made bots
        // strictly worse, and why the ladder ran backwards until this
        // existed. Skill is the size of the reserve kept back, and the
        // willingness to break off and rebuild it.
        // Break off and rebuild rather than trade at the floor. The trigger
        // itself lives in trigger(); this is only where the pilot goes.
        let e = me.energy as f32 / max_e;
        if e < (0.22 + self.skill * 0.20) * 0.6 {
            out &= !sim::BTN_THRUST;
            if dist < ideal * 1.6 {
                out |= sim::BTN_REVERSE;
            }
        }
        out
    }

    fn aim_diff(&self, w: &World, dx: f32, dy: f32) -> f32 {
        let me = &w.state.ships[self.ship as usize];
        let want = dx.atan2(-dy);
        let head = (me.heading as f32 / 65536.0) * std::f32::consts::TAU;
        let mut diff = want - head;
        while diff > std::f32::consts::PI {
            diff -= std::f32::consts::TAU;
        }
        while diff < -std::f32::consts::PI {
            diff += std::f32::consts::TAU;
        }
        diff
    }

    fn steer(&mut self, w: &World, dx: f32, dy: f32, with_error: bool) -> u16 {
        let jitter = if with_error {
            (self.rand() - 0.5) * self.aim_err
        } else {
            0.0
        };
        let diff = self.aim_diff(w, dx, dy) + jitter;
        let mut out = 0;
        if diff > 0.05 {
            out |= sim::BTN_RIGHT;
        } else if diff < -0.05 {
            out |= sim::BTN_LEFT;
        }
        if !with_error && diff.abs() < 0.5 {
            out |= sim::BTN_THRUST;
        }
        out
    }
}

/// The closest flag this pilot's team does not already hold.
fn nearest_flag(w: &World, mx: f32, my: f32, team: u8, within: f32) -> Option<(f32, f32)> {
    let mut best: Option<(f32, f32, f32)> = None;
    for i in 0..w.state.flag_count as usize {
        let f = &w.state.flags[i];
        if f.active == 0 || f.team == team || f.carried == 1 {
            continue;
        }
        let dx = f.x as f32 / 256.0 - mx;
        let dy = f.y as f32 / 256.0 - my;
        let d2 = dx * dx + dy * dy;
        if d2 <= within * within && best.map_or(true, |b| d2 < b.0) {
            best = Some((d2, dx, dy));
        }
    }
    best.map(|(_, dx, dy)| (dx, dy))
}

fn nearest_prize(w: &World, mx: f32, my: f32, within: f32) -> Option<(f32, f32)> {
    let mut best: Option<(f32, f32, f32)> = None;
    for p in w.state.prizes.iter() {
        if p.active == 0 {
            continue;
        }
        let dx = p.x as f32 / 256.0 - mx;
        let dy = p.y as f32 / 256.0 - my;
        let d2 = dx * dx + dy * dy;
        if d2 <= within * within && best.map_or(true, |b| d2 < b.0) {
            best = Some((d2, dx, dy));
        }
    }
    best.map(|(_, dx, dy)| (dx, dy))
}
