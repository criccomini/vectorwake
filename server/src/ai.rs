//! AI pilots.
//!
//! A bot produces an `InputCommand` and nothing else, from a view no better
//! than a human's, exactly as docs/design/ai-players.md requires. Skill is
//! imperfection added: reaction delay, aim error, range misjudgement, and how
//! early the pilot stops firing to protect its energy.

use crate::sim::{self, World};

/// A standing pilot. No side: which one they fly for is the zone's business,
/// decided by its own balancer when they join. It used to be written here, six
/// against three, and a two-team zone honoured it, so War ran six against three
/// and one side took every round.
///
/// No start position either. A roster entry used to carry the tile its pilot
/// was placed on, which made sense while the arena seated its own bots at build
/// time; a bot joins through the front door now and takes the next start in the
/// map's rotation exactly as a player does.
#[derive(Clone)]
pub struct RosterEntry {
    pub name: String,
    pub class: u8,
    pub skill: f32,
}

/// The calibrated roster. These nine have careers: `zone/ladder.json` holds a
/// rating for each, earned in the offline tournament, and every other pilot in a
/// zone floats against the one pinned among them.
pub const CALIBRATED: [(&str, u8, f32); 9] = [
    ("Kestrel", 0, 0.30),
    ("Halcyon", 3, 0.46),
    ("Vantage", 6, 0.62),
    ("Ridgeline", 2, 0.78),
    ("Sable", 5, 0.90),
    ("Meridian", 7, 0.38),
    ("Ozone", 1, 0.54),
    ("Tessellate", 4, 0.70),
    ("Cirrus", 2, 0.44),
];

/// Names for the pilots beyond the calibrated nine. Same register, no overlap
/// with them and none with the call signs the client hands players in
/// `client/arena/callsign.lua`, so a scoreboard never leaves you wondering
/// which of the three a name came from.
const FILL_NAMES: [&str; 39] = [
    "Aperture", "Bellwether", "Carrack", "Downdraft", "Escarpment", "Foxglove",
    "Gantry", "Hollow", "Isobar", "Jackstay", "Keelson", "Longshore",
    "Mackerel", "Nightjar", "Oxbow", "Palisade", "Quicksilver", "Ravine",
    "Saltmarsh", "Tideline", "Undertow", "Vellum", "Windrow", "Xenolith",
    "Yardarm", "Zenith", "Alluvium", "Bracken", "Coppice", "Dunelight",
    "Estuary", "Fernbrake", "Glasswort", "Headland", "Inlet", "Junco",
    "Kittiwake", "Limestone", "Moraine",
];

/// The zone's standing roster. Long-lived individuals rather than template
/// spawns: each keeps its name, its hull, and its skill.
pub fn roster() -> Vec<RosterEntry> {
    CALIBRATED
        .iter()
        .map(|&(name, class, skill)| RosterEntry { name: name.into(), class, skill })
        .collect()
}

/// The nth individual the bot server can put in a room, counting from zero.
///
/// The calibrated nine come first, because a room wants the pilots whose
/// ratings mean something. After them the roster is generated, which it has to
/// be: a 64-seat room asks for fifty-one bots and hand-authoring fifty-one
/// careers to fill one room is work with no reader. Deterministic, so pilot 30
/// is the same pilot with the same hull and the same skill every time this
/// process starts, which is what makes an individual an individual.
///
/// Skill spreads over the same range the calibrated nine cover, and hull walks
/// the roster, so a generated crowd is as mixed as an authored one. A name that
/// runs out of list takes a numeral, which is what the client does for a player.
pub fn individual(n: usize) -> RosterEntry {
    if let Some(&(name, class, skill)) = CALIBRATED.get(n) {
        return RosterEntry { name: name.into(), class, skill };
    }
    let i = n - CALIBRATED.len();
    let word = FILL_NAMES[i % FILL_NAMES.len()];
    let lap = i / FILL_NAMES.len();
    let name = if lap == 0 { word.to_string() } else { format!("{word} {}", lap + 1) };
    // A hash of the index rather than a counter, so neighbours in the list are
    // not neighbours in skill and a room filled in order is not a ladder.
    let h = (i as u32).wrapping_mul(2654435761) ^ 0x9e3779b9;
    RosterEntry {
        name,
        class: (h >> 11) as u8 % 8,
        skill: 0.30 + (h % 61) as f32 / 100.0,
    }
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
    /// Pixels a tick. What the engine is actually doing, as against what the
    /// whiskers predict it could: the unstick reflex reads this, because a
    /// hull pinned on a corner is a fact about the world, not the map.
    pub vx: f32,
    pub vy: f32,
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
    /// How far the nearest wall is along each of sixteen compass rays, in
    /// pixels, capped at `WHISKER_PX`. This is what a player gets from the
    /// screen for free: not a route anywhere, just whether the direction they
    /// are about to fly is about to be a wall. Index 0 is north, clockwise,
    /// matching how headings are measured everywhere else here.
    pub clear: [f32; WHISKERS],
}

