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
mod admin;
mod calibrate;
mod catalog;
mod config;
mod directory;
mod fleet;
mod modes;
mod persist;
mod rating;
mod select;
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
/// `[C2S_JOIN, class, protocol, zone_len] zone name`
///
/// The zone is what the player picked out of a browse list, and it is checked
/// rather than assumed: an instance is free to change zone the moment its last
/// player leaves, so a client can arrive at an address that no longer serves the
/// game it chose. Empty means "whatever you are running", which is what somebody
/// typing an address directly means. The name runs to the end of the message, so
/// it is last and needs no length.
const C2S_JOIN: u8 = 1;
const C2S_INPUT: u8 = 2;
const C2S_SHIP: u8 = 5;
/// The client wire, which versions separately from the arena-to-directory one in
/// `fleet.rs`: they change for different reasons and are spoken by different
/// programs. Bump when a message's layout changes, so a stale build is told its
/// build is stale rather than left to misparse a snapshot.
const CLIENT_PROTOCOL: u8 = 1;
/// The biggest message a client may send. The largest legitimate one is a join:
/// tag, class, protocol, a zone name and a call sign. 8 KB is two orders of
/// magnitude of headroom.
const C2S_MAX: usize = 8 * 1024;
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
/// Why a join was refused. Three of these mean "try another instance" and two
/// mean "stop trying", which is the distinction a client cannot make from a
/// sentence. See the refusal table in docs/architecture/zones-and-arenas.md.
const DENY_FULL: u8 = 1;
const DENY_DRAINING: u8 = 2;
const DENY_WRONG_ZONE: u8 = 3;
const DENY_BANNED: u8 = 4;
const DENY_VERSION: u8 = 5;
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
    tx: mpsc::Sender<Vec<u8>>,
}

