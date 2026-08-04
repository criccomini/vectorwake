//! AI pilots.
//!
//! A bot produces an `InputCommand` and nothing else, from a view no better
//! than a human's, exactly as docs/design/ai-players.md requires. Skill is
//! imperfection added: reaction delay, aim error, range misjudgement, and how
//! early the pilot stops firing to protect its energy.
//!
//! Three clocks, and keeping them apart is most of what makes a pilot look like
//! one. Perception refreshes on a look, ten to twenty times a second, and
//! everything between looks works from a stale picture carried forward. What to
//! do is decided at the pilot's reaction cadence. The hands run every tick,
//! because a servo loop on a reaction clock is a pilot who cannot fly rather
//! than a slow one.
//!
//! `impl Bot` takes no `&World`, which is what makes "a bot knows no more than a
//! player" checkable by grep. It does take a `&Nav`: that is the map the pilot
//! was sent at join, read into a grid, and every client holds the same thing.

use crate::nav::Nav;
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
    /// Muzzle speed in px a tick, which is what a lead has to be solved
    /// against. It used to be assumed: the aim carried a hardcoded 2 px a
    /// tick, which happens to be right for the bullet the shipped zones fire
    /// and wrong for every bomb, every burst, and any zone that tunes one.
    pub speed: f32,
}

/// The cockpit: what a pilot knows about their own ship without looking
/// anywhere. Exact, and current every tick.
pub struct Own {
    pub alive: bool,
    pub x: f32,
    pub y: f32,
    /// Px a tick. This was missing, and its absence is most of why a bot flew
    /// the way it did: with no sense of its own drift a pilot can only point
    /// the nose at where it wants to be and hold thrust, which in a vacuum is
    /// an overshoot every time and a wall shortly after.
    pub vx: f32,
    pub vy: f32,
    /// What this hull can do about that: px per tick squared, and the ceiling
    /// in px a tick. Braking distance is v squared over twice the first, which
    /// on a stock hull at speed is about three hundred pixels.
    pub accel: f32,
    pub top: f32,
    pub radius: f32,
    /// Turns, 0..1.
    pub heading: f32,
    /// Share of this hull's effective maximum.
    pub energy: f32,
    pub in_safe: bool,
    /// What is left in each charge slot, so a repel can be spent rather than
    /// carried to the grave. Three of each, on every hull, and until now not
    /// one of them was ever used.
    pub charges: [u8; sim::MAX_CHARGES],
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

/// Something in the air with this pilot's name on it.
///
/// Bots could not see a shot coming at all: `Scan` was a foe, a flag and a
/// green, so a bomb crossing the room was invisible and they flew into it. A
/// player watches the bomb, which is most of what makes one hard to hit.
#[derive(Clone, Copy)]
pub struct Threat {
    pub x: f32,
    pub y: f32,
    pub vx: f32,
    pub vy: f32,
    /// Px of blast, so a bomb is given more room than a bullet.
    pub blast: f32,
    /// Ticks until it is nearest, and how near that is. Solved in the scan
    /// because it is the same arithmetic for every candidate and only the
    /// winner is worth carrying.
    pub eta: f32,
    pub miss: f32,
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
    pub threat: Option<Threat>,
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
    let cls = &w.cfg.classes[me.cls as usize];
    Own {
        alive: me.active != 0 && me.alive != 0,
        x: me.x as f32 / 256.0,
        y: me.y as f32 / 256.0,
        vx: me.vx as f32 / 65536.0,
        vy: me.vy as f32 / 65536.0,
        // The effective numbers rather than the class ceiling: a pilot who has
        // taken four speed greens flies the ship they are in.
        accel: unsafe { sim::sim_eff_thrust(cls, me) } as f32 / 65536.0,
        top: unsafe { sim::sim_eff_speed(cls, me) } as f32 / 65536.0,
        radius: cls.radius as f32 / 256.0,
        heading: me.heading as f32 / 65536.0,
        energy: me.energy as f32 / max_e,
        in_safe: unsafe { sim::sim_in_safe(&*w.map, me.x, me.y) } != 0,
        charges: me.charge,
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
    out.threat = incoming(w, mx, my, me.team, ship);
    out
}

/// The hostile round most likely to arrive, within a couple of seconds.
///
/// Closest approach of two points moving in straight lines, which is what a
/// player is judging when they watch a bomb and decide whether to move. Rounds
/// do not steer, so the straight line is exact rather than an estimate, and the
/// only reason a pilot gets it wrong is that they looked a moment ago.
fn incoming(w: &World, mx: f32, my: f32, team: u8, ship: u8) -> Option<Threat> {
    /// Two seconds. Further out than that and a shot is somebody else's
    /// problem, or will have hit a wall before it is yours.
    const HORIZON: f32 = 200.0;
    let mut best: Option<Threat> = None;
    for i in 0..w.state.weapon_count as usize {
        let p = &w.state.weapons[i];
        if p.life == 0 || p.owner == ship || p.team == team {
            continue;
        }
        let (px, py) = (p.x as f32 / 256.0 - mx, p.y as f32 / 256.0 - my);
        let (vx, vy) = (p.vx as f32 / 65536.0, p.vy as f32 / 65536.0);
        let vv = vx * vx + vy * vy;
        if vv < 1e-4 {
            continue;
        }
        // Where it passes closest, and when. A negative time is a round that
        // is already past and receding.
        let t = -(px * vx + py * vy) / vv;
        if t < 0.0 || t > HORIZON.min(p.life as f32) {
            continue;
        }
        let (cx, cy) = (px + vx * t, py + vy * t);
        let miss = (cx * cx + cy * cy).sqrt();
        let blast = w.cfg.specs[p.spec as usize].blast as f32 / 256.0;
        // Anything that misses by more than its blast and a hull's width is a
        // round to ignore, and ignoring it is what keeps a pilot from flinching
        // at every shot in a crowded room.
        if miss > blast + 40.0 {
            continue;
        }
        if best.map_or(true, |b| t < b.eta) {
            best = Some(Threat {
                x: p.x as f32 / 256.0,
                y: p.y as f32 / 256.0,
                vx,
                vy,
                blast,
                eta: t,
                miss,
            });
        }
    }
    best
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
        let cls = w.map.tile[ty * sim::MAP_TILES + tx] & 0x0f;
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
            speed: sp.speed as f32 / 65536.0,
        });
    }
    None
}