pub const WHISKERS: usize = 16;
/// Eleven tiles. At full thrust a hull covers about three pixels a tick, so
/// this is around half a second of warning, which is what a pilot glancing
/// ahead actually has.
const WHISKER_PX: f32 = 176.0;

/// Distance this hull can actually fly along a ray before something stops
/// it, walked at half a tile like `clear_line`, doors counted as walls for
/// the same reason they are there.
///
/// A capsule as wide as the hull, not a line. The shipped maps are full of
/// dashed walls -- single tiles with one-tile gaps -- and a line threads a
/// sixteen-pixel gap that no hull fits through: every hull is wider than
/// that, and the widest need two tiles and change. A bot given line rays
/// pressed at the gap it could see through for as long as the test ran,
/// which turned one dashed wall on Chaos into two thirds of all the
/// grinding on the map. Each step therefore checks a point either side of
/// the ray at most of the hull's radius, so a gap reads open only when this
/// hull passes it.
fn whisker(w: &World, x: f32, y: f32, dx: f32, dy: f32, r: f32) -> f32 {
    // The full radius and a few pixels of slack, not a fraction of it. The
    // width this answers is "can this hull fly down there", and the shipped
    // maps hold passages a hull fits through only if centred to the pixel --
    // a 46 px hull at a 48 px gap. A capsule narrower than the hull calls
    // those open, and a bot believes it, clips the corner, and spends its
    // life being un-stuck; asking for the hull plus room to manoeuvre makes
    // it decline squeezes it could only thread perfectly, which is what a
    // person does with them.
    let half = r + 4.0;
    let (px, py) = (-dy * half, dx * half);
    let wall = |sx: f32, sy: f32| {
        let tx = (sx / 16.0) as usize;
        let ty = (sy / 16.0) as usize;
        if tx >= sim::MAP_TILES || ty >= sim::MAP_TILES {
            return true;
        }
        let cls = unsafe { (*w.map).tile[ty * sim::MAP_TILES + tx] } & 0x0f;
        cls == 1 || cls == 3
    };
    // A side ray that is blocked at its very first step is a wall this hull
    // is already flush against, and flying along a wall you are touching is
    // something the collision happily allows -- so that side stops counting.
    // Without this a bot scraping a long wall read every direction but
    // straight back as blocked, and the fallback pressed it into the wall it
    // was trying to leave.
    let mut side_a = true;
    let mut side_b = true;
    let mut d = 8.0;
    while d < WHISKER_PX {
        let (cx, cy) = (x + dx * d, y + dy * d);
        if wall(cx, cy) {
            return d;
        }
        if d == 8.0 {
            side_a = !wall(cx + px, cy + py);
            side_b = !wall(cx - px, cy - py);
        } else if (side_a && wall(cx + px, cy + py))
            || (side_b && wall(cx - px, cy - py))
        {
            return d;
        }
        d += 8.0;
    }
    WHISKER_PX
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
        vx: me.vx as f32 / 65536.0,
        vy: me.vy as f32 / 65536.0,
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
    let r = w.cfg.classes[me.cls as usize].radius as f32;
    for k in 0..WHISKERS {
        let a = k as f32 / WHISKERS as f32 * std::f32::consts::TAU;
        out.clear[k] = whisker(w, mx, my, a.sin(), -a.cos(), r);
    }
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

/// The things a plan can head towards, so an approach that stops closing can be
/// abandoned without the pilot deciding it all over again on the next cycle.
///
/// Leaving a safe zone is not on the list. The way out is the way the pilot came
/// in, and a bot that gave up on it would stay in the one place nothing can be
/// shot from.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Goal {
    Flag = 0,
    Prize = 1,
    Foe = 2,
    Roam = 3,
}

