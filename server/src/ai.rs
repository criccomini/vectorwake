//! AI pilots.
//!
//! A bot produces an `InputCommand` and nothing else, from a view no better
//! than a human's, exactly as docs/design/ai-players.md requires. Skill is
//! imperfection added: reaction delay, aim error, range misjudgement, and how
//! early the pilot stops firing to protect its energy.

use crate::sim::{self, World};

/// A standing pilot. No side: which one they fly for is the zone's business,
/// decided by its own balancer when the room is built. It used to be written
/// here, six against three, and a two-team zone honoured it -- so War ran
/// six-against-three and one side took every round.
pub struct RosterEntry {
    pub name: &'static str,
    pub class: u8,
    pub tile_x: i32,
    pub tile_y: i32,
    pub skill: f32,
}

/// The zone's standing roster. Long-lived individuals rather than template
/// spawns: each keeps its name, its hull, and its skill.
pub fn roster() -> Vec<RosterEntry> {
    vec![
        RosterEntry { name: "Kestrel",    class: 0, tile_x: 486, tile_y: 486, skill: 0.30 },
        RosterEntry { name: "Halcyon",    class: 3, tile_x: 538, tile_y: 486, skill: 0.46 },
        RosterEntry { name: "Vantage",    class: 6, tile_x: 538, tile_y: 538, skill: 0.62 },
        RosterEntry { name: "Ridgeline",  class: 2, tile_x: 486, tile_y: 538, skill: 0.78 },
        RosterEntry { name: "Sable",      class: 5, tile_x: 512, tile_y: 478, skill: 0.90 },
        RosterEntry { name: "Meridian",   class: 7, tile_x: 478, tile_y: 512, skill: 0.38 },
        RosterEntry { name: "Ozone",      class: 1, tile_x: 546, tile_y: 512, skill: 0.54 },
        RosterEntry { name: "Tessellate", class: 4, tile_x: 512, tile_y: 546, skill: 0.70 },
        RosterEntry { name: "Cirrus",     class: 2, tile_x: 500, tile_y: 546, skill: 0.44 },
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

/// How far a pilot can see, in world pixels.
///
/// Sixty tiles, which is exactly the radar's reach in the client: `RADAR_TILES`
/// in arena/world.lua and `SPAN` in arena/ui.lua. On screen a ship is visible
/// within about 215 px of the camera; past that a player has a blip on the
/// radar out to here, and beyond it nothing at all.
///
/// This is the number that was missing. `plan` scanned every ship in the arena
/// with no distance test whatever, on a map 16384 px across, which made a bot
/// the one pilot in the room who could see all of it.
pub const SIGHT: f32 = 60.0 * 16.0;

/// One pull of a trigger, as the pilot holding it understands it: the damage
/// it does per tick of the cooldown it imposes, what it costs as a share of
/// the bar, and the blast it makes.
#[derive(Clone, Copy)]
pub struct Shot {
    pub per_tick: f32,
    pub cost: f32,
    pub blast: f32,
}

/// The cockpit: what a pilot knows about their own ship without looking
/// anywhere. Exact, and current every tick.
pub struct Own {
    pub alive: bool,
    pub x: f32,
    pub y: f32,
    /// Turns, 0..1.
    pub heading: f32,
    /// Share of this hull's effective maximum.
    pub energy: f32,
    pub in_safe: bool,
    /// What each trigger would do if pulled now, at the rung this pilot is on.
    /// A pilot knows their own loadout, and the numbers behind it are in the
    /// settings table every client is sent.
    pub gun: Option<Shot>,
    pub bomb: Option<Shot>,
}

#[derive(Clone, Copy)]
pub struct Foe {
    pub x: f32,
    pub y: f32,
    pub vx: f32,
    pub vy: f32,
    /// Whether the line to them is open. A player can see a wall in the way;
    /// this is the same information, and it is what decides whether a bomb is
    /// a weapon or a way to kill yourself.
    pub clear: bool,
}

/// What a look around turned up. Kept between looks, so in between a pilot is
/// working from where things were rather than where they are -- which is both
/// cheaper and more human.
///
/// Positions are absolute rather than relative, so going stale means the
/// target moved and not that the pilot forgot where they themselves are.
#[derive(Clone, Default)]
pub struct Scan {
    pub foe: Option<Foe>,
    pub flag: Option<(f32, f32)>,
    pub prize: Option<(f32, f32)>,
}

/// The pilot's own state, every tick.
///
/// This and `scan` are the only two places a bot's world comes from, and
/// nothing in `impl Bot` takes a `&World` at all. That is what makes "a bot
/// knows no more than a player" a property of the program rather than a
/// sentence in a document -- it is checkable by grep, which is the only kind
/// of guarantee that survives.
pub fn own(w: &World, ship: u8) -> Own {
    let me = &w.state.ships[ship as usize];
    let max_e = w.eff_max_energy(ship as usize).max(1) as f32;
    Own {
        alive: me.active != 0 && me.alive != 0,
        x: me.x as f32 / 256.0,
        y: me.y as f32 / 256.0,
        heading: me.heading as f32 / 65536.0,
        energy: me.energy as f32 / max_e,
        in_safe: unsafe { sim::sim_in_safe(&*w.map, me.x, me.y) } != 0,
        gun: shot_of(w, me, sim::TRIG_GUN, max_e),
        bomb: shot_of(w, me, sim::TRIG_BOMB, max_e),
    }
}

/// A look around, bounded by `SIGHT`.
pub fn scan(w: &World, ship: u8) -> Scan {
    let me = &w.state.ships[ship as usize];
    let (mx, my) = (me.x as f32 / 256.0, me.y as f32 / 256.0);
    let mut out = Scan::default();

    let mut best = SIGHT * SIGHT;
    for i in 0..w.state.ship_count as usize {
        let o = &w.state.ships[i];
        if i == ship as usize || o.active == 0 || o.alive == 0 || o.team == me.team {
            continue;
        }
        let (ox, oy) = (o.x as f32 / 256.0, o.y as f32 / 256.0);
        let d2 = (ox - mx) * (ox - mx) + (oy - my) * (oy - my);
        if d2 < best {
            best = d2;
            out.foe = Some(Foe {
                x: ox,
                y: oy,
                vx: o.vx as f32 / 65536.0,
                vy: o.vy as f32 / 65536.0,
                clear: clear_line(w, mx, my, ox, oy),
            });
        }
    }

    // A flag nobody owns, or one the other side holds, is worth crossing the
    // room for. Flags decide the round; kills only clear the way.
    //
    // A flag this pilot can see is a flag they will go for. The reach used to be
    // 420 px on the reasoning that it should sit "well inside what they can see
    // -- a bot does not sprint the width of the radar for a flag", which was
    // written when a bot could see the whole map. Sight is the radar now, so
    // that reasoning inverts: 420 px is a quarter of perception, and with the
    // flags where they were no bot ever saw one at all.
    out.flag = nearest_flag(w, mx, my, me.team, SIGHT);
    out.prize = nearest_prize(w, mx, my, 200.0);
    out
}

/// Whether the straight line between two points crosses a wall.
///
/// Walked at half a tile, which cannot skip an eight-pixel-thick wall and is
/// a few dozen samples over the ranges anybody asks about. Doors count: they
/// are a wall whenever they are shut, and a pilot who bombs through one when
/// it happens to be open has still made a bad habit of it.
fn clear_line(w: &World, x0: f32, y0: f32, x1: f32, y1: f32) -> bool {
    let (dx, dy) = (x1 - x0, y1 - y0);
    let steps = ((dx * dx + dy * dy).sqrt() / 8.0).ceil() as i32;
    for i in 1..steps {
        let t = i as f32 / steps as f32;
        let tx = ((x0 + dx * t) / 16.0) as usize;
        let ty = ((y0 + dy * t) / 16.0) as usize;
        if tx >= sim::MAP_TILES || ty >= sim::MAP_TILES {
            return false;
        }
        let cls = unsafe { (*w.map).tile[ty * sim::MAP_TILES + tx] } & 0x0f;
        if cls == 1 || cls == 3 {
            return false;
        }
    }
    true
}

/// A trigger's numbers at the rung this pilot is on, or None when the hull has
/// no such weapon.
///
/// The rung is resolved the way the core does it, walking down from the
/// pilot's level: a level is kept through a hull change, so a third rung has
/// to mean rung zero on a ship that only has one.
fn shot_of(w: &World, me: &sim::sim_ship, trig: usize, max_e: f32) -> Option<Shot> {
    let cls = &w.cfg.classes[me.cls as usize];
    let start = (me.level[trig] as usize).min(sim::MAX_RUNGS - 1);
    for r in (0..=start).rev() {
        let pat = cls.trigger[trig][r];
        if pat == sim::NO_PATTERN {
            continue;
        }
        let p = &w.cfg.patterns[pat as usize];
        let sp = &w.cfg.specs[p.spec as usize];
        return Some(Shot {
            per_tick: (sp.damage as f32 * p.count as f32) / p.delay.max(1) as f32,
            cost: p.energy as f32 / max_e,
            blast: sp.blast as f32 / 256.0,
        });
    }
    None
}

pub struct Bot {
    pub ship: u8,
    skill: f32,
    react: u32,
    look_every: u32,
    aim_err: f32,
    timer: u32,
    want: u16,
    seed: u32,
    /// The last look around, and the tick it was taken on. Refreshed on this
    /// pilot's own cadence and worked from in between.
    seen: Scan,
    seen_at: u32,
    /// Where the last plan wanted to shoot, and how far off the target was.
    /// The trigger reads these every tick while the plan refreshes them at
    /// the pilot's reaction cadence.
    aim: (f32, f32),
    dist: f32,
    /// Where this pilot is heading when there is nothing to fight. Zero means
    /// "pick somewhere", which is also the starting state.
    roam: (f32, f32),
}

impl Bot {
    pub fn new(ship: u8, skill: f32) -> Self {
        Bot {
            ship,
            skill,
            react: (38.0 - skill * 30.0).max(3.0) as u32,
            // Ten looks a second for the worst pilot and twenty for the best,
            // which is what docs/architecture/ai-runtime.md has always said
            // perception costs and what this code did not do: it re-read the
            // world every tick, at a hundred hertz, which no client can.
            look_every: (10.0 - skill * 5.0).max(5.0) as u32,
            aim_err: (1.0 - skill) * 0.42,
            timer: ship as u32 * 7, // stagger so they do not all think at once
            want: 0,
            seed: 0x9e3779b9 ^ ((ship as u32) << 16),
            seen: Scan::default(),
            seen_at: 0,
            aim: (0.0, 0.0),
            dist: 0.0,
            roam: (0.0, 0.0),
        }
    }

    /// Vary this pilot's luck. Two bots with the same hull and skill would
    /// otherwise fly an identical match every time, which makes a calibration
    /// tournament replay one game rather than sample many.
    pub fn reseed(&mut self, seed: u32) {
        self.seed = 0x9e3779b9 ^ seed.wrapping_mul(2654435761).max(1);
        self.timer = seed % 64;
    }

    /// Whether this pilot is due a look this tick. The arena asks, and only
    /// then pays for a `scan`; the offset in `timer` spreads that cost across
    /// ticks rather than landing every bot on the same one.
    pub fn looks_due(&self) -> bool {
        self.timer % self.look_every == 0
    }

    fn rand(&mut self) -> f32 {
        self.seed ^= self.seed << 13;
        self.seed ^= self.seed >> 17;
        self.seed ^= self.seed << 5;
        (self.seed % 10_000) as f32 / 10_000.0
    }

    /// One tick of input. `fresh` is a look around, which the arena provides
    /// when `looks_due` says so and not otherwise.
    ///
    /// Where the pilot is going is re-planned at their reaction cadence; when
    /// they pull the trigger is judged every tick. Gating both on reaction
    /// time -- the obvious way to write this -- makes reaction time secretly
    /// control rate of fire, and since firing costs the same pool as living,
    /// the quickest pilot then shoots itself down to nothing. That is what
    /// made a skill-0.95 bot lose 20-1 to a skill-0.15 one.
    pub fn think(&mut self, o: &Own, fresh: Option<Scan>) -> u16 {
        if let Some(s) = fresh {
            self.seen = s;
            self.seen_at = self.timer;
        }
        self.timer += 1;
        if self.timer % self.react == 0 {
            self.want = self.plan(o);
        }
        self.want | self.trigger(o)
    }

    /// The share of the bar a pilot keeps back rather than shooting it away.
    /// Energy is health and ammunition in one pool, so this is the reserve
    /// that stops a bot sitting at empty and dying to the first round that
    /// lands.
    ///
    /// Skill buys a bigger reserve, but only a little, because what it costs
    /// is the time to earn it back. The original recharges a fresh hull at 40
    /// energy a second against a 1000 bar where our own numbers did 105
    /// against 945, so the twenty points of reserve that used to cost under
    /// two seconds came to cost five: a skilled bot spent the fight waiting
    /// instead of shooting, and lost to an unskilled one in calibration.
    fn reserve(&self) -> f32 {
        0.22 + self.skill * 0.07
    }

    /// The reflex: fire when the shot is on and the reserve allows it.
    fn trigger(&mut self, o: &Own) -> u16 {
        if !o.alive || self.aim == (0.0, 0.0) {
            return 0;
        }
        // In a safe zone the trigger is the brake. A bot crossing one with a
        // shot lined up would stop dead in the middle of it.
        if o.in_safe {
            return 0;
        }
        // Energy is health and ammunition in one pool, so knowing when to
        // stop shooting is the whole game. A pilot who fires whenever the
        // shot is on sits permanently at their floor and dies to the first
        // round that lands. Skill is the size of the reserve kept back.
        if o.energy <= self.reserve() {
            return 0;
        }
        if self.aim_diff(o, self.aim.0, self.aim.1).abs() >= 0.16 {
            return 0;
        }
        // A bomb instead of the burst of gunfire, never as well as it. The
        // core reads a held gun as a gun -- `int trig = ((b & BTN_FIRE) == 0)
        // ? TRIG_BOMB : TRIG_GUN` -- and one cooldown covers both, so asking
        // for both at once fires a bomb precisely never.
        if self.bomb_now(o) {
            return sim::BTN_BOMB;
        }
        sim::BTN_FIRE
    }

    /// Whether to throw a bomb instead of the gunfire it stands in for.
    ///
    /// Not a rate comparison. That is what stood here, and on the original's
    /// numbers -- which every hull now carries -- the gun wins everywhere and
    /// always will: 200 damage on a 25 tick cooldown is 8.0 a tick against the
    /// bomb's 750 on 150, which is 5.0. Measured over a full round robin,
    /// every ship at every rung threw zero bombs. A bomb is never the better
    /// shot by that arithmetic, so that arithmetic was the wrong question.
    ///
    /// What a bomb buys is that it does not have to hit. It lands its damage
    /// over a radius, so the question is range. Too close and the blast is on
    /// the pilot who threw it: forcing bombs on regardless made 16% of all
    /// deaths self-inflicted, which is a number no rate test would ever have
    /// found. Too far and it is a fifth of the bar thrown across a room at
    /// somebody who will simply move.
    ///
    /// So the band opens outside the pilot's own blast and closes where the
    /// flight time stops being worth it, and both ends move with the bomb the
    /// hull is actually carrying -- which is how a level 3 bomb becomes a
    /// weapon you throw further rather than a bigger version of the same one.
    fn bomb_now(&self, o: &Own) -> bool {
        let Some(bomb) = o.bomb else { return false };
        // A bomb is a judgement call, and the worst pilots do not make it.
        if self.skill < 0.35 {
            return false;
        }
        // It has to leave the reserve intact, or the pilot spends the fight
        // recovering from having thrown one.
        if o.energy - bomb.cost <= self.reserve() {
            return false;
        }
        // Nothing in the way. A bomb ends on the first wall it touches and
        // puts its blast there, so a bomb thrown down a corridor is a blast on
        // the corridor. This is the condition that was missing, and its
        // absence is measurable rather than theoretical: with the band alone,
        // the pilots allowed to bomb rated 60 points *below* the one that was
        // not, in a room small enough that every bomb found a wall.
        if !self.seen.foe.map_or(false, |f| f.clear) {
            return false;
        }
        // Clear of our own blast with room to close on it while it flies: a
        // bomb covers about 2 px a tick and a hull up to 3, so the gap between
        // them shuts in well under a second.
        let near = bomb.blast + 120.0;
        let far = 480.0f32.max(near + 160.0);
        self.dist > near && self.dist < far
    }

    fn plan(&mut self, o: &Own) -> u16 {
        if !o.alive {
            self.aim = (0.0, 0.0);
            return 0;
        }

        // Get out of a safe zone, and never pull the trigger inside one: in
        // there the trigger is the brake, so a bot that fires on its way
        // through stops dead in the one place nothing can shoot into.
        if o.in_safe {
            let c = (sim::MAP_TILES as f32 / 2.0) * 16.0;
            return self.steer(o, c - o.x, c - o.y, false) | sim::BTN_THRUST;
        }

        // A flag nobody owns, or one the other side holds, is worth crossing
        // the room for. Flags decide the round; kills only clear the way.
        if let Some((fx, fy)) = self.seen.flag {
            self.aim = (0.0, 0.0); // hands off the trigger while running a flag
            return self.steer(o, fx - o.x, fy - o.y, false);
        }

        // A green within easy reach is worth the detour when energy allows.
        if o.energy > 0.4 {
            if let Some((px, py)) = self.seen.prize {
                self.aim = (0.0, 0.0);
                return self.steer(o, px - o.x, py - o.y, false);
            }
        }

        let Some(foe) = self.seen.foe else {
            self.aim = (0.0, 0.0);
            return self.roam(o);
        };
        // Where they were when last looked at, carried forward by how long
        // ago that was. A pilot tracks a target rather than photographing it,
        // and without this the whole ladder inverts: freezing the picture
        // between looks costs a sharp pilot everything and a poor one almost
        // nothing, because precision is the only thing staleness destroys. It
        // ran backwards -- skill 0.95 rated 1192 against skill 0.15 on 1214 --
        // until this line existed.
        let age = self.timer.saturating_sub(self.seen_at) as f32;
        let (fx, fy) = (foe.x + foe.vx * age, foe.y + foe.vy * age);
        let (dx, dy) = (fx - o.x, fy - o.y);
        let dist = (dx * dx + dy * dy).sqrt();
        self.dist = dist;

        // Lead the target: bullets travel about 2 px per tick.
        let lead = (dist / 2.0).min(140.0);
        let ax = dx + foe.vx * lead;
        let ay = dy + foe.vy * lead;
        self.aim = (ax, ay);

        let mut out = self.steer(o, ax, ay, true);

        // Hold a working range; weaker pilots misjudge it.
        let ideal = 130.0 + (1.0 - self.skill) * 90.0;
        if dist > ideal * 1.15 {
            out |= sim::BTN_THRUST;
        } else if dist < ideal * 0.55 {
            out |= sim::BTN_REVERSE;
        }

        // Break off and rebuild rather than trade at the floor. The trigger
        // itself lives in trigger(); this is only where the pilot goes.
        if o.energy < self.reserve() * 0.6 {
            out &= !sim::BTN_THRUST;
            if dist < ideal * 1.6 {
                out |= sim::BTN_REVERSE;
            }
        }
        out
    }

    /// Where a pilot goes when they can see nothing worth going to.
    ///
    /// This used to be no buttons at all, which reads as a bug and is one: a
    /// bot that lost sight of its target stopped dead and stayed there. It went
    /// unnoticed while sight was unlimited, because there was always something
    /// to chase; bounding perception to the radar's sixty tiles made "nothing
    /// in sight" the ordinary case on a map a thousand tiles across, and turned
    /// an arena into a gallery of statues.
    ///
    /// The heading is the contested middle, which is where the maps put their
    /// furniture and therefore where anybody else looking for a fight is also
    /// going, offset per pilot so a roster does not converge on one tile. A new
    /// one is rolled on arrival, so a bot that finds nobody there moves on.
    fn roam(&mut self, o: &Own) -> u16 {
        let arrived = {
            let (dx, dy) = (self.roam.0 - o.x, self.roam.1 - o.y);
            dx * dx + dy * dy < (20.0 * 16.0) * (20.0 * 16.0)
        };
        if self.roam == (0.0, 0.0) || arrived {
            let c = (sim::MAP_TILES as f32 / 2.0) * 16.0;
            let spread = (sim::MAP_TILES as f32 / 8.0) * 16.0;
            let (rx, ry) = (self.rand(), self.rand());
            self.roam = (c + (rx - 0.5) * 2.0 * spread, c + (ry - 0.5) * 2.0 * spread);
        }
        self.steer(o, self.roam.0 - o.x, self.roam.1 - o.y, false) | sim::BTN_THRUST
    }

    fn aim_diff(&self, o: &Own, dx: f32, dy: f32) -> f32 {
        let want = dx.atan2(-dy);
        let head = o.heading * std::f32::consts::TAU;
        let mut diff = want - head;
        while diff > std::f32::consts::PI {
            diff -= std::f32::consts::TAU;
        }
        while diff < -std::f32::consts::PI {
            diff += std::f32::consts::TAU;
        }
        diff
    }

    fn steer(&mut self, o: &Own, dx: f32, dy: f32, with_error: bool) -> u16 {
        let jitter = if with_error {
            (self.rand() - 0.5) * self.aim_err
        } else {
            0.0
        };
        let diff = self.aim_diff(o, dx, dy) + jitter;
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
        let (fx, fy) = (f.x as f32 / 256.0, f.y as f32 / 256.0);
        let d2 = (fx - mx) * (fx - mx) + (fy - my) * (fy - my);
        if d2 <= within * within && best.map_or(true, |b| d2 < b.0) {
            best = Some((d2, fx, fy));
        }
    }
    best.map(|(_, x, y)| (x, y))
}

fn nearest_prize(w: &World, mx: f32, my: f32, within: f32) -> Option<(f32, f32)> {
    let mut best: Option<(f32, f32, f32)> = None;
    for p in w.state.prizes.iter() {
        if p.active == 0 {
            continue;
        }
        let (px, py) = (p.x as f32 / 256.0, p.y as f32 / 256.0);
        let d2 = (px - mx) * (px - mx) + (py - my) * (py - my);
        if d2 <= within * within && best.map_or(true, |b| d2 < b.0) {
            best = Some((d2, px, py));
        }
    }
    best.map(|(_, x, y)| (x, y))
}
