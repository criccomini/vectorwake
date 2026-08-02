//! vectorwake zone server.
//!
//! One arena, ticking at 100 Hz, authoritative over everything that matters.
//! Clients send inputs and nothing else; positions, damage, deaths, and prize
//! pickups are outputs of `sim_step` and cannot be asserted from outside.
//!
//! Transport is WebSocket, which every browser can speak. UDP for native
//! clients is the same message format on a different socket and is not built
//! yet; see docs/architecture/networking.md.

mod ai;
mod calibrate;
mod config;
mod directory;
mod modes;
mod persist;
mod rating;
mod sim;

use std::collections::HashMap;
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;

const TICK_HZ: u64 = 100;
const SNAPSHOT_EVERY: u32 = 5; // 20 Hz
/// How far from a player a prize has to be before it is left out of that
/// player's snapshot, in Q8 pixels. 256 tiles.
///
/// Four times the radar's reach, which is the furthest a client can see one
/// by any means. A hull tops out at 490 px/s and a snapshot period is 50 ms,
/// so a ship covers 24 px between snapshots against 3136 px of margin beyond
/// the radar -- the boundary is not somewhere a player can arrive at.
const PRIZE_INTEREST: i32 = 256 * 16 * 256;
/// Humans a zone admits when its file says nothing. The room may hold more
/// seats than this: `max_ships` sizes the room, and this bounds how many of its
/// seats people get, which is what leaves room for the bot roster.
const DEFAULT_MAX_PLAYERS: usize = 16;

// Client to server
const C2S_JOIN: u8 = 1;
const C2S_INPUT: u8 = 2;
const C2S_SHIP: u8 = 5;
/// Asked by the directory, and by any client that wants to know what a zone
/// is before committing to it. Answerable without joining.
const C2S_STATUS: u8 = directory::STATUS_REQUEST;

// Server to client
const S2C_WELCOME: u8 = 1;
const S2C_SNAPSHOT: u8 = 2;
const S2C_ROSTER: u8 = 3;
const S2C_KILL: u8 = 4;
const S2C_BANNER: u8 = 5;
const S2C_ZONE: u8 = 6;
const S2C_DENIED: u8 = 7;
const S2C_STATUS: u8 = directory::STATUS_REPLY;
/// The map, run-length encoded, sent before the first snapshot. A client
/// predicts collisions locally, so it needs the room before it needs anyone
/// in it.
const S2C_MAP: u8 = 9;
/// The tuning, sent straight after the map and again whenever an operator
/// reloads the zone file. A client that predicts on its own compiled
/// defaults is predicting a different game the moment a zone tunes anything.
const S2C_SETTINGS: u8 = 10;

struct Player {
    ship: u8,
    buttons: u16,
    /// Highest input tick this client has sent, echoed back in snapshots so
    /// it knows how far its prediction has been confirmed.
    last_input_tick: u32,
    name: String,
    tx: mpsc::UnboundedSender<Vec<u8>>,
}

/// Feed one tick's damage into the ledger and hand back the deaths it
/// contained. Shared by the live arena and the offline calibration
/// tournament, so the two cannot disagree about what an event means.
fn ingest_damage(
    world: &sim::World,
    rating: &mut rating::Rating,
    name_of: &dyn Fn(u8) -> String,
) -> Vec<(u8, u8)> {
    let tick = world.state.tick;
    let ev = &*world.events;
    let mut deaths = Vec::new();
    for i in 0..ev.count as usize {
        let e = ev.e[i];
        match e.etype {
            sim::EV_HIT => {
                let (victim, attacker) = (e.a as usize, e.b as usize);
                if victim < sim::MAX_SHIPS && attacker < sim::MAX_SHIPS {
                    let same =
                        world.state.ships[victim].team == world.state.ships[attacker].team;
                    rating.damage(tick, &name_of(e.a), &name_of(e.b), e.v, same);
                }
            }
            sim::EV_DEATH => deaths.push((e.a, e.b)),
            _ => {}
        }
    }
    deaths
}

struct Arena {
    world: sim::World,
    players: HashMap<u64, Player>,
    bots: Vec<ai::Bot>,
    names: HashMap<u8, (String, bool)>, // ship -> (name, is_ai)
    next_id: u64,
    rating: rating::Rating,
    mode: Box<dyn modes::Mode>,
    banner: String,
    finished: bool,
}