/// How long a pilot pushes at something that is not getting any closer, and how
/// long it leaves that kind of thing alone afterwards. Ticks, so two seconds and
/// five.
const STUCK_TICKS: u32 = 200;
const GIVE_UP_TICKS: u32 = 500;
/// Closing by less than this over the window does not count as closing. A hull
/// does up to 3 px a tick, so anything actually making its way somewhere clears
/// it by an order of magnitude; a hull with its nose against a wall does zero.
const PROGRESS_PX: f32 = 32.0;
/// Two destinations this close together are the same destination, so a green
/// taken and replaced nearby continues the attempt rather than restarting it.
const SAME_GOAL_PX: f32 = 48.0;

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
    /// The approach in progress: what kind it is, where it is going, the closest
    /// this pilot has been to it, and when that closest approach was.
    goal: Option<(Goal, f32, f32)>,
    best_dist: f32,
    best_at: u32,
    /// When each kind of approach is worth trying again, indexed by `Goal`.
    blocked: [u32; 4],
    /// Ticks spent pushing the engine while the hull stayed pinned, and the
    /// escape in progress when that went on long enough: where to fly and
    /// until when.
    pinned: u32,
    detour_dir: f32,
    detour_until: u32,
    /// Whether the hull was facing close enough to where the last steer
    /// wanted to go. Thrust reads this: pushing while pointed somewhere else
    /// is how a pilot grinds a wall while turning away from it.
    aligned: bool,
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
            goal: None,
            best_dist: 0.0,
            best_at: 0,
            blocked: [0; 4],
            pinned: 0,
            detour_dir: 0.0,
            detour_until: 0,
            aligned: true,
        }
    }

    /// Vary this pilot's luck. Two bots with the same hull and skill would
    /// otherwise fly an identical match every time, which makes a calibration
    /// tournament replay one game rather than sample many.
    pub fn reseed(&mut self, seed: u32) {
        self.seed = 0x9e3779b9 ^ seed.wrapping_mul(2654435761).max(1);
        self.timer = seed % 64;
    }

    /// Whether this pilot is due a look this tick. The caller asks, and only
    /// then pays for a `scan`; the offset in `timer` spreads that cost across
    /// ticks rather than landing every bot on the same one.
    pub fn looks_due(&self) -> bool {
        self.timer % self.look_every == 0
    }

    /// Nobody in sight and no flag to run. Asked by the bot server when this
    /// pilot has been told to stand down, because leaving is a thing a player
    /// does between fights: a bot that vanished mid-duel would be a bug the
    /// person it was fighting could see.
    pub fn horizon_clear(&self) -> bool {
        self.seen.foe.is_none() && self.seen.flag.is_none()
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

        // The unstick reflex. Everything above the engine can be wrong about
        // a wall -- the whiskers sample, corners are knife edges, doors move
        // -- but a hull that has been pushing for half a second and going
        // nowhere is not an estimate. When that happens, stop arguing with
        // the map: turn to the openest direction there is and fly that way
        // for most of a second, then resume. It is what a person does when
        // they find themselves nosed into a corner, and it backstops every
        // geometric case this file gets subtly wrong, which by construction
        // it cannot enumerate.
        let out = if o.alive && self.timer < self.detour_until {
            self.steer(o, self.detour_dir.sin() * 100.0,
                       -self.detour_dir.cos() * 100.0, false)
        } else {
            if self.timer % self.react == 0 {
                self.want = self.plan(o);
            }
            self.want | self.trigger(o)
        };
        // The bookkeeping runs on whatever is actually being flown, the
        // escape included: an escape that is itself pinned has to be noticed,
        // or one bad direction choice becomes a hole a bot never leaves.
        if o.alive
            && out & sim::BTN_THRUST != 0
            && (o.vx * o.vx + o.vy * o.vy).sqrt() < 0.4
        {
            self.pinned += 1;
            if self.pinned > 35 {
                self.pinned = 0;
                let c = &self.seen.clear;
                let mut best = 0;
                for k in 0..WHISKERS {
                    if c[k] > c[best] {
                        best = k;
                    }
                }
                self.detour_dir = best as f32 * std::f32::consts::TAU
                    / WHISKERS as f32
                    + (self.rand() - 0.5) * 0.5;
                // Long enough to turn fully round and then actually fly:
                // half a rotation alone is most of a second.
                self.detour_until = self.timer + 130;
                // The roam target is re-rolled, because a wander has no
                // memory worth keeping and the next pick starts from here.
                // The approach in progress is deliberately NOT dropped: its
                // no-progress clock is what abandons an unreachable goal,
                // and resetting it on every escape would let pin-and-escape
                // cycles stretch that give-up out for ever.
                self.roam = (0.0, 0.0);
            }
        } else {
            self.pinned = 0;
        }
        out
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

    /// Whether this kind of approach is worth trying at all right now.
    fn worth_trying(&self, g: Goal) -> bool {
        self.timer >= self.blocked[g as usize]
    }

    /// Note how an approach is going, and give up on it when it stops closing.
    ///
    /// This is the whole of the routing this AI has, and it is deliberately not
    /// routing: rather than working out whether somewhere is reachable, a pilot
    /// heads for it and notices when that is not working. The alternative on the
    /// table was A* over a coarse grid, per docs/architecture/ai-runtime.md, and
    /// it would not have fixed the thing that was actually wrong. What was wrong
    /// is that a plan committed to a destination and then re-derived the same
    /// destination for ever, so any target chosen badly once was chosen badly
    /// until the pilot died. A pathfinder still needs this underneath it, for
    /// every case the path is right and the flying is not.
    ///
    /// `arrive` is the distance at which the approach has succeeded rather than
    /// stalled, which is what keeps a bot holding its working range from
    /// deciding it is stuck against the enemy it is busy shooting.
    fn approaching(&mut self, o: &Own, g: Goal, tx: f32, ty: f32, arrive: f32) {
        let (dx, dy) = (tx - o.x, ty - o.y);
        let d = (dx * dx + dy * dy).sqrt();
        if d <= arrive {
            self.goal = None;
            return;
        }
        let same = self.goal.map_or(false, |(og, ox, oy)| {
            og == g && (ox - tx).abs() < SAME_GOAL_PX && (oy - ty).abs() < SAME_GOAL_PX
        });
        if !same {
            self.goal = Some((g, tx, ty));
            self.best_dist = d;
            self.best_at = self.timer;
        } else if d < self.best_dist - PROGRESS_PX {
            self.best_dist = d;
            self.best_at = self.timer;
        } else if self.timer.saturating_sub(self.best_at) > STUCK_TICKS {
            self.goal = None;
            match g {
                // Nothing falls through past roaming, so an unreachable roam
                // point is replaced rather than given up on. Zero is how `roam`
                // is told to pick somewhere.
                Goal::Roam => self.roam = (0.0, 0.0),
                _ => self.blocked[g as usize] = self.timer + GIVE_UP_TICKS,
            }
        }
    }

    fn plan(&mut self, o: &Own) -> u16 {
        if !o.alive {
            self.aim = (0.0, 0.0);
            self.goal = None;
            return 0;
        }

        // Get out of a safe zone, and never pull the trigger inside one: in
        // there the trigger is the brake, so a bot that fires on its way
        // through stops dead in the one place nothing can shoot into.
        if o.in_safe {
            let c = (sim::MAP_TILES as f32 / 2.0) * 16.0;
            return self.steer(o, c - o.x, c - o.y, false);
        }

        // A flag nobody owns, or one the other side holds, is worth crossing
        // the room for. Flags decide the round; kills only clear the way.
        if let Some((fx, fy)) = self.seen.flag.filter(|_| self.worth_trying(Goal::Flag)) {
            self.aim = (0.0, 0.0); // hands off the trigger while running a flag
            self.approaching(o, Goal::Flag, fx, fy, 16.0);
            return self.steer(o, fx - o.x, fy - o.y, false);
        }

        // A green within easy reach is worth the detour when energy allows.
        if o.energy > 0.4 {
            if let Some((px, py)) = self.seen.prize.filter(|_| self.worth_trying(Goal::Prize)) {
                self.aim = (0.0, 0.0);
                self.approaching(o, Goal::Prize, px, py, 16.0);
                return self.steer(o, px - o.x, py - o.y, false);
            }
        }

        let foe = self.seen.foe.filter(|_| self.worth_trying(Goal::Foe));
        let Some(foe) = foe else {
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
        // Inside that range the pilot has arrived and is fighting, so closing no
        // further is the plan working rather than a wall. Only the run in counts
        // as an approach.
        self.approaching(o, Goal::Foe, fx, fy, ideal * 1.15);
        if dist > ideal * 1.15 && self.aligned {
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
            self.roam = self.pick_roam(o);
        }
        // A point rolled inside a wall would otherwise be pushed at for ever:
        // nothing is nearer than twenty tiles, so `arrived` never fires, and a
        // roam is the one approach with nothing after it to fall through to.
        self.approaching(o, Goal::Roam, self.roam.0, self.roam.1, 20.0 * 16.0);
        self.steer(o, self.roam.0 - o.x, self.roam.1 - o.y, false)
    }

    /// The next place to wander to: a hop in a direction the whiskers say is
    /// open, leaning toward the contested middle.
    ///
    /// It used to be a point rolled in the middle quarter of the map, full
    /// stop, and that is what parked bots against the dashed walls the
    /// converted maps are full of. From anywhere north-east of a dashed
    /// corner, every roll in the middle box is south-west, the dashes are
    /// always in the way, and the give-up fired, re-rolled, and re-derived
    /// the same impossible intent for ever -- a third of all the grinding on
    /// the map came from one such corner. A hop picked from what is open
    /// where the pilot actually is cannot fixate: blocked one way, it leans
    /// another, works around the obstacle a leg at a time, and the bias
    /// still collects everybody in the middle where the fights are.
    fn pick_roam(&mut self, o: &Own) -> (f32, f32) {
        let c = (sim::MAP_TILES as f32 / 2.0) * 16.0;
        let clear = self.seen.clear;
        if clear.iter().all(|v| *v == 0.0) {
            // Never looked yet. The first scan is at most a tenth of a
            // second away and a target is re-picked freely, so anything
            // sensible does: aim at the middle.
            return (c, c);
        }
        let (mx, my) = (c - o.x, c - o.y);
        let md = (mx * mx + my * my).sqrt().max(1.0);
        let step = std::f32::consts::TAU / WHISKERS as f32;
        let mut best_k = 0;
        let mut best = f32::MIN;
        for k in 0..WHISKERS {
            let a = k as f32 * step;
            let (dx, dy) = (a.sin(), -a.cos());
            let dot = (dx * mx + dy * my) / md;
            let score = clear[k] + dot * 70.0 + self.rand() * 60.0;
            if score > best {
                best = score;
                best_k = k;
            }
        }
        let a = best_k as f32 * step;
        let hop = (24.0 + self.rand() * 32.0) * 16.0;
        (o.x + a.sin() * hop, o.y - a.cos() * hop)
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

    /// Bend a desired direction around what the whiskers say is a wall.
    ///
    /// The straight line to the target stays the plan whenever it is clear
    /// enough: `need` is the distance to the target or a hull's worth of
    /// stopping room, whichever is less, so a point-blank fight never bends.
    /// When it is not clear, the nearest sufficiently open ray wins, tried
    /// outward from the straight line a step at a time starting on the side
    /// with more room. When no ray is open enough, the openest one wins,
    /// which in a dead end is straight back out of it.
    ///
    /// This is deliberately still not routing, per ai-runtime.md: nothing
    /// here knows where anything is, only which ways are walls right now.
    /// The give-up in `approaching` stays underneath it for everywhere a
    /// slide along a wall still does not reach.
    fn bend(&self, want: f32, dist: f32) -> f32 {
        let c = &self.seen.clear;
        // Never looked yet: the first scan lands within a tenth of a second,
        // and steering at the target until it does beats steering at north.
        if c.iter().all(|v| *v == 0.0) {
            return want;
        }
        let step = std::f32::consts::TAU / WHISKERS as f32;
        let k0 = (want / step).round() as i32;
        let at = |k: i32| c[k.rem_euclid(WHISKERS as i32) as usize];
        let need = dist.min(96.0).max(24.0);
        if at(k0) >= need {
            return want;
        }
        let side = if at(k0 + 1) >= at(k0 - 1) { 1 } else { -1 };
        for off in 1..=(WHISKERS as i32 / 2) {
            for s in [side, -side] {
                let k = k0 + s * off;
                if at(k) >= need {
                    return k as f32 * step;
                }
            }
        }
        // Boxed in on every side that matters: take the openest direction,
        // ties going to straight back the way we came, because a hull that
        // cannot go anywhere useful should at least stop pressing forward.
        let mut best = k0 + WHISKERS as i32 / 2;
        for k in 0..WHISKERS as i32 {
            if at(k) > at(best) {
                best = k;
            }
        }
        best as f32 * step
    }

    fn steer(&mut self, o: &Own, dx: f32, dy: f32, with_error: bool) -> u16 {
        let jitter = if with_error {
            (self.rand() - 0.5) * self.aim_err
        } else {
            0.0
        };
        let dist = (dx * dx + dy * dy).sqrt();
        let want = self.bend(dx.atan2(-dy), dist);
        let head = o.heading * std::f32::consts::TAU;
        let mut diff = want - head + jitter;
        while diff > std::f32::consts::PI {
            diff -= std::f32::consts::TAU;
        }
        while diff < -std::f32::consts::PI {
            diff += std::f32::consts::TAU;
        }
        let mut out = 0;
        if diff > 0.05 {
            out |= sim::BTN_RIGHT;
        } else if diff < -0.05 {
            out |= sim::BTN_LEFT;
        }
        self.aligned = diff.abs() < 0.5;
        if !with_error && self.aligned {
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

/// The closest green this pilot has a clear run at.
///
/// The line matters more here than it does for a foe. A green does not move, so
/// a bot that picks one behind a wall thrusts into that wall and stays there:
/// the next plan chooses the same green, because it is still the nearest and
/// still sitting there precisely because nobody can reach it. Greens appear in a
/// ring six to twenty-eight tiles from a live pilot, which on a map of scattered
/// furniture puts a good number of them on the far side of something.
///
/// A straight line is not a route, so a green around a corner is passed over.
/// For a green that is the right trade: they are opportunistic, another is along
/// shortly, and a clear line at two hundred pixels is about what a player would
/// bother with. Flags get no such filter, because there are four of them and
/// they decide the round.
fn nearest_prize(w: &World, mx: f32, my: f32, within: f32) -> Option<(f32, f32)> {
    let mut best: Option<(f32, f32, f32)> = None;
    for p in w.state.prizes.iter() {
        if p.active == 0 {
            continue;
        }
        let (px, py) = (p.x as f32 / 256.0, p.y as f32 / 256.0);
        let d2 = (px - mx) * (px - mx) + (py - my) * (py - my);
        if d2 > within * within || best.map_or(false, |b| d2 >= b.0) {
            continue;
        }
        // Last, because it is the expensive test: a couple of dozen tile reads
        // against the two subtractions above.
        if clear_line(w, mx, my, px, py) {
            best = Some((d2, px, py));
        }
    }
    best.map(|(_, x, y)| (x, y))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sim;

    /// Bots on the shipped Chaos map, measured for the failure a player
    /// reports as "stuck in corners": thrust held while going nowhere.
    ///
    /// The number is the share of alive bot-ticks inside sustained pinning:
    /// half a second or more of engine lit and the hull moving under a third
    /// of a pixel a tick. Launches and reversals pass through low speed and
    /// are not that.
    ///
    /// Straight-at-it steering with no wall sense measured 56.2% on this
    /// exact harness: more than half of every bot's life nose against a
    /// wall, which is what "bots stuck in corners" looks like from a
    /// cockpit. Whiskers, the unstick reflex and open-direction roaming
    /// measure 0.0%.
    #[test]
    fn bots_do_not_grind_walls_on_a_real_map() {
        let bytes = std::fs::read("../catalog/zones/chaos/chaos.vwmap")
            .expect("the chaos map ships in this repository");
        let mut w = sim::World::from_packed(0x5eed, &bytes).expect("a map");
        let mut bots = Vec::new();
        for i in 0..10usize {
            let e = individual(i);
            let ship = w.spawn_on_map(e.class, (i % 2) as u8, i as u32 / 2,
                                      512, 512, 0);
            assert!(ship >= 0, "a seat on the map");
            let mut b = Bot::new(ship as u8, e.skill);
            b.reseed(i as u32 * 977 + 13);
            bots.push(b);
        }

        let mut inputs = Vec::new();
        let mut alive_ticks = 0u64;
        let mut grinding = 0u64;
        let mut grind_at: Vec<(i32, i32)> = Vec::new();
        // A launch or a reversal passes through low speed with the engine
        // lit, and neither is being stuck. Stuck is staying that way: only
        // runs of fifty consecutive pinned ticks count, and the whole run
        // counts once it does.
        let mut run: Vec<u32> = vec![0; bots.len()];
        for _ in 0..12_000u32 {
            inputs.clear();
            for b in bots.iter_mut() {
                let ship = b.ship;
                let fresh = b.looks_due().then(|| scan(&w, ship));
                let buttons = b.think(&own(&w, ship), fresh);
                inputs.push(sim::sim_input { ship, buttons });
            }
            w.step(&inputs);
            for (bi, inp) in inputs.iter().enumerate() {
                let sh = &w.state.ships[inp.ship as usize];
                if sh.active == 0 || sh.alive == 0 {
                    run[bi] = 0;
                    continue;
                }
                alive_ticks += 1;
                let vx = sh.vx as f32 / 65536.0;
                let vy = sh.vy as f32 / 65536.0;
                let pushing = inp.buttons & sim::BTN_THRUST != 0;
                if pushing && (vx * vx + vy * vy).sqrt() < 0.35 {
                    run[bi] += 1;
                    if run[bi] == 50 {
                        grinding += 50;
                        grind_at.push((sh.x / 256 / 16, sh.y / 256 / 16));
                    } else if run[bi] > 50 {
                        grinding += 1;
                    }
                } else {
                    run[bi] = 0;
                }
            }
        }
        let mut spots: std::collections::HashMap<(i32, i32), u32> =
            std::collections::HashMap::new();
        for (tx, ty) in grind_at.iter() {
            *spots.entry((tx / 4, ty / 4)).or_default() += 1;
        }
        let mut top: Vec<_> = spots.into_iter().collect();
        top.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
        for ((cx, cy), n) in top.iter().take(10) {
            println!("  {n:6} ticks near tile ({}, {})", cx * 4 + 2, cy * 4 + 2);
        }
        let share = grinding as f64 / alive_ticks.max(1) as f64;
        println!("grinding {grinding} of {alive_ticks} alive bot-ticks \
                  ({:.1}%)", share * 100.0);
        assert!(share < 0.02,
                "bots spend {:.1}% of their lives pushing into walls",
                share * 100.0);
    }
}
