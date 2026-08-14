//! AI pilots.
//!
//! A bot produces an `InputCommand` and nothing else, from a view no better
//! than a human's, exactly as docs/design/ai-players.md requires. Skill is
//! imperfection added: reaction delay, aim error, look cadence, and whether the
//! pilot can use the harder parts of its loadout well.
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

/// The calibrated roster. These eight have careers: `zone/ladder.json` holds a
/// rating for each, earned in the offline tournament, and every other pilot in a
/// zone floats against the one pinned among them.
pub const CALIBRATED: [(&str, u8, f32); 8] = [
    ("Kestrel", 0, 0.30),
    ("Halcyon", 3, 0.46),
    ("Vantage", 6, 0.62),
    ("Ridgeline", 2, 0.78),
    ("Sable", 5, 0.90),
    ("Ozone", 1, 0.54),
    ("Tessellate", 4, 0.70),
    ("Cirrus", 2, 0.44),
];

/// Names for the pilots beyond the calibrated roster. Same register, no overlap
/// with them and none with the call signs the client hands players in
/// `client/arena/callsign.lua`, so a scoreboard never leaves you wondering
/// which of the three a name came from.
pub(crate) const FILL_NAMES: [&str; 39] = [
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

/// The zone's standing roster. Long-lived individuals rather than template
/// spawns: each keeps its name, its hull, and its skill.
pub fn roster() -> Vec<RosterEntry> {
    CALIBRATED
        .iter()
        .map(|&(name, class, skill)| RosterEntry {
            name: name.into(),
            class,
            skill,
        })
        .collect()
}

/// The nth individual the bot server can put in a room, counting from zero.
///
/// The calibrated pilots come first, because a room wants the pilots whose
/// ratings mean something. After them the roster is generated, which it has to
/// be: a 64-seat room asks for fifty-one bots and hand-authoring fifty-one
/// careers to fill one room is work with no reader. Deterministic, so pilot 30
/// is the same pilot with the same hull and the same skill every time this
/// process starts, which is what makes an individual an individual.
///
/// Skill spreads over the same range the calibrated pilots cover, and hull walks
/// the roster, so a generated crowd is as mixed as an authored one. A name that
/// runs out of list takes a numeral, which is what the client does for a player.
pub fn individual(n: usize) -> RosterEntry {
    if let Some(&(name, class, skill)) = CALIBRATED.get(n) {
        return RosterEntry {
            name: name.into(),
            class,
            skill,
        };
    }
    let i = n - CALIBRATED.len();
    let word = FILL_NAMES[i % FILL_NAMES.len()];
    let lap = i / FILL_NAMES.len();
    let name = if lap == 0 {
        word.to_string()
    } else {
        format!("{word} {}", lap + 1)
    };
    // A hash of the index rather than a counter, so neighbours in the list are
    // not neighbours in skill and a room filled in order is not a ladder.
    let h = (i as u32).wrapping_mul(2654435761) ^ 0x9e3779b9;
    RosterEntry {
        name,
        // Over the roster's own length rather than a literal: the hull
        // count is a property of the core, and a bot handed an index past
        // the end of it is an out-of-bounds read the moment anything asks
        // what it is flying.
        class: (h >> 11) as u8 % CLASS_NAMES.len() as u8,
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
pub const CLASS_NAMES: [&str; 7] = [
    "Apex", "Wedge", "Chord", "Anvil", "Cipher", "Facet", "Lattice",
];

pub fn class_index(name: &str) -> Option<usize> {
    CLASS_NAMES
        .iter()
        .position(|n| n.eq_ignore_ascii_case(name))
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
    /// Improvements carried on this life. A fresh hull should want greens;
    /// one that has already built a kit should value keeping it.
    pub build: u16,
    /// Everything this death would pay, including earned bounty. Kept separate
    /// from `build` because a veteran with no upgrades still has something to
    /// preserve, while earned bounty does not make another green less useful.
    pub value: u16,
    /// A carried objective makes survival more important than another duel.
    pub carrying_flag: bool,
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
    pub energy: f32,
    pub value: u16,
    pub carrying_flag: bool,
    /// Whether the line to them is open. A player can see a wall in the way;
    /// this is the same information, and it is what decides whether a bomb is
    /// a weapon or a way to kill yourself.
    pub clear: bool,
}

#[derive(Clone, Copy)]
pub struct Prize {
    pub x: f32,
    pub y: f32,
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
    /// Every hostile contact inside radar range. The decision layer scores
    /// them; nearest alone is a poor target when that pilot is healthy and a
    /// wounded flag carrier is standing beside them.
    pub contacts: Vec<Foe>,
    /// Anybody at all inside sight, either side. The fights only care about
    /// `foe`, but a departure holds the door for everyone: a pilot that logs
    /// off in front of a teammate has popped out of their world exactly as
    /// rudely as in front of an enemy. This went unenforced while the router
    /// could fail: a leaver often could not reach the best corner, took a
    /// nearer one, and the test that asserts a quiet exit stayed green on
    /// where the roamers happened to be.
    pub company: bool,
    pub flag: Option<(f32, f32)>,
    pub prize: Option<(f32, f32)>,
    /// A small nearest-first set, enough to choose a useful green without
    /// walking every prize through the map router on every look.
    pub prizes: Vec<Prize>,
    pub allies_near: u8,
    pub hostiles_near: u8,
    pub threat: Option<Threat>,
    /// How far the nearest wall is along each of sixteen compass rays, in
    /// pixels, capped at `WHISKER_PX`. This is what a player gets from the
    /// screen for free: not a route anywhere, just whether the direction they
    /// are about to fly is about to be a wall. Index 0 is north, clockwise,
    /// matching how headings are measured everywhere else here.
    ///
    /// The router answers a different question. Its grid is two-tile cells and
    /// its routes are legs between cell centers, so it knows the way through a
    /// maze and nothing about the wall eight pixels off this hull's bow in the
    /// middle of a leg. The whiskers are the short-range sense the routes fly
    /// by, and the pairing halved the wall contacts the router alone left.
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
    // maps hold passages a hull fits through only if centered to the pixel --
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
        let cls = w.map.tile[ty * sim::MAP_TILES + tx] & 0x0f;
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
        } else if (side_a && wall(cx + px, cy + py)) || (side_b && wall(cx - px, cy - py)) {
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
    let cls = &w.cfg.classes[me.cls as usize];
    let mods: u16 = me
        .mods
        .iter()
        .map(|packed| {
            (0..sim::MOD_COUNT)
                .map(|m| ((packed >> (m * 2)) & 3) as u16)
                .sum::<u16>()
        })
        .sum();
    let build = me.up.iter().map(|n| *n as u16).sum::<u16>()
        + me.level.iter().map(|n| *n as u16).sum::<u16>()
        + mods;
    let carrying_flag = w.state.flags[..w.state.flag_count as usize]
        .iter()
        .any(|f| f.active != 0 && f.carried != 0 && f.carrier == ship);
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
        // The collision box follows the heading now, so one number for "how
        // big am I" is the nose-corner diagonal: the worst reach at any
        // orientation, which is the honest figure for both ducking a blast
        // and judging how wide a target stands.
        radius: ((cls.fore * cls.fore + cls.halfw * cls.halfw) as f32).sqrt(),
        heading: me.heading as f32 / 65536.0,
        energy: me.energy as f32 / max_e,
        in_safe: unsafe { sim::sim_in_safe(&*w.map, me.x, me.y) } != 0,
        build,
        value: w.bounty(ship as usize).clamp(0, u16::MAX as i32) as u16,
        carrying_flag,
        charges: me.charge,
        gun: shot_of(w, me, sim::TRIG_GUN, max_e),
        bomb: shot_of(w, me, sim::TRIG_BOMB, max_e),
    }
}

/// Everybody else in the room, whatever side they are on and whether or not
/// this pilot can see them. Not a look around: this is the question "where is
/// there nobody" being asked by a pilot on its way out, and the answer has to
/// account for the people it cannot see as well as the ones it can.
pub fn crowd(w: &World, ship: u8) -> Vec<(f32, f32)> {
    let mut out = Vec::with_capacity(w.state.ship_count as usize);
    for i in 0..w.state.ship_count as usize {
        let o = &w.state.ships[i];
        if i == ship as usize || o.active == 0 {
            continue;
        }
        out.push((o.x as f32 / 256.0, o.y as f32 / 256.0));
    }
    out
}

/// A look around, bounded by `SIGHT`.
pub fn scan(w: &World, ship: u8) -> Scan {
    let me = &w.state.ships[ship as usize];
    let (mx, my) = (me.x as f32 / 256.0, me.y as f32 / 256.0);
    let mut out = Scan::default();

    let mut best = SIGHT * SIGHT;
    const LOCAL: f32 = 480.0;
    for i in 0..w.state.ship_count as usize {
        let o = &w.state.ships[i];
        if i == ship as usize || o.active == 0 || o.alive == 0 {
            continue;
        }
        {
            let (ox, oy) = (o.x as f32 / 256.0, o.y as f32 / 256.0);
            let d2 = (ox - mx) * (ox - mx) + (oy - my) * (oy - my);
            if d2 < SIGHT * SIGHT {
                out.company = true;
            }
        }
        let (ox, oy) = (o.x as f32 / 256.0, o.y as f32 / 256.0);
        let d2 = (ox - mx) * (ox - mx) + (oy - my) * (oy - my);
        if o.team == me.team {
            if d2 < LOCAL * LOCAL {
                out.allies_near = out.allies_near.saturating_add(1);
            }
            continue;
        }
        // Somebody standing in a safe zone is not a target. Nothing can be
        // shot into one, so a bot that kept them selected held station outside
        // the door and waited, trigger shut, for as long as they cared to
        // stand there: a pilot who ducks into a safe has a bot parked on them
        // rather than a game going on. Skipping them here rather than in
        // `decide` is what makes the whole chain let go: the approach, the
        // aim and the trigger all read this one field.
        if unsafe { sim::sim_in_safe(&*w.map, o.x, o.y) } != 0 {
            continue;
        }
        if d2 >= SIGHT * SIGHT {
            continue;
        }
        if d2 < LOCAL * LOCAL {
            out.hostiles_near = out.hostiles_near.saturating_add(1);
        }
        let max_e = w.eff_max_energy(i).max(1) as f32;
        let carrying_flag = w.state.flags[..w.state.flag_count as usize]
            .iter()
            .any(|f| f.active != 0 && f.carried != 0 && f.carrier == i as u8);
        let foe = Foe {
            x: ox,
            y: oy,
            vx: o.vx as f32 / 65536.0,
            vy: o.vy as f32 / 65536.0,
            energy: o.energy as f32 / max_e,
            value: w.bounty(i).clamp(0, u16::MAX as i32) as u16,
            carrying_flag,
            clear: clear_line(w, mx, my, ox, oy),
        };
        out.contacts.push(foe);
        if d2 < best {
            best = d2;
            out.foe = Some(foe);
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
    out.prizes = nearest_prizes(w, mx, my, SIGHT, 8);
    out.prize = out
        .prizes
        .iter()
        .find(|p| p.clear && (p.x - mx).hypot(p.y - my) <= 200.0)
        .map(|p| (p.x, p.y));
    out.threat = incoming(w, mx, my, me.team, ship);
    // The margin a whisker keeps from a wall. The box follows the heading
    // now, so the honest bound for "can I fly this way" is the hull's worst
    // reach at any orientation: the nose-corner diagonal. A bot that probed
    // with its flank width would plan routes its own nose cannot take.
    let cls = &w.cfg.classes[me.cls as usize];
    let (fore, halfw) = (cls.fore as f32, cls.halfw as f32);
    let r = (fore * fore + halfw * halfw).sqrt();
    for k in 0..WHISKERS {
        let a = k as f32 / WHISKERS as f32 * std::f32::consts::TAU;
        out.clear[k] = whisker(w, mx, my, a.sin(), -a.cos(), r);
    }
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
    let me = &w.state.ships[ship as usize];
    let (mvx, mvy) = (me.vx as f32 / 65536.0, me.vy as f32 / 65536.0);
    for i in 0..w.state.weapon_count as usize {
        let p = &w.state.weapons[i];
        if p.life == 0 || p.owner == ship || p.team == team {
            continue;
        }
        let (px, py) = (p.x as f32 / 256.0 - mx, p.y as f32 / 256.0 - my);
        let (vx, vy) = (p.vx as f32 / 65536.0, p.vy as f32 / 65536.0);
        // Closest approach belongs in this hull's moving frame. Using world
        // velocity made a fast pilot dodge rounds it was outrunning and miss
        // rounds that were stationary in world space but closing on it.
        let (rvx, rvy) = (vx - mvx, vy - mvy);
        let vv = rvx * rvx + rvy * rvy;
        if vv < 1e-4 {
            continue;
        }
        // Where it passes closest, and when. A negative time is a round that
        // is already past and receding.
        let t = -(px * rvx + py * rvy) / vv;
        if t < 0.0 || t > HORIZON.min(p.life as f32) {
            continue;
        }
        let (cx, cy) = (px + rvx * t, py + rvy * t);
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
    /// The quiet corner a pilot on its way out is heading for. Its own kind
    /// rather than a roam, because giving up on it means picking a different
    /// corner and giving up on a roam means rolling a new point.
    Leave = 4,
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
    /// The same flight controller with a different reason. Keeping recovery
    /// visible lets the drill distinguish a pilot preserving a life from one
    /// that is merely crossing the map.
    Recover(f32, f32, f32, f32),
    /// Hold station on the last foe seen, at this range, and shoot it.
    Fight(f32),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Posture {
    Normal,
    Disengaging,
    Recovering,
}

#[derive(Clone, Copy)]
enum Choice {
    Flag(f32, f32),
    Prize(Prize),
    Foe(Foe),
}

/// A pilot told to stand down, and how far through leaving it is.
///
/// Leaving is a state rather than a moment because the moment never came. The
/// old rule was "go when dead or when nobody is in sight, and go anyway after
/// ten seconds", with the pilot fighting at full strength the whole time: in a
/// busy room nobody is ever out of sight, so what fired was the timer, and what
/// a player saw was an opponent blinking out of a duel.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Exit {
    /// Not going anywhere.
    Staying,
    /// Told to go, and seeing out the fight it was already in. A pilot that
    /// turns and runs the instant it is told to leave reads as fleeing, and
    /// takes a kill the player had earned away with it.
    Breaking,
    /// Out of contact and on the way to somewhere quiet.
    Leaving,
    /// Arrived, and waiting to be sure of it.
    Parked,
}

/// How long a departing pilot may go on fighting before it breaks off anyway,
/// in ticks. Fifteen seconds: long enough that most fights finish on their own
/// terms, short enough to leave the flight out inside the whole budget, which
/// is `DEPART_MAX_MS` in the bot server.
const BREAK_OFF_TICKS: u32 = 1_500;
/// How far a pilot will look for somewhere to leave from, in pixels. Not much
/// beyond `SIGHT`, which is the whole requirement: leaving quietly means being
/// off the radar of everyone who was watching.
///
/// Reaching further costs more than it buys. A route across this much of a
/// maze is a hundred waypoints of hairpins, and the speed envelope brakes for
/// every one of them: measured on Chaos, a pilot sent 2,400 px away covered
/// 150 px in four seconds and its road distance to the corner did not move at
/// all. A near corner is usually a straight line, and a straight line is flown
/// at speed.
pub const REFUGE_PX: f32 = 1_400.0;
/// Consecutive clear looks before a parked pilot closes its socket. Two, so a
/// foe crossing the edge of sight on the wrong tick does not produce a logoff
/// in front of them.
const PARKED_LOOKS: u32 = 2;
/// How near the chosen spot counts as arrived. Twenty tiles, the same as a
/// roam point, and for the same reason: this is a corner to end up in, not a
/// coordinate to hit. At a cell and a half the pilot flew a route of a hundred
/// waypoints, passed within six hundred pixels, missed the window, and gave up
/// on a corner it had essentially reached.
const REFUGE_ARRIVE_PX: f32 = 320.0;

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
    posture: Posture,
    shelter: Option<(f32, f32)>,
    retreat_started: u32,
    retreat_completed: u32,
    retreat_ticks: u64,
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
    blocked: [u32; 5],
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
    /// The unstick reflex's state: ticks spent pushing without moving, and
    /// until when the escape it triggered owns the controls.
    pinned: u32,
    detour_until: u32,
    detour_dir: f32,
    /// Where the reflex last fired and when, so firing again in the same spot
    /// can be told apart from firing somewhere new. The first is a plan that
    /// keeps not working; the second is ordinary flying.
    pin_site: (f32, f32),
    pin_seen: u32,
    /// How many escapes deep this pilot is: pinning during a detour means the
    /// escape itself hit a wall, and each link widens the next throw.
    detour_chain: u32,
    /// How far through leaving this pilot is, the tick it was told to, and how
    /// many clear looks it has had since parking.
    exit: Exit,
    exit_at: u32,
    parked_for: u32,
    /// Where it is going to log off. Chosen by whoever holds the world, at the
    /// moment this pilot breaks contact; see `wants_refuge`.
    refuge: Option<(f32, f32)>,
    /// Where it broke contact, and whether it has since put a full sight
    /// radius between itself and there.
    ///
    /// That, and not arrival, is what leaving actually asks for. A pilot that
    /// has flown out of the fight and can see nobody has left properly whether
    /// or not it reached the particular corner it set out for, and on a map of
    /// tight corridors it often will not: the corner is the direction, the
    /// distance is the requirement.
    left_from: (f32, f32),
    went_far: bool,
    /// Corners it set out for and could not get to. Handed to the next search
    /// alongside the people, because what a departing pilot wants is distance
    /// from these just as much: without it the same unreachable corner wins
    /// the ranking again and the pilot spends its whole budget re-choosing it.
    tried: Vec<(f32, f32)>,
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
            posture: Posture::Normal,
            shelter: None,
            retreat_started: 0,
            retreat_completed: 0,
            retreat_ticks: 0,
            seed: 0x9e3779b9 ^ ((ship as u32) << 16),
            seen: Scan::default(),
            seen_at: 0,
            aim: (0.0, 0.0),
            dist: 0.0,
            roam: (0.0, 0.0),
            goal: None,
            best_dist: 0.0,
            best_at: 0,
            blocked: [0; 5],
            path: Vec::new(),
            at: 0,
            path_to: (0.0, 0.0),
            corner: Vec::new(),
            suffix: Vec::new(),
            pinned: 0,
            detour_until: 0,
            detour_dir: 0.0,
            pin_site: (0.0, 0.0),
            pin_seen: 0,
            detour_chain: 0,
            exit: Exit::Staying,
            exit_at: 0,
            parked_for: 0,
            refuge: None,
            left_from: (0.0, 0.0),
            went_far: false,
            tried: Vec::new(),
        }
    }

    /// Told to stand down. From here the pilot is leaving: it will see out the
    /// fight it is in, break off, fly somewhere nobody is, and stop there.
    ///
    /// Idempotent, because the supervisor may say so more than once and the
    /// clock this starts is the whole budget for going.
    pub fn stand_down(&mut self) {
        if self.exit == Exit::Staying {
            self.exit = Exit::Breaking;
            self.exit_at = self.timer;
        }
    }

    /// Whether this pilot is out of contact and still has nowhere to go. The
    /// caller answers with `refuge`, because choosing a quiet corner needs the
    /// positions of everybody in the room and this file is only ever handed
    /// one pilot's view of it.
    pub fn wants_refuge(&self) -> bool {
        self.exit == Exit::Leaving && self.refuge.is_none()
    }

    /// Corners this pilot has already failed to reach, to be weighed with the
    /// people when choosing the next one.
    pub fn avoid(&self) -> &[(f32, f32)] {
        &self.tried
    }

    /// Where to go and stop. `None` means there was nowhere reachable, which
    /// is not a failure: the pilot parks where it stands and waits for the
    /// room to empty around it, which is what leaving used to be.
    pub fn refuge(&mut self, at: Option<(f32, f32)>) {
        match at {
            Some(p) => self.refuge = Some(p),
            None => self.exit = Exit::Parked,
        }
    }

    /// Whether this pilot has finished leaving and its socket can close. True
    /// once it has parked somewhere quiet and stayed sure of it, which is the
    /// graceful ending; the caller's own ceiling is what covers the rest.
    pub fn departed(&self) -> bool {
        self.parked_for >= PARKED_LOOKS && (self.exit == Exit::Parked || self.went_far)
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
    /// that is 90% traveling is a roster that never finds anybody, and that
    /// is not visible from the outside: a bot flying hard at nothing looks
    /// exactly like a bot flying hard at somebody.
    pub fn doing(&self) -> usize {
        // Leaving first, because from the outside it looks exactly like
        // traveling and a roster quietly spending its life walking out is the
        // failure this counter exists to make visible.
        if self.exit != Exit::Staying {
            return 4;
        }
        match self.mode {
            Mode::Idle => 0,
            Mode::Travel(..) => 1,
            Mode::Fight(_) => 2,
            Mode::Recover(..) => 3,
        }
    }

    pub fn retreats_started(&self) -> u32 {
        self.retreat_started
    }

    pub fn retreats_completed(&self) -> u32 {
        self.retreat_completed
    }

    pub fn retreat_ticks(&self) -> u64 {
        self.retreat_ticks
    }

    pub fn horizon_clear(&self) -> bool {
        !self.seen.company && self.seen.flag.is_none()
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
        if o.alive && self.posture != Posture::Normal {
            self.retreat_ticks += 1;
        }
        if fresh.is_some() {
            // A fresh look is a fresh estimate, right or wrong.
            self.jitter = (self.rand() - 0.5) * self.aim_err;
        }
        if let Some(s) = fresh {
            self.seen = s;
            self.seen_at = self.timer;
            // Being sure, rather than being lucky for one tick. A foe that
            // wanders back into sight resets the count, so a pilot only
            // vanishes from somewhere that has stayed empty.
            if matches!(self.exit, Exit::Leaving | Exit::Parked) && self.horizon_clear() {
                self.parked_for += 1;
            } else {
                self.parked_for = 0;
                // Somebody found the corner, so it is not one. A parked pilot
                // sits still with its trigger shut, which makes staying put
                // an offer of a free kill that whoever found it has no reason
                // to decline: measured on alpha, an enemy held station within
                // 400 px for three thousand ticks while the pilot waited for a
                // quiet it was never going to get, and the departure ended on
                // the bot server's 40-second backstop rather than on its own
                // terms. Somewhere else instead, with this corner on the list
                // not to choose again. Leaving is what keeps its distance;
                // parking is only ever the last few seconds of it.
                if self.exit == Exit::Parked {
                    self.exit = Exit::Leaving;
                    if let Some(p) = self.refuge.take() {
                        if self.tried.len() < 4 {
                            self.tried.push(p);
                        }
                    }
                    self.drop_route();
                }
            }
        }
        self.timer += 1;

        // The unstick reflex. Everything above the engine can be wrong about
        // a wall -- the whiskers sample, the router's cells are two tiles,
        // corners are knife edges, doors move -- but a hull that has been
        // pushing for a third of a second and going nowhere is not an
        // estimate. When that happens, stop arguing with the map: turn to the
        // openest direction there is and fly that way for most of a second,
        // then resume. It is what a person does when they find themselves
        // nosed into a corner, and it backstops every geometric case this
        // file gets subtly wrong, which by construction it cannot enumerate.
        let out = if o.alive && self.timer < self.detour_until {
            self.aim = (0.0, 0.0);
            let (dx, dy) = (self.detour_dir.sin(), -self.detour_dir.cos());
            self.seek(o, (dx * o.top, dy * o.top), (dx * 100.0, dy * 100.0))
        } else {
            if self.timer % self.react == 0 {
                self.decide(o, nav);
                self.breaking_off((o.x, o.y));
            }
            self.drive(o) | self.trigger(o) | self.charge(o)
        };
        // The bookkeeping runs on whatever is actually being flown, the
        // escape included: an escape that is itself pinned has to be noticed,
        // or one bad direction choice becomes a hole a bot never leaves.
        if o.alive && out & sim::BTN_THRUST != 0 && (o.vx * o.vx + o.vy * o.vy).sqrt() < 0.4 {
            self.pinned += 1;
            if self.pinned > 35 {
                self.pinned = 0;
                let c = self.seen.clear;
                let mut best = 0;
                for k in 0..WHISKERS {
                    if c[k] > c[best] {
                        best = k;
                    }
                }
                // Pinning while a detour owns the controls means the escape
                // itself hit a wall. Each link in that chain throws wider,
                // because the openest whisker got us here: in a slot where
                // every ray is short, "openest plus a little jitter" names
                // nearly the same wall every time, and a bot was measured
                // re-detouring in place for twenty-eight seconds on the
                // strength of it. The third link stops throwing altogether
                // and hands the controls back to the plan, which by then is
                // aiming somewhere routed rather than somewhere pointed at.
                let chained = self.timer < self.detour_until;
                self.detour_chain = if chained { self.detour_chain + 1 } else { 1 };
                let spread = 0.5 + 0.7 * (self.detour_chain - 1) as f32;
                self.detour_dir = best as f32 * std::f32::consts::TAU / WHISKERS as f32
                    + (self.rand() - 0.5) * spread.min(2.4);
                // Long enough to turn fully round and then actually fly:
                // half a rotation alone is most of a second.
                self.detour_until = if self.detour_chain >= 3 {
                    self.timer
                } else {
                    self.timer + 130
                };
                // Pinned here before, and recently: the escape flew, the plan
                // resumed, and the plan led straight back. The third pass is
                // not going to end differently, so the destination is what has
                // to change. Measured before this existed: a bot that
                // respawned near one bad corner on Chaos unstuck at the same
                // wall every 250 ticks for as long as the run lasted, drifting
                // a hundred pixels a cycle, which from a cockpit is a bot
                // sitting still. The roam that replaces the one being given up
                // on goes out the open way instead of being rolled from the
                // middle of the map, because the middle of the map is the
                // direction the wall is in.
                let (dx, dy) = (o.x - self.pin_site.0, o.y - self.pin_site.1);
                let again = dx * dx + dy * dy < 200.0 * 200.0
                    && self.timer.saturating_sub(self.pin_seen) < 700;
                self.pin_site = (o.x, o.y);
                self.pin_seen = self.timer;
                self.roam = (0.0, 0.0);
                if again {
                    // Somewhere genuinely else, found the way the departure
                    // search finds a quiet corner: reachable by the grid's own
                    // reckoning and validated against a real route, with the
                    // pin site as the thing to be far from. A straight ray
                    // was tried first and could not work; a pocket you need
                    // unsticking from is a pocket with no 300-pixel straight
                    // line out of it, or you would not be pinned in it.
                    if let Some(p) = nav.refuge((o.x, o.y), &[(o.x, o.y)], 1200.0, false) {
                        self.roam = p;
                    }
                }
                // The route is dropped either way: it was derived from a
                // picture that just proved wrong about a wall. The approach in
                // progress is deliberately NOT dropped, because its no-progress
                // clock is what abandons an unreachable goal, and resetting it
                // on every escape would let pin-and-escape cycles stretch that
                // give-up out for ever.
                self.drop_route();
            }
        } else {
            self.pinned = 0;
        }
        out
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
        ((w.0 - me.0) * (w.0 - me.0) + (w.1 - me.1) * (w.1 - me.1)).sqrt() + self.suffix[self.at]
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
            self.suffix[i] =
                self.suffix[i + 1] + ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).sqrt();
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
    /// A small common floor keeps every pilot from shooting itself to death.
    /// Skill changes how quickly a pilot recognizes the need to disengage, not
    /// how long it refuses a good shot while still sitting in the fight.
    fn reserve(&self) -> f32 {
        0.20
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
        // Past breaking off, this pilot is not playing any more. Shooting on
        // the way out is how a departure stops reading as one.
        if matches!(self.exit, Exit::Leaving | Exit::Parked) {
            return 0;
        }
        // Energy is health and ammunition in one pool, so knowing when to
        // stop shooting is the whole game. A pilot who fires whenever the
        // shot is on sits permanently at their floor and dies to the first
        // round that lands. The retreat state protects the rest of the bar.
        if o.energy <= self.reserve() {
            return 0;
        }
        if self.posture != Posture::Normal
            && (o.energy <= self.reserve() + 0.06 || self.dist >= 300.0)
        {
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
        if self.posture != Posture::Normal {
            return sim::BTN_FIRE;
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
        // In a duel, a healthy target is better served by the gun. The bomb's
        // cost buys area denial, a crowd hit, or a finish that prevents the
        // target rebuilding its bar. Throwing it on cooldown at one healthy
        // pilot was a skill penalty disguised as a skill feature.
        let finisher = self.seen.foe.map_or(false, |f| f.energy < 0.38);
        if self.seen.hostiles_near < 2 && !finisher {
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
    /// The one transition that cannot be made inside `decide`, because it
    /// depends on what `decide` just settled on.
    ///
    /// A pilot told to leave keeps fighting while it is fighting: turning tail
    /// the instant it is told reads as running away and takes a kill the other
    /// pilot had earned. The moment the fight is over, it goes. `BREAK_OFF_TICKS`
    /// is the backstop for the fight that never ends, and the whole reason the
    /// budget above it is generous enough to fly somewhere afterwards.
    fn breaking_off(&mut self, from: (f32, f32)) {
        if self.exit != Exit::Breaking {
            return;
        }
        let done = !matches!(self.mode, Mode::Fight(_))
            || self.timer.saturating_sub(self.exit_at) > BREAK_OFF_TICKS;
        if done {
            self.exit = Exit::Leaving;
            self.left_from = from;
            // The plan it was flying belonged to the game it is no longer in.
            self.goal = None;
            self.drop_route();
        }
    }

    /// Fly to the chosen corner and stop there. Nothing else in `decide`
    /// applies once this is running: no flags, no greens, no targets, and the
    /// safe-zone escape above all does not fire, because a safe zone is a
    /// perfectly good place to have gone.
    fn departing(&mut self, o: &Own, nav: &Nav) {
        self.aim = (0.0, 0.0);
        // How far it has got from the fight it left, which is the thing
        // leaving actually asks for. Latched: a pilot that has once been a
        // sight radius clear has left, whatever the corridor does with it
        // afterwards.
        let (gx, gy) = (o.x - self.left_from.0, o.y - self.left_from.1);
        self.went_far |= gx * gx + gy * gy > SIGHT * SIGHT;
        if self.exit == Exit::Parked {
            // Arrived. Sit still and wait to be sure of it.
            self.goal = None;
            self.mode = Mode::Idle;
            return;
        }
        if let Some((rx, ry)) = self.refuge {
            // By the road rather than the wall between, which is what makes
            // the give-up clock below mean "this is not working" rather than
            // "there is a corner in the way".
            let d = self.plot(o, nav, (rx, ry));
            if d < REFUGE_ARRIVE_PX {
                self.exit = Exit::Parked;
                self.goal = None;
                self.mode = Mode::Idle;
                return;
            }
            // The same clock every other approach runs on, and a departing
            // pilot needs it most: it has nothing else it would rather be
            // doing, so an approach that cannot work is one it will fly at
            // until its budget runs out. Measured: a pilot picked a corner
            // 4,000 px away across a map it could not route through, and spent
            // every remaining tick pinned and unsticking in the same corridor.
            self.approaching(Goal::Leave, rx, ry, d, REFUGE_ARRIVE_PX);
            if self.goal.is_some() {
                self.mode = Mode::Travel(rx, ry, REFUGE_ARRIVE_PX, f32::INFINITY);
                return;
            }
            // It stopped closing. Somewhere else, chosen from where this pilot
            // has ended up rather than from where it set out, and with this
            // corner on the list of places not to choose again.
            if self.tried.len() < 4 {
                self.tried.push((rx, ry));
            }
            self.refuge = None;
            self.drop_route();
        }
        // Between corners, or with nowhere reachable to be. Keep moving and
        // stop as soon as nobody is about: that is what leaving was before any
        // of this, and it is still a perfectly good ending. The trigger stays
        // shut either way, which is the half that matters to whoever is
        // watching.
        self.roam(o, nav);
    }

    /// Energy at which this pilot stops trading and protects the life it has
    /// built. Local numbers, incoming fire, carried upgrades, bounty and a flag
    /// make the current life more expensive to gamble. Skill still matters:
    /// a quick pilot notices the crossing several reaction cycles sooner.
    fn retreat_at(&self, o: &Own) -> f32 {
        let value = (o.value as f32 / 60.0).min(1.0);
        let numbers = self
            .seen
            .hostiles_near
            .saturating_sub(self.seen.allies_near.saturating_add(1)) as f32;
        let threat = self
            .seen
            .threat
            .map_or(0.0, |t| if t.eta < 55.0 { 0.07 } else { 0.0 });
        (0.30
            + value * 0.10
            + numbers.min(3.0) * 0.035
            + threat
            + if o.carrying_flag { 0.14 } else { 0.0 })
        .min(0.72)
    }

    fn recovered_at(&self, o: &Own) -> f32 {
        (0.68f32 + if o.carrying_flag { 0.10 } else { 0.0 }).min(0.86)
    }

    fn closest_contact(&self, o: &Own) -> Option<f32> {
        self.seen
            .contacts
            .iter()
            .map(|f| (f.x - o.x).hypot(f.y - o.y))
            .min_by(|a, b| a.total_cmp(b))
    }

    fn should_disengage(&self, o: &Own) -> bool {
        let under_pressure = self.seen.threat.is_some() || !self.seen.contacts.is_empty();
        (under_pressure && o.energy <= self.retreat_at(o))
            || (o.carrying_flag && under_pressure && o.energy < 0.78)
    }

    /// Pick a target, rather than inheriting whichever hostile happened to be
    /// nearest. A wounded pilot, a flag carrier and a valuable life are better
    /// opportunities; walls and distance make a contact worse.
    fn select_foe(&self, o: &Own) -> Option<Foe> {
        self.seen.contacts.iter().copied().max_by(|a, b| {
            let score = |f: Foe| {
                let d = (f.x - o.x).hypot(f.y - o.y);
                (if f.clear { 0.55 } else { 0.0 })
                    + (1.0 - f.energy.clamp(0.0, 1.0)) * 1.1
                    + if f.carrying_flag { 1.4 } else { 0.0 }
                    + (f.value as f32 / 60.0).min(1.0) * 0.25
                    - d / SIGHT * 0.8
            };
            score(*a).total_cmp(&score(*b))
        })
    }

    /// The best green in the small candidate set from the latest look. The
    /// score is highest on a fresh life, rises again when energy is low, and
    /// falls with exposure and travel. That makes greening a build plan rather
    /// than a two-hundred-pixel accident without turning every fight into a
    /// scavenger hunt.
    fn select_prize(&self, o: &Own) -> Option<(Prize, f32)> {
        let build_need = (1.0 - o.build as f32 / 36.0).clamp(0.0, 1.0);
        let reach = if o.build < 12 {
            720.0
        } else if o.energy < 0.55 {
            380.0
        } else {
            480.0
        };
        self.seen
            .prizes
            .iter()
            .copied()
            .filter_map(|p| {
                let d = (p.x - o.x).hypot(p.y - o.y);
                if d > reach {
                    return None;
                }
                let pressure = self
                    .seen
                    .hostiles_near
                    .saturating_sub(self.seen.allies_near);
                let score = 0.25 + build_need * 1.45 + (1.0 - o.energy) * 0.75
                    - d / reach
                    - pressure as f32 * 0.18
                    - if p.clear { 0.0 } else { 0.25 };
                Some((p, score))
            })
            .max_by(|a, b| a.1.total_cmp(&b.1))
    }

    /// Continue a disengagement until the bar is rebuilt and immediate
    /// pressure is gone. This is deliberately sticky: without the separate
    /// exit threshold a bot crosses one energy point, turns back, takes one
    /// hit and turns away again.
    fn survive(&mut self, o: &Own, nav: &Nav) -> bool {
        if self.posture == Posture::Normal && !self.should_disengage(o) {
            return false;
        }
        if self.posture == Posture::Normal {
            self.posture = Posture::Disengaging;
            self.retreat_started += 1;
            self.shelter = None;
            self.goal = None;
            self.drop_route();
        }

        let close = self.closest_contact(o).unwrap_or(f32::INFINITY);
        let immediate = self
            .seen
            .threat
            .map_or(false, |t| t.eta < 65.0 && t.miss < t.blast + o.radius);
        if o.energy >= self.recovered_at(o) && close > 420.0 && !immediate {
            self.posture = Posture::Normal;
            self.retreat_completed += 1;
            self.shelter = None;
            self.goal = None;
            self.drop_route();
            return false;
        }

        self.aim = (0.0, 0.0);
        if o.in_safe {
            self.posture = Posture::Recovering;
            self.mode = Mode::Idle;
            return true;
        }

        // Backing off in open space while never returning fire is an offer to
        // be chased. Use the gun only while the pursuer is close enough to
        // prevent a clean break; once there is room, the route and recharge
        // take over. Bombs remain shut because a retreating pilot is inside
        // the blast geometry it is trying to leave.
        if close < 300.0 {
            if let Some(foe) = self.select_foe(o).filter(|f| f.clear) {
                self.seen.foe = Some(foe);
                self.posture = Posture::Disengaging;
                self.mode = Mode::Fight(370.0);
                return true;
            }
        }

        // A nearby clear green is worth taking during recovery. It may refill
        // energy or recharge immediately, and every other result still makes
        // this life more valuable. It is not worth crossing a firing line for.
        if close > 280.0 {
            if let Some(p) = self
                .seen
                .prizes
                .iter()
                .copied()
                .filter(|p| p.clear && (p.x - o.x).hypot(p.y - o.y) <= 340.0)
                .min_by(|a, b| {
                    (a.x - o.x)
                        .hypot(a.y - o.y)
                        .total_cmp(&(b.x - o.x).hypot(b.y - o.y))
                })
            {
                self.posture = Posture::Recovering;
                self.plot(o, nav, (p.x, p.y));
                self.mode = Mode::Recover(p.x, p.y, 24.0, 1.2);
                return true;
            }
        }

        let foes: Vec<(f32, f32)> = self.seen.contacts.iter().map(|f| (f.x, f.y)).collect();
        let shelter_stale = self.shelter.map_or(true, |p| {
            (p.0 - o.x).hypot(p.1 - o.y) < 180.0 && (close < 360.0 || immediate)
        });
        if shelter_stale {
            self.shelter = nav.refuge((o.x, o.y), &foes, 1_200.0, true);
            if self.shelter.is_none() {
                let (mut ax, mut ay) = (0.0, 0.0);
                for f in &self.seen.contacts {
                    let (dx, dy) = (o.x - f.x, o.y - f.y);
                    let d = (dx * dx + dy * dy).sqrt().max(1.0);
                    ax += dx / d;
                    ay += dy / d;
                }
                if ax.abs() + ay.abs() < 0.01 {
                    let a = self.ship as f32 * 2.399_963;
                    (ax, ay) = (a.sin(), -a.cos());
                }
                let n = (ax * ax + ay * ay).sqrt().max(1.0);
                let edge = sim::MAP_TILES as f32 * 16.0 - 256.0;
                self.shelter = Some((
                    (o.x + ax / n * 700.0).clamp(256.0, edge),
                    (o.y + ay / n * 700.0).clamp(256.0, edge),
                ));
            }
            self.drop_route();
        }
        if let Some((x, y)) = self.shelter {
            let d = self.plot(o, nav, (x, y));
            self.posture = if d < 220.0 && close > 420.0 && !immediate {
                Posture::Recovering
            } else {
                Posture::Disengaging
            };
            self.mode = if self.posture == Posture::Recovering {
                Mode::Recover(x, y, 160.0, 0.0)
            } else {
                Mode::Recover(x, y, 96.0, 1.5)
            };
        } else {
            self.mode = Mode::Idle;
        }
        true
    }

    fn decide(&mut self, o: &Own, nav: &Nav) {
        if !o.alive {
            self.aim = (0.0, 0.0);
            self.goal = None;
            self.mode = Mode::Idle;
            self.posture = Posture::Normal;
            self.shelter = None;
            return;
        }

        // On the way out. Above the safe-zone escape on purpose: a pilot that
        // has parked in one has arrived, and the rule below would fly it back
        // into the middle of the room to be shot at while it waits.
        if matches!(self.exit, Exit::Leaving | Exit::Parked) {
            self.departing(o, nav);
            return;
        }

        if self.survive(o, nav) {
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

        let selected = self.select_foe(o);
        self.seen.foe = selected;

        // Score the useful things in sight. The numbers are deliberately
        // small and legible: the purpose is to compare risk and value, not to
        // bury behavior in a learned model nobody can debug.
        let mut choice: Option<(f32, Choice)> = None;
        let mut offer = |score: f32, candidate: Choice| {
            if choice.map_or(true, |(best, _)| score > best) {
                choice = Some((score, candidate));
            }
        };
        if let Some((fx, fy)) = self.seen.flag.filter(|_| self.worth_trying(Goal::Flag)) {
            let d = (fx - o.x).hypot(fy - o.y);
            let safe = o.energy > self.retreat_at(o) + 0.10
                && self.seen.hostiles_near <= self.seen.allies_near.saturating_add(1);
            if safe {
                offer(1.75 - d / SIGHT * 0.45, Choice::Flag(fx, fy));
            }
        }
        if let Some((p, score)) = self.select_prize(o) {
            if self.worth_trying(Goal::Prize) {
                offer(score, Choice::Prize(p));
            }
        }
        if let Some(foe) = selected.filter(|_| self.worth_trying(Goal::Foe)) {
            let d = (foe.x - o.x).hypot(foe.y - o.y);
            let score = 0.90
                + o.energy * 0.55
                + (1.0 - foe.energy) * 0.75
                + if foe.carrying_flag { 0.8 } else { 0.0 }
                - d / SIGHT * 0.35
                - self
                    .seen
                    .hostiles_near
                    .saturating_sub(self.seen.allies_near) as f32
                    * 0.08;
            offer(score, Choice::Foe(foe));
        }

        let Some((_, choice)) = choice else {
            self.roam(o, nav);
            return;
        };
        let foe = match choice {
            Choice::Flag(fx, fy) => {
                let d = self.plot(o, nav, (fx, fy));
                self.approaching(Goal::Flag, fx, fy, d, 24.0);
                self.mode = Mode::Travel(fx, fy, 24.0, 1.2);
                return;
            }
            Choice::Prize(p) => {
                let d = self.plot(o, nav, (p.x, p.y));
                self.approaching(Goal::Prize, p.x, p.y, d, 24.0);
                self.mode = Mode::Travel(p.x, p.y, 24.0, 1.2);
                return;
            }
            Choice::Foe(foe) => foe,
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

        // Strong pilots preserve a useful firing lane instead of spending
        // their better aim at knife range. Weak pilots overcommit, which is a
        // visible mistake and gives the skill dial leverage in real matches.
        let ideal = 175.0;
        let range = ideal;
        // Inside that range the pilot has arrived and is fighting, so closing no
        // further is the plan working rather than a wall. Only the run in counts
        // as an approach.
        let (ddx, ddy) = (fx - o.x, fy - o.y);
        self.approaching(
            Goal::Foe,
            fx,
            fy,
            (ddx * ddx + ddy * ddy).sqrt(),
            ideal * 1.15,
        );
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
            Mode::Travel(dx, dy, arrive, vend) | Mode::Recover(dx, dy, arrive, vend) => {
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
                    (
                        self.path[self.at],
                        self.corner[self.at],
                        self.suffix[self.at],
                    )
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
                let want = if d > 1e-3 {
                    (sx / d * v, sy / d * v)
                } else {
                    (0.0, 0.0)
                };
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
                // Nose to nose, which a shared spawn hands out exactly: a
                // respawn puts a ship back on its own `spawn_x, spawn_y`, so
                // two pilots holding one spawn sit on the same coordinate to
                // the pixel. A line of zero length has no direction, and
                // everything below divides by it: the stand-off point collapses
                // onto the pilot itself, the wanted velocity comes out zero,
                // and the aim vector comes out zero too, which is the sentinel
                // for "no shot". Both pilots then press nothing, neither moves,
                // and nothing in the loop perturbs them: a heap of bots sitting
                // on a spawn until somebody shoots one loose.
                //
                // So when there is no line, this pilot invents one. Per ship
                // rather than per tick, because a bearing re-rolled every tick
                // is a pilot shaking rather than leaving, and spread by the
                // golden angle so that two who spawned together, facing the
                // same way, with the same hull, still part.
                let raw = (dx * dx + dy * dy).sqrt();
                let (dx, dy, dist) = if raw < 1.0 {
                    let a = self.ship as f32 * 2.399_963;
                    (a.sin(), -a.cos(), 1.0)
                } else {
                    (dx, dy, raw)
                };
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
    /// Not a separate behavior with its own buttons: a dodge is a different
    /// answer to "where do I want to be going", and putting it here means it
    /// composes with whatever the pilot was already doing rather than
    /// interrupting it.
    fn sidestep(&self, o: &Own, wx: f32, wy: f32) -> (f32, f32) {
        let Some(t) = self.seen.threat else {
            return (wx, wy);
        };
        let age = self.timer.saturating_sub(self.seen_at) as f32;
        if t.eta - age > 45.0 {
            return (wx, wy);
        }
        let (rx, ry) = (t.x + t.vx * age - o.x, t.y + t.vy * age - o.y);
        let (rvx, rvy) = (t.vx - o.vx, t.vy - o.vy);
        let vv = rvx * rvx + rvy * rvy;
        if vv < 1e-4 {
            return (wx, wy);
        }
        // Where it will pass, relative to this hull.
        let tc = -(rx * rvx + ry * rvy) / vv;
        if tc < 0.0 {
            return (wx, wy);
        }
        let (cx, cy) = (rx + rvx * tc, ry + rvy * tc);
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
            (-rvy / s, rvx / s)
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
    /// Bend a wanted velocity around what the whiskers say is a wall.
    ///
    /// The straight line stays the plan whenever it is clear enough: `need`
    /// is the distance to the steer point or a hull's worth of stopping room,
    /// whichever is less, so a point-blank fight never bends. When it is not
    /// clear, the nearest sufficiently open ray wins, tried outward from the
    /// straight line a step at a time starting on the side with more room.
    /// When no ray is open enough, the openest one wins, which in a dead end
    /// is straight back out of it.
    ///
    /// This is the short-range half of not hitting walls; the router is the
    /// long-range half. The router flies legs between two-tile cell centers
    /// and knows nothing about the wall eight pixels off the bow mid-leg,
    /// which is exactly the distance this answers.
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

    fn seek(&mut self, o: &Own, want: (f32, f32), ahead: (f32, f32)) -> u16 {
        let (wx, wy) = self.sidestep(o, want.0, want.1);
        // Walls outrank everything the velocity was chosen for, the dodge
        // included: a sidestep into a wall is still a wall.
        let wlen = (wx * wx + wy * wy).sqrt();
        let (wx, wy) = if wlen > DEAD {
            let d = (ahead.0 * ahead.0 + ahead.1 * ahead.1).sqrt();
            let bent = self.bend(wx.atan2(-wy), d);
            (bent.sin() * wlen, -bent.cos() * wlen)
        } else {
            (wx, wy)
        };
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

/// The closest greens this pilot might reasonably reach.
///
/// Distance finds a small candidate set cheaply. Line of sight is recorded on
/// those candidates rather than used as a hard filter: a fresh pilot may route
/// around a corner for a useful green, while a recovering pilot only takes one
/// with a clear escape line. The decision layer makes that trade after adding
/// build progress and enemy pressure.
fn nearest_prizes(w: &World, mx: f32, my: f32, within: f32, keep: usize) -> Vec<Prize> {
    let mut best: Vec<(f32, f32, f32)> = Vec::with_capacity(keep + 1);
    for p in w.state.prizes.iter() {
        if p.active == 0 {
            continue;
        }
        let (px, py) = (p.x as f32 / 256.0, p.y as f32 / 256.0);
        let d2 = (px - mx) * (px - mx) + (py - my) * (py - my);
        if d2 > within * within {
            continue;
        }
        let at = best.partition_point(|b| b.0 < d2);
        if at < keep {
            best.insert(at, (d2, px, py));
            best.truncate(keep);
        }
    }
    best.into_iter()
        .map(|(_, x, y)| Prize {
            x,
            y,
            clear: clear_line(w, mx, my, x, y),
        })
        .collect()
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
    /// cockpit. Whiskers and the unstick reflex alone measured 0.0%; the
    /// merged brain carries those plus the router and the velocity control
    /// layer, and this bound holds it to the same standard.
    #[test]
    fn bots_do_not_grind_walls_on_a_real_map() {
        let bytes = std::fs::read("../catalog/zones/alpha/alpha.vwmap")
            .expect("the alpha map ships in this repository");
        let mut w = sim::World::from_packed(0x5eed, &bytes).expect("a map");
        let mut bots = Vec::new();
        for i in 0..10usize {
            let e = individual(i);
            let ship = w.spawn_on_map(e.class, (i % 2) as u8, i as u32 / 2, 0);
            assert!(ship >= 0, "a seat on the map");
            let mut b = Bot::new(ship as u8, e.skill);
            b.reseed(i as u32 * 977 + 13);
            bots.push(b);
        }

        let route = crate::nav::Nav::build(&w.map);
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
                let buttons = b.think(&own(&w, ship), &route, fresh);
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
        println!(
            "grinding {grinding} of {alive_ticks} alive bot-ticks \
                  ({:.1}%)",
            share * 100.0
        );
        assert!(
            share < 0.02,
            "bots spend {:.1}% of their lives pushing into walls",
            share * 100.0
        );
    }

    /// A safe patch in the middle of open ground, to duck into.
    fn safe_pocket(m: &mut sim::sim_map) {
        for ty in 500..510 {
            for tx in 500..510 {
                m.tile[ty * sim::MAP_TILES + tx] = 2; // SIM_TILE_SAFE
            }
        }
    }

    #[test]
    fn nobody_is_a_target_while_they_stand_in_a_safe_zone() {
        let mut w = sim::World::with_map(0x5eed, safe_pocket);
        let me = w.spawn(0, 0, 480, 505, 0);
        let them = w.spawn(0, 1, 520, 505, 0);
        assert!(me >= 0 && them >= 0, "two seats");

        assert!(
            scan(&w, me as u8).foe.is_some(),
            "somebody on open ground is a target"
        );

        // The same pilot, one tile inside the safe. Nothing can be shot into
        // one, so a bot that kept them selected would hold station outside the
        // door with its trigger shut for as long as they cared to stand there.
        let s = &mut w.state.ships[them as usize];
        s.x = 505 * 16 * 256;
        s.y = 505 * 16 * 256;
        assert!(
            scan(&w, me as u8).foe.is_none(),
            "somebody standing in a safe zone is not"
        );

        // And the moment they step out again they are.
        let s = &mut w.state.ships[them as usize];
        s.x = 520 * 16 * 256;
        assert!(scan(&w, me as u8).foe.is_some(), "back out, back on");
    }

    /// Leaving, end to end, on a real map: told to stand down, seeing out the
    /// fight, flying somewhere nobody is, and stopping there.
    ///
    /// The failure this holds off is the one a player reports as a bot
    /// vanishing mid-duel. It cannot be seen in one frame and it cannot be
    /// seen from the roster, because both ends look identical either way: what
    /// differs is where the pilot was and what it was doing on the way out.
    ///
    /// Eight salts rather than one, because the interesting failures here are
    /// about where the other seven pilots happen to be standing, and one seed
    /// samples one arrangement of them. The seed this started on went green
    /// while a departing pilot was being camped in its corner for three
    /// thousand ticks on every other seed there is.
    /// One run of the departure drill, on the arrangement of pilots this
    /// salt produces. Failures name the salt, because which one broke is
    /// the whole of the reproduction.
    fn a_departure(salt: u32) {
        let bytes = std::fs::read("../catalog/zones/alpha/alpha.vwmap")
            .expect("the alpha map ships in this repository");
        let mut w = sim::World::from_packed(salt, &bytes).expect("a map");
        let mut bots = Vec::new();
        for i in 0..8usize {
            let e = individual(i);
            let ship = w.spawn_on_map(e.class, (i % 2) as u8, i as u32 / 2, 0);
            assert!(ship >= 0, "a seat on the map");
            let mut b = Bot::new(ship as u8, e.skill);
            b.reseed(i as u32 * 977 + 13);
            bots.push(b);
        }
        let route = crate::nav::Nav::build(&w.map);

        // Long enough that the room is a going concern and the pilot being
        // sent home is in the middle of something.
        let mut inputs = Vec::new();
        let run = |w: &mut sim::World,
                   bots: &mut Vec<Bot>,
                   inputs: &mut Vec<sim::sim_input>,
                   ticks: u32,
                   mut watch: Option<&mut dyn FnMut(&Bot, u16)>| {
            for _ in 0..ticks {
                inputs.clear();
                for b in bots.iter_mut() {
                    let ship = b.ship;
                    let fresh = b.looks_due().then(|| scan(w, ship));
                    let o = own(w, ship);
                    if b.wants_refuge() {
                        let mut c = crowd(w, ship);
                        c.extend_from_slice(b.avoid());
                        b.refuge(route.refuge((o.x, o.y), &c, REFUGE_PX, true));
                    }
                    let buttons = b.think(&o, &route, fresh);
                    if let Some(watch) = watch.as_deref_mut() {
                        watch(b, buttons);
                    }
                    inputs.push(sim::sim_input { ship, buttons });
                }
                w.step(inputs);
            }
        };
        run(&mut w, &mut bots, &mut inputs, 3_000, None);

        bots[0].stand_down();
        let leaver = bots[0].ship;
        // Every tick the leaver spends past breaking off, and whether it ever
        // pulled a trigger there. Shooting on the way out is how a departure
        // stops reading as one.
        let mut shot_while_going = 0u32;
        let mut going_ticks = 0u32;
        let mut done_at = None;
        for t in 0..4_000u32 {
            {
                let mut watch = |b: &Bot, buttons: u16| {
                    if b.ship == leaver && matches!(b.exit, Exit::Leaving | Exit::Parked) {
                        going_ticks += 1;
                        if buttons & (sim::BTN_FIRE | sim::BTN_BOMB) != 0 {
                            shot_while_going += 1;
                        }
                    }
                };
                run(&mut w, &mut bots, &mut inputs, 1, Some(&mut watch));
            }
            if bots[0].departed() {
                done_at = Some(t);
                break;
            }
        }

        let done_at = done_at.expect(&format!(
            "salt {salt:#x}: a pilot told to leave never finished leaving"
        ));
        // 40 seconds is the bot server's ceiling. Reaching it is the backstop
        // firing, not the ordinary way out, so this asserts the ordinary way
        // out actually happens.
        assert!(
            done_at < 4_000,
            "salt {salt:#x}: left after {done_at} ticks"
        );
        assert!(
            going_ticks > 100,
            "salt {salt:#x}: it flew somewhere: only {going_ticks} ticks spent leaving"
        );
        assert_eq!(
            shot_while_going, 0,
            "salt {salt:#x}: the trigger stays shut once a pilot is on its way out"
        );

        // And it ended up somewhere nobody is. Sight is 960 px, so clearing it
        // is the whole point: a pilot that logs off inside somebody's radar
        // has popped in front of them however politely it got there.
        //
        // Somebody, not something. A ship waiting to respawn is still active
        // and still sitting at the coordinates it died on, and it is watching
        // nothing at all -- `scan` skips the dead when it decides a horizon is
        // clear, so counting them here asked the departure for a quiet the
        // code never promised and does not owe. This measured a corpse 820 px
        // from a pilot that had correctly waited for an empty room.
        let me = &w.state.ships[leaver as usize];
        let (mx, my) = (me.x as f32 / 256.0, me.y as f32 / 256.0);
        let mut nearest = f32::INFINITY;
        for b in bots.iter().skip(1) {
            let o = &w.state.ships[b.ship as usize];
            if o.active == 0 || o.alive == 0 {
                continue;
            }
            let (dx, dy) = (o.x as f32 / 256.0 - mx, o.y as f32 / 256.0 - my);
            nearest = nearest.min((dx * dx + dy * dy).sqrt());
        }
        assert!(
            nearest > SIGHT,
            "salt {salt:#x}: logged off {nearest:.0} px from somebody, inside their sight"
        );
    }

    /// Leaving, end to end, on a real map: told to stand down, seeing out the
    /// fight, flying somewhere nobody is, and stopping there.
    ///
    /// The failure this holds off is the one a player reports as a bot
    /// vanishing mid-duel. It cannot be seen in one frame and it cannot be
    /// seen from the roster, because both ends look identical either way: what
    /// differs is where the pilot was and what it was doing on the way out.
    ///
    /// Eight salts rather than one, because what makes this hard is where the
    /// other seven pilots happen to be standing, and one seed samples one
    /// arrangement of them. The seed this started on stayed green while every
    /// other seed had a departing pilot camped in its corner for three
    /// thousand ticks.
    #[test]
    fn a_pilot_told_to_leave_flies_away_before_it_goes() {
        for salt in [0x5eed, 1, 2, 3, 4, 5, 6, 7] {
            a_departure(salt);
        }
    }

    /// The failure a player reports as "bots sit still until I shoot at
    /// them", measured as the longest run of ticks any bot spends alive, in
    /// travel, and not moving. Four minutes of the shipped Chaos map with the
    /// calibrated roster: before the unstick reflex learned to escalate, this
    /// harness measured freezes of 1,473, 7,327 and 1,818 ticks across three
    /// salts, the worst of them a minute and a quarter of a bot standing
    /// against a wall re-firing the same escape. The bound is three times the worst this
    /// code measures now and eight times an ordinary corner scrape, so it
    /// catches the loop coming back without breaking on tuning noise.
    #[test]
    fn nobody_stands_still_for_twelve_seconds() {
        let bytes = std::fs::read("../catalog/zones/alpha/alpha.vwmap").unwrap();
        let mut w = sim::World::from_packed(0x5eed, &bytes).unwrap();
        // Match the two Alpha settings that reshape this drill. The map alone
        // builds baseline settings, whose thirty-item opening kit produces a
        // different sequence of fights and deaths than the shipped room.
        w.cfg.spawn_prizes = 0;
        w.cfg.prize_delay = 700;
        let mut bots = Vec::new();
        for i in 0..24usize {
            let e = individual(i);
            let ship = w.spawn_on_map(e.class, (i % 2) as u8, i as u32 / 2, 0);
            let mut b = Bot::new(ship as u8, e.skill);
            b.reseed(i as u32 * 977 + 13);
            bots.push(b);
        }
        let route = crate::nav::Nav::build(&w.map);
        let mut inputs = Vec::new();
        let mut streak = vec![0u32; bots.len()];
        let mut worst = vec![0u32; bots.len()];
        for _ in 0..24_000u32 {
            inputs.clear();
            for b in bots.iter_mut() {
                let ship = b.ship;
                let fresh = b.looks_due().then(|| scan(&w, ship));
                let buttons = b.think(&own(&w, ship), &route, fresh);
                inputs.push(sim::sim_input { ship, buttons });
            }
            w.step(&inputs);
            for (bi, b) in bots.iter().enumerate() {
                let s = &w.state.ships[b.ship as usize];
                let (vx, vy) = (s.vx as f32 / 65536.0, s.vy as f32 / 65536.0);
                // Stationary while alive and trying to travel: the shape a
                // player reads as a bot sitting still.
                if s.active != 0
                    && s.alive != 0
                    && b.doing() == 1
                    && (vx * vx + vy * vy).sqrt() < 0.4
                {
                    streak[bi] += 1;
                    worst[bi] = worst[bi].max(streak[bi]);
                } else {
                    streak[bi] = 0;
                }
            }
        }
        let bad = worst.iter().copied().max().unwrap_or(0);
        assert!(
            bad < 1_200,
            "a bot stood still in travel for {bad} ticks; the pin loop \
is back"
        );
    }

    /// Two enemies at the same coordinate, which is what a shared spawn point
    /// hands out: a respawn puts a ship back at exactly `spawn_x, spawn_y`, so
    /// a pile at a spawn is the ordinary case rather than a freak one.
    ///
    /// The stand-off geometry divides the line to the target by its own
    /// length. At zero length that line has no direction: the station point
    /// collapses onto the pilot's own position, the wanted velocity is zero,
    /// and the aim vector is zero too, which shuts the trigger. So both pilots
    /// press nothing, neither moves, and nothing in the loop ever perturbs
    /// them. A player watching sees a heap of bots sitting on the spawn until
    /// a shot knocks one loose and the arithmetic starts working again.
    #[test]
    fn two_pilots_on_the_same_spot_do_not_freeze_each_other() {
        let mut w = sim::World::new(0x5eed);
        // Same tile, opposite sides, both alive and looking at each other.
        let a = w.spawn(0, 0, 512, 512, 0);
        let b = w.spawn(0, 1, 512, 512, 0);
        assert!(a >= 0 && b >= 0, "two seats");
        let (a, b) = (a as u8, b as u8);
        for s in [a, b] {
            let sh = &mut w.state.ships[s as usize];
            sh.x = 512 * 16 * 256;
            sh.y = 512 * 16 * 256;
            sh.vx = 0;
            sh.vy = 0;
        }
        let route = crate::nav::Nav::build(&w.map);
        let mut bots = vec![Bot::new(a, 0.7), Bot::new(b, 0.7)];
        bots[0].reseed(11);
        bots[1].reseed(29);

        let mut idle = 0u32;
        for _ in 0..600u32 {
            let mut inputs = Vec::new();
            for bot in bots.iter_mut() {
                let ship = bot.ship;
                let fresh = bot.looks_due().then(|| scan(&w, ship));
                let buttons = bot.think(&own(&w, ship), &route, fresh);
                inputs.push(sim::sim_input { ship, buttons });
            }
            if inputs.iter().all(|i| i.buttons == 0) {
                idle += 1;
            }
            w.step(&inputs);
        }

        let apart: f32 = {
            let (p, q) = (&w.state.ships[a as usize], &w.state.ships[b as usize]);
            let dx = (p.x - q.x) as f32 / 256.0;
            let dy = (p.y - q.y) as f32 / 256.0;
            (dx * dx + dy * dy).sqrt()
        };
        assert!(
            idle < 400,
            "both pilots pressed nothing on {idle} of 600 ticks"
        );
        assert!(
            apart > 32.0,
            "two pilots stacked on one spawn never separated: {apart:.0} px \
apart after six seconds"
        );
    }

    #[test]
    fn incoming_rounds_are_solved_in_the_pilots_moving_frame() {
        let mut w = sim::World::new(0x5eed);
        let me = w.spawn(0, 0, 500, 500, 0) as u8;
        let sh = &mut w.state.ships[me as usize];
        sh.vx = 2 * 65536;
        let mx = sh.x as f32 / 256.0;
        let my = sh.y as f32 / 256.0;
        w.state.weapon_count = 1;
        w.state.weapons[0] = sim::sim_weapon {
            owner: 1,
            team: 1,
            x: sh.x + 100 * 256,
            y: sh.y,
            life: 100,
            ..Default::default()
        };

        let threat = incoming(&w, mx, my, 0, me).expect("the pilot is flying into the round");
        assert!((threat.eta - 50.0).abs() < 0.1, "eta was {}", threat.eta);
        assert!(threat.miss < 0.1);
    }

    #[test]
    fn a_damaged_pilot_disengages_and_waits_for_a_real_recovery() {
        let mut w = sim::World::with_map(0x5eed, sim::build_pit);
        let me = w.spawn(0, 0, 500, 500, 0) as u8;
        let foe = w.spawn(0, 1, 525, 500, 32768) as u8;
        let max = w.eff_max_energy(me as usize);
        w.state.ships[me as usize].energy = max * 3 / 10;
        let route = crate::nav::Nav::build(&w.map);
        let mut bot = Bot::new(me, 0.8);
        bot.seen = scan(&w, me);
        bot.decide(&own(&w, me), &route);
        assert_eq!(bot.retreats_started(), 1);
        assert_ne!(bot.posture, Posture::Normal);
        assert_eq!(bot.doing(), 3, "recovery must be visible to the drill");

        w.state.ships[me as usize].energy = max * 6 / 10;
        bot.seen = scan(&w, me);
        bot.decide(&own(&w, me), &route);
        assert_ne!(
            bot.posture,
            Posture::Normal,
            "sixty percent is not recovered"
        );

        w.state.ships[me as usize].energy = max * 9 / 10;
        w.state.ships[foe as usize].x += (SIGHT as i32 + 100) * 256;
        bot.seen = scan(&w, me);
        bot.decide(&own(&w, me), &route);
        assert_eq!(bot.posture, Posture::Normal);
        assert_eq!(bot.retreats_completed(), 1);
    }

    #[test]
    fn a_fresh_pilot_builds_with_reachable_greens() {
        let mut w = sim::World::with_map(0x5eed, sim::build_pit);
        let me = w.spawn(0, 0, 500, 500, 0) as u8;
        w.state.prizes[0] = sim::sim_prize {
            active: 1,
            x: (520 * 16 + 8) * 256,
            y: (500 * 16 + 8) * 256,
            life: 30_000,
        };
        let route = crate::nav::Nav::build(&w.map);
        let mut bot = Bot::new(me, 0.7);
        bot.seen = scan(&w, me);
        bot.decide(&own(&w, me), &route);
        assert!(
            matches!(bot.goal, Some((Goal::Prize, _, _))),
            "a fresh pilot ignored a reachable green"
        );
    }

    #[test]
    fn greening_does_not_override_immediate_survival() {
        let mut w = sim::World::with_map(0x5eed, sim::build_pit);
        let me = w.spawn(0, 0, 500, 500, 0) as u8;
        let _foe = w.spawn(0, 1, 508, 500, 32768);
        let max = w.eff_max_energy(me as usize);
        w.state.ships[me as usize].energy = max / 4;
        w.state.prizes[0] = sim::sim_prize {
            active: 1,
            x: (503 * 16 + 8) * 256,
            y: (500 * 16 + 8) * 256,
            life: 30_000,
        };
        let route = crate::nav::Nav::build(&w.map);
        let mut bot = Bot::new(me, 0.7);
        bot.seen = scan(&w, me);
        bot.decide(&own(&w, me), &route);
        assert_eq!(bot.posture, Posture::Disengaging);
        assert!(!matches!(bot.goal, Some((Goal::Prize, _, _))));
    }
}