impl Arena {
    /// Apply the operator's tuning over a fresh baseline, and report anything
    /// the file asked for that could not be done.
    ///
    /// Rebuilding first is what makes a reload mean the file as it stands
    /// rather than the file plus everything it has ever said: a deleted line
    /// used to stay in force until a restart, and a weapon block would append
    /// another row every time the file was saved.
    fn apply_config(world: &mut sim::World, c: &config::ArenaConfig) -> Vec<String> {
        let mut warn = Vec::new();
        world.reset_settings();
        if c.bounce > 0 { world.cfg.bounce = c.bounce; }
        if c.friction > 0 { world.cfg.friction = c.friction; }
        if c.respawn_delay > 0 { world.cfg.respawn_delay = c.respawn_delay; }
        // The core clamps this to SIM_MAX_SHIPS and reads zero as the ceiling,
        // so a zone asking for more than the array holds gets the array rather
        // than an overflow.
        if let Some(v) = c.max_ships { world.cfg.max_ships = v; }
        if c.prize_delay > 0 { world.cfg.prize_delay = c.prize_delay; }
        if c.prize_max > 0 { world.cfg.prize_max = c.prize_max; }

        // Weapons are named here and numbered in the core. The baseline
        // built one gun and one bomb per hull, so those get the names an
        // operator would guess -- `apex-gun`, `anvil-bomb` -- and anything
        // else in the file is a weapon that did not exist before.
        // A hull's trigger is a ladder now, so every rung gets a name: the
        // first is `apex-gun` and the ones above it are `apex-gun-2` and up,
        // which reads as the level it is.
        let mut named: Vec<(String, u8)> = Vec::new();
        for (i, hull) in ai::CLASS_NAMES.iter().enumerate() {
            let hull: &str = hull;
            let cls = world.cfg.classes[i];
            for (t, trig) in ["gun", "bomb"].iter().enumerate() {
                for (rung, &pat) in cls.trigger[t].iter().enumerate() {
                    if pat == sim::NO_PATTERN { break }
                    let n = if rung == 0 {
                        format!("{}-{trig}", hull.to_lowercase())
                    } else {
                        format!("{}-{trig}-{}", hull.to_lowercase(), rung + 1)
                    };
                    named.push((n, pat));
                }
            }
        }
        if let Some(v) = c.rust { world.cfg.rust_chance = v.min(1000); }
        if let Some(v) = c.spawn_prizes { world.cfg.spawn_prizes = v; }
        if let Some(v) = c.bounty_per_kill { world.cfg.bounty_per_kill = v; }
        if let Some(v) = c.points_per_flag { world.cfg.points_per_flag = v; }
        if let Some(v) = c.multi_energy { world.cfg.mod_multi_energy = v; }
        if let Some(v) = c.multi_delay { world.cfg.mod_multi_delay = v; }
        for (name, v) in &c.prize_weight {
            match Arena::prize_index(name) {
                Some(i) => world.cfg.prize_weight[i] = *v,
                None => warn.push(format!("\"{name}\" is not a prize")),
            }
        }
        // What a rung of each add-on is worth, before any hull is told which
        // ones it may hold.
        for (name, v) in &c.mod_step {
            match Arena::mod_index(name) {
                Some(m) => world.cfg.mod_step[m] = match m {
                    sim::MOD_PROX => v * 256,               // px
                    sim::MOD_PUSH => unsafe { sim::sim_units_speed(*v) },
                    _ => *v,
                },
                None => warn.push(format!("\"{name}\" is not an add-on")),
            }
        }
        // Two passes, because a splinter may name a weapon written later in
        // the file, or one that does not exist until this pass makes it.
        for w in &c.weapons {
            if w.name.is_empty() {
                warn.push("a weapon with no name is a weapon nothing can point at".into());
                continue;
            }
            if named.iter().any(|(n, _)| *n == w.name) { continue; }
            match world.add_weapon() {
                Some(p) => named.push((w.name.clone(), p)),
                None => warn.push(format!("no room in the weapon table for \"{}\"", w.name)),
            }
        }
        for w in &c.weapons {
            let Some(&(_, pat)) = named.iter().find(|(n, _)| *n == w.name) else { continue };
            Arena::apply_weapon(world, &named, pat, w, &mut warn);
        }

        for s in &c.ships {
            let Some(idx) = ai::class_index(&s.name) else {
                warn.push(format!("no hull called \"{}\"", s.name));
                continue;
            };
            for (t, (field, want)) in [("gun", &s.gun), ("bomb", &s.bomb)]
                .into_iter().enumerate()
            {
                let Some(want) = want else { continue };
                // An empty name takes the trigger away, which is how a hull
                // loses its bomb rack rather than being given a free one.
                let pat = if want.is_empty() {
                    Some(sim::NO_PATTERN)
                } else {
                    named.iter().find(|(n, _)| n == want).map(|&(_, p)| p)
                };
                match pat {
                    // Naming one weapon replaces the whole ladder with it, so
                    // a hull given a repel does not level into a bomb.
                    Some(p) => {
                        world.cfg.classes[idx].trigger[t] =
                            [p, sim::NO_PATTERN, sim::NO_PATTERN, sim::NO_PATTERN];
                    }
                    None => warn.push(format!(
                        "{} has no weapon called \"{want}\" to put on its {field}", s.name)),
                }
            }
            for (t, mods) in [&s.gun_mods, &s.bomb_mods].into_iter().enumerate() {
                if mods.is_empty() { continue }
                let mut packed = 0u16;
                for (name, rungs) in mods {
                    match Arena::mod_index(name) {
                        Some(m) => {
                            let n = (*rungs).min(sim::MOD_MAX) as u16;
                            packed |= n << (m * 2);
                        }
                        None => warn.push(format!("\"{name}\" is not an add-on")),
                    }
                }
                world.cfg.classes[idx].mod_max[t] = packed;
            }
            let cls = &mut world.cfg.classes[idx];
            unsafe {
                if let Some(v) = s.speed { cls.max_speed = sim::sim_units_speed(v); }
                if let Some(v) = s.thrust { cls.thrust = sim::sim_units_thrust(v); }
                if let Some(v) = s.rotation { cls.rot = sim::sim_units_rotation(v); }
                if let Some(v) = s.energy { cls.max_energy = sim::sim_units_energy(v); }
                if let Some(v) = s.recharge { cls.recharge = sim::sim_units_recharge(v); }
            }
            // Upgrades climb toward whatever ceiling the operator set.
            cls.init_speed = cls.max_speed * 70 / 100;
            cls.up_speed = (cls.max_speed - cls.init_speed) / 8;
            cls.init_thrust = cls.thrust * 70 / 100;
            cls.up_thrust = (cls.thrust - cls.init_thrust) / 8;
            cls.init_rot = cls.rot * 70 / 100;
            cls.up_rot = (cls.rot - cls.init_rot) / 8;
            cls.init_energy = cls.max_energy * 70 / 100;
            cls.up_energy = (cls.max_energy - cls.init_energy) / 8;
            cls.init_recharge = cls.recharge * 70 / 100;
            cls.up_recharge = (cls.recharge - cls.init_recharge) / 8;
        }
        warn
    }

    /// Prizes are named in a zone file and numbered in the core. The five
    /// stats keep the names the panel shows; a level and an add-on are named
    /// for the trigger they belong to, because both are per trigger.
    fn prize_index(name: &str) -> Option<usize> {
        const STATS: [&str; sim::UP_COUNT] =
            ["energy", "recharge", "speed", "thrust", "rotation"];
        if let Some(i) = STATS.iter().position(|n| n.eq_ignore_ascii_case(name)) {
            return Some(i);
        }
        // Charge slots are named by position, because what sits in each is
        // the zone's own choice: the baseline puts a repel in one and a burst
        // in two, and a zone that fills three and four names those.
        if let Some(n) = name.strip_prefix("charge-") {
            let k: usize = n.parse().ok()?;
            if k >= 1 && k <= sim::MAX_CHARGES {
                return Some(sim::UP_COUNT + sim::TRIG_COUNT
                            + sim::TRIG_COUNT * sim::MOD_COUNT + k - 1);
            }
            return None;
        }
        let (trig, rest) = name.split_once('-')?;
        let t = match trig.to_ascii_lowercase().as_str() {
            "gun" => 0,
            "bomb" => 1,
            _ => return None,
        };
        if rest.eq_ignore_ascii_case("level") {
            return Some(sim::UP_COUNT + t);
        }
        let m = Arena::mod_index(rest)?;
        Some(sim::UP_COUNT + sim::TRIG_COUNT + t * sim::MOD_COUNT + m)
    }