/// Messages a client may fall behind by before the arena stops queueing for it.
///
/// The queue used to be unbounded, which meant a client that stopped reading
/// cost this process memory without limit: two hundred stalled clients in one
/// room took it from 8 MB to 450 MB in twenty-five seconds, measured. A snapshot
/// is a whole state pack rather than a delta, so the next one supersedes any that
/// was dropped and the cure is simply not to send it. Two seconds of snapshots at
/// 20 Hz: long enough to ride out a hiccup, short enough that two hundred hopeless
/// clients in one room cost tens of megabytes rather than hundreds. Disconnecting
/// a client this far behind is a lag action, which server.md defers.
const OUT_QUEUE: usize = 40;

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
    /// How many teams the zone allows, and how an arrival is placed among them.
    /// The mode owns the policy and the catalog owns the shape, which is why a
    /// client never asserts a team: "what is a team here" is the same question
    /// as "what game is this".
    teams: u8,
    balance: String,
    /// How many bots this arena is supposed to have, fixed when it was built.
    /// `leave` needs it: handing every departing player's ship to a fresh bot
    /// grew the roster past its configured size, because a join only consumes a
    /// bot when one is there to consume.
    bot_target: usize,
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
        // The room, and the shape of the space in it. Every one of these is
        // absent-means-baseline rather than zero-means-baseline, because zero
        // is a legal value for most of them: a bounce of zero is a wall that
        // eats everything that hits it, and a door period of zero is a zone
        // whose doors never open.
        if let Some(v) = c.bounce { world.cfg.bounce = v; }
        if let Some(v) = c.friction { world.cfg.friction = v; }
        if let Some(v) = c.respawn_delay { world.cfg.respawn_delay = v; }
        // The core clamps this to SIM_MAX_SHIPS and reads zero as the ceiling,
        // so a zone asking for more than the array holds gets the array rather
        // than an overflow.
        if let Some(v) = c.max_ships { world.cfg.max_ships = v; }
        if let Some(v) = c.prize_delay { world.cfg.prize_delay = v; }
        if let Some(v) = c.prize_max { world.cfg.prize_max = v; }
        if let Some(v) = c.prize_life { world.cfg.prize_life = v; }
        if let Some(v) = c.prize_radius { world.cfg.prize_radius = v * 256; }
        if let Some(v) = c.prize_lo { world.cfg.prize_lo = v; }
        if let Some(v) = c.prize_hi { world.cfg.prize_hi = v; }
        if let Some(v) = c.flag_radius { world.cfg.flag_radius = v * 256; }
        if let Some(v) = c.flag_drop_cooldown { world.cfg.flag_drop_cooldown = v; }
        if let Some(v) = c.door_period { world.cfg.door_period = v; }
        if let Some(v) = c.door_open { world.cfg.door_open = v; }
        if let Some(v) = c.wormhole_pull {
            world.cfg.wormhole_pull = unsafe { sim::sim_units_speed(v) };
        }
        if let Some(v) = c.wormhole_range { world.cfg.wormhole_range = v * 256; }

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
        // And the weapons that belong to a slot in the settings rather than to
        // a hull: the four charges, and what each rung of shrapnel breaks
        // into. Without names those were the only weapons in the zone an
        // operator could not touch -- the repel's own radius was ours and
        // nobody else's.
        for (name, pat) in Arena::slots(world) {
            if pat != sim::NO_PATTERN { named.push((name, pat)); }
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
        if let Some(v) = c.mod_spread {
            world.cfg.mod_spread = ((v as i64 * 65536 / 360) & 0xffff) as u16;
        }
        if let Some(v) = c.prox_step { world.cfg.prox_step = v * 256; }
        if let Some(v) = c.shrap_inactive {
            world.cfg.shrap_inactive = unsafe { sim::sim_units_energy(v) };
        }
        if let Some(v) = c.shrap_inactive_ticks { world.cfg.shrap_inactive_ticks = v; }
        // Two passes, because a splinter may name a weapon written later in
        // the file, or one that does not exist until this pass makes it.
        for w in &c.weapons {
            if w.name.is_empty() {
                warn.push("a weapon with no name is a weapon nothing can point at".into());
                continue;
            }
            if named.iter().any(|(n, _)| *n == w.name) { continue; }
            match world.add_weapon() {
                Some(p) => {
                    // A slot name the baseline left empty -- `charge-3`, say
                    // -- fills that slot as well as making the weapon, so a
                    // zone adding a third charge writes one block rather than
                    // a block and a wiring line that does not exist.
                    Arena::fill_slot(world, &w.name, p);
                    named.push((w.name.clone(), p));
                }
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
                if want.len() > sim::MAX_RUNGS {
                    warn.push(format!("{}'s {field} ladder is {} rungs and {} is the ceiling",
                                      s.name, want.len(), sim::MAX_RUNGS));
                    continue;
                }
                // The whole ladder, first rung first, and an empty list takes
                // the trigger away -- which is how a hull loses its bomb rack
                // rather than being handed a free one. A name that resolves to
                // nothing leaves the hull's own ladder alone: half-applying it
                // would silently shorten the ladder, and a shortened ladder is
                // a hull that stops levelling for no reason a log would show.
                let mut ladder = [sim::NO_PATTERN; sim::MAX_RUNGS];
                let mut ok = true;
                for (rung, n) in want.iter().enumerate() {
                    match named.iter().find(|(nm, _)| nm == n) {
                        Some(&(_, p)) => ladder[rung] = p,
                        None => {
                            warn.push(format!(
                                "{} has no weapon called \"{n}\" to put on its {field}", s.name));
                            ok = false;
                        }
                    }
                }
                if ok { world.cfg.classes[idx].trigger[t] = ladder; }
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
            if s.charges.len() > sim::MAX_CHARGES {
                warn.push(format!("{} names {} charge slots and there are {}",
                                  s.name, s.charges.len(), sim::MAX_CHARGES));
            }
            for (k, &n) in s.charges.iter().take(sim::MAX_CHARGES).enumerate() {
                world.cfg.classes[idx].charge_max[k] = n.min(sim::CHARGE_MAX);
            }
            let cls = &mut world.cfg.classes[idx];
            // Raise the ceiling and the ladder under it moves with it, in
            // proportion. A zone that says nothing keeps the baseline's own
            // numbers exactly, which is the whole point: those are the
            // original's, and it starts a pilot at 62% of top speed but 88%
            // of top thrust and closes a quarter of the speed gap per green
            // against a seventh of the energy gap. Recomputing them from a
            // flat rule -- seventy per cent of the ceiling and an eighth of
            // the gap, which is what stood here -- overwrote all of that on
            // every reload, whether or not the file mentioned the ship.
            fn scaled(old_max: i32, new_max: i32, v: &mut i32) {
                if old_max > 0 && new_max != old_max {
                    *v = ((*v as i64) * new_max as i64 / old_max as i64) as i32;
                }
            }
            unsafe {
                if let Some(v) = s.speed {
                    let m = sim::sim_units_speed(v);
                    scaled(cls.max_speed, m, &mut cls.init_speed);
                    scaled(cls.max_speed, m, &mut cls.up_speed);
                    cls.max_speed = m;
                }
                if let Some(v) = s.thrust {
                    let m = sim::sim_units_thrust(v);
                    scaled(cls.thrust, m, &mut cls.init_thrust);
                    scaled(cls.thrust, m, &mut cls.up_thrust);
                    cls.thrust = m;
                }
                if let Some(v) = s.rotation {
                    let m = sim::sim_units_rotation(v);
                    scaled(cls.rot, m, &mut cls.init_rot);
                    scaled(cls.rot, m, &mut cls.up_rot);
                    cls.rot = m;
                }
                if let Some(v) = s.energy {
                    let m = sim::sim_units_energy(v);
                    scaled(cls.max_energy, m, &mut cls.init_energy);
                    scaled(cls.max_energy, m, &mut cls.up_energy);
                    cls.max_energy = m;
                }
                if let Some(v) = s.recharge {
                    let m = sim::sim_units_recharge(v);
                    scaled(cls.recharge, m, &mut cls.init_recharge);
                    scaled(cls.recharge, m, &mut cls.up_recharge);
                    cls.recharge = m;
                }
                // A floor or a step written out beats the proportion, so a
                // zone can say what the original's files say -- InitialSpeed,
                // UpgradeSpeed and MaximumSpeed as three independent numbers
                // -- rather than only being able to move all three together.
                if let Some(v) = s.initial_speed { cls.init_speed = sim::sim_units_speed(v); }
                if let Some(v) = s.upgrade_speed { cls.up_speed = sim::sim_units_speed(v); }
                if let Some(v) = s.initial_thrust { cls.init_thrust = sim::sim_units_thrust(v); }
                if let Some(v) = s.upgrade_thrust { cls.up_thrust = sim::sim_units_thrust(v); }
                if let Some(v) = s.initial_rotation { cls.init_rot = sim::sim_units_rotation(v); }
                if let Some(v) = s.upgrade_rotation { cls.up_rot = sim::sim_units_rotation(v); }
                if let Some(v) = s.initial_energy { cls.init_energy = sim::sim_units_energy(v); }
                if let Some(v) = s.upgrade_energy { cls.up_energy = sim::sim_units_energy(v); }
                if let Some(v) = s.initial_recharge {
                    cls.init_recharge = sim::sim_units_recharge(v);
                }
                if let Some(v) = s.upgrade_recharge {
                    cls.up_recharge = sim::sim_units_recharge(v);
                }
            }
            if let Some(v) = s.radius { cls.radius = v * 256; }
        }
        warn
    }

    /// The weapons that belong to a settings slot rather than to a hull, under
    /// the names a zone file reaches them by: `charge-1` through `charge-4`,
    /// and `shrapnel-1` up, one per rung of the add-on.
    ///
    /// Numbered rather than called repel and burst, because what sits in a
    /// charge slot is the zone's own choice and the prize weights name them
    /// the same way.
    fn slots(world: &sim::World) -> Vec<(String, u8)> {
        let mut v = Vec::new();
        for k in 0..sim::MAX_CHARGES {
            v.push((format!("charge-{}", k + 1), world.cfg.charge[k]));
        }
        for k in 1..sim::MAX_RUNGS {
            v.push((format!("shrapnel-{k}"), world.cfg.mod_splinter[k]));
        }
        v
    }

    /// Put a freshly made weapon in the slot its name asks for, if it asks for
    /// one. This is what lets a zone fill a slot the baseline leaves empty.
    fn fill_slot(world: &mut sim::World, name: &str, pat: u8) {
        if let Some(n) = name.strip_prefix("charge-") {
            if let Ok(k) = n.parse::<usize>() {
                if k >= 1 && k <= sim::MAX_CHARGES { world.cfg.charge[k - 1] = pat; }
            }
        } else if let Some(n) = name.strip_prefix("shrapnel-") {
            if let Ok(k) = n.parse::<usize>() {
                if k >= 1 && k < sim::MAX_RUNGS { world.cfg.mod_splinter[k] = pat; }
            }
        }
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
        // Mode and flags were keys in the file that nobody read: the arena
        // built a four-flag warzone whatever they said. They settle at start
        // rather than on reload, because changing what a round is for while
        // one is being played is not a tuning change.
        //
        // Flags can come down but not up: where they stand is the map's, and
        // the built-in arena puts four in the four quadrants. A zone asking
        // for more is told so rather than quietly given four.
        let placed = a.world.state.flag_count;
        if cfg.arena.flags > placed {
            println!("zone: this map places {placed} flags and the file asks for {}",
                     cfg.arena.flags);
        }
        a.world.state.flag_count = cfg.arena.flags.min(placed);
        a.mode = match cfg.arena.mode.as_str() {
            "arena" | "ffa" => Box::new(modes::FreeForAll),
            _ => Box::new(modes::Warzone::new(a.world.state.flag_count)),
        };
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
        let mut a = Arena::with_world_bare(world);
        a.mode = Box::new(modes::Warzone::new(4));
        a.fill_bots();
        a.add_default_flags();
        a
    }

    /// An empty room. A catalog zone builds one of these and then decides its
    /// mode, its teams and its population, rather than inheriting a warzone.
    fn with_world_bare(world: sim::World) -> Self {
        Arena {
            world,
            players: HashMap::new(),
            bots: Vec::new(),
            names: HashMap::new(),
            next_id: 1,
            rating: rating::Rating::new(),
            mode: Box::new(modes::FreeForAll),
            banner: String::new(),
            finished: false,
            teams: 2,
            balance: "smaller".into(),
            bot_target: 0,
        }
    }

    /// The population director in miniature: fill the room with AI so a player
    /// arriving alone still finds a game. Bots leave as humans arrive, per
    /// docs/design/ai-players.md.
    fn fill_bots(&mut self) {
        let roster = ai::roster();
        // Whatever actually fits is the target, since a narrow room takes fewer
        // than the roster lists.
        for (i, r) in roster.iter().enumerate() {
            // The map's own start wins over the roster's tile: a zone pointed at
            // a new map should not need its roster rewritten to match that map's
            // walls. Headings spread around the circle, and the multiply has to
            // happen wider than u16 or the ninth pilot overflows it.
            let heading = ((i as u32 * 8192) % 65536) as u16;
            // The roster's own team, folded into what the zone allows. A
            // free-for-all is settled after the spawn instead, so that placement
            // still uses the map's shared starts rather than looking for a start
            // marked for team nineteen.
            let team = if self.free_for_all() { 0 } else { r.team % self.teams };
            let ship = self
                .world
                .spawn_on_map(r.class, team, i as u32, r.tile_x, r.tile_y, heading);
            if ship >= 0 {
                if self.free_for_all() {
                    self.world.state.ships[ship as usize].team = ship as u8;
                }
                self.bots.push(ai::Bot::new(ship as u8, r.skill));
                self.names.insert(ship as u8, (r.name.to_string(), true));
            }
        }
        self.bot_target = self.bots.len();
    }

    /// One flag per quadrant, three hundred tiles apart, on the clear cell
    /// offset the map's starts use. Away from every spawn, and far enough from
    /// each other that holding two is a decision.
    fn add_default_flags(&mut self) {
        for (tx, ty) in [(308, 308), (756, 308), (308, 756), (756, 756)] {
            self.world.add_flag(tx, ty);
        }
    }

    /// `max_players` is the zone's, which used to be a constant here while the
    /// key in the file was read by nobody. It bounds humans; the room's own size
    /// is `arena.max_ships` and the two are different questions, since a wide
    /// room with a small player cap is a zone that wants mostly bots.
    fn join(&mut self, name: String, class: u8, max_players: usize,
            tx: mpsc::Sender<Vec<u8>>) -> Option<u64> {
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

        // Which team is the zone's question and the mode's answer, never the
        // client's. `smaller` is ASSS's behaviour, whose MaxTeamDifference
        // defaults to 1, so the balancer tolerates almost nothing.
        let team = self.pick_team(ship);
        {
            let sh = &mut self.world.state.ships[ship as usize];
            sh.cls = class.min(7);
            sh.team = team;
            sh.alive = 1;
            sh.up = [0; sim::UP_COUNT];
        }
        // A full bar, asked for as the number it is, and after the class is set
        // because the ceiling depends on it. This used to be i32::MAX with a
        // comment saying the core would clamp it; the core clamped it by adding
        // a tick of recharge first, which overflowed, so a joining ship spent
        // its first tick at INT32_MIN energy and one hit from dead. The core no
        // longer allows that, and this no longer asks for it.
        let full = self.world.eff_max_energy(ship as usize);
        self.world.state.ships[ship as usize].energy = full;

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

    /// Where an arrival goes. One team is a free-for-all and there is nothing to
    /// decide; otherwise `smaller` counts live ships per team and takes the
    /// thinnest, `random` spreads without counting, and `none` leaves everybody
    /// on team zero.
    /// A free-for-all is not one team. It is no teams: every pilot their own
    /// side.
    ///
    /// Every hostility test in this stack, in the core and in the bots alike,
    /// asks whether two teams differ. A weapon skips a ship on its own team, a
    /// kill on a teammate pays no points and no bounty, a repel does not push
    /// one, and a bot does not so much as look at one. So putting everybody on
    /// side zero did not mean everybody in, it meant combat off: Chaos ran with
    /// no damage, no kills and nine pilots with nothing to shoot at, sitting
    /// perfectly still, while War two doors down played fine.
    ///
    /// A pilot's seat is their side. Ship indices stop at 254 and 255 is
    /// `TEAM_NONE`, so there is room for every seat to be its own team.
    fn free_for_all(&self) -> bool {
        self.teams <= 1
    }

    fn pick_team(&self, joining: u8) -> u8 {
        if self.free_for_all() {
            return joining;
        }
        match self.balance.as_str() {
            "none" => 0,
            "random" => {
                // The world's rng is the simulation's and must not be disturbed
                // by something outside it, so this uses the seat number, which
                // is arbitrary enough and costs no state.
                joining % self.teams
            }
            // "smaller", and anything the catalog let through.
            _ => {
                let mut count = vec![0usize; self.teams as usize];
                for (i, s) in self.world.state.ships.iter().enumerate() {
                    if s.active == 0 || i as u8 == joining {
                        continue;
                    }
                    if let Some(c) = count.get_mut(s.team as usize) {
                        *c += 1;
                    }
                }
                let mut best = 0u8;
                for t in 1..self.teams {
                    if count[t as usize] < count[best as usize] {
                        best = t;
                    }
                }
                best
            }
        }
    }

    fn leave(&mut self, id: u64) {
        if let Some(p) = self.players.remove(&id) {
            self.rating.forget(&p.name);
            // Hand the ship to a bot only while the roster is short of the size
            // this arena was built with. It used to be unconditional, and a join
            // only takes a bot when one is there to take -- so every player who
            // spawned into a fresh slot left a bot behind them that nobody had
            // removed. A live arena configured for nine bots reached sixteen in
            // two minutes of ordinary joining and leaving, on its way to
            // simulating and broadcasting sixty-four.
            if self.bots.len() < self.bot_target {
                self.bots.push(ai::Bot::new(p.ship, 0.5));
                self.names.insert(p.ship, (ai::name_for(p.ship), true));
            } else {
                // Retire it. The slot is reusable: the core hands an inactive
                // one to the next arrival rather than only ever appending.
                let sh = &mut self.world.state.ships[p.ship as usize];
                sh.active = 0;
                sh.alive = 0;
                self.names.remove(&p.ship);
            }
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
            // A look around only when this pilot is due one, so perception
            // costs ten to twenty hertz rather than a hundred and the bots do
            // not all pay for it on the same tick.
            let fresh = b.looks_due().then(|| ai::scan(&self.world, b.ship));
            let buttons = b.think(&ai::own(&self.world, b.ship), fresh);
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
                let _ = p.tx.try_send(m.clone());
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
            let _ = p.tx.try_send(m.clone());
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
            let _ = p.tx.try_send(msg);
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
            let _ = p.tx.try_send(m.clone());
        }
    }

    fn broadcast_roster(&self) {
        let m = self.roster_msg();
        for p in self.players.values() {
            let _ = p.tx.try_send(m.clone());
        }
    }
}

/// The zone and the one arena it is hosting. This held a map of arenas while
/// duels made rooms of their own; with duels out nothing else ever made a
/// second one, and one process to one room is where decision 23 was going
/// anyway.
struct Zone {
    /// Rooms this process holds for its zone, created on demand and reclaimed
    /// when they empty, capped by the zone's `max_rooms`. Never empty: an
    /// instance serving a zone always keeps one, so it still *is* an instance of
    /// that zone and appears as one. See the fill ladder in
    /// docs/architecture/zones-and-arenas.md.
    rooms: Vec<Arena>,
    cfg: config::ConfigWatcher,
    store: persist::Store,
    /// The zone this process is serving, empty when it is running the built-in
    /// room because no catalog reached it.
    zone_name: String,
    /// The catalog as a directory handed it over, and the version, so the
    /// highest offered wins and a disagreement is a log line rather than a vote.
    catalog: Option<fleet::WireCatalog>,
    /// Last measured tick cost, for the metrics that ride in `STATUS`.
    tick_us: u32,
    /// An operator pin. While set, policy stops applying: admin.md's verbs win
    /// over selection, and the pin is displayed with who set it and when.
    pinned: Option<(String, String, u64)>,
    /// Set by a `drain` command or by wanting a different zone. No new joins.
    draining: bool,
    /// Everything about this instance's place in a fleet: its id, the views the
    /// directories pushed, what it has announced. Empty and harmless when no
    /// directory was ever configured.
    fleet: select::Fleet,
}

impl Zone {
    /// Every player in every room, which is what a status push reports.
    ///
    /// There is deliberately no "the arena" accessor. There was one, meaning
    /// room zero, and every caller that used it was wrong once a process held
    /// more than one room: rule 1 let an instance change zone under players in
    /// room two, a kick could not reach them, and their ratings were never
    /// saved. Anything asking about the process asks about all of its rooms.
    fn total_players(&self) -> usize {
        self.rooms.iter().map(|r| r.players.len()).sum()
    }

    /// Where the next arrival goes, per the fill ladder. Rung one is the fullest
    /// room below its player cap, which is most of the work and needs no
    /// coordination. Rung two is a new room here, when every room is at the
    /// zone's fill target and we are below `max_rooms`: 79 KB and a shared map,
    /// which is why it comes before anything involving another process.
    ///
    /// `None` means this instance is out of room, and the client should try the
    /// next address the directory gave it.
    fn room_for_join(&mut self) -> Option<usize> {
        let cap = self.max_players();
        let target = self.fill_target();

        // Rung 1: fullest below cap.
        let best = self
            .rooms
            .iter()
            .enumerate()
            .filter(|(_, r)| r.players.len() < cap)
            .max_by_key(|(_, r)| r.players.len())
            .map(|(i, _)| i);

        // Only grow when every room has reached the target. A room holding six of
        // twenty wants the next six players, not a sibling.
        let all_at_target = self.rooms.iter().all(|r| r.players.len() >= target);
        if let Some(i) = best {
            if !all_at_target || self.rooms.len() >= self.max_rooms() {
                return Some(i);
            }
        }

        // Rung 2: a new room here.
        if self.rooms.len() < self.max_rooms() {
            match self.open_room() {
                Ok(i) => return Some(i),
                Err(e) => {
                    println!("cannot open another room: {e}");
                    return best;
                }
            }
        }
        best
    }

    /// Another simulation of the same zone, sharing the map bytes. Bounded by
    /// `max_rooms`, which bounds both memory and the blast radius of this process
    /// dying, since rooms in a process share its fate.
    fn open_room(&mut self) -> Result<usize, String> {
        let z = self.wire_zone().cloned().ok_or("no zone definition")?;
        // On the map the first room already holds, rather than unpacking the
        // bytes again. Geometry is a megabyte and immutable, so a hundred rooms
        // share one copy; without this the ceiling would be a memory limit
        // instead of a blast-radius one.
        let mut fresh = Self::build_room(&z, Some(&self.rooms[0].world))?;
        prime_ratings(&mut fresh.rating, &load_ladder("zone"));
        self.rooms.push(fresh);
        let n = self.rooms.len();
        println!("opened room {n} of {} for zone {:?}", self.max_rooms(), z.name);
        Ok(n - 1)
    }

    /// A returning pilot's record, into the room they are actually joining.
    ///
    /// The number and its game count move together, always. A rating restored
    /// without its count is a number with no confidence attached: the pilot
    /// reads as still placing, and the next death moves them by a newcomer's K,
    /// which is four times as far as their record says it should. The count was
    /// not saved at all until it was noticed that every deploy un-settled
    /// everybody who had earned a rating.
    fn restore_pilot(&mut self, room: usize, name: &str) {
        let Some(saved) = self.store.rating(name) else {
            return;
        };
        let played = self.store.games(name);
        if let Some(a) = self.rooms.get_mut(room) {
            a.rating.score.insert(name.to_string(), saved);
            a.rating.games.insert(name.to_string(), played);
        }
    }

    /// Every room's ladder to disk. A human is in exactly one room at a time so
    /// their score saves cleanly; a bot name appears in all of them and the last
    /// room wins, which costs nothing because bots are re-seeded from the
    /// calibrated ladder whenever a room is built.
    fn save_ladder(&mut self) {
        let rows: Vec<(String, f64, u32)> = self
            .rooms
            .iter()
            .flat_map(|r| {
                r.rating
                    .score
                    .iter()
                    .map(|(k, v)| (k.clone(), *v, r.rating.games_of(k)))
            })
            .collect();
        for (name, score, played) in rows {
            self.store.set_rating(&name, score);
            self.store.set_games(&name, played);
        }
        if let Err(e) = self.store.flush() {
            println!("could not save ratings: {e}");
        }
    }

    /// Give back rooms nobody is in, keeping the first. A process shrinks as
    /// matches end rather than holding its high-water mark forever.
    fn reclaim_rooms(&mut self) {
        if self.rooms.len() <= 1 {
            return;
        }
        let before = self.rooms.len();
        let mut keep_first = true;
        self.rooms.retain(|r| {
            if keep_first {
                keep_first = false;
                return true;
            }
            !r.players.is_empty()
        });
        if self.rooms.len() != before {
            println!("reclaimed {} empty room(s)", before - self.rooms.len());
        }
    }

    /// One room built from a zone definition. Shared by the first room and by
    /// every room grown after it, so they cannot differ. `on` is a room already
    /// running this zone, whose map the new one borrows instead of unpacking a
    /// second megabyte of identical tiles.
    fn build_room(z: &fleet::WireZone, on: Option<&sim::World>) -> Result<Arena, String> {
        let world = match on {
            Some(w) => w.sibling(0x5eed),
            None => {
                let bytes = fleet::unb64(&z.map_b64).ok_or("map is not base64")?;
                sim::World::from_packed(0x5eed, &bytes).map_err(|e| e.to_string())?
            }
        };
        let def: catalog::ZoneDef =
            toml::from_str(&z.zone_toml).map_err(|e| format!("zone.toml: {e}"))?;
        let mut arena = Arena::with_world_bare(world);
        for w in Arena::apply_config(&mut arena.world, &def.arena) {
            println!("zone {}: {w}", z.name);
        }
        if let Some(m) = def.max_ships {
            arena.world.cfg.max_ships = m;
        }
        arena.mode = modes::build(&z.mode, def.arena.flags, z.teams);
        arena.teams = z.teams.max(1);
        arena.balance = def.balance.clone();
        arena.fill_bots();
        if z.mode == "warzone" {
            arena.add_default_flags();
        }
        Ok(arena)
    }

    /// Take a catalog a directory offered. Highest version wins; a tie with
    /// different content is an author error rather than a race, so it is a log
    /// line naming both directories rather than a vote.
    fn take_catalog(&mut self, c: fleet::WireCatalog, from: &str) {
        let have = self.catalog.as_ref().map(|c| c.version).unwrap_or(0);
        if c.version < have {
            println!(
                "catalog: {from} offered v{} and we hold v{have} from {:?}; keeping ours",
                c.version, self.fleet.catalog_from
            );
            return;
        }
        if c.version == have {
            let same = self
                .catalog
                .as_ref()
                .map(|old| serde_json::to_string(old).ok() == serde_json::to_string(&c).ok())
                .unwrap_or(false);
            if !same {
                println!(
                    "catalog: {from} and {:?} both call this v{have} with different \
                     content; keeping what we hold. This is an author error, not a race",
                    self.fleet.catalog_from
                );
            }
            return;
        }
        println!("catalog: v{} from {from} ({} zones)", c.version, c.zones.len());
        self.fleet.catalog_from = from.to_string();

        // A running room does not change zone because the catalog changed: it
        // takes new settings for the zone it already serves, and the rest at its
        // next drain. A catalog edit is not a reason to disconnect anybody.
        if !self.zone_name.is_empty() {
            if let Some(z) = c.zone(&self.zone_name).cloned() {
                if let Ok(def) = toml::from_str::<catalog::ZoneDef>(&z.zone_toml) {
                    let name = self.zone_name.clone();
                    for r in self.rooms.iter_mut() {
                        for w in Arena::apply_config(&mut r.world, &def.arena) {
                            println!("zone {name}: {w}");
                        }
                        if let Some(m) = def.max_ships {
                            r.world.cfg.max_ships = m;
                        }
                        r.broadcast_settings();
                    }
                }
            }
        }
        self.catalog = Some(c);
        // Deliberately not serving anything here. `default_zone` is what an
        // arena falls back to when it can reach no directory at all; taking it
        // the moment a catalog arrives would have every instance in a fleet grab
        // the same zone and skip selection entirely, which is exactly what the
        // first end-to-end run did. The decision loop chooses, within a couple of
        // seconds, and it is the only thing that chooses.
    }

    /// Tell every directory what we are serving, now rather than on the next
    /// heartbeat. Called on commit, because a directory that learns seconds late
    /// is a directory whose view is stale exactly when another instance is
    /// deciding against it, which is how a redundant commit happens.
    fn push_status(&self) {
        let msg = fleet::frame(fleet::A2D_STATUS, &self.status());
        for tx in self.fleet.senders.values() {
            let _ = tx.send(msg.clone());
        }
    }

    /// Announce an intent to every directory, now rather than on the next
    /// heartbeat. The expiry travels with it, so a crash here releases the claim
    /// on a timer rather than holding a zone empty forever.
    fn announce(&self, zone: &str) {
        let msg = fleet::frame(
            fleet::A2D_INTENT,
            &fleet::Intent {
                zone: zone.to_string(),
                expires_ms: select::INTENT_TTL_MS,
            },
        );
        let mut sent = 0;
        for tx in self.fleet.senders.values() {
            if tx.send(msg.clone()).is_ok() {
                sent += 1;
            }
        }
        println!("selection: announced intent to serve {zone:?} to {sent} directory(s)");
    }

    /// An operator verb from a directory. `unknown_verb` is what lets a
    /// directory be newer than an arena without either pretending.
    fn run_command(&mut self, c: &fleet::Command) -> (&'static str, String) {
        match c.verb.as_str() {
            "drain" => {
                self.draining = true;
                ("done", format!("draining {} player(s)", self.total_players()))
            }
            "pin" => {
                if self.catalog.as_ref().and_then(|k| k.zone(&c.args)).is_none() {
                    return ("refused", format!("no zone {:?} in the catalog", c.args));
                }
                self.pinned = Some((c.args.clone(), c.actor.clone(), fleet::now_ms()));
                let def = self.catalog.as_ref().and_then(|k| k.zone(&c.args)).cloned();
                if let Some(def) = def {
                    if self.total_players() == 0 {
                        if let Err(e) = self.serve_zone(&def) {
                            return ("refused", e);
                        }
                    } else {
                        self.draining = true;
                        return ("done", "pinned; draining before the switch".into());
                    }
                }
                ("done", format!("pinned to {:?}", c.args))
            }
            "unpin" => {
                self.pinned = None;
                ("done", String::new())
            }
            "kick" => {
                // Every room, because an operator naming a player does not know
                // or care which room of this process holds them.
                let before = self.total_players();
                let mut hit = 0;
                for r in self.rooms.iter_mut() {
                    let ids: Vec<u64> = r
                        .players
                        .iter()
                        .filter(|(_, p)| p.name.eq_ignore_ascii_case(&c.args))
                        .map(|(id, _)| *id)
                        .collect();
                    for id in &ids {
                        r.leave(*id);
                    }
                    if !ids.is_empty() {
                        hit += ids.len();
                        r.broadcast_roster();
                    }
                }
                if hit == 0 {
                    ("refused", format!("nobody here called {:?}", c.args))
                } else {
                    ("done", format!("kicked {hit} of {before}"))
                }
            }
            "restart" => {
                println!("restart asked for by {:?}; exiting so the supervisor restarts us",
                         c.actor);
                // The container platform owns restarts. Exiting is the whole
                // implementation, and it is the honest one.
                std::process::exit(0);
            }
            _ => ("unknown_verb", c.verb.clone()),
        }
    }

    fn wire_zone(&self) -> Option<&fleet::WireZone> {
        self.catalog.as_ref()?.zone(&self.zone_name)
    }

    fn fill_target(&self) -> usize {
        self.wire_zone()
            .map(|z| z.fill_target as usize)
            .unwrap_or(catalog::DEFAULT_FILL_TARGET)
    }

    fn max_rooms(&self) -> usize {
        self.wire_zone().map(|z| z.max_rooms as usize).unwrap_or(1).max(1)
    }

    fn max_players(&self) -> usize {
        self.wire_zone()
            .map(|z| z.max_players as usize)
            .unwrap_or(DEFAULT_MAX_PLAYERS)
    }

    /// Bans come from the catalog when there is one, because they are
    /// deployment-wide, and from the local file only when there is not.
    fn is_banned(&self, name: &str) -> bool {
        match &self.catalog {
            Some(c) => c.is_banned(name),
            None => self.cfg.current.is_banned(name),
        }
    }

    /// Take a zone definition and rebuild the room around it: its map, its
    /// settings, its mode. The one path by which a process changes what game it
    /// is running, so the map failing is a refusal rather than a half-change.
    fn serve_zone(&mut self, z: &fleet::WireZone) -> Result<(), String> {
        // From the bytes, not from a sibling: this is a change of zone, so the
        // map the running rooms hold is the wrong map.
        let mut arena = Self::build_room(z, None)?;
        prime_ratings(&mut arena.rating, &load_ladder("zone"));
        // A change of zone replaces every room: they all served the old game.
        self.rooms = vec![arena];
        self.zone_name = z.name.clone();
        self.draining = false;
        println!(
            "serving zone {:?}: mode {}, {} ships, {} players, {} team(s)",
            z.name, z.mode, z.max_ships, z.max_players, z.teams
        );
        Ok(())
    }
}

/// Put an arena's ratings on the same footing as every other: the AI marked
/// so it moves slowly against humans, each bot seeded from the calibrated
/// prior, and the anchor pinned last so nothing can overwrite the fixed
/// point the rest of the ladder is measured against.
/// A call sign as the rest of the system may hold it.
///
/// The wire hands us arbitrary bytes, and a name travels further than anywhere
/// else a client can reach: into every other player's roster, into the kill
/// feed and so into the logs, into the ratings map and so onto disk, and into
/// the argument of an operator's kick. So it is printable ASCII, single-spaced,
/// and at most 24 characters -- which is also the roster wire format's cap, so
/// what is stored is what everyone sees. Control characters would otherwise
/// ride into the logs (a newline forges a log line), and a 64 MB name is a
/// memory bill somebody else pays.
fn sanitize_name(raw: &str) -> String {
    let mut out = String::with_capacity(24);
    let mut pending_space = false;
    for c in raw.chars() {
        if c == ' ' || c.is_whitespace() {
            pending_space = !out.is_empty();
            continue;
        }
        if !c.is_ascii_graphic() {
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(c);
        if out.len() >= 24 {
            break;
        }
    }
    if out.is_empty() {
        "pilot".into()
    } else {
        out
    }
}

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
        Zone {
            rooms: vec![arena],
            cfg,
            store,
            zone_name: String::new(),
            catalog: None,
            tick_us: 0,
            pinned: None,
            draining: false,
            fleet: select::Fleet::default(),
        }
    }

    /// Re-read the zone file and push the new numbers into every live arena.
    /// Nobody is disconnected: an operator tuning a bounce factor should not
    /// cost the room its round.
    fn reload(&mut self) {
        if let Some(msg) = self.cfg.poll() {
            println!("{msg}");
            // Cloned so the arena can be borrowed mutably while reading it, and
            // applied to every room: they are all the same game.
            let block = self.cfg.current.arena.clone();
            for r in self.rooms.iter_mut() {
                for w in Arena::apply_config(&mut r.world, &block) {
                    println!("zone: {w}");
                }
                r.broadcast_settings();
            }
        }
    }

    /// What this arena server tells a directory, and anybody else who asks.
    /// This doubles as the verification answer: a directory dials the claimed
    /// address, asks for status, and requires a well-formed reply, so the shape
    /// here is what proves an address works.
    fn status_json(&self) -> String {
        serde_json::to_string(&self.status()).unwrap_or_default()
    }

    fn status(&self) -> fleet::Status {
        let zone = self.zone_name.clone();
        let target = self.fill_target();
        fleet::Status {
            zone,
            players: self.total_players() as u32,
            bots: self.rooms.iter().map(|r| r.bots.len()).sum::<usize>() as u32,
            rooms: self.rooms.len() as u32,
            max_rooms: self.max_rooms() as u32,
            // This instance's own answer to "am I out of room", so the rule lives
            // in one place rather than being recomputed by every reader. Capped
            // means every room is at the target *and* there is no headroom to
            // open another, which is the fill ladder's second rung exhausted.
            capped: self.rooms.iter().all(|r| r.players.len() >= target)
                && self.rooms.len() >= self.max_rooms(),
            metrics: fleet::Metrics {
                tick_us: self.tick_us,
                // The worst-off client in the process. A depth near `OUT_QUEUE`
                // is a connection that cannot keep up and is losing snapshots,
                // which is the one player-visible symptom an operator cannot see
                // from a player count.
                queue_depth: self
                    .rooms
                    .iter()
                    .flat_map(|r| r.players.values())
                    .map(|p| (OUT_QUEUE - p.tx.capacity()) as u32)
                    .max()
                    .unwrap_or(0),
                ..Default::default()
            },
        }
    }

    /// The name a joining player is shown. The catalog's when this process is
    /// serving a catalog zone, because that is the game they picked; the local
    /// file's only when no directory was ever reached.
    fn zone_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_ZONE];
        let (name, desc) = match self.wire_zone() {
            Some(z) => (z.name.clone(), z.description.clone()),
            None => (
                self.cfg.current.name.clone(),
                self.cfg.current.description.clone(),
            ),
        };
        m.extend_from_slice(format!("{name}\n{desc}").as_bytes());
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

