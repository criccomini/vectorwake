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

// Server to client
const S2C_WELCOME: u8 = 1;
const S2C_SNAPSHOT: u8 = 2;
const S2C_ROSTER: u8 = 3;

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
}

impl Arena {
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
        Arena {
            world,
            players: HashMap::new(),
            bots,
            names,
            next_id: 1,
        }
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

#[tokio::main]
async fn main() {
    let addr = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "127.0.0.1:9010".to_string());

    let arena = Arc::new(Mutex::new(Arena::new()));
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind failed");
    println!("vectorwake zone server listening on ws://{addr}");

    // The arena loop. One thread owns the simulation for the duration of a
    // tick; connections only ever enqueue inputs.
    {
        let arena = arena.clone();
        tokio::spawn(async move {
            let mut ticker =
                tokio::time::interval(std::time::Duration::from_micros(1_000_000 / TICK_HZ));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut buf = vec![0u8; sim::PACK_MAX];
            let mut n: u32 = 0;
            loop {
                ticker.tick().await;
                let mut a = arena.lock().await;
                a.tick();
                n += 1;
                if n % SNAPSHOT_EVERY == 0 {
                    a.broadcast_snapshot(&mut buf);
                }
            }
        });
    }

    while let Ok((stream, _)) = listener.accept().await {
        let arena = arena.clone();
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

            let mut id: Option<u64> = None;
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
                    C2S_JOIN if id.is_none() => {
                        let class = data.get(1).copied().unwrap_or(0);
                        let name = String::from_utf8_lossy(&data[2..]).to_string();
                        let name = if name.is_empty() { "pilot".into() } else { name };
                        let mut a = arena.lock().await;
                        if let Some(new_id) = a.join(name, class, tx.clone()) {
                            id = Some(new_id);
                            let ship = a.players[&new_id].ship;
                            let mut w = vec![S2C_WELCOME, ship];
                            w.extend_from_slice(&a.world.state.tick.to_le_bytes());
                            let _ = tx.send(w);
                            a.broadcast_roster();
                        }
                    }
                    C2S_INPUT => {
                        // buttons: u16, tick: u32. The tick is advisory: the
                        // server applies inputs when it receives them and
                        // echoes the number back so the client can reconcile.
                        if data.len() >= 7 {
                            if let Some(pid) = id {
                                let buttons = u16::from_le_bytes([data[1], data[2]]);
                                let t = u32::from_le_bytes([data[3], data[4], data[5], data[6]]);
                                let mut a = arena.lock().await;
                                if let Some(p) = a.players.get_mut(&pid) {
                                    p.buttons = buttons;
                                    p.last_input_tick = t;
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }

            if let Some(pid) = id {
                let mut a = arena.lock().await;
                a.leave(pid);
                a.broadcast_roster();
            }
            writer.abort();
        });
    }
}