    /// Add-ons are named in a zone file and numbered in the core. The order
    /// is `sim_mod`'s and the names are the ones the design doc uses.
    fn mod_index(name: &str) -> Option<usize> {
        const NAMES: [&str; sim::MOD_COUNT] =
            ["multi", "bounce", "prox", "shrapnel", "freeze", "push"];
        NAMES.iter().position(|n| n.eq_ignore_ascii_case(name))
    }

    /// One weapon block, over whatever that weapon already was. The units are
    /// the ones the rest of the file uses -- px, px/s/10, energy, ticks --
    /// and degrees, because nobody thinks in sixty-five thousandths of a turn.
    fn apply_weapon(world: &mut sim::World, named: &[(String, u8)], pat: u8,
                    w: &config::WeaponConfig, warn: &mut Vec<String>) {
        let spec_idx = world.cfg.patterns[pat as usize].spec as usize;
        let sp = &mut world.cfg.specs[spec_idx];
        unsafe {
            if let Some(v) = w.speed { sp.speed = sim::sim_units_speed(v); }
            if let Some(v) = w.push { sp.push = sim::sim_units_speed(v); }
            if let Some(v) = w.damage { sp.damage = sim::sim_units_energy(v); }
        }
        if let Some(v) = w.life { sp.life = v; }
        if let Some(v) = w.bounces { sp.bounces = v; }
        if let Some(v) = w.trigger { sp.trigger = v * 256; }
        if let Some(v) = w.blast { sp.blast = v * 256; }
        if let Some(v) = w.stall { sp.stall = v; }
        if let Some(v) = w.expire_ends { sp.expire_ends = v as u8; }
        if let Some(rule) = &w.on_wall {
            match rule.as_str() {
                "end" => sp.on_wall = 0,
                "bounce" => sp.on_wall = 1,
                "pass" => sp.on_wall = 2,
                other => warn.push(format!(
                    "\"{other}\" is not a wall rule: end, bounce or pass")),
            }
        }
        if let Some(name) = &w.splinter {
            // Naming itself is legal and bounded: the core stops a fragment
            // fragmenting by the generation it carries, not by the table.
            match named.iter().find(|(n, _)| n == name) {
                Some(&(_, p)) => world.cfg.specs[spec_idx].splinter = p,
                None if name.is_empty() => world.cfg.specs[spec_idx].splinter = sim::NO_PATTERN,
                None => warn.push(format!(
                    "\"{}\" splinters into \"{name}\", which is not a weapon", w.name)),
            }
        }
        let p = &mut world.cfg.patterns[pat as usize];
        unsafe {
            if let Some(v) = w.recoil { p.recoil = sim::sim_units_speed(v); }
            if let Some(v) = w.energy { p.energy = sim::sim_units_energy(v); }
        }
        if let Some(v) = w.count { p.count = v; }
        if let Some(v) = w.delay { p.delay = v; }
        if let Some(v) = w.spread {
            p.spacing = ((v as i64 * 65536 / 360) & 0xffff) as u16;
        }
    }

    fn new_from(cfg: &config::ZoneConfig) -> Self {
        let mut a = Arena::new_on_map(&cfg.map);
        for w in Arena::apply_config(&mut a.world, &cfg.arena) {
            println!("zone: {w}");
        }
        a
    }

    /// A zone's own map, if it named one. A map that will not load is
    /// reported and then ignored: a zone that refuses to start because of a
    /// bad file is worse for the people trying to play in it than one that
    /// runs the built-in room and says so.
    fn new_on_map(path: &str) -> Self {
        if path.is_empty() {
            return Arena::new();
        }
        match std::fs::read(path) {
            Ok(bytes) => match sim::World::from_packed(0x5eed, &bytes) {
                Ok(w) => {
                    println!("map {path}: {} bytes", bytes.len());
                    Arena::with_world(w)
                }
                Err(e) => {
                    println!("map {path}: {e}; running the built-in arena");
                    Arena::new()
                }
            },
            Err(e) => {
                println!("map {path}: {e}; running the built-in arena");
                Arena::new()
            }
        }
    }

    fn new() -> Self {
        Self::with_world(sim::World::new(0x5eed))
    }

    fn with_world(world: sim::World) -> Self {
        let mut world = world;
        let mut bots = Vec::new();
        let mut names = HashMap::new();

        // The population director in miniature: fill the arena with AI so a
        // player arriving alone still finds a game. Bots leave as humans
        // arrive, per docs/design/ai-players.md.
        let roster = ai::roster();
        for (i, r) in roster.iter().enumerate() {
            // The map's own start wins over the roster's tile: a zone
            // pointed at a new map should not need its roster rewritten to
            // match that map's walls.
            // Headings spread around the circle. The multiply has to happen
            // wider than u16 or the ninth pilot overflows it, which a release
            // build wrapped quietly and a debug build panicked on.
            let heading = ((i as u32 * 8192) % 65536) as u16;
            let ship = world.spawn_on_map(r.class, r.team, i as u32,
                                          r.tile_x, r.tile_y, heading);
            if ship >= 0 {
                bots.push(ai::Bot::new(ship as u8, r.skill));
                names.insert(ship as u8, (r.name.to_string(), true));
            }
        }
        // One per quadrant, three hundred tiles apart, on the clear cell
        // offset the map's starts use. Away from every spawn, and far enough
        // from each other that holding two is a decision.
        for (tx, ty) in [(308, 308), (756, 308), (308, 756), (756, 756)] {
            world.add_flag(tx, ty);
        }

        Arena {
            world,
            players: HashMap::new(),
            bots,
            names,
            next_id: 1,
            rating: rating::Rating::new(),
            mode: Box::new(modes::Warzone::new(4)),
            banner: String::new(),
            finished: false,
        }
    }

    /// `max_players` is the zone's, which used to be a constant here while the
    /// key in the file was read by nobody. It bounds humans; the room's own size
    /// is `arena.max_ships` and the two are different questions, since a wide
    /// room with a small player cap is a zone that wants mostly bots.
    fn join(&mut self, name: String, class: u8, max_players: usize,
            tx: mpsc::UnboundedSender<Vec<u8>>) -> Option<u64> {
        if self.players.len() >= max_players {
            return None;
        }
        // Take a bot's slot if one is available, so the arena size stays put.
        let ship = if let Some(bot) = self.bots.pop() {
            self.world.state.ships[bot.ship as usize].kills = 0;
            self.world.state.ships[bot.ship as usize].deaths = 0;
            bot.ship
        } else {
            // A joining pilot takes the next start in the map's rotation, so
            // arrivals spread across them instead of landing on each other.
            let nth = self.world.state.ship_count as u32;
            let s = self.world.spawn_on_map(class.min(7), 0, nth, 512, 522, 0);
            if s < 0 {
                return None;
            }
            s as u8
        };

        let sh = &mut self.world.state.ships[ship as usize];
        sh.cls = class.min(7);
        sh.team = 0;
        sh.alive = 1;
        sh.up = [0; sim::UP_COUNT];
        sh.energy = i32::MAX; // clamped to the effective maximum next tick

        let id = self.next_id;
        self.next_id += 1;
        self.names.insert(ship, (name.clone(), false));
        self.players.insert(
            id,
            Player {
                ship,
                buttons: 0,
                last_input_tick: 0,
                name,
                tx,
            },
        );
        Some(id)
    }