/// Where the directories are. `VW_DIRECTORY` names a host, which is resolved,
/// so one hostname with several records is a whole deployment and a directory can
/// be added or moved without touching an arena server. That is the DNS decision
/// in docs/architecture/discovery.md: `directory.vectorwake.net` resolves to
/// every directory of this deployment.
///
/// An explicit `ws://` or `wss://` URL is taken as given, which is what a
/// developer running one of each on a laptop wants.
async fn directory_urls() -> Vec<String> {
    let spec = std::env::var("VW_DIRECTORY").unwrap_or_default();
    if spec.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for part in spec.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        if part.starts_with("ws://") || part.starts_with("wss://") {
            out.push(part.to_string());
            continue;
        }
        // A bare host, optionally with a port. Resolve it and take every record,
        // so a round-robin name is a list of directories.
        let (host, port) = match part.rsplit_once(':') {
            Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) => (h, p.to_string()),
            _ => (part, "9000".to_string()),
        };
        match tokio::net::lookup_host(format!("{host}:{port}")).await {
            Ok(addrs) => {
                let mut seen = Vec::new();
                for a in addrs {
                    // wss for a real hostname, because the token is a bearer
                    // credential and the directory will refuse it in the clear.
                    // Loopback is development and stays ws.
                    let scheme = if a.ip().is_loopback() { "ws" } else { "wss" };
                    // Dial the name rather than the address so TLS verifies: the
                    // certificate is issued for the hostname, and all of a
                    // deployment's directories share it.
                    let url = if a.ip().is_loopback() {
                        format!("{scheme}://{a}")
                    } else {
                        format!("{scheme}://{host}:{port}")
                    };
                    if !seen.contains(&url) {
                        seen.push(url);
                    }
                }
                if seen.is_empty() {
                    println!("VW_DIRECTORY {part:?} resolved to nothing");
                }
                out.extend(seen);
            }
            Err(e) => println!("VW_DIRECTORY {part:?}: {e}"),
        }
    }
    // Shuffled, so a fleet of identical containers does not all prefer the same
    // directory. The order is arbitrary and only needs to differ between hosts.
    let n = out.len();
    if n > 1 {
        let seed = (fleet::now_ms() as usize).wrapping_mul(2654435761);
        out.rotate_left(seed % n);
    }
    println!("directories: {}", out.join(", "));
    out
}