/// When a shot fired now would arrive, in ticks, or None when the target
/// outruns it.
///
/// `p` is where the target is relative to the pilot and `v` how it is moving
/// relative to the pilot, both in the pilot's own frame. That frame is the
/// point: the core fires a round at `vx0 + speed * direction`, so a shot
/// carries the ship's own velocity with it and only the *relative* motion has
/// to be led. At a hull's 3.25 px a tick against a bullet's 2, the ship
/// outruns its own gun, so a lead that ignores this is not a small error.
///
/// Solving |p + v t| = s t is a quadratic in t. Take the earlier positive root,
/// which is the shot that arrives rather than the one that catches up later.
fn intercept(p: (f32, f32), v: (f32, f32), s: f32) -> Option<f32> {
    let a = v.0 * v.0 + v.1 * v.1 - s * s;
    let b = 2.0 * (p.0 * v.0 + p.1 * v.1);
    let c = p.0 * p.0 + p.1 * p.1;
    // Running at exactly muzzle speed collapses the quadratic to a line, which
    // is not a special case worth an approximation: it is a division by zero.
    if a.abs() < 1e-5 {
        if b.abs() < 1e-6 {
            return None;
        }
        let t = -c / b;
        return (t > 0.0).then_some(t);
    }
    let disc = b * b - 4.0 * a * c;
    if disc < 0.0 {
        return None;
    }
    let r = disc.sqrt();
    let (t1, t2) = ((-b - r) / (2.0 * a), (-b + r) / (2.0 * a));
    let best = match (t1 > 0.0, t2 > 0.0) {
        (true, true) => t1.min(t2),
        (true, false) => t1,
        (false, true) => t2,
        _ => return None,
    };
    Some(best)
}