    fn leave(&mut self, id: u64) {
        if let Some(p) = self.players.remove(&id) {
            self.rating.forget(&p.name);
            // Hand the ship back to a bot rather than leaving a corpse.
            self.bots.push(ai::Bot::new(p.ship, 0.5));
            self.names
                .insert(p.ship, (ai::name_for(p.ship), true));
        }
    }

    fn tick(&mut self) {
        let mut inputs: Vec<sim::sim_input> = Vec::with_capacity(32);
        for p in self.players.values() {
            inputs.push(sim::sim_input {
                ship: p.ship,
                buttons: p.buttons,
            });
        }
        for b in &mut self.bots {
            let buttons = b.think(&self.world);
            inputs.push(sim::sim_input {
                ship: b.ship,
                buttons,
            });
        }
        self.world.step(&inputs);
        self.score_events();

        let seats: Vec<(u8, bool)> = self
            .names
            .iter()
            .map(|(s, (_, ai))| (*s, *ai))
            .collect();
        let mut ctx = modes::ModeCtx {
            world: &mut self.world,
            seats: &seats,
            banner: std::mem::take(&mut self.banner),
            finished: false,
        };
        self.mode.tick(&mut ctx);
        self.banner = std::mem::take(&mut ctx.banner);
        if ctx.finished {
            self.finished = true;
        }
    }

    /// Turn this tick's events into rating movement. The simulation does not
    /// know rating exists; this layer reads what it produced.
    fn score_events(&mut self) {
        let tick = self.world.state.tick;
        let names = self.names.clone();
        let name_of = move |ship: u8| {
            names
                .get(&ship)
                .map(|(n, _)| n.clone())
                .unwrap_or_else(|| ai::name_for(ship))
        };
        let deaths = ingest_damage(&self.world, &mut self.rating, &name_of);
        for (victim, killer) in deaths.iter().copied() {
            let seats: Vec<(u8, bool)> = self.names.iter().map(|(s, (_, a))| (*s, *a)).collect();
            let mut ctx = modes::ModeCtx {
                world: &mut self.world,
                seats: &seats,
                banner: std::mem::take(&mut self.banner),
                finished: false,
            };
            self.mode.on_death(&mut ctx, victim, killer);
            self.banner = std::mem::take(&mut ctx.banner);
            if ctx.finished {
                self.finished = true;
            }
        }
        for (victim, killer) in deaths {
            let vname = self.name_of(victim);
            let kname = self.name_of(killer);
            let rated = self.rating.death(tick, &vname);
            let mut m = vec![S2C_KILL];
            m.push(victim);
            m.push(killer);
            // Rating after the exchange, rounded, for the scoreboard.
            let vr = self.rating.rating_of(&vname).round() as i16;
            let kr = self.rating.rating_of(&kname).round() as i16;
            m.extend_from_slice(&vr.to_le_bytes());
            m.extend_from_slice(&kr.to_le_bytes());
            m.push(rated.as_ref().map_or(0, |r| r.credits.len() as u8));
            for p in self.players.values() {
                let _ = p.tx.send(m.clone());
            }
            let assists = rated.as_ref().map_or(0, |r| r.credits.len());
            if assists > 1 {
                println!("tick {tick}: {kname} killed {vname} with {assists} contributors");
            }
        }
    }

    fn name_of(&self, ship: u8) -> String {
        self.names
            .get(&ship)
            .map(|(n, _)| n.clone())
            .unwrap_or_else(|| format!("ship{ship}"))
    }

    fn broadcast_banner(&self) {
        let mut m = vec![S2C_BANNER];
        m.extend_from_slice(self.banner.as_bytes());
        for p in self.players.values() {
            let _ = p.tx.send(m.clone());
        }
    }

    fn broadcast_snapshot(&self, buf: &mut [u8]) {
        for p in self.players.values() {
            // Packed per player rather than once for everybody, so each is
            // sent only the prizes near its own ship. Prizes are most of a
            // snapshot -- two hundred of them outweigh the ships and every
            // projectile together -- and a client can only see the handful
            // inside its radar, sixty tiles out.
            //
            // A pack is under two microseconds, so sixteen of them is thirty
            // microseconds of a fifty millisecond period. The bytes saved are
            // worth far more than the pack costs.
            let sh = &self.world.state.ships[p.ship as usize];
            let n = self.world.pack_around(buf, sh.x, sh.y, PRIZE_INTEREST);
            if n <= 0 {
                continue;
            }
            let mut msg = Vec::with_capacity(n as usize + 10);
            msg.push(S2C_SNAPSHOT);
            msg.push(p.ship);
            msg.extend_from_slice(&p.last_input_tick.to_le_bytes());
            msg.extend_from_slice(&buf[..n as usize]);
            let _ = p.tx.send(msg);
        }
    }

    /// Names and AI labels, sent when the roster changes. Bots are always
    /// labeled: a player deserves to know who they are fighting.
    fn roster_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_ROSTER];
        m.push(self.names.len() as u8);
        for (ship, (name, is_ai)) in &self.names {
            m.push(*ship);
            m.push(if *is_ai { 1 } else { 0 });
            m.extend_from_slice(&(self.rating.rating_of(name).round() as i16).to_le_bytes());
            // Rated deaths so far. The client derives the tier from the
            // rating itself, but it cannot know from a number alone whether
            // that number has been earned yet, and an unearned rating should
            // not be shown as if it had been.
            m.push(self.rating.games_of(name).min(255) as u8);
            let bytes = name.as_bytes();
            let len = bytes.len().min(24) as u8;
            m.push(len);
            m.extend_from_slice(&bytes[..len as usize]);
        }
        m
    }

    /// Everyone in the room gets the new numbers. An operator retuning a
    /// live arena would otherwise leave every client predicting the game as
    /// it was when they joined.
    fn broadcast_settings(&self) {
        let mut m = vec![S2C_SETTINGS];
        m.extend_from_slice(&self.world.packed_settings());
        for p in self.players.values() {
            let _ = p.tx.send(m.clone());
        }
    }

    fn broadcast_roster(&self) {
        let m = self.roster_msg();
        for p in self.players.values() {
            let _ = p.tx.send(m.clone());
        }
    }
}