/// Either kind of accepted connection, boxed so the connection handler is
/// written once. tokio implements AsyncRead and AsyncWrite for Box<T>, and a
/// trait object carries its supertraits, so this needs no glue of its own.
pub trait Conn: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send> Conn for T {}

/// Build a TLS acceptor from PEM files, or None when the zone is plain ws.
/// A zone that is configured for TLS and cannot load its certificate must
/// not quietly fall back to cleartext: the operator asked for wss, and
/// serving ws instead would look like it worked.
pub fn tls_acceptor(cert: &str, key: &str) -> Option<tokio_rustls::TlsAcceptor> {
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
        directory::run().await;
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("catalog") {
        catalog::run_check();
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("token") {
        catalog::run_token();
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
    let scheme = if tls.is_some() { "wss" } else { "ws" };
    println!("vectorwake arena server listening on {scheme}://{addr}");

    // Join a fleet, if one was configured. An arena server with no directory is
    // still a whole game: it serves the built-in room or its local zone file to
    // anybody who knows its address, which is the Offline state in
    // docs/architecture/zones-and-arenas.md and the reason a discovery outage is
    // not a gameplay outage.
    {
        let mut z = zone.lock().await;
        z.fleet.instance = select::Fleet::load_instance_id(&dir);
        z.fleet.region = std::env::var("VW_REGION").unwrap_or_else(|_| "local".into());
        // What a client should dial. Defaults to the listen address, which is
        // right for a single host and wrong behind NAT, so it is overridable.
        z.fleet.address = std::env::var("VW_ADDRESS")
            .unwrap_or_else(|_| format!("{scheme}://{addr}"));
        z.fleet.willing = std::env::var("VW_ZONES")
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        println!(
            "instance {} in region {:?}, reachable at {}",
            z.fleet.instance, z.fleet.region, z.fleet.address
        );
        if !z.fleet.willing.is_empty() {
            println!("  willing to serve only {:?}", z.fleet.willing);
        }
    }
    let token = std::env::var("VW_TOKEN").unwrap_or_default();
    let urls = directory_urls().await;
    if urls.is_empty() {
        println!("no directory configured (VW_DIRECTORY); serving standalone");
    } else if token.is_empty() {
        println!("VW_DIRECTORY is set but VW_TOKEN is empty; serving standalone");
    } else {
        for url in urls {
            tokio::spawn(select::register_with(url, token.clone(), zone.clone()));
        }
        tokio::spawn(select::decide_loop(zone.clone()));
    }

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
                    z.save_ladder();
                }
                // Every room, in order. The process holds one arena per room and
                // ticks them all on this thread: at 16 us for sixty-four ships
                // and 1.6 for two, a hundred duel rooms is a sixth of a core, so
                // there is nothing here a pool would buy.
                let snap = n % SNAPSHOT_EVERY == 0;
                let t0 = std::time::Instant::now();
                for a in z.rooms.iter_mut() {
                    a.tick();
                    if snap {
                        a.broadcast_snapshot(&mut buf);
                        a.broadcast_banner();
                    }
                }
                z.tick_us = t0.elapsed().as_micros() as u32;

                // A drain that has finished is an instance free to choose again,
                // and an empty extra room is memory to give back.
                if n % 100 == 0 {
                    z.reclaim_rooms();
                    if z.draining && z.total_players() == 0 {
                        println!("drain complete");
                        z.draining = false;
                        if let Some((want, who, _)) = z.pinned.clone() {
                            if let Some(def) =
                                z.catalog.as_ref().and_then(|c| c.zone(&want)).cloned()
                            {
                                match z.serve_zone(&def) {
                                    Ok(()) => println!("pinned to {want:?} by {who}"),
                                    Err(e) => println!("cannot serve pinned {want:?}: {e}"),
                                }
                            }
                        }
                        z.push_status();
                    }
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
            // Incoming frames are capped far below the library default of
            // 64 MiB, which is buffered in full per frame. Nothing a client
            // legitimately sends is bigger than a join -- a tag, a few bytes,
            // a zone name and a call sign -- so a stranger on an open port
            // gets to cost this process kilobytes, not gigabytes.
            let cfg = tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
                max_message_size: Some(C2S_MAX),
                max_frame_size: Some(C2S_MAX),
                ..Default::default()
            };
            let ws = match tokio_tungstenite::accept_async_with_config(stream, Some(cfg)).await {
                Ok(w) => w,
                Err(_) => return,
            };
            let (mut sink, mut source) = ws.split();
            let (tx, mut rx) = mpsc::channel::<Vec<u8>>(OUT_QUEUE);

            let writer = tokio::spawn(async move {
                while let Some(msg) = rx.recv().await {
                    if sink.send(Message::Binary(msg)).await.is_err() {
                        return;
                    }
                }
                // A proper close once the channel is done, so a refused client
                // sees a closed socket rather than a dropped one and can tell
                // "you are not welcome" from "the network ate it".
                let _ = sink.close().await;
            });

            // This connection's id in the arena, once it has joined.
            // Which room, and which id within it.
            let mut seat: Option<(usize, u64)> = None;
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
                        let _ = tx.try_send(m);
                    }
                    C2S_JOIN if seat.is_none() => {
                        let class = data.get(1).copied().unwrap_or(0);
                        let proto = data.get(2).copied().unwrap_or(0);
                        let zlen = data.get(3).copied().unwrap_or(0) as usize;
                        let want = String::from_utf8_lossy(
                            data.get(4..4 + zlen).unwrap_or_default(),
                        )
                        .to_string();
                        let name = sanitize_name(&String::from_utf8_lossy(
                            data.get(4 + zlen..).unwrap_or_default(),
                        ));
                        let mut z = zone.lock().await;

                        // A refusal has to say which of five things went wrong,
                        // because three mean "try another instance" and two mean
                        // "stop trying". The code is the first byte after the tag.
                        let deny = |code: u8, why: &str| {
                            let mut m = vec![S2C_DENIED, code];
                            m.extend_from_slice(why.as_bytes());
                            m
                        };
                        if proto != CLIENT_PROTOCOL {
                            // Before anything else: a client that misparses this
                            // wire would misread every refusal below it too.
                            let _ = tx.try_send(deny(
                                DENY_VERSION,
                                &format!("this zone speaks protocol {CLIENT_PROTOCOL}"),
                            ));
                            break;
                        }
                        // A player picked a game, not an address. This instance may
                        // have changed zone since the browse reply they are acting
                        // on, and sending them into a different game because the
                        // address still answers is worse than telling them to
                        // re-browse.
                        if !want.is_empty() && want != z.zone_name {
                            let _ = tx.try_send(deny(
                                DENY_WRONG_ZONE,
                                &format!(
                                    "this instance serves {:?} now; re-browse",
                                    z.zone_name
                                ),
                            ));
                            break;
                        }
                        if z.is_banned(&name) {
                            let _ = tx.try_send(deny(DENY_BANNED, "you are banned here"));
                            break;
                        }
                        if z.draining {
                            let _ = tx.try_send(deny(
                                DENY_DRAINING,
                                "this arena is draining; try another instance",
                            ));
                            break;
                        }
                        let _ = tx.try_send(z.zone_msg());
                        let cap = z.max_players();
                        // The fill ladder: fullest room below cap, else a new room
                        // here if the zone allows one, else this instance is out
                        // of room and the client should try the next address.
                        let Some(idx) = z.room_for_join() else {
                            let _ = tx.try_send(deny(
                                DENY_FULL,
                                "no room here; try another instance of this zone",
                            ));
                            break;
                        };
                        // Into the room they are actually joining. Rooms keep their
                        // own ladders, so putting a returning player's rating in
                        // room zero would leave them unrated wherever they landed.
                        z.restore_pilot(idx, &name);
                        let a = &mut z.rooms[idx];
                        if let Some(new_id) = a.join(name, class, cap, tx.clone()) {
                            seat = Some((idx, new_id));
                            let ship = a.players[&new_id].ship;
                            let mut m = vec![S2C_MAP];
                            m.extend_from_slice(&a.world.packed_map());
                            let _ = tx.try_send(m);
                            let mut c = vec![S2C_SETTINGS];
                            c.extend_from_slice(&a.world.packed_settings());
                            let _ = tx.try_send(c);
                            let mut w = vec![S2C_WELCOME, ship];
                            w.extend_from_slice(&a.world.state.tick.to_le_bytes());
                            let _ = tx.try_send(w);
                            a.broadcast_roster();
                        } else {
                            let _ = tx.try_send(deny(DENY_FULL, "no seat in that room"));
                        }
                        // A join changes the count a directory reports, and a
                        // stale count is a directory routing players to the wrong
                        // place, so it goes out now rather than on the heartbeat.
                        z.push_status();
                    }
                    C2S_SHIP => {
                        // A hull change, in place. The core refuses it unless
                        // the pilot is alive and at a full bar, which is what
                        // stops it being an escape from a fight -- a fresh
                        // ship is a fresh bar. Nothing is sent back: the next
                        // snapshot carries the new class, and a refusal leaves
                        // the old one, which is the same answer either way.
                        if data.len() >= 2 {
                            if let Some((room, pid)) = seat {
                                let cls = data[1];
                                let mut z = zone.lock().await;
                                if let Some(a) = z.rooms.get_mut(room) {
                                    let ship = a.players.get(&pid).map(|p| p.ship);
                                    if let Some(ship) = ship {
                                        a.world.set_ship_class(ship, cls);
                                    }
                                }
                            }
                        }
                    }
                    C2S_INPUT => {
                        // buttons: u16, tick: u32. The tick is advisory: the
                        // server applies inputs when it receives them and
                        // echoes the number back so the client can reconcile.
                        if data.len() >= 7 {
                            if let Some((room, pid)) = seat {
                                let buttons = u16::from_le_bytes([data[1], data[2]]);
                                let t = u32::from_le_bytes([data[3], data[4], data[5], data[6]]);
                                let mut z = zone.lock().await;
                                if let Some(p) = z
                                    .rooms
                                    .get_mut(room)
                                    .and_then(|a| a.players.get_mut(&pid))
                                {
                                    p.buttons = buttons;
                                    p.last_input_tick = t;
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }

            if let Some((room, pid)) = seat {
                let mut z = zone.lock().await;
                if let Some(a) = z.rooms.get_mut(room) {
                    a.leave(pid);
                    a.broadcast_roster();
                }
                // An empty room goes back, except the first: a process shrinks as
                // matches end rather than holding its high-water mark.
                z.reclaim_rooms();
                z.push_status();
            }

            // Let the writer drain before it goes. A refusal is enqueued and then
            // the read loop breaks immediately, so aborting here threw away the
            // very byte that tells a client whether to try the next instance or
            // stop trying. Dropping our sender closes the channel, the writer
            // finishes what is in it and exits; the timeout is for the case where
            // the socket is gone and the send will never complete.
            let mut writer = writer;
            drop(tx);
            if tokio::time::timeout(std::time::Duration::from_secs(2), &mut writer)
                .await
                .is_err()
            {
                writer.abort();
            }
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

    // ---- rooms on demand ---------------------------------------------------
    //
    // The fill ladder's first two rungs live entirely inside one process, so
    // they are testable without a directory, a socket, or a second binary.

    /// A zone as a catalog would deliver it, with a real packed map so
    /// `build_room` takes the same path it takes in production.
    fn wire_zone(rooms: u32, target: u32, cap: u32) -> fleet::WireZone {
        fleet::WireZone {
            name: "testzone".into(),
            description: "a zone for tests".into(),
            mode: "arena".into(),
            max_ships: 64,
            max_players: cap,
            fill_target: target,
            max_rooms: rooms,
            teams: 1,
            balance: "smaller".into(),
            map_b64: fleet::b64(&sim::World::new(1).packed_map()),
            // A zone's name lives in the catalog that references it, never in the
            // zone's own file, so there is one place a name can be.
            zone_toml: "description = \"a zone for tests\"\n".into(),
        }
    }

    /// A zone process already serving that definition. No config file and no
    /// store file: both read defaults when the path is absent, which is what a
    /// catalog-served arena runs on anyway.
    fn serving(rooms: u32, target: u32, cap: u32) -> Zone {
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, persist::Store::open("/nonexistent/state.json"),
                              HashMap::new());
        let def = wire_zone(rooms, target, cap);
        z.catalog = Some(fleet::WireCatalog {
            version: 1,
            name: "test".into(),
            default_zone: "testzone".into(),
            zones: vec![def.clone()],
            ..Default::default()
        });
        z.serve_zone(&def).expect("the definition builds a room");
        z
    }

    /// Seat `n` players in a room without a socket on the other end. A dropped
    /// receiver is fine: every send is `let _ =`, because a client that has gone
    /// away must not take the tick loop with it.
    fn seat(z: &mut Zone, room: usize, n: usize) {
        let cap = z.max_players();
        for i in 0..n {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            z.rooms[room]
                .join(format!("p{room}-{i}"), 0, cap, tx)
                .expect("a seat below the cap");
        }
    }

    #[test]
    fn a_free_for_all_has_enemies_in_it() {
        // Chaos ran for a day with nothing able to hit anything. `teams = 1` put
        // every pilot on side zero, and every hostility test in the stack is
        // whether two sides differ: no weapon could reach a ship, no kill paid,
        // and no bot could see a target, so nine of them sat still while a
        // player flew around an arena that could not fight back.
        let mut z = serving(1, 6, 16);
        assert!(z.rooms[0].free_for_all(), "the fixture is a one-team zone");

        let a = &z.rooms[0];
        let mut sides = std::collections::HashSet::new();
        let mut ships = 0;
        for (i, s) in a.world.state.ships.iter().enumerate() {
            if s.active == 0 {
                continue;
            }
            ships += 1;
            assert!(sides.insert(s.team), "ship {i} shares a side with somebody");
            assert_ne!(s.team, sim::TEAM_NONE, "a pilot is never nobody's side");
        }
        assert!(ships >= 2, "a roster to fight over");

        // And the bots' own perception, which is where the symptom was: a
        // pilot with a teammate in front of them sees nobody, plans nothing,
        // and holds still. Put two together rather than trusting the map's
        // starts, so this measures the rule and not the geometry.
        let (a, b) = (a.bots[0].ship, a.bots[1].ship);
        let room = &mut z.rooms[0];
        room.world.state.ships[b as usize].x = room.world.state.ships[a as usize].x + 40 * 256;
        room.world.state.ships[b as usize].y = room.world.state.ships[a as usize].y;
        assert!(ai::scan(&room.world, a).foe.is_some(), "nobody to fight");
        assert!(ai::scan(&room.world, b).foe.is_some(), "and not one-sided");

        // And a joining human is their own side too, not folded in with the
        // pilot whose seat they took.
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0].join("human".into(), 0, 16, tx).expect("a seat");
        let ship = z.rooms[0].players[&id].ship;
        let mine = z.rooms[0].world.state.ships[ship as usize].team;
        for (i, s) in z.rooms[0].world.state.ships.iter().enumerate() {
            if s.active == 0 || i as u8 == ship {
                continue;
            }
            assert_ne!(s.team, mine, "the human shares a side with ship {i}");
        }
    }

    #[test]
    fn a_pilot_who_can_see_nobody_goes_looking() {
        // The other reason the arena was full of statues. A bot with nothing in
        // sight returned no buttons at all, so it stopped where it stood and
        // stayed there for as long as the room was up.
        let mut z = serving(1, 6, 16);
        let a = &mut z.rooms[0];
        // Alone: retire everybody but one pilot, so there is provably nothing
        // for them to see.
        let keep = a.bots[0].ship;
        for i in 0..a.world.state.ship_count as usize {
            if i as u8 != keep {
                a.world.state.ships[i].active = 0;
            }
        }
        let mut bot = a.bots.remove(0);
        let mut moved = false;
        for _ in 0..400 {
            let fresh = bot.looks_due().then(|| ai::scan(&a.world, keep));
            let buttons = bot.think(&ai::own(&a.world, keep), fresh);
            a.world.step(&[sim::sim_input { ship: keep, buttons }]);
            let sh = &a.world.state.ships[keep as usize];
            if sh.vx != 0 || sh.vy != 0 {
                moved = true;
                break;
            }
        }
        assert!(moved, "a pilot with nobody in sight sat still instead of looking");
    }

    #[test]
    fn a_two_team_zone_still_has_two_teams() {
        // The other half of the same rule: a warzone must not become a
        // free-for-all with two flags in it.
        let mut def = wire_zone(1, 6, 16);
        def.teams = 2;
        def.mode = "warzone".into();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, persist::Store::open("/nonexistent/state.json"),
                              HashMap::new());
        z.serve_zone(&def).expect("a room");
        assert!(!z.rooms[0].free_for_all());
        let sides: std::collections::HashSet<u8> = z.rooms[0]
            .world
            .state
            .ships
            .iter()
            .filter(|s| s.active != 0)
            .map(|s| s.team)
            .collect();
        assert_eq!(sides.len(), 2, "two sides, whatever the roster says");
    }

    #[test]
    fn a_settled_pilot_is_still_settled_after_a_restart() {
        // The bug this covers: the file held the rating and not the game count,
        // so a pilot with forty rated deaths came back reading as placing, and
        // their next death moved them by a newcomer's K.
        let path = std::env::temp_dir()
            .join(format!("vw-ladder-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);

        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, persist::Store::open(&path), HashMap::new());
        let def = wire_zone(1, 6, 16);
        z.serve_zone(&def).expect("a room");
        z.rooms[0].rating.score.insert("veteran".into(), 1640.0);
        z.rooms[0].rating.games.insert("veteran".into(), 40);
        z.save_ladder();

        // A new process, reading what the last one wrote.
        let (cfg2, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z2 = Zone::new(cfg2, persist::Store::open(&path), HashMap::new());
        z2.serve_zone(&def).expect("a room");
        assert_eq!(z2.rooms[0].rating.games_of("veteran"), 0, "not until they join");
        z2.restore_pilot(0, "veteran");
        assert_eq!(z2.rooms[0].rating.rating_of("veteran"), 1640.0);
        assert_eq!(z2.rooms[0].rating.games_of("veteran"), 40);
        assert!(z2.rooms[0].rating.tier_of("veteran").is_some(),
                "a settled pilot is shown a tier, not 'placing'");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_room_fills_before_a_second_one_opens() {
        // Rung one: the fullest room below cap. A room holding four of a target
        // of six wants the next arrival, not a sibling with nobody in it.
        let mut z = serving(4, 6, 16);
        assert_eq!(z.rooms.len(), 1, "one room to start");
        for _ in 0..6 {
            let i = z.room_for_join().expect("room");
            assert_eq!(i, 0, "everything lands in the first room until it hits target");
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 1, "still one room at exactly the target");

        // The seventh is the first arrival every room could refuse to concentrate.
        let i = z.room_for_join().expect("room");
        assert_eq!(i, 1, "so a second room opens for them");
        assert_eq!(z.rooms.len(), 2);
    }

    #[test]
    fn the_room_ceiling_holds_and_players_stack_past_the_target() {
        // `max_rooms` is a ceiling, not a target: once it is reached the fill
        // target stops mattering and rooms take players up to `max_players`.
        let mut z = serving(2, 2, 5);
        for _ in 0..10 {
            let Some(i) = z.room_for_join() else { break };
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 2, "never a third room");
        assert_eq!(z.total_players(), 10, "two rooms of five");
        assert!(z.status().capped, "and the instance says so");
        assert_eq!(z.room_for_join(), None, "the eleventh is sent elsewhere");
    }

    #[test]
    fn an_emptied_room_goes_back_but_never_the_first() {
        let mut z = serving(3, 1, 16);
        for _ in 0..3 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 3, "a target of one grows a room per player");

        // Empty the last two. The first stays whatever happens: an instance
        // serving a zone always has a room, or it is not an instance of it.
        for r in 1..3 {
            let ids: Vec<u64> = z.rooms[r].players.keys().copied().collect();
            for id in ids {
                z.rooms[r].leave(id);
            }
        }
        z.reclaim_rooms();
        assert_eq!(z.rooms.len(), 1, "the empty ones are given back");

        let ids: Vec<u64> = z.rooms[0].players.keys().copied().collect();
        for id in ids {
            z.rooms[0].leave(id);
        }
        z.reclaim_rooms();
        assert_eq!(z.rooms.len(), 1, "and the first survives being empty");
    }

    #[test]
    fn every_room_runs_the_same_game() {
        // Rooms differing would make which room you landed in matter, which is
        // the one thing the fill ladder is allowed to decide for a player.
        let mut z = serving(2, 1, 16);
        seat(&mut z, 0, 1);
        let i = z.room_for_join().expect("a second room");
        assert_eq!(i, 1);
        assert_eq!(z.rooms[0].world.cfg.max_ships, z.rooms[1].world.cfg.max_ships);
        assert_eq!(z.rooms[0].teams, z.rooms[1].teams);
        // A joining pilot takes a bot's slot, so the roster is one shorter where
        // somebody sat down. Bots plus players is what stays equal.
        assert_eq!(z.rooms[0].bots.len() + z.rooms[0].players.len(),
                   z.rooms[1].bots.len() + z.rooms[1].players.len(),
                   "including the roster of bots");
        assert_eq!(z.rooms[0].world.packed_map(), z.rooms[1].world.packed_map());
        // The same tiles, not a copy of them. A megabyte per room would make
        // `max_rooms` a memory limit rather than the blast-radius limit it is
        // meant to be, and would put the per-room figure in hosting.md out by
        // a factor of thirteen.
        assert!(
            std::sync::Arc::ptr_eq(&z.rooms[0].world.map, &z.rooms[1].world.map),
            "rooms of one zone share one map"
        );
        assert_eq!(std::sync::Arc::strong_count(&z.rooms[0].world.map), 2);
    }

    #[test]
    fn a_hundred_rooms_share_one_map() {
        // What M7.5 asks for: a small-room zone grows to its ceiling in one
        // process, and the geometry is paid for once.
        let mut z = serving(100, 1, 2);
        for _ in 0..100 {
            let Some(i) = z.room_for_join() else { break };
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 100, "the ceiling is reachable");
        assert_eq!(z.total_players(), 100);
        let map = z.rooms[0].world.map.clone();
        for (n, r) in z.rooms.iter().enumerate() {
            assert!(std::sync::Arc::ptr_eq(&map, &r.world.map), "room {n} shares it");
        }
    }

    #[test]
    fn changing_zone_replaces_every_room() {
        let mut z = serving(3, 1, 16);
        for _ in 0..3 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 3);
        let other = fleet::WireZone { name: "elsewhere".into(), ..wire_zone(3, 1, 16) };
        z.serve_zone(&other).expect("it builds");
        assert_eq!(z.zone_name, "elsewhere");
        assert_eq!(z.rooms.len(), 1, "the old rooms served the old game");
        assert_eq!(z.total_players(), 0);
    }

    #[test]
    fn a_kick_reaches_a_player_in_any_room() {
        let mut z = serving(2, 1, 16);
        seat(&mut z, 0, 1);
        let i = z.room_for_join().expect("a second room");
        seat(&mut z, i, 1);
        // p1-0 is in room one, which the operator neither knows nor should.
        let (outcome, _why) = z.run_command(&fleet::Command {
            command_id: 1,
            verb: "kick".into(),
            args: "p1-0".into(),
            actor: "tester".into(),
        });
        assert_eq!(outcome, "done");
        assert_eq!(z.total_players(), 1);
    }

    #[test]
    fn a_client_that_stops_reading_costs_a_bounded_amount() {
        // The queue used to be unbounded, so a client that stopped reading made
        // the process allocate for as long as it stayed connected. A snapshot is
        // a whole state pack, so dropping one is correct: the next supersedes it.
        let mut z = serving(1, 2, 4);
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0].join("stalled".into(), 0, 4, tx).expect("a seat");
        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..OUT_QUEUE * 10 {
            z.rooms[0].tick();
            z.rooms[0].broadcast_snapshot(&mut buf);
        }
        assert_eq!(rx.len(), OUT_QUEUE, "the queue stops at the bound");
        assert_eq!(z.status().metrics.queue_depth, OUT_QUEUE as u32,
                   "and an operator can see which connection is drowning");
        // Still in the room, still simulated: falling behind is not an eviction.
        assert!(z.rooms[0].players.contains_key(&id));
    }

    #[test]
    fn churn_does_not_grow_the_roster_or_the_ship_count() {
        // The leak this pins was found by joining and leaving a live arena for
        // two minutes: a zone configured for nine bots reached sixteen, on its
        // way to sixty-four. `leave` handed every departing player's ship to a
        // fresh bot, while `join` only takes a bot when one is there to take --
        // so each player who spawned into a new slot left a bot behind them.
        //
        // Nothing reported it. Status was green, the arena was serving, and the
        // only outward sign was a browse list advertising more AI every hour and
        // a tick cost quietly climbing.
        let mut z = serving(1, 4, 32);
        let bots0 = z.rooms[0].bots.len();
        let ships0 = z.rooms[0].world.state.ship_count;
        assert!(bots0 > 0, "the fixture has a roster to lose");
        assert_eq!(z.rooms[0].bot_target, bots0);

        // More players at once than there are bots, so some must spawn into
        // fresh slots -- which is the only case that leaked.
        for _round in 0..6 {
            let mut seated = Vec::new();
            let cap = z.max_players();
            for i in 0..(bots0 + 5) {
                let (tx, _rx) = mpsc::channel(OUT_QUEUE);
                if let Some(id) = z.rooms[0].join(format!("churn{i}"), 0, cap, tx) {
                    seated.push(id);
                }
            }
            for id in seated {
                z.rooms[0].leave(id);
            }
        }

        assert_eq!(z.rooms[0].bots.len(), bots0,
                   "the roster came back to the size it was built with");
        assert_eq!(z.rooms[0].players.len(), 0);
        // The count is a high-water mark and may have risen once to hold the
        // extra concurrent players, but it must not climb every round: the core
        // hands an inactive slot to the next arrival.
        let ships1 = z.rooms[0].world.state.ship_count;
        assert!(u16::from(ships1) <= u16::from(ships0) + (bots0 + 5) as u16,
                "ship_count {ships1} grew past one peak from {ships0}");
        let active = (0..ships1 as usize)
            .filter(|&i| z.rooms[0].world.state.ships[i].active != 0)
            .count();
        assert_eq!(active, bots0, "only the bots are left flying");
    }

    #[test]
    fn a_name_is_printable_bounded_and_never_empty() {
        // The wire hands us arbitrary bytes and a name travels further than
        // anything else a client controls: rosters, logs, the ratings file,
        // an operator's kick argument.
        assert_eq!(sanitize_name("Kestrel"), "Kestrel", "a normal name is untouched");
        assert_eq!(sanitize_name("two  words"), "two words");
        assert_eq!(sanitize_name("  padded\t"), "padded");
        assert_eq!(
            sanitize_name("evil\nname"),
            "evil name",
            "a newline would forge a log line; it becomes a space"
        );
        // The ESC byte is what arms a terminal escape sequence; with it gone
        // the "[2J" left behind is inert text, which is the property that
        // matters when a name is printed into a log.
        assert_eq!(sanitize_name("a\u{1b}[2Jb\u{0}c"), "a[2Jbc");
        assert_eq!(sanitize_name("").as_str(), "pilot");
        assert_eq!(sanitize_name("\u{200b}\u{202e}").as_str(), "pilot",
                   "invisible unicode cannot be a whole name");
        let huge = "x".repeat(10_000_000);
        assert_eq!(sanitize_name(&huge).len(), 24, "10 MB of name stores 24 bytes");
        // The cap matches the roster wire format, so what is stored is what
        // every other player is shown.
        assert_eq!(sanitize_name(&huge).len(), 24usize.min(24));
    }

    #[test]
    fn a_hostile_name_lands_sanitized_in_the_room() {
        let mut z = serving(1, 4, 8);
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let cap = z.max_players();
        let id = z.rooms[0]
            .join(sanitize_name("bad\r\nguy\u{7f}"), 0, cap, tx)
            .expect("a seat");
        assert_eq!(z.rooms[0].players[&id].name, "bad guy");
    }

    #[test]
    fn a_joining_player_is_told_the_zone_they_picked() {
        // Not the local file's name: this process is serving a catalog zone, and
        // the name in the browse list is the name they chose from.
        let z = serving(1, 6, 16);
        let msg = z.zone_msg();
        let text = String::from_utf8_lossy(&msg[1..]).to_string();
        assert!(text.starts_with("testzone\n"), "{text:?}");
        assert!(text.contains("a zone for tests"), "{text:?}");
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
            bomb = ["burst"]
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
        // Every hull carries a rack in the baseline now, the way every one
        // of the original's ships does, so what this proves is that the named
        // weapon replaced the rack rather than sat beside it.
        let fresh = sim::World::new(1);
        let base = fresh.cfg.patterns[fresh.cfg.classes[spire].trigger[1][0] as usize];
        assert_ne!(base.count, p.count, "the zone's weapon is not the baseline's");
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
            bomb = []
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
            gun = ["also-not-a-weapon"]
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
        // A bomb rung buys no damage. BombDamageLevel is defined "for all
        // bomb levels" and there is no upgrade beside it; what a level costs
        // is BombFireEnergyUpgrade, so that is where the ladder shows.
        assert_eq!(top.damage, base.damage, "a bomb rung is the same bomb");
        let top_p = w.cfg.patterns[rungs[2] as usize];
        let base_p = w.cfg.patterns[rungs[0] as usize];
        assert!(top_p.energy > base_p.energy, "and it costs more to let go");
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
            bomb = ["repel"]
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

    /// `mode` and `flags` were documented keys that nobody read: the arena
    /// built a four-flag warzone whatever the file said.
    #[test]
    fn a_zone_picks_its_mode_and_how_many_flags_it_plays_for() {
        let cfg: config::ZoneConfig =
            toml::from_str("[arena]\nmode = \"arena\"\nflags = 2\n").unwrap();
        let a = Arena::new_from(&cfg);
        assert_eq!(a.mode.name(), "arena");
        assert_eq!(a.world.state.flag_count, 2);

        let cfg: config::ZoneConfig = toml::from_str("name = \"bare\"").unwrap();
        let a = Arena::new_from(&cfg);
        assert_eq!(a.mode.name(), "warzone", "and a file that says nothing is a warzone");
        assert_eq!(a.world.state.flag_count, 4);
    }

    /// The zone we ship is the documentation for this format. Parsing it is
    /// half the check; the other half is that every name in it resolves, since
    /// a weapon or an add-on the file cannot have is a warning rather than an
    /// error and would otherwise go out unnoticed.
    #[test]
    fn the_reference_zone_applies_without_a_complaint() {
        let (_, warn) = tuned(include_str!("../../zone/zone.toml"));
        assert!(warn.is_empty(), "{warn:?}");
    }

    /// The bomb rules the original spells out, as settings rather than as
    /// numbers compiled into the baseline.
    #[test]
    fn a_zone_writes_its_own_bomb_rules() {
        let (w, warn) = tuned(r#"
            [arena]
            prox_step = 32
            shrap_inactive = 100
            shrap_inactive_ticks = 5
            mod_spread = 30
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.prox_step, 32 * 256, "two tiles wider a bomb level");
        assert_eq!(w.cfg.shrap_inactive, unsafe { sim::sim_units_energy(100) });
        assert_eq!(w.cfg.shrap_inactive_ticks, 5);
        assert_eq!(w.cfg.mod_spread, (30 * 65536 / 360) as u16);

        // And untouched they are the original's: ProximityDistance gains a
        // tile a level, InactiveShrapDamage is 3 over a quarter second.
        let (w, _) = tuned("[arena]\nmode = \"warzone\"\n");
        assert_eq!(w.cfg.prox_step, 16 * 256);
        assert_eq!(w.cfg.shrap_inactive, unsafe { sim::sim_units_energy(3) });
        assert_eq!(w.cfg.shrap_inactive_ticks, 25);
    }

    /// The weapons that sit in a settings slot rather than on a hull. These
    /// were the only ones in the zone nothing could reach: the repel's radius
    /// and the fragments a bomb breaks into were ours and nobody else's.
    #[test]
    fn a_zone_tunes_the_charges_and_the_shrapnel() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "charge-1"
            blast = 200
            push = 1000

            [[arena.weapons]]
            name = "shrapnel-2"
            count = 12
            damage = 30
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let repel = w.cfg.specs[w.cfg.patterns[w.cfg.charge[0] as usize].spec as usize];
        assert_eq!(repel.blast, 200 * 256, "a shorter shove");
        assert_eq!(repel.push, unsafe { sim::sim_units_speed(1000) });
        let shell = w.cfg.patterns[w.cfg.mod_splinter[2] as usize];
        assert_eq!(shell.count, 12, "a second rung of shrapnel is twelve now");
        assert_eq!(w.cfg.patterns[w.cfg.mod_splinter[1] as usize].count, 2,
                   "and the rung below it is untouched");
    }

    /// The baseline fills two charge slots and leaves two empty. Naming an
    /// empty one makes the weapon and puts it in the slot, so adding a third
    /// charge is one block rather than a block plus a wiring line.
    #[test]
    fn naming_an_empty_charge_slot_fills_it() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "charge-3"
            speed = 0
            life = 1
            on_wall = "pass"
            expire_ends = true
            blast = 400
            damage = 900
            delay = 200

            [arena.prize_weight]
            charge-3 = 40

            [[arena.ships]]
            name = "Anvil"
            charges = [3, 3, 2]
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_ne!(w.cfg.charge[2], sim::NO_PATTERN, "the slot is filled");
        let sp = w.cfg.specs[w.cfg.patterns[w.cfg.charge[2] as usize].spec as usize];
        assert_eq!(sp.blast, 400 * 256);
        assert_eq!(w.cfg.prize_weight[sim::PRIZE_COUNT - 2], 40, "and greens can be it");
        let anvil = ai::class_index("Anvil").unwrap();
        assert_eq!(w.cfg.classes[anvil].charge_max[2], 2, "the Anvil carries two");
        assert_eq!(w.cfg.classes[ai::class_index("Apex").unwrap()].charge_max[2], 0,
                   "and nobody else carries any");
        assert_eq!(w.cfg.charge[3], sim::NO_PATTERN, "the fourth slot is still empty");
    }

    #[test]
    fn a_zone_builds_a_ladder_rather_than_a_single_weapon() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "spike"
            damage = 300

            [[arena.ships]]
            name = "Spire"
            gun = ["spike", "apex-gun-2", "apex-gun-3"]
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let spire = ai::class_index("Spire").unwrap();
        let rungs = w.cfg.classes[spire].trigger[0];
        assert_ne!(rungs[2], sim::NO_PATTERN, "three rungs to climb");
        assert_eq!(rungs[3], sim::NO_PATTERN, "and the ladder ends there");
        let first = w.cfg.specs[w.cfg.patterns[rungs[0] as usize].spec as usize];
        assert_eq!(first.damage, unsafe { sim::sim_units_energy(300) });

        // A rung that names nothing leaves the hull alone rather than
        // half-applying: a ladder silently shortened is a hull that stops
        // levelling for a reason no log would show.
        let (w, warn) = tuned(r#"
            [[arena.ships]]
            name = "Spire"
            gun = ["apex-gun", "not-a-weapon"]
        "#);
        assert!(warn.iter().any(|x| x.contains("not-a-weapon")), "{warn:?}");
        let rungs = w.cfg.classes[spire].trigger[0];
        assert_ne!(rungs[1], sim::NO_PATTERN, "the hull kept its own ladder");
    }

    /// A stat is three numbers -- the original's InitialSpeed, UpgradeSpeed
    /// and MaximumSpeed -- and a zone can write all three.
    #[test]
    fn a_zone_sets_a_floor_and_a_step_as_well_as_a_ceiling() {
        let (w, warn) = tuned(r#"
            [[arena.ships]]
            name = "Apex"
            speed = 4000
            initial_speed = 1000
            upgrade_speed = 600
            initial_energy = 500
            upgrade_recharge = 200
            radius = 20
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let apex = w.cfg.classes[ai::class_index("Apex").unwrap()];
        unsafe {
            assert_eq!(apex.max_speed, sim::sim_units_speed(4000));
            assert_eq!(apex.init_speed, sim::sim_units_speed(1000), "written, not scaled");
            assert_eq!(apex.up_speed, sim::sim_units_speed(600));
            assert_eq!(apex.init_energy, sim::sim_units_energy(500));
            assert_eq!(apex.up_recharge, sim::sim_units_recharge(200));
        }
        assert_eq!(apex.radius, 20 * 256);

        // A ceiling on its own still moves the floor and the step with it, so
        // raising a hull's top speed does not make it start slower relative to
        // where it can get.
        let (w, _) = tuned(r#"
            [[arena.ships]]
            name = "Apex"
            speed = 6500
        "#);
        let apex = w.cfg.classes[ai::class_index("Apex").unwrap()];
        let base = sim::World::new(1).cfg.classes[0];
        assert_eq!(apex.init_speed, base.init_speed * 2, "doubling the ceiling doubled it");
    }

    /// Absent and zero are different things. Every setting the core owns is
    /// absent-means-baseline, which leaves zero free to mean zero: a wall that
    /// gives nothing back, doors that never open, a room with no greens in it.
    #[test]
    fn zero_is_a_setting_rather_than_a_missing_one() {
        let (w, warn) = tuned(r#"
            [arena]
            bounce = 0
            prize_max = 0
            door_period = 0
            prize_life = 400
            prize_radius = 4
            prize_lo = 100
            prize_hi = 900
            flag_radius = 30
            flag_drop_cooldown = 50
            door_open = 100
            wormhole_pull = 40
            wormhole_range = 500
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.bounce, 0, "a wall that eats everything that hits it");
        assert_eq!(w.cfg.prize_max, 0, "and a room with no greens in it");
        assert_eq!(w.cfg.door_period, 0);
        assert_eq!(w.cfg.prize_life, 400);
        assert_eq!(w.cfg.prize_radius, 4 * 256);
        assert_eq!((w.cfg.prize_lo, w.cfg.prize_hi), (100, 900));
        assert_eq!(w.cfg.flag_radius, 30 * 256);
        assert_eq!(w.cfg.flag_drop_cooldown, 50);
        assert_eq!(w.cfg.door_open, 100);
        assert_eq!(w.cfg.wormhole_pull, unsafe { sim::sim_units_speed(40) });
        assert_eq!(w.cfg.wormhole_range, 500 * 256);

        // Left out, each is the core's own.
        let (w, _) = tuned("[arena]\nmode = \"warzone\"\n");
        assert_eq!(w.cfg.bounce, 10);
        assert_eq!(w.cfg.prize_max, 200);
        assert_eq!(w.cfg.door_period, 600);
        assert_eq!(w.cfg.prize_life, 3000);
        assert_eq!(w.cfg.flag_radius, 18 * 256);
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