/// The velocity a pilot wants while heading somewhere it means to stop at.
///
/// Fast when there is room and slow enough to stop when there is not, which is
/// `v² = 2as` and nothing more. It is the whole difference between a pilot who
/// arrives and one who arrives at speed and sails into the far wall: from a
/// stock hull's top speed the braking distance is about three hundred pixels,
/// nineteen tiles, which is most of a room.
fn want_velocity(o: &Own, tx: f32, ty: f32, arrive: f32) -> (f32, f32) {
    let (dx, dy) = (tx - o.x, ty - o.y);
    let d = (dx * dx + dy * dy).sqrt();
    if d < 1e-3 {
        return (0.0, 0.0);
    }
    let room = (d - arrive).max(0.0);
    let v = (2.0 * o.accel * room).sqrt().min(o.top);
    (dx / d * v, dy / d * v)
}

/// A velocity error smaller than this is not worth a burn: the hull is already
/// flying what it asked for, and pressing anything from here is the wobble.
const DEAD: f32 = 0.28;
/// How far off the nose a burn may be and still be worth making. Wide enough
/// that a pilot does not wait for perfect alignment, and no wider: at a full
/// radian this held ships pinned on walls, thrusting fifty degrees off the
/// nose straight into the brick they were trying to pass.
const BURN_ARC: f32 = 0.7;

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

/// What the last decision settled on. Decisions are made at the pilot's
/// reaction cadence; this is what the hands do with one in between.
///
/// Splitting the two is the point. Steering used to be decided with the plan
/// and then held: a pilot on a 38 tick reaction held a turn for 38 ticks, which
/// at 230 rotation is 79 degrees of swing before anything looked again. That is
/// not a slow pilot, it is a pilot who cannot fly. Reaction time belongs on
/// *what to do*, and a servo loop belongs on every tick.
#[derive(Clone, Copy)]
enum Mode {
    /// Nothing worth pressing a key for.
    Idle,
    /// Somewhere to be: where, how close counts as arrived, and how fast
    /// arriving may still be. The pass speed matters more than it looks: the
    /// pickup radius on a green is sixteen pixels, so a pilot can take one at
    /// a slow pass, and braking to a dead stop on every pickup and corner was
    /// costing the roster half its life stood still.
    Travel(f32, f32, f32, f32),
    /// Hold station on the last foe seen, at this range, and shoot it.
    Fight(f32),
}

pub struct Bot {
    pub ship: u8,
    skill: f32,
    react: u32,
    look_every: u32,
    aim_err: f32,
    /// This pilot's current misjudgement, held rather than re-rolled. Rolled
    /// fresh on every look: a wrong estimate that changed a hundred times a
    /// second would average to a right one, which is the opposite of what an
    /// error is meant to model.
    jitter: f32,
    timer: u32,
    mode: Mode,
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
    /// The route in progress, nearest waypoint first, and how far along it this
    /// pilot has got. Held rather than solved every cycle: a search costs a few
    /// thousand cells and the answer is good until the destination moves.
    path: Vec<(f32, f32)>,
    at: usize,
    /// What the route was solved towards, so a destination that has wandered
    /// off can be noticed without re-solving to find out.
    path_to: (f32, f32),
    /// What flying the route needs, one entry per waypoint: how fast its bend
    /// can be taken, and how much route remains beyond it. The first is what
    /// lets the speed envelope brake for the corner ahead instead of parking at
    /// every waypoint; the second is what makes "how far away is it" mean the
    /// road rather than the wall between.
    corner: Vec<f32>,
    suffix: Vec<f32>,
}