/// The zone and the one arena it is hosting. This held a map of arenas while
/// duels made rooms of their own; with duels out nothing else ever made a
/// second one, and one process to one room is where decision 23 was going
/// anyway.
struct Zone {
    arena: Arena,
    cfg: config::ConfigWatcher,
    store: persist::Store,
}

/// Put an arena's ratings on the same footing as every other: the AI marked
/// so it moves slowly against humans, each bot seeded from the calibrated
/// prior, and the anchor pinned last so nothing can overwrite the fixed
/// point the rest of the ladder is measured against.
fn prime_ratings(r: &mut rating::Rating, ladder: &HashMap<String, f64>) {
    for e in ai::roster() {
        r.mark_bot(e.name);
        if let Some(&v) = ladder.get(e.name) {
            r.score.insert(e.name.to_string(), v);
        }
    }
    r.set_anchor(ai::ANCHOR, ai::ANCHOR_RATING);
}

/// Read the ladder a calibration run wrote. A missing file is normal.
fn load_ladder(dir: &str) -> HashMap<String, f64> {
    std::fs::read_to_string(format!("{dir}/ladder.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

impl Zone {
    fn new(cfg: config::ConfigWatcher, store: persist::Store,
           ladder: HashMap<String, f64>) -> Self {
        let mut arena = Arena::new_from(&cfg.current);
        prime_ratings(&mut arena.rating, &ladder);
        Zone { arena, cfg, store }
    }

    /// Re-read the zone file and push the new numbers into every live arena.
    /// Nobody is disconnected: an operator tuning a bounce factor should not
    /// cost the room its round.
    fn reload(&mut self) {
        if let Some(msg) = self.cfg.poll() {
            println!("{msg}");
            for w in Arena::apply_config(&mut self.arena.world, &self.cfg.current.arena) {
                println!("zone: {w}");
            }
            self.arena.broadcast_settings();
        }
    }

    /// What this zone tells a directory, and anybody else who asks.
    fn status_json(&self) -> String {
        let players = self.arena.players.len() as u32;
        let bots = self.arena.bots.len() as u32;
        serde_json::to_string(&directory::Status {
            name: self.cfg.current.name.clone(),
            description: self.cfg.current.description.clone(),
            players,
            bots,
            arenas: 1,
        })
        .unwrap_or_default()
    }

    fn zone_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_ZONE];
        let text = format!("{}\n{}", self.cfg.current.name, self.cfg.current.description);
        m.extend_from_slice(text.as_bytes());
        m
    }
}

/// Run the offline tournament and write the ladder the zone seeds bots from.
///
///     vectorwake-server calibrate [rounds] [dir]
fn run_calibration() {
    let rounds: u32 = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(6);
    let dir = std::env::args().nth(3).unwrap_or_else(|| ".".into());
    let path = format!("{dir}/ladder.json");

    println!("calibrating: {rounds} rounds of round-robin matches");
    let r = calibrate::run(rounds, true);

    println!("\n{:<12} {:>7}  {:>6}  {}", "pilot", "rating", "games", "tier");
    let mut ladder = std::collections::HashMap::new();
    for (name, score, games, tier) in calibrate::table(&r) {
        let pin = if name == ai::ANCHOR { " (anchor)" } else { "" };
        println!("{name:<12} {score:>7.0}  {games:>6}  {tier}{pin}");
        ladder.insert(name, score);
    }

    let doc = serde_json::to_string_pretty(&ladder).expect("serialize ladder");
    match std::fs::write(&path, doc) {
        Ok(()) => println!("\nwrote {path}"),
        Err(e) => println!("\ncould not write {path}: {e}"),
    }
}

/// Serve the zone directory.
///
///     vectorwake-server directory <listen> [dir]
async fn run_directory() {
    let addr = std::env::args().nth(2).unwrap_or_else(|| "0.0.0.0:9000".into());
    let dir = std::env::args().nth(3).unwrap_or_else(|| ".".into());
    let (d, err) = directory::Directory::load(&format!("{dir}/directory.toml"));
    if let Some(e) = err {
        println!("no usable directory.toml ({e}); serving an empty list");
    }
    println!("directory \"{}\": {} zones", d.name, d.entries.len());
    let d = Arc::new(Mutex::new(d));

    // Poll on a timer rather than on demand, so one slow zone cannot make a
    // player's browse request hang.
    {
        let d = d.clone();
        tokio::spawn(async move {
            loop {
                directory::refresh(&d).await;
                tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            }
        });
    }

    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind failed");
    println!("vectorwake directory listening on ws://{addr}");
    while let Ok((stream, _)) = listener.accept().await {
        let d = d.clone();
        tokio::spawn(async move {
            let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await else { return };
            while let Some(Ok(msg)) = ws.next().await {
                if let Message::Binary(b) = msg {
                    if b.first() == Some(&C2S_STATUS) {
                        let mut m = vec![S2C_STATUS];
                        m.extend_from_slice(d.lock().await.as_json().as_bytes());
                        if ws.send(Message::Binary(m)).await.is_err() {
                            return;
                        }
                    }
                }
            }
        });
    }
}

/// Either kind of accepted connection, boxed so the connection handler is
/// written once. tokio implements AsyncRead and AsyncWrite for Box<T>, and a
/// trait object carries its supertraits, so this needs no glue of its own.
trait Conn: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send> Conn for T {}

/// Build a TLS acceptor from PEM files, or None when the zone is plain ws.
/// A zone that is configured for TLS and cannot load its certificate must
/// not quietly fall back to cleartext: the operator asked for wss, and
/// serving ws instead would look like it worked.
fn tls_acceptor(cert: &str, key: &str) -> Option<tokio_rustls::TlsAcceptor> {
    if cert.is_empty() && key.is_empty() {
        return None;
    }
    if cert.is_empty() || key.is_empty() {
        panic!("tls_cert and tls_key must be set together");
    }
    let certs: Vec<_> = rustls_pemfile::certs(&mut std::io::BufReader::new(
        std::fs::File::open(cert).unwrap_or_else(|e| panic!("tls_cert {cert}: {e}")),
    ))
    .collect::<Result<_, _>>()
    .expect("tls_cert is not a PEM certificate chain");
    let k = rustls_pemfile::private_key(&mut std::io::BufReader::new(
        std::fs::File::open(key).unwrap_or_else(|e| panic!("tls_key {key}: {e}")),
    ))
    .expect("tls_key is not readable")
    .expect("tls_key holds no private key");
    let cfg = tokio_rustls::rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, k)
        .expect("certificate and key do not match");
    Some(tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(cfg)))
}

