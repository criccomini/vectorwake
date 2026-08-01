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
mod config;
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
const MAX_PLAYERS: usize = 16;

// Client to server
const C2S_JOIN: u8 = 1;
const C2S_INPUT: u8 = 2;
const C2S_DUEL: u8 = 3;

// Server to client
const S2C_WELCOME: u8 = 1;
const S2C_SNAPSHOT: u8 = 2;
const S2C_ROSTER: u8 = 3;
const S2C_KILL: u8 = 4;
const S2C_BANNER: u8 = 5;
const S2C_ZONE: u8 = 6;
const S2C_DENIED: u8 = 7;

struct Player {
    ship: u8,
    buttons: u16,
    /// Highest input tick this client has sent, echoed back in snapshots so
    /// it knows how far its prediction has been confirmed.
    last_input_tick: u32,
    name: String,
    tx: mpsc::UnboundedSender<Vec<u8>>,
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
    /// Apply the operator's tuning over the baseline. Anything the zone file
    /// leaves out keeps the value the core ships with, which is what makes a
    /// short config file legal.
    fn apply_config(world: &mut sim::World, c: &config::ArenaConfig) {
        if c.bounce > 0 { world.cfg.bounce = c.bounce; }
        if c.friction > 0 { world.cfg.friction = c.friction; }
        if c.respawn_delay > 0 { world.cfg.respawn_delay = c.respawn_delay; }
        if c.prize_delay > 0 { world.cfg.prize_delay = c.prize_delay; }
        if c.prize_max > 0 { world.cfg.prize_max = c.prize_max; }
        for s in &c.ships {
            let Some(idx) = ai::class_index(&s.name) else { continue };
            let cls = &mut world.cfg.classes[idx];
            unsafe {
                if s.speed > 0 { cls.max_speed = sim::sim_units_speed(s.speed); }
                if s.thrust > 0 { cls.thrust = sim::sim_units_thrust(s.thrust); }
                if s.rotation > 0 { cls.rot = sim::sim_units_rotation(s.rotation); }
                if s.energy > 0 { cls.max_energy = sim::sim_units_energy(s.energy); }
                if s.recharge > 0 { cls.recharge = sim::sim_units_recharge(s.recharge); }
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
    }

    fn new_from(cfg: &config::ZoneConfig) -> Self {
        let mut a = Arena::new();
        Arena::apply_config(&mut a.world, &cfg.arena);
        a
    }

    fn new() -> Self {
        let mut world = sim::World::new(0x5eed);
        let mut bots = Vec::new();
        let mut names = HashMap::new();

        // The population director in miniature: fill the arena with AI so a
        // player arriving alone still finds a game. Bots leave as humans
        // arrive, per docs/design/ai-players.md.
        let roster = ai::roster();
        for (i, r) in roster.iter().enumerate() {
            let ship = world.spawn(r.class, r.team, r.tile_x, r.tile_y, (i as u16) * 8192);
            if ship >= 0 {
                bots.push(ai::Bot::new(ship as u8, r.skill));
                names.insert(ship as u8, (r.name.to_string(), true));
            }
        }
        // Away from every spawn: a flag nobody starts on top of.
        for (tx, ty) in [(512, 492), (532, 512), (512, 532), (492, 512)] {
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

    /// A one on one arena: a small room, two seats, and the duel ruleset.
    /// The opponent is a rating-matched bot when nobody else is queued,
    /// which is what makes duels playable before there is a population.
    fn duel(player_name: String, class: u8, tx: mpsc::UnboundedSender<Vec<u8>>,
            bot_name: &str, bot_skill: f32, bot_class: u8) -> (Self, u64) {
        let mut world = sim::World::with_map(0xd0e1, modes::build_duel_map);
        let a = world.spawn(class.min(7), 0, 505, 522, 0) as u8;
        let b = world.spawn(bot_class.min(7), 1, 519, 502, 32768) as u8;

        let mut names = HashMap::new();
        names.insert(a, (player_name.clone(), false));
        names.insert(b, (bot_name.to_string(), true));

        let mut arena = Arena {
            world,
            players: HashMap::new(),
            bots: vec![ai::Bot::new(b, bot_skill)],
            names,
            next_id: 1,
            rating: rating::Rating::new(),
            mode: Box::new(modes::Duel::new(a, b, 5)),
            banner: String::new(),
            finished: false,
        };
        arena.players.insert(
            1,
            Player { ship: a, buttons: 0, last_input_tick: 0, name: player_name, tx },
        );
        (arena, 1)
    }

    fn join(&mut self, name: String, class: u8, tx: mpsc::UnboundedSender<Vec<u8>>) -> Option<u64> {
        if self.players.len() >= MAX_PLAYERS {
            return None;
        }
        // Take a bot's slot if one is available, so the arena size stays put.
        let ship = if let Some(bot) = self.bots.pop() {
            self.world.state.ships[bot.ship as usize].kills = 0;
            self.world.state.ships[bot.ship as usize].deaths = 0;
            bot.ship
        } else {
            let s = self.world.spawn(class.min(7), 0, 512, 522, 0);
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
        let ev = &*self.world.events;
        let mut deaths: Vec<(u8, u8)> = Vec::new();
        for i in 0..ev.count as usize {
            let e = ev.e[i];
            match e.etype {
                sim::EV_HIT => {
                    let victim = e.a as usize;
                    let attacker = e.b as usize;
                    if victim < sim::MAX_SHIPS && attacker < sim::MAX_SHIPS {
                        let same = self.world.state.ships[victim].team
                            == self.world.state.ships[attacker].team;
                        let vid = self.name_of(e.a);
                        let aid = self.name_of(e.b);
                        self.rating.damage(tick, &vid, &aid, e.v, same);
                    }
                }
                sim::EV_DEATH => deaths.push((e.a, e.b)),
                _ => {}
            }
        }
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
        let n = self.world.pack(buf);
        if n <= 0 {
            return;
        }
        for p in self.players.values() {
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
            let bytes = name.as_bytes();
            let len = bytes.len().min(24) as u8;
            m.push(len);
            m.extend_from_slice(&bytes[..len as usize]);
        }
        m
    }

    fn broadcast_roster(&self) {
        let m = self.roster_msg();
        for p in self.players.values() {
            let _ = p.tx.send(m.clone());
        }
    }
}

/// Every arena the zone is hosting. The public room is arena 0; duels get
/// their own, created on request and torn down when the match ends, which
/// is decision 16 in practice.
struct Zone {
    arenas: HashMap<u32, Arena>,
    next_arena: u32,
    cfg: config::ConfigWatcher,
    store: persist::Store,
}

impl Zone {
    fn new(cfg: config::ConfigWatcher, store: persist::Store) -> Self {
        let mut arenas = HashMap::new();
        arenas.insert(0, Arena::new_from(&cfg.current));
        Zone { arenas, next_arena: 1, cfg, store }
    }

    /// Re-read the zone file and push the new numbers into every live arena.
    /// Nobody is disconnected: an operator tuning a bounce factor should not
    /// cost the room its round.
    fn reload(&mut self) {
        if let Some(msg) = self.cfg.poll() {
            println!("{msg}");
            for a in self.arenas.values_mut() {
                Arena::apply_config(&mut a.world, &self.cfg.current.arena);
            }
        }
    }

    fn zone_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_ZONE];
        let text = format!("{}\n{}", self.cfg.current.name, self.cfg.current.description);
        m.extend_from_slice(text.as_bytes());
        m
    }
}

#[tokio::main]
async fn main() {
    let addr_arg = std::env::args().nth(1);

    let dir = std::env::args().nth(2).unwrap_or_else(|| ".".into());
    let (watcher, err) = config::ConfigWatcher::load(format!("{dir}/zone.toml"));
    if let Some(e) = err {
        println!("no usable zone.toml ({e}); running on the built-in defaults");
    }
    let store = persist::Store::open(format!("{dir}/ratings.json"));
    println!("zone \"{}\": {}", watcher.current.name, watcher.current.description);
    // The command line wins over the zone file, so an operator can move a
    // zone to another port without editing its configuration.
    let addr = addr_arg.unwrap_or_else(|| watcher.current.listen.clone());
    let zone = Arc::new(Mutex::new(Zone::new(watcher, store)));
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind failed");
    println!("vectorwake zone server listening on ws://{addr}");

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
                    let ratings: Vec<(String, f64)> = z.arenas[&0]
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
                for a in z.arenas.values_mut() {
                    a.tick();
                    if n % SNAPSHOT_EVERY == 0 {
                        a.broadcast_snapshot(&mut buf);
                        a.broadcast_banner();
                    }
                }
                // A finished duel takes its room with it. Arena 0 is the
                // public room and never leaves.
                z.arenas.retain(|id, a| *id == 0 || !(a.finished || a.players.is_empty()));
            }
        });
    }

    while let Ok((stream, _)) = listener.accept().await {
        let zone = zone.clone();
        tokio::spawn(async move {
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

            // Which arena this connection is in, and its id there.
            let mut seat: Option<(u32, u64)> = None;
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
                            z.arenas.get_mut(&0).unwrap().rating.score.insert(name.clone(), saved);
                        }
                        let a = z.arenas.get_mut(&0).unwrap();
                        if let Some(new_id) = a.join(name, class, tx.clone()) {
                            seat = Some((0, new_id));
                            let ship = a.players[&new_id].ship;
                            let mut w = vec![S2C_WELCOME, ship];
                            w.extend_from_slice(&a.world.state.tick.to_le_bytes());
                            let _ = tx.send(w);
                            a.broadcast_roster();
                        }
                    }
                    C2S_DUEL => {
                        // Leave whatever room we are in and open a duel against
                        // a rating-matched bot. Nobody waits in a queue that
                        // has nobody else in it.
                        let class = data.get(1).copied().unwrap_or(0);
                        let name = String::from_utf8_lossy(&data[2..]).to_string();
                        let name = if name.is_empty() { "pilot".into() } else { name };
                        let mut z = zone.lock().await;
                        if let Some((aid, pid)) = seat.take() {
                            if let Some(a) = z.arenas.get_mut(&aid) {
                                a.leave(pid);
                                a.broadcast_roster();
                            }
                        }
                        let my_rating = z.arenas[&0].rating.rating_of(&name);
                        let roster = ai::roster();
                        let pick = roster
                            .iter()
                            .min_by(|x, y| {
                                let rx = (z.arenas[&0].rating.rating_of(x.name) - my_rating).abs();
                                let ry = (z.arenas[&0].rating.rating_of(y.name) - my_rating).abs();
                                rx.partial_cmp(&ry).unwrap()
                            })
                            .unwrap();
                        let (arena, pid) = Arena::duel(
                            name, class, tx.clone(), pick.name, pick.skill, pick.class,
                        );
                        let aid = z.next_arena;
                        z.next_arena += 1;
                        let ship = arena.players[&pid].ship;
                        z.arenas.insert(aid, arena);
                        seat = Some((aid, pid));
                        let mut w = vec![S2C_WELCOME, ship];
                        w.extend_from_slice(&0u32.to_le_bytes());
                        let _ = tx.send(w);
                        z.arenas[&aid].broadcast_roster();
                    }
                    C2S_INPUT => {
                        // buttons: u16, tick: u32. The tick is advisory: the
                        // server applies inputs when it receives them and
                        // echoes the number back so the client can reconcile.
                        if data.len() >= 7 {
                            if let Some((aid, pid)) = seat {
                                let buttons = u16::from_le_bytes([data[1], data[2]]);
                                let t = u32::from_le_bytes([data[3], data[4], data[5], data[6]]);
                                let mut z = zone.lock().await;
                                if let Some(a) = z.arenas.get_mut(&aid) {
                                    if let Some(p) = a.players.get_mut(&pid) {
                                        p.buttons = buttons;
                                        p.last_input_tick = t;
                                    }
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }

            if let Some((aid, pid)) = seat {
                let mut z = zone.lock().await;
                if let Some(a) = z.arenas.get_mut(&aid) {
                    a.leave(pid);
                    a.broadcast_roster();
                }
            }
            writer.abort();
        });
    }
}