/// How far a destination may drift before the route to it is stale. One cell.
const REROUTE_PX: f32 = 128.0;

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
            jitter: 0.0,
            timer: ship as u32 * 7, // stagger so they do not all think at once
            mode: Mode::Idle,
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
            path: Vec::new(),
            at: 0,
            path_to: (0.0, 0.0),
            corner: Vec::new(),
            suffix: Vec::new(),
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
    /// What this pilot thinks it is doing, for the drill to count. A roster
    /// that is 90% travelling is a roster that never finds anybody, and that
    /// is not visible from the outside: a bot flying hard at nothing looks
    /// exactly like a bot flying hard at somebody.
    pub fn doing(&self) -> usize {
        match self.mode {
            Mode::Idle => 0,
            Mode::Travel(..) => 1,
            Mode::Fight(_) => 2,
        }
    }

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
    pub fn think(&mut self, o: &Own, nav: &Nav, fresh: Option<Scan>) -> u16 {
        if fresh.is_some() {
            // A fresh look is a fresh estimate, right or wrong.
            self.jitter = (self.rand() - 0.5) * self.aim_err;
        }
        if let Some(s) = fresh {
            self.seen = s;
            self.seen_at = self.timer;
        }
        self.timer += 1;
        if self.timer % self.react == 0 {
            self.decide(o, nav);
        }
        self.drive(o) | self.trigger(o) | self.charge(o)
    }

    /// The charges, which every hull carries three of and no bot has ever
    /// spent. A repel is the answer to something already too close to outrun,
    /// and a burst is what you throw when the answer to that did not work.
    ///
    /// Slot zero is the repel and slot one the burst, which is what the
    /// baseline builds and what every shipped zone keeps. A hull whose slot is
    /// empty simply never passes the count test.
    fn charge(&mut self, o: &Own) -> u16 {
        if !o.alive || o.in_safe {
            return 0;
        }
        // The worst pilots never think of it, the same way they never bomb.
        if self.skill < 0.35 {
            return 0;
        }
        let threat = self.seen.threat;
        // A repel: something is arriving and there is no time to be elsewhere.
        // The push is hostile-only, so this costs the pilot nothing but the
        // charge.
        let shoved = threat.map_or(false, |t| t.eta < 45.0 && t.miss < t.blast + 24.0);
        let crowded = self.dist < 150.0 && matches!(self.mode, Mode::Fight(_));
        if o.charges[0] > 0 && (shoved || (crowded && o.energy < 0.45)) {
            return sim::BTN_USE;
        }
        // A burst: sixteen rounds in every direction, which is a weapon only at
        // the range where it cannot be dodged. Kept for the fight that has gone
        // wrong rather than spent on the first contact.
        if o.charges[1] > 0
            && self.dist < 220.0
            && o.energy < 0.35
            && matches!(self.mode, Mode::Fight(_))
        {
            return sim::BTN_USE | (1 << sim::BTN_SLOT_SHIFT);
        }
        0
    }

    /// Keep the route to `dest` current, and say how far away it is by the road
    /// this pilot will actually fly: the straight line when one is open, the
    /// length of the route when not. That distance is what the give-up timer
    /// watches, and measuring it along the road is the point of returning it.
    ///
    /// A clear run is flown straight, which is most of them and costs nothing.
    /// Otherwise the route is refreshed when it is spent or its destination has
    /// wandered, and the pilot follows it loosely: skipped ahead here to the
    /// furthest waypoint in plain sight, so a path through a room is flown
    /// across the room rather than corner to corner.
    fn plot(&mut self, o: &Own, nav: &Nav, dest: (f32, f32)) -> f32 {
        let me = (o.x, o.y);
        let straight =
            ((dest.0 - me.0) * (dest.0 - me.0) + (dest.1 - me.1) * (dest.1 - me.1)).sqrt();
        if nav.clear(me, dest) {
            self.drop_route();
            return straight;
        }
        let stale = self.path.is_empty()
            || self.at >= self.path.len()
            || (self.path_to.0 - dest.0).abs() > REROUTE_PX
            || (self.path_to.1 - dest.1).abs() > REROUTE_PX;
        if stale {
            let route = nav.route(me, dest);
            self.store_route(me, route, dest);
        }
        if self.path.is_empty() {
            // Nowhere to route: head at it and let the give-up timer decide,
            // which is what this AI did about everything before there was a
            // route at all.
            return straight;
        }
        while self.at + 1 < self.path.len() && nav.clear(me, self.path[self.at + 1]) {
            self.at += 1;
        }
        let w = self.path[self.at];
        ((w.0 - me.0) * (w.0 - me.0) + (w.1 - me.1) * (w.1 - me.1)).sqrt()
            + self.suffix[self.at]
    }

    fn drop_route(&mut self) {
        self.path.clear();
        self.corner.clear();
        self.suffix.clear();
        self.at = 0;
    }

    /// Keep a route, and precompute what flying it needs. A bend's pass speed
    /// comes from the angle between its legs: straight through is no cap at
    /// all, a right angle is a crawl, and a hairpin is barely moving. Absolute
    /// numbers rather than shares of top speed, because a corner is geometry
    /// and does not widen for a faster hull.
    fn store_route(&mut self, me: (f32, f32), path: Vec<(f32, f32)>, dest: (f32, f32)) {
        self.path = path;
        self.at = 0;
        self.path_to = dest;
        let n = self.path.len();
        self.suffix = vec![0.0; n];
        self.corner = vec![f32::INFINITY; n];
        for i in (0..n.saturating_sub(1)).rev() {
            let (a, b) = (self.path[i], self.path[i + 1]);
            self.suffix[i] = self.suffix[i + 1]
                + ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).sqrt();
        }
        for i in 0..n.saturating_sub(1) {
            let prev = if i == 0 { me } else { self.path[i - 1] };
            let (here, next) = (self.path[i], self.path[i + 1]);
            let (ax, ay) = (here.0 - prev.0, here.1 - prev.1);
            let (bx, by) = (next.0 - here.0, next.1 - here.1);
            let la = (ax * ax + ay * ay).sqrt().max(1e-3);
            let lb = (bx * bx + by * by).sqrt().max(1e-3);
            let c = (ax * bx + ay * by) / (la * lb);
            self.corner[i] = if c > 0.85 {
                f32::INFINITY
            } else if c > 0.45 {
                1.6
            } else if c > -0.2 {
                1.0
            } else {
                0.6
            };
        }
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
        // Nothing is shot through a wall. The bomb already asked this and the
        // gun never did, so a pilot with a target behind a pillar emptied its
        // bar into the pillar: on the drill, one shot in seventy-seven landed.
        if !self.seen.foe.map_or(false, |f| f.clear) {
            return 0;
        }
        // How wide the target is from here, which is the tolerance the shot
        // actually has. A flat 0.16 radians was two ships wide at close range
        // and four ships wide at a hundred tiles, so a pilot at range fired
        // constantly and hit nothing.
        let span = ((o.radius * 2.0) / self.dist.max(1.0)).atan();
        let tol = (span + (1.0 - self.skill) * 0.04).clamp(0.05, 0.32);
        if self.aim_diff(o, self.aim.0, self.aim.1).abs() >= tol {
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
    /// The router does not retire this; it needs it underneath, for every case
    /// where the path is right and the flying is not. `d` is how far away the
    /// destination is by the road the pilot will fly -- route length when there
    /// is a route, straight line when there is not -- and measuring it that way
    /// is what stops the timer and the router fighting. Watching the straight
    /// line, every correct detour reads as a stall. Watching the steer point
    /// instead, as this briefly did, makes the goal's identity churn with every
    /// re-route, and a genuinely pinned pilot chasing a moving target never
    /// accumulates enough stillness to give up: the drill caught one holding
    /// thrust into a wall for ninety seconds on exactly that.
    ///
    /// `arrive` is the distance at which the approach has succeeded rather than
    /// stalled, which is what keeps a bot holding its working range from
    /// deciding it is stuck against the enemy it is busy shooting.
    fn approaching(&mut self, g: Goal, tx: f32, ty: f32, d: f32, arrive: f32) {
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

    /// What to do, at the pilot's reaction cadence. Nothing here presses a key:
    /// it settles a mode and `drive` flies it.
    fn decide(&mut self, o: &Own, nav: &Nav) {
        if !o.alive {
            self.aim = (0.0, 0.0);
            self.goal = None;
            self.mode = Mode::Idle;
            return;
        }

        // Get out of a safe zone, and never pull the trigger inside one: in
        // there the trigger is the brake, so a bot that fires on its way
        // through stops dead in the one place nothing can shoot into.
        if o.in_safe {
            let c = (sim::MAP_TILES as f32 / 2.0) * 16.0;
            self.plot(o, nav, (c, c));
            self.mode = Mode::Travel(c, c, 0.0, f32::INFINITY);
            return;
        }

        // A flag nobody owns, or one the other side holds, is worth crossing
        // the room for. Flags decide the round; kills only clear the way.
        if let Some((fx, fy)) = self.seen.flag.filter(|_| self.worth_trying(Goal::Flag)) {
            let d = self.plot(o, nav, (fx, fy));
            self.approaching(Goal::Flag, fx, fy, d, 24.0);
            // Taken at a pass: the flag radius is eighteen pixels, so slowing
            // to walking pace is enough and stopping is a habit that cost the
            // roster half its life.
            self.mode = Mode::Travel(fx, fy, 24.0, 1.2);
            return;
        }

        // A green within easy reach is worth the detour when energy allows.
        if o.energy > 0.4 {
            if let Some((px, py)) = self.seen.prize.filter(|_| self.worth_trying(Goal::Prize)) {
                let d = self.plot(o, nav, (px, py));
                self.approaching(Goal::Prize, px, py, d, 24.0);
                self.mode = Mode::Travel(px, py, 24.0, 1.2);
                return;
            }
        }

        let foe = self.seen.foe.filter(|_| self.worth_trying(Goal::Foe));
        let Some(foe) = foe else {
            self.roam(o, nav);
            return;
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

        // A wall between the two of them is not a fight, it is a journey. Fly
        // at them rather than holding a range against something that cannot be
        // shot, and let the trigger stay shut on the way.
        if !foe.clear {
            let d = self.plot(o, nav, (fx, fy));
            self.approaching(Goal::Foe, fx, fy, d, 48.0);
            self.mode = Mode::Travel(fx, fy, 0.0, 1.5);
            return;
        }

        // Hold a working range; weaker pilots misjudge it. Break off and
        // rebuild rather than trade at the floor.
        let ideal = 130.0 + (1.0 - self.skill) * 90.0;
        let range = if o.energy < self.reserve() * 0.6 { ideal * 2.2 } else { ideal };
        // Inside that range the pilot has arrived and is fighting, so closing no
        // further is the plan working rather than a wall. Only the run in counts
        // as an approach.
        let (ddx, ddy) = (fx - o.x, fy - o.y);
        self.approaching(Goal::Foe, fx, fy, (ddx * ddx + ddy * ddy).sqrt(), ideal * 1.15);
        self.mode = Mode::Fight(range);
    }

    /// The hands, every tick.
    fn drive(&mut self, o: &Own) -> u16 {
        if !o.alive {
            return 0;
        }
        match self.mode {
            Mode::Idle => {
                self.aim = (0.0, 0.0);
                0
            }
            Mode::Travel(dx, dy, arrive, vend) => {
                self.aim = (0.0, 0.0);
                // Waypoints are passed the moment they are passed, at the tick
                // rate rather than the reaction cadence that planned them. A
                // pilot who needed a whole reaction to notice each corner
                // behind them flew every route as a chain of stops, and the
                // stops are where the roster's time was going.
                while self.at < self.path.len() {
                    let p = self.path[self.at];
                    let (px, py) = (p.0 - o.x, p.1 - o.y);
                    let close = px * px + py * py < 40.0 * 40.0;
                    let passed = !close && self.at + 1 < self.path.len() && {
                        // Beyond the plane through the waypoint that faces the
                        // next leg, which catches a corner cut wide.
                        let q = self.path[self.at + 1];
                        (q.0 - p.0) * -px + (q.1 - p.1) * -py > 0.0
                    };
                    if close || passed {
                        self.at += 1;
                    } else {
                        break;
                    }
                }
                let (steer, cap, rest) = if self.at < self.path.len() {
                    (self.path[self.at], self.corner[self.at], self.suffix[self.at])
                } else {
                    ((dx, dy), f32::INFINITY, 0.0)
                };
                let (sx, sy) = (steer.0 - o.x, steer.1 - o.y);
                let d = (sx * sx + sy * sy).sqrt();
                // Fast where there is road, slow enough for the bend ahead, and
                // down to the pass speed by the end: v² = v_end² + 2as, each
                // cap measured from where its own constraint stands.
                let room = (d + rest - arrive).max(0.0);
                let v = o
                    .top
                    .min((vend * vend + 2.0 * o.accel * room).sqrt())
                    .min((cap * cap + 2.0 * o.accel * d).sqrt());
                let want = if d > 1e-3 { (sx / d * v, sy / d * v) } else { (0.0, 0.0) };
                self.seek(o, want, (sx, sy))
            }
            Mode::Fight(range) => {
                let Some(foe) = self.seen.foe else {
                    self.aim = (0.0, 0.0);
                    return 0;
                };
                let age = self.timer.saturating_sub(self.seen_at) as f32;
                let (fx, fy) = (foe.x + foe.vx * age, foe.y + foe.vy * age);
                let (dx, dy) = (fx - o.x, fy - o.y);
                let dist = (dx * dx + dy * dy).sqrt().max(1.0);
                self.dist = dist;

                // Where to point. The shot inherits this ship's velocity, so
                // what has to be led is the target's motion relative to ours,
                // and the muzzle speed is the weapon's own rather than a
                // constant. A round that cannot catch them leaves `intercept`
                // empty, and then the best a pilot can do is point at them and
                // wait for the geometry to improve.
                let rel = (foe.vx - o.vx, foe.vy - o.vy);
                let muzzle = o.gun.or(o.bomb).map_or(2.0, |s| s.speed);
                let t = intercept((dx, dy), rel, muzzle).unwrap_or(0.0).min(200.0);
                self.aim = (dx + rel.0 * t, dy + rel.1 * t);

                // Stand off at the working range along the line already flown,
                // so closing and backing off are one instruction rather than a
                // thrust rule and a reverse rule that disagree at the boundary.
                let (ux, uy) = (-dx / dist, -dy / dist);
                self.fly(o, fx + ux * range, fy + uy * range, range * 0.25)
            }
        }
    }

    /// Bend the wanted velocity off the line of an arriving round.
    ///
    /// Not a separate behaviour with its own buttons: a dodge is a different
    /// answer to "where do I want to be going", and putting it here means it
    /// composes with whatever the pilot was already doing rather than
    /// interrupting it.
    fn sidestep(&self, o: &Own, wx: f32, wy: f32) -> (f32, f32) {
        let Some(t) = self.seen.threat else { return (wx, wy) };
        let age = self.timer.saturating_sub(self.seen_at) as f32;
        if t.eta - age > 45.0 {
            return (wx, wy);
        }
        let (rx, ry) = (t.x + t.vx * age - o.x, t.y + t.vy * age - o.y);
        let vv = t.vx * t.vx + t.vy * t.vy;
        if vv < 1e-4 {
            return (wx, wy);
        }
        // Where it will pass, relative to this hull.
        let tc = -(rx * t.vx + ry * t.vy) / vv;
        if tc < 0.0 {
            return (wx, wy);
        }
        let (cx, cy) = (rx + t.vx * tc, ry + t.vy * tc);
        let d = (cx * cx + cy * cy).sqrt();
        // What would actually land, rather than what passes nearby. A crowded
        // room is full of rounds going somewhere else, and a pilot who flinches
        // at each of them never holds an aim: widening this by forty pixels cost
        // a third of the shots fired and bought no fewer deaths.
        let want = t.blast + o.radius;
        if d >= want {
            return (wx, wy);
        }
        // Away from where it will pass. Dead on, any perpendicular will do, and
        // the one across its path is the one that clears soonest.
        let (ax, ay) = if d > 1.0 {
            (-cx / d, -cy / d)
        } else {
            let s = vv.sqrt();
            (-t.vy / s, t.vx / s)
        };
        // At the hull's whole speed, because half a dodge is a hit.
        (wx + ax * o.top, wy + ay * o.top)
    }

    /// One wanted velocity in, buttons out: the common tail of every flight.
    ///
    /// The nose is the gun and the engine at once (decision 17), so the two
    /// compete: a pilot with a shot lined up points at the target and takes
    /// whatever thrust that leaves, which is what makes a fight look like
    /// circling rather than a charge. With nothing to shoot the nose follows
    /// the burn -- except when the burn is a brake. Flipping the hull around to
    /// slow down is what the reverse key is for, and a pilot who did it by
    /// turning spent every deceleration facing backwards.
    ///
    /// A burn under `DEAD` is not worth making, and the direction of a vector
    /// that small is noise: a coasting pilot pointed at it turned gently and
    /// for ever, so a settled hull points down the road instead.
    fn seek(&mut self, o: &Own, want: (f32, f32), ahead: (f32, f32)) -> u16 {
        let (wx, wy) = self.sidestep(o, want.0, want.1);
        let (ex, ey) = (wx - o.vx, wy - o.vy);
        let err = (ex * ex + ey * ey).sqrt();
        let free = self.aim == (0.0, 0.0);
        let braking = ex * ahead.0 + ey * ahead.1 < 0.0;
        let dir = if !free {
            self.aim
        } else if err > DEAD && !braking {
            (ex, ey)
        } else {
            ahead
        };
        let mut out = if dir.0.abs() + dir.1.abs() > 1e-3 {
            self.turn(o, dir.0, dir.1, !free)
        } else {
            0
        };
        if err > DEAD {
            let off = self.aim_diff(o, ex, ey).abs();
            if off < BURN_ARC {
                out |= sim::BTN_THRUST;
            } else if off > std::f32::consts::PI - BURN_ARC {
                out |= sim::BTN_REVERSE;
            }
        }
        out
    }

    /// Fly towards a point, and stop there. The bare version, for a
    /// destination with no route behind it: the fight's stand-off point.
    fn fly(&mut self, o: &Own, tx: f32, ty: f32, arrive: f32) -> u16 {
        let want = want_velocity(o, tx, ty, arrive);
        self.seek(o, want, (tx - o.x, ty - o.y))
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
    fn roam(&mut self, o: &Own, nav: &Nav) {
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
        // A point rolled inside a wall would otherwise be pushed at for ever:
        // nothing is nearer than twenty tiles, so `arrived` never fires, and a
        // roam is the one approach with nothing after it to fall through to.
        // Arriving at speed is fine here. A roam point is a direction to be
        // going, not a place to park.
        let d = self.plot(o, nav, self.roam);
        self.approaching(Goal::Roam, self.roam.0, self.roam.1, d, 20.0 * 16.0);
        self.mode = Mode::Travel(self.roam.0, self.roam.1, 20.0 * 16.0, f32::INFINITY);
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

    /// Put the nose on a bearing. Thrust is not decided here: what the engine
    /// does depends on where the burn is, which is `fly`'s business.
    fn turn(&mut self, o: &Own, dx: f32, dy: f32, with_error: bool) -> u16 {
        let diff = self.aim_diff(o, dx, dy) + if with_error { self.jitter } else { 0.0 };
        if diff > 0.05 {
            sim::BTN_RIGHT
        } else if diff < -0.05 {
            sim::BTN_LEFT
        } else {
            0
        }
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