#[tokio::main]
async fn main() {
    if std::env::args().nth(1).as_deref() == Some("directory") {
        run_directory().await;
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("calibrate") {
        run_calibration();
        return;
    }
    let addr_arg = std::env::args().nth(1);

    let dir = std::env::args().nth(2).unwrap_or_else(|| ".".into());
    let (watcher, err) = config::ConfigWatcher::load(format!("{dir}/zone.toml"));
    if let Some(e) = err {
        println!("no usable zone.toml ({e}); running on the built-in defaults");
    }
    let store = persist::Store::open(format!("{dir}/ratings.json"));
    let ladder = load_ladder(&dir);
    if ladder.is_empty() {
        println!("no ladder.json; bots start level. Run `calibrate` to seed one");
    } else {
        println!("seeded {} bot ratings from ladder.json", ladder.len());
    }
    println!("zone \"{}\": {}", watcher.current.name, watcher.current.description);
    // The command line wins over the zone file, so an operator can move a
    // zone to another port without editing its configuration.
    let addr = addr_arg.unwrap_or_else(|| watcher.current.listen.clone());
    // Read before the watcher moves into the zone. Certificates are not
    // hot-reloaded: a listener is bound once, and swapping its identity
    // underneath live connections is not something an operator asked for.
    let cfg_tls = (
        watcher.current.tls_cert.clone(),
        watcher.current.tls_key.clone(),
    );
    let zone = Arc::new(Mutex::new(Zone::new(watcher, store, ladder)));
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind failed");
    let tls = tls_acceptor(&cfg_tls.0, &cfg_tls.1);
    println!(
        "vectorwake zone server listening on {}://{addr}",
        if tls.is_some() { "wss" } else { "ws" }
    );

    // The arena loop. One thread owns the simulation for the duration of a
    // tick; connections only ever enqueue inputs.
    {
        let zone = zone.clone();
        tokio::spawn(async move {
            let mut ticker =
                tokio::time::interval(std::time::Duration::from_micros(1_000_000 / TICK_HZ));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut buf = vec![0u8; sim::PACK_MAX];
            let mut n: u32 = 0;
            loop {
                ticker.tick().await;
                let mut z = zone.lock().await;
                n += 1;
                if n % 300 == 0 {
                    z.reload();
                }
                if n % 3000 == 0 {
                    let ratings: Vec<(String, f64)> = z.arena
                        .rating
                        .score
                        .iter()
                        .map(|(k, v)| (k.clone(), *v))
                        .collect();
                    for (k, v) in ratings {
                        z.store.set_rating(&k, v);
                    }
                    if let Err(e) = z.store.flush() {
                        println!("could not save ratings: {e}");
                    }
                }
                z.arena.tick();
                if n % SNAPSHOT_EVERY == 0 {
                    z.arena.broadcast_snapshot(&mut buf);
                    z.arena.broadcast_banner();
                }
            }
        });
    }

    while let Ok((stream, _)) = listener.accept().await {
        let zone = zone.clone();
        let tls = tls.clone();
        tokio::spawn(async move {
            // The TLS handshake happens before the WebSocket one, and a
            // client that fails it is simply a client that never arrives.
            let stream: Box<dyn Conn> = match &tls {
                Some(a) => match a.accept(stream).await {
                    Ok(s) => Box::new(s),
                    Err(_) => return,
                },
                None => Box::new(stream),
            };
            let ws = match tokio_tungstenite::accept_async(stream).await {
                Ok(w) => w,
                Err(_) => return,
            };
            let (mut sink, mut source) = ws.split();
            let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();

            let writer = tokio::spawn(async move {
                while let Some(msg) = rx.recv().await {
                    if sink.send(Message::Binary(msg)).await.is_err() {
                        break;
                    }
                }
            });

            // This connection's id in the arena, once it has joined.
            let mut seat: Option<u64> = None;
            while let Some(Ok(msg)) = source.next().await {
                let data = match msg {
                    Message::Binary(b) => b,
                    Message::Close(_) => break,
                    _ => continue,
                };
                if data.is_empty() {
                    continue;
                }
                match data[0] {
                    C2S_STATUS => {
                        // Answerable without joining, so a directory or a
                        // browsing player can look before committing.
                        let z = zone.lock().await;
                        let mut m = vec![S2C_STATUS];
                        m.extend_from_slice(z.status_json().as_bytes());
                        let _ = tx.send(m);
                    }
                    C2S_JOIN if seat.is_none() => {
                        let class = data.get(1).copied().unwrap_or(0);
                        let name = String::from_utf8_lossy(&data[2..]).to_string();
                        let name = if name.is_empty() { "pilot".into() } else { name };
                        let mut z = zone.lock().await;
                        if z.cfg.current.is_banned(&name) {
                            let mut m = vec![S2C_DENIED];
                            m.extend_from_slice(b"you are banned from this zone");
                            let _ = tx.send(m);
                            break;
                        }
                        let _ = tx.send(z.zone_msg());
                        if let Some(saved) = z.store.rating(&name) {
                            z.arena.rating.score.insert(name.clone(), saved);
                        }
                        let cap = if z.cfg.current.max_players > 0 {
                            z.cfg.current.max_players
                        } else {
                            DEFAULT_MAX_PLAYERS
                        };
                        let a = &mut z.arena;
                        if let Some(new_id) = a.join(name, class, cap, tx.clone()) {
                            seat = Some(new_id);
                            let ship = a.players[&new_id].ship;
                            let mut m = vec![S2C_MAP];
                            m.extend_from_slice(&a.world.packed_map());
                            let _ = tx.send(m);
                            let mut c = vec![S2C_SETTINGS];
                            c.extend_from_slice(&a.world.packed_settings());
                            let _ = tx.send(c);
                            let mut w = vec![S2C_WELCOME, ship];
                            w.extend_from_slice(&a.world.state.tick.to_le_bytes());
                            let _ = tx.send(w);
                            a.broadcast_roster();
                        }
                    }
                    C2S_SHIP => {
                        // A hull change, in place. The core refuses it unless
                        // the pilot is alive and at a full bar, which is what
                        // stops it being an escape from a fight -- a fresh
                        // ship is a fresh bar. Nothing is sent back: the next
                        // snapshot carries the new class, and a refusal leaves
                        // the old one, which is the same answer either way.
                        if data.len() >= 2 {
                            if let Some(pid) = seat {
                                let cls = data[1];
                                let mut z = zone.lock().await;
                                let ship = z.arena.players.get(&pid).map(|p| p.ship);
                                if let Some(ship) = ship {
                                    z.arena.world.set_ship_class(ship, cls);
                                }
                            }
                        }
                    }
                    C2S_INPUT => {
                        // buttons: u16, tick: u32. The tick is advisory: the
                        // server applies inputs when it receives them and
                        // echoes the number back so the client can reconcile.
                        if data.len() >= 7 {
                            if let Some(pid) = seat {
                                let buttons = u16::from_le_bytes([data[1], data[2]]);
                                let t = u32::from_le_bytes([data[3], data[4], data[5], data[6]]);
                                let mut z = zone.lock().await;
                                if let Some(p) = z.arena.players.get_mut(&pid) {
                                    p.buttons = buttons;
                                    p.last_input_tick = t;
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }

            if let Some(pid) = seat {
                let mut z = zone.lock().await;
                z.arena.leave(pid);
                z.arena.broadcast_roster();
            }
            writer.abort();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(toml_src: &str) -> config::ArenaConfig {
        let z: config::ZoneConfig = toml::from_str(toml_src).expect("zone file parses");
        z.arena
    }

    /// The tables a zone file produces, which is the only thing a client
    /// ever sees of it.
    fn tuned(toml_src: &str) -> (sim::World, Vec<String>) {
        let mut w = sim::World::new(1);
        let warn = Arena::apply_config(&mut w, &parse(toml_src));
        (w, warn)
    }

    fn gun(w: &sim::World, cls: usize) -> (sim::sim_fire_pattern, sim::sim_weapon_spec) {
        let p = w.cfg.patterns[w.cfg.classes[cls].trigger[0][0] as usize];
        (p, w.cfg.specs[p.spec as usize])
    }

    #[test]
    fn a_named_baseline_weapon_is_tuned_in_place() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "anvil-bomb"
            on_wall = "bounce"
            bounces = 3
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let p = w.cfg.patterns[w.cfg.classes[anvil].trigger[1][0] as usize];
        let sp = w.cfg.specs[p.spec as usize];
        assert_eq!((sp.on_wall, sp.bounces), (1, 3), "the bomb bounces now");
        assert!(sp.blast > 0, "and is otherwise still the bomb");
        // Nobody else's weapon moved: each hull's rows are its own.
        let (_, apex) = gun(&w, ai::class_index("Apex").unwrap());
        assert_eq!(apex.on_wall, 0);
    }

    #[test]
    fn an_unknown_name_is_a_new_weapon_a_hull_can_carry() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "burst"
            speed = 1500
            life = 60
            damage = 40
            count = 16
            spread = 22
            energy = 300

            [[arena.ships]]
            name = "Spire"
            bomb = "burst"
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let spire = ai::class_index("Spire").unwrap();
        let p = w.cfg.patterns[w.cfg.classes[spire].trigger[1][0] as usize];
        let sp = w.cfg.specs[p.spec as usize];
        assert_eq!(p.count, 16);
        assert_eq!(sp.life, 60);
        assert_eq!(sp.splinter, sim::NO_PATTERN, "a new weapon splinters into nothing");
        // Degrees, because nobody thinks in sixty-five thousandths of a turn.
        assert_eq!(p.spacing, (22 * 65536 / 360) as u16);
        // The Spire has no bomb rack in the baseline, so this gave it one.
        let fresh = sim::World::new(1);
        assert_eq!(fresh.cfg.classes[spire].trigger[1][0], sim::NO_PATTERN);
    }

    #[test]
    fn a_weapon_can_splinter_into_one_written_after_it() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "anvil-bomb"
            splinter = "shrapnel"

            [[arena.weapons]]
            name = "shrapnel"
            speed = 1200
            life = 40
            damage = 50
            count = 8
            spread = 45
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let bomb = w.cfg.patterns[w.cfg.classes[anvil].trigger[1][0] as usize];
        let into = w.cfg.specs[bomb.spec as usize].splinter;
        assert_ne!(into, sim::NO_PATTERN, "the bomb splinters");
        assert_eq!(w.cfg.patterns[into as usize].count, 8, "into eight fragments");
    }

    #[test]
    fn an_empty_name_takes_the_rack_away() {
        let (w, warn) = tuned(r#"
            [[arena.ships]]
            name = "Anvil"
            bomb = ""
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.classes[ai::class_index("Anvil").unwrap()].trigger[1][0], sim::NO_PATTERN);
    }

    #[test]
    fn what_the_file_cannot_have_is_reported_rather_than_guessed() {
        let (_, warn) = tuned(r#"
            [[arena.weapons]]
            name = "odd"
            on_wall = "sideways"
            splinter = "nothing-called-this"

            [[arena.ships]]
            name = "Trapezoid"

            [[arena.ships]]
            name = "Apex"
            gun = "also-not-a-weapon"
        "#);
        assert_eq!(warn.len(), 4, "{warn:?}");
        assert!(warn.iter().any(|w| w.contains("sideways")));
        assert!(warn.iter().any(|w| w.contains("nothing-called-this")));
        assert!(warn.iter().any(|w| w.contains("Trapezoid")));
        assert!(warn.iter().any(|w| w.contains("also-not-a-weapon")));
    }

    #[test]
    fn a_rung_above_the_first_is_named_for_its_level() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "anvil-bomb-3"
            blast = 96
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let rungs = w.cfg.classes[anvil].trigger[1];
        let top = w.cfg.specs[w.cfg.patterns[rungs[2] as usize].spec as usize];
        let base = w.cfg.specs[w.cfg.patterns[rungs[0] as usize].spec as usize];
        assert_eq!(top.blast, 96 * 256, "the third rung got the wider blast");
        assert_eq!(base.blast, 80 * 256, "and the first kept its own");
        assert!(top.damage > base.damage, "a rung is still the same weapon harder");
    }

    #[test]
    fn a_hull_holds_the_add_ons_its_row_allows() {
        let (w, warn) = tuned(r#"
            [arena.mod_step]
            freeze = 250

            [[arena.ships]]
            name = "Spire"
            gun_mods = { freeze = 3, multi = 1 }
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.mod_step[4], 250, "a rung of freeze is two and a half seconds");
        let spire = ai::class_index("Spire").unwrap();
        let m = w.cfg.classes[spire].mod_max[0];
        assert_eq!((m >> 8) & 3, 3, "three rungs of freeze");
        assert_eq!(m & 3, 1, "and one of multifire");
        // Named add-ons are checked, not guessed at.
        let (_, warn) = tuned(r#"
            [[arena.ships]]
            name = "Spire"
            gun_mods = { sideways = 1 }
        "#);
        assert!(warn.iter().any(|w| w.contains("sideways")), "{warn:?}");
    }

    #[test]
    fn naming_one_weapon_replaces_the_whole_ladder() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "repel"
            speed = 0
            life = 1
            on_wall = "pass"
            expire_ends = true
            blast = 300
            push = 3000

            [[arena.ships]]
            name = "Anvil"
            bomb = "repel"
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let rungs = w.cfg.classes[anvil].trigger[1];
        assert_ne!(rungs[0], sim::NO_PATTERN, "the repel is on the trigger");
        assert_eq!(rungs[1], sim::NO_PATTERN,
                   "and there is nothing to level into");
    }

    #[test]
    fn a_zone_sets_its_room_size() {
        let mut w = sim::World::new(1);
        assert_eq!(w.cfg.max_ships, 64, "the baseline's room");
        Arena::apply_config(&mut w, &parse("[arena]\nmax_ships = 200\n"));
        assert_eq!(w.cfg.max_ships, 200, "a zone can widen it");
        // Reload builds from the baseline first, so dropping the line reverts.
        Arena::apply_config(&mut w, &parse("[arena]\n"));
        assert_eq!(w.cfg.max_ships, 64, "and removing the line puts it back");
    }

    #[test]
    fn a_zone_sets_the_odds_and_the_rust() {
        let (w, warn) = tuned(r#"
            [arena]
            rust = 250

            [arena.prize_weight]
            speed = 5
            gun-level = 400
            bomb-shrapnel = 90
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.rust_chance, 250);
        assert_eq!(w.cfg.prize_weight[2], 5, "speed is the third stat");
        assert_eq!(w.cfg.prize_weight[sim::UP_COUNT], 400, "gun level");
        let bomb_shrap = sim::UP_COUNT + sim::TRIG_COUNT + sim::MOD_COUNT + 3;
        assert_eq!(w.cfg.prize_weight[bomb_shrap], 90);
        // Everything unnamed keeps the baseline's odds.
        assert_eq!(w.cfg.prize_weight[0], 40, "energy keeps the original's odds");

        let (w, warn) = tuned(r#"
            [arena.prize_weight]
            luck = 10
        "#);
        assert!(warn.iter().any(|x| x.contains("luck")), "{warn:?}");
        assert_eq!(w.cfg.rust_chance, 10, "and rust keeps its default");
    }

    #[test]
    fn a_zone_prices_a_kill() {
        let (w, warn) = tuned(r#"
            [arena]
            bounty_per_kill = 9
            points_per_flag = 25
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.bounty_per_kill, 9);
        assert_eq!(w.cfg.points_per_flag, 25);

        // And a file that says nothing keeps the core's own numbers, which is
        // the check that catches a mirror drifting out of step with the C
        // struct -- the reason this reads a field two along from the ones it
        // set.
        let (w, _) = tuned(r#"
            [arena]
            mode = "warzone"
        "#);
        assert_eq!(w.cfg.bounty_per_kill, 3);
        assert_eq!(w.cfg.points_per_flag, 100);
        assert_eq!(w.cfg.rust_chance, 10);
    }

    #[test]
    fn a_zone_sets_the_opening_loadout() {
        let (w, warn) = tuned(r#"
            [arena]
            spawn_prizes = 0
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.spawn_prizes, 0, "a zone can start pilots plain");

        // Untouched it is thirty. Reading the field on either side too,
        // because a u16 landing in the wrong place is how this mirror drifts.
        let (w, _) = tuned(r#"
            [arena]
            mode = "warzone"
        "#);
        assert_eq!(w.cfg.spawn_prizes, 30);
        assert_eq!(w.cfg.rust_chance, 10, "and the field before it");
        assert_eq!(w.cfg.mod_step[0], 2, "and the one after");
    }

    #[test]
    fn a_zone_prices_multifire() {
        let (w, warn) = tuned(r#"
            [arena]
            multi_energy = 200
            multi_delay = 25
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.mod_multi_energy, 200);
        assert_eq!(w.cfg.mod_multi_delay, 25);

        // Untouched, these are the original's: MultiFireEnergy 30 against
        // BulletFireEnergy 20, and MultiFireDelay 50 against BulletFireDelay
        // 25. Reading the fields on either side too, because two u16s landing
        // in the wrong place is exactly how this mirror drifts.
        let (w, _) = tuned(r#"
            [arena]
            mode = "warzone"
        "#);
        assert_eq!(w.cfg.mod_multi_energy, 50);
        assert_eq!(w.cfg.mod_multi_delay, 100);
        assert_eq!(w.cfg.mod_spread, 2730, "fifteen degrees, still");
        assert_eq!(w.cfg.bounce, 10, "and the field past the splinters");
    }

    /// The reason apply_config rebuilds from the baseline. An operator saves
    /// the file repeatedly; the arena has to end up where the file says, not
    /// where every version of it since boot has said.
    #[test]
    fn applying_a_file_twice_is_applying_it_once() {
        let src = r#"
            [[arena.weapons]]
            name = "shrapnel"
            speed = 1200
            count = 8

            [[arena.weapons]]
            name = "anvil-bomb"
            splinter = "shrapnel"
        "#;
        let mut w = sim::World::new(1);
        Arena::apply_config(&mut w, &parse(src));
        let (specs, patterns) = (w.cfg.spec_count, w.cfg.pattern_count);
        for _ in 0..5 {
            Arena::apply_config(&mut w, &parse(src));
        }
        assert_eq!((w.cfg.spec_count, w.cfg.pattern_count), (specs, patterns),
                   "a reload does not append a row every time");
    }

    /// And a line taken out of the file comes back out of the arena.
    #[test]
    fn removing_a_line_removes_its_effect() {
        let mut w = sim::World::new(1);
        Arena::apply_config(&mut w, &parse(r#"
            [[arena.ships]]
            name = "Apex"
            speed = 6000
        "#));
        let tuned_speed = w.cfg.classes[0].max_speed;
        Arena::apply_config(&mut w, &parse("[arena]\nmode = \"warzone\""));
        assert!(w.cfg.classes[0].max_speed < tuned_speed, "back to the baseline");
    }
}
